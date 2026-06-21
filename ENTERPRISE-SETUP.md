# Enterprise Setup — GitHub Copilot CLI with Self-Hosted Local Models

How to run the GitHub Copilot CLI against **self-hosted local models** for **many developers**
working on **confidential / airgapped projects**.

> This document is the **enterprise / multi-developer** companion to [`README.md`](./README.md).
> The README covers the **single-developer pilot** (Ollama in Docker on one laptop). That setup
> does **not** scale — CPU inference is too slow, every laptop needs the weights + RAM, and there
> is no central governance. At scale you **invert the model: centralize inference on GPU servers,
> put thin clients on laptops, and front everything with an AI gateway.**

---

## TL;DR — pick the right tier

| Tier | Inference location | Hardware | Good for | Reference |
| --- | --- | --- | --- | --- |
| **Pilot** | Each laptop (Ollama) | CPU / small GPU | 1 dev, evaluation | [`README.md`](./README.md) |
| **Team PoC** | 1 shared GPU node + gateway | 1× A100/H100 | One team (~5–30 devs) | This doc |
| **Enterprise** | GPU pool + HA gateway | Multiple GPUs, K8s | Whole org, 100s of devs | This doc |

The Copilot CLI only needs an **OpenAI-compatible `/v1` base URL**. It cannot tell the difference
between `http://localhost:11434/v1` and a shared `https://copilot-ai.corp.internal/v1` gateway —
that is what makes centralizing clean.

---

## Reference architecture (airgapped)

```
┌──────────────────────────────────────────────────────────────────────┐
│  DEVELOPER WORKSTATIONS  (corp network / VPN only — no internet)       │
│                                                                        │
│   Dev A           Dev B           Dev C        … (100s of devs)        │
│   copilot CLI     copilot CLI     copilot CLI                          │
│   OFFLINE=true    OFFLINE=true    OFFLINE=true                         │
│   API_KEY=sk-devA (per-dev virtual key)                                │
│   BASE_URL ───────────┬───────────────┘                               │
└───────────────────────┼─────────────────────────────────────────────-─┘
                        │  HTTPS + mTLS, internal DNS
                        ▼
┌──────────────────────────────────────────────────────────────────────┐
│  AI GATEWAY  (LiteLLM Proxy / Portkey / Kong AI)  ·  HA, 2+ replicas   │
│   • OpenAI-compatible /v1      • per-dev & per-team virtual keys       │
│   • SSO/OIDC authn  + RBAC     • rate limits + budgets                 │
│   • routing & model fallback   • audit log + token metering           │
└───────┬────────────────────────────────────────┬─────────────────────┘
        │  load-balanced                          │
        ▼                                         ▼
┌──────────────────────┐                ┌──────────────────────┐
│  INFERENCE NODE 1    │                │  INFERENCE NODE 2    │  … GPU pool
│  vLLM / TGI / NIM    │                │  vLLM / TGI / NIM    │
│  Qwen2.5-Coder-32B   │                │  Llama-3.3-70B       │
│  A100 / H100 GPUs    │                │  A100 / H100 GPUs    │
└──────────────────────┘                └──────────────────────┘
        │
        ▼
┌──────────────────────────────────────────────────────────────────────┐
│  SUPPORTING SERVICES (all on-prem / private VPC)                       │
│  Private model registry   Prometheus+Grafana   Postgres (keys/usage)  │
│  Secrets vault            SIEM / audit sink     MDM/GPO config push    │
└──────────────────────────────────────────────────────────────────────┘
```

---

## The layers that matter

### 1. Inference serving (GPU tier)

Replace per-laptop Ollama with a shared, **batched** server.

| Option | When to use |
| --- | --- |
| **vLLM** | **Default.** Highest throughput (continuous batching, PagedAttention), native OpenAI `/v1`, tool-calling + streaming. |
| **NVIDIA NIM** | Want vendor support / procurement + pre-tuned containers. |
| **HF TGI / SGLang** | Strong alternatives with good ecosystems. |
| **Triton + TRT-LLM** | Maximum performance, more ops effort. |
| Ollama | Only for small teams or edge nodes. |

One 32B model on a single H100 serves **dozens** of concurrent coding sessions — interactive use is
bursty (devs read between turns), so concurrency ≫ active requests. **Size GPUs by peak concurrent
*active* requests, not by headcount.**

### 2. AI gateway (the control plane)

The most important enterprise piece. Self-host **LiteLLM Proxy** (airgap-friendly) or a commercial
gateway (Portkey, Kong AI Gateway). It provides:

