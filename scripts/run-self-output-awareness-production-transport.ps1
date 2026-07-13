[CmdletBinding()]
param(
  [string]$AitBaseUrl = "http://127.0.0.1:3000",
  [string]$AiTalkCoreBaseUrl = "http://127.0.0.1:8000",
  [int]$ControlledChromeRootPid = 0,
  [int]$ObserverWindowMs = 3000,
  [int]$DeadlineMs = 10000,
  [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$LifecycleStates = @("handoff_accepted", "cooldown", "released")
$TransportKeys = @(
  "schema_version",
  "lifecycle",
  "client_timestamp_wall",
  "client_timestamp_monotonic",
  "client_performance_now",
  "raw_private_publication_flags",
  "transition_ordinal"
)
$AitResponseKeys = @("ok", "result_class", "transport", "raw_private_publication_flags")
$LifecycleKeys = @(
  "schema_version",
  "system_speech_session_id",
  "speech_session_generation",
  "playback_event_ref",
  "lifecycle_state",
  "queue_handoff_status",
  "queue_completion_status",
  "playback_observation_status",
  "suppression_status",
  "cooldown_status",
  "cooldown_ms",
  "compare_and_release_required",
  "may_start_user_turn",
  "turn_adoption_authority",
  "raw_text_published",
  "text_hash_published",
  "provider_payload_published",
  "path_published",
  "url_published",
  "raw_audio_published",
  "device_identity_published",
  "private_data_published"
)
$ObserverKeys = @(
  "schema_version",
  "source_class",
  "proof_ceiling",
  "result_class",
  "capability_class",
  "attribution_class",
  "observation",
  "lifecycle",
  "privacy",
  "authority",
  "does_not_prove"
)

function Throw-Fixed {
  param([Parameter(Mandatory)][string]$Class)
  throw [System.InvalidOperationException]::new($Class)
}

function Assert-ExactKeys {
  param(
    [Parameter(Mandatory)]$Value,
    [Parameter(Mandatory)][string[]]$Expected,
    [Parameter(Mandatory)][string]$FailureClass
  )
  if ($null -eq $Value -or $Value -isnot [PSCustomObject]) {
    Throw-Fixed -Class $FailureClass
  }
  $actualKeys = @($Value.PSObject.Properties.Name | Sort-Object)
  $expectedKeys = @($Expected | Sort-Object)
  if (($actualKeys -join "`n") -cne ($expectedKeys -join "`n")) {
    Throw-Fixed -Class $FailureClass
  }
}

function Resolve-LoopbackBaseUri {
  param([Parameter(Mandatory)][string]$Value)
  $uri = $null
  if (-not [Uri]::TryCreate($Value, [UriKind]::Absolute, [ref]$uri)) {
    Throw-Fixed -Class "transport_configuration_invalid"
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
    Throw-Fixed -Class "transport_configuration_invalid"
  }
  return $uri
}

function Test-BoundedNumber {
  param($Value, [double]$Minimum, [double]$Maximum)
  if ($Value -is [bool] -or $Value -isnot [ValueType]) { return $false }
  try { $number = [double]$Value } catch { return $false }
  return [double]::IsFinite($number) -and $number -ge $Minimum -and $number -le $Maximum
}

function Test-ExactInteger {
  param($Value, [long]$Minimum, [long]$Maximum)
  if (
    $Value -is [bool] -or
    ($Value -isnot [int] -and $Value -isnot [long])
  ) {
    return $false
  }
  $number = [long]$Value
  return $number -ge $Minimum -and $number -le $Maximum
}

function Assert-LifecycleTransport {
  param([Parameter(Mandatory)]$Transport)
  Assert-ExactKeys -Value $Transport -Expected $TransportKeys -FailureClass "lifecycle_transport_invalid"
  if (
    [string]$Transport.schema_version -cne "ait_system_speech_lifecycle_transport.v0" -or
    $Transport.raw_private_publication_flags -isnot [bool] -or
    [bool]$Transport.raw_private_publication_flags -or
    $Transport.transition_ordinal -is [bool] -or
    $Transport.transition_ordinal -isnot [long] -and $Transport.transition_ordinal -isnot [int] -or
    [long]$Transport.transition_ordinal -lt 1 -or
    -not (Test-BoundedNumber $Transport.client_timestamp_monotonic 0 1000000000000) -or
    -not (Test-BoundedNumber $Transport.client_performance_now 0 1000000000000)
  ) {
    Throw-Fixed -Class "lifecycle_transport_invalid"
  }
  $parsedWall = [DateTimeOffset]::MinValue
  if (
    $Transport.client_timestamp_wall -isnot [string] -or
    [string]$Transport.client_timestamp_wall -notmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,6})?Z$' -or
    -not [DateTimeOffset]::TryParse([string]$Transport.client_timestamp_wall, [ref]$parsedWall)
  ) {
    Throw-Fixed -Class "lifecycle_transport_invalid"
  }

  $lifecycle = $Transport.lifecycle
  Assert-ExactKeys -Value $lifecycle -Expected $LifecycleKeys -FailureClass "lifecycle_transport_invalid"
  $state = [string]$lifecycle.lifecycle_state
  $expectedStateGuards = switch ($state) {
    "handoff_accepted" { @("pending", "active", "clear") }
    "cooldown" { @("callback_observed", "active", "active") }
    "released" { @("callback_observed", "released", "elapsed") }
    default { Throw-Fixed -Class "lifecycle_transport_invalid" }
  }
  $falseKeys = @(
    "may_start_user_turn", "turn_adoption_authority", "raw_text_published",
    "text_hash_published", "provider_payload_published", "path_published",
    "url_published", "raw_audio_published", "device_identity_published",
    "private_data_published"
  )
  foreach ($key in $falseKeys) {
    if ($lifecycle.$key -isnot [bool] -or [bool]$lifecycle.$key) {
      Throw-Fixed -Class "lifecycle_transport_invalid"
    }
  }
  if (
    [string]$lifecycle.schema_version -cne "ait_system_speech_lifecycle.v0" -or
    [string]$lifecycle.system_speech_session_id -notmatch '^system-speech-session:sss_[a-f0-9]{32}$' -or
    $lifecycle.speech_session_generation -is [bool] -or
    ($lifecycle.speech_session_generation -isnot [long] -and $lifecycle.speech_session_generation -isnot [int]) -or
    [long]$lifecycle.speech_session_generation -lt 1 -or
    [string]$lifecycle.playback_event_ref -notmatch '^playback-event:pe_[a-f0-9]{32}$' -or
    [string]$lifecycle.queue_handoff_status -cne "accepted" -or
    [string]$lifecycle.queue_completion_status -cne $expectedStateGuards[0] -or
    [string]$lifecycle.playback_observation_status -cne "not_observed" -or
    [string]$lifecycle.suppression_status -cne $expectedStateGuards[1] -or
    [string]$lifecycle.cooldown_status -cne $expectedStateGuards[2] -or
    $lifecycle.cooldown_ms -is [bool] -or
    ($lifecycle.cooldown_ms -isnot [long] -and $lifecycle.cooldown_ms -isnot [int]) -or
    [long]$lifecycle.cooldown_ms -lt 0 -or
    [long]$lifecycle.cooldown_ms -gt 2000 -or
    $lifecycle.compare_and_release_required -isnot [bool] -or
    -not [bool]$lifecycle.compare_and_release_required
  ) {
    Throw-Fixed -Class "lifecycle_transport_invalid"
  }
  return $Transport
}

