param(
  [string]$Profile = "standard",
  [string]$DistributionManifestPath = "",
  [switch]$DryRun,
  [switch]$NoDeps,
  [switch]$NoEnv,
  [switch]$ForceEnv,
  [switch]$VerifyRemote,
  [switch]$IncludeDeferred
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

function Read-JsonFile {
  param([Parameter(Mandatory = $true)][string]$Path)
  return Get-Content -Raw -LiteralPath (Resolve-RepoPath $Path) | ConvertFrom-Json
}

function Get-OptionalProperty {
  param(
    [Parameter(Mandatory = $true)]$Object,
    [Parameter(Mandatory = $true)][string]$Name,
    [object]$Default = $null
  )
  $property = $Object.PSObject.Properties[$Name]
  if ($null -eq $property -or $null -eq $property.Value) {
    return $Default
  }
  return $property.Value
}

function Invoke-Step {
  param(
    [Parameter(Mandatory = $true)][string[]]$Command,
    [string]$WorkingDirectory = $RepoRoot
  )
  if ($Command.Count -eq 0) {
    return
  }
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

function Test-RemotePin {
  param([Parameter(Mandatory = $true)]$Item)
  $line = git ls-remote ([string]$Item.repo_url) "refs/heads/$($Item.branch)"
  if ([string]::IsNullOrWhiteSpace(($line -join ""))) {
    throw "remote branch not found for $($Item.id): $($Item.branch)"
  }
  $remoteCommit = (($line | Select-Object -First 1) -split "`t")[0]
  if ($remoteCommit -ne [string]$Item.commit) {
    throw "remote commit mismatch for $($Item.id): expected $($Item.commit), got $remoteCommit"
  }
  Write-Host "remote verified: $($Item.id) $($Item.commit.Substring(0, 7))"
}

function Invoke-GitChecked {
  param([Parameter(Mandatory = $true)][string[]]$Arguments)
  $output = & git @Arguments 2>&1
  $exitCode = $LASTEXITCODE
  foreach ($line in @($output)) {
    if (-not [string]::IsNullOrWhiteSpace([string]$line)) {
      Write-Host $line
    }
  }
  if ($exitCode -ne 0) {
    throw "git failed: git $($Arguments -join ' ')"
  }
}

function Get-CheckoutItems {
  param([Parameter(Mandatory = $true)]$Manifest)

  $items = @()
  $controlPlane = Read-JsonFile -Path ([string]$Manifest.control_plane_manifest_path)
  $items += [PSCustomObject]@{
    id = [string]$controlPlane.id
    kind = "control-plane"
    repo_url = [string]$controlPlane.repo_url
    branch = [string]$controlPlane.branch
    commit = [string]$controlPlane.commit
    target_path = [string]$controlPlane.target_path
    adoption = "standard"
  }

  $organManifest = Read-JsonFile -Path ([string]$Manifest.organ_manifest_path)
  foreach ($source in @($organManifest.sources)) {
    if ([string]$source.adoption -eq "deferred_reference" -and -not $IncludeDeferred) {
      Write-Host "skip deferred organ: $($source.organ_id)"
      continue
    }
    $items += [PSCustomObject]@{
      id = [string]$source.organ_id
      kind = "organ"
      repo_url = [string]$source.repo_url
      branch = [string]$source.branch
      commit = [string]$source.commit
      target_path = [string]$source.target_path
      adoption = [string]$source.adoption
    }
  }
  return $items
}

function Update-Checkout {
  param([Parameter(Mandatory = $true)]$Item)

  $target = Resolve-RepoPath ([string]$Item.target_path)
  $expected = [string]$Item.commit
  $branch = [string]$Item.branch
  $label = "$($Item.kind):$($Item.id)"

  if ($VerifyRemote) {
    Test-RemotePin -Item $Item
  }

  if (-not (Test-Path -LiteralPath $target -PathType Container)) {
    Write-Warning "hold missing checkout: $label -> $target"
    return "held"
  }
  if (-not (Test-Path -LiteralPath (Join-Path $target ".git"))) {
    Write-Warning "hold non-git checkout path: $label -> $target"
    return "held"
  }

  $dirty = git -C $target status --porcelain
  if (-not [string]::IsNullOrWhiteSpace(($dirty -join ""))) {
    Write-Warning "hold dirty checkout: $label"
    return "held"
  }

  $currentBranch = git -C $target branch --show-current
  if ($currentBranch -ne $branch) {
    Write-Warning "hold branch mismatch for ${label}: expected $branch, got $currentBranch"
    return "held"
  }

  $head = git -C $target rev-parse HEAD
  if ($head -eq $expected) {
    Write-Host "up-to-date: $label $($expected.Substring(0, 7))"
    return "up_to_date"
  }

  if ($DryRun) {
    Write-Host "update planned: $label $($head.Substring(0, 7)) -> $($expected.Substring(0, 7))"
    Invoke-Step -Command @("git", "-C", $target, "fetch", "origin", $branch)
    Invoke-Step -Command @("git", "-C", $target, "merge", "--ff-only", $expected)
    return "planned"
  }

  Invoke-GitChecked -Arguments @("-C", $target, "fetch", "origin", $branch)
  Invoke-GitChecked -Arguments @("-C", $target, "cat-file", "-e", "$expected^{commit}")
  git -C $target merge-base --is-ancestor $head $expected
  if ($LASTEXITCODE -ne 0) {
    Write-Warning "hold non-fast-forward update: $label $($head.Substring(0, 7)) -> $($expected.Substring(0, 7))"
    return "held"
  }

  Invoke-GitChecked -Arguments @("-C", $target, "merge", "--ff-only", $expected)
  $newHead = git -C $target rev-parse HEAD
  if ($newHead -ne $expected) {
    throw "update did not reach manifest pin for ${label}: expected $expected, got $newHead"
  }
  Write-Host "updated: $label $($expected.Substring(0, 7))"
  return "updated"
}

function Invoke-EnvRender {
  $renderArgs = @("-NoProfile", "-File", (Join-Path $PSScriptRoot "render-env-files.ps1"), "-Profile", $Profile)
  if (-not [string]::IsNullOrWhiteSpace($DistributionManifestPath)) {
    $renderArgs += @("-DistributionManifestPath", $DistributionManifestPath)
  }
  if ($DryRun) {
    $renderArgs += "-DryRun"
  }
  if ($ForceEnv) {
    $renderArgs += "-Force"
  }
  Invoke-Step -Command (@("pwsh") + $renderArgs)
}

function Invoke-DependencyInstall {
  param([Parameter(Mandatory = $true)]$Manifest)
  foreach ($dep in @($Manifest.dependencies)) {
    $id = [string]$dep.id
    $path = Resolve-RepoPath ([string]$dep.path)
    $command = @($dep.command | ForEach-Object { [string]$_ })
    if ($command.Count -eq 0) {
      Write-Host "dependency skip: $id (no command)"
      continue
    }
    if (-not (Test-Path -LiteralPath $path -PathType Container)) {
      Write-Warning "dependency path missing for ${id}: $path"
      continue
    }
    Write-Host "dependency install: $id"
    Invoke-Step -Command $command -WorkingDirectory $path
  }
}

if ([string]::IsNullOrWhiteSpace($DistributionManifestPath)) {
  $DistributionManifestPath = "manifests/distributions/$Profile.json"
}

$manifest = Read-JsonFile -Path $DistributionManifestPath

Write-Host "Sword Agent OS distribution update"
Write-Host "  Repo root: $RepoRoot"
Write-Host "  Profile  : $Profile"
Write-Host "  Manifest : $DistributionManifestPath"
Write-Host ""

$counts = @{
  planned = 0
  updated = 0
  up_to_date = 0
  held = 0
}

foreach ($item in @(Get-CheckoutItems -Manifest $manifest)) {
  $result = Update-Checkout -Item $item
  $counts[$result] = [int]$counts[$result] + 1
}

if (-not $NoEnv) {
  Write-Host ""
  Write-Host "Render missing local env/config files"
  Invoke-EnvRender
}
else {
  Write-Host "env rendering skipped: -NoEnv"
}

if (-not $NoDeps) {
  Write-Host ""
  Write-Host "Install/update dependencies"
  Invoke-DependencyInstall -Manifest $manifest
}
else {
  Write-Host "dependency install skipped: -NoDeps"
}

Write-Host ""
Write-Host "Validate manifests"
Invoke-Step -Command @("pwsh", "-NoProfile", "-File", (Join-Path $PSScriptRoot "validate-manifests.ps1"))

Write-Host ""
Write-Host "Update summary:"
Write-Host "  planned   : $($counts.planned)"
Write-Host "  updated   : $($counts.updated)"
Write-Host "  up-to-date: $($counts.up_to_date)"
Write-Host "  held      : $($counts.held)"
if ([int]$counts.held -gt 0) {
  Write-Host ""
  Write-Host "Some checkouts were held. Inspect their git status before updating them manually."
}
