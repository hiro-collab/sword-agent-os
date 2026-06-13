param(
  [Parameter(Mandatory = $true)]
  [string]$ConfigPath,

  [string]$OutputDir = "",

  [switch]$Json
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$RepoRoot = Split-Path -Parent $PSScriptRoot
$AnalyzerRoot = Join-Path $RepoRoot "runtime\visual-motion-analyzer"

function Resolve-LocalPath {
  param([Parameter(Mandatory = $true)][string]$Path)
  if ([System.IO.Path]::IsPathRooted($Path)) {
    return [System.IO.Path]::GetFullPath($Path)
  }
  return [System.IO.Path]::GetFullPath((Join-Path (Get-Location) $Path))
}

if (-not (Test-Path -LiteralPath $AnalyzerRoot -PathType Container)) {
  throw "Self Mirror visual analyzer runtime package not found"
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
  "run", "python", "-m", "self_mirror_visual_analyzer.visual_motion_analyzer",
  "--config", $resolvedConfigPath,
  "--output-dir", $resolvedOutputDir
)
if ($Json) {
  $arguments += "--json"
}

Push-Location $AnalyzerRoot
try {
  & uv @arguments
  if ($LASTEXITCODE -ne 0) {
    throw "visual motion analyzer failed"
  }
}
finally {
  Pop-Location
}
