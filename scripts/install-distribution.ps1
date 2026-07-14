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
. (Join-Path $PSScriptRoot "lib/common.ps1")

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
    $stepArgs = @()
    if ($Command.Count -gt 1) {
      $stepArgs = $Command[1..($Command.Count - 1)]
    }
    & $exe @stepArgs
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
      throw "command failed with exit code ${exitCode}: $($Command -join ' ')"
    }
  }
  finally {
    Pop-Location
  }
}

function Write-InstallText {
  param(
    [string]$Text = "",
    [ConsoleColor]$Color = [ConsoleColor]::Gray
  )
  if ([string]::IsNullOrEmpty($Text)) {
    Write-Host ""
  }
  else {
    Write-Host $Text -ForegroundColor $Color
  }
}

function Get-RepoRevision {
  try {
    $revision = (git -C $RepoRoot rev-parse --short HEAD 2>$null) -join ""
    if (-not [string]::IsNullOrWhiteSpace($revision)) {
      return "git $revision"
    }
  }
  catch {
  }
  return "unknown"
}

function Write-InstallBanner {
  param([Parameter(Mandatory = $true)]$Manifest)
  $modeParts = @()
  if ($DryRun) { $modeParts += "dry-run" }
  if ($VerifyOnly) { $modeParts += "verify-only" }
  if ($NoDeps) { $modeParts += "no-deps" }
  if ($NoEnv) { $modeParts += "no-env" }
  if ($ForceEnv) { $modeParts += "force-env" }
  if ($VerifyRemote) { $modeParts += "verify-remote" }
  if ($modeParts.Count -eq 0) {
    $modeParts += "install"
  }
  $modeLabel = $modeParts -join ", "
  $distributionId = [string](Get-OptionalProperty -Object $Manifest -Name "id" -Default $Profile)
  $schemaVersion = [string](Get-OptionalProperty -Object $Manifest -Name "schema_version" -Default "unknown-schema")
  $osVersion = [string](Get-OptionalProperty -Object $Manifest -Name "os_version" -Default "unknown")
  $distributionVersion = [string](Get-OptionalProperty -Object $Manifest -Name "distribution_version" -Default "unknown")
  $description = [string](Get-OptionalProperty -Object $Manifest -Name "description" -Default "Standard local Sword Agent OS distribution.")
  $releaseManifestPath = [string](Get-OptionalProperty -Object $Manifest -Name "release_manifest_path" -Default "")
  $releaseLabel = "unknown release"
  $componentLabel = "components listed in source manifests"
  if (-not [string]::IsNullOrWhiteSpace($releaseManifestPath)) {
    try {
      $releaseManifest = Read-JsonFile -Path $releaseManifestPath
      $releaseName = [string](Get-OptionalProperty -Object $releaseManifest -Name "release_name" -Default "unnamed release")
      $releaseSchema = [string](Get-OptionalProperty -Object $releaseManifest -Name "schema_version" -Default "unknown-schema")
      $releaseLabel = "$releaseName / $releaseSchema"
      $componentCount = @($releaseManifest.components).Count
      $componentLabel = "$componentCount pinned components"
    }
    catch {
      $releaseLabel = "release manifest unreadable: $releaseManifestPath"
    }
  }

  Write-InstallText "+------------------------------------------------------------+" Cyan
  Write-InstallText "| WELCOME TO SWORD AGENT OS                                 |" Cyan
  Write-InstallText "| Local AI body OS distribution setup                       |" DarkCyan
  Write-InstallText "+------------------------------------------------------------+" Cyan
  Write-InstallText ("  OS Version   : Sword Agent OS {0} ({1})" -f $osVersion, (Get-RepoRevision)) Yellow
  Write-InstallText ("  Distribution : {0} {1} / {2}" -f $distributionId, $distributionVersion, $schemaVersion) Yellow
  Write-InstallText ("  Release      : {0}" -f $releaseLabel) Yellow
  Write-InstallText ("  Components   : {0}" -f $componentLabel) Yellow
  Write-InstallText ("  Mode         : {0}" -f $modeLabel) Yellow
  Write-InstallText ("  About        : {0}" -f $description) Gray
  Write-InstallText ("  Repo         : {0}" -f $RepoRoot) DarkGray
  Write-InstallText ("  Manifest     : {0}" -f $DistributionManifestPath) DarkGray
  Write-InstallText ""
  Write-InstallText "This installer will prepare the control plane, organs, local env bridge, and dependency layer." Gray
  Write-InstallText "Secrets and machine-local values stay in local/ and generated .env files." Gray
}

