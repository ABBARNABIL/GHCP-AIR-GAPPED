# Local Model Test Campaign — GitHub Copilot CLI (offline)

_Generated: 2026-06-27 12:34 CEST_

## Test bench

| Property | Value |
| --- | --- |
| Host arch | `aarch64` |
| CPU / RAM | 20 cores / 121Gi |
| GPU (host) | NVIDIA GB10 |
| Acceleration | GPU — CUDA (container has GPU access) |
| Backend | Dockerized Ollama `0.30.10` on `:11434` |
| Copilot CLI | GitHub Copilot CLI 1.0.65. |
| Mode | `COPILOT_OFFLINE=true` (no GitHub egress) |

## What is measured & why

The agentic CLI only works if a model: (1) returns **structured `tool_calls`** (not
text), (2) streams with **`finish_reason`**, and (3) finishes a turn inside the CLI's
**~10-min request timeout**. The agent system prompt is large (~13400 tokens).

Two derived numbers:

- **1-pass** = one forward pass of that prompt = promptTokens/promptRate + 300/genRate.
- **est. real turn** = 1-pass × 3.2 — a real turn runs several LLM calls (think →
  tool → think …). The ×3.2 factor is calibrated from `mistral:7b`, whose measured
  Copilot turn was 13m35s vs a 4m14s single pass. **The verdict uses est. real turn.**

## Results

| Model | Size | tool_calls | stream | instruction | prompt t/s | gen t/s | 1-pass | est. real turn | Verdict |
| --- | --- | :---: | :---: | :---: | ---: | ---: | ---: | ---: | --- |
| `llama3.2:1b` | 1.3 GB | PASS | PASS | PASS | 16642.4 | 132.0 | 0m03s | 0m10s | Good — interactive |
| `llama3.2:3b` | 2.0 GB | PASS | PASS | PASS | 6379.7 | 73.5 | 0m06s | 0m20s | Good — interactive |
| `qwen2.5-coder:7b` | 4.7 GB | FAIL | PASS | PASS | 3024.0 | 40.0 | 0m12s | 0m38s | Unsupported — no structured tool calls |
| `mistral:7b` | 4.4 GB | PASS | PASS | PASS | 2841.1 | 39.1 | 0m12s | 0m40s | Good — interactive |
| `llama3.1:8b` | 4.9 GB | PASS | PASS | PASS | 2877.4 | 36.7 | 0m13s | 0m41s | Good — interactive |
| `mistral-nemo:12b` | 7.1 GB | PASS | PASS | PASS | 2117.4 | 27.1 | 0m17s | 0m56s | Good — interactive |
| `gpt-oss:20b` | 13 GB | PASS | PASS | PASS | 4257.3 | 50.1 | 0m09s | 0m29s | Good — interactive |
| `qwen3:30b-a3b` | 18 GB | PASS | PASS | PASS | 2973.3 | 69.6 | 0m09s | 0m28s | Good — interactive |

### Real Copilot CLI turns (`--full`)

| Model | Wall time — outcome |
| --- | --- |
| `llama3.2:1b` | 0m03s — ok (said PONG) |
| `llama3.2:3b` | 0m04s — ok (said PONG) |
| `mistral:7b` | 0m10s — completed but off-task |
| `llama3.1:8b` | 0m06s — completed but off-task |
| `mistral-nemo:12b` | 0m09s — ok (said PONG) |
| `gpt-oss:20b` | 0m08s — ok (said PONG) |
| `qwen3:30b-a3b` | 0m10s — ok (said PONG) |

## CPU vs GPU (GB10) — the decisive factor

Same models, same host; the **only** difference is whether the container can reach the
GB10 GPU. Enabling it (the `deploy` block in `docker-compose.yml`) turned "mostly
unusable" into "all interactive". CPU baseline: [TEST-RESULTS-cpu.md](TEST-RESULTS-cpu.md).

