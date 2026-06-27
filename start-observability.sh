#!/usr/bin/env bash
#
# start-observability.sh
# ----------------------------------------------------------------------------
# Linux / arm64 (aarch64) port of Start-Observability.ps1.
#
# Brings up the Grafana observability stack and opens the live dashboard:
#
#   ollama-exporter  parses the Ollama logs (Docker Engine API) + polls /api/ps,
#                    and exposes Prometheus metrics on :9105/metrics
#   prometheus       scrapes the exporter                      (:9090)
#   loki + promtail  ship the raw Ollama logs for the tables   (:3100)
#   grafana          provisioned datasources + dashboard       (:3000)
#
# All images are multi-arch and run natively on arm64. Pairs with the offline
# Copilot CLI setup; run this alongside start-copilot-with-docker.sh.
#
# Usage:
#   ./start-observability.sh
#   ./start-observability.sh --no-browser
#   ./start-observability.sh --down        # stop/remove the stack (keeps Ollama + volumes)
# ----------------------------------------------------------------------------
set -euo pipefail

NO_BROWSER=0
DOWN=0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="${SCRIPT_DIR}/docker-compose.yml"
GRAFANA_URL="http://localhost:3000/d/ollama-copilot"
SERVICES=(ollama-exporter prometheus loki promtail grafana)

c_cyan()  { printf '\033[36m%s\033[0m\n' "$*"; }
c_green() { printf '\033[32m%s\033[0m\n' "$*"; }
c_yellow(){ printf '\033[33m%s\033[0m\n' "$*"; }
c_red()   { printf '\033[31m%s\033[0m\n' "$*" >&2; }
die() { c_red "ERROR: $*"; exit 1; }

compose() {
    if docker compose version >/dev/null 2>&1; then
        docker compose -f "$COMPOSE_FILE" "$@"
    elif command -v docker-compose >/dev/null 2>&1; then
        docker-compose -f "$COMPOSE_FILE" "$@"
    else
        die "Neither 'docker compose' nor 'docker-compose' is available."
    fi
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-browser) NO_BROWSER=1; shift ;;
        --down)       DOWN=1; shift ;;
        -h|--help)    sed -n '2,24p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "Unknown option: $1 (try --help)" ;;
    esac
done

c_cyan "=== Ollama / Copilot CLI — Grafana observability ==="

# --- preflight: docker daemon -----------------------------------------------
command -v docker >/dev/null 2>&1 || die "'docker' not found. Install Docker Engine: https://docs.docker.com/engine/install/"
[[ -f "$COMPOSE_FILE" ]] || die "docker-compose.yml not found next to this script ($COMPOSE_FILE)."
docker info >/dev/null 2>&1 || die "Docker daemon is not running. Start it (sudo systemctl start docker) and retry."

if [[ $DOWN -eq 1 ]]; then
    c_yellow "Stopping observability services (Ollama + data volumes are kept)..."
    compose stop "${SERVICES[@]}" >/dev/null
    compose rm -f "${SERVICES[@]}" >/dev/null
    c_green "Done."
    exit 0
fi

# --- bring up the stack (idempotent; also ensures Ollama is up) -------------
c_cyan "Starting stack (docker compose up -d)..."
compose up -d ollama "${SERVICES[@]}"

# --- wait for Grafana health ------------------------------------------------
printf 'Waiting for Grafana to become healthy'
ready=0
for _ in $(seq 1 60); do
    if curl -fsS --max-time 2 "http://localhost:3000/api/health" 2>/dev/null | grep -q '"database"[[:space:]]*:[[:space:]]*"ok"'; then
        ready=1
        break
    fi
    sleep 1
    printf '.'
done
echo

if [[ $ready -eq 1 ]]; then
    c_green "Grafana    : healthy"
else
    c_yellow "Grafana    : not healthy yet — it may need another moment."
fi

c_green "Dashboard  : ${GRAFANA_URL}"
echo    "Prometheus : http://localhost:9090"
echo    "Exporter   : http://localhost:9105/metrics"
echo    "Login      : anonymous (admin/admin for edit) — local only"
echo
printf '\033[90mTip: the rich panels populate once the Copilot CLI sends a turn.\033[0m\n'
echo "Stop with: ./start-observability.sh --down"

if [[ $NO_BROWSER -eq 0 && $ready -eq 1 ]] && command -v xdg-open >/dev/null 2>&1; then
    xdg-open "$GRAFANA_URL" >/dev/null 2>&1 || true
fi
