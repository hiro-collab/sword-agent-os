param(
  [string]$ManifestPath = "",
  [switch]$DryRun,
  [switch]$IncludeDeferred
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$RepoRoot = Split-Path -Parent $PSScriptRoot

if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
  $ManifestPath = Join-Path $RepoRoot "manifests\organs\legacy-github.json"
}
elseif (-not [System.IO.Path]::IsPathRooted($ManifestPath)) {
  $ManifestPath = Join-Path $RepoRoot $ManifestPath
}

$manifest = Get-Content -Raw -LiteralPath $ManifestPath | ConvertFrom-Json

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

function Get-RelativeTarget {
  param([Parameter(Mandatory = $true)][string]$Path)
  return ($Path -replace "/", [System.IO.Path]::DirectorySeparatorChar)
}

foreach ($source in $manifest.sources) {
  if ($source.adoption -eq "deferred_reference" -and -not $IncludeDeferred) {
    Write-Host "skip deferred organ: $($source.organ_id)"
    continue
  }

  $target = Join-Path $RepoRoot (Get-RelativeTarget -Path $source.target_path)
  $parent = Split-Path -Parent $target

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
      [string]$source.branch,
      [string]$source.repo_url,
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
    $expected = [string]$source.commit

    if (-not [string]::IsNullOrWhiteSpace(($dirty -join ""))) {
      Write-Warning "dirty organ checkout: $($source.organ_id)"
    }
    if ($branch -ne [string]$source.branch) {
      Write-Warning "branch mismatch for $($source.organ_id): expected $($source.branch), got $branch"
    }
    if ($head -ne $expected) {
      Write-Warning "commit mismatch for $($source.organ_id): expected $expected, got $head"
    }
    else {
      Write-Host "verified: $($source.organ_id) $($expected.Substring(0, 7))"
    }
  }
}

