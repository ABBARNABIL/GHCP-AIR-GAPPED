# Model Internals: Config, Logs & Prompt Cache

A deep dive into the local model used by the offline Copilot CLI setup — its **full
configuration**, **how to read the Ollama runtime logs**, and **exactly when the prompt cache
is reused vs. cleared** (including what `/clear` in the CLI really does).

Everything here is captured from the **actual running container** on this host
(`ollama/ollama:0.30.10`, model `llama3.2:3b`, CPU-only). Companion docs:
[`README.md`](./README.md) (setup) and [`ENTERPRISE-SETUP.md`](./ENTERPRISE-SETUP.md) (scale-out).

---

## 1. Model configuration (`llama3.2:3b`)

From `ollama show llama3.2:3b` and `POST /api/show`:

| Property | Value | Meaning |
| --- | --- | --- |
| Architecture | `llama` | Llama 3.2 family |
| Parameters | **3.2 B** | Small model — fast on CPU, lower agentic reliability |
| Quantization | **Q4_K_M** | 4-bit weights (k-quant medium) → ~2 GB on disk |
| Trained context length | **131072** (128k) | The model's maximum |
| **Runtime context (`n_ctx`)** | **32768** (32k) | Capped by `OLLAMA_CONTEXT_LENGTH` (see §2) |
| Embedding length | 3072 | Hidden size |
| Layers (`block_count`) | 28 | Transformer blocks |
| Attention heads | **24 query / 8 KV** | Grouped-Query Attention (GQA) — 8 KV heads shrink the KV cache |
| Head dimension | 128 | 3072 / 24 |
| RoPE freq base | 500000 | Rotary position encoding base (long-context tuned) |
| Vocab size | 128256 | Token vocabulary |
| Capabilities | `completion`, **`tools`** | Tool-calling is what the agentic CLI needs |
| Stop tokens | `<|start_header_id|>`, `<|end_header_id|>`, `<|eot_id|>` | Llama 3 header/end markers |
| Loaded size (resident) | **~6.3 GB** | Weights (~2 GB) + KV cache (3.5 GB) + compute buffers |
| `size_vram` | **0** | **100% CPU** — nothing on GPU on this host |

### Tool-calling format (from the Modelfile template)

The model is **not** natively trained to emit OpenAI `tool_calls`. Ollama's template bridges this:
when tools are present, it injects this instruction before your message —

```
Given the following functions, please respond with a JSON for a function call with its
proper arguments that best answers the given prompt.

Respond in the format {"name": function name, "parameters": dictionary of argument name
and its value}. Do not use variables.
```