| Model | prompt t/s (CPU → GPU) | gen t/s (CPU → GPU) | real turn (CPU → GPU) | verdict (CPU → GPU) |
| --- | --- | --- | --- | --- |
| `llama3.2:1b` | 289 → 16642 (~58×) | 26 → 132 | 3m05s → 0m10s | Good → Good |
| `llama3.2:3b` | 106 → 6380 (~60×) | 23 → 74 | 7m26s → 0m20s | Usable → Good |
| `qwen2.5-coder:7b` | 77 → 3024 (~39×) | 14 → 40 | 10m21s → 0m38s | Unsupported → Unsupported |
| `mistral:7b` | 59 → 2841 (~48×) | 14 → 39 | 13m11s → 0m40s | Too slow → Good |
| `llama3.1:8b` | 65 → 2877 (~44×) | 13 → 37 | 12m16s → 0m41s | Too slow → Good |
| `mistral-nemo:12b` | 54 → 2117 (~39×) | 12 → 27 | 14m40s → 0m56s | Too slow → Good |
| `gpt-oss:20b` | 33 → 4257 (~128×) | 11 → 50 | 22m56s → 0m29s | Too slow → Good |
| `qwen3:30b-a3b` | 45 → 2973 (~66×) | 18 → 70 | 16m51s → 0m28s | Too slow → Good |

## Findings & limitations

1. **Tool-call _format_ is the hard gate — and it is hardware-independent.**
   `qwen2.5-coder:7b` emits the call as JSON **text in `content`**, so Ollama returns no
   `tool_calls` and the agent loop cannot act. It fails on both CPU and GPU. A "coder"
   model is **not** automatically better here; the tool-call serialization is what matters.
2. **On CPU, prefill of the ~13.4k-token agent prompt is the bottleneck — not model size
   or RAM.** Only ≤3B was usable; everything ≥7B blew past the CLI's ~10-min request
   timeout (seen as `transient API error. Retrying…`). 121 GiB of RAM did not help.
3. **The GB10 GPU removes that wall.** Prefill got **39–128× faster**, and every
   tool-capable model now finishes a real turn in **under a minute** — confirmed by the
   live `--full` Copilot runs (3–10 s each).
4. **Unified memory (121.6 GiB) means no offloading.** Even `qwen3:30b-a3b` (18 GB) loads
   fully into GPU memory, with headroom for 70B-class models.
5. **MoE helps generation, not CPU prefill.** On CPU, `gpt-oss:20b` was the *slowest* to
   prefill (33 t/s) because prefill is compute-bound across experts. On GPU the MoE models
   (`gpt-oss:20b`, `qwen3:30b-a3b`) post the best generation rates for their size.
6. **Instruction-following is imperfect and a bit nondeterministic.** In the `--full`
   runs, `mistral:7b` and `llama3.1:8b` completed fast but ignored the trivial "say PONG"
   instruction; `llama3.2:1b` flipped between PASS/FAIL across runs. Bigger ≠ always more
   obedient — validate per use case.
7. **Projection caveat.** The `est. real turn` ×3.2 factor is calibrated from a single CPU
   data point (`mistral:7b`). It is a planning heuristic; real tasks with many tool
   round-trips take longer. The GPU `--full` measurements are the ground truth here.
8. **Context headroom.** With the GPU, Ollama defaulted to a 262k context window, but the
   compose file pins `OLLAMA_CONTEXT_LENGTH=32768`. Given the 122 GiB you can raise it for
   long agent sessions.

### Recommendations for this host

