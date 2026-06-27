---
title: "Air-Gapped GitHub Copilot CLI with Local Models"
subtitle: "Test Campaign Report — Linux / arm64 (NVIDIA GB10)"
author: "GHCP-AIR-GAPPED"
date: "2026-06-27"
---

# Executive summary

This report documents a test campaign for running the **GitHub Copilot CLI** fully
offline (air-gapped) against **local models** served by a Dockerized **Ollama** backend,
on a **Linux / arm64** host equipped with an **NVIDIA GB10** (Grace-Blackwell) GPU.

The work covered four things:

1. **Porting** the project's Windows PowerShell launchers to native Linux/arm64 Bash scripts.
2. **Building an automated test harness** that measures whether a given model can actually
   drive the agentic CLI (structured tool calls, streaming, instruction-following) and how
   fast it runs.
3. **Running the campaign** across eight models (1B → 30B, multiple families) — first
   CPU-only, then GPU-accelerated.
4. **Discovering and fixing the key bottleneck:** the container was not using the GB10 GPU.
   Enabling it changed the result from "only ≤3B models usable" to "every tool-capable
   model is interactive."

**Headline result:** on CPU, prefill of the large (~13.4k-token) agent prompt capped
throughput so badly that every model ≥7B exceeded the CLI's ~10-minute request timeout.
Enabling the GB10 GPU made prompt processing **39–128× faster**, and every tool-capable
model now completes a real Copilot turn in **under a minute**.

# Test bench

| Property | Value |
| --- | --- |
| Host OS / arch | Ubuntu 24.04.4 LTS, `aarch64` (arm64) |
| CPU / RAM | 20 cores / 121 GiB |
| GPU | NVIDIA **GB10** (Grace-Blackwell), CUDA 12.1, **iGPU, 121.6 GiB unified memory** |
| GPU driver | 580.159.03 (CUDA runtime 13.0) |
| Backend | Dockerized **Ollama 0.30.10** on `:11434` (OpenAI-compatible `/v1`) |
| Agent | **GitHub Copilot CLI 1.0.65** |
| Mode | `COPILOT_OFFLINE=true` — no GitHub egress, no telemetry, no auto-update |
| Container Toolkit | NVIDIA Container Toolkit 1.19.1 (Docker `nvidia` runtime registered) |

# How it works (architecture)

The Copilot CLI speaks the OpenAI Chat Completions protocol. Pointing it at a local
OpenAI-compatible endpoint and enabling offline mode keeps **all inference on-device**:

```
User ─▶ start-copilot-with-docker.sh (wrapper)
          ├─ ensure Docker daemon is up (systemctl)
          ├─ docker compose up -d ollama ─▶ [ Ollama container ] OpenAI API @ :11434/v1
          │                                   └─ GB10 GPU via NVIDIA runtime; models in a named volume
          ├─ ensure the model is present (pull once while online)
          ├─ export COPILOT_PROVIDER_* + COPILOT_OFFLINE=true
          └─ exec `copilot` ─▶ inference runs 100% on-device, no GitHub egress
```

The four environment variables that wire the CLI to the local backend:

| Variable | Value |
| --- | --- |
| `COPILOT_PROVIDER_TYPE` | `openai` |
| `COPILOT_PROVIDER_BASE_URL` | `http://localhost:11434/v1` (the `/v1` suffix is required) |
| `COPILOT_PROVIDER_API_KEY` | `ollama` (dummy; local needs no auth) |
| `COPILOT_MODEL` | e.g. `gpt-oss:20b` |
| `COPILOT_OFFLINE` | `true` |

# Deliverables (scripts created)

| File | Purpose |
| --- | --- |
| `start-copilot-with-docker.sh` | Linux/arm64 port of the Docker launcher: starts the daemon (`systemctl`), brings up Ollama, ensures the model, exports `COPILOT_*`, launches `copilot`. Flags: `--model`, `--port`, `--context-length`, `--online/--offline`, `--pull`, `--no-launch`. |
| `start-observability.sh` | Linux/arm64 port of the Grafana stack launcher (`--no-browser`, `--down`); opens the dashboard via `xdg-open`. |
| `model-test-campaign.sh` | Automated test harness (below). Probes capabilities + throughput per model and writes a Markdown report. Flags: `--models`, `--full`, `--keep-going`, `--out`, `--port`. |

# Methodology — what is measured and why

The agentic CLI only works if a model satisfies **three hard requirements**, plus a
practical speed gate:

1. **Structured `tool_calls`** — the model must return tool invocations as a structured
   `tool_calls` array, not as JSON text inside `content`. If it returns text, the agent
   loop cannot parse or execute the call.