The model replies with that JSON; **Ollama parses it back into a structured `tool_calls`
array** for the OpenAI-compatible response. (This is why `llama3.2:3b` works with the agent but
`qwen2.5-coder:7b` does not — see `README.md`: qwen emits the JSON as plain text that Ollama
doesn't parse.)

---

## 2. Runtime / server configuration

Set in [`docker-compose.yml`](./docker-compose.yml) (`environment:` block):

| Env var | Value | Effect |
| --- | --- | --- |
| `OLLAMA_HOST` | `0.0.0.0:11434` | Binds the API to the published port |
| `OLLAMA_CONTEXT_LENGTH` | **`32768`** | Per-slot context window (`n_ctx`). Caps the 128k-capable model at 32k to bound KV-cache RAM |
| `OLLAMA_KEEP_ALIVE` | **`30m`** | How long the model stays resident **after the last request** before unloading |

### KV-cache memory math (why 32k context costs 3.5 GB)

From the load log: `llama_kv_cache: CPU KV buffer size = 3584.00 MiB`. That is:

```
2 (K and V) × 28 layers × 32768 ctx × 8 KV heads × 128 head_dim × 2 bytes (f16)
  = 3,758,096,384 bytes = 3584 MiB
```

So **raising `OLLAMA_CONTEXT_LENGTH` linearly raises RAM**; halving it to 16k saves ~1.8 GB but
also caps how much history/code fits. 32k is the chosen balance on this 16 GB-VM host.

---

## 3. Reading the Ollama logs (`docker logs -f ollama`)

There are **two families** of log lines: HTTP access lines and llama-runtime slot lines.

### 3a. HTTP access lines (`[GIN]`)

```
[GIN] 2026/06/20 - 19:31:08 | 200 |         9m44s |      172.19.0.1 | POST "/v1/chat/completions"
        └ timestamp            └ HTTP  └ duration     └ client IP        └ method + path
                                 status
```

| Field | Notes |
| --- | --- |
| **status** | `200` OK · `500` server error (**this is what a 10-minute timeout shows up as**) · `404` model/path not found |
| **duration** | Wall-clock for the whole request. A value of exactly `10m0s` = the **fixed request timeout** was hit |
| **client IP** | `127.0.0.1` = health checks from inside the container; `172.19.0.x` = the Copilot CLI on the Docker bridge |
| **path** | `/v1/chat/completions` = a model turn · `/v1/models` = model list · `/api/tags` = health · `/api/ps` = running state |

### 3b. Slot lifecycle lines (the llama runtime)

A "slot" is one inference context. With the default single slot, all requests share `id 0`.

**On model load:**
```
llama_context: n_ctx_seq (32768) < n_ctx_train (131072) -- the full capacity ... will not be utilized
llama_kv_cache: CPU KV buffer size =  3584.00 MiB
slot load_model: id  0 | task -1 | new slot, n_ctx = 32768
srv  llama_server: model loaded
```
- `n_ctx_seq (32768) < n_ctx_train (131072)` — **informational, not an error**: you've capped the
  32k window below the model's 128k maximum (by design).

**On every request (the most important line):**
```
slot update_slots: id 0 | task 521 | new prompt, n_ctx_slot = 32768, n_keep = 4, task.n_tokens = 19357
                          └ task id              └ window size    └ tokens always    └ TOTAL tokens in
                                                                    kept on shift       THIS prompt
```
- **`task.n_tokens`** = the full size of the prompt the CLI sent for this turn. This is the single
  best number to watch — see the real values in §4.
- **`n_keep = 4`** = when the conversation overflows `n_ctx_slot`, the first 4 tokens (BOS + header)
  are preserved while older middle tokens are evicted.

**During prompt processing (prefill — the slow part on CPU):**
```
slot print_timing: id 0 | task 521 | prompt processing, n_tokens = 5120, progress = 0.57, t = 101.94 s / 50.22 tokens per second
                                                          └ processed   └ fraction   └ elapsed   └ throughput
                                                            so far         of prompt
```
- `progress` climbs 0→1 as the model **reads** the prompt. If it starts at, say, `0.36` instead of
  `0.00`, that jump is the **cache hit** — those tokens were restored instantly (see §4).
- `tokens per second` here is **prefill speed** (reading), which dominates cost on CPU.

**On completion (two summary lines):**
```
slot print_timing: id 0 | task 521 | prompt eval time = 485235.78 ms / 13391 tokens ( ... 27.60 tokens per second)
slot print_timing: id 0 | task 521 |        eval time =  15941.85 ms /    13 tokens (  ...  0.82 tokens per second)
```
- **`prompt eval`** = reading the input. `13391 tokens` here = how many were **actually processed**
  (the rest were served from cache). `27.6 tok/s` is the CPU prefill rate.
- **`eval time`** = **generating** the answer. `13 tokens` = the model's output (e.g., a tool call).
  Generation is far fewer tokens but ~1 s/token on CPU.

**Cache-related lines you may see:**
```
slot update_slots: id 0 | task 179 | cached n_tokens = 3087, memory_seq_rm [3087, end)
```
- `cached n_tokens = N` — N tokens of prefix were reused from the previous turn.
- `memory_seq_rm [N, end)` — everything from position N onward was **dropped** (cache invalidated
  from the first divergence) and will be reprocessed.

### 3c. Field glossary

| Field | Meaning |
| --- | --- |
| `n_ctx` / `n_ctx_slot` | The context window for the slot (32768 here) |
| `task.n_tokens` | Total tokens in the prompt for this turn |
| `n_tokens` (timing) | Tokens processed **so far** in the current prefill |
| `progress` | Fraction of the prompt prefilled (0→1) |
| `n_keep` | Tokens preserved at the front when the window overflows (4) |
| `prompt eval` | Reading/ingesting the prompt (prefill) |
| `eval` | Generating the response (decode) |
| `cached n_tokens` | Prefix tokens reused from cache |
| `memory_seq_rm [a, b)` | Cache region discarded and slated for reprocessing |

---

## 4. The prompt cache — when it's reused vs. cleared

### 4a. How it works

Ollama (llama.cpp) keeps the **KV cache** of the last prompt in the slot. On the next request it
reuses the **longest matching token prefix**, then reprocesses everything from the **first
differing token** onward. There is **no partial/fuzzy match** — one differing token invalidates
the entire remainder.

### 4b. The catch: a per-request dynamic block breaks the cache early

The Copilot CLI's prompt is structured roughly as:
```
[ system instructions ][ date/time + session + cwd ][ tool schemas ][ conversation ][ your message ]
   stable                 CHANGES every request        stable          grows           new
```
Because a **timestamp/session block changes on every request** and sits **before the big tool
schemas**, the cache match ends there — so **all the tool schemas after it (~13k tokens) are
reprocessed on every new user message**. Only ~⅓ of the prompt (the part before the dynamic block)
is actually reused.

### 4c. Measured proof (real `task.n_tokens` from this session)

| Task | What it was | `task.n_tokens` | Outcome |
| --- | --- | --- | --- |
| 179 | `Hello` (cold, no history) | **19,357** | 9m44s — full prefill, nothing cached |
| 216 | Hello follow-up (continuation) | 7,902 | fast — cache hit |
| 244 | Hello follow-up (continuation) | 9,418 | fast — cache hit |
| 398 | `List files` **+ Hello history** | **22,605** | **500 @ 10m0s** — ~13k reprocessed, timed out |
| 413 | retry of 398 (identical) | 22,605 | 200 in 46.7s — cache fully warm (1-token prefill) |
| 443 | tool result → answer (continuation) | 9,777 | 200 in 1m2s |
| **521** | **`/clear` then `List files`** | **19,357** | 8m21s — **identical size to the cold `Hello` (179)** |
| 548 | tool result → answer (continuation) | 6,424 | 200 in 40s |

**Key reads:**
- Task **521 = 19,357 tokens — byte-for-byte the same total as the cold `Hello` (task 179).** This
  proves **`/clear` resets the prompt to the ~19.4k baseline** (system + tools + env + one short
  message). The model still had to reprocess **13,391** of those tokens (only ~6k cached) → 8m21s.
- Task **398 = 22,605** (= baseline + ~3.2k of `Hello` history). The extra history is what pushed it
  **over** the 10-minute ceiling.
- Tasks **216/244/443/548** are **continuations** (same timestamp, only a small suffix appended) →
  small effective work → fast.

### 4d. What clears / invalidates the cache

Two different layers — don't confuse them:

#### Ollama **KV cache** (server-side)

| Trigger | Effect | Recovery cost |
| --- | --- | --- |
| **New prompt diverges from the cached prefix** (the normal case, via the timestamp block) | Tokens after the divergence are dropped (`memory_seq_rm`) and reprocessed | ~13k tokens (~8 min CPU) |
| **Idle > `OLLAMA_KEEP_ALIVE` (30m)** → model unloads | **Entire cache gone**, model evicted from RAM | Full cold reload + reprocess (~9 min) |
| **Context overflows `n_ctx_slot` (32768)** | Oldest tokens evicted (`n_keep=4` kept), shifting invalidates following cache | Partial reprocess |
| **Different model requested / second slot** | Slot's cache replaced | Cold for the new model |
| **`ollama stop`, container restart, `docker compose down`** | Cache (and loaded model) gone | Full cold reload |

#### Copilot CLI **`/clear`** (client-side) — *different thing*

- `/clear` clears the **CLI's conversation history**, not Ollama's KV cache.
- Effect on the next request: the prompt shrinks back to the **~19.4k baseline** (no history) — but
  it still **diverges from whatever is in the KV cache** (different history + new timestamp), so the
  big tool-schema block is **still reprocessed**.
- **Net:** `/clear` lowers the token *count* (helps you stay under the 10-min timeout) but does
  **not** make a turn fast (task 521 = 8m21s ≈ the cold turn). It is a **timeout-avoidance** tool,
  not a speed-up. See `README.md` → *Performance* for the full discussion.

### 4e. What actually gives a fast turn

| Scenario | Fast? | Why |
| --- | --- | --- |
| Immediate continuation (tool-loop step, auto-retry) | ✅ seconds–<1 min | Same timestamp → cache matches almost everything |
| New user message (with or without `/clear`) | ❌ ~8 min CPU | Timestamp changes → ~13k tool-schema tokens reprocessed |
| Model still within keep-alive, short prompt | ⚠️ partial | Only the pre-timestamp prefix is reused |
| **GPU** | ✅✅ | The ~13k reprocess drops from minutes to **seconds** — the real fix |

### 4f. Measured proof #2 — *warm model, cold cache* (dashboard-captured)

A second run, this time **non-interactive** (`copilot -p "List the files in the current directory."
--allow-all-tools`) with the model already **loaded and warm**, captured live by the
[dashboard](./DASHBOARD.md):

| Task | Role | Sent | Reused | Reproc. | Hit% | Prefill | Gen | HTTP |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| **770** | initial turn | **17,489** | 32 | **17,457** | **~0%** | 8m1s | 21 | `200` 8m19s |
| **809** | tool-result follow-up | 5,775 | 5,609 | 166 | **97%** | 3.1s | 33 | `200` 22.9s |

CLI footer: `Duration 8m44s · ↑23.3k · ↓54`. Reconciles as **770 (8m19s) + 809 (23s) ≈ 8m44s** wall.

**The lesson — "warm model" ≠ "warm cache for *this* prompt":**
- The model was resident (within keep-alive), yet task 770 reused only **32 of 17,489 tokens
  (~0%)** and reprocessed everything → 8m19s. The KV cache held the *previous* turn's content (an
  interactive-style ~19k prompt); this non-interactive prompt has a **different structure**, so the
  shared prefix ended at token 32. A loaded model does **not** guarantee a cache hit — only a
  matching **prefix** does.
