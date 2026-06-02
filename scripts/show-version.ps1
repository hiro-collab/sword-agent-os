param(
  [string]$Profile = "standard",
  [string]$DistributionManifestPath = "",
  [switch]$Json
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

function Get-RepoRevision {
  try {
    $revision = (git -C $RepoRoot rev-parse --short HEAD 2>$null) -join ""
    if (-not [string]::IsNullOrWhiteSpace($revision)) {
      return $revision
    }
  }
  catch {
  }
  return "unknown"
}

if ([string]::IsNullOrWhiteSpace($DistributionManifestPath)) {
  $DistributionManifestPath = "manifests/distributions/$Profile.json"
}

$distribution = Read-JsonFile -Path $DistributionManifestPath
$releasePath = [string](Get-OptionalProperty -Object $distribution -Name "release_manifest_path" -Default "")
if ([string]::IsNullOrWhiteSpace($releasePath)) {
  throw "distribution has no release_manifest_path: $DistributionManifestPath"
}
$release = Read-JsonFile -Path $releasePath

$payload = [PSCustomObject]@{
  os_id = [string](Get-OptionalProperty -Object $release -Name "os_id" -Default "sword-agent-os")
  os_version = [string](Get-OptionalProperty -Object $release -Name "os_version" -Default "unknown")
  distribution_id = [string](Get-OptionalProperty -Object $release -Name "distribution_id" -Default $distribution.id)
  distribution_version = [string](Get-OptionalProperty -Object $release -Name "distribution_version" -Default "unknown")
  release_name = [string](Get-OptionalProperty -Object $release -Name "release_name" -Default "unknown")
  release_channel = [string](Get-OptionalProperty -Object $release -Name "release_channel" -Default "unknown")
  release_schema = [string](Get-OptionalProperty -Object $release -Name "schema_version" -Default "unknown")
  distribution_schema = [string](Get-OptionalProperty -Object $distribution -Name "schema_version" -Default "unknown")
  git_revision = Get-RepoRevision
  component_count = @($release.components).Count
  components = @($release.components)
}

if ($Json) {
  $payload | ConvertTo-Json -Depth 8
  return
}

Write-Host "Sword Agent OS version"
Write-Host ("  OS           : {0} {1}" -f $payload.os_id, $payload.os_version)
Write-Host ("  Distribution : {0} {1}" -f $payload.distribution_id, $payload.distribution_version)
Write-Host ("  Release      : {0} ({1})" -f $payload.release_name, $payload.release_channel)
Write-Host ("  Schemas      : {0} / {1}" -f $payload.release_schema, $payload.distribution_schema)
Write-Host ("  Git revision : {0}" -f $payload.git_revision)
Write-Host ("  Components   : {0}" -f $payload.component_count)
foreach ($component in @($payload.components)) {
  Write-Host ("    - {0} {1} [{2}]" -f $component.component_id, $component.component_version, $component.component_role)
}
