param(
  [Alias("DevWorkspace")]
  [switch]$DeveloperWorkspace,
  [switch]$CloneCoordination,
  [string]$CoordinationRepoUrl = "https://github.com/hiro-collab/sword-agent-os-coordination.git"
)

$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path -Parent $PSScriptRoot
$WorkspaceRoot = Split-Path -Parent $RepoRoot

$dirs = @()

if ($DeveloperWorkspace) {
  $dirs += @(
    "worktrees",
    "_codex",
    "local",
    "local\organ-cache",
    "local\artifact-cache",
    "local\backups",
    "local\scratch"
  )
}

if ($CloneCoordination) {
  $dirs += @(
    "coordination",
    "coordination\local"
  )
}

foreach ($dir in $dirs) {
  New-Item -ItemType Directory -Force -Path (Join-Path $WorkspaceRoot $dir) | Out-Null
}

$sharedPath = Join-Path $WorkspaceRoot "coordination\shared"
if ($CloneCoordination -and -not (Test-Path $sharedPath)) {
  git clone $CoordinationRepoUrl $sharedPath
}

Write-Host "Workspace root: $WorkspaceRoot"
Write-Host "Main repo:       $RepoRoot"
if ($DeveloperWorkspace) {
  Write-Host "Worktrees:       $(Join-Path $WorkspaceRoot 'worktrees')"
  Write-Host "Codex state:     $(Join-Path $WorkspaceRoot '_codex')"
  Write-Host "Local assets:    $(Join-Path $WorkspaceRoot 'local')"
}
if ($CloneCoordination) {
  Write-Host "Coordination:    $(Join-Path $WorkspaceRoot 'coordination')"
}
if (-not $DeveloperWorkspace -and -not $CloneCoordination) {
  Write-Host "No workspace-local directories requested."
  Write-Host "Use -DeveloperWorkspace for Codex/worktree/local-cache folders."
  Write-Host "Use -CloneCoordination to clone the private coordination workspace."
}