- A single **OpenAI-compatible `/v1`** endpoint for all clients.
- **Per-developer / per-team virtual keys**, revocable and tied to SSO identity.
- **Budgets + rate limits** per key/team (kill switch for a leaver or a runaway loop).
- **Routing + fallback** across multiple model backends.
- **Token metering + audit log** for internal chargeback and compliance.

Developers point at the gateway, **never** directly at a model node.

### 3. Model choice

Must support **tool calling + streaming** (both are required by the agentic CLI). Go big for
reliability:

| Model | Notes |
| --- | --- |
| **Qwen2.5-Coder-32B-Instruct** | Strong coding + tool calling. Great default. |
| **Llama-3.3-70B-Instruct** | Highest general quality; needs more GPU. |
| DeepSeek-Coder-V2 / Codestral / Mistral-Large | Solid alternatives. |

> **Why big models at scale:** small models (3B–8B) degrade badly under the CLI's ~17k-token agent
> prompt — see the *Performance* notes in [`README.md`](./README.md). Centralized GPUs let you run
> the large, reliable models that actually drive the agent loop well, while still serving everyone.

### 4. Client configuration distribution

Don't have developers hand-edit env vars. Push config centrally:

- **Windows:** Group Policy / Intune sets the machine-wide vars below; inject the per-dev
  `COPILOT_PROVIDER_API_KEY` at login (e.g. from the gateway via a login script).
- **macOS / Linux:** Jamf / Ansible / managed shell profile.
- **Wrapper script:** evolve [`Start-CopilotWithDocker.ps1`](./Start-CopilotWithDocker.ps1) to point at
  the gateway instead of `localhost`, and ship it via your internal package repo (Artifactory/Nexus).
- **Golden images / dev containers:** bake the config in.

`COPILOT_OFFLINE=true` everywhere → no telemetry, no GitHub egress, no auto-update calls.

### 5. Security for confidential code

- **Airgapped / private VPC:** workstations reach only the internal gateway; **zero internet egress**
  for inference.
- **mTLS or VPN** client → gateway; TLS terminates at the gateway.
- **Per-dev virtual keys** (revocable), mapped to SSO identity; secrets in **Vault / Key Vault**.
- **⚠️ Prompt-logging caution:** prompts contain your **source code**. Any prompt log is as sensitive
  as the repos themselves — encrypt it, keep retention short, restrict access, **or log metadata only**
  (tokens/latency, not content).
- **Air-gapped weights:** download model weights **once** in a DMZ, scan them, then move into the
  **private registry**. No runtime calls to Hugging Face.

### 6. Cost (self-hosted economics)

- Self-hosting means **no per-token vendor bill** — cost is **GPU CapEx/OpEx**.
- The gateway's **token metering** gives per-team accounting for chargeback and right-sizing.
- Frame cost as **GPU-hours + token throughput**, not per-request multipliers.
- Use **quantization** (FP8 / AWQ / GPTQ) to raise throughput per GPU and fit bigger models.

### 7. High availability & operations

- **2+ gateway replicas** behind an internal load balancer.
- **2+ inference nodes**; gateway-level **fallback model** if one backend is down.
- **Rolling model updates**, health checks, GPU autoscaling.
- Platform: **Kubernetes + NVIDIA GPU Operator** is typical (Docker Compose is fine for a pilot).

---

## Capacity & sizing guidance

| Factor | Rule of thumb |
| --- | --- |
| GPU count | Driven by **peak concurrent active requests**, not headcount. 200 devs ≈ 10–30 concurrent at peak. |
| Model footprint | 32B @ FP16 ≈ ~64 GB → fits 1× H100 (80 GB) or 2× A100 (40 GB) with tensor-parallel. Quantize to fit more. |
| Context length | The Copilot agent prompt is ~17k tokens; set `--max-model-len` to **≥ 32768**. |
| Throughput | Prompt processing dominates; GPUs do the ~17k-token prefill in **seconds** vs **minutes** on CPU — GPU is mandatory for acceptable UX at scale. |

---

## Example configs

> Illustrative starting points — adapt names, hosts, and secrets to your environment.

### a) Inference node — vLLM (OpenAI-compatible, tool calling on)

```bash
vllm serve Qwen/Qwen2.5-Coder-32B-Instruct \
  --served-model-name qwen2.5-coder-32b \
  --enable-auto-tool-choice \
  --tool-call-parser hermes \
  --max-model-len 32768 \
  --tensor-parallel-size 2 \
  --api-key "$VLLM_NODE_KEY" \
  --port 8000
```

> The `--tool-call-parser` depends on the model family (`hermes` for Qwen, `llama3_json`/`pythonic`
> for Llama 3.x). Confirm against the vLLM docs for your chosen model.

### b) AI gateway — LiteLLM `config.yaml`

