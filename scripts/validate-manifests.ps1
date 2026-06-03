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

function Test-SafeManifestText {
  param([object]$Value)
  if ($null -eq $Value) {
    return $true
  }
  $text = [string]$Value
  if ($text.Length -gt 480) {
    return $false
  }
  if ($text -match "(?i)(api[_-]?key|x-api-key|access[_-]?token|refresh[_-]?token|secret|password|passwd|pwd|authorization\s*[:=]|bearer\s+[A-Za-z0-9._-]+)") {
    return $false
  }
  if ($text -match "(?i)(^|[_ -])(system|user|assistant)?[_ -]?prompt\s*[:=]") {
    return $false
  }
  if ($text -match "(^|[:=])[A-Za-z]:[\\/]") {
    return $false
  }
  if ($text -match "\\\\[^\\]+\\") {
    return $false
  }
  if ($text -match "(^|[:=])(/Users/|/home/|/mnt/|/var/|/tmp/|/etc/|~[\\/]|\.{1,2}[\\/])") {
    return $false
  }
  if ($text -match "(?i)(^|[\\/:=])[^\\/:=]+\.(log|jsonl|pcap|har)(\b|$)") {
    return $false
  }
  return $true
}

function Test-SafeManifestPath {
  param([string]$Path)
  if ([string]::IsNullOrWhiteSpace($Path)) {
    return $false
  }
  if ([System.IO.Path]::IsPathRooted($Path)) {
    return $false
  }
  $normalized = $Path -replace "\\", "/"
  if ($normalized -match "(^|/)\.\.(/|$)") {
    return $false
  }
  return Test-SafeManifestText -Value $Path
}

function Test-SemVer {
  param([string]$Value)
  if ([string]::IsNullOrWhiteSpace($Value)) {
    return $false
  }
  return $Value -match "^[0-9]+\.[0-9]+\.[0-9]+(?:[-+][0-9A-Za-z.-]+)?$"
}

function Test-SafeFixtureCandidate {
  param([string]$Path)
  if (-not (Test-SafeManifestPath -Path $Path)) {
    return $false
  }
  return ($Path -replace "\\", "/") -match "^\.cache/agent-os/fixtures/[A-Za-z0-9_.-]+\.(mp4|mov|webm|jpg|jpeg|png|webp)$"
}

function Read-LocalComponentVersion {
  param([Parameter(Mandatory = $true)][string]$Path)
  if (-not (Test-SafeManifestPath -Path $Path)) {
    return $null
  }
  $resolved = Resolve-ManifestPath $Path
  if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
    return $null
  }
  if ($Path -match "(?i)package\.json$") {
    $package = Read-Json -Path $resolved
    return [string]$package.version
  }
  if ($Path -match "(?i)pyproject\.toml$") {
    foreach ($line in Get-Content -LiteralPath $resolved) {
      if ($line -match '^\s*version\s*=\s*"([^"]+)"\s*$') {
        return $Matches[1]
      }
    }
  }
  return $null
}

function Get-UpstreamReleaseVersion {
  param(
    [Parameter(Mandatory = $true)]$Object,
    [Parameter(Mandatory = $true)][string]$Context
  )
  $versionLinkage = [string](Get-OptionalProperty -Object $Object -Name "version_linkage" -Default "")
  $upstreamRepoUrl = [string](Get-OptionalProperty -Object $Object -Name "upstream_repo_url" -Default "")
  $upstreamReleaseTag = [string](Get-OptionalProperty -Object $Object -Name "upstream_release_tag" -Default "")
  $upstreamReleaseUrl = [string](Get-OptionalProperty -Object $Object -Name "upstream_release_url" -Default "")

  Assert-True ($versionLinkage -eq "official-upstream-release-tag") "$Context has invalid version_linkage"
  Assert-True (-not [string]::IsNullOrWhiteSpace($upstreamRepoUrl)) "$Context missing upstream_repo_url"
  Assert-True (-not [string]::IsNullOrWhiteSpace($upstreamReleaseTag)) "$Context missing upstream_release_tag"
  Assert-True (-not [string]::IsNullOrWhiteSpace($upstreamReleaseUrl)) "$Context missing upstream_release_url"
  Assert-True (Test-SafeManifestText -Value $upstreamRepoUrl) "$Context upstream_repo_url is unsafe"
  Assert-True (Test-SafeManifestText -Value $upstreamReleaseTag) "$Context upstream_release_tag is unsafe"
  Assert-True (Test-SafeManifestText -Value $upstreamReleaseUrl) "$Context upstream_release_url is unsafe"
  Assert-True ($upstreamReleaseTag -match "^v?[0-9]+\.[0-9]+\.[0-9]+(?:[-+][0-9A-Za-z.-]+)?$") "$Context upstream_release_tag must be semver-like"
  $version = $upstreamReleaseTag -replace "^v", ""
  Assert-True (Test-SemVer -Value $version) "$Context upstream_release_tag must resolve to semver"
  return $version
}

