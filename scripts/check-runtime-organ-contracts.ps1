param(
  [ValidateSet("all", "thought_core", "action_boundary", "environment_state", "diagnostics_metrics", "event_correlation")]
  [string]$Scope = "all",
  [string]$ServiceManifestPath = "manifests/services/standard.json",
  [string]$DiagnosticPolicyPath = "manifests/diagnostics/standard.json",
  [string]$TestPackPath = "manifests/tests/organ-test-packs/standard.json",
  [switch]$Json
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$RepoRoot = Split-Path -Parent $PSScriptRoot
$script:checks = [System.Collections.Generic.List[object]]::new()

function Resolve-RepoPath {
  param([Parameter(Mandatory = $true)][string]$Path)
  if ([System.IO.Path]::IsPathRooted($Path)) {
    return $Path
  }
  return Join-Path $RepoRoot ($Path -replace "/", [System.IO.Path]::DirectorySeparatorChar)
}

function Read-JsonFile {
  param([Parameter(Mandatory = $true)][string]$Path)
  $resolved = Resolve-RepoPath -Path $Path
  if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
    throw "required JSON file not found: $resolved"
  }
  return Get-Content -Raw -LiteralPath $resolved | ConvertFrom-Json
}

function Read-TextFile {
  param([Parameter(Mandatory = $true)][string]$Path)
  $resolved = Resolve-RepoPath -Path $Path
  if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
    return ""
  }
  return Get-Content -Raw -LiteralPath $resolved
}

function Get-OptionalProperty {
  param(
    [Parameter(Mandatory = $true)]$Object,
    [Parameter(Mandatory = $true)][string]$Name,
    [object]$Default = $null
  )
  if ($null -eq $Object) {
    return $Default
  }
  $property = $Object.PSObject.Properties[$Name]
  if ($null -eq $property -or $null -eq $property.Value) {
    return $Default
  }
  return $property.Value
}