- Task **809 then hit 97%** — the immediate agent-loop continuation reused 5,609 tokens, reprocessed
  just 166 → **3.1s prefill**. Same pattern as the continuations in 4c (216/443/548): fast *because*
  it directly extends what was just processed.

**Two side findings:**
- **Non-interactive prompts are leaner:** `copilot -p` sent **17,489** tokens vs the interactive
  TUI's ~19.4k baseline (~2k less session/TUI context).
- **Tool-calling quirk (llama3.2:3b):** the first call (`List directory`, 11 files) parsed correctly,
  but a second call was emitted as **raw text** `{"name":"view","params":{…}}` instead of a parsed
  `tool_call` — the documented limitation (see §1, *Tool-calling format*).

> Reproduce this yourself: run `./Start-Observability.ps1`, then send a prompt and watch task numbers,
> `task.n_tokens`, and the reused/reprocessed split update live in Grafana.

---

## 5. Worked example — the `/clear` test, annotated

Your live `/clear` + `List the files in the current directory.` run, line by line:

```
slot update_slots: ... task 521 | new prompt, n_ctx_slot = 32768, n_keep = 4, task.n_tokens = 19357
   → /clear worked: prompt is back to the 19,357-token baseline (same as the cold Hello).

slot print_timing: ... task 521 | prompt processing, n_tokens = 1024, progress = 0.36, ... 74.01 tok/s
   → progress STARTS at 0.36, not 0.00: ~6k tokens (36%) were restored from cache instantly.
     The remaining ~64% must be reprocessed.

slot print_timing: ... task 521 | prompt processing, n_tokens = 13312, progress = 1.00, ... 27.88 tok/s
   → prefill finished; throughput decayed 74→28 tok/s as the KV cache filled.

slot print_timing: ... task 521 | prompt eval time = 485235 ms / 13391 tokens ( ... 27.60 tok/s)
   → 13,391 tokens were actually processed (19,357 − ~6k cached). 8 min of CPU prefill.

slot print_timing: ... task 521 | eval time = 15941 ms / 13 tokens
   → generated a 13-token TOOL CALL (list the directory).

[GIN] ... | 200 | 8m21s | POST "/v1/chat/completions"
   → turn 1 done in 8m21s (just under the 10-min ceiling).

[GIN] ... | 200 | 40.1s | POST "/v1/chat/completions"   (task 548, n_tokens = 6424)
   → continuation: CLI ran the tool, fed 95 new tokens back; cache matched the rest →
     final answer (65 tokens) in 40s.
```

---

## 6. Cheat sheet

- **Watch `task.n_tokens`** — the prompt size for the turn. ~19.4k = a fresh turn; >22k = history piled up.
- **`progress` starting above 0.00** = cache hit (that fraction was reused).
- **`prompt eval … / N tokens`** = how many were *actually* reprocessed (the real cost).
- **`500 | 10m0s`** = hit the fixed request timeout (reprocess didn't finish in time).
- **`/clear`** = smaller prompt, **not** a faster one; use it to dodge timeouts on long sessions.
- **Warm model ≠ warm cache:** a loaded model still reprocesses everything if the new prompt's
  **prefix** doesn't match what's cached (measured: 0% hit on a warm model — §4f).
- **Keep within 30 min** to avoid a cold model reload; **add a GPU** to make fresh turns actually fast.

Commands used to gather all of the above:
```powershell
docker exec ollama ollama show llama3.2:3b
docker exec ollama ollama show llama3.2:3b --modelfile
Invoke-RestMethod http://localhost:11434/api/show -Method Post -Body '{"model":"llama3.2:3b"}'
Invoke-RestMethod http://localhost:11434/api/ps
docker exec ollama sh -lc "env | grep -i OLLAMA"
docker logs -f ollama          # live runtime/slot logs
```
