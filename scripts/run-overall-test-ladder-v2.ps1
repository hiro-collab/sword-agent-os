param(
  [ValidateSet("daily-confidence-smoke")]
  [string]$Mode = "daily-confidence-smoke",
  [switch]$Json
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$RepoRoot = Split-Path -Parent $PSScriptRoot

function Test-RepoRelativePath {
  param([Parameter(Mandatory = $true)][string]$RelativePath)
  return (Test-Path -LiteralPath (Join-Path $RepoRoot $RelativePath) -PathType Leaf)
}

function New-ReportPolicy {
  return [ordered]@{
    shared_output_policy = "class_count_bucket_only"
    evidence_summary_policy = "class_count_bucket_only_no_raw_material"
    pass_candidate_readiness_policy = "pass_candidate_is_not_rr003_final_or_release_ready"
    raw_private_publication_policy = "block_shared_report_if_raw_private_required"
    blocked_or_held_row_policy = "valid_safety_outcome_not_global_failure"
    home_control_live_policy = "optional_exact_route_with_manager_user_gate_only"
    front_door_runner_policy = "thin_front_door_after_schema_no_broad_runner_here"
  }
}

function New-PublicationBoundary {
  return [ordered]@{
    raw_transcript_allowed = $false
    raw_audio_allowed = $false
    raw_media_allowed = $false
    raw_screenshot_allowed = $false
    raw_browser_frame_allowed = $false
    touchdesigner_content_allowed = $false
    provider_payload_allowed = $false
    home_assistant_raw_payload_allowed = $false
    entity_or_device_id_allowed = $false
    private_path_or_filename_allowed = $false
    private_url_allowed = $false
    exact_env_value_allowed = $false
    stdout_stderr_or_stack_trace_allowed = $false
    token_or_secret_allowed = $false
    raw_private_publication_required = $false
  }
}

function New-ClaimGuards {
  return [ordered]@{
    rr003_pass_claimed = $false
    final_readiness_claimed = $false
    release_readiness_claimed = $false
    proof_upgrade_claimed = $false
    physical_device_proof_claimed = $false
  }
}

function ConvertTo-BoundedCounts {
  param([Parameter(Mandatory = $true)][hashtable]$Counts)

  $boundedCounts = [ordered]@{}
  foreach ($key in @($Counts.Keys | Sort-Object)) {
    $boundedCounts[[string]$key] = [int]$Counts[$key]
  }
  return $boundedCounts
}

function New-LadderRow {
  param(
    [Parameter(Mandatory = $true)][string]$RowId,
    [Parameter(Mandatory = $true)][string]$Layer,
    [Parameter(Mandatory = $true)][string]$Purpose,
    [Parameter(Mandatory = $true)][string]$UserValueQuestion,
    [Parameter(Mandatory = $true)][string]$StatusClass,
    [Parameter(Mandatory = $true)][string]$ResultClass,
    [AllowNull()][string]$BlockerClass,
    [Parameter(Mandatory = $true)][string]$ProofCeiling,
    [Parameter(Mandatory = $true)][string]$SummaryClass,
    [Parameter(Mandatory = $true)][string]$CountBucket,
    [Parameter(Mandatory = $true)][string]$EvidenceBucket,
    [Parameter(Mandatory = $true)][hashtable]$BoundedCounts,
    [string[]]$SafeRefs = @(),
    [Parameter(Mandatory = $true)][string]$NextActionClass,
    [string[]]$NonClaims = @()
  )

  $rowNonClaims = @("not_rr003_or_final_readiness") + @($NonClaims)
  $uniqueNonClaims = @()
  foreach ($nonClaim in $rowNonClaims) {
    if ($uniqueNonClaims -notcontains $nonClaim) {
      $uniqueNonClaims += $nonClaim
    }
  }

  return [ordered]@{
    row_id = $RowId
    layer = $Layer
    purpose = $Purpose
    user_value_question = $UserValueQuestion
    status_class = $StatusClass
    result_class = $ResultClass
    blocker_class = if ([string]::IsNullOrWhiteSpace($BlockerClass)) { $null } else { $BlockerClass }
    proof_ceiling = $ProofCeiling
    evidence_summary = [ordered]@{
      summary_class = $SummaryClass
      count_bucket = $CountBucket
      evidence_bucket = $EvidenceBucket
    }
    bounded_counts = ConvertTo-BoundedCounts -Counts $BoundedCounts
    safe_refs = @($SafeRefs)
    next_action_class = $NextActionClass
    publication_boundary = New-PublicationBoundary
    claim_guards = New-ClaimGuards
    non_claims = $uniqueNonClaims
    raw_private_publication_flags = $false
  }
}

function Get-StatusCount {
  param(
    [Parameter(Mandatory = $true)][object[]]$Rows,
    [Parameter(Mandatory = $true)][string]$StatusClass
  )
  return [int]@($Rows | Where-Object { [string]$_.status_class -eq $StatusClass }).Count
}

function Get-OverallStatusClass {
  param([Parameter(Mandatory = $true)][object[]]$Rows)
  if (@($Rows | Where-Object { [string]$_.status_class -eq "blocked" }).Count -gt 0) {
    return "blocked"
  }
  if (@($Rows | Where-Object { [string]$_.status_class -eq "held" }).Count -gt 0) {
    return "completed_with_holds"
  }
  return "pass_candidate"
}

function New-DailyConfidenceSmokeReport {
  $schemaPresent = Test-RepoRelativePath -RelativePath "contracts\overall_test_ladder_report\overall_test_ladder_report.v2.schema.json"
  $dailyExamplePresent = Test-RepoRelativePath -RelativePath "contracts\overall_test_ladder_report\examples\daily_confidence_smoke.held.example.json"
  $frontDoorText = ""
  $frontDoorPath = Join-Path $RepoRoot "sword.ps1"
  if (Test-Path -LiteralPath $frontDoorPath -PathType Leaf) {
    $frontDoorText = Get-Content -Raw -LiteralPath $frontDoorPath
  }
  $frontDoorCommandPresent = ($frontDoorText -match '"ladder"')
  $contractReady = ($schemaPresent -and $dailyExamplePresent)
  $leafHelperCandidates = @(
    "scripts\run-full-install-verification.ps1",
    "scripts\check-distribution-pins.ps1",
    "scripts\check-launch-readiness.ps1",
    "scripts\check-organ-readiness.ps1",
    "scripts\run-primary-system-cell-preflight.ps1",
    "scripts\run-self-mirror-proof.ps1",
    "scripts\start-prepared-sample-browser-stt-operator.ps1",
    "scripts\start-home-control-bridge.ps1"
  )
  $leafHelperPresentCount = 0
  foreach ($candidate in $leafHelperCandidates) {
    if (Test-RepoRelativePath -RelativePath $candidate) {
      $leafHelperPresentCount++
    }
  }

  $rows = @()
  $rows += New-LadderRow `
    -RowId "row_front_door_inventory_v2_001" `
    -Layer "front_door_inventory" `
    -Purpose "thin_front_door_route_shape" `
    -UserValueQuestion "can_operator_start_daily_smoke_without_live_authority" `
    -StatusClass $(if ($frontDoorCommandPresent) { "pass_candidate" } else { "blocked" }) `
    -ResultClass $(if ($frontDoorCommandPresent) { "sword_ladder_front_door_available" } else { "sword_ladder_front_door_missing" }) `
    -BlockerClass $(if ($frontDoorCommandPresent) { $null } else { "front_door_command_missing" }) `
    -ProofCeiling "source_static_front_door_inventory_only" `
    -SummaryClass "thin_front_door_command_inventory_completed" `
    -CountBucket "front_door_count_bucket" `
    -EvidenceBucket "class_count_bucket_only" `
    -BoundedCounts @{
      front_door_commands_checked = 1
      runtime_operations = 0
      raw_private_publications = 0
    } `
    -SafeRefs @("safe_ref_sword_ladder_front_door") `
    -NextActionClass "paired_review_or_hold" `
    -NonClaims @("not_broad_runner_implementation", "not_runtime_or_device_operation")

  $rows += New-LadderRow `
    -RowId "row_report_schema_v2_contract_001" `
    -Layer "source_static" `
    -Purpose "report_schema_v2_contract_consumption" `
    -UserValueQuestion "can_front_door_emit_reviewed_report_shape" `
    -StatusClass $(if ($contractReady) { "pass_candidate" } else { "blocked" }) `
    -ResultClass $(if ($contractReady) { "overall_test_ladder_report_schema_available" } else { "overall_test_ladder_report_schema_missing" }) `
    -BlockerClass $(if ($contractReady) { $null } else { "report_schema_v2_missing" }) `
    -ProofCeiling "source_static_contract_test_only" `
    -SummaryClass "report_contract_presence_classified" `
    -CountBucket "contract_count_bucket" `
    -EvidenceBucket "class_count_bucket_only" `
    -BoundedCounts @{
      report_schema_contracts_present = $(if ($schemaPresent) { 1 } else { 0 })
      report_examples_present = $(if ($dailyExamplePresent) { 1 } else { 0 })
      runtime_operations = 0
    } `
    -SafeRefs @("safe_ref_overall_test_ladder_report_contract") `
    -NextActionClass "use_report_contract_for_later_rows" `
    -NonClaims @("not_runtime_or_browser_proof", "not_readiness_pass")

  $rows += New-LadderRow `
    -RowId "row_leaf_helper_inventory_001" `
    -Layer "readiness_no_live" `
    -Purpose "leaf_helper_inventory_no_invocation" `
    -UserValueQuestion "can_existing_helpers_remain_leaf_only" `
    -StatusClass "pass_candidate" `
    -ResultClass "leaf_helper_inventory_available_without_invocation" `
    -BlockerClass $null `
    -ProofCeiling "source_static_inventory_only" `
    -SummaryClass "leaf_helpers_counted_not_executed" `
    -CountBucket "leaf_helper_count_bucket" `
    -EvidenceBucket "class_count_bucket_only" `
    -BoundedCounts @{
      leaf_helper_candidates = $leafHelperCandidates.Count
      leaf_helpers_present = $leafHelperPresentCount
      helper_invocations = 0
      runtime_operations = 0
    } `
    -SafeRefs @("safe_ref_leaf_helper_inventory") `
    -NextActionClass "wrap_leaf_helpers_only_under_exact_routes" `
    -NonClaims @("not_full_install_verification_run", "not_runtime_or_device_operation")

  $rows += New-LadderRow `
    -RowId "row_local_artifact_hold_policy_001" `
    -Layer "manifest_pin" `
    -Purpose "local_artifact_hold_visibility" `
    -UserValueQuestion "can_holds_be_reported_without_global_failure" `
    -StatusClass "held" `
    -ResultClass "local_artifact_hold_reportable_as_held_row" `
    -BlockerClass "strict_green_not_claimed" `
    -ProofCeiling "source_static_hold_classification_only" `
    -SummaryClass "held_rows_remain_valid_safety_outcomes" `
    -CountBucket "hold_policy_count_bucket" `
    -EvidenceBucket "class_count_bucket_only" `
    -BoundedCounts @{
      held_rows = 1
      strict_green_claims = 0
      runtime_operations = 0
    } `
    -SafeRefs @("safe_ref_local_artifact_hold_policy") `
    -NextActionClass "route_exact_hold_resolution_if_selected" `
    -NonClaims @("not_strict_green", "not_fresh_install_ready")

  $rows += New-LadderRow `
    -RowId "row_browser_runtime_layers_held_001" `
    -Layer "browser_display" `
    -Purpose "browser_runtime_route_hold" `
    -UserValueQuestion "can_browser_layers_stay_out_of_default_smoke" `
    -StatusClass "held" `
    -ResultClass "browser_runtime_not_default_daily_smoke" `
    -BlockerClass "exact_browser_runtime_route_not_selected" `
    -ProofCeiling "held_no_browser_runtime_proof" `
    -SummaryClass "browser_layer_held_without_runtime_start" `
    -CountBucket "browser_operation_count_zero" `
    -EvidenceBucket "class_count_bucket_only" `
    -BoundedCounts @{
      browser_operations = 0
      screenshots_shared = 0
      raw_frames_shared = 0
    } `
    -SafeRefs @() `
    -NextActionClass "open_exact_browser_or_self_mirror_route_if_selected" `
    -NonClaims @("not_browser_runtime_proof", "not_visible_motion_proof")

  $rows += New-LadderRow `
    -RowId "row_audio_recognition_layers_held_001" `
    -Layer "audio_recognizer_execution" `
    -Purpose "audio_recognition_route_hold" `
    -UserValueQuestion "can_audio_recognition_stay_blocked_until_redacted_route" `
    -StatusClass "held" `
    -ResultClass "audio_recognition_not_default_daily_smoke" `
    -BlockerClass "exact_audio_recognition_route_not_selected" `
    -ProofCeiling "held_no_audio_recognition_proof" `
    -SummaryClass "audio_layer_held_without_recognition" `
    -CountBucket "audio_operation_count_zero" `
    -EvidenceBucket "class_count_bucket_only" `
    -BoundedCounts @{
      audio_decode_runs = 0
      recognition_runs = 0
      model_downloads = 0
    } `
    -SafeRefs @("safe_ref_audio_redaction_wrapper_contract") `
    -NextActionClass "open_exact_redacted_recognition_route_if_selected" `
    -NonClaims @("not_audio_recognition", "not_thought_core_turninput")

  $rows += New-LadderRow `
    -RowId "row_home_control_layers_held_001" `
    -Layer "home_assistant_execute" `
    -Purpose "home_control_live_route_hold" `
    -UserValueQuestion "can_appliance_actions_remain_explicit_routes" `
    -StatusClass "held" `
    -ResultClass "home_control_execute_not_default_daily_smoke" `
    -BlockerClass "exact_home_control_route_not_selected" `
    -ProofCeiling "held_no_home_control_execute_proof" `
    -SummaryClass "home_control_layer_held_without_live_execute" `
    -CountBucket "home_control_execute_count_zero" `
    -EvidenceBucket "class_count_bucket_only" `
    -BoundedCounts @{
      live_execute = 0
      direct_bypass = 0
      raw_payloads_shared = 0
    } `
    -SafeRefs @() `
    -NextActionClass "open_exact_home_control_route_if_selected" `
    -NonClaims @("not_home_control_action", "not_physical_device_proof")

  $rows += New-LadderRow `
    -RowId "row_touchdesigner_layers_held_001" `
    -Layer "touchdesigner_toe_mcp" `
    -Purpose "touchdesigner_nosave_route_hold" `
    -UserValueQuestion "can_touchdesigner_stay_no_save_and_separate" `
    -StatusClass "held" `
    -ResultClass "touchdesigner_nosave_validation_not_default_daily_smoke" `
    -BlockerClass "exact_touchdesigner_nosave_route_not_selected" `
    -ProofCeiling "held_no_touchdesigner_runtime_proof" `
    -SummaryClass "touchdesigner_layer_held_without_toe_content" `
    -CountBucket "touchdesigner_operation_count_zero" `
    -EvidenceBucket "class_count_bucket_only" `
    -BoundedCounts @{
      toe_content_reads = 0
      toe_save_writebacks = 0
      raw_frames_shared = 0
    } `
    -SafeRefs @() `
    -NextActionClass "open_exact_touchdesigner_nosave_route_if_selected" `
    -NonClaims @("not_touchdesigner_runtime_proof", "not_toe_content_publication")

  $summaryCounts = [ordered]@{
    rows_total = [int]$rows.Count
    pass_candidate_rows = Get-StatusCount -Rows $rows -StatusClass "pass_candidate"
    held_rows = Get-StatusCount -Rows $rows -StatusClass "held"
    blocked_rows = Get-StatusCount -Rows $rows -StatusClass "blocked"
    raw_private_rows = 0
  }

  return [ordered]@{
    schema_version = "overall_test_ladder_report.v2"
    report_schema_version = "overall_test_ladder_report.v2"
    report_contract_id = "otlr_front_door_daily_confidence_smoke_v2"
    route_id = "OVERALL-TEST-LADDER-REPORT-SCHEMA-V2-SOURCE-STATIC-01"
    report_class = "daily_confidence_smoke"
    generated_at_class = "runtime_generated_timestamp_redacted"
    overall_status_class = Get-OverallStatusClass -Rows $rows
    report_policy = New-ReportPolicy
    summary_counts = $summaryCounts
    rows = $rows
    claim_guards = New-ClaimGuards
    non_claims = @(
      "not_rr003_or_final_readiness",
      "not_release_readiness",
      "not_raw_private_publication",
      "not_broad_runner_implementation",
      "not_runtime_or_device_operation"
    )
    raw_private_publication_flags = $false
  }
}

function Write-HumanSummary {
  param([Parameter(Mandatory = $true)][object]$Report)

  Write-Host "Sword Agent OS overall test ladder v2"
  Write-Host ("mode={0}" -f $Mode)
  Write-Host "default_safety=no-live/no-device"
  Write-Host ("report_class={0}" -f $Report.report_class)
  Write-Host ("overall_status_class={0}" -f $Report.overall_status_class)
  Write-Host ("proof_ceiling={0}" -f "source_static_front_door_inventory_only")
  Write-Host "raw_private_publication_flags=false"
  Write-Host ("rows_total={0}" -f $Report.summary_counts.rows_total)
  Write-Host ("pass_candidate_rows={0}" -f $Report.summary_counts.pass_candidate_rows)
  Write-Host ("held_rows={0}" -f $Report.summary_counts.held_rows)
  Write-Host ("blocked_rows={0}" -f $Report.summary_counts.blocked_rows)
  Write-Host ""
  foreach ($row in @($Report.rows)) {
    $blocker = if ($null -eq $row.blocker_class) { "none" } else { [string]$row.blocker_class }
    Write-Host ("row={0} layer={1} status_class={2} result_class={3} blocker_class={4} proof_ceiling={5}" -f $row.row_id, $row.layer, $row.status_class, $row.result_class, $blocker, $row.proof_ceiling)
  }
  Write-Host ""
  Write-Host "non_claims=not_rr003_or_final_readiness,not_release_readiness,not_broad_runner_implementation,not_runtime_or_device_operation"
}

switch ($Mode) {
  "daily-confidence-smoke" {
    $report = New-DailyConfidenceSmokeReport
  }
}

if ($Json) {
  $report | ConvertTo-Json -Depth 20
}
else {
  Write-HumanSummary -Report $report
}