function Write-InstallSection {
  param(
    [Parameter(Mandatory = $true)][string]$Index,
    [Parameter(Mandatory = $true)][string]$Title,
    [string]$Detail = ""
  )
  Write-InstallText ""
  Write-InstallText ("[{0}] {1}" -f $Index, $Title) Cyan
  if (-not [string]::IsNullOrWhiteSpace($Detail)) {
    Write-InstallText ("    {0}" -f $Detail) DarkGray
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
  $renderArgs = @(
    "-NoProfile",
    "-File",
    (Join-Path $PSScriptRoot "render-env-files.ps1"),
    "-Profile",
    $Profile,
    "-CreateCentralEnv"
  )
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
      $message = "dependency path missing for ${id}: $path"
      if ($DryRun) {
        Write-Warning "$message (dry-run expected before checkout/dependency bootstrap; no install was attempted)"
        continue
      }
      throw $message
    }
    Write-Host "dependency install: $id"
    Invoke-Step -Command $command -WorkingDirectory $path
  }
}

function Write-ManualAssets {
  param([Parameter(Mandatory = $true)]$Manifest)
  Write-Host ""
  Write-InstallText "Manual assets / local secrets still required:" Yellow
  foreach ($asset in @(Get-OptionalProperty -Object $Manifest -Name "manual_assets" -Default @())) {
    Write-Host "- $($asset.id): $($asset.detail)"
  }
}

if ([string]::IsNullOrWhiteSpace($DistributionManifestPath)) {
  $DistributionManifestPath = "manifests/distributions/$Profile.json"
}

$manifest = Read-JsonFile -Path $DistributionManifestPath

Write-InstallBanner -Manifest $manifest
if ($DryRun) {
  Write-InstallText "Dry run: planning only; no clone, env, dependency, or generated local file changes will be performed." Yellow
}

Write-InstallSection -Index "1/5" -Title "Tool preflight" -Detail "Checking required commands before touching the distribution."
Test-ToolRequirements -Manifest $manifest -SkipDependencyTools:($NoDeps -or $VerifyOnly)

if ($VerifyOnly) {
  Write-InstallSection -Index "2/5" -Title "Verification only" -Detail "Checking manifests and organ readiness without clone, env render, or dependency install."
  Invoke-Step -Command @("pwsh", "-NoProfile", "-File", (Join-Path $PSScriptRoot "validate-manifests.ps1"))
  Invoke-Step -Command @("pwsh", "-NoProfile", "-File", (Join-Path $PSScriptRoot "check-organ-readiness.ps1"))
  Write-ManualAssets -Manifest $manifest
  return
}

Write-InstallSection -Index "2/5" -Title "Bootstrap checkouts" -Detail "Preparing control plane and organ repositories."
Invoke-Bootstrap -Manifest $manifest

if (-not $NoEnv) {
  Write-InstallSection -Index "3/5" -Title "Local env bridge" -Detail "Rendering missing .env and local config files without overwriting by default."
  Invoke-EnvRender
}
else {
  Write-InstallSection -Index "3/5" -Title "Local env bridge" -Detail "Skipped by -NoEnv."
  Write-Host "env rendering skipped: -NoEnv"
}

if (-not $NoDeps) {
  Write-InstallSection -Index "4/5" -Title "Dependency layer" -Detail "Installing or refreshing Python and web dependencies."
  Invoke-DependencyInstall -Manifest $manifest
}
else {
  Write-InstallSection -Index "4/5" -Title "Dependency layer" -Detail "Skipped by -NoDeps."
  Write-Host "dependency install skipped: -NoDeps"
}

Write-InstallSection -Index "5/5" -Title "Manifest validation" -Detail "Checking that the assembled distribution still matches OS contracts."
Invoke-Step -Command @("pwsh", "-NoProfile", "-File", (Join-Path $PSScriptRoot "validate-manifests.ps1"))

Write-ManualAssets -Manifest $manifest

Write-Host ""
Write-InstallText "+------------------------------------------------------------+" Green
if ($DryRun) {
  Write-InstallText "| SWORD AGENT OS DRY RUN COMPLETE                           |" Green
}
else {
  Write-InstallText "| SWORD AGENT OS IS READY FOR FIRST LAUNCH                  |" Green
}
Write-InstallText "+------------------------------------------------------------+" Green
if ($DryRun) {
  Write-InstallText "Next command for real install:" Yellow
  Write-Host "  pwsh -NoProfile -File .\scripts\install-distribution.ps1 -Profile $Profile"
}
else {
  Write-InstallText "Next command:" Yellow
  Write-Host "  .\start-home-control-launcher.bat"
}