2. **Streaming with `finish_reason`** — the Copilot stream parser needs `finish_reason`
   on the terminal chunk.
3. **Instruction-following** — a trivial deterministic check ("reply with exactly PONG").
4. **Speed** — the agent system prompt is large (~13,400 tokens). A turn must finish
   inside the CLI's **~10-minute request timeout**.

The harness derives two timing numbers from Ollama's nanosecond timing fields:

- **1-pass** = one forward pass of the agent prompt = `promptTokens / promptRate + 300 / genRate`.
- **est. real turn** = `1-pass × 3.2`. A real turn runs several LLM calls (think → tool →
  think …). The ×3.2 factor was **calibrated** from `mistral:7b`, whose measured Copilot
  turn was 13m35s versus a 4m14s single pass. The verdict uses **est. real turn**.

# Results

## CPU baseline (GPU disabled)

| Model | Size | tool_calls | prompt t/s | gen t/s | est. real turn | Verdict |
| --- | --- | :---: | ---: | ---: | ---: | --- |
| `llama3.2:1b` | 1.3 GB | PASS | 288.6 | 26.3 | 3m05s | Good |
| `llama3.2:3b` | 2.0 GB | PASS | 106.1 | 22.9 | 7m26s | Usable — slow |
| `qwen2.5-coder:7b` | 4.7 GB | **FAIL** | 77.4 | 14.2 | 10m21s | Unsupported (text tool calls) |
| `mistral:7b` | 4.4 GB | PASS | 59.3 | 14.2 | 13m11s | Too slow |
| `llama3.1:8b` | 4.9 GB | PASS | 64.7 | 13.2 | 12m16s | Too slow |
| `mistral-nemo:12b` | 7.1 GB | PASS | 53.7 | 11.6 | 14m40s | Too slow |
| `gpt-oss:20b` | 13 GB | PASS | 33.3 | 11.0 | 22m56s | Too slow |
| `qwen3:30b-a3b` | 18 GB | PASS | 44.8 | 17.8 | 16m51s | Too slow |

## GPU-accelerated (NVIDIA GB10, CUDA)

| Model | Size | tool_calls | prompt t/s | gen t/s | est. real turn | Verdict |
| --- | --- | :---: | ---: | ---: | ---: | --- |
| `llama3.2:1b` | 1.3 GB | PASS | 16642.4 | 132.0 | 0m10s | Good |
| `llama3.2:3b` | 2.0 GB | PASS | 6379.7 | 73.5 | 0m20s | Good |
| `qwen2.5-coder:7b` | 4.7 GB | **FAIL** | 3024.0 | 40.0 | 0m38s | Unsupported (text tool calls) |
| `mistral:7b` | 4.4 GB | PASS | 2841.1 | 39.1 | 0m40s | Good |
| `llama3.1:8b` | 4.9 GB | PASS | 2877.4 | 36.7 | 0m41s | Good |
| `mistral-nemo:12b` | 7.1 GB | PASS | 2117.4 | 27.1 | 0m56s | Good |
| `gpt-oss:20b` | 13 GB | PASS | 4257.3 | 50.1 | 0m29s | Good |
| `qwen3:30b-a3b` | 18 GB | PASS | 2973.3 | 69.6 | 0m28s | Good |

## CPU vs GPU — the decisive factor

| Model | prompt t/s (CPU → GPU) | est. real turn (CPU → GPU) | Verdict (CPU → GPU) |
| --- | --- | --- | --- |
| `llama3.2:1b` | 289 → 16642 (~58×) | 3m05s → 0m10s | Good → Good |
| `llama3.2:3b` | 106 → 6380 (~60×) | 7m26s → 0m20s | Usable → Good |
| `qwen2.5-coder:7b` | 77 → 3024 (~39×) | 10m21s → 0m38s | Unsupported → Unsupported |
| `mistral:7b` | 59 → 2841 (~48×) | 13m11s → 0m40s | Too slow → Good |
| `llama3.1:8b` | 65 → 2877 (~44×) | 12m16s → 0m41s | Too slow → Good |
| `mistral-nemo:12b` | 54 → 2117 (~39×) | 14m40s → 0m56s | Too slow → Good |
| `gpt-oss:20b` | 33 → 4257 (~128×) | 22m56s → 0m29s | Too slow → Good |
| `qwen3:30b-a3b` | 45 → 2973 (~66×) | 16m51s → 0m28s | Too slow → Good |

## Real Copilot CLI turns (GPU, `--full`)

Ground-truth, end-to-end runs of `copilot -p … --allow-all-tools` against each model:

