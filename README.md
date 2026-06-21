# Local LLM in Docker + GitHub Copilot CLI (offline / airgapped)

Run a local model **inside a Docker container** and drive the **GitHub Copilot CLI**
against it with **offline (airgapped) mode** enabled, so the CLI talks only to your
local provider and never to GitHub's servers.

Based on the GitHub docs:
*[Using your own LLM models in Copilot CLI](https://docs.github.com/en/copilot/how-tos/copilot-cli/customize-copilot/use-byok-models#running-in-offline-mode)*
(BYOK via `COPILOT_PROVIDER_*` + `COPILOT_OFFLINE=true`).

## How it works

```
User ─▶ Start-CopilotWithDocker.ps1 (wrapper)
          ├─ ensure Docker daemon is up
          ├─ docker compose up -d ─▶ [ Ollama container ]  OpenAI-compatible API @ :11434/v1
          │                               └─ named volume: models persist (pull once, reuse offline)
          ├─ ensure the model is present (pull once while online)
          ├─ export COPILOT_PROVIDER_* + COPILOT_OFFLINE=true
          └─ exec `copilot` ─▶ inference runs 100% on-device, no GitHub egress
```

This maps to `How-it-works.png`: **Wrapper script → Exec Copilot CLI → OpenAI-compatible
API → Local LLM backend (Ollama)**.

## Files

| File | Purpose |
| --- | --- |
| `docker-compose.yml` | Runs Ollama (pinned `0.30.10`), exposes `:11434`, persists models in a named volume, sets a 32k context window. Also defines the Grafana observability stack (exporter + Prometheus + Loki + Promtail + Grafana). |
| `Start-CopilotWithDocker.ps1` | Wrapper: starts Docker + the container, ensures the model, exports the `COPILOT_*` env vars, launches `copilot`. |
| `observability/` + `Start-Observability.ps1` | **Grafana live metrics dashboard** — parses the model logs + `/api/ps` and shows requests, token size, cache hit/miss, live KV cache and throughput. See [`DASHBOARD.md`](./DASHBOARD.md). |
| `README.md` | This guide. |

There is also `Start-CopilotWithFoundryLocal.ps1`, an alternative wrapper that uses
**Foundry Local** instead of Docker. This guide covers the Docker path.

## Prerequisites

- **Docker Desktop** with the WSL2 backend enabled.
- **GitHub Copilot CLI**: `winget install GitHub.Copilot` (verify with `copilot --version`).
- A GitHub Copilot subscription for the initial sign-in (see *Airgap notes* below).

## Quick start

### 1. One-time online setup (needs network)

Pull the container image **and** the model into the persistent volume:

```powershell
cd "<this-folder>"
# Starts Docker if needed, brings up Ollama, and pulls the model on first run:
./Start-CopilotWithDocker.ps1 -Pull
```

The first run downloads the Ollama image (~3.4 GB) and the model (llama3.2:3b ≈ 2.0 GB).
Both are cached in the `ollama` Docker volume, so you only do this once.

> **No GitHub sign-in is required for offline BYOK use.** `COPILOT_OFFLINE=true` disables
> GitHub authentication, and a BYOK provider needs no GitHub login. Only the image/model
> downloads above require network.

### 2. Everyday use (offline / airgapped)

```powershell
./Start-CopilotWithDocker.ps1
```

This is offline by default (`COPILOT_OFFLINE=true`). It will refuse to start if the
model is not already in the volume (so you never accidentally hit the network).

To set the environment without launching the CLI:

```powershell
./Start-CopilotWithDocker.ps1 -NoLaunch
copilot
```

### Manual equivalent (no wrapper)

```powershell
docker compose up -d
$env:COPILOT_PROVIDER_TYPE     = "openai"
$env:COPILOT_PROVIDER_BASE_URL = "http://localhost:11434/v1"   # NOTE: the /v1 suffix is required
$env:COPILOT_PROVIDER_API_KEY  = "ollama"                       # dummy; local Ollama needs no auth
$env:COPILOT_MODEL             = "llama3.2:3b"
$env:COPILOT_OFFLINE           = "true"
copilot
```

## Choosing a model

The agentic CLI **requires** a model that supports **tool calling** *and* **streaming**.
Critically, the model's tool calls must come back as **structured `tool_calls`** that
Ollama can parse — not as plain text.

| Model | Tool calls | CPU verdict | Notes |
| --- | --- | --- | --- |
| **llama3.2:3b** (default) | ✅ structured | ✅ completes (~6 min cold turn) | Recommended on this CPU-only host. Lower agentic quality than larger models. |
| llama3.1:8b | ✅ structured | ❌ exceeds the ~10-min timeout | Best quality + reliable tools, but needs a **GPU** to be usable here. Override: `-Model llama3.1:8b`. |
| qwen2.5-coder:7b | ⚠️ plain text | n/a | At Q4 it emits `{"name":...,"arguments":...}` as message **content**, so Ollama returns no `tool_calls` and the agent loop breaks. OK for manual/non-agentic chat only. |

> The original request specified `qwen2.5-coder:7b`, but it **does not return
> Ollama-parseable tool calls at Q4** (which the agentic CLI needs). `llama3.1:8b` fixes
> the tool calls but is **too slow on CPU** (exceeds the ~10-min request timeout), so the
> default is **`llama3.2:3b`**, which actually completes on this hardware. To use another:
> `./Start-CopilotWithDocker.ps1 -Model qwen2.5-coder:7b` (or `-Model llama3.1:8b` on a GPU host).

Verify any candidate model yourself:

```powershell
# Expect a non-null "tool_calls" array:
$body = '{"model":"llama3.2:3b","stream":false,"messages":[{"role":"user","content":"What is the weather in Paris?"}],"tools":[{"type":"function","function":{"name":"get_weather","description":"Get weather for a city","parameters":{"type":"object","properties":{"city":{"type":"string"}},"required":["city"]}}}]}'
(Invoke-RestMethod http://localhost:11434/v1/chat/completions -Method Post -ContentType application/json -Body $body).choices[0].message.tool_calls
```

## Performance (read this on CPU-only hosts)

This host has **no NVIDIA GPU**, so Ollama runs **100% on CPU**.

The Copilot CLI sends a large agent prompt — **~19–20k tokens** (measured **19,342** on this
host: system instructions + tool schemas + environment). `COPILOT_OFFLINE=true` already
strips the GitHub MCP server, so this is the **irreducible floor** — it cannot be shrunk
further.

The provider request also has a **fixed ~10-minute timeout** (not configurable). Measured
CPU prompt-processing rates on this host:

| Model | Prompt processing | First cold turn (~19–20k tok) | Verdict on CPU-only |
| --- | --- | --- | --- |
| llama3.1:8b | ~17–30 tok/s | **> 10 min → times out** | Not usable here without a GPU. |
| llama3.2:3b | ~34–55 tok/s | ~6–10 min (can brush the timeout) | Usable, but slow; lower quality. |

> Small models also give **weaker agentic behavior** — they may emit tool calls as plain
> text or pick the wrong tool. Expect a noticeably less reliable experience than
> GitHub-hosted models. **A GPU + the 8B model is the recommended combination.**

### Measured run on this CPU-only host (llama3.2:3b)

Two real interactive turns, captured live from the Ollama logs:

**`Hello` (pure chat) — 3 model turns, ~12 min total:**

| Turn | Result | Time | Notes |
| --- | --- | --- | --- |
| 1 (cold) | 200 | **9m44s** | Read all 19,342 tokens @ 34 tok/s (565s) + generated 18 tokens. Just under the 10-min ceiling. |
| 2 | 200 | 55.7s | Prompt-cache hit on the shared prefix. |
| 3 | 200 | 1m55s | Cache hit. |

**`List the files in the current directory.` (tool use) — hit the timeout, then recovered:**

| Task | Result | Time | Notes |
| --- | --- | --- | --- |
| 398 | **500** | **10m0s** | Cache matched only the first ~9.5k tokens; the remaining ~13k reprocessed at 22–42 tok/s and **crossed the 10-min ceiling**. |
| 413 | 200 | 46.7s | The CLI **auto-retried**; the failed attempt had warmed the cache (prompt-eval = 1 token), so it emitted the tool call fast. |
| 443 | 200 | 1m2s | Tool result fed back (203 tokens in) → final answer (77 tokens) listing the 6 files. |

**`/clear` then re-send the *same* `List the files` prompt — does NOT speed things up:**

| Task | Result | Time | Notes |
| --- | --- | --- | --- |
| 521 | 200 | **8m21s** | `/clear` dropped the history, but the prompt is still **~19.5k tokens** (tool schemas dominate). Cache covered only ~6k; **~13.4k reprocessed** @ 27.6 tok/s → tool call. |
| 548 | 200 | 40.1s | Immediate continuation: tool result fed back (95 tokens) → final answer (65 tokens). Cache matched almost everything. |

`/clear` kept this run **under** the 10-min ceiling (8m21s vs the 10m0s timeout above) by removing
history — but it is **not faster**: 8m21s ≈ the cold "Hello" turn. The behaviours below explain why.

**Key behaviours this reveals:**

- The Copilot CLI **automatically retries** when the provider returns a 500 / times out, and a
  **timed-out attempt still warms Ollama's cache**, so the retry usually succeeds quickly.
- **The baseline agent prompt is ~19–20k tokens even with zero history** — the **tool schemas**,
  not the conversation, dominate. `/clear` removes only history, so it does **not** cut this cost.
- **The cache covers only ~⅓ of the prompt (~6–9k tokens).** The CLI injects a **per-request
  dynamic block (date/time, session, cwd) early** in the prompt; a fresh timestamp invalidates the
  cache for **everything after it — including all the tool schemas (~13k tokens)**, which are then
  reprocessed on **every new user message**.
- **Fast turns happen only on an _immediate continuation_** (the tool-loop follow-up at 40s, or the
  auto-retry at 46s) — the timestamp didn't change, so the cache matched. Any new user message pays
  the full ~13k reprocess (~8 min on CPU).
- **`/clear` avoids _timeouts_, not _latency_.** Use it to keep long sessions under the 10-min
  ceiling — but expect ~8 min per fresh turn regardless.
- **Pure-chat prompts are comfortable; tool/agentic prompts are slow on CPU.** A **GPU** is the only
  thing that makes fresh turns fast (the ~13k reprocess drops to seconds).

What helps:

- **Use a GPU.** This is the single biggest win. On an NVIDIA host, uncomment the `deploy`
  GPU block in `docker-compose.yml` (requires the NVIDIA Container Toolkit) and recreate
  the container. Expect an order-of-magnitude speedup.
- **Keep the model warm.** `OLLAMA_KEEP_ALIVE=30m` (set in compose) keeps weights resident
  between calls.
- **Prompt caching is limited.** Ollama caches a prefix, but the CLI's **per-request timestamp sits
  early** in the prompt, so a fresh user message reprocesses ~13k tokens regardless. Only
  _immediate continuations_ (tool-loop steps, auto-retries) are near-instant (see *Measured run*).
- **`/clear` to dodge timeouts, not for speed.** On a long session, `/clear` drops history so a turn
  stays under the 10-min ceiling — but it does **not** make turns faster (~8 min per fresh turn).
- **Smaller model = faster prompt processing** (at some quality/tool-calling cost), e.g.
  `./Start-CopilotWithDocker.ps1 -Model llama3.2:3b` — verify its tool calls first (see above).
- **Lower context** (`-ContextLength`) reduces KV-cache RAM but not the prompt size.

The Docker VM is allocated ~16 GB RAM (half of 32 GB) by default; an 8B Q4 model needs
~9–10 GB resident. Raise WSL2's memory in `%UserProfile%\.wslconfig` if needed.

> **Deep dive:** for the full model configuration, an annotated guide to the Ollama runtime
> logs, and exactly when the prompt cache is reused vs. cleared (with measured proof), see
> [`MODEL-LOGS-AND-CACHE.md`](./MODEL-LOGS-AND-CACHE.md).
>
> **Watch it live:** run `./Start-Observability.ps1` (separate terminal) for a provisioned
> **Grafana** dashboard at **http://localhost:3000** that shows each request, its token size,
> cache hit/miss, live KV-cache occupancy and throughput — all parsed from these logs.
> See [`DASHBOARD.md`](./DASHBOARD.md).

## Configuration reference

| Env var | Value used here | Notes |
| --- | --- | --- |
| `COPILOT_PROVIDER_TYPE` | `openai` | Ollama speaks the OpenAI Chat Completions API. |
| `COPILOT_PROVIDER_BASE_URL` | `http://localhost:11434/v1` | **The `/v1` suffix is required** — the CLI does not add it. |
| `COPILOT_PROVIDER_API_KEY` | `ollama` | Dummy; local Ollama needs no auth. |
| `COPILOT_MODEL` | `llama3.2:3b` | Must match a served id (`/v1/models`). Also settable via `--model`. |
| `COPILOT_OFFLINE` | `true` | Stops the CLI contacting GitHub's servers. |

`docker-compose.yml` knobs: `OLLAMA_CONTEXT_LENGTH` (default 32768),
`OLLAMA_KEEP_ALIVE` (default 30m), the pinned image tag, and the commented GPU block.

## Troubleshooting

- **`Docker daemon is not running`** — start Docker Desktop (the wrapper tries to start it
  and waits up to 180s). Confirm with `docker info`.
- **`Model '<name>' not found ... (HTTP 404)`** — your `COPILOT_PROVIDER_BASE_URL` is
  missing the **`/v1`** suffix, or `COPILOT_MODEL` doesn't match a served id. Check
  `Invoke-RestMethod http://localhost:11434/v1/models`.
- **Model is not in the volume and Offline mode is on** — run the one-time online step:
  `./Start-CopilotWithDocker.ps1 -Pull`.
- **The agent ignores tools / replies with raw JSON** — the model isn't returning structured
  `tool_calls`. Use `llama3.2:3b` (or `llama3.1:8b` on a GPU) and avoid `qwen2.5-coder:7b`
  (see *Choosing a model*).
- **First response takes minutes** — expected on CPU (see *Performance*). Wait for the cold
  turn, keep the model warm, or use a GPU / smaller model.
- **Inspect what the CLI sent** — `docker logs ollama --tail 40` shows requests and
  `prompt processing` timings; `docker exec ollama ollama ps` shows the loaded model.

## Airgap notes & limitations

- **Offline only guarantees isolation if the provider is also local.** Here the provider is
  `http://localhost:11434`, so prompts and code context stay on-device. If you point
  `COPILOT_PROVIDER_BASE_URL` at a remote endpoint, your data leaves the machine.
- **Reproducibility:** the image is pinned (`ollama/ollama:0.30.10`) and the model lives in
  the `ollama` named volume, so behavior is stable across restarts once provisioned.
- **No GitHub sign-in required:** the CLI help confirms `COPILOT_OFFLINE=true` disables
  GitHub authentication, telemetry, web tools, the GitHub MCP server, and auto-update; a
  BYOK provider needs no GitHub login. Only the one-time image/model pull needs network.
- **Out of scope here:** moving the setup to a *fully disconnected* host (would need
  `docker save` of the image + an export of the model volume), the optional MCP/SearXNG
  search path, and GPU acceleration (no GPU on this machine).

## Useful commands

```powershell
docker compose up -d            # start Ollama
docker compose ps               # status / health
docker exec ollama ollama list  # models in the volume
docker compose down             # stop (keeps the volume/models)
docker compose down -v          # stop AND delete models (re-pull needed)
```