function Test-SafeHttpPath {
  param([string]$Path)
  if ([string]::IsNullOrWhiteSpace($Path)) {
    return $true
  }
  $normalized = $Path -replace "\\", "/"
  if ($normalized -notmatch "^/[A-Za-z0-9._~!`$&'()*+,;=:@/-]+$") {
    return $false
  }
  if ($normalized -match "(^|/)\.\.(/|$)") {
    return $false
  }
  if ($normalized -match "//") {
    return $false
  }
  return $true
}

$standardProfile = Read-Json -Path (Resolve-ManifestPath "manifests/profiles/standard.json")
$compatProfile = Read-Json -Path (Resolve-ManifestPath "manifests/profiles/thought-core-v0-compat.json")
$serviceManifest = Read-Json -Path (Resolve-ManifestPath $compatProfile.service_manifest)
$organManifest = Read-Json -Path (Resolve-ManifestPath "manifests/organs/legacy-github.json")
$distributionManifest = Read-Json -Path (Resolve-ManifestPath "manifests/distributions/standard.json")
$releaseManifest = Read-Json -Path (Resolve-ManifestPath "manifests/releases/standard.json")
$controlPlaneReference = Read-Json -Path (Resolve-ManifestPath "manifests/legacy/control-plane-reference.json")
$recoveryCandidates = Read-Json -Path (Resolve-ManifestPath "manifests/legacy/recovery-candidates.json")
$authorityManifest = Read-Json -Path (Resolve-ManifestPath "manifests/authorities/standard.json")
$memoryStewardshipPolicy = Read-Json -Path (Resolve-ManifestPath "policies/data-safety/memory-stewardship.json")
$driverManifest = Read-Json -Path (Resolve-ManifestPath "manifests/drivers/standard.json")
$diagnosticPolicy = Read-Json -Path (Resolve-ManifestPath "manifests/diagnostics/standard.json")
$organTestPacks = Read-Json -Path (Resolve-ManifestPath "manifests/tests/organ-test-packs/standard.json")
$bodyPlan = Read-Json -Path (Resolve-ManifestPath "manifests/body-plans/system-cell-v0.json")
$actionDriverManifest = Read-Json -Path (Resolve-ManifestPath "manifests/driver-manifests/system-cell-v0.json")
$compatAliases = Read-Json -Path (Resolve-ManifestPath "manifests/compat-aliases/legacy-service-aliases.json")

$contractFiles = @(
  "contracts/action_request/action_request.v0.schema.json",
  "contracts/event_ingest/event_ingest.v0.schema.json",
  "contracts/status_patch/status_patch.v0.schema.json",
  "contracts/body_plan/body_plan.v0.schema.json",
  "contracts/driver_manifest/driver_manifest.v0.schema.json",
  "contracts/body_schema_snapshot/body_schema_snapshot.v0.schema.json",
  "contracts/body_display_projection/body_display_projection.v0.schema.json",
  "contracts/motion_stimulus/motion_stimulus.v0.schema.json",
  "contracts/motion_mixer_snapshot/motion_mixer_snapshot.v0.schema.json",
  "contracts/motion_driver_result/motion_driver_result.v0.schema.json",
  "contracts/motion_trace_event/motion_trace_event.v0.schema.json",
  "contracts/motion_memory_candidate/motion_memory_candidate.v0.schema.json"
)

