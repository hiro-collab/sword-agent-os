param(
  [Parameter(Position = 0)]
  [ValidateSet("status", "start", "stop")]
  [string]$Command = "status",
  [string]$Profile = "thought-core-v0-compat",
  [switch]$ManifestOnly,
  [switch]$DryRun,
  [switch]$LegacyDelegate,
  [switch]$Force,
  [int]$TimeoutMs = 1200,
  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]]$PassthroughArgs = @()
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

function Read-Json {
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

function New-ProfileSpec {
  param([Parameter(Mandatory = $true)][string]$ProfilePath)

  $profile = Read-Json -Path $ProfilePath
  $serviceManifestPath = [string](Get-OptionalProperty -Object $profile -Name "service_manifest" -Default "")
  if ([string]::IsNullOrWhiteSpace($serviceManifestPath)) {
    throw "Profile is not controllable yet because it has no service_manifest: $ProfilePath"
  }

  $serviceManifest = Read-Json -Path $serviceManifestPath
  $legacyProfileId = [string](Get-OptionalProperty -Object $serviceManifest -Name "legacy_profile_id" -Default "")
  if ([string]::IsNullOrWhiteSpace($legacyProfileId)) {
    $legacyProfileId = [string](Get-OptionalProperty -Object $profile -Name "id" -Default $Profile)
  }

  return [PSCustomObject]@{
    profile_path = Resolve-RepoPath $ProfilePath
    profile = $profile
    profile_id = [string](Get-OptionalProperty -Object $profile -Name "id" -Default "")
    service_manifest_path = Resolve-RepoPath $serviceManifestPath
    service_manifest = $serviceManifest
    legacy_profile_id = $legacyProfileId
  }
}

function Resolve-ProfileSpec {
  param([Parameter(Mandatory = $true)][string]$ProfileName)

  $directPath = Resolve-RepoPath "manifests/profiles/$ProfileName.json"
  if (Test-Path -LiteralPath $directPath -PathType Leaf) {
    return New-ProfileSpec -ProfilePath $directPath
  }

  $profileDir = Resolve-RepoPath "manifests/profiles"
  foreach ($file in Get-ChildItem -LiteralPath $profileDir -Filter "*.json" -File) {
    try {
      $candidate = New-ProfileSpec -ProfilePath $file.FullName
      if ($candidate.legacy_profile_id -eq $ProfileName) {
        return $candidate
      }
    }
    catch {
      continue
    }
  }

  throw "Profile not found: $ProfileName"
}

function Resolve-LegacySystemScript {
  param([Parameter(Mandatory = $true)]$Spec)

  $legacyReferencePath = [string](Get-OptionalProperty -Object $Spec.service_manifest -Name "legacy_reference" -Default "")
  if ([string]::IsNullOrWhiteSpace($legacyReferencePath)) {
    $legacyReferencePath = [string](Get-OptionalProperty -Object $Spec.profile -Name "legacy_reference" -Default "")
  }
  if ([string]::IsNullOrWhiteSpace($legacyReferencePath)) {
    throw "Profile has no legacy_reference: $($Spec.profile_id)"
  }

  $legacyReference = Read-Json -Path $legacyReferencePath
  $targetPath = [string](Get-OptionalProperty -Object $legacyReference -Name "target_path" -Default "")
  if ([string]::IsNullOrWhiteSpace($targetPath)) {
    throw "Legacy reference has no target_path: $legacyReferencePath"
  }

  $scriptPath = Join-Path (Resolve-RepoPath $targetPath) "ops\scripts\system.ps1"
  if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
    throw "Legacy control-plane script is missing: $scriptPath. Run scripts/bootstrap-control-plane.ps1 first."
  }
  return $scriptPath
}

function New-LegacyDelegateArguments {
  param([Parameter(Mandatory = $true)]$Spec)

  $arguments = [System.Collections.Generic.List[string]]::new()
  $arguments.Add($Command)
  $arguments.Add("-Profile")
  $arguments.Add([string]$Spec.legacy_profile_id)
  if ($Force.IsPresent) {
    $arguments.Add("-Force")
  }
  foreach ($argument in $PassthroughArgs) {
    $arguments.Add($argument)
  }
  return [string[]]$arguments.ToArray()
}

function Write-DelegatePlan {
  param(
    [Parameter(Mandatory = $true)]$Spec,
    [Parameter(Mandatory = $true)][string]$ScriptPath,
    [Parameter(Mandatory = $true)][string[]]$Arguments,
    [Parameter(Mandatory = $true)][string]$Mode
  )

  [PSCustomObject]@{
    command = $Command
    profile_id = [string]$Spec.profile_id
    legacy_profile_id = [string]$Spec.legacy_profile_id
    mode = $Mode
    delegate = [PSCustomObject]@{
      script = $ScriptPath
      arguments = @($Arguments)
    }
    native_status = [PSCustomObject]@{
      script = (Join-Path $PSScriptRoot "check-profile-health.ps1")
      manifest_only = [bool]$ManifestOnly
    }
  } | ConvertTo-Json -Depth 6
}

$spec = Resolve-ProfileSpec -ProfileName $Profile

if ($Command -eq "status") {
  $healthArgs = @{
    ProfilePath = [string]$spec.profile_path
    TimeoutMs = $TimeoutMs
  }
  if ($ManifestOnly) {
    $healthArgs.ManifestOnly = $true
  }
  & (Join-Path $PSScriptRoot "check-profile-health.ps1") @healthArgs
  if ($?) {
    exit 0
  }
  exit 1
}

$legacyScript = Resolve-LegacySystemScript -Spec $spec
$delegateArgs = New-LegacyDelegateArguments -Spec $spec

if ($DryRun) {
  $dryRunArgs = @($delegateArgs + "-DryRun")
  Write-DelegatePlan -Spec $spec -ScriptPath $legacyScript -Arguments $dryRunArgs -Mode "dry-run"
  exit 0
}

if (-not $LegacyDelegate) {
  Write-DelegatePlan -Spec $spec -ScriptPath $legacyScript -Arguments $delegateArgs -Mode "requires-legacy-delegate"
  throw "$Command for $($spec.profile_id) is currently delegated to the legacy control-plane checkout. Re-run with -LegacyDelegate to execute it."
}

& $legacyScript @delegateArgs
if ($?) {
  exit 0
}
exit 1