function ConvertTo-StringArray {
  param([object]$Value)
  if ($null -eq $Value) {
    return @()
  }
  return @($Value | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

function Test-TextContains {
  param(
    [Parameter(Mandatory = $true)][string]$Text,
    [Parameter(Mandatory = $true)][string]$Needle
  )
  return $Text.IndexOf($Needle, [StringComparison]::OrdinalIgnoreCase) -ge 0
}

function Get-TextIndex {
  param(
    [Parameter(Mandatory = $true)][string]$Text,
    [Parameter(Mandatory = $true)][string]$Needle
  )
  return $Text.IndexOf($Needle, [StringComparison]::Ordinal)
}

function Add-Check {
  param(
    [Parameter(Mandatory = $true)][string]$ScopeName,
    [Parameter(Mandatory = $true)][string]$Id,
    [ValidateSet("pass", "fail")]
    [Parameter(Mandatory = $true)][string]$Status,
    [Parameter(Mandatory = $true)][string]$Detail,
    [string]$EvidenceRef = ""
  )
  $script:checks.Add([PSCustomObject]@{
    scope = $ScopeName
    id = $Id
    status = $Status
    detail = $Detail
    evidence_ref = $EvidenceRef
  }) | Out-Null
}

function Require-Condition {
  param(
    [Parameter(Mandatory = $true)][string]$ScopeName,
    [Parameter(Mandatory = $true)][string]$Id,
    [Parameter(Mandatory = $true)][bool]$Condition,
    [Parameter(Mandatory = $true)][string]$Detail,
    [string]$EvidenceRef = ""
  )
  if ($Condition) {
    Add-Check -ScopeName $ScopeName -Id $Id -Status "pass" -Detail $Detail -EvidenceRef $EvidenceRef
  }
  else {
    Add-Check -ScopeName $ScopeName -Id $Id -Status "fail" -Detail $Detail -EvidenceRef $EvidenceRef
  }
}

function Require-Path {
  param(
    [Parameter(Mandatory = $true)][string]$ScopeName,
    [Parameter(Mandatory = $true)][string]$Id,
    [Parameter(Mandatory = $true)][string]$Path
  )
  Require-Condition `
    -ScopeName $ScopeName `
    -Id $Id `
    -Condition (Test-Path -LiteralPath (Resolve-RepoPath -Path $Path) -PathType Leaf) `
    -Detail "required file exists: $Path" `
    -EvidenceRef "snapshot:source-tree"
}

function Find-Service {
  param([Parameter(Mandatory = $true)][string]$ServiceId)
  foreach ($service in @($script:serviceManifest.services)) {
    if ([string]$service.service_id -eq $ServiceId) {
      return $service
    }
  }
  return $null
}

function Find-Pack {
  param([Parameter(Mandatory = $true)][string]$OrganId)
  foreach ($pack in @($script:testPack.packs)) {
    if ([string]$pack.organ_id -eq $OrganId) {
      return $pack
    }
  }
  return $null
}

function Find-Test {
  param([Parameter(Mandatory = $true)][string]$TestId)
  foreach ($pack in @($script:testPack.packs)) {
    foreach ($test in @($pack.tests)) {
      if ([string]$test.id -eq $TestId) {
        return $test
      }
    }
  }
  return $null
}

function Test-ArrayContainsAll {
  param(
    [object]$Value,
    [Parameter(Mandatory = $true)][string[]]$Expected
  )
  $actual = ConvertTo-StringArray -Value $Value
  foreach ($item in $Expected) {
    if ($item -notin $actual) {
      return $false
    }
  }
  return $true
}

function Test-CommandTestScope {
  param(
    [Parameter(Mandatory = $true)][string]$TestId,
    [Parameter(Mandatory = $true)][string]$ExpectedScope
  )
  $test = Find-Test -TestId $TestId
  if ($null -eq $test) {
    return $false
  }
  $args = ConvertTo-StringArray -Value (Get-OptionalProperty -Object $test -Name "args" -Default @())
  return (
    [string](Get-OptionalProperty -Object $test -Name "type" -Default "") -eq "command" -and
    [string](Get-OptionalProperty -Object $test -Name "mode" -Default "") -eq "auto" -and
    [string](Get-OptionalProperty -Object $test -Name "executable" -Default "") -ne "" -and
    "-Scope" -in $args -and
    $ExpectedScope -in $args -and
    [int](Get-OptionalProperty -Object $test -Name "expect_exit_code" -Default 0) -eq 0
  )
}

function Test-SafeEvidenceSubject {
  param([Parameter(Mandatory = $true)][string]$Subject)
  if ([string]::IsNullOrWhiteSpace($Subject)) {
    return $false
  }
  if ($Subject -notmatch "^[a-z][a-z0-9_.-]*$") {
    return $false
  }
  return $true
}

function Test-EvidencePacketSubjectsAreSafe {
  param([Parameter(Mandatory = $true)]$Packet)
  $subjects = [System.Collections.Generic.List[string]]::new()
  $scope = Get-OptionalProperty -Object $Packet -Name "scope" -Default $null
  if ($null -ne $scope) {
    foreach ($subject in @(Get-OptionalProperty -Object $scope -Name "subjects" -Default @())) {
      $subjects.Add([string]$subject) | Out-Null
    }
  }
  foreach ($observation in @(Get-OptionalProperty -Object $Packet -Name "observations" -Default @())) {
    $subjects.Add([string](Get-OptionalProperty -Object $observation -Name "subject" -Default "")) | Out-Null
  }
  foreach ($conflict in @(Get-OptionalProperty -Object $Packet -Name "conflicts" -Default @())) {
    $subjects.Add([string](Get-OptionalProperty -Object $conflict -Name "subject" -Default "")) | Out-Null
  }
  if ($subjects.Count -eq 0) {
    return $false
  }
  foreach ($subject in $subjects) {
    if (-not (Test-SafeEvidenceSubject -Subject $subject)) {
      return $false
    }
  }
  return $true
}

function Invoke-ThoughtCoreChecks {
  $scopeName = "thought_core"
  $api = Find-Service -ServiceId "thought_core_api"
  $watcher = Find-Service -ServiceId "thought_core_watcher"
  $apiBehavior = Get-OptionalProperty -Object $api -Name "behavior" -Default ([PSCustomObject]@{})
  $watcherBehavior = Get-OptionalProperty -Object $watcher -Name "behavior" -Default ([PSCustomObject]@{})

  Require-Path -ScopeName $scopeName -Id "thought_core.loop_source" -Path "control-plane/core/services/thought-core/src/thought_core/loop.py"
  Require-Path -ScopeName $scopeName -Id "thought_core.tools_source" -Path "control-plane/core/services/thought-core/src/thought_core/tools.py"
  Require-Path -ScopeName $scopeName -Id "thought_core.readiness_source" -Path "control-plane/core/services/thought-core/src/thought_core/readiness.py"
  Require-Condition -ScopeName $scopeName -Id "thought_core.api_service_contracts" -Condition (
    $null -ne $api -and
    (Test-ArrayContainsAll -Value (Get-OptionalProperty -Object $api -Name "contracts" -Default @()) -Expected @("turn", "events", "tools", "environment", "home-control", "memory", "access-control"))
  ) -Detail "thought_core_api declares turn/events/tools/environment/home-control/memory/access-control contracts" -EvidenceRef "snapshot:service-manifest"
  Require-Condition -ScopeName $scopeName -Id "thought_core.api_behavior_contract" -Condition (
    [string](Get-OptionalProperty -Object $apiBehavior -Name "behavior_kind" -Default "") -eq "reasoning" -and
    [string](Get-OptionalProperty -Object $apiBehavior -Name "agency_mode" -Default "") -eq "voluntary"
  ) -Detail "thought_core_api remains a voluntary reasoning service" -EvidenceRef "snapshot:service-manifest"
  Require-Condition -ScopeName $scopeName -Id "thought_core.watcher_contracts" -Condition (
    $null -ne $watcher -and
    (Test-ArrayContainsAll -Value (Get-OptionalProperty -Object $watcher -Name "contracts" -Default @()) -Expected @("turn", "events", "expression"))
  ) -Detail "thought_core_watcher declares turn/events/expression routing contracts" -EvidenceRef "snapshot:service-manifest"
  Require-Condition -ScopeName $scopeName -Id "thought_core.watcher_behavior_contract" -Condition (
    [string](Get-OptionalProperty -Object $watcherBehavior -Name "behavior_kind" -Default "") -eq "routing" -and
    [string](Get-OptionalProperty -Object $watcherBehavior -Name "agency_mode" -Default "") -eq "autonomic"
  ) -Detail "thought_core_watcher remains an autonomic routing adapter" -EvidenceRef "snapshot:service-manifest"
  Require-Condition -ScopeName $scopeName -Id "thought_core.readiness_required_events" -Condition (
    (Test-TextContains -Text $script:readinessText -Needle "assistant.message") -and
    (Test-TextContains -Text $script:readinessText -Needle "turn.completed") -and
    (Test-TextContains -Text $script:readinessText -Needle "used_llm=False") -and
    (Test-TextContains -Text $script:readinessText -Needle "startup_stage")
  ) -Detail "deterministic readiness requires assistant.message/turn.completed and stays off the LLM path" -EvidenceRef "snapshot:thought-core-readiness"
  Require-Condition -ScopeName $scopeName -Id "thought_core.test_pack_runtime_contract" -Condition (
    Test-CommandTestScope -TestId "thought_core_api.runtime_contracts" -ExpectedScope "thought_core"
  ) -Detail "standard organ test pack includes the Thought Core runtime contract command" -EvidenceRef "snapshot:organ-test-pack"
  Require-Condition -ScopeName $scopeName -Id "thought_core.test_pack_conscious_readiness" -Condition (
    $null -ne (Find-Test -TestId "thought_core_api.conscious_readiness")
  ) -Detail "standard organ test pack retains the deterministic conscious readiness check" -EvidenceRef "snapshot:organ-test-pack"
}

function Invoke-ActionBoundaryChecks {
  $scopeName = "action_boundary"
  $service = Find-Service -ServiceId "home_assistant_bridge"
  $behavior = Get-OptionalProperty -Object $service -Name "behavior" -Default ([PSCustomObject]@{})
  $approvalMode = [string](Get-OptionalProperty -Object $behavior -Name "approval_mode" -Default "")
  $previewIndex = Get-TextIndex -Text $script:loopText -Needle 'stage="home.preview"'
  $executeIndex = Get-TextIndex -Text $script:loopText -Needle '"home.execute"'

  Require-Condition -ScopeName $scopeName -Id "action_boundary.service_contracts" -Condition (
    $null -ne $service -and
    (Test-ArrayContainsAll -Value (Get-OptionalProperty -Object $service -Name "contracts" -Default @()) -Expected @("home-control", "access-control"))
  ) -Detail "home_assistant_bridge declares home-control and access-control contracts" -EvidenceRef "snapshot:service-manifest"
  Require-Condition -ScopeName $scopeName -Id "action_boundary.service_behavior" -Condition (
    [string](Get-OptionalProperty -Object $behavior -Name "behavior_kind" -Default "") -eq "operation" -and
    [string](Get-OptionalProperty -Object $behavior -Name "risk_class" -Default "") -eq "action_catalog_defined" -and
    ($approvalMode -match "policy|confirmation")
  ) -Detail "home action execution remains catalog-defined and policy/confirmation gated" -EvidenceRef "snapshot:service-manifest"
  Require-Condition -ScopeName $scopeName -Id "action_boundary.diagnostics_no_execute" -Condition (
    [bool](Get-OptionalProperty -Object (Get-OptionalProperty -Object $script:diagnosticPolicy -Name "safety" -Default ([PSCustomObject]@{})) -Name "may_execute_actions" -Default $true) -eq $false
  ) -Detail "routine diagnostics are not allowed to execute home actions" -EvidenceRef "snapshot:diagnostics-policy"
  Require-Condition -ScopeName $scopeName -Id "action_boundary.tool_preview_execute_split" -Condition (
    (Test-TextContains -Text $script:toolsText -Needle "def home_preview") -and
    (Test-TextContains -Text $script:toolsText -Needle "/preview") -and
    (Test-TextContains -Text $script:toolsText -Needle "def home_execute") -and
    (Test-TextContains -Text $script:toolsText -Needle "/execute")
  ) -Detail "Thought Core tool adapter keeps preview and execute as separate bridge calls" -EvidenceRef "snapshot:thought-core-tools"
  Require-Condition -ScopeName $scopeName -Id "action_boundary.loop_orders_preview_before_execute" -Condition (
    $previewIndex -ge 0 -and $executeIndex -gt $previewIndex
  ) -Detail "Thought Loop routes home.preview before any home.execute call" -EvidenceRef "snapshot:thought-core-loop"
  Require-Condition -ScopeName $scopeName -Id "action_boundary.confirmation_loop_limits_documented" -Condition (
    (Test-TextContains -Text $script:actionBoundaryText -Needle "at most one appliance operation") -and
    (Test-TextContains -Text $script:actionBoundaryText -Needle "at most two post-operation state/effect checks") -and
    (Test-TextContains -Text $script:actionBoundaryText -Needle "zero automatic re-operation attempts")
  ) -Detail "Action Boundary documents RR-001 confirmation-loop limits" -EvidenceRef "snapshot:action-boundary-doc"
  Require-Condition -ScopeName $scopeName -Id "action_boundary.side_effect_gate" -Condition (
    [bool](Get-OptionalProperty -Object (Find-Test -TestId "home_assistant_bridge.reversible_light_action") -Name "requires_side_effect_permission" -Default $false)
  ) -Detail "live reversible home action test is still protected by side-effect permission" -EvidenceRef "snapshot:organ-test-pack"
  Require-Condition -ScopeName $scopeName -Id "action_boundary.test_pack_contract" -Condition (
    Test-CommandTestScope -TestId "home_assistant_bridge.action_boundary_contract" -ExpectedScope "action_boundary"
  ) -Detail "standard organ test pack includes the action-boundary no-side-effect command" -EvidenceRef "snapshot:organ-test-pack"
}

function Invoke-EnvironmentStateChecks {
  $scopeName = "environment_state"
  $service = Find-Service -ServiceId "environment_state_server"
  $stateApi = Get-OptionalProperty -Object $service -Name "state_api" -Default ([PSCustomObject]@{})
  $notes = [string](Get-OptionalProperty -Object $service -Name "notes" -Default "")

  Require-Path -ScopeName $scopeName -Id "environment_state.state_source" -Path "organs/environment/environment-state-server/src/environment_state_server/state.py"
  Require-Path -ScopeName $scopeName -Id "environment_state.feedback_source" -Path "organs/environment/environment-state-server/src/environment_state_server/feedback.py"
  Require-Path -ScopeName $scopeName -Id "environment_state.evidence_packet_schema" -Path "contracts/environment_evidence_packet/environment_evidence_packet.v0.schema.json"
  Require-Path -ScopeName $scopeName -Id "environment_state.external_observation_example" -Path "contracts/environment_evidence_packet/examples/home-control-external-observation.example.json"
  Require-Condition -ScopeName $scopeName -Id "environment_state.evidence_packet_contract" -Condition (
    (Test-TextContains -Text $script:evidencePacketSchemaText -Needle "environment_evidence_packet.v0") -and
    (Test-TextContains -Text $script:evidencePacketSchemaText -Needle "source_layer") -and
    (Test-TextContains -Text $script:evidencePacketSchemaText -Needle "home_assistant_vs_camera_vision_brightness") -and
    (Test-TextContains -Text $script:evidencePacketSchemaText -Needle "policy_switches") -and
    (Test-TextContains -Text $script:evidencePacketSchemaText -Needle "confirmation_loop")
  ) -Detail "Environment evidence packet preserves source layers, conflicts, policy switches, and confirmation loop limits" -EvidenceRef "snapshot:environment-evidence-packet-schema"
  Require-Condition -ScopeName $scopeName -Id "environment_state.evidence_packet_subject_redaction" -Condition (
    (Test-TextContains -Text $script:evidencePacketSchemaText -Needle '"pattern": "^[a-z][a-z0-9_.-]*$"') -and
    (Test-EvidencePacketSubjectsAreSafe -Packet $script:evidencePacketExample)
  ) -Detail "Environment evidence packet subjects use stable redacted labels, not path-like private strings" -EvidenceRef "snapshot:environment-evidence-packet-example"
  Require-Condition -ScopeName $scopeName -Id "environment_state.external_observation_contract" -Condition (
    (Test-TextContains -Text $script:externalObservationExampleText -Needle "environment_state") -and
    (Test-TextContains -Text $script:externalObservationExampleText -Needle "camera_vision") -and
    (Test-TextContains -Text $script:externalObservationExampleText -Needle "action_feedback") -and
    (Test-TextContains -Text $script:externalObservationExampleText -Needle "raw media is not stored") -and
    (-not (Test-TextContains -Text $script:externalObservationExampleText -Needle "external_sensor")) -and
    (-not (Test-TextContains -Text $script:externalObservationExampleText -Needle '"value_class": "moving"')) -and
    (-not (Test-TextContains -Text $script:externalObservationExampleText -Needle '"source_layer": "home_assistant"')) -and
    (-not (Test-TextContains -Text $script:externalObservationExampleText -Needle "token")) -and
    (-not (Test-TextContains -Text $script:externalObservationExampleText -Needle "ha_url")) -and
    (-not (Test-TextContains -Text $script:externalObservationExampleText -Needle "entity_id")) -and
    (-not (Test-TextContains -Text $script:externalObservationExampleText -Needle "raw_frame")) -and
    (-not (Test-TextContains -Text $script:externalObservationExampleText -Needle "raw_catalog")) -and
    (-not (Test-TextContains -Text $script:externalObservationExampleText -Needle "raw_response")) -and
    (-not (Test-TextContains -Text $script:externalObservationExampleText -Needle "C:\")) -and
    (-not (Test-TextContains -Text $script:externalObservationExampleText -Needle "Users\")) -and
    (Test-EvidencePacketSubjectsAreSafe -Packet $script:externalObservationExample)
  ) -Detail "external observation example keeps HA state proof separate and excludes raw/private fields" -EvidenceRef "snapshot:home-control-external-observation-example"
  Require-Condition -ScopeName $scopeName -Id "environment_state.service_contracts" -Condition (
    $null -ne $service -and
    (Test-ArrayContainsAll -Value (Get-OptionalProperty -Object $service -Name "contracts" -Default @()) -Expected @("environment", "reflex", "access-control"))
  ) -Detail "environment_state_server declares environment/reflex/access-control contracts" -EvidenceRef "snapshot:service-manifest"
  Require-Condition -ScopeName $scopeName -Id "environment_state.current_state_api" -Condition (
    [string](Get-OptionalProperty -Object $stateApi -Name "type" -Default "") -eq "http" -and
    (Test-TextContains -Text ([string](Get-OptionalProperty -Object $stateApi -Name "url" -Default "")) -Needle "/environment/current") -and
    (Test-TextContains -Text ([string](Get-OptionalProperty -Object $stateApi -Name "auth" -Default "")) -Needle "ENVIRONMENT_API_TOKEN")
  ) -Detail "environment current-state projection is exposed through a tokened HTTP state_api" -EvidenceRef "snapshot:service-manifest"
  Require-Condition -ScopeName $scopeName -Id "environment_state.authority_surfaces" -Condition (
    Test-ArrayContainsAll -Value (Get-OptionalProperty -Object $service -Name "authority_touched" -Default @()) -Expected @("environment_projection", "indicator_projection", "state_query_feedback")
  ) -Detail "environment service declares projection, indicator, and feedback authority surfaces" -EvidenceRef "snapshot:service-manifest"
  Require-Condition -ScopeName $scopeName -Id "environment_state.source_separation_note" -Condition (
    (Test-TextContains -Text $notes -Needle "Home Assistant") -and
    ((Test-TextContains -Text $notes -Needle "camera") -or (Test-TextContains -Text $notes -Needle "vision"))
  ) -Detail "service notes preserve Home Assistant vs camera/vision source separation" -EvidenceRef "snapshot:service-manifest"
  Require-Condition -ScopeName $scopeName -Id "environment_state.thought_core_feedback_loop" -Condition (
    (Test-TextContains -Text $script:toolsText -Needle "state_query_feedback") -and
    (Test-TextContains -Text $script:loopText -Needle "_post_action_room_light_feedback") -and
    (Test-TextContains -Text $script:loopText -Needle "_persist_state_query_feedback")
  ) -Detail "Thought Core can report state-query feedback without owning environment authority" -EvidenceRef "snapshot:thought-core-loop"
  Require-Condition -ScopeName $scopeName -Id "environment_state.test_pack_contract" -Condition (
    Test-CommandTestScope -TestId "environment_state_server.projection_feedback_contract" -ExpectedScope "environment_state"
  ) -Detail "standard organ test pack includes the environment projection/feedback contract command" -EvidenceRef "snapshot:organ-test-pack"
}

function Invoke-DiagnosticsMetricChecks {
  $scopeName = "diagnostics_metrics"
  $safety = Get-OptionalProperty -Object $script:diagnosticPolicy -Name "safety" -Default ([PSCustomObject]@{})
  $envelope = Get-OptionalProperty -Object $script:diagnosticPolicy -Name "observation_envelope" -Default ([PSCustomObject]@{})
  $freshnessPolicy = Get-OptionalProperty -Object $script:diagnosticPolicy -Name "freshness_policy" -Default ([PSCustomObject]@{})
  $stores = Get-OptionalProperty -Object $script:diagnosticPolicy -Name "stores" -Default ([PSCustomObject]@{})
  $statusStore = Get-OptionalProperty -Object $stores -Name "status_store" -Default ([PSCustomObject]@{})
  $topologyStore = Get-OptionalProperty -Object $stores -Name "topology_store" -Default ([PSCustomObject]@{})
  $eventJournal = Get-OptionalProperty -Object $stores -Name "event_journal" -Default ([PSCustomObject]@{})

  Require-Condition -ScopeName $scopeName -Id "diagnostics.read_only_policy" -Condition (
    [bool](Get-OptionalProperty -Object $safety -Name "read_only" -Default $false) -and
    [bool](Get-OptionalProperty -Object $safety -Name "may_execute_actions" -Default $true) -eq $false -and
    [bool](Get-OptionalProperty -Object $safety -Name "may_print_secrets" -Default $true) -eq $false
  ) -Detail "diagnostics policy is read-only, does not execute actions, and must not print secrets" -EvidenceRef "snapshot:diagnostics-policy"
  Require-Condition -ScopeName $scopeName -Id "diagnostics.state_values" -Condition (
    Test-ArrayContainsAll -Value (Get-OptionalProperty -Object $envelope -Name "state_values" -Default @()) -Expected @("available", "degraded", "unavailable", "blocked", "unknown")
  ) -Detail "diagnostic observation envelope carries available/degraded/unavailable/blocked/unknown" -EvidenceRef "snapshot:diagnostics-policy"
  Require-Condition -ScopeName $scopeName -Id "diagnostics.freshness_separate" -Condition (
    [bool](Get-OptionalProperty -Object $freshnessPolicy -Name "state_and_freshness_are_separate" -Default $false) -and
    [bool](Get-OptionalProperty -Object $freshnessPolicy -Name "do_not_show_stale_available_as_currently_available" -Default $false)
  ) -Detail "diagnostics policy keeps state and freshness separate" -EvidenceRef "snapshot:diagnostics-policy"
  Require-Condition -ScopeName $scopeName -Id "diagnostics.status_store_modes" -Condition (
    [string](Get-OptionalProperty -Object $statusStore -Name "mode" -Default "") -eq "overwrite_latest" -and
    [string](Get-OptionalProperty -Object $topologyStore -Name "mode" -Default "") -eq "overwrite_latest" -and
    [string](Get-OptionalProperty -Object $eventJournal -Name "mode" -Default "") -eq "append_normalized_events"
  ) -Detail "status/topology stores overwrite latest while event journal appends normalized events" -EvidenceRef "snapshot:diagnostics-policy"
  Require-Condition -ScopeName $scopeName -Id "diagnostics.metric_record_contract_doc" -Condition (
    (Test-TextContains -Text $script:metricDocText -Needle '"metric"') -and
    (Test-TextContains -Text $script:metricDocText -Needle '"subject"') -and
    (Test-TextContains -Text $script:metricDocText -Needle '"value"') -and
    (Test-TextContains -Text $script:metricDocText -Needle '"recorded_at"') -and
    (Test-TextContains -Text $script:metricDocText -Needle '"source"') -and
    (Test-TextContains -Text $script:metricDocText -Needle "evidence_refs")
  ) -Detail "metric record doc preserves required fields and typed evidence refs" -EvidenceRef "snapshot:metric-record-contract"
  Require-Condition -ScopeName $scopeName -Id "diagnostics.writer_exposes_current_metrics" -Condition (
    (Test-TextContains -Text $script:updateDiagnosticsText -Needle "New-MetricRecord") -and
    (Test-TextContains -Text $script:updateDiagnosticsText -Needle "metrics = [PSCustomObject]") -and
    (Test-TextContains -Text $script:updateDiagnosticsText -Needle "current = @(") -and
    (Test-TextContains -Text $script:updateDiagnosticsText -Needle "evidence_refs")
  ) -Detail "diagnostics writer emits topology metrics.current[] with evidence refs" -EvidenceRef "snapshot:diagnostics-writer"
  Require-Condition -ScopeName $scopeName -Id "diagnostics.neural_contract_checker" -Condition (
    (Test-TextContains -Text $script:neuralContractText -Needle "Test-EvidenceRefShape") -and
    (Test-TextContains -Text $script:neuralContractText -Needle "metrics.current") -and
    (Test-TextContains -Text $script:neuralContractText -Needle "status.invalid_service_state") -and
    (Test-TextContains -Text $script:neuralContractText -Needle "status.invalid_capability_state")
  ) -Detail "existing neural monitoring checker validates metrics.current, typed evidence refs, and policy-defined service/capability states" -EvidenceRef "snapshot:neural-monitoring-contract"
  Require-Condition -ScopeName $scopeName -Id "diagnostics.test_pack_contract" -Condition (
    Test-CommandTestScope -TestId "system_house_renderer.diagnostics_metric_contract" -ExpectedScope "diagnostics_metrics"
  ) -Detail "standard organ test pack includes the diagnostics metric contract command" -EvidenceRef "snapshot:organ-test-pack"
}

function Invoke-EventCorrelationChecks {
  $scopeName = "event_correlation"
  Require-Path -ScopeName $scopeName -Id "event_correlation.contract_doc" -Path "runtime/event-journal/correlation-spine.v0.md"
  Require-Condition -ScopeName $scopeName -Id "event_correlation.identity_fields" -Condition (
    (Test-TextContains -Text $script:correlationText -Needle "issue_ticket_id") -and
    (Test-TextContains -Text $script:correlationText -Needle "issue_ticket_ids") -and
    (Test-TextContains -Text $script:correlationText -Needle "ticket_status") -and
    (Test-TextContains -Text $script:correlationText -Needle "interpretation_id") -and
    (Test-TextContains -Text $script:correlationText -Needle "action_id")
  ) -Detail "correlation spine defines ticket, interpretation, and action identity surfaces" -EvidenceRef "snapshot:event-correlation-contract"
  Require-Condition -ScopeName $scopeName -Id "event_correlation.multi_turn_ticket_continuity" -Condition (
    (Test-TextContains -Text $script:correlationText -Needle "Multiple Turns, One Ticket") -and
    (Test-TextContains -Text $script:correlationText -Needle 'new `turn_id`') -and
    (Test-TextContains -Text $script:correlationText -Needle 'same `issue_ticket_id`') -and
    (Test-TextContains -Text $script:correlationText -Needle "turn_living_room_001") -and
    (Test-TextContains -Text $script:correlationText -Needle "turn_living_room_002") -and
    (Test-TextContains -Text $script:correlationText -Needle "ticket_living_room_light_001")
  ) -Detail "correlation spine preserves one unresolved issue ticket across multiple turns" -EvidenceRef "snapshot:event-correlation-contract"
  Require-Condition -ScopeName $scopeName -Id "event_correlation.state_semantics" -Condition (
    (Test-TextContains -Text $script:correlationText -Needle "blocked") -and
    (Test-TextContains -Text $script:correlationText -Needle "degraded") -and
    (Test-TextContains -Text $script:correlationText -Needle "needs_confirmation") -and
    (Test-TextContains -Text $script:correlationText -Needle "sources_disagree")
  ) -Detail "correlation contract names blocked/degraded/confirmation/source-conflict semantics" -EvidenceRef "snapshot:event-correlation-contract"
  Require-Condition -ScopeName $scopeName -Id "event_correlation.policy_switch_operation" -Condition (
    (Test-TextContains -Text $script:correlationText -Needle "policy_switch_operation") -and
    (Test-TextContains -Text $script:correlationText -Needle "selected policy") -and
    (Test-TextContains -Text $script:correlationText -Needle "automatic re-operation attempts")
  ) -Detail "correlation spine records conflict policy switches and bounded confirmation loops" -EvidenceRef "snapshot:event-correlation-contract"
  Require-Condition -ScopeName $scopeName -Id "event_correlation.typed_evidence_refs" -Condition (
    (Test-TextContains -Text $script:correlationText -Needle "event:") -and
    (Test-TextContains -Text $script:correlationText -Needle "snapshot:") -and
    (Test-TextContains -Text $script:correlationText -Needle "turn:") -and
    (Test-TextContains -Text $script:correlationText -Needle "action:") -and
    (Test-TextContains -Text $script:correlationText -Needle "evidence_refs")
  ) -Detail "correlation examples keep evidence as typed refs instead of raw logs/media" -EvidenceRef "snapshot:event-correlation-contract"
  Require-Condition -ScopeName $scopeName -Id "event_correlation.metrics_and_memory" -Condition (
    (Test-TextContains -Text $script:correlationText -Needle "metrics") -and
    (Test-TextContains -Text $script:correlationText -Needle "memory") -and
    (Test-TextContains -Text $script:correlationText -Needle "retag") -and
    (Test-TextContains -Text $script:correlationText -Needle "provenance")
  ) -Detail "correlation spine links event, metric, and memory retagging surfaces" -EvidenceRef "snapshot:event-correlation-contract"
  Require-Condition -ScopeName $scopeName -Id "event_correlation.test_pack_contract" -Condition (
    Test-CommandTestScope -TestId "thought_core_api.event_correlation_contract" -ExpectedScope "event_correlation"
  ) -Detail "standard organ test pack includes the event/ticket correlation contract command" -EvidenceRef "snapshot:organ-test-pack"
}

$script:serviceManifest = Read-JsonFile -Path $ServiceManifestPath
$script:diagnosticPolicy = Read-JsonFile -Path $DiagnosticPolicyPath
$script:testPack = Read-JsonFile -Path $TestPackPath
$script:readinessText = Read-TextFile -Path "control-plane/core/services/thought-core/src/thought_core/readiness.py"
$script:loopText = Read-TextFile -Path "control-plane/core/services/thought-core/src/thought_core/loop.py"
$script:toolsText = Read-TextFile -Path "control-plane/core/services/thought-core/src/thought_core/tools.py"
$script:metricDocText = Read-TextFile -Path "runtime/status-store/metric-records.v0.md"
$script:correlationText = Read-TextFile -Path "runtime/event-journal/correlation-spine.v0.md"
$script:actionBoundaryText = Read-TextFile -Path "runtime/action-boundary/README.md"
$script:evidencePacketSchemaText = Read-TextFile -Path "contracts/environment_evidence_packet/environment_evidence_packet.v0.schema.json"
$script:evidencePacketExample = Read-JsonFile -Path "contracts/environment_evidence_packet/examples/rr001-home-assistant-camera-conflict.example.json"
$script:externalObservationExampleText = Read-TextFile -Path "contracts/environment_evidence_packet/examples/home-control-external-observation.example.json"
$script:externalObservationExample = Read-JsonFile -Path "contracts/environment_evidence_packet/examples/home-control-external-observation.example.json"
$script:updateDiagnosticsText = Read-TextFile -Path "scripts/update-diagnostics-status.ps1"
$script:neuralContractText = Read-TextFile -Path "scripts/check-neural-monitoring-contract.ps1"

$scopesToRun = if ($Scope -eq "all") {
  @("thought_core", "action_boundary", "environment_state", "diagnostics_metrics", "event_correlation")
}
else {
  @($Scope)
}

foreach ($scopeName in $scopesToRun) {
  switch ($scopeName) {
    "thought_core" { Invoke-ThoughtCoreChecks }
    "action_boundary" { Invoke-ActionBoundaryChecks }
    "environment_state" { Invoke-EnvironmentStateChecks }
    "diagnostics_metrics" { Invoke-DiagnosticsMetricChecks }
    "event_correlation" { Invoke-EventCorrelationChecks }
  }
}

$failures = @($script:checks | Where-Object { $_.status -eq "fail" })
$resultStatus = if ($failures.Count -gt 0) { "failed" } else { "ok" }
$result = [PSCustomObject]@{
  status = $resultStatus
  scope = $Scope
  checks = $script:checks.Count
  failed = $failures.Count
  results = @($script:checks)
}

if ($Json) {
  $result | ConvertTo-Json -Depth 8
}
else {
  Write-Output "Agent OS runtime organ contracts: $resultStatus"
  Write-Output "scope=$Scope checks=$($script:checks.Count) failed=$($failures.Count)"
  foreach ($check in $script:checks) {
    $prefix = "[$($check.status)] $($check.scope).$($check.id)"
    Write-Output "$prefix - $($check.detail)"
  }
}

if ($failures.Count -gt 0) {
  exit 1
}
