<#
.SYNOPSIS
    Brings up the Grafana observability stack and opens the live dashboard.

.DESCRIPTION
    Starts the Dockerized metrics stack that replaces the old browser dashboard:

      ollama-exporter  parses the Ollama logs (Docker Engine API) + polls /api/ps,
                       and exposes Prometheus metrics on :9105/metrics
      prometheus       scrapes the exporter                      (:9090)
      loki + promtail  ship the raw Ollama logs for the tables   (:3100)
      grafana          provisioned datasources + dashboard       (:3000)

    Everything is provisioned as-code, so the dashboard is ready the moment Grafana
    is up. Pairs with the offline GitHub Copilot CLI setup (see README.md); run this
    alongside Start-CopilotWithDocker.ps1.

.PARAMETER NoBrowser
    Do not auto-open the browser.

.PARAMETER Down
    Stop and remove the observability stack (keeps Ollama and all data volumes).

.EXAMPLE
    .\Start-Observability.ps1
.EXAMPLE
    .\Start-Observability.ps1 -NoBrowser
.EXAMPLE
    .\Start-Observability.ps1 -Down
#>
[CmdletBinding()]
param(
    [switch]$NoBrowser,
    [switch]$Down
)

$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $here

$services = @("ollama-exporter", "prometheus", "loki", "promtail", "grafana")
$grafanaUrl = "http://localhost:3000/d/ollama-copilot"

Write-Host "=== Ollama / Copilot CLI — Grafana observability ===" -ForegroundColor Cyan

# --- preflight: docker daemon ------------------------------------------------
try {
    docker info --format '{{.ServerVersion}}' *> $null
    if ($LASTEXITCODE -ne 0) { throw "daemon not responding" }
} catch {
    Write-Host "ERROR: Docker daemon is not running. Start Docker Desktop and retry." -ForegroundColor Red
    exit 1
}

if ($Down) {
    Write-Host "Stopping observability services (Ollama + data volumes are kept)..." -ForegroundColor Yellow
    docker compose stop $services | Out-Null
    docker compose rm -f $services | Out-Null
    Write-Host "Done." -ForegroundColor Green
    exit 0
}

# --- bring up the stack (idempotent; also ensures Ollama is up) ---------------
Write-Host "Starting stack (docker compose up -d)..."
docker compose up -d ollama @services

# --- wait for Grafana health -------------------------------------------------
Write-Host "Waiting for Grafana to become healthy..." -NoNewline
$ready = $false
for ($i = 0; $i -lt 60; $i++) {
    try {
        $h = Invoke-RestMethod "http://localhost:3000/api/health" -TimeoutSec 2
        if ($h.database -eq "ok") { $ready = $true; break }
    } catch { }
    Start-Sleep -Seconds 1
    Write-Host "." -NoNewline
}
Write-Host ""

if ($ready) {
    Write-Host "Grafana    : healthy" -ForegroundColor Green
} else {
    Write-Host "Grafana    : not healthy yet — it may need another moment." -ForegroundColor Yellow
}

Write-Host ("Dashboard  : {0}" -f $grafanaUrl) -ForegroundColor Green
Write-Host  "Prometheus : http://localhost:9090"
Write-Host  "Exporter   : http://localhost:9105/metrics"
Write-Host  "Login      : anonymous (admin/admin for edit) — local only"
Write-Host ""
Write-Host "Tip: the rich panels populate once the Copilot CLI sends a turn." -ForegroundColor DarkGray
Write-Host "Stop with: .\Start-Observability.ps1 -Down"

if (-not $NoBrowser -and $ready) {
    Start-Process $grafanaUrl
}
