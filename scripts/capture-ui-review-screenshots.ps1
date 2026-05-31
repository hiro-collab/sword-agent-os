param(
    [ValidateSet("rr001", "launcher", "projection", "display")]
    [string]$Preset = "rr001",

    [string]$OutDir = "",
    [string]$Only = "",
    [string]$TargetsFile = "",
    [string]$LauncherUrl = "http://127.0.0.1:8799/",
    [string]$AituberUrl = "http://127.0.0.1:18880/",
    [string]$DisplayUrl = "http://127.0.0.1:18889/",
    [int]$TimeoutMs = 15000,
    [int]$SettleMs = 800,
    [switch]$Headed,
    [switch]$FailOnMissing
)

$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$nodeScript = Join-Path $scriptDir "capture-ui-review-screenshots.mjs"

$node = Get-Command node -ErrorAction SilentlyContinue
if (-not $node) {
    throw "Node.js is required for UI screenshot capture, but 'node' was not found on PATH."
}

$arguments = @(
    $nodeScript,
    "--preset", $Preset,
    "--launcher-url", $LauncherUrl,
    "--aituber-url", $AituberUrl,
    "--display-url", $DisplayUrl,
    "--timeout-ms", [string]$TimeoutMs,
    "--settle-ms", [string]$SettleMs
)

if ($OutDir) {
    $arguments += @("--out", $OutDir)
}

if ($Only) {
    $arguments += @("--only", $Only)
}

if ($TargetsFile) {
    $arguments += @("--targets-file", $TargetsFile)
}

if ($Headed) {
    $arguments += "--headed"
}

if ($FailOnMissing) {
    $arguments += "--fail-on-missing"
}
else {
    $arguments += "--skip-unavailable"
}

& $node.Source @arguments
