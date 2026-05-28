param(
  [switch]$CloneCoordination,
  [string]$CoordinationRepoUrl = "https://github.com/hiro-collab/sword-agent-os-coordination.git"
)

$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path -Parent $PSScriptRoot
$WorkspaceRoot = Split-Path -Parent $RepoRoot

$dirs = @(
  "worktrees",
  "coordination",
  "coordination\local",
  "_codex",
  "local",
  "local\organ-cache",
  "local\artifact-cache",
  "local\backups",
  "local\scratch"
)

foreach ($dir in $dirs) {
  New-Item -ItemType Directory -Force -Path (Join-Path $WorkspaceRoot $dir) | Out-Null
}

$sharedPath = Join-Path $WorkspaceRoot "coordination\shared"
if ($CloneCoordination -and -not (Test-Path $sharedPath)) {
  git clone $CoordinationRepoUrl $sharedPath
}

Write-Host "Workspace root: $WorkspaceRoot"
Write-Host "Main repo:       $RepoRoot"
Write-Host "Worktrees:       $(Join-Path $WorkspaceRoot 'worktrees')"
Write-Host "Coordination:    $(Join-Path $WorkspaceRoot 'coordination')"
Write-Host "Local assets:    $(Join-Path $WorkspaceRoot 'local')"

