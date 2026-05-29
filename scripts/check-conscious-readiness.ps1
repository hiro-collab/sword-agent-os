param(
  [string]$ControlPlaneRoot = "control-plane/sword-voice-agent",
  [string]$TurnId = "turn_conscious_ready_probe",
  [string]$SessionId = "agent_os_readiness",
  [switch]$IncludeEvents
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$RepoRoot = Split-Path -Parent $PSScriptRoot

function Resolve-RepoPath {
  param([Parameter(Mandatory = $true)][string]$Path)
  if ([System.IO.Path]::IsPathRooted($Path)) {
    return $Path
  }
  return Join-Path $RepoRoot ($Path -replace "/", [System.IO.Path]::DirectorySeparatorChar)
}

function Assert-Path {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$Message
  )
  if (-not (Test-Path -LiteralPath $Path)) {
    throw "$Message`: $Path"
  }
}

$controlPlanePath = Resolve-RepoPath $ControlPlaneRoot
$thoughtCoreSrc = Join-Path $controlPlanePath "services\thought-core\src"
$readinessModule = Join-Path $thoughtCoreSrc "thought_core\readiness.py"

Assert-Path -Path $controlPlanePath -Message "control-plane checkout missing"
Assert-Path -Path $readinessModule -Message "Thought Core readiness module missing"

$uv = Get-Command "uv" -ErrorAction SilentlyContinue
if ($null -eq $uv) {
  throw "uv is required to run the conscious readiness probe"
}

$probeArgs = @(
  "--turn-id",
  $TurnId,
  "--session-id",
  $SessionId
)
if ($IncludeEvents) {
  $probeArgs += "--include-events"
}

$envSuffix = [System.Guid]::NewGuid().ToString("N")
$srcEnvName = "SWORD_AGENT_OS_READINESS_SRC_$envSuffix"
$argsEnvName = "SWORD_AGENT_OS_READINESS_ARGS_$envSuffix"
$argsJson = ConvertTo-Json ([string[]]$probeArgs) -Compress
[Environment]::SetEnvironmentVariable($srcEnvName, [string]$thoughtCoreSrc, "Process")
[Environment]::SetEnvironmentVariable($argsEnvName, [string]$argsJson, "Process")
$pythonCode = @"
import json
import os
import sys

sys.path.insert(0, os.environ['$srcEnvName'])
from thought_core.readiness import main

raise SystemExit(main(json.loads(os.environ['$argsEnvName'])))
"@

$previousErrorActionPreference = $ErrorActionPreference
try {
  $ErrorActionPreference = "Continue"
  $output = & $uv.Source run python -c $pythonCode 2>&1
  $exitCode = $LASTEXITCODE
}
finally {
  $ErrorActionPreference = $previousErrorActionPreference
  [Environment]::SetEnvironmentVariable($srcEnvName, $null, "Process")
  [Environment]::SetEnvironmentVariable($argsEnvName, $null, "Process")
}
$raw = ($output | ForEach-Object { [string]$_ }) -join "`n"

if ($exitCode -ne 0) {
  throw "conscious readiness probe failed with exit code $exitCode`: $raw"
}

try {
  $payload = $raw | ConvertFrom-Json
}
catch {
  throw "conscious readiness probe did not return JSON: $raw"
}

if ([string]$payload.status -ne "ok") {
  throw "conscious readiness probe returned non-ok status: $raw"
}
if ([string]$payload.startup_stage -ne "conscious_ready") {
  throw "conscious readiness probe returned unexpected startup_stage: $raw"
}
if ([bool]$payload.used_llm) {
  throw "conscious readiness probe must not use LLM/API path: $raw"
}

$payload | ConvertTo-Json -Depth 10
