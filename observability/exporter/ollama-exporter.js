#!/usr/bin/env node
/*
 * ollama-exporter.js — zero-dependency Prometheus exporter for the Dockerized
 * Ollama backend used by the offline GitHub Copilot CLI setup.
 *
 * It replaces the old browser dashboard (ollama-dashboard.js + dashboard.html).
 * Instead of serving an SSE/HTML page, it exposes a Prometheus /metrics endpoint
 * that Grafana visualises (see observability/grafana/dashboards/ollama-copilot.json).
 *
 * The hard numbers (cache-hit rate, reused vs reprocessed, prefill/gen tok/s,
 * session totals) require correlating several llama.cpp log lines by *task id* —
 * something LogQL cannot join — so the proven JS parser is reused here verbatim
 * and the result is published as Prometheus gauges/counters. Loki/Promtail handle
 * the raw-log tables separately.
 *
 * Data sources (same as the old dashboard):
 *   1. Ollama container logs, streamed over the Docker Engine API (unix socket),
 *      parsed with the llama.cpp slot/timing + [GIN] regexes.
 *   2. The Ollama /api/ps endpoint (model load state, RAM, processor, keep-alive).
 *
 * Config via env vars:
 *   METRICS_PORT       (default 9105)                exporter listen port
 *   OLLAMA_URL         (default http://ollama:11434) Ollama HTTP API (for /api/ps)
 *   OLLAMA_CONTAINER   (default "ollama")            container name to tail
 *   DOCKER_SOCKET      (default /var/run/docker.sock) Docker Engine API socket
 *   KV_CTX             (default 32768)               logical context / slot size
 *   KV_FULL_MIB        (default 3584)                KV cache size in MiB at full ctx
 *   LOG_TAIL           (default 600)                 lines of history to backfill
 */
"use strict";

const http = require("http");

const METRICS_PORT = parseInt(process.env.METRICS_PORT || "9105", 10);
const OLLAMA_URL = (process.env.OLLAMA_URL || "http://ollama:11434").replace(/\/+$/, "");
const CONTAINER = process.env.OLLAMA_CONTAINER || "ollama";
const DOCKER_SOCKET = process.env.DOCKER_SOCKET || "/var/run/docker.sock";
const KV_CTX = parseInt(process.env.KV_CTX || "32768", 10);
const KV_FULL_MIB = parseInt(process.env.KV_FULL_MIB || "3584", 10);
const LOG_TAIL = process.env.LOG_TAIL || "600";

// ------------------------------------------------------------------ state ----
const state = {
  model: { name: null, params: null, quant: null, processor: "CPU",
           ctx: KV_CTX, ramBytes: null, loaded: false, expiresAt: null, secsToExpire: null },
  current: { taskId: null, status: "idle", promptTokens: 0, nKeep: 4,
             progress: 0, prefillTps: null, genTps: null,
             reusedTokens: 0, reprocessedTokens: 0, active: false },
  kvUsedTokens: 0,
  lastTurn: { promptTokens: null, reusedTokens: null, reprocessedTokens: null,
              genTokens: null, prefillMs: null, totalMs: null,
              prefillTps: null, genTps: null, cacheHitRatio: null },
  agg: { turns: 0, posts: 0, errors: 0,
         totalReprocessed: 0, totalGenerated: 0, totalReused: 0, promptSum: 0 },
  httpStatus: new Map(),   // status code -> count
  logConnected: false,
};

// per-task scratch while a task is in flight (keyed by taskId)
const tasks = new Map();
function task(id) {
  if (!tasks.has(id)) tasks.set(id, {
    taskId: id, promptTokens: 0, nKeep: 4, reprocessedTokens: null,
    reusedTokens: null, prefillMs: null, prefillTps: null,
    genTokens: null, genTps: null, totalMs: null, startTs: Date.now(),
  });
  return tasks.get(id);
}

// ------------------------------------------------------------- log regexes ----
const RE = {
  newPrompt: /task (\d+) \| new prompt, n_ctx_slot = (\d+), n_keep = (\d+), task\.n_tokens = (\d+)/,
  processing: /task (\d+) \| prompt processing, n_tokens =\s*(\d+), progress = ([\d.]+), t =\s*([\d.]+) s \/ ([\d.]+) tokens per second/,
  cached: /task (\d+) \| cached n_tokens = (\d+), memory_seq_rm \[(\d+), end\)/,
  promptEval: /task (\d+) \| prompt eval time =\s*([\d.]+) ms \/\s*(\d+) tokens \(\s*([\d.]+) ms per token,\s*([\d.]+) tokens per second\)/,
  eval: /task (\d+) \|\s*eval time =\s*([\d.]+) ms \/\s*(\d+) tokens \(\s*([\d.]+) ms per token,\s*([\d.]+) tokens per second\)/,
  totalTime: /task (\d+) \|\s*total time =\s*([\d.]+) ms \/\s*(\d+) tokens/,
  release: /task (\d+) \| stop processing: n_tokens = (\d+), truncated = (\d+)/,
  gin: /\[GIN\]\s+([\d/]+ - [\d:]+)\s+\|\s*(\d+)\s+\|\s*([^|]+?)\s*\|\s*([\d.a-fµ:]+)\s*\|\s*(\w+)\s+"([^"]+)"/,
};

