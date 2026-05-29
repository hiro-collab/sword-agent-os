param(
  [string]$HostName = "127.0.0.1",
  [int]$Port = 8799,
  [switch]$OpenBrowser,
  [switch]$ReuseExisting
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$RepoRoot = Split-Path -Parent $PSScriptRoot
$target = Join-Path $RepoRoot "control-plane\sword-voice-agent\ops\scripts\home-control-stack\start-home-control-launcher.ps1"

if (-not (Test-Path -LiteralPath $target -PathType Leaf)) {
  throw "Launcher delegate not found: $target"
}

$arguments = @{
  WorkspaceRoot = $RepoRoot
  HostName = $HostName
  Port = $Port
}
if ($OpenBrowser) {
  $arguments.OpenBrowser = $true
}
if ($ReuseExisting) {
  $arguments.ReuseExisting = $true
}

& $target @arguments
if ($LASTEXITCODE -is [int]) {
  exit $LASTEXITCODE
}