```yaml
model_list:
  - model_name: qwen2.5-coder-32b          # what clients request as COPILOT_MODEL
    litellm_params:
      model: openai/qwen2.5-coder-32b
      api_base: http://vllm-node-1:8000/v1
      api_key: os.environ/VLLM_NODE_KEY
  - model_name: llama-3.3-70b
    litellm_params:
      model: openai/llama-3.3-70b
      api_base: http://vllm-node-2:8000/v1
      api_key: os.environ/VLLM_NODE_KEY

litellm_settings:
  num_retries: 2
  request_timeout: 600          # seconds; large prompts on busy GPUs

general_settings:
  master_key: os.environ/LITELLM_MASTER_KEY
  database_url: os.environ/DATABASE_URL    # Postgres: virtual keys + usage tracking
```

### c) Gateway PoC — `docker-compose.yml` (gateway + Postgres)

```yaml
services:
  litellm:
    image: ghcr.io/berriai/litellm:main-stable
    command: ["--config", "/app/config.yaml", "--port", "4000"]
    ports: ["4000:4000"]
    volumes:
      - ./config.yaml:/app/config.yaml:ro
    environment:
      - LITELLM_MASTER_KEY=${LITELLM_MASTER_KEY}
      - DATABASE_URL=${DATABASE_URL}
      - VLLM_NODE_KEY=${VLLM_NODE_KEY}
    depends_on: [db]
  db:
    image: postgres:16
    environment:
      - POSTGRES_USER=litellm
      - POSTGRES_PASSWORD=${PGPASSWORD}
      - POSTGRES_DB=litellm
    volumes: ["litellm-db:/var/lib/postgresql/data"]
volumes:
  litellm-db:
```

### d) Issue a per-developer virtual key

```bash
curl -X POST https://copilot-ai.corp.internal/key/generate \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"models":["qwen2.5-coder-32b"],"user_id":"dev-a","max_budget":50}'
# → returns {"key":"sk-litellm-devA..."}
```

### e) Client — env vars pushed to each workstation

```powershell
# Windows: set machine-wide via Intune / GPO; inject API key at login.
$env:COPILOT_PROVIDER_TYPE     = "openai"
$env:COPILOT_PROVIDER_BASE_URL = "https://copilot-ai.corp.internal/v1"  # /v1 is required
$env:COPILOT_PROVIDER_API_KEY  = "sk-litellm-devA..."                   # per-dev virtual key
$env:COPILOT_MODEL             = "qwen2.5-coder-32b"
$env:COPILOT_OFFLINE           = "true"
copilot
```

> **The `/v1` suffix is required** on the base URL — the CLI does not add it (same finding as the
> single-dev setup in [`README.md`](./README.md)).

---

## Rollout path

1. **Pilot** — single dev, local Ollama ([`README.md`](./README.md)).
2. **Team PoC** — 1 GPU node (vLLM) + LiteLLM gateway (compose above), one team.
3. **Enterprise** — GPU pool + HA gateway + MDM/GPO config push + audit/governance on Kubernetes.

---

## Security & compliance checklist

- [ ] Workstations have **no internet egress** for inference; gateway is the only reachable endpoint.
- [ ] **mTLS / VPN** between clients and gateway; TLS certs managed and rotated.
- [ ] **Per-dev virtual keys** tied to SSO; revoked on offboarding.
- [ ] **Budgets + rate limits** per key/team configured.
- [ ] Prompt content logging **disabled** or encrypted with short retention + restricted access.
- [ ] Model weights acquired in a **DMZ**, scanned, stored in a **private registry**.
- [ ] Gateway + inference run in a **private VPC / on-prem**; no third-party AI APIs.
- [ ] `COPILOT_OFFLINE=true` enforced on every client (no telemetry/GitHub/auto-update).
- [ ] Observability (Prometheus/Grafana) + audit sink (SIEM) wired up.
- [ ] **Copilot licensing/terms** for multi-seat BYOK + offline use confirmed with GitHub.

> ⚠️ The last item is a **terms** question, not an architecture one — confirm that BYOK + offline mode
> is licensed for your organization's multi-seat use before a wide rollout.

---

## Related files in this repo

- [`README.md`](./README.md) — single-developer pilot (Ollama in Docker, CPU/GPU).
- [`docker-compose.yml`](./docker-compose.yml) — the pilot Ollama backend.
- [`Start-CopilotWithDocker.ps1`](./Start-CopilotWithDocker.ps1) — the pilot wrapper (adapt to point at the gateway for enterprise).
- [`Start-CopilotWithFoundryLocal.ps1`](./Start-CopilotWithFoundryLocal.ps1) — Foundry Local variant.