- **Keep the GPU enabled** (now committed in `docker-compose.yml`).
- **Best quality + speed:** `qwen3:30b-a3b` or `gpt-oss:20b` (large, fast on GPU, structured tools).
- **Lean default:** `llama3.1:8b` or `mistral:7b` (small, structured tools, ~40 s real turn).
- **Avoid for agentic use:** `qwen2.5-coder:7b` (text tool calls — agent loop can't parse).

## Per-model notes & limitations

### `llama3.2:1b` — Good — interactive

- tools: structured tool_calls (n=1); instr: exact: PONG; stream: finish_reason present

### `llama3.2:3b` — Good — interactive

- tools: structured tool_calls (n=1); instr: exact: PONG; stream: finish_reason present

### `qwen2.5-coder:7b` — Unsupported — no structured tool calls

- tools: emits tool call as TEXT in content (agent loop cannot parse): {"name": "get_weather", "arguments": {"city": "Paris"}}; instr: exact: PONG; stream: finish_reason present

### `mistral:7b` — Good — interactive

- tools: structured tool_calls (n=1); instr: exact: PONG; stream: finish_reason present

### `llama3.1:8b` — Good — interactive

- tools: structured tool_calls (n=1); instr: exact: PONG; stream: finish_reason present

### `mistral-nemo:12b` — Good — interactive

- tools: structured tool_calls (n=1); instr: exact: PONG; stream: finish_reason present

### `gpt-oss:20b` — Good — interactive

- tools: structured tool_calls (n=1); instr: exact: PONG; stream: finish_reason present

### `qwen3:30b-a3b` — Good — interactive

- tools: structured tool_calls (n=1); instr: exact: PONG; stream: finish_reason present

## Why not Foundry Local on this host

We evaluated Microsoft **Foundry Local** as an alternative backend. It is now installable
on Linux ARM64 (CLI preview `0.10.1`; v1.2.0 "Added support for Linux ARM64 / aarch64")
and its catalog includes `gpt-oss`, `qwen`, `mistral`, `phi`. **But it would run CPU-only
on this machine**, so it cannot use the GB10 GPU — defeating the purpose here.

Foundry Local's execution-provider (EP) coverage (per Microsoft's release notes):

| Execution Provider | Hardware | Platform |
| --- | --- | --- |
| CPU | universal fallback | all platforms |
| WebGPU | any GPU | Windows x64, macOS arm64 |
| CUDA | NVIDIA | Windows x64, **Linux x64** |
| OpenVINO | Intel | Windows x64 |
| QNN | Qualcomm NPU | Windows ARM64 |
| TensorRT RTX | NVIDIA | Windows x64 |
| VitisAI | AMD NPU | Windows x64 |

This host is **Linux `aarch64`**. There is **no CUDA EP for Linux arm64**, and WebGPU is not
offered for Linux at all → the only EP left is **CPU**. The campaign already showed CPU-only
makes every model ≥7B exceed the agent timeout, so Foundry Local here would be strictly
slower than the GPU-accelerated Ollama path, with no GPU upside.

Additional blockers specific to the Copilot CLI use case:

- The repo's `Start-CopilotWithFoundryLocal.ps1` targets the **old** `foundry service …`
  CLI; the new CLI renamed it (`foundry server …`, `foundry run …`), so it would need updating.
- Foundry tool-calling is preview-grade: "one tool call per request," past streaming
  `tool_calls` bugs, and an open issue **"Tool calling fails on NVIDIA GPUs"** — the agent
  loop depends on reliable tool calls.

**Conclusion:** Foundry Local makes sense on **Windows x64 / Linux x64 + NVIDIA** (CUDA) or
**macOS Apple Silicon** (WebGPU). On this Linux/arm64 + GB10 box, the **Dockerized Ollama +
CUDA** path is the right choice.

## Legend

- **tool_calls PASS** = returns a structured `tool_calls` array (required). **FAIL** = emits the call as text or not at all → the agent loop cannot act.
- **1-pass** = one forward pass of the agent prompt (lower bound). **est. real turn** = 1-pass × 3.2 (calibrated). `Good` ≤ 6 min, `Usable` ≤ 10 min; beyond ~10 min the CLI times out (seen as "transient API error. Retrying…").
- Throughput here used **GPU — CUDA (NVIDIA GB10, container has GPU access)**. Prefill of the ~13400-token agent prompt dominates; on CPU that caps the bigger models, while GPU prefill is far faster.
