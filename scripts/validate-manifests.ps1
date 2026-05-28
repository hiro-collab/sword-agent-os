param(
  [switch]$VerifyRemote
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$RepoRoot = Split-Path -Parent $PSScriptRoot

function Read-Json {
  param([Parameter(Mandatory = $true)][string]$Path)
  return Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json
}

function Resolve-ManifestPath {
  param([Parameter(Mandatory = $true)][string]$RelativePath)
  return Join-Path $RepoRoot ($RelativePath -replace "/", [System.IO.Path]::DirectorySeparatorChar)
}

function Assert-True {
  param(
    [Parameter(Mandatory = $true)][bool]$Condition,
    [Parameter(Mandatory = $true)][string]$Message
  )
  if (-not $Condition) {
    throw $Message
  }
}

$standardProfile = Read-Json -Path (Resolve-ManifestPath "manifests/profiles/standard.json")
$compatProfile = Read-Json -Path (Resolve-ManifestPath "manifests/profiles/thought-core-v0-compat.json")
$serviceManifest = Read-Json -Path (Resolve-ManifestPath $compatProfile.service_manifest)
$organManifest = Read-Json -Path (Resolve-ManifestPath "manifests/organs/legacy-github.json")
$controlPlaneReference = Read-Json -Path (Resolve-ManifestPath "manifests/legacy/control-plane-reference.json")

$runtimeDirs = @(
  "runtime/routers/turn-router",
  "runtime/status-store",
  "runtime/process-registry",
  "runtime/event-journal",
  "runtime/communication-governance",
  "runtime/memory-core",
  "runtime/approval-queue"
)
foreach ($dir in $runtimeDirs) {
  Assert-True (Test-Path -LiteralPath (Resolve-ManifestPath $dir)) "missing runtime directory: $dir"
}

foreach ($component in $standardProfile.required_runtime) {
  $known = @(
    "turn-router",
    "status-store",
    "process-registry",
    "event-journal",
    "communication-governance",
    "memory-core",
    "approval-queue"
  )
  Assert-True ($component -in $known) "standard profile has unknown runtime component: $component"
}

Assert-True ($compatProfile.required_services.Count -eq 8) "thought-core-v0-compat should require 8 services"
Assert-True ($serviceManifest.services.Count -eq 8) "thought-core-v0-compat service inventory should define 8 services"

$serviceIds = @($serviceManifest.services | ForEach-Object { $_.service_id })
foreach ($serviceId in $compatProfile.required_services) {
  Assert-True ($serviceId -in $serviceIds) "profile requires missing service: $serviceId"
}

$organIds = @($organManifest.sources | ForEach-Object { $_.organ_id })
$controlPlaneId = $controlPlaneReference.id
foreach ($service in $serviceManifest.services) {
  $organId = [string]$service.organ_id
  Assert-True (($organId -in $organIds) -or ($organId -eq $controlPlaneId)) "service $($service.service_id) references unknown organ/control-plane id: $organId"
  Assert-True (-not [string]::IsNullOrWhiteSpace([string]$service.layer)) "service $($service.service_id) missing layer"
  Assert-True (-not [string]::IsNullOrWhiteSpace([string]$service.health.type)) "service $($service.service_id) missing health type"
}

foreach ($source in $organManifest.sources) {
  Assert-True (-not [string]::IsNullOrWhiteSpace([string]$source.repo_url)) "organ $($source.organ_id) missing repo_url"
  Assert-True (-not [string]::IsNullOrWhiteSpace([string]$source.branch)) "organ $($source.organ_id) missing branch"
  Assert-True ([string]$source.commit -match "^[0-9a-f]{40}$") "organ $($source.organ_id) commit is not a full SHA"
}

Assert-True ([string]$controlPlaneReference.commit -match "^[0-9a-f]{40}$") "control-plane reference commit is not a full SHA"
Assert-True (-not [string]::IsNullOrWhiteSpace([string]$controlPlaneReference.target_path)) "control-plane reference missing target_path"
Assert-True (Test-Path -LiteralPath (Join-Path $RepoRoot "scripts/system.ps1") -PathType Leaf) "runtime system facade missing"

if ($VerifyRemote) {
  foreach ($source in $organManifest.sources) {
    $line = git ls-remote ([string]$source.repo_url) "refs/heads/$($source.branch)"
    Assert-True (-not [string]::IsNullOrWhiteSpace(($line -join ""))) "remote branch not found for organ $($source.organ_id): $($source.branch)"
    $remoteCommit = (($line | Select-Object -First 1) -split "`t")[0]
    Assert-True ($remoteCommit -eq [string]$source.commit) "remote commit mismatch for organ $($source.organ_id): expected $($source.commit), got $remoteCommit"
  }

  $cpLine = git ls-remote ([string]$controlPlaneReference.repo_url) "refs/heads/$($controlPlaneReference.branch)"
  Assert-True (-not [string]::IsNullOrWhiteSpace(($cpLine -join ""))) "control-plane remote branch not found: $($controlPlaneReference.branch)"
  $cpRemoteCommit = (($cpLine | Select-Object -First 1) -split "`t")[0]
  Assert-True ($cpRemoteCommit -eq [string]$controlPlaneReference.commit) "control-plane remote commit mismatch: expected $($controlPlaneReference.commit), got $cpRemoteCommit"
}

[PSCustomObject]@{
  status = "ok"
  standard_runtime = $standardProfile.required_runtime.Count
  compatibility_profile = $compatProfile.id
  services = $serviceManifest.services.Count
  organ_sources = $organManifest.sources.Count
  remote_verified = [bool]$VerifyRemote
} | ConvertTo-Json
