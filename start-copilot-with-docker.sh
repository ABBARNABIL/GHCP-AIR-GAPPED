#!/usr/bin/env bash
#
# start-copilot-with-docker.sh
# ----------------------------------------------------------------------------
# Linux / arm64 (aarch64) port of Start-CopilotWithDocker.ps1.
#
# Runs a local model inside Docker (Ollama) and launches the GitHub Copilot CLI
# wired to it in offline / airgapped mode, so the CLI talks only to your local
# provider and never to GitHub's servers.
#
#   1. Ensures the Docker daemon is running (tries `systemctl start docker`).
#   2. Starts the Ollama container via docker-compose.yml
#      (OpenAI-compatible API on http://localhost:PORT).
#   3. Waits for the endpoint to become healthy.
#   4. Ensures the requested model is present (pulls it once if online).
#   5. Confirms the served model id via the OpenAI-compatible /v1/models route.
#   6. Exports the COPILOT_PROVIDER_* variables plus COPILOT_OFFLINE and launches
#      `copilot`, so inference runs 100% on-device.
#
# Usage:
#   ./start-copilot-with-docker.sh
#   ./start-copilot-with-docker.sh --model llama3.1:8b --context-length 32768
#   ./start-copilot-with-docker.sh --no-launch      # set env only, then run `copilot`
#   ./start-copilot-with-docker.sh --pull           # force (re)pull the model (needs network)
#   ./start-copilot-with-docker.sh --online         # allow the first-run model pull
#
# Prereqs (arm64 Linux):
#   - Docker Engine + the compose plugin:  https://docs.docker.com/engine/install/
#       (add your user to the `docker` group to avoid sudo: `sudo usermod -aG docker $USER`)
#   - GitHub Copilot CLI:  npm install -g @github/copilot   (Node.js 18+)
#   - One-time online step: pull the model once before going fully offline.
#
# The Ollama image and the default model (llama3.2:3b) are multi-arch and run
# natively on arm64. The model MUST support tool calling + streaming for the
# agentic CLI to work; see README.md "Choosing a model".
# ----------------------------------------------------------------------------
set -euo pipefail

# ---- defaults --------------------------------------------------------------
MODEL="llama3.2:3b"
PORT=11434
CONTEXT_LENGTH=32768
OFFLINE=1
PULL=0
NO_LAUNCH=0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="${SCRIPT_DIR}/docker-compose.yml"

# ---- helpers ---------------------------------------------------------------
c_cyan()  { printf '\033[36m%s\033[0m\n' "$*"; }
c_green() { printf '\033[32m%s\033[0m\n' "$*"; }
c_yellow(){ printf '\033[33m%s\033[0m\n' "$*"; }
c_red()   { printf '\033[31m%s\033[0m\n' "$*" >&2; }

die() { c_red "ERROR: $*"; exit 1; }

usage() {
    sed -n '2,32p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit 0
}

assert_command() {
    command -v "$1" >/dev/null 2>&1 || die "'$1' not found. $2"
}

docker_up() {
    docker info >/dev/null 2>&1
}

# `docker compose` (v2 plugin) is preferred; fall back to legacy `docker-compose`.
compose() {
    if docker compose version >/dev/null 2>&1; then
        docker compose -f "$COMPOSE_FILE" "$@"
    elif command -v docker-compose >/dev/null 2>&1; then
        docker-compose -f "$COMPOSE_FILE" "$@"
    else
        die "Neither 'docker compose' nor 'docker-compose' is available."
    fi
}

# ---- arg parsing -----------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --model)          MODEL="$2"; shift 2 ;;
        --port)           PORT="$2"; shift 2 ;;
        --context-length) CONTEXT_LENGTH="$2"; shift 2 ;;
        --offline)        OFFLINE=1; shift ;;
        --online)         OFFLINE=0; shift ;;
        --pull)           PULL=1; OFFLINE=0; shift ;;
        --no-launch)      NO_LAUNCH=1; shift ;;
        -h|--help)        usage ;;
        *) die "Unknown option: $1 (try --help)" ;;
    esac
done

export OLLAMA_CONTEXT_LENGTH="$CONTEXT_LENGTH"   # consumed by docker-compose.yml

# ---- preflight -------------------------------------------------------------
assert_command "docker"  "Install Docker Engine: https://docs.docker.com/engine/install/"
assert_command "copilot" "Install with: npm install -g @github/copilot"
assert_command "curl"    "Install with your package manager, e.g. sudo apt install curl"
[[ -f "$COMPOSE_FILE" ]] || die "docker-compose.yml not found next to this script ($COMPOSE_FILE)."