$runtimeDirs = @(
  "runtime/routers/turn-router",
  "runtime/status-store",
  "runtime/process-registry",
  "runtime/event-journal",
  "runtime/diagnostic-scheduler",
  "runtime/organ-drivers",
  "runtime/organ-test-packs",
  "runtime/communication-governance",
  "runtime/memory-core",
  "runtime/approval-queue",
  "runtime/state-event-ingest",
  "runtime/action-catalog",
  "runtime/action-boundary",
  "runtime/body-schema",
  "runtime/body-display-projection",
  "runtime/motion-runtime"
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

foreach ($contractFile in $contractFiles) {
  $contractPath = Resolve-ManifestPath $contractFile
  Assert-True (Test-Path -LiteralPath $contractPath -PathType Leaf) "missing contract schema: $contractFile"
  $contract = Read-Json -Path $contractPath
  Assert-True ($null -ne $contract.PSObject.Properties["`$schema"]) "contract missing `$schema: $contractFile"
  Assert-True ($null -ne $contract.PSObject.Properties["`$id"]) "contract missing `$id: $contractFile"
  Assert-True ($null -ne $contract.title) "contract missing title: $contractFile"
}

Assert-True ([string]$bodyPlan.schema_version -eq "body_plan.v0") "body plan schema_version must be body_plan.v0"
Assert-True ([string]$bodyPlan.body_plan_id -eq "system_cell_v0") "body plan id must be system_cell_v0"
Assert-True ([string]$bodyPlan.body_plan_version -match "^[0-9]+\.[0-9]+\.[0-9]+$") "body plan version must be semver-like"
Assert-True (-not [string]::IsNullOrWhiteSpace([string]$bodyPlan.organism_id)) "body plan missing organism_id"
Assert-True (-not [string]::IsNullOrWhiteSpace([string]$bodyPlan.organism_name)) "body plan missing organism_name"
Assert-True ($null -eq $bodyPlan.agency_profile_id) "initial body plan should leave agency_profile_id null"

$bodyPlanContractValues = @($bodyPlan.compatible_contracts.PSObject.Properties | ForEach-Object { [string]$_.Value })
foreach ($requiredContract in @("action_request.v0", "event_ingest.v0", "status_patch.v0", "body_plan.v0", "driver_manifest.v0", "body_schema_snapshot.v0", "body_display_projection.v0")) {
  Assert-True ($requiredContract -in $bodyPlanContractValues) "body plan missing compatible contract: $requiredContract"
}

$bodyPlanOrganIds = @($bodyPlan.organs | ForEach-Object { [string]$_.organ_id })
Assert-True (($bodyPlanOrganIds | Select-Object -Unique).Count -eq $bodyPlanOrganIds.Count) "body plan organ_id values must be unique"
foreach ($organId in $bodyPlanOrganIds) {
  Assert-True ($organId -match "^[a-z][a-z0-9_.-]*$") "body plan has unsafe organ_id: $organId"
}
foreach ($requiredOrganId in @("thought.core", "reflex.core", "action.boundary", "environment.state", "sense.vision.primary", "display.projection", "memory.event_journal", "memory.status_store", "body.schema")) {
  Assert-True ($requiredOrganId -in $bodyPlanOrganIds) "body plan missing required organism organ: $requiredOrganId"
}

Assert-True ([string]$actionDriverManifest.schema_version -eq "driver_manifest.v0") "action driver manifest schema_version must be driver_manifest.v0"
Assert-True ([string]$actionDriverManifest.body_plan_id -eq [string]$bodyPlan.body_plan_id) "action driver manifest must match body plan id"
$actionDriverIds = @($actionDriverManifest.drivers | ForEach-Object { [string]$_.driver_id })
Assert-True (($actionDriverIds | Select-Object -Unique).Count -eq $actionDriverIds.Count) "action driver ids must be unique"
foreach ($organ in @($bodyPlan.organs)) {
  foreach ($driverRef in @($organ.driver_manifest_refs)) {
    Assert-True ([string]$driverRef -in $actionDriverIds) "body plan organ $($organ.organ_id) references unknown driver: $driverRef"
  }
}

$validDriverKinds = @("real", "dummy", "compat_adapter")
$validInstancePolicies = @("single", "multiple")
$validRiskClasses = @("internal", "reversible_external", "sensitive_external", "restricted")
$actionProviderCounts = @{}
foreach ($driver in $actionDriverManifest.drivers) {
  $driverId = [string]$driver.driver_id
  $driverKind = [string]$driver.driver_kind
  $driverOrganId = [string]$driver.organ_id
  $instancePolicy = [string]$driver.instance_policy
  Assert-True ($driverId -match "^[a-z][a-z0-9_.-]*$") "action driver has unsafe driver_id: $driverId"
  Assert-True ($driverKind -in $validDriverKinds) "action driver $driverId has invalid driver_kind: $driverKind"
  Assert-True ($instancePolicy -in $validInstancePolicies) "action driver $driverId has invalid instance_policy: $instancePolicy"
  Assert-True ($driverOrganId -in $bodyPlanOrganIds) "action driver $driverId references unknown body organ: $driverOrganId"

  foreach ($action in @($driver.provides_actions)) {
    $actionId = [string]$action.action_id
    Assert-True ($actionId -match "^[a-z][a-z0-9_.-]*$") "action driver $driverId has unsafe action_id: $actionId"
    Assert-True ([string]$action.risk_class -in $validRiskClasses) "action $actionId has invalid risk_class"
    Assert-True ($null -ne $action.parameter_schema) "action $actionId must declare parameter_schema"
    if ($driverKind -eq "dummy") {
      Assert-True ([bool]$action.dry_run) "dummy action $actionId must declare dry_run true"
    }
    if (-not $actionProviderCounts.ContainsKey($actionId)) {
      $actionProviderCounts[$actionId] = 0
    }
    if ($driverKind -ne "dummy") {
      $actionProviderCounts[$actionId]++
    }
  }
}
foreach ($entry in $actionProviderCounts.GetEnumerator()) {
  Assert-True ([int]$entry.Value -le 1) "action has multiple non-dummy providers: $($entry.Key)"
}

Assert-True ([string]$compatAliases.schema_version -eq "compat_aliases.v0") "compat aliases schema_version must be compat_aliases.v0"
foreach ($alias in @($compatAliases.aliases)) {
  Assert-True (-not [string]::IsNullOrWhiteSpace([string]$alias.legacy)) "compat alias missing legacy label"
  Assert-True ([string]$alias.canonical_organ_id -in $bodyPlanOrganIds) "compat alias references unknown canonical organ: $($alias.legacy)"
  if (-not [string]::IsNullOrWhiteSpace([string]$alias.canonical_driver_id)) {
    Assert-True ([string]$alias.canonical_driver_id -in $actionDriverIds) "compat alias references unknown canonical driver: $($alias.legacy)"
  }
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
Assert-True ([string]$organTestPacks.schema_version -eq "organ-test-packs.v0") "organ test packs schema_version must be organ-test-packs.v0"
Assert-True ([string]$organTestPacks.profile_id -eq [string]$compatProfile.id) "organ test packs profile_id must match compat profile id"
Assert-True ([string]$organTestPacks.service_manifest -eq [string]$compatProfile.service_manifest) "organ test packs must reference compat service manifest"
Assert-True ([string]$organTestPacks.driver_manifest -eq "manifests/drivers/standard.json") "organ test packs must reference standard driver manifest"
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
  foreach ($evidence in @(Get-OptionalProperty -Object $organDriver -Name "static_evidence" -Default @())) {
    $evidenceId = [string](Get-OptionalProperty -Object $evidence -Name "id" -Default "")
    Assert-True ($evidenceId -match "^[A-Za-z0-9_.-]+$") "organ driver $($organDriver.driver_id) has static evidence with unsafe id: $evidenceId"
    Assert-True ([string](Get-OptionalProperty -Object $evidence -Name "type" -Default "") -eq "path_exists") "organ driver $($organDriver.driver_id) has unsupported static evidence type"
    Assert-True (Test-SafeManifestPath -Path ([string](Get-OptionalProperty -Object $evidence -Name "path" -Default ""))) "organ driver $($organDriver.driver_id) has unsafe static evidence path"
  }
  Assert-True (@($organDriver.capabilities).Count -gt 0) "organ driver $($organDriver.driver_id) must declare capabilities"
}

$validTestModes = @("auto", "replay", "live", "manual", "deep")
$validTestTypes = @("path_exists", "diagnostics_service", "diagnostics_capability", "http_health", "websocket_health", "replay_fixture", "side_effect_gate", "manual_check", "command")
$declaredCapabilities = @($driverManifest.organ_drivers | ForEach-Object { $_.capabilities } | ForEach-Object { [string]$_ })
$testIds = @()
Assert-True (@($organTestPacks.packs).Count -ge 8) "organ test packs should cover the selected standard organs"
foreach ($pack in @($organTestPacks.packs)) {
  $packOrganId = [string]$pack.organ_id
  Assert-True (-not [string]::IsNullOrWhiteSpace($packOrganId)) "organ test pack missing organ_id"
  Assert-True (@($pack.tests).Count -gt 0) "organ test pack $packOrganId must declare tests"
  foreach ($serviceId in @($pack.service_ids | ForEach-Object { [string]$_ })) {
    Assert-True ($serviceId -in $serviceIds) "organ test pack $packOrganId references unknown service: $serviceId"
  }
  foreach ($capability in @($pack.capabilities | ForEach-Object { [string]$_ })) {
    Assert-True ($capability -in $declaredCapabilities) "organ test pack $packOrganId references unknown capability: $capability"
  }
  foreach ($test in @($pack.tests)) {
    $testId = [string]$test.id
    Assert-True (-not [string]::IsNullOrWhiteSpace($testId)) "organ test pack $packOrganId has test missing id"
    $testIds += $testId
    Assert-True ([string]$test.mode -in $validTestModes) "organ test $testId has invalid mode: $($test.mode)"
    Assert-True ([string]$test.type -in $validTestTypes) "organ test $testId has invalid type: $($test.type)"
    if ([string]$test.type -in @("diagnostics_service", "http_health", "websocket_health")) {
      Assert-True ([string]$test.service_id -in $serviceIds) "organ test $testId references unknown service: $($test.service_id)"
    }
    if ([string]$test.type -eq "diagnostics_capability") {
      Assert-True ([string]$test.capability -in $declaredCapabilities) "organ test $testId references unknown capability: $($test.capability)"
    }
    if ([string]$test.type -eq "path_exists" -and $null -ne $test.PSObject.Properties["missing_result"]) {
      Assert-True ([string]$test.missing_result -in @("fail", "blocked")) "organ test $testId has invalid missing_result: $($test.missing_result)"
    }
    if ([string]$test.type -eq "path_exists") {
      Assert-True (Test-SafeManifestPath -Path ([string]$test.path)) "organ test $testId has unsafe path_exists path"
    }
    if ([string]$test.type -eq "http_health" -and $null -ne $test.PSObject.Properties["path"]) {
      Assert-True (Test-SafeHttpPath -Path ([string]$test.path)) "organ test $testId has unsafe http_health path"
    }
    if ([string]$test.type -eq "replay_fixture") {
      Assert-True ([string]$test.fixture_label -match "^[A-Za-z0-9_-]+$") "organ test $testId must declare a safe fixture_label"
      foreach ($candidate in @($test.fixture_candidates | ForEach-Object { [string]$_ })) {
        Assert-True (Test-SafeFixtureCandidate -Path $candidate) "organ test $testId has unsafe replay fixture candidate: $candidate"
      }
    }
    if ([string]$test.type -eq "side_effect_gate") {
      Assert-True ([bool]$test.requires_side_effect_permission) "side-effect test $testId must require side-effect permission"
    }
    foreach ($field in @("instructions", "evidence_policy")) {
      $property = $test.PSObject.Properties[$field]
      if ($null -ne $property) {
        Assert-True (Test-SafeManifestText -Value $property.Value) "organ test $testId has unsafe text in $field"
      }
    }
  }
}
Assert-True (($testIds | Select-Object -Unique).Count -eq $testIds.Count) "organ test ids must be unique"

foreach ($source in $organManifest.sources) {
  Assert-True (-not [string]::IsNullOrWhiteSpace([string]$source.repo_url)) "organ $($source.organ_id) missing repo_url"
  Assert-True (-not [string]::IsNullOrWhiteSpace([string]$source.branch)) "organ $($source.organ_id) missing branch"
  Assert-True ([string]$source.commit -match "^[0-9a-f]{40}$") "organ $($source.organ_id) commit is not a full SHA"
  if ([string]$source.adoption -ne "deferred_reference") {
    Assert-True (Test-SemVer -Value ([string]$source.component_version)) "organ $($source.organ_id) component_version must be semver"
    Assert-True (Test-SafeManifestText -Value ([string]$source.version_source)) "organ $($source.organ_id) version_source is unsafe"
    if ([string](Get-OptionalProperty -Object $source -Name "version_linkage" -Default "") -eq "official-upstream-release-tag") {
      $sourceUpstreamVersion = Get-UpstreamReleaseVersion -Object $source -Context "organ $($source.organ_id)"
      Assert-True ([string]$source.component_version -eq $sourceUpstreamVersion) "organ $($source.organ_id) component_version must match upstream_release_tag"
    }
  }
}

Assert-True ([string]$distributionManifest.schema_version -eq "agent_os.distribution.v0") "distribution schema_version must be agent_os.distribution.v0"
Assert-True ([string]$distributionManifest.id -eq "standard") "standard distribution id must be standard"
Assert-True (Test-SemVer -Value ([string]$distributionManifest.os_version)) "standard distribution os_version must be semver"
Assert-True (Test-SemVer -Value ([string]$distributionManifest.distribution_version)) "standard distribution distribution_version must be semver"
Assert-True ([string]$distributionManifest.release_manifest_path -eq "manifests/releases/standard.json") "standard distribution release manifest mismatch"
Assert-True ([string]$distributionManifest.control_plane_manifest_path -eq "manifests/legacy/control-plane-reference.json") "standard distribution control-plane manifest mismatch"
Assert-True ([string]$distributionManifest.organ_manifest_path -eq "manifests/organs/legacy-github.json") "standard distribution organ manifest mismatch"
Assert-True (Test-SafeManifestPath -Path ([string]$distributionManifest.env.central_template_path)) "distribution central env template path is unsafe"
Assert-True (Test-SafeManifestPath -Path ([string]$distributionManifest.env.central_env_path)) "distribution central env path is unsafe"
Assert-True (Test-Path -LiteralPath (Resolve-ManifestPath ([string]$distributionManifest.env.central_template_path)) -PathType Leaf) "distribution central env template missing"
foreach ($target in @($distributionManifest.env.targets)) {
  Assert-True (-not [string]::IsNullOrWhiteSpace([string]$target.id)) "distribution env target missing id"
  Assert-True (Test-SafeManifestPath -Path ([string]$target.template_path)) "distribution env target $($target.id) has unsafe template_path"
  Assert-True (Test-SafeManifestPath -Path ([string]$target.target_path)) "distribution env target $($target.id) has unsafe target_path"
}
foreach ($copyTarget in @($distributionManifest.env.local_config_templates)) {
  Assert-True (-not [string]::IsNullOrWhiteSpace([string]$copyTarget.id)) "distribution local config target missing id"
  Assert-True (Test-SafeManifestPath -Path ([string]$copyTarget.template_path)) "distribution local config target $($copyTarget.id) has unsafe template_path"
  Assert-True (Test-SafeManifestPath -Path ([string]$copyTarget.target_path)) "distribution local config target $($copyTarget.id) has unsafe target_path"
}
foreach ($dependency in @($distributionManifest.dependencies)) {
  Assert-True (-not [string]::IsNullOrWhiteSpace([string]$dependency.id)) "distribution dependency missing id"
  Assert-True (Test-SafeManifestPath -Path ([string]$dependency.path)) "distribution dependency $($dependency.id) has unsafe path"
  foreach ($part in @($dependency.command | ForEach-Object { [string]$_ })) {
    Assert-True ($part -notmatch "[`r`n]") "distribution dependency $($dependency.id) command contains newline"
  }
}
Assert-True (Test-Path -LiteralPath (Join-Path $RepoRoot "scripts/install-distribution.ps1") -PathType Leaf) "distribution installer missing"
Assert-True (Test-Path -LiteralPath (Join-Path $RepoRoot "scripts/update-distribution.ps1") -PathType Leaf) "distribution updater missing"
Assert-True (Test-Path -LiteralPath (Join-Path $RepoRoot "scripts/render-env-files.ps1") -PathType Leaf) "env renderer missing"
Assert-True (Test-Path -LiteralPath (Join-Path $RepoRoot "scripts/show-version.ps1") -PathType Leaf) "version reporter missing"
Assert-True (Test-Path -LiteralPath (Join-Path $RepoRoot "scripts/test-distribution-maintenance.ps1") -PathType Leaf) "distribution maintenance test missing"

Assert-True ([string]$releaseManifest.schema_version -eq "agent_os.release.v0") "release schema_version must be agent_os.release.v0"
Assert-True ([string]$releaseManifest.os_id -eq "sword-agent-os") "release os_id must be sword-agent-os"
Assert-True ([string]$releaseManifest.distribution_id -eq [string]$distributionManifest.id) "release distribution_id mismatch"
Assert-True ([string]$releaseManifest.os_version -eq [string]$distributionManifest.os_version) "release os_version must match distribution"
Assert-True ([string]$releaseManifest.distribution_version -eq [string]$distributionManifest.distribution_version) "release distribution_version must match distribution"
Assert-True (Test-SemVer -Value ([string]$releaseManifest.os_version)) "release os_version must be semver"
Assert-True (Test-SemVer -Value ([string]$releaseManifest.distribution_version)) "release distribution_version must be semver"
Assert-True ([string]$releaseManifest.body_plan_id -eq [string]$bodyPlan.body_plan_id) "release body_plan_id mismatch"
Assert-True ([string]$releaseManifest.body_plan_version -eq [string]$bodyPlan.body_plan_version) "release body_plan_version mismatch"
$releaseComponentIds = @($releaseManifest.components | ForEach-Object { [string]$_.component_id })
Assert-True (($releaseComponentIds | Select-Object -Unique).Count -eq $releaseComponentIds.Count) "release component ids must be unique"
Assert-True ([string]$controlPlaneReference.id -in $releaseComponentIds) "release missing control-plane component"
foreach ($source in @($organManifest.sources | Where-Object { [string]$_.adoption -ne "deferred_reference" })) {
  Assert-True ([string]$source.organ_id -in $releaseComponentIds) "release missing organ component: $($source.organ_id)"
}
foreach ($component in @($releaseManifest.components)) {
  Assert-True (-not [string]::IsNullOrWhiteSpace([string]$component.component_id)) "release component missing id"
  Assert-True (Test-SemVer -Value ([string]$component.component_version)) "release component $($component.component_id) version must be semver"
  Assert-True (Test-SafeManifestText -Value ([string]$component.version_source)) "release component $($component.component_id) version_source is unsafe"
  if ([string](Get-OptionalProperty -Object $component -Name "version_linkage" -Default "") -eq "official-upstream-release-tag") {
    $componentUpstreamVersion = Get-UpstreamReleaseVersion -Object $component -Context "release component $($component.component_id)"
    Assert-True ([string]$component.component_version -eq $componentUpstreamVersion) "release component $($component.component_id) version must match upstream_release_tag"
  }
  else {
    $localComponentVersion = Read-LocalComponentVersion -Path ([string]$component.version_source)
    if (-not [string]::IsNullOrWhiteSpace($localComponentVersion)) {
      Assert-True ([string]$component.component_version -eq $localComponentVersion) "release component $($component.component_id) version does not match $($component.version_source)"
    }
  }
}

Assert-True ([string]$controlPlaneReference.commit -match "^[0-9a-f]{40}$") "control-plane reference commit is not a full SHA"
Assert-True (-not [string]::IsNullOrWhiteSpace([string]$controlPlaneReference.target_path)) "control-plane reference missing target_path"
Assert-True (Test-SemVer -Value ([string]$controlPlaneReference.component_version)) "control-plane component_version must be semver"
Assert-True (Test-SafeManifestText -Value ([string]$controlPlaneReference.version_source)) "control-plane version_source is unsafe"
$controlPlaneReleaseComponent = $releaseManifest.components | Where-Object { [string]$_.component_id -eq [string]$controlPlaneReference.id } | Select-Object -First 1
Assert-True ($null -ne $controlPlaneReleaseComponent) "release missing control-plane version component"
Assert-True ([string]$controlPlaneReleaseComponent.component_version -eq [string]$controlPlaneReference.component_version) "control-plane component_version must match release"
foreach ($source in @($organManifest.sources | Where-Object { [string]$_.adoption -ne "deferred_reference" })) {
  $releaseComponent = $releaseManifest.components | Where-Object { [string]$_.component_id -eq [string]$source.organ_id } | Select-Object -First 1
  Assert-True ($null -ne $releaseComponent) "release missing organ version component: $($source.organ_id)"
  Assert-True ([string]$releaseComponent.component_version -eq [string]$source.component_version) "organ $($source.organ_id) component_version must match release"
  if ([string](Get-OptionalProperty -Object $source -Name "version_linkage" -Default "") -eq "official-upstream-release-tag") {
    Assert-True ([string](Get-OptionalProperty -Object $releaseComponent -Name "version_linkage" -Default "") -eq [string](Get-OptionalProperty -Object $source -Name "version_linkage" -Default "")) "organ $($source.organ_id) version_linkage must match release"
    Assert-True ([string](Get-OptionalProperty -Object $releaseComponent -Name "upstream_release_tag" -Default "") -eq [string](Get-OptionalProperty -Object $source -Name "upstream_release_tag" -Default "")) "organ $($source.organ_id) upstream_release_tag must match release"
  }
}

$aituberSource = $organManifest.sources | Where-Object { [string]$_.organ_id -eq "aituber-kit" } | Select-Object -First 1
$aituberRelease = $releaseManifest.components | Where-Object { [string]$_.component_id -eq "aituber-kit" } | Select-Object -First 1
Assert-True ($null -ne $aituberSource) "AITuberKit source manifest entry missing"
Assert-True ($null -ne $aituberRelease) "AITuberKit release component missing"
$aituberFields = @(
  "upstream_release_commit",
  "sword_adapter_version",
  "patchset_id",
  "patchset_version",
  "compatibility_status",
  "contract_test_pack",
  "proof_level",
  "runtime_reflection_status",
  "adapter_inventory_path"
)
foreach ($fieldName in $aituberFields) {
  $sourceValue = [string](Get-OptionalProperty -Object $aituberSource -Name $fieldName -Default "")
  $releaseValue = [string](Get-OptionalProperty -Object $aituberRelease -Name $fieldName -Default "")
  Assert-True (-not [string]::IsNullOrWhiteSpace($sourceValue)) "AITuberKit source missing $fieldName"
  Assert-True ($sourceValue -eq $releaseValue) "AITuberKit $fieldName must match release"
  Assert-True (Test-SafeManifestText -Value $sourceValue) "AITuberKit $fieldName is unsafe"
}
Assert-True ([string](Get-OptionalProperty -Object $aituberSource -Name "upstream_release_commit" -Default "") -match "^[0-9a-f]{40}$") "AITuberKit upstream_release_commit must be a full SHA"
Assert-True (Test-SemVer -Value ([string](Get-OptionalProperty -Object $aituberSource -Name "sword_adapter_version" -Default ""))) "AITuberKit sword_adapter_version must be semver"
Assert-True (Test-SemVer -Value ([string](Get-OptionalProperty -Object $aituberSource -Name "patchset_version" -Default ""))) "AITuberKit patchset_version must be semver"
Assert-True ([string](Get-OptionalProperty -Object $aituberSource -Name "proof_level" -Default "") -in @("source-static", "browser-local", "runtime-reflected", "live-pilot")) "AITuberKit proof_level is invalid"
Assert-True ([string](Get-OptionalProperty -Object $aituberSource -Name "runtime_reflection_status" -Default "") -in @("not-proven", "proven", "blocked", "not-required")) "AITuberKit runtime_reflection_status is invalid"
$aituberInventoryPath = [string](Get-OptionalProperty -Object $aituberSource -Name "adapter_inventory_path" -Default "")
Assert-True (Test-SafeManifestPath -Path $aituberInventoryPath) "AITuberKit adapter_inventory_path is unsafe"
Assert-True (Test-Path -LiteralPath (Resolve-ManifestPath $aituberInventoryPath) -PathType Leaf) "AITuberKit adapter inventory file missing"

Assert-True (Test-Path -LiteralPath (Join-Path $RepoRoot "scripts/system.ps1") -PathType Leaf) "runtime system facade missing"
Assert-True (Test-Path -LiteralPath (Join-Path $RepoRoot "scripts/check-runtime-reflex.ps1") -PathType Leaf) "runtime reflex checker missing"
Assert-True (Test-Path -LiteralPath (Join-Path $RepoRoot "scripts/check-conscious-readiness.ps1") -PathType Leaf) "conscious readiness checker missing"
Assert-True (Test-Path -LiteralPath (Join-Path $RepoRoot "scripts/check-organ-readiness.ps1") -PathType Leaf) "organ readiness checker missing"
Assert-True (Test-Path -LiteralPath (Join-Path $RepoRoot "scripts/check-launch-readiness.ps1") -PathType Leaf) "launch readiness checker missing"
Assert-True (Test-Path -LiteralPath (Join-Path $RepoRoot "scripts/start-launcher.ps1") -PathType Leaf) "launcher start wrapper missing"
Assert-True (Test-Path -LiteralPath (Join-Path $RepoRoot "scripts/stop-launcher.ps1") -PathType Leaf) "launcher stop wrapper missing"
Assert-True (Test-Path -LiteralPath (Join-Path $RepoRoot "scripts/prepare-compat-launch.ps1") -PathType Leaf) "compat launch preparation script missing"
Assert-True (Test-Path -LiteralPath (Join-Path $RepoRoot "scripts/prepare-aituberkit-sword-adapter.ps1") -PathType Leaf) "AITuberKit adapter preparation script missing"
Assert-True (Test-Path -LiteralPath (Join-Path $RepoRoot "scripts/run-compat-smoke.ps1") -PathType Leaf) "compat launch smoke script missing"
Assert-True (Test-Path -LiteralPath (Join-Path $RepoRoot "scripts/update-diagnostics-status.ps1") -PathType Leaf) "diagnostics status writer missing"
Assert-True (Test-Path -LiteralPath (Join-Path $RepoRoot "scripts/read-diagnostics-status.ps1") -PathType Leaf) "diagnostics status reader missing"
Assert-True (Test-Path -LiteralPath (Join-Path $RepoRoot "scripts/watch-diagnostics-status.ps1") -PathType Leaf) "diagnostics status watcher missing"
Assert-True (Test-Path -LiteralPath (Join-Path $RepoRoot "scripts/check-neural-monitoring-contract.ps1") -PathType Leaf) "neural monitoring contract checker missing"
Assert-True (Test-Path -LiteralPath (Join-Path $RepoRoot "scripts/run-organ-test-packs.ps1") -PathType Leaf) "organ test pack runner missing"
Assert-True (Test-Path -LiteralPath (Join-Path $RepoRoot "scripts/build-body-schema-snapshot.ps1") -PathType Leaf) "body schema snapshot builder missing"
Assert-True (Test-Path -LiteralPath (Join-Path $RepoRoot "runtime/diagnostic-scheduler/neural-monitoring-test-plan.v0.md") -PathType Leaf) "neural monitoring test plan missing"
Assert-True (Test-Path -LiteralPath (Join-Path $RepoRoot "runtime/organ-test-packs/README.md") -PathType Leaf) "organ test pack runtime README missing"

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
    if ([string](Get-OptionalProperty -Object $source -Name "version_linkage" -Default "") -eq "official-upstream-release-tag") {
      $upstreamRepoUrl = [string](Get-OptionalProperty -Object $source -Name "upstream_repo_url" -Default "")
      $upstreamReleaseTag = [string](Get-OptionalProperty -Object $source -Name "upstream_release_tag" -Default "")
      $tagLine = git ls-remote --tags $upstreamRepoUrl "refs/tags/$upstreamReleaseTag"
      Assert-True (-not [string]::IsNullOrWhiteSpace(($tagLine -join ""))) "upstream release tag not found for organ $($source.organ_id): $upstreamReleaseTag"
    }
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
  distributions = 1
  os_version = $releaseManifest.os_version
  distribution_version = $releaseManifest.distribution_version
  recovery_candidates = $recoveryCandidates.candidates.Count
  authorities = $authorityManifest.authorities.Count
  driver_count = $driverManifest.generic_drivers.Count + $driverManifest.organ_drivers.Count
  diagnostic_tiers = $diagnosticPolicy.tiers.Count
  remote_verified = [bool]$VerifyRemote
} | ConvertTo-Json
