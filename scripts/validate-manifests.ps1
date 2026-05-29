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
$driverManifest = Read-Json -Path (Resolve-ManifestPath "manifests/drivers/standard.json")
$diagnosticPolicy = Read-Json -Path (Resolve-ManifestPath "manifests/diagnostics/standard.json")

$runtimeDirs = @(
  "runtime/routers/turn-router",
  "runtime/status-store",
  "runtime/process-registry",
  "runtime/event-journal",
  "runtime/diagnostic-scheduler",
  "runtime/organ-drivers",
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
    "diagnostic-scheduler",
    "organ-drivers",
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
Assert-True ("basic_runtime_reflex" -in @($standardProfile.health_model.boot_critical_capabilities)) "standard profile must keep basic_runtime_reflex boot-critical"
Assert-True ([string]$standardProfile.health_model.minimum_alive_stage -eq "reflex_alive") "standard profile minimum alive stage should be reflex_alive"
Assert-True ([string]$standardProfile.health_model.minimum_ready_stage -eq "conscious_ready") "standard profile minimum ready stage should be conscious_ready"
Assert-True ([string]$standardProfile.health_model.full_ready_stage -eq "full_conscious_ready") "standard profile full ready stage should be full_conscious_ready"
Assert-True ([string]$standardProfile.port_policy.default_mode -eq "manifest_default") "standard profile default port mode should be manifest_default"
Assert-True ("isolated_override" -in @($standardProfile.port_policy.accepted_validation_modes)) "standard profile must accept isolated_override validation"
Assert-True ([string]$standardProfile.port_policy.parallel_validation_mode -eq "isolated_override") "standard profile parallel validation mode should be isolated_override"
Assert-True ("diagnostic-scheduler" -in @($standardProfile.required_runtime)) "standard profile must require diagnostic-scheduler"
Assert-True ("organ-drivers" -in @($standardProfile.required_runtime)) "standard profile must require organ-drivers"

$startupStages = @($standardProfile.health_model.startup_stages | ForEach-Object { [string]$_.stage })
foreach ($stage in @("nonresponsive", "reflex_alive", "conscious_ready", "full_conscious_ready")) {
  Assert-True ($stage -in $startupStages) "standard profile missing startup stage: $stage"
}

Assert-True ($compatProfile.required_services.Count -eq 8) "thought-core-v0-compat should require 8 services"
Assert-True ($serviceManifest.services.Count -eq 8) "thought-core-v0-compat service inventory should define 8 services"
Assert-True ("manifest_default" -in @($compatProfile.validation_policy.accepted_port_modes)) "compat profile must accept manifest_default port mode"
Assert-True ("isolated_override" -in @($compatProfile.validation_policy.accepted_port_modes)) "compat profile must accept isolated_override port mode"
Assert-True ([string]$compatProfile.validation_policy.final_standard_port_mode -eq "manifest_default") "compat final standard port mode should be manifest_default"
Assert-True ([string]$compatProfile.validation_policy.routine_smoke_port_mode -eq "isolated_override") "compat routine smoke port mode should be isolated_override"

$serviceIds = @($serviceManifest.services | ForEach-Object { $_.service_id })
foreach ($serviceId in $compatProfile.required_services) {
  Assert-True ($serviceId -in $serviceIds) "profile requires missing service: $serviceId"
}

$endpointServiceIds = @(
  $serviceManifest.services |
    Where-Object {
      $null -ne $_.health -and
      $null -ne $_.health.PSObject.Properties["url"] -and
      -not [string]::IsNullOrWhiteSpace([string]$_.health.url)
    } |
    ForEach-Object { [string]$_.service_id }
)
foreach ($modeName in @("manifest_default", "isolated_override")) {
  $modeProperty = $serviceManifest.port_modes.PSObject.Properties[$modeName]
  Assert-True ($null -ne $modeProperty) "service manifest missing port mode: $modeName"
  $mode = $modeProperty.Value
  Assert-True ($null -ne $mode.service_ports) "port mode $modeName missing service_ports"
  Assert-True ($null -ne $mode.auxiliary_ports) "port mode $modeName missing auxiliary_ports"
  foreach ($serviceId in $endpointServiceIds) {
    $portProperty = $mode.service_ports.PSObject.Properties[$serviceId]
    Assert-True ($null -ne $portProperty) "port mode $modeName missing service port: $serviceId"
    $port = [int]$portProperty.Value
    Assert-True ($port -ge 1 -and $port -le 65535) "port mode $modeName has invalid port for $serviceId"
  }
  $monitorPort = [int]$mode.auxiliary_ports.mediapipe_browser_monitor
  Assert-True ($monitorPort -ge 1 -and $monitorPort -le 65535) "port mode $modeName has invalid mediapipe_browser_monitor port"
}

$organIds = @($organManifest.sources | ForEach-Object { $_.organ_id })
$controlPlaneId = $controlPlaneReference.id
foreach ($service in $serviceManifest.services) {
  $organId = [string]$service.organ_id
  Assert-True (($organId -in $organIds) -or ($organId -eq $controlPlaneId)) "service $($service.service_id) references unknown organ/control-plane id: $organId"
  Assert-True (-not [string]::IsNullOrWhiteSpace([string]$service.layer)) "service $($service.service_id) missing layer"
  Assert-True (-not [string]::IsNullOrWhiteSpace([string]$service.health.type)) "service $($service.service_id) missing health type"
}

Assert-True ([string]$driverManifest.profile_id -eq [string]$compatProfile.id) "driver manifest profile_id must match compat profile id"
Assert-True ([string]$driverManifest.service_manifest -eq [string]$compatProfile.service_manifest) "driver manifest must reference compat service manifest"
Assert-True ([string]$driverManifest.diagnostic_policy -eq "manifests/diagnostics/standard.json") "driver manifest must reference standard diagnostics policy"
Assert-True ([string]$diagnosticPolicy.profile_id -eq [string]$compatProfile.id) "diagnostic policy profile_id must match compat profile id"
Assert-True ([string]$diagnosticPolicy.driver_manifest -eq "manifests/drivers/standard.json") "diagnostic policy must reference standard driver manifest"
Assert-True ([bool]$driverManifest.driver_contract.default_safety.read_only) "driver default safety must be read-only"
Assert-True (-not [bool]$driverManifest.driver_contract.default_safety.may_execute_actions) "diagnostic drivers must not execute actions"
Assert-True (-not [bool]$driverManifest.driver_contract.default_safety.may_stop_processes) "diagnostic drivers must not stop processes"
Assert-True ([bool]$diagnosticPolicy.safety.read_only) "diagnostic policy must be read-only"
Assert-True (-not [bool]$diagnosticPolicy.safety.may_execute_actions) "diagnostic policy must not execute actions"
Assert-True (-not [bool]$diagnosticPolicy.safety.may_stop_processes) "diagnostic policy must not stop processes"

$expectedDiagnosticTiers = @("instant", "light", "standard", "snapshot", "deep")
$driverTiers = @($driverManifest.driver_contract.tiers | ForEach-Object { [string]$_ })
$diagnosticTiers = @($diagnosticPolicy.tiers | ForEach-Object { [string]$_.tier })
foreach ($tier in $expectedDiagnosticTiers) {
  Assert-True ($tier -in $driverTiers) "driver manifest missing diagnostic tier: $tier"
  Assert-True ($tier -in $diagnosticTiers) "diagnostic policy missing tier: $tier"
}

$expectedOutputTypes = @("topology_observation", "capability_evidence", "event_projection", "health_evidence")
$driverOutputTypes = @($driverManifest.driver_contract.output_types | ForEach-Object { [string]$_ })
foreach ($outputType in $expectedOutputTypes) {
  Assert-True ($outputType -in $driverOutputTypes) "driver manifest missing output type: $outputType"
}

$diagnosticStateValues = @($diagnosticPolicy.observation_envelope.state_values | ForEach-Object { [string]$_ })
foreach ($state in @($driverManifest.driver_contract.capability_states | ForEach-Object { [string]$_ })) {
  Assert-True ($state -in $diagnosticStateValues) "diagnostic policy missing driver state value: $state"
}
foreach ($freshness in @("fresh", "stale", "missing", "unknown")) {
  Assert-True ($freshness -in @($diagnosticPolicy.observation_envelope.freshness_values | ForEach-Object { [string]$_ })) "diagnostic policy missing freshness value: $freshness"
}
Assert-True ([bool]$diagnosticPolicy.freshness_policy.state_and_freshness_are_separate) "diagnostic policy must separate state and freshness"
Assert-True ([bool]$diagnosticPolicy.freshness_policy.do_not_show_stale_available_as_currently_available) "stale available observations must not be shown as currently available"
Assert-True ([string]$diagnosticPolicy.stores.status_store.mode -eq "overwrite_latest") "status store must overwrite latest"
Assert-True ([int64]$diagnosticPolicy.stores.status_store.target_max_bytes -le 1048576) "status store target must stay under 1 MB"
Assert-True ([string]$diagnosticPolicy.stores.topology_store.mode -eq "overwrite_latest") "topology store must overwrite latest"
Assert-True ([int]$diagnosticPolicy.stores.event_journal.retention_days -eq 30) "event journal retention must be 30 days"
Assert-True ([string]$diagnosticPolicy.stores.event_journal.rotation -eq "daily") "event journal must rotate daily"
Assert-True ([string]$diagnosticPolicy.stores.event_journal.compression -eq "compress_after_rotation") "event journal must compress rotated files"
Assert-True ([int]$diagnosticPolicy.stores.event_journal.normal_success_heartbeat_seconds -ge 900) "normal success heartbeat should be sampled at 15 minutes or slower"
Assert-True ([int64]$diagnosticPolicy.stores.event_journal.target_max_uncompressed_bytes_per_day -le 314572800) "event journal daily target should stay at or below 300 MB"
Assert-True ([int]$diagnosticPolicy.stores.snapshots.retention_days -eq 7) "snapshot retention must be 7 days"
Assert-True ([int]$diagnosticPolicy.stores.evidence.retention_days -eq 30) "evidence retention must be 30 days"
Assert-True ([int64]$diagnosticPolicy.stores.evidence.max_total_bytes -eq 5368709120) "evidence store cap must be 5 GB"
Assert-True ([string]$diagnosticPolicy.stores.evidence.cap_priority -eq "max_total_bytes_before_age") "evidence store must prioritize size cap before age"
Assert-True ([bool]$diagnosticPolicy.viewer_policy.read_only) "diagnostics viewer policy must be read-only"

$genericDriverIds = @($driverManifest.generic_drivers | ForEach-Object { [string]$_.driver_id })
Assert-True (($genericDriverIds | Select-Object -Unique).Count -eq $genericDriverIds.Count) "generic driver ids must be unique"
foreach ($genericDriver in $driverManifest.generic_drivers) {
  Assert-True (-not [string]::IsNullOrWhiteSpace([string]$genericDriver.driver_id)) "generic driver missing driver_id"
  foreach ($tier in @($genericDriver.tiers | ForEach-Object { [string]$_ })) {
    Assert-True ($tier -in $driverTiers) "generic driver $($genericDriver.driver_id) references unknown tier: $tier"
  }
  foreach ($outputType in @($genericDriver.outputs | ForEach-Object { [string]$_ })) {
    Assert-True ($outputType -in $driverOutputTypes) "generic driver $($genericDriver.driver_id) references unknown output type: $outputType"
  }
}

$organDriverIds = @($driverManifest.organ_drivers | ForEach-Object { [string]$_.driver_id })
Assert-True (($organDriverIds | Select-Object -Unique).Count -eq $organDriverIds.Count) "organ driver ids must be unique"
foreach ($organDriver in $driverManifest.organ_drivers) {
  Assert-True (-not [string]::IsNullOrWhiteSpace([string]$organDriver.driver_id)) "organ driver missing driver_id"
  $driverOrganId = [string]$organDriver.organ_id
  Assert-True (($driverOrganId -in $organIds) -or ($driverOrganId -eq $controlPlaneId)) "organ driver $($organDriver.driver_id) references unknown organ/control-plane id: $driverOrganId"
  foreach ($targetService in @($organDriver.target_services | ForEach-Object { [string]$_ })) {
    Assert-True ($targetService -in $serviceIds) "organ driver $($organDriver.driver_id) references unknown service: $targetService"
  }
  foreach ($genericDriverId in @($organDriver.composes | ForEach-Object { [string]$_ })) {
    Assert-True ($genericDriverId -in $genericDriverIds) "organ driver $($organDriver.driver_id) composes unknown generic driver: $genericDriverId"
  }
  Assert-True (@($organDriver.capabilities).Count -gt 0) "organ driver $($organDriver.driver_id) must declare capabilities"
}

foreach ($source in $organManifest.sources) {
  Assert-True (-not [string]::IsNullOrWhiteSpace([string]$source.repo_url)) "organ $($source.organ_id) missing repo_url"
  Assert-True (-not [string]::IsNullOrWhiteSpace([string]$source.branch)) "organ $($source.organ_id) missing branch"
  Assert-True ([string]$source.commit -match "^[0-9a-f]{40}$") "organ $($source.organ_id) commit is not a full SHA"
}

Assert-True ([string]$controlPlaneReference.commit -match "^[0-9a-f]{40}$") "control-plane reference commit is not a full SHA"
Assert-True (-not [string]::IsNullOrWhiteSpace([string]$controlPlaneReference.target_path)) "control-plane reference missing target_path"
Assert-True (Test-Path -LiteralPath (Join-Path $RepoRoot "scripts/system.ps1") -PathType Leaf) "runtime system facade missing"
Assert-True (Test-Path -LiteralPath (Join-Path $RepoRoot "scripts/check-runtime-reflex.ps1") -PathType Leaf) "runtime reflex checker missing"
Assert-True (Test-Path -LiteralPath (Join-Path $RepoRoot "scripts/check-conscious-readiness.ps1") -PathType Leaf) "conscious readiness checker missing"
Assert-True (Test-Path -LiteralPath (Join-Path $RepoRoot "scripts/check-organ-readiness.ps1") -PathType Leaf) "organ readiness checker missing"
Assert-True (Test-Path -LiteralPath (Join-Path $RepoRoot "scripts/check-launch-readiness.ps1") -PathType Leaf) "launch readiness checker missing"
Assert-True (Test-Path -LiteralPath (Join-Path $RepoRoot "scripts/prepare-compat-launch.ps1") -PathType Leaf) "compat launch preparation script missing"
Assert-True (Test-Path -LiteralPath (Join-Path $RepoRoot "scripts/run-compat-smoke.ps1") -PathType Leaf) "compat launch smoke script missing"
Assert-True (Test-Path -LiteralPath (Join-Path $RepoRoot "scripts/update-diagnostics-status.ps1") -PathType Leaf) "diagnostics status writer missing"
Assert-True (Test-Path -LiteralPath (Join-Path $RepoRoot "scripts/read-diagnostics-status.ps1") -PathType Leaf) "diagnostics status reader missing"

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
  driver_count = $driverManifest.generic_drivers.Count + $driverManifest.organ_drivers.Count
  diagnostic_tiers = $diagnosticPolicy.tiers.Count
  remote_verified = [bool]$VerifyRemote
} | ConvertTo-Json
