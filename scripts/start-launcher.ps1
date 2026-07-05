param(
  [string]$HostName = "127.0.0.1",
  [int]$Port = 8799,
  [ValidateSet("", "manifest_default", "isolated_override")]
  [string]$PortMode = "",
  [string]$StackStateDir = "",
  [switch]$OpenBrowser,
  [switch]$ReuseExisting
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$RepoRoot = Split-Path -Parent $PSScriptRoot
$target = Join-Path $RepoRoot "control-plane\core\ops\scripts\home-control-stack\start-home-control-launcher.ps1"

if (-not (Test-Path -LiteralPath $target -PathType Leaf)) {
  throw "Launcher delegate not found: $target"
}

$arguments = @{
  WorkspaceRoot = $RepoRoot
  HostName = $HostName
  Port = $Port
}
if (-not [string]::IsNullOrWhiteSpace($PortMode)) {
  $arguments.PortMode = $PortMode
}
if (-not [string]::IsNullOrWhiteSpace($StackStateDir)) {
  $arguments.StackStateDir = $StackStateDir
}
if ($OpenBrowser) {
  $arguments.OpenBrowser = $true
}
if ($ReuseExisting) {
  $arguments.ReuseExisting = $true
}

& $target @arguments
if ((Test-Path Variable:LASTEXITCODE) -and $LASTEXITCODE -is [int]) {
  exit $LASTEXITCODE
}
