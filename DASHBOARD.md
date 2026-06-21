# Grafana Live Metrics Dashboard

A provisioned **Grafana** stack that visualises the Dockerized Ollama backend
powering the offline GitHub Copilot CLI setup. It shows every request, its token
size, the prompt-cache hit/miss split, live KV-cache occupancy, throughput, and a
full history — all parsed from the model logs and the `/api/ps` endpoint.

> Companion to [`README.md`](./README.md) (the setup) and
> [`MODEL-LOGS-AND-CACHE.md`](./MODEL-LOGS-AND-CACHE.md) (the log/cache theory).
> This file documents the dashboard stack itself.

> Replaces the old zero-dependency browser dashboard (`ollama-dashboard.js` +
> `dashboard.html`). Everything is **provisioned as code** and runs in Docker, so
> the dashboard is ready the moment the stack is up — no manual Grafana clicking.

---

## Architecture

The rich numbers (cache-hit rate, reused vs reprocessed, prefill/gen tok/s, session
totals) require **correlating several llama.cpp log lines by task id** — something
LogQL cannot join. So a tiny **exporter** reuses the proven parser and publishes
Prometheus metrics; Loki/Promtail handle the raw-log tables.

```
                      ┌──────────────► Prometheus ─┐
 ollama ──(logs)──► ollama-exporter   (scrape)     │
   │   └─(/api/ps)─►  /metrics :9105               ├─► Grafana :3000
   │                                               │   (provisioned
   └──(logs via docker_sd)──► promtail ─► Loki ────┘    datasources +
                                          :3100         dashboard)
```

| Service | Image (pinned) | Role |
|---|---|---|
| `ollama-exporter` | `node:22.11.0-alpine` | Tails the Ollama logs over the Docker Engine API + polls `/api/ps`; exposes Prometheus metrics on `:9105/metrics`. Zero npm deps. |
| `prometheus` | `prom/prometheus:v2.54.1` | Scrapes the exporter every 5s; 7-day retention. `:9090`. |
| `loki` | `grafana/loki:3.2.1` | Stores the raw Ollama logs (filesystem). `:3100`. |
| `promtail` | `grafana/promtail:3.2.1` | Discovers the Ollama container (docker socket) and ships its logs to Loki. |
| `grafana` | `grafana/grafana:11.3.0` | Provisioned Prometheus + Loki datasources and the bundled dashboard. `:3000`. |

---

## What it shows

| Panel | Source | Meaning |
|---|---|---|
| **Header** — model · params · quant · **CPU/GPU** · ctx · RAM · **keep-alive countdown** | Prometheus (`/api/ps`) | Live model state. The countdown shows when the model unloads (KV cache freed). |
| **Current request** — status (`IDLE`/`PREFILL`/`GENERATING`/`COLD`), tokens sent, **prefill progress**, **reused vs reprocessed**, prefill tok/s, gen tok/s | Prometheus (logs) | The turn in flight. |
| **Live KV cache** — occupancy %, used/free tokens, used/free **MiB** | Prometheus (logs) | Real-time KV-cache occupancy for slot 0; drops to 0 when the model unloads. |
| **Session totals** — turns, POSTs, **5xx/timeouts**, avg prompt, **cache-hit rate**, total reprocessed, total generated | Prometheus (logs) | Aggregates since the exporter started. |
| **Throughput (tok/s)** — prefill & gen time series | Prometheus (logs) | Replaces the old sparkline with a real time series. |
| **Recent turns** | Loki | The raw per-task log lines (`new prompt` / `prompt eval time` / `eval time` / `total time` / `stop processing`). |
| **HTTP requests** | Loki | The raw `[GIN]` access log for `/v1/chat/completions` (time, status, duration, path). |

---

## Run it

```powershell
.\Start-Observability.ps1
```

Then browse to **http://localhost:3000/d/ollama-copilot** (the launcher opens it
automatically). Login is anonymous for viewing; use `admin` / `admin` to edit.

Options:

```powershell
.\Start-Observability.ps1 -NoBrowser
.\Start-Observability.ps1 -Down      # stop/remove the stack (keeps Ollama + volumes)
```

Or drive Compose directly:

```powershell
docker compose up -d ollama-exporter prometheus loki promtail grafana
docker compose stop ollama-exporter prometheus loki promtail grafana
```

On start the exporter **backfills** the last ~600 log lines, so totals and the live
state are populated immediately; new turns then stream in.

### Requirements
- **Docker Desktop** (the same prerequisite as the rest of the setup). The whole
  stack is containerised — **no Node.js on the host** is needed any more.
- The **`ollama` container running** (`docker compose up -d`, or just use the
  launcher, which brings it up).
