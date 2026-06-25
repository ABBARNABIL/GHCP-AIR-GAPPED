<#
.SYNOPSIS
    Runs a Foundry Local model and launches GitHub Copilot CLI wired to it.

.DESCRIPTION
    1. Ensures the Foundry Local service is running.
    2. Loads the requested model (downloads on first use).
    3. Reads the dynamic local endpoint from `foundry service status`
       and confirms the served model id from /v1/models.
    4. Exports the COPILOT_PROVIDER_* environment variables.
    5. Launches `copilot` so inference runs 100% on-device.

.EXAMPLE
    ./Start-CopilotWithFoundryLocal.ps1 -Model qwen2.5-coder-7b

.EXAMPLE
    # Pass extra arguments straight through to the copilot CLI:
    ./Start-CopilotWithFoundryLocal.ps1 -Model phi-4-mini -CopilotArgs '-p','What is 2+2?','--allow-all-tools'

.NOTES
    Prereqs:
      winget install Microsoft.FoundryLocal
      npm install -g @github/copilot   (GitHub Copilot CLI)

    The model MUST support tool calling (look for "tools" in `foundry model ls`).

    Streaming is force-disabled (`--stream off`). Foundry Local's OpenAI-compatible
    endpoint omits `finish_reason` on streaming chunks, which makes the Copilot CLI
    stream parser fail with:
      "CAPIError: Failed to finalize chat-completions stream: missing finish_reason".
    Non-streaming requests avoid this, so the agentic loop works reliably.

    CPU model variants (e.g. Phi-4-mini-instruct-generic-cpu) are the most stable.
    Some NPU/QNN variants can crash the Foundry inference service on large agent
    prompts; if that happens, pass an explicit CPU model id via -Model.
#>
[CmdletBinding()]
param(
    [string]$Model = "qwen2.5-coder-7b",
    [switch]$NoLaunch,
    [string[]]$CopilotArgs = @()
)

$ErrorActionPreference = "Stop"

function Assert-Command($name, $hint) {
    if (-not (Get-Command $name -ErrorAction SilentlyContinue)) {
        throw "'$name' not found. $hint"
    }
}

Assert-Command "foundry" "Install with: winget install Microsoft.FoundryLocal"
Assert-Command "copilot" "Install with: npm install -g @github/copilot"

Write-Host "==> Ensuring Foundry Local service is running..." -ForegroundColor Cyan
foundry service start | Out-Null

Write-Host "==> Loading model '$Model' (downloads on first run)..." -ForegroundColor Cyan
foundry model download $Model
foundry model load $Model

Write-Host "==> Resolving local endpoint..." -ForegroundColor Cyan
$status = foundry service status 2>&1 | Out-String
$match  = [regex]::Match($status, 'https?://(?:localhost|127\.0\.0\.1):(\d+)')
if (-not $match.Success) {
    throw "Could not parse the endpoint from 'foundry service status'. Raw output:`n$status"
}
$port    = $match.Groups[1].Value
$baseUrl = "http://localhost:$port/v1"
Write-Host "    Endpoint: $baseUrl" -ForegroundColor Green

# Confirm the exact served model id (Copilot needs the served id, not just the alias).
$servedId = $Model
try {
    $models = Invoke-RestMethod -Uri "$baseUrl/models" -TimeoutSec 10
    $ids = @($models.data.id)
    $pick = $ids | Where-Object { $_ -like "*$Model*" } | Select-Object -First 1
    if (-not $pick) { $pick = $ids | Select-Object -First 1 }
    if ($pick) { $servedId = $pick }
    Write-Host "    Served model id: $servedId" -ForegroundColor Green
} catch {
    Write-Warning "Could not query $baseUrl/models; using '$Model' as the model id."
}

Write-Host "==> Exporting Copilot CLI provider environment variables..." -ForegroundColor Cyan
$env:COPILOT_PROVIDER_TYPE     = "openai"
$env:COPILOT_PROVIDER_BASE_URL = $baseUrl
$env:COPILOT_PROVIDER_API_KEY  = "foundry-local"   # dummy; local needs no auth
$env:COPILOT_MODEL             = $servedId
$env:COPILOT_OFFLINE           = "true"            # air-gap: skip GitHub auth, telemetry, web tools, MCP, auto-update

Write-Host ""
Write-Host "  COPILOT_PROVIDER_TYPE     = $($env:COPILOT_PROVIDER_TYPE)"
Write-Host "  COPILOT_PROVIDER_BASE_URL = $($env:COPILOT_PROVIDER_BASE_URL)"
Write-Host "  COPILOT_MODEL             = $($env:COPILOT_MODEL)"
Write-Host "  COPILOT_OFFLINE           = $($env:COPILOT_OFFLINE)"
Write-Host ""

if ($NoLaunch) {
    Write-Host "Environment is set in this session. Run the CLI with streaming disabled:" -ForegroundColor Yellow
    Write-Host "    copilot --stream off" -ForegroundColor Yellow
    return
}

Write-Host "==> Launching GitHub Copilot CLI (inference is now local, streaming disabled)..." -ForegroundColor Cyan
# --stream off is REQUIRED: Foundry Local omits finish_reason on streaming chunks,
# which breaks the Copilot CLI stream parser. See .NOTES above.
copilot --stream off @CopilotArgs
