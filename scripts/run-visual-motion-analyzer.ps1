param(
  [Parameter(Mandatory = $true)]
  [string]$ConfigPath,

  [string]$OutputDir = "",

  [switch]$Json
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$RepoRoot = Split-Path -Parent $PSScriptRoot
$VisionRoot = Join-Path $RepoRoot "organs\environment\vision-snapshot-processor"

function Resolve-LocalPath {
  param([Parameter(Mandatory = $true)][string]$Path)
  if ([System.IO.Path]::IsPathRooted($Path)) {
    return [System.IO.Path]::GetFullPath($Path)
  }
  return [System.IO.Path]::GetFullPath((Join-Path (Get-Location) $Path))
}

if (-not (Test-Path -LiteralPath $VisionRoot -PathType Container)) {
  throw "vision-snapshot-processor checkout not found"
}

$resolvedConfigPath = Resolve-LocalPath -Path $ConfigPath
if (-not (Test-Path -LiteralPath $resolvedConfigPath -PathType Leaf)) {
  throw "visual analyzer config not found"
}

if ([string]::IsNullOrWhiteSpace($OutputDir)) {
  $OutputDir = Join-Path $RepoRoot ".cache\agent-os\visual-motion-analyzer"
}
$resolvedOutputDir = Resolve-LocalPath -Path $OutputDir
New-Item -ItemType Directory -Force -Path $resolvedOutputDir | Out-Null

$arguments = @(
  "--cache-dir", ".uv-cache",
  "run", "python", "-m", "vision_snapshot_processor.visual_motion_analyzer",
  "--config", $resolvedConfigPath,
  "--output-dir", $resolvedOutputDir
)
if ($Json) {
  $arguments += "--json"
}

Push-Location $VisionRoot
try {
  & uv @arguments
}
finally {
  Pop-Location
}