- The exporter and Promtail read the Ollama container logs via the Docker socket
  (`/var/run/docker.sock`, mounted read-only).

### Airgap
All five images are **pinned**; pull them once while online
(`docker compose pull ollama-exporter prometheus loki promtail grafana`) and they
are cached for offline reuse. Grafana update checks and analytics are disabled.

---

## Which log line drives which metric

The exporter parses the same llama.cpp slot/timing and `[GIN]` lines the old
dashboard did:

| Log line | Metric(s) |
|---|---|
| `… new prompt, … task.n_tokens = N` | `ollama_current_prompt_tokens` |
| `… prompt processing, … progress = P, t = … / R tok/s` | `ollama_current_progress_ratio`, `ollama_current_prefill_tps` |
| `… cached n_tokens = C, memory_seq_rm [C, end)` | `ollama_kv_cache_used_tokens` |
| `… prompt eval time = … / X tokens (…)` | `ollama_current_reprocessed_tokens` (reused = sent − X) |
| `… eval time = … / G tokens (…)` | `ollama_current_gen_tps`, `ollama_generated_tokens_total` |
| `… total time = … / … tokens` | `ollama_last_turn_total_ms` |
| `… stop processing: n_tokens = …` | turn finalized → `ollama_turns_total`, KV updated |
| `[GIN] … 200/500 … POST "/v1/chat/completions"` | `ollama_http_requests_total{status}`, `ollama_http_errors_total` |

The `/api/ps` poll drives the model panels: `ollama_model_loaded` (with
`name`/`params`/`quant`/`processor` labels), `ollama_model_ram_bytes`,
`ollama_model_context_tokens`, `ollama_model_keepalive_seconds`, `ollama_model_gpu`.

> Full annotation of the log lines is in
> [`MODEL-LOGS-AND-CACHE.md`](./MODEL-LOGS-AND-CACHE.md).

---

## Reading it (what "good" vs "slow" looks like)

- **Cold turn** (after `/clear`, or first message): tokens sent ≈ **19–20k**,
  cache hit ≈ **30%**, ~13k reprocessed → minutes of `PREFILL` on CPU. Normal.
- **Fast follow-up** (tool-loop step / auto-retry): high **cache-hit rate** (90%+),
  tiny reprocessed, seconds. The immediate-continuation cache win.
- **A `500` in *5xx / timeouts*** with a ~`10m0s` duration = the fixed request
  timeout (prefill couldn't finish in 10 min). The CLI auto-retries; the next turn
  usually succeeds quickly because the failed attempt warmed the cache.
- **KV occupancy → 0** and header shows `unloaded (cold)` = keep-alive expired; the
  next turn pays a full model reload on top of prefill.

> The single biggest lever to make every number better is a **GPU** — the ~13k
> reprocess drops from minutes to seconds. See README → Performance.

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| Header empty / `No data` | Send a turn so `/api/ps` reports the model. If still empty, is the `ollama` container running? `docker compose ps`. |
| Panels blank but Grafana loads | Check the exporter: `Invoke-WebRequest http://localhost:9105/metrics`. Check the Prometheus target: http://localhost:9090/targets. |
| `ollama_exporter_log_connected` is 0 | The exporter can't read the Docker socket. Confirm `/var/run/docker.sock` is mounted (it is by default) and Docker Desktop is running. |
| *Recent turns* / *HTTP requests* empty | Promtail/Loki warming up (first ~15s) or no traffic yet. Check `http://localhost:3100/ready` and that `job="ollama"` exists in Loki. |
| Port already in use (3000/9090/9105/3100) | Edit the `ports:` mappings in `docker-compose.yml`. |
| KV MiB looks off | It assumes llama3.2:3b @ 32k ctx (3584 MiB). Override `KV_FULL_MIB` / `KV_CTX` in the `ollama-exporter` service env. |

---

## Files

| File | Role |
|---|---|
| `observability/exporter/ollama-exporter.js` | Prometheus exporter: log tailer (Docker Engine API) + `/api/ps` poller. |
| `observability/prometheus/prometheus.yml` | Scrape config (targets the exporter). |
| `observability/loki/loki-config.yml` | Loki single-binary, filesystem storage. |
| `observability/promtail/promtail-config.yml` | Ships the Ollama container logs to Loki. |
| `observability/grafana/provisioning/` | Datasources (Prometheus + Loki) and the dashboard provider. |
| `observability/grafana/dashboards/ollama-copilot.json` | The dashboard itself. |
| `Start-Observability.ps1` | Launcher: brings the stack up, waits for Grafana, opens the browser. |
