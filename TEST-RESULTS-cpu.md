# Local Model Test Campaign — GitHub Copilot CLI (offline)

_Generated: 2026-06-27 12:24 CEST_

## Test bench

| Property | Value |
| --- | --- |
| Host arch | `aarch64` |
| CPU / RAM | 20 cores / 121Gi |
| GPU | NVIDIA GB10 |
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
| `llama3.2:1b` | 1.3 GB | PASS | PASS | FAIL | 288.6 | 26.3 | 0m58s | 3m05s | Good — interactive |
| `llama3.2:3b` | 2.0 GB | PASS | PASS | PASS | 106.1 | 22.9 | 2m19s | 7m26s | Usable — slow |
| `qwen2.5-coder:7b` | 4.7 GB | FAIL | PASS | PASS | 77.4 | 14.2 | 3m14s | 10m21s | Unsupported — no structured tool calls |
| `mistral:7b` | 4.4 GB | PASS | PASS | PASS | 59.3 | 14.2 | 4m07s | 13m11s | Too slow on CPU — exceeds ~10-min timeout |
| `llama3.1:8b` | 4.9 GB | PASS | PASS | PASS | 64.7 | 13.2 | 3m50s | 12m16s | Too slow on CPU — exceeds ~10-min timeout |
| `mistral-nemo:12b` | 7.1 GB | PASS | PASS | PASS | 53.7 | 11.6 | 4m35s | 14m40s | Too slow on CPU — exceeds ~10-min timeout |
| `gpt-oss:20b` | 13 GB | PASS | PASS | PASS | 33.3 | 11.0 | 7m10s | 22m56s | Too slow on CPU — exceeds ~10-min timeout |
| `qwen3:30b-a3b` | 18 GB | PASS | PASS | PASS | 44.8 | 17.8 | 5m16s | 16m51s | Too slow on CPU — exceeds ~10-min timeout |

## Per-model notes & limitations

### `llama3.2:1b` — Good — interactive

- tools: structured tool_calls (n=1); instr: did not say PONG: NO; stream: finish_reason present

### `llama3.2:3b` — Usable — slow

- tools: structured tool_calls (n=1); instr: exact: PONG; stream: finish_reason present

### `qwen2.5-coder:7b` — Unsupported — no structured tool calls

- tools: emits tool call as TEXT in content (agent loop cannot parse): {"name": "get_weather", "arguments": {"city": "Paris"}}; instr: exact: PONG; stream: finish_reason present

### `mistral:7b` — Too slow on CPU — exceeds ~10-min timeout

- tools: structured tool_calls (n=1); instr: exact: PONG; stream: finish_reason present

### `llama3.1:8b` — Too slow on CPU — exceeds ~10-min timeout

- tools: structured tool_calls (n=1); instr: exact: PONG; stream: finish_reason present

### `mistral-nemo:12b` — Too slow on CPU — exceeds ~10-min timeout

- tools: structured tool_calls (n=1); instr: exact: PONG; stream: finish_reason present

### `gpt-oss:20b` — Too slow on CPU — exceeds ~10-min timeout

- tools: structured tool_calls (n=1); instr: exact: PONG; stream: finish_reason present

### `qwen3:30b-a3b` — Too slow on CPU — exceeds ~10-min timeout

- tools: structured tool_calls (n=1); instr: exact: PONG; stream: finish_reason present

## Legend

- **tool_calls PASS** = returns a structured `tool_calls` array (required). **FAIL** = emits the call as text or not at all → the agent loop cannot act.
- **1-pass** = one forward pass of the agent prompt (lower bound). **est. real turn** = 1-pass × 3.2 (calibrated). `Good` ≤ 6 min, `Usable` ≤ 10 min; beyond ~10 min the CLI times out (seen as "transient API error. Retrying…").
- Throughput is CPU-bound here (no GPU); a GPU roughly removes the speed limitation for 7–8B models.