function Resolve-LifecycleStep {
  param(
    [Parameter(Mandatory)]$Transport,
    [Parameter(Mandatory)][long]$LastOrdinal,
    [Parameter(Mandatory)][string]$ExpectedState,
    [AllowNull()]$Lease
  )
  $validated = Assert-LifecycleTransport -Transport $Transport
  if ([long]$validated.transition_ordinal -ne $LastOrdinal + 1) {
    Throw-Fixed -Class "lifecycle_transport_incomplete"
  }
  $lifecycle = $validated.lifecycle
  if ([string]$lifecycle.lifecycle_state -cne $ExpectedState) {
    Throw-Fixed -Class "lifecycle_transition_mismatch"
  }
  if ($null -ne $Lease -and (
      [string]$lifecycle.system_speech_session_id -cne [string]$Lease.system_speech_session_id -or
      [long]$lifecycle.speech_session_generation -ne [long]$Lease.speech_session_generation -or
      [string]$lifecycle.playback_event_ref -cne [string]$Lease.playback_event_ref
    )) {
    Throw-Fixed -Class "lifecycle_lease_mismatch"
  }
  return $validated
}

function Assert-AitResponse {
  param([Parameter(Mandatory)]$Response)
  if ($null -eq $Response -or $Response.status_code -ne 200) {
    Throw-Fixed -Class "ait_lifecycle_unreachable"
  }
  Assert-ExactKeys -Value $Response.body -Expected $AitResponseKeys -FailureClass "lifecycle_transport_invalid"
  if (
    $Response.body.ok -isnot [bool] -or
    -not [bool]$Response.body.ok -or
    $Response.body.raw_private_publication_flags -isnot [bool] -or
    [bool]$Response.body.raw_private_publication_flags
  ) {
    Throw-Fixed -Class "lifecycle_transport_invalid"
  }
  $expectedResultClass = $(if ($null -eq $Response.body.transport) {
      "lifecycle_transport_empty"
    } else {
      "lifecycle_transport_current"
    })
  if ([string]$Response.body.result_class -cne $expectedResultClass) {
    Throw-Fixed -Class "lifecycle_transport_invalid"
  }
  return $Response.body.transport
}