function setCurrentFromTask(t, status) {
  const c = state.current;
  c.taskId = t.taskId;
  c.status = status;
  c.promptTokens = t.promptTokens;
  c.nKeep = t.nKeep;
  c.reusedTokens = t.reusedTokens || 0;
  c.reprocessedTokens = t.reprocessedTokens || 0;
  c.prefillTps = t.prefillTps;
  c.genTps = t.genTps;
  c.active = status === "prefill" || status === "generating";
}

function parseLine(line) {
  let m;

  if ((m = RE.newPrompt.exec(line))) {
    const id = +m[1];
    const t = task(id);
    t.promptTokens = +m[4];
    t.nKeep = +m[3];
    t.startTs = Date.now();
    setCurrentFromTask(t, "prefill");
    state.current.progress = 0;
    return true;
  }

  if ((m = RE.processing.exec(line))) {
    const id = +m[1];
    const t = task(id);
    const progress = parseFloat(m[3]);
    const tps = parseFloat(m[5]);
    t.prefillTps = tps;
    if (state.current.taskId === id) {
      state.current.progress = progress;
      state.current.prefillTps = tps;
      state.current.status = "prefill";
      state.current.active = true;
    }
    // live KV occupancy estimate from progress
    state.kvUsedTokens = Math.round(progress * t.promptTokens);
    return true;
  }

  if ((m = RE.cached.exec(line))) {
    const id = +m[1];
    state.kvUsedTokens = +m[2];
    if (state.current.taskId === id) state.current.active = true;
    return true;
  }

  if ((m = RE.promptEval.exec(line))) {
    const id = +m[1];
    const t = task(id);
    t.reprocessedTokens = +m[3];
    t.prefillMs = parseFloat(m[2]);
    t.prefillTps = parseFloat(m[5]);
    t.reusedTokens = Math.max(0, t.promptTokens - t.reprocessedTokens);
    if (state.current.taskId === id) {
      state.current.reprocessedTokens = t.reprocessedTokens;
      state.current.reusedTokens = t.reusedTokens;
      state.current.status = "generating";
      state.current.active = true;
    }
    return true;
  }

  if ((m = RE.eval.exec(line))) {
    const id = +m[1];
    const t = task(id);
    t.genTokens = +m[3];
    t.genTps = parseFloat(m[5]);
    if (state.current.taskId === id) {
      state.current.genTps = t.genTps;
      state.current.status = "generating";
    }
    return true;
  }

  if ((m = RE.totalTime.exec(line))) {
    const id = +m[1];
    task(id).totalMs = parseFloat(m[2]);
    return true;
  }

  if ((m = RE.release.exec(line))) {
    const id = +m[1];
    const t = task(id);
    state.kvUsedTokens = Math.min(KV_CTX, +m[2]);
    finalizeTask(t);
    tasks.delete(id);
    if (state.current.taskId === id) {
      state.current.status = "idle";
      state.current.active = false;
    }
    return true;
  }

  if ((m = RE.gin.exec(line))) {
    const status = +m[2];
    const p = m[6];
    if (p.includes("/chat/completions")) {
      state.agg.posts++;
      state.httpStatus.set(status, (state.httpStatus.get(status) || 0) + 1);
      if (status >= 400) state.agg.errors++;
    }
    return true;
  }

  return false;
}

function finalizeTask(t) {
  const known = t.reprocessedTokens != null;          // saw a `prompt eval time` line
  const reused = known ? Math.max(0, t.promptTokens - t.reprocessedTokens) : null;

  // latest-turn snapshot (drives the "last turn" panels + per-turn time series)
  const lt = state.lastTurn;
  lt.promptTokens = t.promptTokens;
  lt.reusedTokens = reused;
  lt.reprocessedTokens = known ? t.reprocessedTokens : null;
  lt.genTokens = t.genTokens;
  lt.prefillMs = t.prefillMs;
  lt.totalMs = t.totalMs;
  lt.prefillTps = t.prefillTps;
  lt.genTps = t.genTps;
  lt.cacheHitRatio = (known && t.promptTokens > 0) ? (reused / t.promptTokens) : null;

  // aggregates
  const a = state.agg;
  a.turns++;
  a.promptSum += t.promptTokens || 0;
  if (known) {
    a.totalReprocessed += t.reprocessedTokens;
    a.totalReused += reused;
  }
  if (t.genTokens != null) a.totalGenerated += t.genTokens;
}