# 1. Ensure the Docker daemon is running.
if ! docker_up; then
    c_cyan "==> Docker daemon not responding. Attempting to start it (systemctl)..."
    if command -v systemctl >/dev/null 2>&1; then
        sudo systemctl start docker || true
    fi
    deadline=$(( $(date +%s) + 60 ))
    until docker_up; do
        [[ $(date +%s) -gt $deadline ]] && die "Docker daemon did not become ready within 60s. Start it manually (sudo systemctl start docker)."
        sleep 2
        printf '\033[90m    ...waiting for Docker daemon\033[0m\n'
    done
fi
c_green "==> Docker daemon is running."

# 2. Start the Ollama container.
c_cyan "==> Starting Ollama container (docker compose up -d ollama)..."
compose up -d ollama

# 3. Wait for the endpoint to become healthy.
TAGS_URL="http://localhost:${PORT}/api/tags"
c_cyan "==> Waiting for the Ollama endpoint (${TAGS_URL})..."
deadline=$(( $(date +%s) + 120 ))
until curl -fsS --max-time 5 "$TAGS_URL" >/dev/null 2>&1; do
    [[ $(date +%s) -gt $deadline ]] && die "Ollama endpoint did not respond within 120s."
    sleep 3
done
c_green "    Endpoint is up."

# 4. Ensure the model is present (pull once if online).
if docker exec ollama ollama list 2>/dev/null | grep -qF "$MODEL"; then
    MODEL_PRESENT=1
else
    MODEL_PRESENT=0
fi

if [[ $PULL -eq 1 || $MODEL_PRESENT -eq 0 ]]; then
    if [[ $OFFLINE -eq 1 && $PULL -eq 0 ]]; then
        die "Model '$MODEL' is not in the Ollama volume and offline mode is on.
       Run the one-time online provisioning first:
         ./start-copilot-with-docker.sh --pull   (or --online)."
    fi
    c_cyan "==> Pulling model '$MODEL' (needs network; one-time)..."
    docker exec ollama ollama pull "$MODEL" || die "Failed to pull model '$MODEL'."
else
    c_green "==> Model '$MODEL' already present."
fi

# 5. Confirm the served model id via the OpenAI-compatible route.
# NOTE: The Copilot CLI does NOT auto-append "/v1" -- the base URL must include it.
BASE_URL="http://localhost:${PORT}/v1"
SERVED_ID="$MODEL"
MODELS_JSON="$(curl -fsS --max-time 10 "${BASE_URL}/models" 2>/dev/null || true)"
if [[ -n "$MODELS_JSON" ]]; then
    if command -v jq >/dev/null 2>&1; then
        ids="$(printf '%s' "$MODELS_JSON" | jq -r '.data[].id' 2>/dev/null || true)"
    else
        # Lightweight fallback parse of "id":"..." pairs (no jq dependency).
        ids="$(printf '%s' "$MODELS_JSON" | grep -oE '"id"[[:space:]]*:[[:space:]]*"[^"]+"' | sed -E 's/.*"id"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/')"
    fi
    pick="$(printf '%s\n' "$ids" | grep -Fx "$MODEL" | head -n1 || true)"
    if [[ -z "$pick" ]]; then
        stem="${MODEL%%:*}"
        pick="$(printf '%s\n' "$ids" | grep -F "$stem" | head -n1 || true)"
    fi
    [[ -n "$pick" ]] && SERVED_ID="$pick"
    c_green "    Served model id: $SERVED_ID"
else
    c_yellow "Warning: could not query ${BASE_URL}/models; using '$MODEL' as the model id."
fi

# 6. Export Copilot CLI provider environment variables.
c_cyan "==> Exporting Copilot CLI provider environment variables..."
export COPILOT_PROVIDER_TYPE="openai"
export COPILOT_PROVIDER_BASE_URL="$BASE_URL"   # must include /v1 for the Copilot CLI
export COPILOT_PROVIDER_API_KEY="ollama"       # dummy; local Ollama needs no auth
export COPILOT_MODEL="$SERVED_ID"
if [[ $OFFLINE -eq 1 ]]; then
    export COPILOT_OFFLINE="true"
else
    unset COPILOT_OFFLINE
fi

echo
echo "  COPILOT_PROVIDER_TYPE     = ${COPILOT_PROVIDER_TYPE}"
echo "  COPILOT_PROVIDER_BASE_URL = ${COPILOT_PROVIDER_BASE_URL}"
echo "  COPILOT_MODEL             = ${COPILOT_MODEL}"
echo "  COPILOT_OFFLINE           = ${COPILOT_OFFLINE:-<unset>}"
echo

if [[ $NO_LAUNCH -eq 1 ]]; then
    c_yellow "Environment is set, but this runs in a child shell."
    c_yellow "To use the vars in your current shell instead, source this script:"
    c_yellow "    source ./start-copilot-with-docker.sh --no-launch"
    c_yellow "Then run: copilot"
    # If sourced, the exports persist in the caller's shell.
    (return 0 2>/dev/null) && return 0
    exit 0
fi

c_cyan "==> Launching GitHub Copilot CLI (inference is local; offline=${OFFLINE})..."
exec copilot