function Assert-CoreAcknowledgement {
  param(
    [Parameter(Mandatory)]$Response,
    [Parameter(Mandatory)][string]$ExpectedEvent,
    [Parameter(Mandatory)][string]$ExpectedTurnId,
    [Parameter(Mandatory)][string]$ExpectedWall,
    [Parameter(Mandatory)][double]$ExpectedMonotonic,
    [Parameter(Mandatory)][string]$FailureClass
  )
  if ($null -eq $Response -or $Response.status_code -ne 202) {
    Throw-Fixed -Class $FailureClass
  }
  Assert-ExactKeys -Value $Response.body -Expected @("ok", "event") -FailureClass $FailureClass
  if ($Response.body.ok -isnot [bool] -or -not [bool]$Response.body.ok) {
    Throw-Fixed -Class $FailureClass
  }
  $eventValue = $Response.body.event
  Assert-ExactKeys -Value $eventValue -Expected @(
    "turn_id", "event", "timestamp_wall", "timestamp_monotonic", "source", "payload"
  ) -FailureClass $FailureClass
  Assert-ExactKeys -Value $eventValue.payload -Expected @(
    "client_timestamp_wall", "client_timestamp_monotonic", "client_performance_now"
  ) -FailureClass $FailureClass
  $serverWall = [DateTimeOffset]::MinValue
  if (
    [string]$eventValue.turn_id -cne $ExpectedTurnId -or
    [string]$eventValue.event -cne $ExpectedEvent -or
    [string]$eventValue.source -cne "self-output-awareness-controller" -or
    $eventValue.timestamp_wall -isnot [string] -or
    -not [DateTimeOffset]::TryParse([string]$eventValue.timestamp_wall, [ref]$serverWall) -or
    -not (Test-BoundedNumber $eventValue.timestamp_monotonic 0 1000000000000) -or
    [string]$eventValue.payload.client_timestamp_wall -cne $ExpectedWall -or
    -not (Test-BoundedNumber $eventValue.payload.client_timestamp_monotonic 0 1000000000000) -or
    -not (Test-BoundedNumber $eventValue.payload.client_performance_now 0 1000000000000) -or
    [double]$eventValue.payload.client_timestamp_monotonic -ne $ExpectedMonotonic -or
    [double]$eventValue.payload.client_performance_now -ne $ExpectedMonotonic
  ) {
    Throw-Fixed -Class $FailureClass
  }
  return $eventValue
}

function New-SelfOutputObservationPayload {
  param([Parameter(Mandatory)]$Lease)
  return [ordered]@{
    schema_version = "audio_self_output_observation.v0"
    self_output_observation_ref = "self-output-observation:aso_$([Guid]::NewGuid().ToString('N'))"
    system_speech_session_id = [string]$Lease.system_speech_session_id
    speech_session_generation = [long]$Lease.speech_session_generation
    playback_event_ref = [string]$Lease.playback_event_ref
    observation_status = "current"
    observation_owner = "leased_tts_process_observer"
    may_start_user_turn = $false
    turn_adoption_authority = $false
    raw_private_publication_flags = $false
  }
}

function New-CoreEventEnvelope {
  param(
    [Parameter(Mandatory)][string]$Event,
    [Parameter(Mandatory)]$Payload,
    [Parameter(Mandatory)][string]$TurnId,
    [Parameter(Mandatory)][string]$Wall,
    [Parameter(Mandatory)][double]$Monotonic
  )
  return [ordered]@{
    event = $Event
    turn_id = $TurnId
    source = "self-output-awareness-controller"
    payload = $Payload
    client_timestamp_wall = $Wall
    client_timestamp_monotonic = $Monotonic
    client_performance_now = $Monotonic
  }
}