// ----------------------------------------------- docker logs (engine API) -----
let retryTimer = null;
function scheduleRetry() {
  if (retryTimer) return;
  retryTimer = setTimeout(() => { retryTimer = null; startLogStream(); }, 3000);
}

function startLogStream() {
  const path = `/containers/${encodeURIComponent(CONTAINER)}/logs` +
               `?stdout=1&stderr=1&follow=1&tail=${encodeURIComponent(LOG_TAIL)}`;
  const req = http.request({ socketPath: DOCKER_SOCKET, path, method: "GET" }, (res) => {
    if (res.statusCode !== 200) {
      state.logConnected = false;
      console.error(`[exporter] docker logs HTTP ${res.statusCode} for container '${CONTAINER}'`);
      res.resume();
      scheduleRetry();
      return;
    }
    state.logConnected = true;
    console.error(`[exporter] streaming logs from container '${CONTAINER}'`);

    // The Docker logs stream for a non-TTY container is multiplexed: each frame
    // is an 8-byte header [stream(1), 0,0,0, size(4 BE)] followed by `size` bytes.
    let buf = Buffer.alloc(0);
    let text = "";
    const flushLines = () => {
      let idx;
      while ((idx = text.indexOf("\n")) >= 0) {
        const line = text.slice(0, idx);
        text = text.slice(idx + 1);
        try { parseLine(line); } catch (e) { /* ignore parse errors */ }
      }
    };
    res.on("data", (chunk) => {
      buf = Buffer.concat([buf, chunk]);
      while (buf.length >= 8) {
        const size = buf.readUInt32BE(4);
        if (buf.length < 8 + size) break;
        text += buf.slice(8, 8 + size).toString("utf8");
        buf = buf.slice(8 + size);
        flushLines();
      }
    });
    res.on("end", () => {
      state.logConnected = false;
      console.error("[exporter] docker logs stream ended; retrying in 3s");
      scheduleRetry();
    });
    res.on("error", () => { state.logConnected = false; scheduleRetry(); });
  });
  req.on("error", (e) => {
    state.logConnected = false;
    console.error(`[exporter] docker logs request error: ${e.message}; retrying in 3s`);
    scheduleRetry();
  });
  req.end();
}

// ----------------------------------------------------------- /api/ps poll ----
async function pollPs() {
  try {
    const r = await fetch(OLLAMA_URL + "/api/ps", { signal: AbortSignal.timeout(4000) });
    const j = await r.json();
    const m = (j.models && j.models[0]) || null;
    if (m) {
      const d = m.details || {};
      state.model.name = m.name || m.model || state.model.name;
      state.model.params = d.parameter_size || state.model.params;
      state.model.quant = d.quantization_level || state.model.quant;
      state.model.ctx = m.context_length || KV_CTX;
      state.model.ramBytes = m.size != null ? m.size : state.model.ramBytes;
      state.model.processor = (m.size_vram && m.size_vram > 0) ? "GPU" : "CPU";
      state.model.loaded = true;
      state.model.expiresAt = m.expires_at || null;
      if (m.expires_at) {
        state.model.secsToExpire = (new Date(m.expires_at).getTime() - Date.now()) / 1000;
      }
    } else {
      state.model.loaded = false;
      state.model.secsToExpire = null;
      state.kvUsedTokens = 0;           // KV cache freed when the model unloads
      if (state.current.status === "idle") state.current.active = false;
    }
  } catch (e) {
    // leave previous values; the exporter stays up
  }
}

