param(
  [string]$BaseUrl = "http://127.0.0.1:8000",
  [string]$Scenario = "self_output_or_ambiguous",
  [int]$WindowMs = 1000,
  [int]$DeadlineMs = 5000,
  [switch]$Json
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$ExpectedResponseKeys = @(
  "schema_version",
  "result_class",
  "expectation_class",
  "capture_packet_count",
  "capture_byte_count",
  "signal_class",
  "vad_decision_class",
  "transcription_count",
  "submission_count",
  "thought_core_turninput_count",
  "elapsed_ms",
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
$AllowedScenarios = @(
  "self_output_or_ambiguous",
  "independent_current_session_user_speech"
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
  "input_gate_capability_unavailable",
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
  "live_controller_failed",
  "whole_route_timeout",
  "cleanup_incomplete"
)

$controllerStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
$handler = $null
$client = $null
$request = $null
$content = $null
$response = $null
$cancellation = $null
$token = ""
$requestJson = ""
$requestBody = $null
$controllerCleanupClear = $true
$requestStarted = $false
$endpointResponseObserved = $false
$exitCode = 1

$controllerStatus = "error"
$safeScenario = "invalid"
$resultClass = "not_observed"
$expectationClass = "not_evaluated"
$capturePacketCount = 0
$captureByteCount = 0
$signalClass = "not_evaluated"
$vadDecisionClass = "not_evaluated"
$transcriptionCount = 0
$submissionCount = 0
$turnInputCount = 0
$endpointElapsedMs = 0
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

function Assert-BoundedInteger {
  param(
    [Parameter(Mandatory = $true)]$Value,
    [Parameter(Mandatory = $true)][long]$Minimum,
    [Parameter(Mandatory = $true)][long]$Maximum
  )

  if (
    $Value -is [bool] -or
    ($Value -isnot [int] -and $Value -isnot [long]) -or
    [long]$Value -lt $Minimum -or
    [long]$Value -gt $Maximum
  ) {
    Throw-Fixed -Class "live_controller_endpoint_response_invalid"
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

function Set-Failure {
  param([Parameter(Mandatory = $true)][string]$Class)

  $script:controllerStatus = "error"
  $script:blockerClass = $Class
  $script:exitCode = 1
}

try {
  if (
    $AllowedScenarios -cnotcontains $Scenario -or
    $WindowMs -lt 100 -or
    $WindowMs -gt 3000 -or
    $DeadlineMs -lt ($WindowMs + 200) -or
    $DeadlineMs -gt 10000
  ) {
    Throw-Fixed -Class "live_controller_configuration_invalid"
  }
  $safeScenario = $Scenario

  $baseUri = Resolve-LoopbackBaseUri -Value $BaseUrl
  $token = [System.Environment]::GetEnvironmentVariable("AI_TALK_CORE_WEB_TOKEN", "Process")
  if ([string]::IsNullOrWhiteSpace($token)) {
    Throw-Fixed -Class "live_controller_token_unavailable"
  }

  $endpointUri = [System.Uri]::new($baseUri, "/api/live-input-gate/candidate-window")
  $requestBody = [ordered]@{
    scenario = $Scenario
    window_ms = $WindowMs
    deadline_ms = $DeadlineMs
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
  $cancellation.CancelAfter($DeadlineMs)
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
    $endpointResult.signal_class -isnot [string] -or
    $AllowedSignalClasses -cnotcontains [string]$endpointResult.signal_class -or
    $endpointResult.vad_decision_class -isnot [string] -or
    $AllowedVadDecisionClasses -cnotcontains [string]$endpointResult.vad_decision_class -or
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

  $resultClass = [string]$endpointResult.result_class
  $expectationClass = [string]$endpointResult.expectation_class
  $capturePacketCount = [int]$endpointResult.capture_packet_count
  $captureByteCount = [int]$endpointResult.capture_byte_count
  $signalClass = [string]$endpointResult.signal_class
  $vadDecisionClass = [string]$endpointResult.vad_decision_class
  $transcriptionCount = [int]$endpointResult.transcription_count
  $submissionCount = [int]$endpointResult.submission_count
  $turnInputCount = [int]$endpointResult.thought_core_turninput_count
  $endpointElapsedMs = [int]$endpointResult.elapsed_ms
  $pcmCleanupCount = [int]$endpointResult.pcm_cleanup_count
  $privateAuthorityResidueCount = [int]$endpointResult.private_authority_residue_count

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
      $turnInputCount -ne 0
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
      $turnInputCount -ne 1
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
  $response = $null
  $content = $null
  $request = $null
  $client = $null
  $cancellation = $null
  $handler = $null
  $token = ""
  $requestJson = ""
  $requestBody = $null
}

$controllerStopwatch.Stop()
$controllerElapsedMs = [Math]::Min(20000, [Math]::Max(0, [int]$controllerStopwatch.ElapsedMilliseconds))
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
  capture_packet_count = $capturePacketCount
  capture_byte_count = $captureByteCount
  signal_class = $signalClass
  vad_decision_class = $vadDecisionClass
  transcription_count = $transcriptionCount
  submission_count = $submissionCount
  thought_core_turninput_count = $turnInputCount
  endpoint_elapsed_ms = $endpointElapsedMs
  controller_elapsed_ms = $controllerElapsedMs
  window_ms = $WindowMs
  deadline_ms = $DeadlineMs
  deadline_class = $deadlineClass
  endpoint_completion_class = $endpointCompletionClass
  http_status_class = $httpStatusClass
  pcm_cleanup_count = $pcmCleanupCount
  private_authority_residue_count = $privateAuthorityResidueCount
  route_owned_process_residue_count = 0
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