function Invoke-JsonRequest {
  param(
    [Parameter(Mandatory)][Uri]$Uri,
    [Parameter(Mandatory)][string]$Method,
    [AllowNull()]$Body,
    [AllowNull()][string]$Token,
    [Parameter(Mandatory)][int]$TimeoutMs,
    [Parameter(Mandatory)][string]$FailureClass
  )
  $handler = $null
  $client = $null
  $request = $null
  $content = $null
  $response = $null
  $cancellation = $null
  $bodyJson = ""
  try {
    $handler = [Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect = $false
    $handler.UseCookies = $false
    $handler.UseProxy = $false
    $client = [Net.Http.HttpClient]::new($handler, $false)
    $request = [Net.Http.HttpRequestMessage]::new(
      [Net.Http.HttpMethod]::new($Method), $Uri)
    if ($null -ne $Body) {
      $bodyJson = $Body | ConvertTo-Json -Depth 8 -Compress
      $content = [Net.Http.StringContent]::new(
        $bodyJson, [Text.Encoding]::UTF8, "application/json")
      $request.Content = $content
    }
    if (-not [string]::IsNullOrWhiteSpace($Token)) {
      [void]$request.Headers.TryAddWithoutValidation("X-AI-Core-Token", $Token)
    }
    $bodyJson = ""
    $Token = ""
    $cancellation = [Threading.CancellationTokenSource]::new()
    $cancellation.CancelAfter($TimeoutMs)
    $response = $client.SendAsync(
      $request,
      [Net.Http.HttpCompletionOption]::ResponseContentRead,
      $cancellation.Token).GetAwaiter().GetResult()
    $responseText = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
    if ([Text.Encoding]::UTF8.GetByteCount($responseText) -gt 32768) {
      Throw-Fixed -Class $FailureClass
    }
    try { $responseBody = $responseText | ConvertFrom-Json -Depth 12 }
    catch { Throw-Fixed -Class $FailureClass }
    finally { $responseText = "" }
    return [pscustomobject]@{
      status_code = [int]$response.StatusCode
      body = $responseBody
    }
  } catch [OperationCanceledException] {
    Throw-Fixed -Class "whole_route_timeout"
  } catch [Net.Http.HttpRequestException] {
    Throw-Fixed -Class $FailureClass
  } finally {
    if ($null -ne $response) { $response.Dispose() }
    if ($null -ne $content) { $content.Dispose() }
    if ($null -ne $request) { $request.Dispose() }
    if ($null -ne $cancellation) { $cancellation.Dispose() }
    if ($null -ne $client) { $client.Dispose() }
    if ($null -ne $handler) { $handler.Dispose() }
    $bodyJson = ""
    $Token = ""
  }
}

function Start-ObserverChild {
  param(
    [Parameter(Mandatory)][string]$ObserverPath,
    [Parameter(Mandatory)][int]$TargetPid,
    [Parameter(Mandatory)][int]$WindowMs,
    [Parameter(Mandatory)][int]$ObserverDeadlineMs
  )
  $pwshPath = "C:\Program Files\PowerShell\7\pwsh.exe"
  if (-not (Test-Path -LiteralPath $pwshPath -PathType Leaf)) {
    $pwshPath = (Get-Command pwsh -ErrorAction Stop).Source
  }
  $startInfo = [Diagnostics.ProcessStartInfo]::new()
  $startInfo.FileName = $pwshPath
  $startInfo.UseShellExecute = $false
  $startInfo.CreateNoWindow = $true
  $startInfo.RedirectStandardOutput = $true
  $startInfo.RedirectStandardError = $true
  [void]$startInfo.Environment.Remove("AI_TALK_CORE_WEB_TOKEN")
  foreach ($argument in @(
      "-NoProfile", "-File", $ObserverPath,
      "-Mode", "live_process_tree",
      "-TargetProcessId", [string]$TargetPid,
      "-WindowMs", [string]$WindowMs,
      "-DeadlineMs", [string]$ObserverDeadlineMs,
      "-Compact"
    )) {
    [void]$startInfo.ArgumentList.Add($argument)
  }
  $process = [Diagnostics.Process]::new()
  $process.StartInfo = $startInfo
  if (-not $process.Start()) {
    $process.Dispose()
    Throw-Fixed -Class "observer_child_start_failed"
  }
  return $process
}

function Assert-ObserverResult {
  param([Parameter(Mandatory)]$Value, [Parameter(Mandatory)][int]$WindowMs)
  Assert-ExactKeys -Value $Value -Expected $ObserverKeys -FailureClass "observer_result_invalid"
  $observationKeys = @(
    "window_ms", "packet_count", "frame_count", "non_silent_frame_count",
    "silent_frame_count", "first_non_silent_frame_offset_ms", "live_capture_used"
  )
  Assert-ExactKeys -Value $Value.observation -Expected $observationKeys -FailureClass "observer_result_invalid"
  Assert-ExactKeys -Value $Value.lifecycle -Expected @(
    "capture_start_count", "capture_stop_attempt_count", "capture_stop_count",
    "buffer_release_count", "resource_release_count", "cancel_count",
    "cleanup_class", "owned_process_residue_count", "temporary_residue_count"
  ) -FailureClass "observer_result_invalid"
  Assert-ExactKeys -Value $Value.privacy -Expected @(
    "raw_pcm_published", "raw_audio_persisted", "transcript_observed",
    "target_process_identity_published", "device_or_endpoint_identity_published",
    "private_path_published", "payload_published"
  ) -FailureClass "observer_result_invalid"
  Assert-ExactKeys -Value $Value.authority -Expected @(
    "microphone_capture_authority", "turn_input_authority",
    "speech_acceptance_authority", "aec_selection_authority",
    "user_heard_authority", "readiness_authority"
  ) -FailureClass "observer_result_invalid"
  $expectedDoesNotProve = @(
    "microphone_capture", "aec_effectiveness", "self_output_classification",
    "user_speech_separation", "turn_input_enforcement", "user_heard_audio",
    "release_readiness"
  )
  $privacyKeys = @(
    "raw_pcm_published", "raw_audio_persisted", "transcript_observed",
    "target_process_identity_published", "device_or_endpoint_identity_published",
    "private_path_published", "payload_published"
  )
  $authorityKeys = @(
    "microphone_capture_authority", "turn_input_authority",
    "speech_acceptance_authority", "aec_selection_authority",
    "user_heard_authority", "readiness_authority"
  )
  foreach ($key in @($privacyKeys + $authorityKeys)) {
    $container = $(if ($privacyKeys -ccontains $key) { $Value.privacy } else { $Value.authority })
    if ($container.$key -isnot [bool] -or [bool]$container.$key) {
      Throw-Fixed -Class "observer_result_invalid"
    }
  }
  $lifecycleIntegerKeys = @(
    "capture_start_count", "capture_stop_attempt_count", "capture_stop_count",
    "buffer_release_count", "resource_release_count", "cancel_count",
    "owned_process_residue_count", "temporary_residue_count"
  )
  foreach ($key in $lifecycleIntegerKeys) {
    if (-not (Test-ExactInteger $Value.lifecycle.$key 0 1000000)) {
      Throw-Fixed -Class "observer_result_invalid"
    }
  }
  if (
    $Value.does_not_prove -isnot [Array] -or
    @($Value.does_not_prove).Count -ne 7 -or
    @($Value.does_not_prove | Where-Object { $_ -isnot [string] }).Count -ne 0
  ) {
    Throw-Fixed -Class "observer_result_invalid"
  }
  if (
    [string]$Value.schema_version -cne "process_loopback_observation.v0" -or
    [string]$Value.source_class -cne "live_process_loopback" -or
    [string]$Value.proof_ceiling -cne "process_loopback_observation_summary_only" -or
    [string]$Value.result_class -cne "process_tree_render_observed" -or
    [string]$Value.capability_class -cne "process_loopback_capability_available" -or
    [string]$Value.attribution_class -cne "target_process_tree_included" -or
    (@($Value.does_not_prove) -join "`n") -cne ($expectedDoesNotProve -join "`n") -or
    -not (Test-ExactInteger $Value.observation.window_ms 0 5000) -or
    [long]$Value.observation.window_ms -ne $WindowMs -or
    -not (Test-ExactInteger $Value.observation.packet_count 1 1000000) -or
    -not (Test-ExactInteger $Value.observation.frame_count 1 1000000000000) -or
    -not (Test-ExactInteger $Value.observation.non_silent_frame_count 1 1000000000000) -or
    -not (Test-ExactInteger $Value.observation.silent_frame_count 0 1000000000000) -or
    [long]$Value.observation.frame_count -ne (
      [long]$Value.observation.non_silent_frame_count + [long]$Value.observation.silent_frame_count) -or
    $Value.observation.live_capture_used -isnot [bool] -or
    -not [bool]$Value.observation.live_capture_used -or
    [long]$Value.observation.non_silent_frame_count -lt 1 -or
    -not (Test-ExactInteger $Value.observation.first_non_silent_frame_offset_ms 0 $WindowMs) -or
    [long]$Value.observation.first_non_silent_frame_offset_ms -gt $WindowMs -or
    [long]$Value.lifecycle.capture_start_count -ne 1 -or
    [long]$Value.lifecycle.capture_stop_attempt_count -ne 1 -or
    [long]$Value.lifecycle.capture_stop_count -ne 1 -or
    [long]$Value.lifecycle.buffer_release_count -ne [long]$Value.observation.packet_count -or
    [long]$Value.lifecycle.resource_release_count -lt 1 -or
    [long]$Value.lifecycle.cancel_count -ne 0 -or
    [string]$Value.lifecycle.cleanup_class -cne "route_owned_cleanup_clear" -or
    [long]$Value.lifecycle.owned_process_residue_count -ne 0 -or
    [long]$Value.lifecycle.temporary_residue_count -ne 0 -or
    [long]$Value.lifecycle.temporary_residue_count -ne 0
  ) {
    Throw-Fixed -Class "observer_result_invalid"
  }
  return $Value
}

function Invoke-ProductionTransportRoute {
param(
  [Parameter(Mandatory)][string]$RouteAitBaseUrl,
  [Parameter(Mandatory)][string]$RouteAiTalkCoreBaseUrl,
  [Parameter(Mandatory)][int]$RouteControlledChromeRootPid,
  [Parameter(Mandatory)][int]$RouteObserverWindowMs,
  [Parameter(Mandatory)][int]$RouteDeadlineMs,
  [scriptblock]$RequestInvoker = ${function:Invoke-JsonRequest},
  [scriptblock]$ObserverStarter = ${function:Start-ObserverChild},
  [scriptblock]$SleepInvoker = { param([int]$Milliseconds) Start-Sleep -Milliseconds $Milliseconds },
  [AllowNull()][string]$CoreTokenOverride = $null
)
$routeStopwatch = [Diagnostics.Stopwatch]::StartNew()
$observerProcess = $null
$cleanupClear = $true
$status = "blocked"
$resultClass = "transport_not_completed"
$blockerClass = "transport_failed"
$lifecycleIngestCount = 0
$observationIngestCount = 0
$lifecycleIngestOutcomeClass = "not_dispatched"
$observationIngestOutcomeClass = "not_dispatched"
$aitPollCount = 0
$coreRequestCount = 0
$finalLifecycleState = "not_observed"
$observerResultClass = "not_observed"
$firstNonSilentFrameOffsetMs = $null
$handoffPickupMs = $null
$cooldownPickupMs = $null
$releasedPickupMs = $null
$observationIngestMs = $null
$exitCode = 1
$coreToken = ""

try {
  if (
    $RouteControlledChromeRootPid -le 0 -or
    $RouteObserverWindowMs -lt 100 -or
    $RouteObserverWindowMs -gt 5000 -or
    $RouteDeadlineMs -lt $RouteObserverWindowMs + 1000 -or
    $RouteDeadlineMs -gt 15000
  ) {
    Throw-Fixed -Class "transport_configuration_invalid"
  }
  $aitUri = Resolve-LoopbackBaseUri -Value $RouteAitBaseUrl
  $coreUri = Resolve-LoopbackBaseUri -Value $RouteAiTalkCoreBaseUrl
  $coreToken = $(if ($PSBoundParameters.ContainsKey("CoreTokenOverride")) {
      [string]$CoreTokenOverride
    } else {
      [Environment]::GetEnvironmentVariable("AI_TALK_CORE_WEB_TOKEN", "Process")
    })
  if ([string]::IsNullOrWhiteSpace($coreToken)) {
    Throw-Fixed -Class "core_token_unavailable"
  }
  $aitEndpoint = [Uri]::new($aitUri, "/api/self-output-awareness-transport/")
  $coreEndpoint = [Uri]::new($coreUri, "/api/events/ingest")
  $turnId = "web_$([Guid]::NewGuid().ToString('N'))"
  $observerPath = [IO.Path]::GetFullPath(
    (Join-Path $PSScriptRoot "..\runtime\audio-awareness\windows\invoke-process-loopback-observer.ps1"))
  if (-not (Test-Path -LiteralPath $observerPath -PathType Leaf)) {
    Throw-Fixed -Class "observer_child_unavailable"
  }

  $remaining = $RouteDeadlineMs - [int]$routeStopwatch.ElapsedMilliseconds
  $baselineResponse = & $RequestInvoker -Uri $aitEndpoint -Method "GET" -Body $null -Token $null -TimeoutMs $remaining -FailureClass "ait_lifecycle_unreachable"
  $aitPollCount += 1
  $baselineTransport = Assert-AitResponse -Response $baselineResponse
  $lastOrdinal = 0L
  $baselineLease = $null
  if ($null -ne $baselineTransport) {
    $baseline = Assert-LifecycleTransport -Transport $baselineTransport
    $lastOrdinal = [long]$baseline.transition_ordinal
    $baselineLease = [pscustomobject]@{
      system_speech_session_id = [string]$baseline.lifecycle.system_speech_session_id
      speech_session_generation = [long]$baseline.lifecycle.speech_session_generation
      playback_event_ref = [string]$baseline.lifecycle.playback_event_ref
    }
  }
  $baselineResponse = $null

  $lease = $null
  $lastClientMonotonic = -1.0
  for ($stateIndex = 0; $stateIndex -lt $LifecycleStates.Count; ) {
    $remaining = $RouteDeadlineMs - [int]$routeStopwatch.ElapsedMilliseconds
    if ($remaining -le 50) { Throw-Fixed -Class "whole_route_timeout" }
    & $SleepInvoker 20
    $response = & $RequestInvoker -Uri $aitEndpoint -Method "GET" -Body $null -Token $null -TimeoutMs $remaining -FailureClass "ait_lifecycle_unreachable"
    $aitPollCount += 1
    $responseTransport = Assert-AitResponse -Response $response
    if ($null -eq $responseTransport) {
      Throw-Fixed -Class "lifecycle_transport_incomplete"
    }
    $candidateOrdinal = [long]$responseTransport.transition_ordinal
    if ($candidateOrdinal -eq $lastOrdinal) {
      $response = $null
      continue
    }
    $step = Resolve-LifecycleStep -Transport $responseTransport -LastOrdinal $lastOrdinal -ExpectedState $LifecycleStates[$stateIndex] -Lease $lease
    if ([double]$step.client_timestamp_monotonic -lt $lastClientMonotonic) {
      Throw-Fixed -Class "lifecycle_timing_mismatch"
    }
    $lastClientMonotonic = [double]$step.client_timestamp_monotonic
    if ($null -eq $lease) {
      if ($null -ne $baselineLease -and (
          [long]$step.lifecycle.speech_session_generation -le [long]$baselineLease.speech_session_generation -or
          ([string]$step.lifecycle.system_speech_session_id -ceq [string]$baselineLease.system_speech_session_id -and
            [string]$step.lifecycle.playback_event_ref -ceq [string]$baselineLease.playback_event_ref)
        )) {
        Throw-Fixed -Class "lifecycle_stale_generation_replay"
      }
      $lease = [pscustomobject]@{
        system_speech_session_id = [string]$step.lifecycle.system_speech_session_id
        speech_session_generation = [long]$step.lifecycle.speech_session_generation
        playback_event_ref = [string]$step.lifecycle.playback_event_ref
      }
    }
    $event = New-CoreEventEnvelope -Event "swordAgentSystemSpeechLifecycleV0" -Payload $step.lifecycle -TurnId $turnId -Wall ([string]$step.client_timestamp_wall) -Monotonic ([double]$step.client_timestamp_monotonic)
    $remaining = $RouteDeadlineMs - [int]$routeStopwatch.ElapsedMilliseconds
    if ($remaining -le 0) { Throw-Fixed -Class "whole_route_timeout" }
    $lifecycleIngestOutcomeClass = "dispatched_ack_pending"
    $coreRequestCount += 1
    $coreResponse = & $RequestInvoker -Uri $coreEndpoint -Method "POST" -Body $event -Token $coreToken -TimeoutMs $remaining -FailureClass "core_lifecycle_ingest_failed"
    [void](Assert-CoreAcknowledgement -Response $coreResponse -ExpectedEvent "swordAgentSystemSpeechLifecycleV0" -ExpectedTurnId $turnId -ExpectedWall ([string]$step.client_timestamp_wall) -ExpectedMonotonic ([double]$step.client_timestamp_monotonic) -FailureClass "core_lifecycle_ingest_failed")
    $event.Clear()
    $lifecycleIngestCount += 1
    $lifecycleIngestOutcomeClass = "acknowledged"
    $lastOrdinal = [long]$step.transition_ordinal
    $finalLifecycleState = [string]$step.lifecycle.lifecycle_state
    switch ($finalLifecycleState) {
      "handoff_accepted" {
        $handoffPickupMs = [int]$routeStopwatch.ElapsedMilliseconds
        $observerDeadline = [Math]::Min(10000, $RouteObserverWindowMs + 1500)
        $observerProcess = & $ObserverStarter -ObserverPath $observerPath -TargetPid $RouteControlledChromeRootPid -WindowMs $RouteObserverWindowMs -ObserverDeadlineMs $observerDeadline
      }
      "cooldown" { $cooldownPickupMs = [int]$routeStopwatch.ElapsedMilliseconds }
      "released" { $releasedPickupMs = [int]$routeStopwatch.ElapsedMilliseconds }
    }
    $stateIndex += 1
    $response = $null
    $step = $null
    $coreResponse = $null
  }

  if ($null -eq $observerProcess) { Throw-Fixed -Class "observer_child_start_failed" }
  $remaining = $RouteDeadlineMs - [int]$routeStopwatch.ElapsedMilliseconds
  if ($remaining -le 0 -or -not $observerProcess.WaitForExit($remaining)) {
    Throw-Fixed -Class "whole_route_timeout"
  }
  $observerText = $observerProcess.StandardOutput.ReadToEnd().Trim()
  $observerError = $observerProcess.StandardError.ReadToEnd()
  if ($observerProcess.ExitCode -ne 0 -or -not [string]::IsNullOrWhiteSpace($observerError) -or [Text.Encoding]::UTF8.GetByteCount($observerText) -gt 32768) {
    $observerText = ""
    $observerError = ""
    Throw-Fixed -Class "observer_child_failed"
  }
  try { $observerValue = $observerText | ConvertFrom-Json -Depth 12 }
  catch { Throw-Fixed -Class "observer_result_invalid" }
  finally {
    $observerText = ""
    $observerError = ""
  }
  $observerValue = Assert-ObserverResult -Value $observerValue -WindowMs $RouteObserverWindowMs
  $observerResultClass = [string]$observerValue.result_class
  $firstNonSilentFrameOffsetMs = [int]$observerValue.observation.first_non_silent_frame_offset_ms

  $observationPayload = New-SelfOutputObservationPayload -Lease $lease
  $nowMonotonic = [double]$routeStopwatch.Elapsed.TotalMilliseconds
  $observationWall = [DateTimeOffset]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
  $observationEvent = New-CoreEventEnvelope -Event "audioSelfOutputObservationV0" -Payload $observationPayload -TurnId $turnId -Wall $observationWall -Monotonic $nowMonotonic
  $remaining = $RouteDeadlineMs - [int]$routeStopwatch.ElapsedMilliseconds
  if ($remaining -le 0) { Throw-Fixed -Class "whole_route_timeout" }
  $observationIngestOutcomeClass = "dispatched_ack_pending"
  $coreRequestCount += 1
  $observationResponse = & $RequestInvoker -Uri $coreEndpoint -Method "POST" -Body $observationEvent -Token $coreToken -TimeoutMs $remaining -FailureClass "core_observation_ingest_failed"
  [void](Assert-CoreAcknowledgement -Response $observationResponse -ExpectedEvent "audioSelfOutputObservationV0" -ExpectedTurnId $turnId -ExpectedWall $observationWall -ExpectedMonotonic $nowMonotonic -FailureClass "core_observation_ingest_failed")
  $observationEvent.Clear()
  $observationPayload.Clear()
  $observationIngestCount = 1
  $observationIngestOutcomeClass = "acknowledged"
  $observationIngestMs = [int]$routeStopwatch.ElapsedMilliseconds
  $coreToken = ""
  $status = "completed"
  $resultClass = "production_self_output_transport_completed"
  $blockerClass = $null
  $exitCode = 0
} catch {
  if ($lifecycleIngestOutcomeClass -ceq "dispatched_ack_pending") {
    $lifecycleIngestCount = $null
    $lifecycleIngestOutcomeClass = "dispatched_ack_unknown"
  }
  if ($observationIngestOutcomeClass -ceq "dispatched_ack_pending") {
    $observationIngestCount = $null
    $observationIngestOutcomeClass = "dispatched_ack_unknown"
  }
  $allowed = @(
    "transport_configuration_invalid", "core_token_unavailable",
    "observer_child_unavailable", "ait_lifecycle_unreachable",
    "lifecycle_transport_invalid", "lifecycle_transport_incomplete",
    "lifecycle_transition_mismatch", "lifecycle_lease_mismatch",
    "lifecycle_timing_mismatch", "core_lifecycle_ingest_failed",
    "lifecycle_stale_generation_replay",
    "observer_child_start_failed", "observer_child_failed",
    "observer_result_invalid", "core_observation_ingest_failed",
    "whole_route_timeout"
  )
  $class = [string]$_.Exception.Message
  $blockerClass = if ($allowed -ccontains $class) { $class } else { "transport_failed" }
  $resultClass = "production_self_output_transport_blocked"
  $exitCode = 1
} finally {
  $coreToken = ""
  if ($null -ne $observerProcess) {
    try {
      if (-not $observerProcess.HasExited) {
        $observerProcess.Kill($true)
        if (-not $observerProcess.WaitForExit(2000)) { $cleanupClear = $false }
      }
    } catch { $cleanupClear = $false }
    try { $observerProcess.Dispose() } catch { $cleanupClear = $false }
  }
  if (-not $cleanupClear) {
    $status = "blocked"
    $resultClass = "production_self_output_transport_blocked"
    $blockerClass = "cleanup_incomplete"
    $exitCode = 1
  }
}

$result = [ordered]@{
  schema_version = "self_output_awareness.production_transport.v0"
  status = $status
  result_class = $resultClass
  blocker_class = $blockerClass
  lifecycle_ingest_count = $lifecycleIngestCount
  observation_ingest_count = $observationIngestCount
  lifecycle_ingest_outcome_class = $lifecycleIngestOutcomeClass
  observation_ingest_outcome_class = $observationIngestOutcomeClass
  ait_poll_count = $aitPollCount
  core_request_count = $coreRequestCount
  final_lifecycle_state = $finalLifecycleState
  observer_result_class = $observerResultClass
  first_non_silent_frame_offset_ms = $firstNonSilentFrameOffsetMs
  handoff_pickup_ms = $handoffPickupMs
  cooldown_pickup_ms = $cooldownPickupMs
  released_pickup_ms = $releasedPickupMs
  observation_ingest_ms = $observationIngestMs
  elapsed_ms = [int]$routeStopwatch.ElapsedMilliseconds
  latency_requirement_status = "last_accepted_speech_frame_timestamp_not_available"
  cleanup_class = $(if ($cleanupClear) { "route_owned_cleanup_clear" } else { "cleanup_incomplete" })
  route_owned_process_residue_count = $(if ($cleanupClear) { 0 } else { $null })
  route_owned_request_residue_count = 0
  route_owned_pipe_residue_count = 0
  route_owned_temp_residue_count = 0
  audio_route_change_count = 0
  microphone_route_change_count = 0
  candidate_authority = $false
  acceptance_authority = $false
  turn_input_authority = $false
  raw_audio_shared = $false
  raw_text_shared = $false
  private_identifier_shared = $false
  private_environment_shared = $false
  raw_private_publication_flags = $false
}
return [pscustomobject]@{
  Value = [pscustomobject]$result
  ExitCode = $exitCode
}
}

if ($MyInvocation.InvocationName -eq ".") { return }

$execution = Invoke-ProductionTransportRoute `
  -RouteAitBaseUrl $AitBaseUrl `
  -RouteAiTalkCoreBaseUrl $AiTalkCoreBaseUrl `
  -RouteControlledChromeRootPid $ControlledChromeRootPid `
  -RouteObserverWindowMs $ObserverWindowMs `
  -RouteDeadlineMs $DeadlineMs
$convertParameters = @{ Depth = 6 }
if ($Json) { $convertParameters.Compress = $true }
$execution.Value | ConvertTo-Json @convertParameters
exit $execution.ExitCode