// --------------------------------------------------------- metrics render -----
function esc(s) {
  return String(s == null ? "" : s).replace(/\\/g, "\\\\").replace(/\n/g, "\\n").replace(/"/g, '\\"');
}
function fmt(v) {
  if (v == null || Number.isNaN(v)) return "NaN";
  return Number.isFinite(v) ? String(v) : "NaN";
}
function metric(out, name, type, help, samples) {
  out.push(`# HELP ${name} ${help}`);
  out.push(`# TYPE ${name} ${type}`);
  for (const s of samples) {
    let labels = "";
    if (s.labels) {
      const parts = Object.entries(s.labels)
        .filter(([, v]) => v != null && v !== "")
        .map(([k, v]) => `${k}="${esc(v)}"`);
      if (parts.length) labels = "{" + parts.join(",") + "}";
    }
    out.push(`${name}${labels} ${fmt(s.value)}`);
  }
}

function statusCode() {
  const c = state.current;
  if (!state.model.loaded && c.status === "idle") return 3;   // cold
  if (c.status === "prefill") return 1;
  if (c.status === "generating") return 2;
  return 0;                                                   // idle
}

function renderMetrics() {
  const out = [];
  const m = state.model;
  const c = state.current;
  const a = state.agg;
  const used = Math.min(KV_CTX, state.kvUsedTokens || 0);
  const usedMiB = (used / KV_CTX) * KV_FULL_MIB;
  const labels = { name: m.name, params: m.params, quant: m.quant, processor: m.processor };

  metric(out, "ollama_exporter_up", "gauge", "Exporter is running (always 1).",
    [{ value: 1 }]);
  metric(out, "ollama_exporter_log_connected", "gauge",
    "Docker logs stream is currently connected (1) or not (0).",
    [{ value: state.logConnected ? 1 : 0 }]);

  // --- model (from /api/ps) ---
  metric(out, "ollama_model_loaded", "gauge",
    "Model resident in memory (1) or unloaded/cold (0). Labels carry model id.",
    [{ value: m.loaded ? 1 : 0, labels }]);
  metric(out, "ollama_model_gpu", "gauge",
    "Model running on GPU (1) or CPU (0).",
    [{ value: m.processor === "GPU" ? 1 : 0 }]);
  metric(out, "ollama_model_ram_bytes", "gauge",
    "Resident model size in bytes (from /api/ps).",
    [{ value: m.ramBytes != null ? m.ramBytes : NaN }]);
  metric(out, "ollama_model_context_tokens", "gauge",
    "Model context window in tokens.",
    [{ value: m.ctx != null ? m.ctx : KV_CTX }]);
  metric(out, "ollama_model_keepalive_seconds", "gauge",
    "Seconds until keep-alive expiry unloads the model (0 when unloaded).",
    [{ value: m.loaded && m.secsToExpire != null ? Math.max(0, m.secsToExpire) : 0 }]);

  // --- current turn ---
  metric(out, "ollama_current_status_code", "gauge",
    "Current turn status: 0 idle, 1 prefill, 2 generating, 3 cold.",
    [{ value: statusCode() }]);
  metric(out, "ollama_current_prompt_tokens", "gauge",
    "Prompt size (tokens sent) of the in-flight turn.",
    [{ value: c.promptTokens || 0 }]);
  metric(out, "ollama_current_progress_ratio", "gauge",
    "Prefill progress of the in-flight turn (0..1).",
    [{ value: c.progress || 0 }]);
  metric(out, "ollama_current_prefill_tps", "gauge",
    "Live prefill throughput (tokens/sec) while prefilling, else 0.",
    [{ value: c.status === "prefill" && c.prefillTps != null ? c.prefillTps : 0 }]);
  metric(out, "ollama_current_gen_tps", "gauge",
    "Live generation throughput (tokens/sec) while generating, else 0.",
    [{ value: c.status === "generating" && c.genTps != null ? c.genTps : 0 }]);
  metric(out, "ollama_current_reused_tokens", "gauge",
    "Tokens reused from the prompt cache (hit) on the in-flight turn.",
    [{ value: c.reusedTokens || 0 }]);
  metric(out, "ollama_current_reprocessed_tokens", "gauge",
    "Tokens reprocessed (cache miss) on the in-flight turn.",
    [{ value: c.reprocessedTokens || 0 }]);
  metric(out, "ollama_current_nkeep", "gauge",
    "Protected token count (n_keep) of the in-flight turn.",
    [{ value: c.nKeep != null ? c.nKeep : 4 }]);

  // --- KV cache (slot 0) ---
  metric(out, "ollama_kv_cache_capacity_tokens", "gauge",
    "KV cache capacity in tokens (context size).", [{ value: KV_CTX }]);
  metric(out, "ollama_kv_cache_used_tokens", "gauge",
    "KV cache tokens currently occupied (slot 0).", [{ value: used }]);
  metric(out, "ollama_kv_cache_used_mib", "gauge",
    "KV cache MiB currently occupied (slot 0).", [{ value: usedMiB }]);
  metric(out, "ollama_kv_cache_full_mib", "gauge",
    "KV cache MiB at full context.", [{ value: KV_FULL_MIB }]);

  // --- session totals (counters; reset on exporter restart) ---
  metric(out, "ollama_turns_total", "counter",
    "Total model turns (tasks) finalized.", [{ value: a.turns }]);
  const httpSamples = [];
  for (const [status, count] of [...state.httpStatus.entries()].sort((x, y) => x[0] - y[0])) {
    httpSamples.push({ value: count, labels: { status: String(status) } });
  }
  if (!httpSamples.length) httpSamples.push({ value: 0, labels: { status: "none" } });
  metric(out, "ollama_http_requests_total", "counter",
    "Total /chat/completions POSTs seen in the [GIN] access log, by status.",
    httpSamples);
  metric(out, "ollama_http_errors_total", "counter",
    "Total /chat/completions POSTs with status >= 400 (5xx / timeouts).",
    [{ value: a.errors }]);
  metric(out, "ollama_prompt_tokens_total", "counter",
    "Sum of prompt tokens across all turns (for avg-prompt).", [{ value: a.promptSum }]);
  metric(out, "ollama_reused_tokens_total", "counter",
    "Sum of cache-hit (reused) tokens across all turns.", [{ value: a.totalReused }]);
  metric(out, "ollama_reprocessed_tokens_total", "counter",
    "Sum of reprocessed (cache-miss) tokens across all turns.", [{ value: a.totalReprocessed }]);
  metric(out, "ollama_generated_tokens_total", "counter",
    "Sum of generated tokens across all turns.", [{ value: a.totalGenerated }]);

  // --- last finalized turn ---
  const lt = state.lastTurn;
  metric(out, "ollama_last_turn_prompt_tokens", "gauge",
    "Prompt tokens of the most recently finalized turn.",
    [{ value: lt.promptTokens != null ? lt.promptTokens : NaN }]);
  metric(out, "ollama_last_turn_reused_tokens", "gauge",
    "Reused (cache-hit) tokens of the most recent turn.",
    [{ value: lt.reusedTokens != null ? lt.reusedTokens : NaN }]);
  metric(out, "ollama_last_turn_reprocessed_tokens", "gauge",
    "Reprocessed (cache-miss) tokens of the most recent turn.",
    [{ value: lt.reprocessedTokens != null ? lt.reprocessedTokens : NaN }]);
  metric(out, "ollama_last_turn_generated_tokens", "gauge",
    "Generated tokens of the most recent turn.",
    [{ value: lt.genTokens != null ? lt.genTokens : NaN }]);
  metric(out, "ollama_last_turn_prefill_ms", "gauge",
    "Prefill time (ms) of the most recent turn.",
    [{ value: lt.prefillMs != null ? lt.prefillMs : NaN }]);
  metric(out, "ollama_last_turn_total_ms", "gauge",
    "Total time (ms) of the most recent turn.",
    [{ value: lt.totalMs != null ? lt.totalMs : NaN }]);
  metric(out, "ollama_last_turn_prefill_tps", "gauge",
    "Prefill throughput (tok/s) of the most recent turn.",
    [{ value: lt.prefillTps != null ? lt.prefillTps : NaN }]);
  metric(out, "ollama_last_turn_gen_tps", "gauge",
    "Generation throughput (tok/s) of the most recent turn.",
    [{ value: lt.genTps != null ? lt.genTps : NaN }]);
  metric(out, "ollama_last_turn_cache_hit_ratio", "gauge",
    "Cache-hit ratio (reused/prompt, 0..1) of the most recent turn.",
    [{ value: lt.cacheHitRatio != null ? lt.cacheHitRatio : NaN }]);

  return out.join("\n") + "\n";
}

// ----------------------------------------------------------------- server -----
const server = http.createServer((req, res) => {
  const url = (req.url || "").split("?")[0];
  if (url === "/metrics") {
    res.writeHead(200, { "Content-Type": "text/plain; version=0.0.4; charset=utf-8" });
    res.end(renderMetrics());
    return;
  }
  if (url === "/healthz" || url === "/") {
    res.writeHead(200, { "Content-Type": "text/plain" });
    res.end("ok\n");
    return;
  }
  res.writeHead(404, { "Content-Type": "text/plain" });
  res.end("not found\n");
});

server.listen(METRICS_PORT, () => {
  console.error(`\n  ollama-exporter → http://0.0.0.0:${METRICS_PORT}/metrics`);
  console.error(`  container=${CONTAINER}  ollama=${OLLAMA_URL}  socket=${DOCKER_SOCKET}  ctx=${KV_CTX}\n`);
  startLogStream();
  pollPs();
  setInterval(pollPs, 3000);   // model state / keep-alive countdown
});
