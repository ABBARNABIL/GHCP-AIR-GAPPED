#!/usr/bin/env bash
#
# model-test-campaign.sh
# ----------------------------------------------------------------------------
# Automated test campaign for local models behind the GitHub Copilot CLI
# (offline / airgapped, Dockerized Ollama on this arm64 host).
#
# For each model it measures the things that actually decide whether the
# agentic CLI works, then writes a Markdown report:
#
#   1. Pull            - downloads into the Ollama volume (timed).
#   2. tool_calls      - does it return STRUCTURED tool_calls (not plain text)?
#                        This is the hard requirement for the agent loop.
#   3. streaming       - does the OpenAI stream carry finish_reason?
#                        (Copilot's stream parser needs it.)
#   4. instruction     - does it obey a trivial deterministic instruction?
#   5. throughput      - prompt-eval and generation tok/s (Ollama timings).
#   6. projection      - estimated time for one real agent turn (~13.4k-token
#                        prompt) and whether it fits the CLI's ~10-min timeout.
#   7. --full (opt)    - actually drives `copilot -p ...` once and times it.
#
# Usage:
#   ./model-test-campaign.sh                                  # default model set
#   ./model-test-campaign.sh --models "llama3.2:3b mistral:7b"
#   ./model-test-campaign.sh --full                           # also run real Copilot turns (slow)
#   ./model-test-campaign.sh --out TEST-RESULTS.md
#   ./model-test-campaign.sh --keep-going                     # don't stop if one model fails to pull
#
# Requires: docker (running `ollama` container), curl, jq, and (for --full) copilot.
# ----------------------------------------------------------------------------
set -uo pipefail

# ---- config / defaults -----------------------------------------------------
PORT=11434
CONTAINER="ollama"
OUT="TEST-RESULTS.md"
FULL=0
KEEP_GOING=0
AGENT_TOK=13400          # measured agent system-prompt size from a real Copilot turn
TIMEOUT_BUDGET=600       # CLI request timeout (~10 min) used for the verdict
TURN_FACTOR=3.2          # empirical: a real multi-step agent turn ~= this x one forward pass
                         # (calibrated from mistral:7b -- 1-pass 4m14s vs measured 13m35s)

# Default campaign: a deliberate spread of families / sizes / specializations.
DEFAULT_MODELS=(
    "llama3.2:1b"        # tiny general, structured tools  -> fast baseline
    "llama3.2:3b"        # small general, structured tools -> repo default
    "qwen2.5-coder:7b"   # coder, emits tool calls as TEXT -> expected failure
    "mistral:7b"         # mid general, structured tools   -> slow on CPU
)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OLLAMA_URL="http://localhost:${PORT}"

c_cyan()  { printf '\033[36m%s\033[0m\n' "$*"; }
c_green() { printf '\033[32m%s\033[0m\n' "$*"; }
c_yellow(){ printf '\033[33m%s\033[0m\n' "$*"; }
c_red()   { printf '\033[31m%s\033[0m\n' "$*" >&2; }
die() { c_red "ERROR: $*"; exit 1; }

# ---- arg parsing -----------------------------------------------------------
MODELS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --models)    read -r -a MODELS <<< "$2"; shift 2 ;;
        --full)      FULL=1; shift ;;
        --out)       OUT="$2"; shift 2 ;;
        --port)      PORT="$2"; OLLAMA_URL="http://localhost:${PORT}"; shift 2 ;;
        --keep-going) KEEP_GOING=1; shift ;;
        -h|--help)   sed -n '2,33p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "Unknown option: $1 (try --help)" ;;
    esac
