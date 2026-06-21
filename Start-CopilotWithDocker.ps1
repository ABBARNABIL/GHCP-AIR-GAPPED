<#
.SYNOPSIS
    Runs a local model in Docker (Ollama) and launches the GitHub Copilot CLI
    wired to it in offline / airgapped mode.

.DESCRIPTION
    1. Ensures the Docker daemon is running (starts Docker Desktop if needed).
    2. Starts the Ollama container via docker-compose.yml
       (OpenAI-compatible API on http://localhost:PORT).
    3. Waits for the endpoint to become healthy.
    4. Ensures the requested model is present (pulls it once if online).
    5. Confirms the served model id via the OpenAI-compatible /v1/models route.
    6. Exports the COPILOT_PROVIDER_* variables plus COPILOT_OFFLINE and launches
       `copilot`, so inference runs 100% on-device and the CLI does not contact
       GitHub's servers.

.EXAMPLE
    ./Start-CopilotWithDocker.ps1
    ./Start-CopilotWithDocker.ps1 -Model llama3.1:8b -ContextLength 32768
    ./Start-CopilotWithDocker.ps1 -NoLaunch         # set env only, then run `copilot` yourself
    ./Start-CopilotWithDocker.ps1 -Pull             # force (re)pull the model (needs network)
    ./Start-CopilotWithDocker.ps1 -Offline:$false   # allow the first-run model pull

.NOTES
    Prereqs:
      - Docker Desktop installed with the WSL2 backend enabled.
      - GitHub Copilot CLI installed:  winget install GitHub.Copilot
      - One-time online step: pull the model once before going fully offline
        (offline mode needs no GitHub login; see README.md).

    The model MUST support tool calling + streaming for the agentic CLI to work.
    Default is llama3.2:3b -- it returns *structured* tool calls and is fast enough
    to finish a turn on CPU-only hosts. llama3.1:8b is higher quality but, at
    ~17-30 tok/s on CPU, exceeds the CLI's ~10-min request timeout, so it needs a
    GPU. qwen2.5-coder:7b emits tool calls as plain text and cannot drive the agent
    loop. See README.md "Choosing a model".

    Performance: the Copilot CLI sends a large (~17.5k token) agent prompt that
    cannot be shrunk. On CPU this is minutes per cold turn; a GPU is strongly
    recommended for interactive use (see README.md "Performance").
#>
[CmdletBinding()]
param(
    [string]$Model         = "llama3.2:3b",
    [int]   $Port          = 11434,
    [int]   $ContextLength = 32768,
    [bool]  $Offline       = $true,
    [switch]$Pull,
    [switch]$NoLaunch
)

$ErrorActionPreference = "Stop"
$composeFile = Join-Path $PSScriptRoot "docker-compose.yml"

function Assert-Command($name, $hint) {
    if (-not (Get-Command $name -ErrorAction SilentlyContinue)) {
        throw "'$name' not found. $hint"
    }
}

function Test-DockerUp {
    docker info *> $null
    return ($LASTEXITCODE -eq 0)
}

Assert-Command "docker"  "Install Docker Desktop: https://www.docker.com/products/docker-desktop/"
Assert-Command "copilot" "Install with: winget install GitHub.Copilot"

if (-not (Test-Path $composeFile)) {
    throw "docker-compose.yml not found next to this script ($composeFile)."
}

# 1. Ensure the Docker daemon is running (start Docker Desktop if needed).
if (-not (Test-DockerUp)) {
    Write-Host "==> Docker daemon not responding. Attempting to start Docker Desktop..." -ForegroundColor Cyan
    $dd = "C:\Program Files\Docker\Docker\Docker Desktop.exe"
    if (Test-Path $dd) {
        Start-Process $dd
    } else {
        throw "Docker daemon is not running and Docker Desktop.exe was not found. Start Docker manually."
    }
    $deadline = (Get-Date).AddSeconds(180)
    while (-not (Test-DockerUp)) {
        if ((Get-Date) -gt $deadline) { throw "Docker daemon did not become ready within 180s." }
        Start-Sleep -Seconds 3
        Write-Host "    ...waiting for Docker daemon" -ForegroundColor DarkGray
    }
}
Write-Host "==> Docker daemon is running." -ForegroundColor Green

# 2. Start the Ollama container.
Write-Host "==> Starting Ollama container (docker compose up -d)..." -ForegroundColor Cyan
docker compose -f $composeFile up -d
if ($LASTEXITCODE -ne 0) { throw "docker compose up failed." }

# 3. Wait for the endpoint to become healthy.
$tagsUrl = "http://localhost:$Port/api/tags"
Write-Host "==> Waiting for the Ollama endpoint ($tagsUrl)..." -ForegroundColor Cyan
$deadline = (Get-Date).AddSeconds(120)
while ($true) {
    try { Invoke-RestMethod -Uri $tagsUrl -TimeoutSec 5 | Out-Null; break } catch {}
    if ((Get-Date) -gt $deadline) { throw "Ollama endpoint did not respond within 120s." }
    Start-Sleep -Seconds 3
}
Write-Host "    Endpoint is up." -ForegroundColor Green

# 4. Ensure the model is present (pull once if online).
$installed = ""
try { $installed = (docker exec ollama ollama list 2>$null | Out-String) } catch {}
$modelPresent = $installed -match [regex]::Escape($Model)
if ($Pull -or -not $modelPresent) {
    if ($Offline -and -not $Pull) {
        throw ("Model '$Model' is not in the Ollama volume and Offline mode is on. " +
               "Run the one-time online provisioning first: " +
               "'./Start-CopilotWithDocker.ps1 -Pull' (or -Offline:`$false).")
    }
    Write-Host "==> Pulling model '$Model' (needs network; one-time)..." -ForegroundColor Cyan
    docker exec ollama ollama pull $Model
    if ($LASTEXITCODE -ne 0) { throw "Failed to pull model '$Model'." }
} else {
    Write-Host "==> Model '$Model' already present." -ForegroundColor Green
}

# 5. Confirm the served model id via the OpenAI-compatible route.
# NOTE: The Copilot CLI does NOT auto-append "/v1" -- the base URL must include it
# (verified empirically: a bare host returns HTTP 404 "model not found").
$baseUrl  = "http://localhost:$Port/v1"
$servedId = $Model
try {
    $models = Invoke-RestMethod -Uri "$baseUrl/models" -TimeoutSec 10
    $ids  = @($models.data.id)
    $pick = $ids | Where-Object { $_ -eq $Model } | Select-Object -First 1
    if (-not $pick) {
        $stem = $Model.Split(':')[0]
        $pick = $ids | Where-Object { $_ -like "*$stem*" } | Select-Object -First 1
    }
    if ($pick) { $servedId = $pick }
    Write-Host "    Served model id: $servedId" -ForegroundColor Green
} catch {
    Write-Warning "Could not query $baseUrl/v1/models; using '$Model' as the model id."
}

# 6. Export Copilot CLI provider environment variables.
Write-Host "==> Exporting Copilot CLI provider environment variables..." -ForegroundColor Cyan
$env:COPILOT_PROVIDER_TYPE     = "openai"
$env:COPILOT_PROVIDER_BASE_URL = $baseUrl       # must include /v1 for the Copilot CLI
$env:COPILOT_PROVIDER_API_KEY  = "ollama"       # dummy; local Ollama needs no auth
$env:COPILOT_MODEL             = $servedId
if ($Offline) {
    $env:COPILOT_OFFLINE = "true"
} else {
    Remove-Item Env:COPILOT_OFFLINE -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "  COPILOT_PROVIDER_TYPE     = $($env:COPILOT_PROVIDER_TYPE)"
Write-Host "  COPILOT_PROVIDER_BASE_URL = $($env:COPILOT_PROVIDER_BASE_URL)"
Write-Host "  COPILOT_MODEL             = $($env:COPILOT_MODEL)"
Write-Host "  COPILOT_OFFLINE           = $($env:COPILOT_OFFLINE)"
Write-Host ""

if ($NoLaunch) {
    Write-Host "Environment is set in this session. Run 'copilot' to start." -ForegroundColor Yellow
    return
}

Write-Host "==> Launching GitHub Copilot CLI (inference is local; offline=$Offline)..." -ForegroundColor Cyan
copilot
