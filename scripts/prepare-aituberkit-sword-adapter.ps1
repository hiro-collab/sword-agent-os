param(
  [string]$Profile = "standard",
  [string]$DistributionManifestPath = "",
  [string]$OrganId = "aituber-kit",
  [switch]$VerifyRemote,
  [switch]$Json,
  [switch]$DryRun
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
  $resolved = Resolve-RepoPath $Path
  if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
    throw "JSON file not found: $Path"
  }
  return Get-Content -Raw -LiteralPath $resolved | ConvertFrom-Json
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

function Assert-Text {
  param(
    [Parameter(Mandatory = $true)][string]$Value,
    [Parameter(Mandatory = $true)][string]$Name
  )
  if ([string]::IsNullOrWhiteSpace($Value)) {
    throw "missing $Name"
  }
  if ($Value -match "[`r`n]") {
    throw "unsafe newline in $Name"
  }
}

function Assert-SemVer {
  param(
    [Parameter(Mandatory = $true)][string]$Value,
    [Parameter(Mandatory = $true)][string]$Name
  )
  Assert-Text -Value $Value -Name $Name
  if ($Value -notmatch "^[0-9]+\.[0-9]+\.[0-9]+(?:[-+][0-9A-Za-z.-]+)?$") {
    throw "$Name must be semver: $Value"
  }
}

function Assert-Sha {
  param(
    [Parameter(Mandatory = $true)][string]$Value,
    [Parameter(Mandatory = $true)][string]$Name
  )
  Assert-Text -Value $Value -Name $Name
  if ($Value -notmatch "^[0-9a-f]{40}$") {
    throw "$Name must be a full git commit SHA"
  }
}

function Assert-RelativePath {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$Name
  )
  Assert-Text -Value $Path -Name $Name
  if ([System.IO.Path]::IsPathRooted($Path)) {
    throw "$Name must be repo-relative"
  }
  $normalized = $Path -replace "\\", "/"
  if ($normalized -match "(^|/)\.\.(/|$)") {
    throw "$Name must not traverse outside the repo"
  }
}

function Get-RemoteHead {
  param(
    [Parameter(Mandatory = $true)][string]$RepoUrl,
    [Parameter(Mandatory = $true)][string]$Ref
  )
  $line = git ls-remote $RepoUrl $Ref
  if ([string]::IsNullOrWhiteSpace(($line -join ""))) {
    return ""
  }
  return (($line | Select-Object -First 1) -split "`t")[0]
}

if ([string]::IsNullOrWhiteSpace($DistributionManifestPath)) {
  $DistributionManifestPath = "manifests/distributions/$Profile.json"
}

$distribution = Read-JsonFile -Path $DistributionManifestPath
$organManifestPath = [string]$distribution.organ_manifest_path
$releaseManifestPath = [string]$distribution.release_manifest_path
Assert-RelativePath -Path $organManifestPath -Name "organ_manifest_path"
Assert-RelativePath -Path $releaseManifestPath -Name "release_manifest_path"

$organManifest = Read-JsonFile -Path $organManifestPath
$releaseManifest = Read-JsonFile -Path $releaseManifestPath

$source = @($organManifest.sources | Where-Object { [string]$_.organ_id -eq $OrganId } | Select-Object -First 1)
if ($source.Count -eq 0) {
  throw "organ not found: $OrganId"
}
$source = $source[0]

$component = @($releaseManifest.components | Where-Object { [string]$_.component_id -eq $OrganId } | Select-Object -First 1)
if ($component.Count -eq 0) {
  throw "release component not found: $OrganId"
}
$component = $component[0]

$upstreamRepoUrl = [string](Get-OptionalProperty -Object $source -Name "upstream_repo_url" -Default "")
$upstreamReleaseTag = [string](Get-OptionalProperty -Object $source -Name "upstream_release_tag" -Default "")
$upstreamReleaseCommit = [string](Get-OptionalProperty -Object $source -Name "upstream_release_commit" -Default "")
$forkRepoUrl = [string]$source.repo_url
$forkBranch = [string]$source.branch
$forkCommit = [string]$source.commit
$adapterVersion = [string](Get-OptionalProperty -Object $source -Name "sword_adapter_version" -Default "")
$patchsetId = [string](Get-OptionalProperty -Object $source -Name "patchset_id" -Default "")
$patchsetVersion = [string](Get-OptionalProperty -Object $source -Name "patchset_version" -Default "")
$compatibilityStatus = [string](Get-OptionalProperty -Object $source -Name "compatibility_status" -Default "")
$contractTestPack = [string](Get-OptionalProperty -Object $source -Name "contract_test_pack" -Default "")
$proofLevel = [string](Get-OptionalProperty -Object $source -Name "proof_level" -Default "")
$runtimeReflectionStatus = [string](Get-OptionalProperty -Object $source -Name "runtime_reflection_status" -Default "")
$inventoryPath = [string](Get-OptionalProperty -Object $source -Name "adapter_inventory_path" -Default "")

