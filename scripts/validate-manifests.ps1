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
$recoveryCandidates = Read-Json -Path (Resolve-ManifestPath "manifests/legacy/recovery-candidates.json")
$authorityManifest = Read-Json -Path (Resolve-ManifestPath "manifests/authorities/standard.json")
$memoryStewardshipPolicy = Read-Json -Path (Resolve-ManifestPath "policies/data-safety/memory-stewardship.json")

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

foreach ($component in $standardProfile.health_model.boot_critical_runtime) {
  Assert-True ($component -in $standardProfile.required_runtime) "boot-critical runtime is not required by standard profile: $component"
}

Assert-True ("minimum_turn_processing" -in @($standardProfile.health_model.boot_critical_capabilities)) "standard profile must keep minimum_turn_processing boot-critical"

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
Assert-True (Test-Path -LiteralPath (Join-Path $RepoRoot "scripts/check-launch-readiness.ps1") -PathType Leaf) "launch readiness checker missing"
Assert-True (Test-Path -LiteralPath (Join-Path $RepoRoot "scripts/prepare-compat-launch.ps1") -PathType Leaf) "compat launch preparation script missing"
Assert-True (Test-Path -LiteralPath (Join-Path $RepoRoot "scripts/run-compat-smoke.ps1") -PathType Leaf) "compat launch smoke script missing"

foreach ($candidate in $recoveryCandidates.candidates) {
  Assert-True (-not [string]::IsNullOrWhiteSpace([string]$candidate.repo_url)) "recovery candidate $($candidate.id) missing repo_url"
  Assert-True (-not [string]::IsNullOrWhiteSpace([string]$candidate.branch)) "recovery candidate $($candidate.id) missing branch"
  Assert-True ([string]$candidate.commit -match "^[0-9a-f]{40}$") "recovery candidate $($candidate.id) commit is not a full SHA"
  Assert-True ([string]$candidate.handling -match "^(inspect-and-recover-feature-elements|inspect-and-cherry-pick-candidate)$") "recovery candidate $($candidate.id) has invalid handling"
}

$authorityIds = @($authorityManifest.authorities | ForEach-Object { [string]$_.authority_id })
foreach ($requiredAuthority in @("memory-core", "approval-queue", "data-safety-policy")) {
  Assert-True ($requiredAuthority -in $authorityIds) "standard authorities missing: $requiredAuthority"
}
Assert-True ([string]$memoryStewardshipPolicy.recording_posture.default -eq "broad_recording_allowed") "memory stewardship policy should allow broad recording by default"
Assert-True ([string]$memoryStewardshipPolicy.forgetting.owner_runtime -eq "memory-core") "forgetting owner must be memory-core"
Assert-True ([string]$memoryStewardshipPolicy.forgetting.default_deletion_class -eq "autonomously_deletable") "default deletion class should be autonomously_deletable"
Assert-True ([string]$memoryStewardshipPolicy.forgetting.protected_deletion_class -eq "protected_requires_approval") "protected deletion class should require approval"

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

  foreach ($candidate in $recoveryCandidates.candidates) {
    $candidateLine = git ls-remote ([string]$candidate.repo_url) "refs/heads/$($candidate.branch)"
    Assert-True (-not [string]::IsNullOrWhiteSpace(($candidateLine -join ""))) "remote branch not found for recovery candidate $($candidate.id): $($candidate.branch)"
    $candidateRemoteCommit = (($candidateLine | Select-Object -First 1) -split "`t")[0]
    Assert-True ($candidateRemoteCommit -eq [string]$candidate.commit) "remote commit mismatch for recovery candidate $($candidate.id): expected $($candidate.commit), got $candidateRemoteCommit"
  }
}

[PSCustomObject]@{
  status = "ok"
  standard_runtime = $standardProfile.required_runtime.Count
  compatibility_profile = $compatProfile.id
  services = $serviceManifest.services.Count
  organ_sources = $organManifest.sources.Count
  recovery_candidates = $recoveryCandidates.candidates.Count
  authorities = $authorityManifest.authorities.Count
  remote_verified = [bool]$VerifyRemote
} | ConvertTo-Json