done
[[ ${#MODELS[@]} -eq 0 ]] && MODELS=("${DEFAULT_MODELS[@]}")
[[ "$OUT" != /* ]] && OUT="${SCRIPT_DIR}/${OUT}"

# ---- preflight -------------------------------------------------------------
for c in docker curl jq; do command -v "$c" >/dev/null 2>&1 || die "'$c' is required."; done
docker ps --filter "name=${CONTAINER}" --format '{{.Names}}' | grep -qx "$CONTAINER" \
    || die "Container '${CONTAINER}' is not running. Start it: ./start-copilot-with-docker.sh --no-launch"
curl -fsS --max-time 5 "${OLLAMA_URL}/api/version" >/dev/null 2>&1 \
    || die "Ollama endpoint ${OLLAMA_URL} not responding."
[[ $FULL -eq 1 ]] && { command -v copilot >/dev/null 2>&1 || die "--full needs the copilot CLI."; }

TMP="$(mktemp -d)"
RESULTS="${TMP}/results.psv"   # pipe-separated rows
trap 'rm -rf "$TMP"' EXIT

# ---- helpers ---------------------------------------------------------------
# Clean a model reply for embedding in a single-cell note: strip newlines/pipes, truncate.
sanitize() { tr '\n' ' ' | tr -d '|' | sed -E 's/  +/ /g; s/^ +//; s/ +$//' | cut -c1-120; }

# Probe 1: structured tool_calls via the OpenAI-compatible route.
test_tool_calls() {
    local model="$1" payload resp tc content
    payload="$(jq -n --arg m "$model" '{
        model:$m, stream:false,
        messages:[{role:"user", content:"What is the weather in Paris? Use the tool."}],
        tools:[{type:"function", function:{name:"get_weather",
                description:"Get weather for a city",
                parameters:{type:"object", properties:{city:{type:"string"}}, required:["city"]}}}]
    }')"
    resp="$(curl -fsS --max-time 120 "${OLLAMA_URL}/v1/chat/completions" \
            -H 'Content-Type: application/json' -d "$payload" 2>/dev/null)"
    tc="$(printf '%s' "$resp" | jq -r '.choices[0].message.tool_calls // [] | length' 2>/dev/null || echo 0)"
    content="$(printf '%s' "$resp" | jq -r '.choices[0].message.content // ""' 2>/dev/null)"
    if [[ "${tc:-0}" -gt 0 ]]; then
        echo "PASS|structured tool_calls (n=${tc})"
    elif printf '%s' "$content" | grep -qiE '"?name"?\s*[:=].*get_weather|get_weather\(|"arguments"'; then
        echo "FAIL|emits tool call as TEXT in content (agent loop cannot parse): $(printf '%s' "$content" | sanitize)"
    else
        echo "FAIL|no tool_calls and no recognizable call: $(printf '%s' "$content" | sanitize)"
    fi
}

# Probe 2: streaming finish_reason present?
test_streaming() {
    local model="$1" payload
    payload="$(jq -n --arg m "$model" '{
        model:$m, stream:true,
        messages:[{role:"user", content:"Say hi in one word."}]
    }')"
    if curl -fsS -N --max-time 60 "${OLLAMA_URL}/v1/chat/completions" \
            -H 'Content-Type: application/json' -d "$payload" 2>/dev/null \
            | grep -qE '"finish_reason"\s*:\s*"(stop|length|tool_calls)"'; then
        echo "PASS|finish_reason present"
    else
        echo "FAIL|no finish_reason in stream (would break Copilot stream parser)"
    fi
}

# Probe 3: trivial instruction following.
test_instruction() {
    local model="$1" payload resp content
    payload="$(jq -n --arg m "$model" '{
        model:$m, stream:false,
        messages:[{role:"user", content:"Reply with exactly the single word PONG and nothing else."}]
    }')"
    resp="$(curl -fsS --max-time 120 "${OLLAMA_URL}/v1/chat/completions" \
            -H 'Content-Type: application/json' -d "$payload" 2>/dev/null)"
    content="$(printf '%s' "$resp" | jq -r '.choices[0].message.content // ""' 2>/dev/null)"
    if printf '%s' "$content" | grep -qiE '^[^a-z0-9]*pong[^a-z0-9]*$'; then
        echo "PASS|exact: $(printf '%s' "$content" | sanitize)"
    elif printf '%s' "$content" | grep -qi 'pong'; then
        echo "PARTIAL|contains PONG but added text: $(printf '%s' "$content" | sanitize)"
    else
        echo "FAIL|did not say PONG: $(printf '%s' "$content" | sanitize)"
    fi
}

# Probe 4: throughput (native /api/chat returns nanosecond timings).
# Warm the model first, then measure a ~1.8k-token prompt with bounded output.
test_throughput() {
    local model="$1" big warm resp pc pd ec ed
    big="$(yes 'the quick brown fox jumps over the lazy dog and then keeps running' | head -n 180 | tr '\n' ' ')"
    big="probe-$RANDOM $big"   # nonce defeats prefix caching
    warm="$(jq -n --arg m "$model" '{model:$m,stream:false,messages:[{role:"user",content:"hi"}],options:{num_predict:1}}')"
    curl -fsS --max-time 300 "${OLLAMA_URL}/api/chat" -d "$warm" >/dev/null 2>&1
    resp="$(curl -fsS --max-time 300 "${OLLAMA_URL}/api/chat" \
            -d "$(jq -n --arg m "$model" --arg c "$big" '{model:$m,stream:false,messages:[{role:"user",content:$c}],options:{num_predict:64}}')" 2>/dev/null)"
    read -r pc pd ec ed < <(printf '%s' "$resp" \
        | jq -r '[.prompt_eval_count//0, .prompt_eval_duration//0, .eval_count//0, .eval_duration//0] | @tsv' 2>/dev/null)
    awk -v pc="${pc:-0}" -v pd="${pd:-0}" -v ec="${ec:-0}" -v ed="${ed:-0}" \
        -v at="$AGENT_TOK" -v tf="$TURN_FACTOR" 'BEGIN{
        pr = (pd>0)? pc/(pd/1e9) : 0;
        gr = (ed>0)? ec/(ed/1e9) : 0;
        onepass = (pr>0 && gr>0)? at/pr + 300/gr : 0;   # one forward pass of the agent prompt
        real    = onepass * tf;                          # est. real multi-step turn
        printf "%.1f|%.1f|%.0f|%.0f", pr, gr, onepass, real;
    }'
}

# Optional: drive a real Copilot turn and time it.
test_full_turn() {
    local model="$1" start end dur out rc
    start=$(date +%s)
    out="$(COPILOT_PROVIDER_TYPE=openai COPILOT_PROVIDER_BASE_URL="${OLLAMA_URL}/v1" \
           COPILOT_PROVIDER_API_KEY=ollama COPILOT_MODEL="$model" COPILOT_OFFLINE=true \
           timeout 900 copilot -p "Reply with exactly the single word PONG." --allow-all-tools 2>&1)"
    rc=$?
    end=$(date +%s); dur=$((end-start))
    if [[ $rc -eq 124 ]]; then echo "${dur}|TIMEOUT (>900s)"
    elif printf '%s' "$out" | grep -qi 'pong'; then echo "${dur}|ok (said PONG)"
    else echo "${dur}|completed but off-task"; fi
}

verdict() {
    local tool="$1" real="$2"
    if [[ "$tool" == FAIL ]]; then echo "Unsupported — no structured tool calls"; return; fi
    if [[ "$real" -eq 0 ]]; then echo "Unknown (no timing)"; return; fi
    if   [[ "$real" -le 360 ]]; then echo "Good — interactive"
    elif [[ "$real" -le "$TIMEOUT_BUDGET" ]]; then echo "Usable — slow"
    else echo "Too slow on CPU — exceeds ~10-min timeout"; fi
}

fmt_mmss() { printf '%dm%02ds' $(( $1/60 )) $(( $1%60 )); }

# ---- run the campaign ------------------------------------------------------
c_cyan "=== Model test campaign — ${#MODELS[@]} model(s) ==="
i=0
for model in "${MODELS[@]}"; do
    i=$((i+1))
    c_cyan ">>> [${i}/${#MODELS[@]}] ${model}"

    c_yellow "    pulling..."
    if ! docker exec "$CONTAINER" ollama pull "$model" >/dev/null 2>&1; then
        c_red "    pull failed for ${model}"
        printf '%s|?|FAIL|N/A|N/A|0|0|0|0|Pull failed|could not download\n' "$model" >> "$RESULTS"
        [[ $KEEP_GOING -eq 1 ]] && continue || die "Pull failed for ${model} (use --keep-going to skip)."
    fi
    size="$(docker exec "$CONTAINER" ollama list 2>/dev/null | awk -v m="$model" '$1==m{print $3" "$4}')"

    c_yellow "    tool_calls..."   ; IFS='|' read -r tool tool_note   <<< "$(test_tool_calls "$model")"
    c_yellow "    streaming..."    ; IFS='|' read -r strm strm_note   <<< "$(test_streaming "$model")"
    c_yellow "    instruction..."  ; IFS='|' read -r instr instr_note <<< "$(test_instruction "$model")"
    c_yellow "    throughput..."   ; IFS='|' read -r prate grate proj real <<< "$(test_throughput "$model")"

    vdt="$(verdict "$tool" "${real:-0}")"
    full_field="not run"
    if [[ $FULL -eq 1 && "$tool" == PASS ]]; then
        c_yellow "    full Copilot turn (can take minutes)..."
        IFS='|' read -r fdur fnote <<< "$(test_full_turn "$model")"
        full_field="$(fmt_mmss "$fdur") — ${fnote}"
    fi

    note="tools: ${tool_note}; instr: ${instr_note}; stream: ${strm_note}"
    printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
        "$model" "${size:-?}" "$tool" "$strm" "$instr" "${prate:-0}" "${grate:-0}" "${proj:-0}" "${real:-0}" "$vdt" "$note" >> "$RESULTS"
    [[ "$full_field" != "not run" ]] && echo "$model|$full_field" >> "${TMP}/full.psv"

    c_green "    -> tool_calls:${tool}  stream:${strm}  instr:${instr}  prompt:${prate:-0}t/s  gen:${grate:-0}t/s  1pass:$(fmt_mmss "${proj:-0}")  realTurn:$(fmt_mmss "${real:-0}")  verdict:${vdt}"
done

# ---- render the Markdown report -------------------------------------------
c_cyan "=== Writing ${OUT} ==="
host_arch="$(uname -m)"; host_cores="$(nproc)"
host_ram="$(free -h 2>/dev/null | awk '/^Mem:/{print $2}')"
host_gpu="$(command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | paste -sd', ' - || echo 'none')"
_logs="$(docker logs "$CONTAINER" 2>&1)"   # capture once; avoids SIGPIPE under pipefail
if grep -qiE 'name=CUDA|library=CUDA' <<<"$_logs"; then
    accel="GPU — CUDA (container has GPU access)"
elif grep -qiE 'name=ROCm|library=ROCm|name=Metal' <<<"$_logs"; then
    accel="GPU — non-CUDA (container)"
else
    accel="CPU only (container has NO GPU access)"
fi
oll_ver="$(curl -fsS "${OLLAMA_URL}/api/version" 2>/dev/null | jq -r '.version' 2>/dev/null)"
cop_ver="$(command -v copilot >/dev/null 2>&1 && copilot --version 2>/dev/null | head -1 || echo 'n/a')"

{
echo "# Local Model Test Campaign — GitHub Copilot CLI (offline)"
echo
echo "_Generated: $(date '+%Y-%m-%d %H:%M %Z')_"
echo
echo "## Test bench"
echo
echo "| Property | Value |"
echo "| --- | --- |"
echo "| Host arch | \`${host_arch}\` |"
echo "| CPU / RAM | ${host_cores} cores / ${host_ram} |"
echo "| GPU (host) | ${host_gpu} |"
echo "| Acceleration | ${accel} |"
echo "| Backend | Dockerized Ollama \`${oll_ver}\` on \`:${PORT}\` |"
echo "| Copilot CLI | ${cop_ver} |"
echo "| Mode | \`COPILOT_OFFLINE=true\` (no GitHub egress) |"
echo
echo "## What is measured & why"
echo
echo "The agentic CLI only works if a model: (1) returns **structured \`tool_calls\`** (not"
echo "text), (2) streams with **\`finish_reason\`**, and (3) finishes a turn inside the CLI's"
echo "**~10-min request timeout**. The agent system prompt is large (~${AGENT_TOK} tokens)."
echo
echo "Two derived numbers:"
echo
echo "- **1-pass** = one forward pass of that prompt = promptTokens/promptRate + 300/genRate."
echo "- **est. real turn** = 1-pass × ${TURN_FACTOR} — a real turn runs several LLM calls (think →"
echo "  tool → think …). The ×${TURN_FACTOR} factor is calibrated from \`mistral:7b\`, whose measured"
echo "  Copilot turn was 13m35s vs a 4m14s single pass. **The verdict uses est. real turn.**"
echo
echo "## Results"
echo
echo "| Model | Size | tool_calls | stream | instruction | prompt t/s | gen t/s | 1-pass | est. real turn | Verdict |"
echo "| --- | --- | :---: | :---: | :---: | ---: | ---: | ---: | ---: | --- |"
while IFS='|' read -r model size tool strm instr prate grate proj real vdt note; do
    printf '| `%s` | %s | %s | %s | %s | %s | %s | %s | %s | %s |\n' \
        "$model" "$size" "$tool" "$strm" "$instr" "$prate" "$grate" "$(fmt_mmss "${proj:-0}")" "$(fmt_mmss "${real:-0}")" "$vdt"
done < "$RESULTS"
echo
if [[ -f "${TMP}/full.psv" ]]; then
    echo "### Real Copilot CLI turns (\`--full\`)"
    echo
    echo "| Model | Wall time — outcome |"
    echo "| --- | --- |"
    while IFS='|' read -r model rest; do printf '| `%s` | %s |\n' "$model" "$rest"; done < "${TMP}/full.psv"
    echo
fi
echo "## Per-model notes & limitations"
echo
while IFS='|' read -r model size tool strm instr prate grate proj real vdt note; do
    echo "### \`${model}\` — ${vdt}"
    echo
    echo "- ${note}"
    echo
done < "$RESULTS"
echo "## Legend"
echo
echo "- **tool_calls PASS** = returns a structured \`tool_calls\` array (required). **FAIL** = emits the call as text or not at all → the agent loop cannot act."
echo "- **1-pass** = one forward pass of the agent prompt (lower bound). **est. real turn** = 1-pass × ${TURN_FACTOR} (calibrated). \`Good\` ≤ 6 min, \`Usable\` ≤ 10 min; beyond ~10 min the CLI times out (seen as \"transient API error. Retrying…\")."
echo "- Throughput here used **${accel}**. Prefill of the ~${AGENT_TOK}-token agent prompt dominates; on CPU that caps the bigger models, while GPU prefill is far faster."
} > "$OUT"

c_green "Done. Report: ${OUT}"