| Model | Wall time — outcome |
| --- | --- |
| `llama3.2:1b` | 0m03s — ok (said PONG) |
| `llama3.2:3b` | 0m04s — ok (said PONG) |
| `mistral:7b` | 0m10s — completed but off-task |
| `llama3.1:8b` | 0m06s — completed but off-task |
| `mistral-nemo:12b` | 0m09s — ok (said PONG) |
| `gpt-oss:20b` | 0m08s — ok (said PONG) |
| `qwen3:30b-a3b` | 0m10s — ok (said PONG) |

# Enabling the GB10 GPU (the key fix)

Initially the container ran **CPU-only** — the `deploy` GPU block in `docker-compose.yml`
was commented out, so the Blackwell GPU sat idle. Everything needed was already present
(GB10 driver, NVIDIA Container Toolkit 1.19.1, Docker `nvidia` runtime). Enabling it:

```yaml
# docker-compose.yml — ollama service
environment:
  - NVIDIA_VISIBLE_DEVICES=all
  - NVIDIA_DRIVER_CAPABILITIES=compute,utility
deploy:
  resources:
    reservations:
      devices:
        - driver: nvidia
          count: all
          capabilities: ["gpu"]
```

After recreating the container, Ollama detected the GPU:

```
inference compute library=CUDA compute=12.1 name="NVIDIA GB10"
  type=iGPU total="121.6 GiB" available="113.2 GiB"
vram-based default context: total_vram="121.6 GiB" default_num_ctx=262144
```

Because the GB10 uses **unified memory (121.6 GiB)**, even the 30B model loads entirely
into GPU memory with no offloading — and there is headroom for 70B-class models.

# Per-model notes & limitations

- **`llama3.2:1b`** — Good. Fastest; lowest agentic quality. Instruction-following was
  nondeterministic (PASS/FAIL across runs).
- **`llama3.2:3b`** — Good on GPU. Solid lean default; structured tool calls.
- **`qwen2.5-coder:7b`** — **Unsupported.** Emits the tool call as JSON **text** in
  `content` (e.g. `{"name":"get_weather","arguments":{"city":"Paris"}}`), so no
  `tool_calls` are returned and the agent loop cannot act. Fails on both CPU and GPU — a
  model limitation, not hardware. A "coder" model is **not** automatically better here.
- **`mistral:7b` / `llama3.1:8b`** — Good on GPU; structured tool calls. In the `--full`
  runs they finished fast but occasionally ignored the trivial instruction.
- **`mistral-nemo:12b`** — Good on GPU. Dense 12B; reliable structured tool calls.
- **`gpt-oss:20b`** — Good on GPU; MoE (20.9B, MXFP4). Strong quality + speed balance.
- **`qwen3:30b-a3b`** — Good on GPU; MoE (3B active) gives the best generation rate for
  its size. Best quality on this host.

# Foundry Local evaluation (why not on this host)

Microsoft **Foundry Local** was evaluated as an alternative backend. It is now installable
on Linux ARM64 (CLI preview 0.10.1) and its catalog includes `gpt-oss`, `qwen`, `mistral`,
`phi`. **However, it would run CPU-only on this machine** — it cannot use the GB10 GPU.

Foundry Local execution-provider (EP) coverage:

| Execution Provider | Hardware | Platform |
| --- | --- | --- |
| CPU | universal fallback | all platforms |
| WebGPU | any GPU | Windows x64, macOS arm64 |
| CUDA | NVIDIA | Windows x64, **Linux x64** |
| OpenVINO | Intel | Windows x64 |
| QNN | Qualcomm NPU | Windows ARM64 |
| TensorRT RTX | NVIDIA | Windows x64 |
| VitisAI | AMD NPU | Windows x64 |

This host is **Linux `aarch64`**. There is **no CUDA EP for Linux arm64**, and WebGPU is
not offered for Linux → the only EP available is **CPU**. The campaign already showed
CPU-only makes every model ≥7B exceed the agent timeout, so Foundry Local here would be
strictly slower than the GPU-accelerated Ollama path, with no GPU upside.

Additional caveats: the repo's `Start-CopilotWithFoundryLocal.ps1` targets the old
`foundry service …` CLI (renamed to `foundry server …`), and Foundry tool-calling is
preview-grade (one tool call per request; past streaming `tool_calls` bugs; an open issue
"Tool calling fails on NVIDIA GPUs").

**Conclusion:** Foundry Local fits **Windows x64 / Linux x64 + NVIDIA** or **macOS Apple
Silicon**. On this Linux/arm64 + GB10 box, the **Dockerized Ollama + CUDA** path is correct.

# Observability (Grafana)

