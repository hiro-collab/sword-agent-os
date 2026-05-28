param(
  [string]$ManifestPath = "manifests/legacy/control-plane-reference.json",
  [switch]$DryRun,
  [switch]$VerifyRemote
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

function Invoke-Step {
  param(
    [Parameter(Mandatory = $true)][string[]]$Command,
    [string]$WorkingDirectory = $RepoRoot
  )

  if ($DryRun) {
    Write-Host "cd $WorkingDirectory"
    Write-Host ($Command -join " ")
    return
  }

  Push-Location $WorkingDirectory
  try {
    $exe = $Command[0]
    $args = @()
    if ($Command.Count -gt 1) {
      $args = $Command[1..($Command.Count - 1)]
    }
    & $exe @args
  }
  finally {
    Pop-Location
  }
}

$manifest = Get-Content -Raw -LiteralPath (Resolve-RepoPath $ManifestPath) | ConvertFrom-Json
$target = Resolve-RepoPath ([string]$manifest.target_path)
$parent = Split-Path -Parent $target

if ($VerifyRemote) {
  $line = git ls-remote ([string]$manifest.repo_url) "refs/heads/$($manifest.branch)"
  if ([string]::IsNullOrWhiteSpace(($line -join ""))) {
    throw "control-plane remote branch not found: $($manifest.branch)"
  }
  $remoteCommit = (($line | Select-Object -First 1) -split "`t")[0]
  if ($remoteCommit -ne [string]$manifest.commit) {
    throw "control-plane remote commit mismatch: expected $($manifest.commit), got $remoteCommit"
  }
  Write-Host "remote verified: $($manifest.id) $($manifest.commit.Substring(0, 7))"
}

if (-not (Test-Path -LiteralPath $parent)) {
  if ($DryRun) {
    Write-Host "New-Item -ItemType Directory -Force -Path $parent"
  }
  else {
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
  }
}

if (-not (Test-Path -LiteralPath $target)) {
  Invoke-Step -Command @(
    "git",
    "clone",
    "--branch",
    [string]$manifest.branch,
    [string]$manifest.repo_url,
    $target
  )
}
elseif (-not (Test-Path -LiteralPath (Join-Path $target ".git"))) {
  throw "target exists but is not a git checkout: $target"
}
else {
  Write-Host "exists: $target"
}

if (Test-Path -LiteralPath (Join-Path $target ".git")) {
  $dirty = git -C $target status --short
  $head = git -C $target rev-parse HEAD
  $branch = git -C $target branch --show-current

  if (-not [string]::IsNullOrWhiteSpace(($dirty -join ""))) {
    Write-Warning "dirty control-plane checkout: $target"
  }
  if ($branch -ne [string]$manifest.branch) {
    Write-Warning "branch mismatch: expected $($manifest.branch), got $branch"
  }
  if ($head -ne [string]$manifest.commit) {
    Write-Warning "commit mismatch: expected $($manifest.commit), got $head"
  }
  else {
    Write-Host "verified: $($manifest.id) $($manifest.commit.Substring(0, 7))"
  }
}

