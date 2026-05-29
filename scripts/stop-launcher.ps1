param(
  [string]$HostName = "127.0.0.1",
  [int]$Port = 8799,
  [int]$TimeoutSeconds = 5,
  [switch]$Force
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$RepoRoot = Split-Path -Parent $PSScriptRoot
$target = Join-Path $RepoRoot "control-plane\sword-voice-agent\ops\scripts\home-control-stack\stop-home-control-launcher.ps1"

if (-not (Test-Path -LiteralPath $target -PathType Leaf)) {
  throw "Launcher stop delegate not found: $target"
}

$arguments = @{
  WorkspaceRoot = $RepoRoot
  HostName = $HostName
  Port = $Port
  TimeoutSeconds = $TimeoutSeconds
}
if ($Force) {
  $arguments.Force = $true
}

& $target @arguments
if ((Test-Path Variable:LASTEXITCODE) -and $LASTEXITCODE -is [int]) {
  exit $LASTEXITCODE
}
