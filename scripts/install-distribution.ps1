param(
  [string]$Profile = "standard",
  [string]$DistributionManifestPath = "",
  [switch]$DryRun,
  [switch]$VerifyOnly,
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

function Test-ToolRequirements {
  param(
    [Parameter(Mandatory = $true)]$Manifest,
    [switch]$SkipDependencyTools
  )
  $missing = @()
  foreach ($tool in @(Get-OptionalProperty -Object $Manifest -Name "tool_requirements" -Default @())) {
    $command = [string]$tool.command
    $optional = [bool](Get-OptionalProperty -Object $tool -Name "optional" -Default $false)
    $requiredFor = [string](Get-OptionalProperty -Object $tool -Name "required_for" -Default "")
    if ($SkipDependencyTools -and ($requiredFor -match "(?i)dependencies|runtime")) {
      Write-Host "tool skipped: $command ($requiredFor)"
      continue
    }
    $found = Get-Command $command -ErrorAction SilentlyContinue
    if ($null -eq $found) {
      $label = if ($optional) { "optional missing" } else { "missing" }
      Write-Host "tool ${label}: $command ($($tool.required_for))"
      if (-not $optional) {
        $missing += $command
      }
    }
    else {
      Write-Host "tool ok: $command -> $($found.Source)"
    }
  }
  if ($missing.Count -gt 0 -and -not $DryRun) {
    throw "required tools missing: $($missing -join ', ')"
  }
}

function Invoke-Bootstrap {
  param([Parameter(Mandatory = $true)]$Manifest)
  $controlPlaneManifestPath = [string]$Manifest.control_plane_manifest_path
  $organManifestPath = [string]$Manifest.organ_manifest_path
  $includeDeferredByManifest = [bool](Get-OptionalProperty -Object $Manifest -Name "include_deferred_organs" -Default $false)
  $includeDeferredOrgans = $IncludeDeferred -or $includeDeferredByManifest

  $controlArgs = @("-NoProfile", "-File", (Join-Path $PSScriptRoot "bootstrap-control-plane.ps1"), "-ManifestPath", $controlPlaneManifestPath)
  $organArgs = @("-NoProfile", "-File", (Join-Path $PSScriptRoot "bootstrap-organs.ps1"), "-ManifestPath", $organManifestPath)
  if ($DryRun) {
    $controlArgs += "-DryRun"
    $organArgs += "-DryRun"
  }
  if ($VerifyRemote) {
    $controlArgs += "-VerifyRemote"
    $organArgs += "-VerifyRemote"
  }
  if ($includeDeferredOrgans) {
    $organArgs += "-IncludeDeferred"
  }

  Invoke-Step -Command (@("pwsh") + $controlArgs)
  Invoke-Step -Command (@("pwsh") + $organArgs)
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

function Write-ManualAssets {
  param([Parameter(Mandatory = $true)]$Manifest)
  Write-Host ""
  Write-Host "Manual assets / local secrets still required:"
  foreach ($asset in @(Get-OptionalProperty -Object $Manifest -Name "manual_assets" -Default @())) {
    Write-Host "- $($asset.id): $($asset.detail)"
  }
}

if ([string]::IsNullOrWhiteSpace($DistributionManifestPath)) {
  $DistributionManifestPath = "manifests/distributions/$Profile.json"
}

$manifest = Read-JsonFile -Path $DistributionManifestPath

Write-Host "Sword Agent OS distribution install"
Write-Host "  Repo root: $RepoRoot"
Write-Host "  Profile  : $Profile"
Write-Host "  Manifest : $DistributionManifestPath"
Write-Host ""

Test-ToolRequirements -Manifest $manifest -SkipDependencyTools:($NoDeps -or $VerifyOnly)

if ($VerifyOnly) {
  Write-Host ""
  Write-Host "VerifyOnly: checking manifests and organ readiness without cloning, env rendering, or dependency install."
  Invoke-Step -Command @("pwsh", "-NoProfile", "-File", (Join-Path $PSScriptRoot "validate-manifests.ps1"))
  Invoke-Step -Command @("pwsh", "-NoProfile", "-File", (Join-Path $PSScriptRoot "check-organ-readiness.ps1"))
  Write-ManualAssets -Manifest $manifest
  return
}

Write-Host ""
Write-Host "Bootstrap checkouts"
Invoke-Bootstrap -Manifest $manifest

if (-not $NoEnv) {
  Write-Host ""
  Write-Host "Render local env/config files"
  Invoke-EnvRender
}
else {
  Write-Host "env rendering skipped: -NoEnv"
}

if (-not $NoDeps) {
  Write-Host ""
  Write-Host "Install dependencies"
  Invoke-DependencyInstall -Manifest $manifest
}
else {
  Write-Host "dependency install skipped: -NoDeps"
}

Write-Host ""
Write-Host "Validate manifests"
Invoke-Step -Command @("pwsh", "-NoProfile", "-File", (Join-Path $PSScriptRoot "validate-manifests.ps1"))

Write-ManualAssets -Manifest $manifest

Write-Host ""
Write-Host "Done. Start the launcher with:"
Write-Host "  .\start-home-control-launcher.bat"