Assert-Text -Value $upstreamRepoUrl -Name "upstream_repo_url"
Assert-Text -Value $upstreamReleaseTag -Name "upstream_release_tag"
Assert-Sha -Value $upstreamReleaseCommit -Name "upstream_release_commit"
Assert-Sha -Value $forkCommit -Name "fork commit"
Assert-SemVer -Value $adapterVersion -Name "sword_adapter_version"
Assert-Text -Value $patchsetId -Name "patchset_id"
Assert-SemVer -Value $patchsetVersion -Name "patchset_version"
Assert-Text -Value $compatibilityStatus -Name "compatibility_status"
Assert-Text -Value $contractTestPack -Name "contract_test_pack"
Assert-Text -Value $proofLevel -Name "proof_level"
Assert-Text -Value $runtimeReflectionStatus -Name "runtime_reflection_status"
Assert-RelativePath -Path $inventoryPath -Name "adapter_inventory_path"

if ([string](Get-OptionalProperty -Object $component -Name "upstream_release_commit" -Default "") -ne $upstreamReleaseCommit) {
  throw "release component upstream_release_commit does not match organ source"
}
if ([string](Get-OptionalProperty -Object $component -Name "fork_commit" -Default "") -ne $forkCommit) {
  throw "release component fork_commit does not match organ source commit"
}
foreach ($fieldName in @(
  "sword_adapter_version",
  "patchset_id",
  "patchset_version",
  "compatibility_status",
  "contract_test_pack",
  "proof_level",
  "runtime_reflection_status",
  "adapter_inventory_path"
)) {
  $sourceValue = [string](Get-OptionalProperty -Object $source -Name $fieldName -Default "")
  $componentValue = [string](Get-OptionalProperty -Object $component -Name $fieldName -Default "")
  if ($sourceValue -ne $componentValue) {
    throw "release component $fieldName does not match organ source"
  }
}

$inventoryExists = Test-Path -LiteralPath (Resolve-RepoPath $inventoryPath) -PathType Leaf
if (-not $inventoryExists) {
  throw "adapter inventory not found: $inventoryPath"
}

$remote = [ordered]@{}
if ($VerifyRemote) {
  $remote.upstream_tag_commit = Get-RemoteHead -RepoUrl $upstreamRepoUrl -Ref "refs/tags/$upstreamReleaseTag"
  $remote.fork_branch_commit = Get-RemoteHead -RepoUrl $forkRepoUrl -Ref "refs/heads/$forkBranch"
  if ([string]$remote.upstream_tag_commit -ne $upstreamReleaseCommit) {
    throw "upstream tag commit mismatch"
  }
  if ([string]$remote.fork_branch_commit -ne $forkCommit) {
    throw "fork branch commit mismatch"
  }
}

$payload = [PSCustomObject]@{
  mode = "dry-run-only"
  organ_id = $OrganId
  upstream_release_tag = $upstreamReleaseTag
  upstream_release_commit = $upstreamReleaseCommit
  fork_branch = $forkBranch
  fork_commit = $forkCommit
  sword_adapter_version = $adapterVersion
  patchset_id = $patchsetId
  patchset_version = $patchsetVersion
  compatibility_status = $compatibilityStatus
  contract_test_pack = $contractTestPack
  proof_level = $proofLevel
  runtime_reflection_status = $runtimeReflectionStatus
  adapter_inventory_path = $inventoryPath
  adapter_inventory_exists = $inventoryExists
  next_slices = @(
    "static contract tests",
    "pure query helper extraction",
    "HUD update-signal normalization",
    "runtime reflection proof after source adoption"
  )
  remote = $remote
}

if ($Json) {
  $payload | ConvertTo-Json -Depth 8
  return
}

Write-Host "AITuberKit Sword adapter prepare plan"
Write-Host ("  Mode                    : {0}" -f $payload.mode)
Write-Host ("  Organ                   : {0}" -f $payload.organ_id)
Write-Host ("  Upstream release        : {0} ({1})" -f $payload.upstream_release_tag, $payload.upstream_release_commit.Substring(0, 7))
Write-Host ("  Fork pin                : {0} {1}" -f $payload.fork_branch, $payload.fork_commit.Substring(0, 7))
Write-Host ("  Sword adapter           : {0}" -f $payload.sword_adapter_version)
Write-Host ("  Patchset                : {0} {1}" -f $payload.patchset_id, $payload.patchset_version)
Write-Host ("  Compatibility           : {0}" -f $payload.compatibility_status)
Write-Host ("  Contract test pack      : {0}" -f $payload.contract_test_pack)
Write-Host ("  Proof level             : {0}" -f $payload.proof_level)
Write-Host ("  Runtime reflection      : {0}" -f $payload.runtime_reflection_status)
Write-Host ("  Adapter inventory       : {0}" -f $payload.adapter_inventory_path)
Write-Host ""
Write-Host "No source rewrite is performed by this planner."
