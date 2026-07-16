param(
  [string]$BaseUrl = "http://127.0.0.1:8000",
  [string]$AitBaseUrl = "http://127.0.0.1:3000",
  [string]$Scenario = "self_output_or_ambiguous",
  [int]$WindowMs = 1000,
  [int]$DeadlineMs = 5000,
  [string]$CdpEndpoint = "",
  [int]$ControlledChromeRootPid = 0,
  [int]$AudioObserverWindowMs = 3000,
  [int]$PreparationDeadlineMs = 20000,
  [switch]$EmitUserSpeechReadySignal,
  [switch]$Json
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$ExpectedResponseKeys = @(
  "schema_version",
  "result_class",
  "expectation_class",
  "accepted_join_class",
  "capture_packet_count",
  "capture_byte_count",
  "signal_class",
  "vad_decision_class",
  "transcription_count",
  "submission_count",
  "thought_core_turninput_count",
  "elapsed_ms",
  "last_vad_speech_frame_offset_ms",
  "utterance_end_to_candidate_result_ms",
  "utterance_end_timing_class",
  "stt_start_offset_ms",
  "stt_end_offset_ms",
  "canonical_accept_offset_ms",
  "canonical_accept_latency_class",
  "inflight_sink_cancellation_class",
  "presentation_class",
  "assistant_event_id",
  "thought_core_first_event_elapsed_ms",
  "pcm_cleanup_count",
  "private_authority_residue_count",
  "raw_private_publication_flags"
)
$AllowedSignalClasses = @(
  "not_evaluated",
  "all_zero",
  "low_signal",
  "signal_above_floor"
)
$AllowedVadDecisionClasses = @(
  "not_evaluated",
  "speech_not_detected",
  "speech_detected"
)
$AllowedUtteranceEndTimingClasses = @(
  "not_evaluated",
  "no_vad_speech_frame",
  "vad_speech_frame_available",
  "vad_speech_frame_inconsistent"
)
$AllowedPresentationClasses = @(
  "presentation_not_attempted",
  "aituber_presentation_forwarded",
  "aituber_presentation_forwarded_timing_unavailable",
  "aituber_presentation_not_forwarded"
)
$AllowedCanonicalAcceptLatencyClasses = @(
  "not_evaluated",
  "within_2s_target",
  "over_2s_within_10s",
  "over_10s"
)
$AllowedInflightSinkCancellationClasses = @(
  "not_applicable",
  "pre_sink_over_10s_suppressed",
  "not_required_within_10s",
  "inflight_sink_cancellation_not_proven"
)
$AllowedScenarios = @(
  "self_output_or_ambiguous",
  "independent_current_session_user_speech"
)
$AllowedAcceptedJoinClasses = @(
  "not_accepted",
  "active_self_output_overlap",
  "released_normal_input"
)
$SuccessfulResultClasses = @(
  "self_output_or_ambiguous_confirmed",
  "independent_user_speech_turninput_accepted"
)
$AllowedEndpointResultClasses = @(
  "self_output_or_ambiguous_confirmed",
  "independent_user_speech_turninput_accepted",
  "scenario_expectation_not_met",
  "live_candidate_request_invalid",
  "live_candidate_window_busy",
  "input_source_epoch_unavailable",
  "input_gate_capability_unavailable",
  "speech_timing_observation_missing",
  "voice_response_latency_over_10s",
  "private_transcription_not_accepted",
  "private_turn_sink_unavailable",
  "private_turn_sink_failed",
  "live_candidate_environment_unavailable",
  "live_candidate_processing_failed",
  "live_candidate_window_failed",
  "processed_pcm_pipe_lease_invalid",
  "processed_pcm_pipe_owner_unavailable",
  "processed_pcm_pipe_lease_missing",
  "processed_pcm_pipe_lease_expired",
  "processed_pcm_pipe_server_identity_mismatch",
  "processed_pcm_pipe_private_input_timeout",
  "processed_pcm_pipe_connect_failed",
  "processed_pcm_pipe_connect_timeout",
  "processed_pcm_pipe_handshake_failed",
  "processed_pcm_pipe_write_failed",
  "live_aec_backend_or_sink_missing",
  "live_aec_bounds_invalid",
  "live_aec_processing_mode_invalid",
  "live_aec_processed_packet_invalid",
  "live_aec_deadline_exceeded",
  "live_aec_cleanup_failed",
  "live_aec_quality_metrics_cleanup_failed",
  "live_aec_quality_metrics_invariant_failed",
  "live_aec_lifecycle_invariant_failed",
  "voice_capture_dsp_activation_failed",
  "voice_capture_dsp_configuration_failed",
  "voice_capture_dsp_output_format_failed",
  "voice_capture_dsp_start_failed",
  "voice_capture_dsp_not_started",
  "voice_capture_dsp_process_output_failed",
  "voice_capture_dsp_stop_failed",
  "live_aec_observer_failed"
)
$AllowedControllerFailureClasses = @(
  "live_controller_configuration_invalid",
  "live_controller_token_unavailable",
  "live_controller_endpoint_unreachable",
  "live_controller_endpoint_access_denied",
  "live_controller_endpoint_not_found",
  "live_controller_endpoint_response_invalid",
  "live_controller_endpoint_cleanup_incomplete",
  "visible_response_observer_unavailable",
  "visible_response_not_observed",
  "production_transport_unavailable",
  "production_transport_not_completed",
  "live_controller_failed",
  "whole_route_timeout",
  "cleanup_incomplete"
)

$controllerStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
$userPhaseStopwatch = $null
$handler = $null
$client = $null
$request = $null
$content = $null
$response = $null
$cancellation = $null
$token = ""
$requestJson = ""
$requestBody = $null
$visibleObserverProcess = $null
$productionTransportProcess = $null
$visibleObserverStdout = $null
$visibleObserverStderr = $null
$controllerCleanupClear = $true
$requestStarted = $false
$endpointResponseObserved = $false
$exitCode = 1

$controllerStatus = "error"
$safeScenario = "invalid"
$resultClass = "not_observed"
$expectationClass = "not_evaluated"
$acceptedJoinClass = "not_accepted"
$capturePacketCount = 0
$captureByteCount = 0
$signalClass = "not_evaluated"
$vadDecisionClass = "not_evaluated"
$transcriptionCount = 0
$submissionCount = 0
$turnInputCount = 0
$endpointElapsedMs = 0
$lastVadSpeechFrameOffsetMs = $null
$utteranceEndToCandidateResultMs = $null
$utteranceEndTimingClass = "not_evaluated"
$sttStartOffsetMs = $null
$sttEndOffsetMs = $null
$canonicalAcceptOffsetMs = $null
$canonicalAcceptLatencyClass = "not_evaluated"
$inflightSinkCancellationClass = "not_applicable"
$presentationClass = "presentation_not_attempted"
$thoughtCoreFirstEventElapsedMs = $null
$visibleResponseClass = "not_observed"
$visibleMatchCount = 0
$firstVisibleObserverElapsedMs = $null
$utteranceEndToFirstVisibleMs = $null
$firstNonSilentAudioObservationClass = "not_observed"
$utteranceEndToFirstAudioMs = $null
$endpointRequestStartedAtWallMs = $null
$utteranceEndWallMs = $null
$pcmCleanupCount = 0
$privateAuthorityResidueCount = 0
$httpStatusClass = "not_observed"
$deadlineClass = "not_observed"
$endpointCompletionClass = "not_started"
$cleanupClass = "controller_http_resources_disposed_no_request_started"
$blockerClass = "live_controller_failed"

function Throw-Fixed {
  param([Parameter(Mandatory = $true)][string]$Class)
  throw [System.InvalidOperationException]::new($Class)
}

function Assert-ExactKeys {
  param([Parameter(Mandatory = $true)]$Value)

  if ($null -eq $Value -or $Value -isnot [PSCustomObject]) {
    Throw-Fixed -Class "live_controller_endpoint_response_invalid"
  }
  $actual = @($Value.PSObject.Properties.Name | Sort-Object)
  $expected = @($ExpectedResponseKeys | Sort-Object)
  if (($actual -join "`n") -cne ($expected -join "`n")) {
    Throw-Fixed -Class "live_controller_endpoint_response_invalid"
  }
}

function Test-AcceptedJoinClass {
  param(
    [Parameter(Mandatory = $true)][string]$AcceptedJoinClass,
    [Parameter(Mandatory = $true)][string]$ResultClass,
    [Parameter(Mandatory = $true)][int]$ControlledChromeRootPid
  )

  if ($AllowedAcceptedJoinClasses -cnotcontains $AcceptedJoinClass) {
    return $false
  }
  if ($ResultClass -ceq "self_output_or_ambiguous_confirmed") {
    return $AcceptedJoinClass -ceq "not_accepted"
  }
  if ($ResultClass -ceq "independent_user_speech_turninput_accepted") {
    if ($AcceptedJoinClass -ceq "not_accepted") {
      return $false
    }
    return (
      $ControlledChromeRootPid -eq 0 -or
      $AcceptedJoinClass -ceq "active_self_output_overlap"
    )
  }
  return $true
}

function Assert-BoundedInteger {
  param(
    [Parameter(Mandatory = $true)]$Value,
    [Parameter(Mandatory = $true)][long]$Minimum,
    [Parameter(Mandatory = $true)][long]$Maximum,
    [string]$FailureClass = "live_controller_endpoint_response_invalid"
  )

  if (
    $Value -is [bool] -or
    ($Value -isnot [int] -and $Value -isnot [long]) -or
    [long]$Value -lt $Minimum -or
    [long]$Value -gt $Maximum
  ) {
    Throw-Fixed -Class $FailureClass
  }
}

function Resolve-LoopbackBaseUri {
  param([Parameter(Mandatory = $true)][string]$Value)

  $uri = $null
  if (-not [System.Uri]::TryCreate($Value, [System.UriKind]::Absolute, [ref]$uri)) {
    Throw-Fixed -Class "live_controller_configuration_invalid"
  }
  if (
    $uri.Scheme -cne "http" -or
    @("127.0.0.1", "localhost") -cnotcontains $uri.Host.ToLowerInvariant() -or
    -not [string]::IsNullOrEmpty($uri.UserInfo) -or
    -not [string]::IsNullOrEmpty($uri.Query) -or
    -not [string]::IsNullOrEmpty($uri.Fragment) -or
    $uri.AbsolutePath -cne "/" -or
    $uri.Port -lt 1 -or
    $uri.Port -gt 65535
  ) {
    Throw-Fixed -Class "live_controller_configuration_invalid"
  }
  return $uri
}

function Resolve-LoopbackCdpUri {
  param([Parameter(Mandatory = $true)][string]$Value)

  $uri = Resolve-LoopbackBaseUri -Value $Value
  return $uri
}

function Stop-VisibleResponseObserverChild {
  param([Parameter(Mandatory = $true)][System.Diagnostics.Process]$Process)

  $clear = $true
  try {
    if (-not $Process.HasExited) {
      try { $Process.StandardInput.Close() } catch {}
      if (-not $Process.WaitForExit(250)) {
        $Process.Kill($true)
        if (-not $Process.WaitForExit(2000)) {
          $clear = $false
        }
      }
    }
  } catch {
    $clear = $false
  }
  try { $Process.Dispose() } catch { $clear = $false }
  return $clear
}

function Start-VisibleResponseObserver {
  param(
    [Parameter(Mandatory = $true)][System.Uri]$Endpoint,
    [Parameter(Mandatory = $true)][int]$ArmTimeoutMs,
    [Parameter(Mandatory = $true)][int]$RouteDeadlineMs
  )

  $node = Get-Command node -CommandType Application -ErrorAction SilentlyContinue
  $observerPath = Join-Path $PSScriptRoot "observe-primary-system-cell-visible-response.mjs"
  if ($null -eq $node -or -not [System.IO.File]::Exists($observerPath)) {
    Throw-Fixed -Class "visible_response_observer_unavailable"
  }
  $resolvedObserverPath = [System.IO.Path]::GetFullPath($observerPath)
  $resolvedScriptsRoot = [System.IO.Path]::GetFullPath($PSScriptRoot + [System.IO.Path]::DirectorySeparatorChar)
  if (-not $resolvedObserverPath.StartsWith($resolvedScriptsRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
    Throw-Fixed -Class "visible_response_observer_unavailable"
  }

  $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
  $startInfo.FileName = $node.Source
  $startInfo.UseShellExecute = $false
  $startInfo.CreateNoWindow = $true
  $startInfo.RedirectStandardInput = $true
  $startInfo.RedirectStandardOutput = $true
  $startInfo.RedirectStandardError = $true
  [void]$startInfo.ArgumentList.Add($resolvedObserverPath)
  [void]$startInfo.ArgumentList.Add("--cdp-endpoint")
  [void]$startInfo.ArgumentList.Add($Endpoint.AbsoluteUri)
  [void]$startInfo.ArgumentList.Add("--message-id-stdin")
  [void]$startInfo.ArgumentList.Add("--timeout-ms")
  [void]$startInfo.ArgumentList.Add([string]$RouteDeadlineMs)

  $process = [System.Diagnostics.Process]::new()
  $process.StartInfo = $startInfo
  if (-not $process.Start()) {
    $process.Dispose()
    Throw-Fixed -Class "visible_response_observer_unavailable"
  }
  $armTask = $process.StandardOutput.ReadLineAsync()
  if (-not $armTask.Wait([Math]::Max(1, $ArmTimeoutMs))) {
    if (-not (Stop-VisibleResponseObserverChild -Process $process)) {
      Throw-Fixed -Class "cleanup_incomplete"
    }
    Throw-Fixed -Class "visible_response_observer_unavailable"
  }
  try {
    $arm = $armTask.Result | ConvertFrom-Json
  } catch {
    if (-not (Stop-VisibleResponseObserverChild -Process $process)) {
      Throw-Fixed -Class "cleanup_incomplete"
    }
    Throw-Fixed -Class "visible_response_observer_unavailable"
  }
  if ($null -eq $arm) {
    if (-not (Stop-VisibleResponseObserverChild -Process $process)) {
      Throw-Fixed -Class "cleanup_incomplete"
    }
    Throw-Fixed -Class "visible_response_observer_unavailable"
  }
  $armKeys = @($arm.PSObject.Properties.Name | Sort-Object)
  if (
    ($armKeys -join ",") -cne "raw_private_publication_flags,result_class,schema_version" -or
    $arm.schema_version -cne "primary_system_cell_visible_response_observer_arm.v1" -or
    $arm.result_class -cne "observer_armed" -or
    $arm.raw_private_publication_flags -isnot [bool] -or
    [bool]$arm.raw_private_publication_flags
  ) {
    if (-not (Stop-VisibleResponseObserverChild -Process $process)) {
      Throw-Fixed -Class "cleanup_incomplete"
    }
    Throw-Fixed -Class "visible_response_observer_unavailable"
  }
  return $process
}

function Complete-VisibleResponseObserver {
  param(
    [Parameter(Mandatory = $true)][System.Diagnostics.Process]$Process,
    [AllowNull()][string]$AssistantEventId,
    [Parameter(Mandatory = $true)][int]$TimeoutMs
  )

  if ($null -ne $AssistantEventId) {
    $Process.StandardInput.WriteLine($AssistantEventId)
  }
  $Process.StandardInput.Close()
  if (-not $Process.WaitForExit([Math]::Max(1, $TimeoutMs))) {
    try { $Process.Kill($true) } catch {}
    Throw-Fixed -Class "visible_response_not_observed"
  }
  $stdout = $Process.StandardOutput.ReadToEnd()
  $stderr = $Process.StandardError.ReadToEnd()
  if (
    [System.Text.Encoding]::UTF8.GetByteCount($stdout) -gt 4096 -or
    [System.Text.Encoding]::UTF8.GetByteCount($stderr) -gt 4096
  ) {
    Throw-Fixed -Class "visible_response_not_observed"
  }
  $lines = @($stdout -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
  if ($lines.Count -ne 1) {
    Throw-Fixed -Class "visible_response_not_observed"
  }
  try {
    $value = $lines[0] | ConvertFrom-Json -DateKind String
  } catch {
    Throw-Fixed -Class "visible_response_not_observed"
  }
  $expectedKeys = @(
    "schema_version", "result_class", "visible_match_count",
    "observed_at_wall", "observer_elapsed_ms", "cleanup_class",
    "raw_private_publication_flags"
  )
  if (
    (@($value.PSObject.Properties.Name | Sort-Object) -join ",") -cne
      (@($expectedKeys | Sort-Object) -join ",") -or
    $value.schema_version -cne "primary_system_cell_visible_response_observation.v1" -or
    $value.result_class -isnot [string] -or
    $value.cleanup_class -cne "observer_socket_released" -or
    $value.raw_private_publication_flags -isnot [bool] -or
    [bool]$value.raw_private_publication_flags
  ) {
    Throw-Fixed -Class "visible_response_not_observed"
  }
  Assert-BoundedInteger -Value $value.visible_match_count -Minimum 0 -Maximum 2
  Assert-BoundedInteger -Value $value.observer_elapsed_ms -Minimum 0 -Maximum 30000
  return $value
}

function Start-ProductionTransportChild {
  param(
    [Parameter(Mandatory = $true)][System.Uri]$AitEndpoint,
    [Parameter(Mandatory = $true)][System.Uri]$AiTalkCoreEndpoint,
    [Parameter(Mandatory = $true)][int]$ChromeRootPid,
    [Parameter(Mandatory = $true)][int]$ObserverWindowMs,
    [Parameter(Mandatory = $true)][int]$ArmTimeoutMs,
    [Parameter(Mandatory = $true)][int]$RouteDeadlineMs,
    [AllowNull()][scriptblock]$ProcessFactory = $null
  )

  $pwshPath = "C:\Program Files\PowerShell\7\pwsh.exe"
  $transportPath = Join-Path $PSScriptRoot "run-self-output-awareness-production-transport.ps1"
  if (
    -not [System.IO.File]::Exists($pwshPath) -or
    -not [System.IO.File]::Exists($transportPath)
  ) {
    Throw-Fixed -Class "production_transport_unavailable"
  }
  $resolvedTransportPath = [System.IO.Path]::GetFullPath($transportPath)
  $resolvedScriptsRoot = [System.IO.Path]::GetFullPath(
    $PSScriptRoot + [System.IO.Path]::DirectorySeparatorChar)
  if (
    -not $resolvedTransportPath.StartsWith(
      $resolvedScriptsRoot,
      [System.StringComparison]::OrdinalIgnoreCase) -or
    [System.IO.Path]::GetFileName($resolvedTransportPath) -cne
      "run-self-output-awareness-production-transport.ps1"
  ) {
    Throw-Fixed -Class "production_transport_unavailable"
  }

  $process = $null
  if ($null -eq $ProcessFactory) {
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $pwshPath
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($argument in @(
        "-NoProfile", "-File", $resolvedTransportPath,
        "-AitBaseUrl", $AitEndpoint.AbsoluteUri,
        "-AiTalkCoreBaseUrl", $AiTalkCoreEndpoint.AbsoluteUri,
        "-ControlledChromeRootPid", [string]$ChromeRootPid,
        "-ObserverWindowMs", [string]$ObserverWindowMs,
        "-DeadlineMs", [string]$RouteDeadlineMs,
        "-EmitArmSignal", "-Json"
      )) {
      [void]$startInfo.ArgumentList.Add($argument)
    }
    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
  } else {
    $process = & $ProcessFactory
  }
  if ($process -isnot [System.Diagnostics.Process]) {
    Throw-Fixed -Class "production_transport_unavailable"
  }
  if (-not $process.Start()) {
    $process.Dispose()
    Throw-Fixed -Class "production_transport_unavailable"
  }
  $armTask = $process.StandardOutput.ReadLineAsync()
  if (-not $armTask.Wait([Math]::Max(1, $ArmTimeoutMs))) {
    if (-not (Stop-ProductionTransportChild -Process $process)) {
      Throw-Fixed -Class "cleanup_incomplete"
    }
    Throw-Fixed -Class "production_transport_unavailable"
  }
  try { $arm = $armTask.Result | ConvertFrom-Json }
  catch {
    if (-not (Stop-ProductionTransportChild -Process $process)) {
      Throw-Fixed -Class "cleanup_incomplete"
    }
    Throw-Fixed -Class "production_transport_unavailable"
  }
  $expectedArmKeys = @(
    "schema_version", "result_class", "raw_private_publication_flags")
  if (
    $null -eq $arm -or
    (@($arm.PSObject.Properties.Name | Sort-Object) -join ",") -cne
      (@($expectedArmKeys | Sort-Object) -join ",") -or
    $arm.schema_version -cne "self_output_awareness.production_transport_arm.v0" -or
    $arm.result_class -cne "overlap_join_ready" -or
    $arm.raw_private_publication_flags -isnot [bool] -or
    [bool]$arm.raw_private_publication_flags
  ) {
    if (-not (Stop-ProductionTransportChild -Process $process)) {
      Throw-Fixed -Class "cleanup_incomplete"
    }
    Throw-Fixed -Class "production_transport_unavailable"
  }
  return $process
}

function Complete-ProductionTransportChild {
  param(
    [Parameter(Mandatory = $true)][System.Diagnostics.Process]$Process,
    [Parameter(Mandatory = $true)][int]$TimeoutMs,
    [Parameter(Mandatory = $true)][int]$RouteDeadlineMs
  )

  if (-not $Process.WaitForExit([Math]::Max(1, $TimeoutMs))) {
    try { $Process.Kill($true) } catch {}
    Throw-Fixed -Class "whole_route_timeout"
  }
  $stdout = $Process.StandardOutput.ReadToEnd().Trim()
  $stderr = $Process.StandardError.ReadToEnd().Trim()
  if (
    $Process.ExitCode -ne 0 -or
    -not [string]::IsNullOrWhiteSpace($stderr) -or
    [System.Text.Encoding]::UTF8.GetByteCount($stdout) -gt 16384
  ) {
    $stdout = ""
    $stderr = ""
    Throw-Fixed -Class "production_transport_not_completed"
  }
  try { $value = $stdout | ConvertFrom-Json -Depth 10 }
  catch { Throw-Fixed -Class "production_transport_not_completed" }
  finally {
    $stdout = ""
    $stderr = ""
  }
  $expectedKeys = @(
    "schema_version", "status", "result_class", "blocker_class",
    "lifecycle_ingest_count", "observation_ingest_count",
    "lifecycle_ingest_outcome_class", "observation_ingest_outcome_class",
    "ait_poll_count", "core_request_count", "final_lifecycle_state",
    "observer_result_class", "first_non_silent_frame_offset_ms",
    "first_non_silent_observed_at_utc_ms", "handoff_pickup_ms",
    "cooldown_pickup_ms", "released_pickup_ms", "observation_ingest_ms",
    "overlap_join_ready_class",
    "elapsed_ms", "latency_requirement_status", "cleanup_class",
    "route_owned_process_residue_count", "route_owned_request_residue_count",
    "route_owned_pipe_residue_count", "route_owned_temp_residue_count",
    "audio_route_change_count", "microphone_route_change_count",
    "candidate_authority", "acceptance_authority", "turn_input_authority",
    "raw_audio_shared", "raw_text_shared", "private_identifier_shared",
    "private_environment_shared", "raw_private_publication_flags")
  if (
    $null -eq $value -or
    (@($value.PSObject.Properties.Name | Sort-Object) -join ",") -cne
      (@($expectedKeys | Sort-Object) -join ",") -or
    $value.schema_version -cne "self_output_awareness.production_transport.v0" -or
    $value.status -cne "completed" -or
    $value.result_class -cne "production_self_output_transport_completed" -or
    $null -ne $value.blocker_class -or
    $value.final_lifecycle_state -cne "released" -or
    $value.observer_result_class -cne "process_tree_render_observed" -or
    $value.latency_requirement_status -cne
      "first_non_silent_wall_timestamp_available" -or
    $value.cleanup_class -cne "route_owned_cleanup_clear" -or
    $value.lifecycle_ingest_outcome_class -cne "acknowledged" -or
    $value.observation_ingest_outcome_class -cne "acknowledged" -or
    $value.overlap_join_ready_class -cne "overlap_join_ready" -or
    $value.raw_private_publication_flags -isnot [bool] -or
    [bool]$value.raw_private_publication_flags
  ) {
    Throw-Fixed -Class "production_transport_not_completed"
  }
  foreach ($key in @(
      "candidate_authority", "acceptance_authority", "turn_input_authority",
      "raw_audio_shared", "raw_text_shared", "private_identifier_shared",
      "private_environment_shared"
    )) {
    if ($value.$key -isnot [bool] -or [bool]$value.$key) {
      Throw-Fixed -Class "production_transport_not_completed"
    }
  }
  foreach ($key in @(
      "route_owned_process_residue_count", "route_owned_request_residue_count",
      "route_owned_pipe_residue_count", "route_owned_temp_residue_count",
      "audio_route_change_count", "microphone_route_change_count"
    )) {
    Assert-BoundedInteger -Value $value.$key -Minimum 0 -Maximum 0 `
      -FailureClass "production_transport_not_completed"
  }
  Assert-BoundedInteger -Value $value.lifecycle_ingest_count -Minimum 3 -Maximum 16 `
    -FailureClass "production_transport_not_completed"
  Assert-BoundedInteger -Value $value.observation_ingest_count -Minimum 1 -Maximum 1 `
    -FailureClass "production_transport_not_completed"
  Assert-BoundedInteger -Value $value.ait_poll_count -Minimum 4 -Maximum 1000 `
    -FailureClass "production_transport_not_completed"
  Assert-BoundedInteger -Value $value.core_request_count -Minimum 4 -Maximum 17 `
    -FailureClass "production_transport_not_completed"
  Assert-BoundedInteger -Value $value.first_non_silent_frame_offset_ms -Minimum 0 -Maximum 5000 `
    -FailureClass "production_transport_not_completed"
  Assert-BoundedInteger -Value $value.first_non_silent_observed_at_utc_ms -Minimum 0 -Maximum 4102444800000 `
    -FailureClass "production_transport_not_completed"
  Assert-BoundedInteger -Value $value.elapsed_ms -Minimum 0 -Maximum $RouteDeadlineMs `
    -FailureClass "production_transport_not_completed"
  if ([long]$value.core_request_count -ne (
      [long]$value.lifecycle_ingest_count + [long]$value.observation_ingest_count)) {
    Throw-Fixed -Class "production_transport_not_completed"
  }
  return $value
}

function Stop-ProductionTransportChild {
  param([Parameter(Mandatory = $true)][System.Diagnostics.Process]$Process)

  $clear = $true
  try {
    if (-not $Process.HasExited) {
      $Process.Kill($true)
      if (-not $Process.WaitForExit(2000)) { $clear = $false }
    }
  } catch { $clear = $false }
  try { $Process.Dispose() } catch { $clear = $false }
  return $clear
}

function Resolve-UtteranceEndToFirstAudioMs {
  param(
    [Parameter(Mandatory = $true)]$UtteranceEndWallMs,
    [Parameter(Mandatory = $true)]$FirstAudioWallMs,
    [Parameter(Mandatory = $true)][int]$RouteDeadlineMs,
    $ObservedNowUtcMs = [System.DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
  )

  foreach ($value in @($UtteranceEndWallMs, $FirstAudioWallMs, $ObservedNowUtcMs)) {
    if (
      $value -is [bool] -or
      ($value -isnot [int] -and $value -isnot [long]) -or
      [long]$value -lt 0 -or
      [long]$value -gt 4102444800000
    ) {
      Throw-Fixed -Class "production_transport_not_completed"
    }
  }
  if (
    $RouteDeadlineMs -lt 1 -or
    $RouteDeadlineMs -gt 10000 -or
    [long]$FirstAudioWallMs -gt ([long]$ObservedNowUtcMs + 1000)
  ) {
    Throw-Fixed -Class "production_transport_not_completed"
  }
  $delta = [long]$FirstAudioWallMs - [long]$UtteranceEndWallMs
  if ($delta -lt 0 -or $delta -gt $RouteDeadlineMs) {
    Throw-Fixed -Class "production_transport_not_completed"
  }
  return [int]$delta
}

function Set-Failure {
  param([Parameter(Mandatory = $true)][string]$Class)

  $script:controllerStatus = "error"
  $script:blockerClass = $Class
  $script:exitCode = 1
}

function New-UserSpeechReadySignal {
  return [ordered]@{
    schema_version = "self_output_awareness.live_controller_ready.v0"
    result_class = "ready_for_user_speech"
    raw_private_publication_flags = $false
  }
}

function Get-RemainingRouteBudgetMs {
  $elapsedMs = $(if ($null -ne $userPhaseStopwatch) {
      [long]$userPhaseStopwatch.ElapsedMilliseconds
    } else {
      [long]$controllerStopwatch.ElapsedMilliseconds
    })
  $remainingMs = [long]$DeadlineMs - $elapsedMs
  if ($remainingMs -le 0) {
    Throw-Fixed -Class "whole_route_timeout"
  }
  return [int][Math]::Min([int]::MaxValue, $remainingMs)
}

function Get-RemainingPreparationBudgetMs {
  $remainingMs = [long]$PreparationDeadlineMs -
    [long]$controllerStopwatch.ElapsedMilliseconds
  if ($remainingMs -le 0) {
    Throw-Fixed -Class "whole_route_timeout"
  }
  return [int][Math]::Min([int]::MaxValue, $remainingMs)
}

if ($MyInvocation.InvocationName -eq ".") { return }

try {
  if (
    $AllowedScenarios -cnotcontains $Scenario -or
    $WindowMs -lt 100 -or
    $WindowMs -gt 3000 -or
    $DeadlineMs -lt ($WindowMs + 200) -or
    $DeadlineMs -gt 10000 -or
    $PreparationDeadlineMs -lt 1000 -or
    $PreparationDeadlineMs -gt 20000 -or
    $ControlledChromeRootPid -lt 0 -or
    $AudioObserverWindowMs -lt 100 -or
    $AudioObserverWindowMs -gt 5000 -or
    ($ControlledChromeRootPid -gt 0 -and (
      $Scenario -cne "independent_current_session_user_speech" -or
      [string]::IsNullOrWhiteSpace($CdpEndpoint) -or
      $PreparationDeadlineMs -lt ($AudioObserverWindowMs + 1000)
    )) -or
    ($EmitUserSpeechReadySignal -and $ControlledChromeRootPid -le 0)
  ) {
    Throw-Fixed -Class "live_controller_configuration_invalid"
  }
  $safeScenario = $Scenario

  $baseUri = Resolve-LoopbackBaseUri -Value $BaseUrl
  $aitUri = $null
  if ($ControlledChromeRootPid -gt 0) {
    $aitUri = Resolve-LoopbackBaseUri -Value $AitBaseUrl
  }
  $cdpUri = $null
  if (-not [string]::IsNullOrWhiteSpace($CdpEndpoint)) {
    if ($Scenario -cne "independent_current_session_user_speech") {
      Throw-Fixed -Class "live_controller_configuration_invalid"
    }
    $cdpUri = Resolve-LoopbackCdpUri -Value $CdpEndpoint
  }
  $token = [System.Environment]::GetEnvironmentVariable("AI_TALK_CORE_WEB_TOKEN", "Process")
  if ([string]::IsNullOrWhiteSpace($token)) {
    Throw-Fixed -Class "live_controller_token_unavailable"
  }

  $endpointUri = [System.Uri]::new($baseUri, "/api/live-input-gate/candidate-window")

  if ($null -ne $cdpUri) {
    $observerArmBudgetMs = Get-RemainingPreparationBudgetMs
    $observerRouteDeadlineMs = [Math]::Min(
      30000,
      $PreparationDeadlineMs + $DeadlineMs)
    $visibleObserverProcess = Start-VisibleResponseObserver `
      -Endpoint $cdpUri `
      -ArmTimeoutMs $observerArmBudgetMs `
      -RouteDeadlineMs $observerRouteDeadlineMs
  }

  if ($ControlledChromeRootPid -gt 0) {
    $productionArmBudgetMs = Get-RemainingPreparationBudgetMs
    if ($productionArmBudgetMs -lt ($AudioObserverWindowMs + 1000)) {
      Throw-Fixed -Class "whole_route_timeout"
    }
    $productionRouteDeadlineMs = [Math]::Min(
      30000,
      $PreparationDeadlineMs + $DeadlineMs)
    $productionTransportProcess = Start-ProductionTransportChild `
      -AitEndpoint $aitUri `
      -AiTalkCoreEndpoint $baseUri `
      -ChromeRootPid $ControlledChromeRootPid `
      -ObserverWindowMs $AudioObserverWindowMs `
      -ArmTimeoutMs $productionArmBudgetMs `
      -RouteDeadlineMs $productionRouteDeadlineMs
    $userPhaseStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    if ($EmitUserSpeechReadySignal) {
      $readySignal = New-UserSpeechReadySignal
      [Console]::Error.WriteLine(($readySignal | ConvertTo-Json -Compress))
      [Console]::Error.Flush()
      $readySignal.Clear()
      $readySignal = $null
    }
  }

  $httpBudgetMs = Get-RemainingRouteBudgetMs
  if ($httpBudgetMs -lt ($WindowMs + 200)) {
    Throw-Fixed -Class "whole_route_timeout"
  }
  $requestBody = [ordered]@{
    scenario = $Scenario
    window_ms = $WindowMs
    deadline_ms = $httpBudgetMs
  }
  $requestJson = $requestBody | ConvertTo-Json -Compress
  $requestBody.Clear()

  $handler = [System.Net.Http.HttpClientHandler]::new()
  $handler.AllowAutoRedirect = $false
  $handler.UseCookies = $false
  $handler.UseProxy = $false
  $client = [System.Net.Http.HttpClient]::new($handler, $false)
  $request = [System.Net.Http.HttpRequestMessage]::new(
    [System.Net.Http.HttpMethod]::Post,
    $endpointUri
  )
  $content = [System.Net.Http.StringContent]::new(
    $requestJson,
    [System.Text.Encoding]::UTF8,
    "application/json"
  )
  $request.Content = $content
  [void]$request.Headers.TryAddWithoutValidation("X-AI-Core-Token", $token)
  $token = ""
  $requestJson = ""

  $cancellation = [System.Threading.CancellationTokenSource]::new()
  $cancellation.CancelAfter($httpBudgetMs)
  $endpointRequestStartedAtWallMs = [System.DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
  $requestStarted = $true
  $response = $client.SendAsync(
    $request,
    [System.Net.Http.HttpCompletionOption]::ResponseContentRead,
    $cancellation.Token
  ).GetAwaiter().GetResult()
  $endpointResponseObserved = $true
  $endpointCompletionClass = "completed_response_observed"

  $statusCode = [int]$response.StatusCode
  $httpStatusClass = switch ($statusCode) {
    200 { "success" }
    400 { "request_rejected" }
    403 { "access_denied" }
    404 { "not_found" }
    409 { "busy" }
    503 { "service_unavailable" }
    default { "unexpected_status" }
  }
  if ($statusCode -eq 403) {
    Throw-Fixed -Class "live_controller_endpoint_access_denied"
  }
  if ($statusCode -eq 404) {
    Throw-Fixed -Class "live_controller_endpoint_not_found"
  }
  if (@(200, 400, 409, 503) -notcontains $statusCode) {
    Throw-Fixed -Class "live_controller_endpoint_response_invalid"
  }

  $responseText = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
  if ([System.Text.Encoding]::UTF8.GetByteCount($responseText) -gt 16384) {
    Throw-Fixed -Class "live_controller_endpoint_response_invalid"
  }
  try {
    $endpointResult = $responseText | ConvertFrom-Json
  } catch {
    Throw-Fixed -Class "live_controller_endpoint_response_invalid"
  } finally {
    $responseText = ""
  }

  Assert-ExactKeys -Value $endpointResult
  if (
    $endpointResult.schema_version -isnot [string] -or
    [string]$endpointResult.schema_version -cne "ai_talk_core.live_input_gate_candidate_window.v0" -or
    $endpointResult.result_class -isnot [string] -or
    $AllowedEndpointResultClasses -cnotcontains [string]$endpointResult.result_class -or
    $endpointResult.expectation_class -isnot [string] -or
    @("matched", "mismatch", "not_evaluated") -cnotcontains [string]$endpointResult.expectation_class -or
    $endpointResult.accepted_join_class -isnot [string] -or
    -not (Test-AcceptedJoinClass `
      -AcceptedJoinClass ([string]$endpointResult.accepted_join_class) `
      -ResultClass ([string]$endpointResult.result_class) `
      -ControlledChromeRootPid $ControlledChromeRootPid) -or
    $endpointResult.signal_class -isnot [string] -or
    $AllowedSignalClasses -cnotcontains [string]$endpointResult.signal_class -or
    $endpointResult.vad_decision_class -isnot [string] -or
    $AllowedVadDecisionClasses -cnotcontains [string]$endpointResult.vad_decision_class -or
    $endpointResult.utterance_end_timing_class -isnot [string] -or
    $AllowedUtteranceEndTimingClasses -cnotcontains [string]$endpointResult.utterance_end_timing_class -or
    $endpointResult.canonical_accept_latency_class -isnot [string] -or
    $AllowedCanonicalAcceptLatencyClasses -cnotcontains [string]$endpointResult.canonical_accept_latency_class -or
    $endpointResult.inflight_sink_cancellation_class -isnot [string] -or
    $AllowedInflightSinkCancellationClasses -cnotcontains [string]$endpointResult.inflight_sink_cancellation_class -or
    $endpointResult.presentation_class -isnot [string] -or
    $AllowedPresentationClasses -cnotcontains [string]$endpointResult.presentation_class -or
    $endpointResult.raw_private_publication_flags -isnot [bool] -or
    [bool]$endpointResult.raw_private_publication_flags
  ) {
    Throw-Fixed -Class "live_controller_endpoint_response_invalid"
  }

  Assert-BoundedInteger -Value $endpointResult.capture_packet_count -Minimum 0 -Maximum 1000
  Assert-BoundedInteger -Value $endpointResult.capture_byte_count -Minimum 0 -Maximum 160000
  Assert-BoundedInteger -Value $endpointResult.transcription_count -Minimum 0 -Maximum 1
  Assert-BoundedInteger -Value $endpointResult.submission_count -Minimum 0 -Maximum 1
  Assert-BoundedInteger -Value $endpointResult.thought_core_turninput_count -Minimum 0 -Maximum 1
  Assert-BoundedInteger -Value $endpointResult.elapsed_ms -Minimum 0 -Maximum 20000
  Assert-BoundedInteger -Value $endpointResult.pcm_cleanup_count -Minimum 0 -Maximum 1
  Assert-BoundedInteger -Value $endpointResult.private_authority_residue_count -Minimum 0 -Maximum 1

  $lastFrameValue = $endpointResult.last_vad_speech_frame_offset_ms
  $utteranceToResultValue = $endpointResult.utterance_end_to_candidate_result_ms
  $timingClass = [string]$endpointResult.utterance_end_timing_class
  $presentationClass = [string]$endpointResult.presentation_class
  $assistantEventId = $endpointResult.assistant_event_id
  $thoughtCoreFirstEventElapsedValue = $endpointResult.thought_core_first_event_elapsed_ms
  $sttStartValue = $endpointResult.stt_start_offset_ms
  $sttEndValue = $endpointResult.stt_end_offset_ms
  $canonicalAcceptValue = $endpointResult.canonical_accept_offset_ms
  $canonicalLatencyClass = [string]$endpointResult.canonical_accept_latency_class
  $inflightCancellationClass = [string]$endpointResult.inflight_sink_cancellation_class
  if ($timingClass -ceq "vad_speech_frame_available") {
    Assert-BoundedInteger -Value $lastFrameValue -Minimum 10 -Maximum $WindowMs
    Assert-BoundedInteger -Value $utteranceToResultValue -Minimum 0 -Maximum 20000
    if (
      [string]$endpointResult.vad_decision_class -cne "speech_detected" -or
      ([int]$lastFrameValue + [int]$utteranceToResultValue) -ne
        [int]$endpointResult.elapsed_ms
    ) {
      Throw-Fixed -Class "live_controller_endpoint_response_invalid"
    }
  } elseif ($null -ne $lastFrameValue -or $null -ne $utteranceToResultValue) {
    Throw-Fixed -Class "live_controller_endpoint_response_invalid"
  } elseif (
    ($timingClass -ceq "no_vad_speech_frame" -and
      [string]$endpointResult.vad_decision_class -cne "speech_not_detected") -or
    ($timingClass -ceq "vad_speech_frame_inconsistent" -and
      [string]$endpointResult.vad_decision_class -cne "speech_detected") -or
    ($timingClass -ceq "not_evaluated" -and
      [string]$endpointResult.vad_decision_class -cne "not_evaluated")
  ) {
    Throw-Fixed -Class "live_controller_endpoint_response_invalid"
  }

  $hasSttTiming = $null -ne $sttStartValue -or $null -ne $sttEndValue
  if ($hasSttTiming) {
    Assert-BoundedInteger -Value $sttStartValue -Minimum 0 -Maximum 20000
    Assert-BoundedInteger -Value $sttEndValue -Minimum 0 -Maximum 20000
    if ([long]$sttStartValue -gt [long]$sttEndValue) {
      Throw-Fixed -Class "live_controller_endpoint_response_invalid"
    }
  }
  if ($null -ne $canonicalAcceptValue) {
    Assert-BoundedInteger -Value $canonicalAcceptValue -Minimum 0 -Maximum 20000
    if (-not $hasSttTiming -or [long]$canonicalAcceptValue -lt [long]$sttEndValue) {
      Throw-Fixed -Class "live_controller_endpoint_response_invalid"
    }
    $expectedLatencyClass = if ([long]$canonicalAcceptValue -le 2000) {
      "within_2s_target"
    } elseif ([long]$canonicalAcceptValue -le 10000) {
      "over_2s_within_10s"
    } else {
      "over_10s"
    }
    if ($canonicalLatencyClass -cne $expectedLatencyClass) {
      Throw-Fixed -Class "live_controller_endpoint_response_invalid"
    }
  } elseif (
    $canonicalLatencyClass -cne "not_evaluated" -and
    -not (
      $canonicalLatencyClass -ceq "over_10s" -and
      $inflightCancellationClass -ceq "pre_sink_over_10s_suppressed"
    )
  ) {
    Throw-Fixed -Class "live_controller_endpoint_response_invalid"
  }

  $forwardedPresentation = $presentationClass -in @(
    "aituber_presentation_forwarded",
    "aituber_presentation_forwarded_timing_unavailable"
  )
  if ($forwardedPresentation) {
    if (
      $assistantEventId -isnot [string] -or
      [string]$assistantEventId -notmatch '^[A-Za-z0-9_.:-]{1,128}$' -or
      [string]$assistantEventId -match '(?i)(^|[._:-])(private|raw|secret|token|transcript|prompt|path|url)($|[._:-])'
    ) {
      Throw-Fixed -Class "live_controller_endpoint_response_invalid"
    }
    if ($presentationClass -ceq "aituber_presentation_forwarded") {
      Assert-BoundedInteger -Value $thoughtCoreFirstEventElapsedValue -Minimum 0 -Maximum 20000
    } elseif ($null -ne $thoughtCoreFirstEventElapsedValue) {
      Throw-Fixed -Class "live_controller_endpoint_response_invalid"
    }
  } elseif ($null -ne $assistantEventId -or $null -ne $thoughtCoreFirstEventElapsedValue) {
    Throw-Fixed -Class "live_controller_endpoint_response_invalid"
  }

  $resultClass = [string]$endpointResult.result_class
  $expectationClass = [string]$endpointResult.expectation_class
  $acceptedJoinClass = [string]$endpointResult.accepted_join_class
  $capturePacketCount = [int]$endpointResult.capture_packet_count
  $captureByteCount = [int]$endpointResult.capture_byte_count
  $signalClass = [string]$endpointResult.signal_class
  $vadDecisionClass = [string]$endpointResult.vad_decision_class
  $transcriptionCount = [int]$endpointResult.transcription_count
  $submissionCount = [int]$endpointResult.submission_count
  $turnInputCount = [int]$endpointResult.thought_core_turninput_count
  $endpointElapsedMs = [int]$endpointResult.elapsed_ms
  $lastVadSpeechFrameOffsetMs = $lastFrameValue
  $utteranceEndToCandidateResultMs = $utteranceToResultValue
  $utteranceEndTimingClass = $timingClass
  $sttStartOffsetMs = $sttStartValue
  $sttEndOffsetMs = $sttEndValue
  $canonicalAcceptOffsetMs = $canonicalAcceptValue
  $canonicalAcceptLatencyClass = $canonicalLatencyClass
  $inflightSinkCancellationClass = $inflightCancellationClass
  $thoughtCoreFirstEventElapsedMs = $thoughtCoreFirstEventElapsedValue
  $pcmCleanupCount = [int]$endpointResult.pcm_cleanup_count
  $privateAuthorityResidueCount = [int]$endpointResult.private_authority_residue_count
  if (
    $null -ne $lastVadSpeechFrameOffsetMs -and
    $null -ne $endpointRequestStartedAtWallMs
  ) {
    $utteranceEndWallMs = [long]$endpointRequestStartedAtWallMs +
      [long]$lastVadSpeechFrameOffsetMs
  }

  $expectedStatusCode = switch ($resultClass) {
    { $SuccessfulResultClasses -ccontains $_ } { 200; break }
    "scenario_expectation_not_met" { 200; break }
    "live_candidate_request_invalid" { 400; break }
    "live_candidate_window_busy" { 409; break }
    default { 503 }
  }
  if ($statusCode -ne $expectedStatusCode) {
    Throw-Fixed -Class "live_controller_endpoint_response_invalid"
  }
  if ($endpointElapsedMs -gt $DeadlineMs) {
    Throw-Fixed -Class "live_controller_endpoint_response_invalid"
  }

  $hasCapture = $capturePacketCount -gt 0 -or $captureByteCount -gt 0
  $requiresEvaluatedDiagnostic = (
    $SuccessfulResultClasses -ccontains $resultClass -or
    $resultClass -ceq "scenario_expectation_not_met"
  )
  if (
    (-not $hasCapture -and (
      $signalClass -cne "not_evaluated" -or
      $vadDecisionClass -cne "not_evaluated"
    )) -or
    ($requiresEvaluatedDiagnostic -and (
      -not $hasCapture -or
      $signalClass -ceq "not_evaluated" -or
      $vadDecisionClass -ceq "not_evaluated"
    )) -or
    ($signalClass -ceq "not_evaluated" -and $vadDecisionClass -cne "not_evaluated") -or
    ($signalClass -ceq "all_zero" -and $vadDecisionClass -ceq "speech_detected")
  ) {
    Throw-Fixed -Class "live_controller_endpoint_response_invalid"
  }
  if (
    (($capturePacketCount -eq 0) -xor ($captureByteCount -eq 0)) -or
    ($hasCapture -and $pcmCleanupCount -ne 1) -or
    (-not $hasCapture -and $pcmCleanupCount -ne 0) -or
    $privateAuthorityResidueCount -ne 0
  ) {
    Throw-Fixed -Class "live_controller_endpoint_cleanup_incomplete"
  }
  $cleanupClass = if ($hasCapture) {
    "controller_http_resources_disposed_endpoint_pcm_and_authority_clear"
  } else {
    "controller_http_resources_disposed_no_endpoint_capture_observed"
  }

  if ($resultClass -ceq "self_output_or_ambiguous_confirmed") {
    if (
      $Scenario -cne "self_output_or_ambiguous" -or
      $expectationClass -cne "matched" -or
      -not $hasCapture -or
      $transcriptionCount -ne 0 -or
      $submissionCount -ne 0 -or
      $turnInputCount -ne 0 -or
      $presentationClass -cne "presentation_not_attempted" -or
      $hasSttTiming -or
      $null -ne $canonicalAcceptValue -or
      $canonicalLatencyClass -cne "not_evaluated" -or
      $inflightCancellationClass -cne "not_applicable"
    ) {
      Throw-Fixed -Class "live_controller_endpoint_response_invalid"
    }
    $controllerStatus = "completed"
    $blockerClass = $null
    $exitCode = 0
  } elseif ($resultClass -ceq "independent_user_speech_turninput_accepted") {
    if (
      $Scenario -cne "independent_current_session_user_speech" -or
      $expectationClass -cne "matched" -or
      -not $hasCapture -or
      $vadDecisionClass -cne "speech_detected" -or
      $transcriptionCount -ne 1 -or
      $submissionCount -ne 1 -or
      $turnInputCount -ne 1 -or
      $presentationClass -ceq "presentation_not_attempted" -or
      -not $hasSttTiming -or
      $null -eq $canonicalAcceptValue -or
      $canonicalLatencyClass -ceq "not_evaluated"
    ) {
      Throw-Fixed -Class "live_controller_endpoint_response_invalid"
    }
    $controllerStatus = "completed"
    $blockerClass = $null
    $exitCode = 0
  } else {
    if (
      $submissionCount -ne 0 -or
      $turnInputCount -ne 0 -or
      ($resultClass -ceq "scenario_expectation_not_met" -and (
        $expectationClass -cne "mismatch" -or
        $transcriptionCount -ne 0
      ))
    ) {
      Throw-Fixed -Class "live_controller_endpoint_response_invalid"
    }
    $controllerStatus = "blocked"
    $blockerClass = $resultClass
    $exitCode = 1
  }

  if ($null -ne $visibleObserverProcess) {
    $remainingObserverMs = Get-RemainingRouteBudgetMs
    $visibleObservation = Complete-VisibleResponseObserver `
      -Process $visibleObserverProcess `
      -AssistantEventId $(if ($assistantEventId -is [string]) { [string]$assistantEventId } else { $null }) `
      -TimeoutMs $remainingObserverMs
    $assistantEventId = $null
    $visibleResponseClass = [string]$visibleObservation.result_class
    $visibleMatchCount = [int]$visibleObservation.visible_match_count
    $firstVisibleObserverElapsedMs = [int]$visibleObservation.observer_elapsed_ms
    if (
      $visibleResponseClass -cne "visible_response_observed" -or
      $visibleMatchCount -ne 1 -or
      $null -eq $visibleObservation.observed_at_wall -or
      $null -eq $lastVadSpeechFrameOffsetMs -or
      $null -eq $endpointRequestStartedAtWallMs
    ) {
      Throw-Fixed -Class "visible_response_not_observed"
    }
    try {
      $visibleWallMs = [System.DateTimeOffset]::ParseExact(
        [string]$visibleObservation.observed_at_wall,
        "O",
        [System.Globalization.CultureInfo]::InvariantCulture,
        [System.Globalization.DateTimeStyles]::AssumeUniversal
      ).ToUnixTimeMilliseconds()
    } catch {
      Throw-Fixed -Class "visible_response_not_observed"
    }
    $visibleDelta = [long]$visibleWallMs - $utteranceEndWallMs
    if ($visibleDelta -lt 0 -or $visibleDelta -gt $DeadlineMs) {
      Throw-Fixed -Class "visible_response_not_observed"
    }
    $utteranceEndToFirstVisibleMs = [int]$visibleDelta
    $visibleObservation = $null
  }
  if ($null -ne $productionTransportProcess) {
    $remainingProductionMs = Get-RemainingRouteBudgetMs
    $productionObservation = Complete-ProductionTransportChild `
      -Process $productionTransportProcess `
      -TimeoutMs $remainingProductionMs `
      -RouteDeadlineMs $productionRouteDeadlineMs
    $productionTransportProcess.Dispose()
    $productionTransportProcess = $null
    if ($null -eq $utteranceEndWallMs) {
      Throw-Fixed -Class "production_transport_not_completed"
    }
    $firstAudioWallMs = [long]$productionObservation.first_non_silent_observed_at_utc_ms
    $audioDelta = Resolve-UtteranceEndToFirstAudioMs `
      -UtteranceEndWallMs $utteranceEndWallMs `
      -FirstAudioWallMs $firstAudioWallMs `
      -RouteDeadlineMs $DeadlineMs
    $firstNonSilentAudioObservationClass = [string]$productionObservation.observer_result_class
    $utteranceEndToFirstAudioMs = [int]$audioDelta
    $productionObservation = $null
  }
  $deadlineClass = "within_deadline"
  $endpointResult = $null
  $baseUri = $null
  $endpointUri = $null
} catch [System.OperationCanceledException] {
  Set-Failure -Class "whole_route_timeout"
} catch [System.Net.Http.HttpRequestException] {
  Set-Failure -Class "live_controller_endpoint_unreachable"
} catch {
  $failureClass = if (
    $AllowedControllerFailureClasses -ccontains [string]$_.Exception.Message
  ) {
    [string]$_.Exception.Message
  } else {
    "live_controller_failed"
  }
  Set-Failure -Class $failureClass
} finally {
  foreach ($resource in @($response, $content, $request, $client, $cancellation, $handler)) {
    if ($null -ne $resource) {
      try {
        $resource.Dispose()
      } catch {
        $controllerCleanupClear = $false
      }
    }
  }
  if ($null -ne $visibleObserverProcess) {
    try {
      if (-not $visibleObserverProcess.HasExited) {
        try { $visibleObserverProcess.StandardInput.Close() } catch {}
        if (-not $visibleObserverProcess.WaitForExit(1000)) {
          $visibleObserverProcess.Kill($true)
          $controllerCleanupClear = $false
        }
      }
    } catch {
      $controllerCleanupClear = $false
    } finally {
      $visibleObserverProcess.Dispose()
      $visibleObserverProcess = $null
    }
  }
  if ($null -ne $productionTransportProcess) {
    if (-not (Stop-ProductionTransportChild -Process $productionTransportProcess)) {
      $controllerCleanupClear = $false
    }
    $productionTransportProcess = $null
  }
  $response = $null
  $content = $null
  $request = $null
  $client = $null
  $cancellation = $null
  $handler = $null
  $token = ""
  $requestJson = ""
  $requestBody = $null
  $aitUri = $null
  $productionObservation = $null
}

$controllerStopwatch.Stop()
if ($null -ne $userPhaseStopwatch) {
  $userPhaseStopwatch.Stop()
}
$controllerElapsedMs = [Math]::Min(
  20000,
  [Math]::Max(
    0,
    [int]$(if ($null -ne $userPhaseStopwatch) {
        $userPhaseStopwatch.ElapsedMilliseconds
      } else {
        $controllerStopwatch.ElapsedMilliseconds
      })))
if ($endpointResponseObserved -and $cleanupClass -ceq "controller_http_resources_disposed_no_request_started") {
  $cleanupClass = "controller_http_resources_disposed_endpoint_cleanup_unverified"
} elseif ($requestStarted -and -not $endpointResponseObserved) {
  $endpointCompletionClass = "unverified_after_transport_end"
  $cleanupClass = "controller_http_resources_disposed_endpoint_completion_unverified"
}
if (-not $controllerCleanupClear) {
  $controllerStatus = "error"
  $blockerClass = "cleanup_incomplete"
  $cleanupClass = "cleanup_incomplete"
  $exitCode = 1
} elseif ($endpointResponseObserved -and $controllerElapsedMs -gt $DeadlineMs -and $exitCode -eq 0) {
  $controllerStatus = "error"
  $blockerClass = "whole_route_timeout"
  $deadlineClass = "exceeded"
  $exitCode = 1
} elseif ($blockerClass -ceq "whole_route_timeout") {
  $deadlineClass = "exceeded"
}

$result = [ordered]@{
  schema_version = "self_output_awareness.live_controller.v0"
  controller_status = $controllerStatus
  scenario = $safeScenario
  result_class = $resultClass
  expectation_class = $expectationClass
  accepted_join_class = $acceptedJoinClass
  capture_packet_count = $capturePacketCount
  capture_byte_count = $captureByteCount
  signal_class = $signalClass
  vad_decision_class = $vadDecisionClass
  transcription_count = $transcriptionCount
  submission_count = $submissionCount
  thought_core_turninput_count = $turnInputCount
  endpoint_elapsed_ms = $endpointElapsedMs
  last_vad_speech_frame_offset_ms = $lastVadSpeechFrameOffsetMs
  utterance_end_to_candidate_result_ms = $utteranceEndToCandidateResultMs
  utterance_end_timing_class = $utteranceEndTimingClass
  stt_start_offset_ms = $sttStartOffsetMs
  stt_end_offset_ms = $sttEndOffsetMs
  canonical_accept_offset_ms = $canonicalAcceptOffsetMs
  canonical_accept_latency_class = $canonicalAcceptLatencyClass
  inflight_sink_cancellation_class = $inflightSinkCancellationClass
  presentation_class = $presentationClass
  thought_core_first_event_elapsed_ms = $thoughtCoreFirstEventElapsedMs
  visible_response_class = $visibleResponseClass
  visible_match_count = $visibleMatchCount
  first_visible_observer_elapsed_ms = $firstVisibleObserverElapsedMs
  utterance_end_to_first_visible_ms = $utteranceEndToFirstVisibleMs
  first_non_silent_audio_observation_class = $firstNonSilentAudioObservationClass
  utterance_end_to_first_audio_ms = $utteranceEndToFirstAudioMs
  controller_elapsed_ms = $controllerElapsedMs
  window_ms = $WindowMs
  deadline_ms = $DeadlineMs
  deadline_class = $deadlineClass
  endpoint_completion_class = $endpointCompletionClass
  http_status_class = $httpStatusClass
  pcm_cleanup_count = $pcmCleanupCount
  private_authority_residue_count = $privateAuthorityResidueCount
  route_owned_process_residue_count = $(if ($controllerCleanupClear) { 0 } else { 1 })
  route_owned_temp_residue_count = 0
  route_owned_request_residue_count = $(if ($controllerCleanupClear) { 0 } else { 1 })
  cleanup_class = $cleanupClass
  blocker_class = $blockerClass
  raw_audio_shared = $false
  raw_text_shared = $false
  private_identifier_shared = $false
  private_environment_shared = $false
  raw_private_publication_flags = $false
}

if ($Json) {
  $result | ConvertTo-Json -Depth 4 -Compress
} else {
  foreach ($property in $result.GetEnumerator()) {
    if ($property.Value -is [bool]) {
      Write-Output ("{0}={1}" -f $property.Key, ([string]$property.Value).ToLowerInvariant())
    } elseif ($null -ne $property.Value) {
      Write-Output ("{0}={1}" -f $property.Key, $property.Value)
    }
  }
}

if ($exitCode -ne 0) {
  exit 1
}