A Dockerized observability stack (exporter + Prometheus + Loki + Promtail + Grafana)
parses the Ollama logs and `/api/ps` and renders a live dashboard at
`http://localhost:3000/d/ollama-copilot`. It is started with `./start-observability.sh`.

The dashboard shows the served model, processor (CPU/GPU), context window, KV-cache
occupancy, per-request prefill/generation throughput, cache hit/miss, total turns and
requests, plus the parsed request log.

**Campaign timeline (actual, 2026-06-27, local time +0200).** The screenshots below are
anchored to the real test window measured from Prometheus:

| Event | Time |
| --- | --- |
| Observability stack started | 11:37 |
| First generation (CPU era begins) | 11:48 |
| Backend recreated with GPU — **CPU → GPU flip** | 12:31 |
| Last generation (GPU era) | 13:10 |
| Total campaign span | **≈ 1h 22m** |

![Grafana — full campaign window **11:45 → 13:15** (covers every test). Note **Processor: GPU**, `gpt-oss:20b` resident in 12 GiB, **125 turns / 84 POSTs / 43% cache-hit / 167K reprocessed**. In *Throughput (tok/s)* the GPU prefill spikes (~2.5–3.0k tok/s) near 12:30 dwarf the CPU era (sub-300 tok/s, flat on this axis). *Prompt size & KV cache* shows the ~13K-token agent prompt in the CPU era (≈11:50), then the GPU activity from 12:31.](docs/screenshots/grafana-01-campaign-full.png){width=6.3in}

![Grafana — GPU-accelerated era zoom **12:28 → 13:13**. The prefill bursts at ~2.5–3.0k tok/s (12:32–12:35) are the GPU campaign; KV-cache fills to the ~13K-token agent prompt and the parsed turn/HTTP logs show per-request timings (e.g. *prompt eval … 860 tokens/second*).](docs/screenshots/grafana-02-gpu-era.png){width=6.3in}

# Findings & limitations (consolidated)

1. **Tool-call _format_ is the hard gate, and it is hardware-independent.** `qwen2.5-coder:7b`
   fails on both CPU and GPU because it serializes tool calls as text.
2. **On CPU, prefill of the ~13.4k-token agent prompt is the bottleneck — not model size
   or RAM.** Only ≤3B was usable; 121 GiB of RAM did not help.
3. **The GB10 GPU removes that wall:** 39–128× faster prefill; every tool-capable model
   finishes a real turn in under a minute (validated by live `--full` runs).
4. **Unified memory (121.6 GiB) → no offloading,** with headroom for 70B-class models.
5. **MoE helps generation, not CPU prefill.** `gpt-oss:20b` was the *slowest* to prefill on
   CPU; on GPU the MoE models post the best generation rates for their size.
6. **Instruction-following is imperfect / nondeterministic** on some models — validate per
   use case; bigger ≠ always more obedient.
7. **Projection caveat:** the ×3.2 turn factor is calibrated from a single CPU data point.
   It is a planning heuristic; the GPU `--full` measurements are the ground truth.

# Recommendations

- **Keep the GPU enabled** (committed in `docker-compose.yml`).
- **Best quality + speed on this host:** `qwen3:30b-a3b` or `gpt-oss:20b`.
- **Lean default:** `llama3.1:8b` or `mistral:7b` (~40 s real turn).
- **Avoid for agentic use:** `qwen2.5-coder:7b` (text tool calls — agent loop cannot parse).
- Everyday launch: `./start-copilot-with-docker.sh --model gpt-oss:20b`.

# Appendix

## Reproduce the campaign

```bash
# bring up the GPU-accelerated backend (offline)
./start-copilot-with-docker.sh --no-launch --model gpt-oss:20b

# run the full campaign incl. real Copilot turns, write TEST-RESULTS.md
./model-test-campaign.sh --keep-going --full \
  --models "llama3.2:1b llama3.2:3b qwen2.5-coder:7b mistral:7b llama3.1:8b mistral-nemo:12b gpt-oss:20b qwen3:30b-a3b"

# observability dashboard
./start-observability.sh
```

## File inventory

| File | Role |
| --- | --- |
| `start-copilot-with-docker.sh` | Linux/arm64 Docker + Ollama launcher |
| `start-observability.sh` | Linux/arm64 Grafana stack launcher |
| `model-test-campaign.sh` | Automated model test harness |
| `docker-compose.yml` | Ollama (GPU-enabled) + observability stack |
| `TEST-RESULTS.md` | Auto-generated GPU campaign report + analysis |
| `TEST-RESULTS-cpu.md` | CPU baseline report |
| `docs/screenshots/` | Grafana dashboard screenshots |
