[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path -Parent $PSScriptRoot
$ControllerPath = Join-Path $PSScriptRoot "run-self-output-awareness-production-transport.ps1"
$ObserverSourcePath = Join-Path $RepoRoot "runtime\audio-awareness\windows\ProcessLoopbackObserver.cs"
$ObserverWrapperPath = Join-Path $RepoRoot "runtime\audio-awareness\windows\invoke-process-loopback-observer.ps1"
$pwsh = Get-Command pwsh -ErrorAction Stop
$script:AssertionCount = 0

function Assert-True {
  param([bool]$Condition, [Parameter(Mandatory)][string]$Message)
  $script:AssertionCount += 1
  if (-not $Condition) { throw "assertion_failed:$Message" }
}

function Assert-Equal {
  param($Actual, $Expected, [Parameter(Mandatory)][string]$Message)
  Assert-True ($Actual -eq $Expected) $Message
}

function Assert-FixedFailure {
  param(
    [Parameter(Mandatory)][scriptblock]$Action,
    [Parameter(Mandatory)][string]$Expected,
    [Parameter(Mandatory)][string]$Message
  )
  $actual = "no_failure"
  try { & $Action } catch { $actual = [string]$_.Exception.Message }
  Assert-Equal $actual $Expected $Message
}

function Assert-ParserClear {
  param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Message)
  $tokens = $null
  $errors = $null
  [void][Management.Automation.Language.Parser]::ParseFile(
    $Path, [ref]$tokens, [ref]$errors)
  Assert-Equal @($errors).Count 0 $Message
}

function New-Lifecycle {
  param(
    [Parameter(Mandatory)][string]$State,
    [int]$Generation = 7,
    [string]$SessionId = "system-speech-session:sss_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    [string]$PlaybackRef = "playback-event:pe_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  )
  $guards = switch ($State) {
    "handoff_accepted" { @("pending", "active", "clear") }
    "cooldown" { @("callback_observed", "active", "active") }
    "released" { @("callback_observed", "released", "elapsed") }
    default { throw "invalid_test_state" }
  }
  return [pscustomobject][ordered]@{
    schema_version = "ait_system_speech_lifecycle.v0"
    system_speech_session_id = $SessionId
    speech_session_generation = $Generation
    playback_event_ref = $PlaybackRef
    lifecycle_state = $State
    queue_handoff_status = "accepted"
    queue_completion_status = $guards[0]
    playback_observation_status = "not_observed"
    suppression_status = $guards[1]
    cooldown_status = $guards[2]
    cooldown_ms = 500
    compare_and_release_required = $true
    may_start_user_turn = $false
    turn_adoption_authority = $false
    raw_text_published = $false
    text_hash_published = $false
    provider_payload_published = $false
    path_published = $false
    url_published = $false
    raw_audio_published = $false
    device_identity_published = $false
    private_data_published = $false
  }
}

function New-Transport {
  param(
    [Parameter(Mandatory)][string]$State,
    [Parameter(Mandatory)][int]$Ordinal,
    [int]$Generation = 7,
    [string]$SessionId = "system-speech-session:sss_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    [string]$PlaybackRef = "playback-event:pe_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  )
  return [pscustomobject][ordered]@{
    schema_version = "ait_system_speech_lifecycle_transport.v0"
    lifecycle = New-Lifecycle -State $State -Generation $Generation -SessionId $SessionId -PlaybackRef $PlaybackRef
    client_timestamp_wall = "2026-07-13T07:30:00.000Z"
    client_timestamp_monotonic = [double](100 + $Ordinal)
    client_performance_now = [double](100 + $Ordinal)
    raw_private_publication_flags = $false
    transition_ordinal = $Ordinal
  }
}

function New-ObserverResult {
  return [pscustomobject][ordered]@{
    schema_version = "process_loopback_observation.v0"
    source_class = "live_process_loopback"
    proof_ceiling = "process_loopback_observation_summary_only"
    result_class = "process_tree_render_observed"
    capability_class = "process_loopback_capability_available"
    attribution_class = "target_process_tree_included"
    observation = [pscustomobject][ordered]@{
      window_ms = 1000
      packet_count = 4
      frame_count = 512
      non_silent_frame_count = 256
      silent_frame_count = 256
      first_non_silent_frame_offset_ms = 25
      live_capture_used = $true
      capture_started_at_utc_ms = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    }
    lifecycle = [pscustomobject]@{
      capture_start_count = 1
      capture_stop_attempt_count = 1
      capture_stop_count = 1
      buffer_release_count = 4
      resource_release_count = 1
      cancel_count = 0
      cleanup_class = "route_owned_cleanup_clear"
      owned_process_residue_count = 0
      temporary_residue_count = 0
    }
    privacy = [pscustomobject]@{
      raw_pcm_published = $false
      raw_audio_persisted = $false
      transcript_observed = $false
      target_process_identity_published = $false
      device_or_endpoint_identity_published = $false
      private_path_published = $false
      payload_published = $false
    }
    authority = [pscustomobject]@{
      microphone_capture_authority = $false
      turn_input_authority = $false
      speech_acceptance_authority = $false
      aec_selection_authority = $false
      user_heard_authority = $false
      readiness_authority = $false
    }
    does_not_prove = @(
      "microphone_capture", "aec_effectiveness", "self_output_classification",
      "user_speech_separation", "turn_input_enforcement", "user_heard_audio",
      "release_readiness"
    )
  }
}

function New-AitResponse {
  param([AllowNull()]$Transport)
  return [pscustomobject]@{
    status_code = 200
    body = [pscustomobject][ordered]@{
      ok = $true
      result_class = $(if ($null -eq $Transport) { "lifecycle_transport_empty" } else { "lifecycle_transport_current" })
      transport = $Transport
      raw_private_publication_flags = $false
    }
  }
}

function New-CoreAcknowledgement {
  param([Parameter(Mandatory)]$RequestBody)
  return [pscustomobject]@{
    status_code = 202
    body = [pscustomobject][ordered]@{
      ok = $true
      event = [pscustomobject][ordered]@{
        turn_id = [string]$RequestBody.turn_id
        event = [string]$RequestBody.event
        timestamp_wall = "2026-07-13T07:30:00.500Z"
        timestamp_monotonic = [double]500
        source = "self-output-awareness-controller"
        payload = [pscustomobject][ordered]@{
          client_timestamp_wall = [string]$RequestBody.client_timestamp_wall
          client_timestamp_monotonic = [double]$RequestBody.client_timestamp_monotonic
          client_performance_now = [double]$RequestBody.client_performance_now
        }
      }
    }
  }
}

function New-FakeObserverProcess {
  param(
    [bool]$ExitImmediately = $true,
    $ObserverResult = (New-ObserverResult)
  )
  $observerJson = $ObserverResult | ConvertTo-Json -Depth 8 -Compress
  $value = [pscustomobject]@{
    HasExited = $ExitImmediately
    ExitCode = 0
    StandardOutput = [IO.StringReader]::new($observerJson)
    StandardError = [IO.StringReader]::new("")
    KillCount = 0
    DisposeCount = 0
  }
  $value | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value {
    param([int]$Milliseconds)
    return [bool]$this.HasExited
  }
  $value | Add-Member -MemberType ScriptMethod -Name Kill -Value {
    param([bool]$EntireProcessTree)
    $this.KillCount += 1
    $this.HasExited = $true
  }
  $value | Add-Member -MemberType ScriptMethod -Name Dispose -Value {
    $this.DisposeCount += 1
    $this.StandardOutput.Dispose()
    $this.StandardError.Dispose()
  }
  return $value
}

function New-ControlledRouteHarness {
  param(
    [ValidateSet("success", "future_derived_wall", "delayed_start", "released_restart_lower_generation", "superseded_generation", "superseded_generation_silent_new", "history_overflow", "ordinal_gap", "lease_mismatch", "stale_replay", "ack_unknown", "timeout")]
    [string]$Mode
  )
  $state = [pscustomobject]@{
    AitReadCount = 0
    AitQueries = [Collections.ArrayList]::new()
    CoreBodies = [Collections.ArrayList]::new()
    ObserverStartCount = 0
    ListenerReadyCount = 0
    ArmedCount = 0
    LastObserverResult = $null
    ObserverProcess = $null
    ObserverProcesses = [Collections.ArrayList]::new()
  }
  $requestInvoker = {
    param($Uri, $Method, $Body, $Token, $TimeoutMs, $FailureClass)
    if ($Uri.AbsolutePath -ceq "/api/self-output-awareness-transport/") {
      [void]$state.AitQueries.Add([string]$Uri.Query)
      $readIndex = $state.AitReadCount
      $state.AitReadCount += 1
      if ($Mode -ceq "stale_replay") {
        if ($readIndex -eq 0) { return New-AitResponse (New-Transport "released" 9 -Generation 7) }
        return New-AitResponse (New-Transport "handoff_accepted" 10 -Generation 7 -PlaybackRef "playback-event:pe_cccccccccccccccccccccccccccccccc")
      }
      if ($Mode -ceq "released_restart_lower_generation") {
        if ($readIndex -eq 0) {
          return New-AitResponse (New-Transport "released" 9 -Generation 7)
        }
        $restartArgs = @{
          Generation = 1
          SessionId = "system-speech-session:sss_cccccccccccccccccccccccccccccccc"
          PlaybackRef = "playback-event:pe_dddddddddddddddddddddddddddddddd"
        }
        switch ($readIndex) {
          1 { return New-AitResponse (New-Transport "handoff_accepted" 10 @restartArgs) }
          2 { return New-AitResponse (New-Transport "cooldown" 11 @restartArgs) }
          default { return New-AitResponse (New-Transport "released" 12 @restartArgs) }
        }
      }
      $lifecycleIndex = $(if ($Mode -ceq "delayed_start") { $readIndex - 2 } else { $readIndex })
      if ($lifecycleIndex -le 0) { return New-AitResponse $null }
      if ($Mode -in @("superseded_generation", "superseded_generation_silent_new")) {
        switch ($lifecycleIndex) {
          1 { return New-AitResponse (New-Transport "handoff_accepted" 1) }
          2 { return New-AitResponse (New-Transport "cooldown" 2) }
          3 { return New-AitResponse (New-Transport "handoff_accepted" 3 -Generation 8 -SessionId "system-speech-session:sss_cccccccccccccccccccccccccccccccc" -PlaybackRef "playback-event:pe_dddddddddddddddddddddddddddddddd") }
          4 { return New-AitResponse (New-Transport "cooldown" 4 -Generation 8 -SessionId "system-speech-session:sss_cccccccccccccccccccccccccccccccc" -PlaybackRef "playback-event:pe_dddddddddddddddddddddddddddddddd") }
          default { return New-AitResponse (New-Transport "released" 5 -Generation 8 -SessionId "system-speech-session:sss_cccccccccccccccccccccccccccccccc" -PlaybackRef "playback-event:pe_dddddddddddddddddddddddddddddddd") }
        }
      }
      if ($Mode -ceq "history_overflow") {
        $generation = [int](7 + [Math]::Floor(($lifecycleIndex - 1) / 2))
        $stateName = $(if ($lifecycleIndex % 2 -eq 1) { "handoff_accepted" } else { "cooldown" })
        $sessionId = "system-speech-session:sss_$('{0:x32}' -f $generation)"
        $playbackRef = "playback-event:pe_$('{0:x32}' -f ($generation + 32))"
        return New-AitResponse (New-Transport $stateName $lifecycleIndex -Generation $generation -SessionId $sessionId -PlaybackRef $playbackRef)
      }
      if ($lifecycleIndex -eq 1) {
        $ordinal = $(if ($Mode -ceq "ordinal_gap") { 2 } else { 1 })
        return New-AitResponse (New-Transport "handoff_accepted" $ordinal)
      }
      if ($lifecycleIndex -eq 2) {
        $ref = $(if ($Mode -ceq "lease_mismatch") {
            "playback-event:pe_ffffffffffffffffffffffffffffffff"
          } else {
            "playback-event:pe_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
          })
        return New-AitResponse (New-Transport "cooldown" 2 -PlaybackRef $ref)
      }
      return New-AitResponse (New-Transport "released" 3)
    }
    Assert-Equal $Token "fixed-test-core-token" "Core request uses expected token"
    $copy = ($Body | ConvertTo-Json -Depth 8 -Compress) | ConvertFrom-Json -Depth 8
    [void]$state.CoreBodies.Add($copy)
    if ($Mode -ceq "ack_unknown" -and $state.CoreBodies.Count -eq 1) {
      throw [Net.Http.HttpRequestException]::new("fixed-test-ambiguous-dispatch")
    }
    return New-CoreAcknowledgement -RequestBody $Body
  }.GetNewClosure()
  $observerStarter = {
    param($ObserverPath, $TargetPid, $WindowMs, $ObserverDeadlineMs)
    $state.ObserverStartCount += 1
    Assert-Equal $state.CoreBodies[$state.CoreBodies.Count - 1].payload.lifecycle_state "handoff_accepted" "observer starts only after an acknowledged handoff"
    $observerResult = New-ObserverResult
    if ($Mode -ceq "superseded_generation_silent_new" -and $state.ObserverStartCount -eq 2) {
      $observerResult.observation.non_silent_frame_count = 0
      $observerResult.observation.silent_frame_count = 512
      $observerResult.observation.first_non_silent_frame_offset_ms = -1
    }
    if ($Mode -ceq "future_derived_wall") {
      $observerResult.observation.capture_started_at_utc_ms =
        [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() + 900
      $observerResult.observation.first_non_silent_frame_offset_ms = 1000
    }
    $state.LastObserverResult = $observerResult
    $observerProcess = New-FakeObserverProcess -ExitImmediately ($Mode -ne "timeout") -ObserverResult $observerResult
    $state.ObserverProcess = $observerProcess
    [void]$state.ObserverProcesses.Add($observerProcess)
    return $observerProcess
  }.GetNewClosure()
  return [pscustomobject]@{
    State = $state
    RequestInvoker = $requestInvoker
    ObserverStarter = $observerStarter
    SleepInvoker = { param([int]$Milliseconds) }.GetNewClosure()
  }
}

Assert-ParserClear $ControllerPath "controller parser"
Assert-ParserClear $ObserverWrapperPath "observer wrapper parser"

. $ControllerPath

$loopback = Resolve-LoopbackBaseUri -Value "http://127.0.0.1:3000"
Assert-Equal $loopback.Host "127.0.0.1" "loopback host retained"
Assert-FixedFailure { Resolve-LoopbackBaseUri -Value "https://private.invalid/path" } "transport_configuration_invalid" "remote URL rejected"
Assert-FixedFailure { Resolve-LoopbackBaseUri -Value "http://user@127.0.0.1:3000/" } "transport_configuration_invalid" "userinfo rejected"
Assert-FixedFailure { Resolve-LoopbackBaseUri -Value "http://127.0.0.1:3000/?private=1" } "transport_configuration_invalid" "query rejected"

$emptyAit = Assert-AitResponse -Response (New-AitResponse $null)
Assert-Equal $emptyAit $null "exact empty AIT response accepted"
$currentAit = Assert-AitResponse -Response (New-AitResponse (New-Transport "handoff_accepted" 1))
Assert-Equal $currentAit.transition_ordinal 1 "exact current AIT response accepted"
$aitOkMutation = New-AitResponse $null
$aitOkMutation.body.ok = "true"
Assert-FixedFailure { Assert-AitResponse -Response $aitOkMutation } "lifecycle_transport_invalid" "truth-equivalent AIT ok rejected"
$aitClassMutation = New-AitResponse $null
$aitClassMutation.body.result_class = "other"
Assert-FixedFailure { Assert-AitResponse -Response $aitClassMutation } "lifecycle_transport_invalid" "AIT result class mutation rejected"
$aitPrivacyMutation = New-AitResponse $null
$aitPrivacyMutation.body.raw_private_publication_flags = $true
Assert-FixedFailure { Assert-AitResponse -Response $aitPrivacyMutation } "lifecycle_transport_invalid" "AIT privacy-positive response rejected"

$coreEvent = New-CoreEventEnvelope -Event "swordAgentSystemSpeechLifecycleV0" -Payload (New-Lifecycle "handoff_accepted") -TurnId "web_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" -Wall "2026-07-13T07:30:00.000Z" -Monotonic 101
$coreAck = New-CoreAcknowledgement -RequestBody $coreEvent
[void](Assert-CoreAcknowledgement -Response $coreAck -ExpectedEvent "swordAgentSystemSpeechLifecycleV0" -ExpectedTurnId "web_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" -ExpectedWall "2026-07-13T07:30:00.000Z" -ExpectedMonotonic 101 -FailureClass "core_lifecycle_ingest_failed")
$coreOkMutation = New-CoreAcknowledgement -RequestBody $coreEvent
$coreOkMutation.body.ok = 1
Assert-FixedFailure { Assert-CoreAcknowledgement -Response $coreOkMutation -ExpectedEvent "swordAgentSystemSpeechLifecycleV0" -ExpectedTurnId "web_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" -ExpectedWall "2026-07-13T07:30:00.000Z" -ExpectedMonotonic 101 -FailureClass "core_lifecycle_ingest_failed" } "core_lifecycle_ingest_failed" "truth-equivalent Core ok rejected"
$coreCorrelationMutation = New-CoreAcknowledgement -RequestBody $coreEvent
$coreCorrelationMutation.body.event.turn_id = "web_ffffffffffffffffffffffffffffffff"
Assert-FixedFailure { Assert-CoreAcknowledgement -Response $coreCorrelationMutation -ExpectedEvent "swordAgentSystemSpeechLifecycleV0" -ExpectedTurnId "web_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" -ExpectedWall "2026-07-13T07:30:00.000Z" -ExpectedMonotonic 101 -FailureClass "core_lifecycle_ingest_failed" } "core_lifecycle_ingest_failed" "Core correlation mutation rejected"
$coreLeakMutation = New-CoreAcknowledgement -RequestBody $coreEvent
$coreLeakMutation.body.event | Add-Member -NotePropertyName transcript -NotePropertyValue "private marker"
Assert-FixedFailure { Assert-CoreAcknowledgement -Response $coreLeakMutation -ExpectedEvent "swordAgentSystemSpeechLifecycleV0" -ExpectedTurnId "web_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" -ExpectedWall "2026-07-13T07:30:00.000Z" -ExpectedMonotonic 101 -FailureClass "core_lifecycle_ingest_failed" } "core_lifecycle_ingest_failed" "Core extra private field rejected"
$coreTimingTypeMutation = New-CoreAcknowledgement -RequestBody $coreEvent
$coreTimingTypeMutation.body.event.payload.client_timestamp_monotonic = "101"
Assert-FixedFailure { Assert-CoreAcknowledgement -Response $coreTimingTypeMutation -ExpectedEvent "swordAgentSystemSpeechLifecycleV0" -ExpectedTurnId "web_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" -ExpectedWall "2026-07-13T07:30:00.000Z" -ExpectedMonotonic 101 -FailureClass "core_lifecycle_ingest_failed" } "core_lifecycle_ingest_failed" "Core numeric-string timing rejected"

$handoffStep = Resolve-LifecycleStep -Transport (New-Transport "handoff_accepted" 1) -LastOrdinal 0 -Lease $null -Phase "awaiting_handoff"
$handoff = $handoffStep.transport
$lease = $handoffStep.lease
$cooldownStep = Resolve-LifecycleStep -Transport (New-Transport "cooldown" 2) -LastOrdinal 1 -Lease $lease -Phase $handoffStep.phase
$cooldown = $cooldownStep.transport
$releasedStep = Resolve-LifecycleStep -Transport (New-Transport "released" 3) -LastOrdinal 2 -Lease $cooldownStep.lease -Phase $cooldownStep.phase
$released = $releasedStep.transport
Assert-Equal $handoff.lifecycle.lifecycle_state "handoff_accepted" "handoff accepted"
Assert-Equal $cooldown.lifecycle.lifecycle_state "cooldown" "cooldown accepted"
Assert-Equal $released.lifecycle.lifecycle_state "released" "release accepted"
Assert-Equal $releasedStep.completed $true "release completes the active lifecycle"

Assert-FixedFailure {
  Resolve-LifecycleStep -Transport (New-Transport "cooldown" 3) -LastOrdinal 1 -Lease $lease -Phase "handoff_accepted"
} "lifecycle_transport_incomplete" "ordinal gap rejected"
Assert-FixedFailure {
  Resolve-LifecycleStep -Transport (New-Transport "released" 2) -LastOrdinal 1 -Lease $lease -Phase "handoff_accepted"
} "lifecycle_transition_mismatch" "wrong state rejected"
Assert-FixedFailure {
  Resolve-LifecycleStep -Transport (New-Transport "cooldown" 2 -PlaybackRef "playback-event:pe_ffffffffffffffffffffffffffffffff") -LastOrdinal 1 -Lease $lease -Phase "handoff_accepted"
} "lifecycle_lease_mismatch" "changed playback ref rejected"
Assert-FixedFailure {
  Resolve-LifecycleStep -Transport (New-Transport "handoff_accepted" 2 -Generation 7 -SessionId "system-speech-session:sss_cccccccccccccccccccccccccccccccc" -PlaybackRef "playback-event:pe_dddddddddddddddddddddddddddddddd") -LastOrdinal 1 -Lease $lease -Phase "handoff_accepted"
} "lifecycle_stale_generation_replay" "equal-generation replacement rejected"
Assert-FixedFailure {
  Resolve-LifecycleStep -Transport (New-Transport "handoff_accepted" 2 -Generation 6 -SessionId "system-speech-session:sss_cccccccccccccccccccccccccccccccc" -PlaybackRef "playback-event:pe_dddddddddddddddddddddddddddddddd") -LastOrdinal 1 -Lease $lease -Phase "handoff_accepted"
} "lifecycle_stale_generation_replay" "lower-generation replacement rejected"

$authorityMutation = New-Transport "handoff_accepted" 1
$authorityMutation.lifecycle.may_start_user_turn = $true
Assert-FixedFailure {
  Resolve-LifecycleStep -Transport $authorityMutation -LastOrdinal 0 -Lease $null -Phase "awaiting_handoff"
} "lifecycle_transport_invalid" "authority mutation rejected"
$extraFieldMutation = New-Transport "handoff_accepted" 1
$extraFieldMutation | Add-Member -NotePropertyName transcript -NotePropertyValue "private transcript marker"
Assert-FixedFailure {
  Resolve-LifecycleStep -Transport $extraFieldMutation -LastOrdinal 0 -Lease $null -Phase "awaiting_handoff"
} "lifecycle_transport_invalid" "extra private field rejected"

$observationPayload = New-SelfOutputObservationPayload -Lease $lease
Assert-Equal ($observationPayload.Keys -join ",") "schema_version,self_output_observation_ref,system_speech_session_id,speech_session_generation,playback_event_ref,observation_status,observation_owner,may_start_user_turn,turn_adoption_authority,raw_private_publication_flags" "observation keys exact"
Assert-True ([string]$observationPayload.self_output_observation_ref -match '^self-output-observation:aso_[a-f0-9]{32}$') "observation ref opaque"
Assert-Equal $observationPayload.may_start_user_turn $false "observation cannot start turn"
Assert-Equal $observationPayload.turn_adoption_authority $false "observation has no adoption authority"

$observer = Assert-ObserverResult -Value (New-ObserverResult) -WindowMs 1000
Assert-Equal $observer.observation.first_non_silent_frame_offset_ms 25 "first-frame offset accepted"
Assert-Equal (Resolve-FirstNonSilentObservedAtUtcMs `
    -CaptureStartedAtUtcMs 123000 `
    -FirstNonSilentFrameOffsetMs 25 `
    -ObserverCompletedAtUtcMs 123100) 123025 `
  "capture wall plus QPC offset yields first non-silent wall"
Assert-FixedFailure {
  Resolve-FirstNonSilentObservedAtUtcMs `
    -CaptureStartedAtUtcMs 123000 `
    -FirstNonSilentFrameOffsetMs 5000 `
    -ObserverCompletedAtUtcMs 123100
} "observer_result_invalid" "derived first-audio wall cannot be in the future"
$missingCaptureMutation = New-ObserverResult
$missingCaptureMutation.observation.capture_started_at_utc_ms = $null
Assert-FixedFailure { Assert-ObserverResult -Value $missingCaptureMutation -WindowMs 1000 } "observer_result_invalid" "missing capture wall rejected"
$stringCaptureMutation = New-ObserverResult
$stringCaptureMutation.observation.capture_started_at_utc_ms = "123000"
Assert-FixedFailure { Assert-ObserverResult -Value $stringCaptureMutation -WindowMs 1000 } "observer_result_invalid" "string capture wall rejected"
$silentMutation = New-ObserverResult
$silentMutation.result_class = "process_tree_silence_observed"
$silentMutation.observation.non_silent_frame_count = 0
$silentMutation.observation.first_non_silent_frame_offset_ms = $null
Assert-FixedFailure { Assert-ObserverResult -Value $silentMutation -WindowMs 1000 } "observer_result_invalid" "silent observer rejected"
$privateObserverMutation = New-ObserverResult
$privateObserverMutation.privacy.raw_pcm_published = $true
Assert-FixedFailure { Assert-ObserverResult -Value $privateObserverMutation -WindowMs 1000 } "observer_result_invalid" "raw PCM publication rejected"
$extraObserverMutation = New-ObserverResult
$extraObserverMutation.observation | Add-Member -NotePropertyName path -NotePropertyValue "C:\private\audio.wav"
Assert-FixedFailure { Assert-ObserverResult -Value $extraObserverMutation -WindowMs 1000 } "observer_result_invalid" "observer extra field rejected"
$identityObserverMutation = New-ObserverResult
$identityObserverMutation.privacy.target_process_identity_published = $true
Assert-FixedFailure { Assert-ObserverResult -Value $identityObserverMutation -WindowMs 1000 } "observer_result_invalid" "observer identity publication rejected"
$authorityObserverMutation = New-ObserverResult
$authorityObserverMutation.authority.speech_acceptance_authority = $true
Assert-FixedFailure { Assert-ObserverResult -Value $authorityObserverMutation -WindowMs 1000 } "observer_result_invalid" "observer authority mutation rejected"
$countObserverMutation = New-ObserverResult
$countObserverMutation.lifecycle.buffer_release_count = 3
Assert-FixedFailure { Assert-ObserverResult -Value $countObserverMutation -WindowMs 1000 } "observer_result_invalid" "observer counter mismatch rejected"
$proofObserverMutation = New-ObserverResult
$proofObserverMutation.does_not_prove = @("user_intent")
Assert-FixedFailure { Assert-ObserverResult -Value $proofObserverMutation -WindowMs 1000 } "observer_result_invalid" "observer proof-ceiling mutation rejected"
$stringCounterMutation = New-ObserverResult
$stringCounterMutation.lifecycle.capture_start_count = "1"
Assert-FixedFailure { Assert-ObserverResult -Value $stringCounterMutation -WindowMs 1000 } "observer_result_invalid" "observer numeric-string counter rejected"
$booleanCounterMutation = New-ObserverResult
$booleanCounterMutation.lifecycle.capture_start_count = $true
Assert-FixedFailure { Assert-ObserverResult -Value $booleanCounterMutation -WindowMs 1000 } "observer_result_invalid" "observer boolean counter rejected"
$negativeFrameMutation = New-ObserverResult
$negativeFrameMutation.observation.silent_frame_count = -1
$negativeFrameMutation.observation.frame_count = 255
Assert-FixedFailure { Assert-ObserverResult -Value $negativeFrameMutation -WindowMs 1000 } "observer_result_invalid" "observer negative frame component rejected"
$stringProofMutation = New-ObserverResult
$stringProofMutation.does_not_prove = ($stringProofMutation.does_not_prove -join "`n")
Assert-FixedFailure { Assert-ObserverResult -Value $stringProofMutation -WindowMs 1000 } "observer_result_invalid" "observer newline-delimited proof string rejected"

$sourceText = Get-Content -LiteralPath $ControllerPath -Raw
$observerSource = Get-Content -LiteralPath $ObserverSourcePath -Raw
Assert-True ($sourceText -match 'X-AI-Core-Token') "Core token header fixed"
Assert-True ($sourceText -match 'UseProxy = \$false') "proxy disabled"
Assert-True ($sourceText -match 'AllowAutoRedirect = \$false') "redirect disabled"
Assert-True ($sourceText -match 'ConvertFrom-Json -Depth 12 -DateKind String') "wire timestamps remain contract strings"
Assert-True ($sourceText -match 'Kill\(\$true\)') "owned child cleanup present"
Assert-True ($sourceText -match 'candidate_authority = \$false') "controller has no candidate authority"
Assert-True ($sourceText -match 'turn_input_authority = \$false') "controller has no TurnInput authority"
Assert-True ($sourceText -notmatch 'WriteAllBytes|WriteAllText|\.wav|transcript\s*=') "controller persists no audio or transcript"
Assert-True ($observerSource -match 'FirstNonSilentFrameOffsetMs') "observer first-frame offset implemented"
Assert-True ($observerSource -match 'QpcPosition100Ns') "offset uses captured packet QPC position"
Assert-True ($observerSource -match 'RevalidateProcessLease[\s\S]+ActivateAsync[\s\S]+RevalidatePostActivationProcessLease[\s\S]+Start\(\)') "lease revalidated after activation before capture start"
Assert-True ($sourceText -match 'IncludeCaptureStartTimestamp') "production observer requests the capture wall anchor"

$tokenMarker = "fixed-test-core-token-must-not-enter-child"
$previousToken = [Environment]::GetEnvironmentVariable("AI_TALK_CORE_WEB_TOKEN", "Process")
$childFixturePath = Join-Path ([IO.Path]::GetTempPath()) "sword-observer-token-$([Guid]::NewGuid().ToString('N')).ps1"
$tokenChild = $null
try {
  @'
param(
  [string]$Mode,
  [int]$TargetProcessId,
  [int]$WindowMs,
  [int]$DeadlineMs,
  [switch]$Compact
)
if ([string]::IsNullOrEmpty($env:AI_TALK_CORE_WEB_TOKEN)) {
  "token_absent"
} else {
  "token_present"
}
'@ | Set-Content -LiteralPath $childFixturePath -Encoding utf8NoBOM
  [Environment]::SetEnvironmentVariable("AI_TALK_CORE_WEB_TOKEN", $tokenMarker, "Process")
  $tokenChild = Start-ObserverChild -ObserverPath $childFixturePath -TargetPid 1 -WindowMs 100 -ObserverDeadlineMs 1000
  Assert-True ($tokenChild.WaitForExit(3000)) "token-isolation child exits"
  $tokenChildOutput = $tokenChild.StandardOutput.ReadToEnd().Trim()
  $tokenChildError = $tokenChild.StandardError.ReadToEnd()
  Assert-Equal $tokenChild.ExitCode 0 "token-isolation child exit code"
  Assert-Equal $tokenChildOutput "token_absent" "observer child receives no Core token"
  Assert-Equal $tokenChildError "" "token-isolation child writes no error"
  Assert-True (-not $tokenChildOutput.Contains($tokenMarker)) "observer child never echoes Core token"
} finally {
  if ($null -ne $tokenChild) { $tokenChild.Dispose() }
  [Environment]::SetEnvironmentVariable("AI_TALK_CORE_WEB_TOKEN", $previousToken, "Process")
  Remove-Item -LiteralPath $childFixturePath -Force -ErrorAction SilentlyContinue
}
Assert-True (-not (Test-Path -LiteralPath $childFixturePath)) "token-isolation fixture leaves no residue"

$environmentHarness = New-ControlledRouteHarness -Mode "success"
$previousRouteToken = [Environment]::GetEnvironmentVariable("AI_TALK_CORE_WEB_TOKEN", "Process")
try {
  [Environment]::SetEnvironmentVariable(
    "AI_TALK_CORE_WEB_TOKEN",
    "fixed-test-core-token",
    "Process"
  )
  $environmentRoute = Invoke-ProductionTransportRoute `
    -RouteAitBaseUrl "http://127.0.0.1:3000" `
    -RouteAiTalkCoreBaseUrl "http://127.0.0.1:8000" `
    -RouteControlledChromeRootPid 1 `
    -RouteObserverWindowMs 1000 `
    -RouteDeadlineMs 3000 `
    -RequestInvoker $environmentHarness.RequestInvoker `
    -ObserverStarter $environmentHarness.ObserverStarter `
    -SleepInvoker $environmentHarness.SleepInvoker
} finally {
  [Environment]::SetEnvironmentVariable(
    "AI_TALK_CORE_WEB_TOKEN",
    $previousRouteToken,
    "Process"
  )
}
Assert-Equal $environmentRoute.ExitCode 0 "omitted token override uses process environment"
Assert-Equal $environmentRoute.Value.lifecycle_ingest_count 3 "environment token route acknowledges lifecycle"
Assert-Equal $environmentHarness.State.CoreBodies.Count 4 "environment token route sends exact Core request count"

$emptyOverrideHarness = New-ControlledRouteHarness -Mode "success"
$previousEmptyOverrideToken = [Environment]::GetEnvironmentVariable("AI_TALK_CORE_WEB_TOKEN", "Process")
try {
  [Environment]::SetEnvironmentVariable(
    "AI_TALK_CORE_WEB_TOKEN",
    "fixed-test-core-token",
    "Process"
  )
  $emptyOverrideRoute = Invoke-ProductionTransportRoute `
    -RouteAitBaseUrl "http://127.0.0.1:3000" `
    -RouteAiTalkCoreBaseUrl "http://127.0.0.1:8000" `
    -RouteControlledChromeRootPid 1 `
    -RouteObserverWindowMs 1000 `
    -RouteDeadlineMs 3000 `
    -RequestInvoker $emptyOverrideHarness.RequestInvoker `
    -ObserverStarter $emptyOverrideHarness.ObserverStarter `
    -SleepInvoker $emptyOverrideHarness.SleepInvoker `
    -CoreTokenOverride ""
} finally {
  [Environment]::SetEnvironmentVariable(
    "AI_TALK_CORE_WEB_TOKEN",
    $previousEmptyOverrideToken,
    "Process"
  )
}
Assert-Equal $emptyOverrideRoute.ExitCode 1 "explicit empty token override fails closed"
Assert-Equal $emptyOverrideRoute.Value.blocker_class "core_token_unavailable" "empty override cannot borrow environment token"
Assert-Equal $emptyOverrideHarness.State.AitReadCount 0 "empty override stops before AIT polling"
Assert-Equal $emptyOverrideHarness.State.CoreBodies.Count 0 "empty override sends no Core request"
Assert-Equal $emptyOverrideHarness.State.ObserverStartCount 0 "empty override starts no observer"
Assert-Equal $emptyOverrideRoute.Value.cleanup_class "route_owned_cleanup_clear" "empty override cleanup remains clear"

$successHarness = New-ControlledRouteHarness -Mode "success"
$listenerReadyCallback = {
  Assert-Equal $successHarness.State.AitReadCount 1 "listener ready follows the baseline read only"
  Assert-Equal $successHarness.State.ObserverStartCount 0 "listener ready precedes observer startup"
  Assert-Equal $successHarness.State.CoreBodies.Count 0 "listener ready precedes Core publication"
  $successHarness.State.ListenerReadyCount += 1
}.GetNewClosure()
$armedCallback = {
  Assert-Equal $successHarness.State.AitReadCount 2 "ready follows baseline and handoff reads"
  Assert-Equal $successHarness.State.ObserverStartCount 1 "ready follows one observer run"
  Assert-Equal $successHarness.State.CoreBodies.Count 2 "ready follows handoff and observation acknowledgements"
  Assert-Equal (@($successHarness.State.CoreBodies | ForEach-Object event) -join ",") "swordAgentSystemSpeechLifecycleV0,audioSelfOutputObservationV0" "ready proves the matching active join"
  $successHarness.State.ArmedCount += 1
}.GetNewClosure()
$successRoute = Invoke-ProductionTransportRoute `
  -RouteAitBaseUrl "http://127.0.0.1:3000" `
  -RouteAiTalkCoreBaseUrl "http://127.0.0.1:8000" `
  -RouteControlledChromeRootPid 1 `
  -RouteObserverWindowMs 1000 `
  -RouteDeadlineMs 3000 `
  -RequestInvoker $successHarness.RequestInvoker `
  -ObserverStarter $successHarness.ObserverStarter `
  -SleepInvoker $successHarness.SleepInvoker `
  -ListenerReadyCallback $listenerReadyCallback `
  -ArmedCallback $armedCallback `
  -CoreTokenOverride "fixed-test-core-token"
Assert-Equal $successRoute.ExitCode 0 "controlled success route exits clear"
Assert-Equal $successRoute.Value.lifecycle_ingest_count 3 "controlled success acknowledges three lifecycle events"
Assert-Equal $successRoute.Value.lifecycle_ingest_outcome_class "acknowledged" "controlled lifecycle outcome acknowledged"
Assert-Equal $successRoute.Value.observation_ingest_count 1 "controlled success acknowledges one observation"
Assert-Equal $successRoute.Value.observation_ingest_outcome_class "acknowledged" "controlled observation outcome acknowledged"
Assert-Equal $successHarness.State.CoreBodies.Count 4 "controlled success sends exactly four Core requests"
Assert-Equal (@($successHarness.State.CoreBodies | ForEach-Object event) -join ",") "swordAgentSystemSpeechLifecycleV0,audioSelfOutputObservationV0,swordAgentSystemSpeechLifecycleV0,swordAgentSystemSpeechLifecycleV0" "controlled success preserves overlap-ready Core event order"
Assert-Equal $successHarness.State.ObserverStartCount 1 "controlled success starts one observer"
Assert-Equal $successHarness.State.ListenerReadyCount 1 "controlled success reports listener readiness exactly once"
Assert-Equal $successHarness.State.ArmedCount 1 "controlled success reports overlap join exactly once"
Assert-Equal $successRoute.Value.overlap_join_ready_class "overlap_join_ready" "controlled success reports the fixed overlap-ready class"
Assert-Equal $successHarness.State.ObserverProcess.DisposeCount 1 "controlled success disposes observer"
Assert-Equal $successRoute.Value.first_non_silent_observed_at_utc_ms `
  ($successHarness.State.LastObserverResult.observation.capture_started_at_utc_ms + 25) `
  "controlled success returns the derived first non-silent wall"

$listenerFailureHarness = New-ControlledRouteHarness -Mode "success"
$listenerFailureRoute = Invoke-ProductionTransportRoute `
  -RouteAitBaseUrl "http://127.0.0.1:3000" `
  -RouteAiTalkCoreBaseUrl "http://127.0.0.1:8000" `
  -RouteControlledChromeRootPid 1 `
  -RouteObserverWindowMs 1000 `
  -RouteDeadlineMs 3000 `
  -RequestInvoker $listenerFailureHarness.RequestInvoker `
  -ObserverStarter $listenerFailureHarness.ObserverStarter `
  -SleepInvoker $listenerFailureHarness.SleepInvoker `
  -ListenerReadyCallback { throw "fixed-listener-failure" } `
  -CoreTokenOverride "fixed-test-core-token"
Assert-Equal $listenerFailureRoute.ExitCode 1 "listener callback failure exits closed"
Assert-Equal $listenerFailureRoute.Value.blocker_class "transport_listener_ready_failed" "listener callback failure uses a fixed class"
Assert-Equal $listenerFailureHarness.State.AitReadCount 1 "listener callback failure occurs after the baseline read"
Assert-Equal $listenerFailureHarness.State.CoreBodies.Count 0 "listener callback failure publishes no Core event"
Assert-Equal $listenerFailureHarness.State.ObserverStartCount 0 "listener callback failure starts no observer"
Assert-Equal $listenerFailureRoute.Value.cleanup_class "route_owned_cleanup_clear" "listener callback failure cleanup remains clear"

$longDeadlineHarness = New-ControlledRouteHarness -Mode "success"
$longDeadlineRoute = Invoke-ProductionTransportRoute `
  -RouteAitBaseUrl "http://127.0.0.1:3000" `
  -RouteAiTalkCoreBaseUrl "http://127.0.0.1:8000" `
  -RouteControlledChromeRootPid 1 `
  -RouteObserverWindowMs 1000 `
  -RouteDeadlineMs 30000 `
  -RequestInvoker $longDeadlineHarness.RequestInvoker `
  -ObserverStarter $longDeadlineHarness.ObserverStarter `
  -SleepInvoker $longDeadlineHarness.SleepInvoker `
  -CoreTokenOverride "fixed-test-core-token"
Assert-Equal $longDeadlineRoute.ExitCode 0 "preparation plus user phase deadline remains supported"
Assert-Equal $longDeadlineHarness.State.ArmedCount 0 "long deadline does not invent an arm callback"

$futureWallHarness = New-ControlledRouteHarness -Mode "future_derived_wall"
$futureWallRoute = Invoke-ProductionTransportRoute `
  -RouteAitBaseUrl "http://127.0.0.1:3000" `
  -RouteAiTalkCoreBaseUrl "http://127.0.0.1:8000" `
  -RouteControlledChromeRootPid 1 `
  -RouteObserverWindowMs 1000 `
  -RouteDeadlineMs 3000 `
  -RequestInvoker $futureWallHarness.RequestInvoker `
  -ObserverStarter $futureWallHarness.ObserverStarter `
  -SleepInvoker $futureWallHarness.SleepInvoker `
  -CoreTokenOverride "fixed-test-core-token"
Assert-Equal $futureWallRoute.Value.blocker_class "observer_result_invalid" "future derived first-audio wall fails closed"
Assert-Equal $futureWallRoute.Value.observation_ingest_count 0 "future derived wall performs no observation ingest"
Assert-Equal $futureWallRoute.Value.first_non_silent_observed_at_utc_ms $null "future derived wall publishes no audio timestamp"
Assert-Equal $futureWallRoute.Value.cleanup_class "route_owned_cleanup_clear" "future derived wall cleanup converges"
Assert-Equal $futureWallRoute.Value.raw_private_publication_flags $false "future derived wall publishes no private fields"
Assert-Equal ($successHarness.State.AitQueries -join ",") ",?after_ordinal=0,?after_ordinal=1,?after_ordinal=2" "controller reads baseline then each next retained ordinal"

$delayedHarness = New-ControlledRouteHarness -Mode "delayed_start"
$delayedRoute = Invoke-ProductionTransportRoute -RouteAitBaseUrl "http://127.0.0.1:3000" -RouteAiTalkCoreBaseUrl "http://127.0.0.1:8000" -RouteControlledChromeRootPid 1 -RouteObserverWindowMs 1000 -RouteDeadlineMs 3000 -RequestInvoker $delayedHarness.RequestInvoker -ObserverStarter $delayedHarness.ObserverStarter -SleepInvoker $delayedHarness.SleepInvoker -CoreTokenOverride "fixed-test-core-token"
Assert-Equal $delayedRoute.ExitCode 0 "controller waits through bounded empty lifecycle polls"
Assert-Equal $delayedHarness.State.AitReadCount 6 "delayed lifecycle consumes baseline, empty waits, and three transitions"
Assert-Equal $delayedHarness.State.CoreBodies.Count 4 "delayed lifecycle sends one ordered event set"
Assert-Equal $delayedRoute.Value.final_lifecycle_state "released" "delayed lifecycle still reaches released"
Assert-Equal ($delayedHarness.State.AitQueries -join ",") ",?after_ordinal=0,?after_ordinal=0,?after_ordinal=0,?after_ordinal=1,?after_ordinal=2" "empty cursor reads do not advance the retained ordinal"

$restartHarness = New-ControlledRouteHarness -Mode "released_restart_lower_generation"
$restartRoute = Invoke-ProductionTransportRoute -RouteAitBaseUrl "http://127.0.0.1:3000" -RouteAiTalkCoreBaseUrl "http://127.0.0.1:8000" -RouteControlledChromeRootPid 1 -RouteObserverWindowMs 1000 -RouteDeadlineMs 3000 -RequestInvoker $restartHarness.RequestInvoker -ObserverStarter $restartHarness.ObserverStarter -SleepInvoker $restartHarness.SleepInvoker -CoreTokenOverride "fixed-test-core-token"
Assert-Equal $restartRoute.ExitCode 0 "fresh lower-generation lease after release is accepted"
Assert-Equal $restartRoute.Value.lifecycle_ingest_count 3 "reload restart ingests exact lifecycle count"
Assert-Equal $restartRoute.Value.observation_ingest_count 1 "reload restart emits one observation"
Assert-Equal $restartRoute.Value.final_lifecycle_state "released" "reload restart reaches released"
Assert-Equal $restartHarness.State.CoreBodies.Count 4 "reload restart sends three lifecycle events and one observation"
Assert-Equal (@($restartHarness.State.CoreBodies | Select-Object -First 3 | ForEach-Object { $_.payload.speech_session_generation }) -join ",") "1,1,1" "reload restart preserves new lower generation"
Assert-Equal ($restartHarness.State.AitQueries -join ",") ",?after_ordinal=9,?after_ordinal=10,?after_ordinal=11" "reload restart consumes only post-baseline ordinals"

$supersededHarness = New-ControlledRouteHarness -Mode "superseded_generation"
$supersededRoute = Invoke-ProductionTransportRoute -RouteAitBaseUrl "http://127.0.0.1:3000" -RouteAiTalkCoreBaseUrl "http://127.0.0.1:8000" -RouteControlledChromeRootPid 1 -RouteObserverWindowMs 1000 -RouteDeadlineMs 3000 -RequestInvoker $supersededHarness.RequestInvoker -ObserverStarter $supersededHarness.ObserverStarter -SleepInvoker $supersededHarness.SleepInvoker -CoreTokenOverride "fixed-test-core-token"
Assert-Equal $supersededRoute.ExitCode 0 "newer handoff supersedes an unreleased older generation"
Assert-Equal $supersededRoute.Value.lifecycle_ingest_count 5 "superseded sequence ingests every retained lifecycle"
Assert-Equal $supersededRoute.Value.final_lifecycle_state "released" "superseded sequence closes only on current generation release"
Assert-Equal $supersededHarness.State.ObserverStartCount 2 "superseded sequence starts one observer per owned generation window"
Assert-Equal $supersededHarness.State.ObserverProcesses[0].DisposeCount 1 "superseded sequence discards the old generation observer"
Assert-Equal $supersededHarness.State.ObserverProcesses[1].DisposeCount 1 "superseded sequence disposes the final generation observer"
Assert-Equal $supersededRoute.Value.observation_ingest_count 2 "superseded sequence reports both acknowledged observations"
Assert-Equal $supersededHarness.State.CoreBodies.Count 7 "superseded sequence sends five lifecycle events plus two observations"
$supersededLifecycleBodies = @($supersededHarness.State.CoreBodies | Where-Object { $_.event -ceq "swordAgentSystemSpeechLifecycleV0" })
Assert-Equal (@($supersededLifecycleBodies | ForEach-Object { $_.payload.lifecycle_state }) -join ",") "handoff_accepted,cooldown,handoff_accepted,cooldown,released" "superseded sequence preserves exact lifecycle order"
Assert-Equal (@($supersededLifecycleBodies | ForEach-Object { $_.payload.speech_session_generation }) -join ",") "7,7,8,8,8" "superseded sequence preserves generation ownership"
$supersededObservationBodies = @($supersededHarness.State.CoreBodies | Where-Object { $_.event -ceq "audioSelfOutputObservationV0" })
Assert-Equal $supersededObservationBodies.Count 2 "superseded sequence retains one observation per owned generation"
Assert-Equal $supersededObservationBodies[1].payload.speech_session_generation 8 "final observation uses the superseding generation"
Assert-Equal $supersededObservationBodies[1].payload.system_speech_session_id "system-speech-session:sss_cccccccccccccccccccccccccccccccc" "final observation uses the superseding session"
Assert-Equal $supersededObservationBodies[1].payload.playback_event_ref "playback-event:pe_dddddddddddddddddddddddddddddddd" "final observation uses the superseding playback ref"
Assert-Equal ($supersededHarness.State.AitQueries -join ",") ",?after_ordinal=0,?after_ordinal=1,?after_ordinal=2,?after_ordinal=3,?after_ordinal=4" "superseded sequence consumes every retained ordinal once"

$silentSupersededHarness = New-ControlledRouteHarness -Mode "superseded_generation_silent_new"
$silentSupersededRoute = Invoke-ProductionTransportRoute -RouteAitBaseUrl "http://127.0.0.1:3000" -RouteAiTalkCoreBaseUrl "http://127.0.0.1:8000" -RouteControlledChromeRootPid 1 -RouteObserverWindowMs 1000 -RouteDeadlineMs 3000 -RequestInvoker $silentSupersededHarness.RequestInvoker -ObserverStarter $silentSupersededHarness.ObserverStarter -SleepInvoker $silentSupersededHarness.SleepInvoker -CoreTokenOverride "fixed-test-core-token"
Assert-Equal $silentSupersededRoute.Value.blocker_class "observer_result_invalid" "old-generation-only render cannot satisfy the superseding lease"
Assert-Equal $silentSupersededRoute.Value.observation_ingest_count 1 "silent superseding generation preserves only the acknowledged old observation count"
Assert-Equal $silentSupersededRoute.Value.overlap_join_ready_class "not_ready" "silent superseding generation cannot retain old-generation readiness"
Assert-Equal $silentSupersededHarness.State.CoreBodies.Count 4 "silent superseding generation stops after the new handoff without publishing a new observation"
Assert-Equal $silentSupersededHarness.State.ObserverProcesses[0].DisposeCount 1 "silent supersession still discards old positive observer"
Assert-Equal $silentSupersededHarness.State.ObserverProcesses[1].DisposeCount 1 "silent supersession disposes current observer"

$overflowHarness = New-ControlledRouteHarness -Mode "history_overflow"
$overflowRoute = Invoke-ProductionTransportRoute -RouteAitBaseUrl "http://127.0.0.1:3000" -RouteAiTalkCoreBaseUrl "http://127.0.0.1:8000" -RouteControlledChromeRootPid 1 -RouteObserverWindowMs 1000 -RouteDeadlineMs 3000 -RequestInvoker $overflowHarness.RequestInvoker -ObserverStarter $overflowHarness.ObserverStarter -SleepInvoker $overflowHarness.SleepInvoker -CoreTokenOverride "fixed-test-core-token"
Assert-Equal $overflowRoute.Value.blocker_class "lifecycle_transport_incomplete" "seventeenth lifecycle event fails closed"
Assert-Equal $overflowRoute.Value.lifecycle_ingest_count 16 "bounded history acknowledges at most sixteen lifecycle events"
Assert-Equal $overflowRoute.Value.observation_ingest_count 8 "bounded-history overflow reports all eight acknowledged observations"
Assert-Equal $overflowHarness.State.CoreBodies.Count 24 "bounded history sends sixteen lifecycle events and eight owned observations"
Assert-Equal $overflowHarness.State.ObserverStartCount 8 "bounded history starts only the eight acknowledged generation observers"
Assert-Equal @($overflowHarness.State.ObserverProcesses | Where-Object { $_.DisposeCount -ne 1 }).Count 0 "bounded-history overflow disposes every observer"

$ordinalHarness = New-ControlledRouteHarness -Mode "ordinal_gap"
$ordinalRoute = Invoke-ProductionTransportRoute -RouteAitBaseUrl "http://127.0.0.1:3000" -RouteAiTalkCoreBaseUrl "http://127.0.0.1:8000" -RouteControlledChromeRootPid 1 -RouteObserverWindowMs 1000 -RouteDeadlineMs 3000 -RequestInvoker $ordinalHarness.RequestInvoker -ObserverStarter $ordinalHarness.ObserverStarter -SleepInvoker $ordinalHarness.SleepInvoker -CoreTokenOverride "fixed-test-core-token"
Assert-Equal $ordinalRoute.Value.blocker_class "lifecycle_transport_incomplete" "ordinal gap blocks route"
Assert-Equal $ordinalHarness.State.CoreBodies.Count 0 "ordinal gap sends no Core event"
Assert-Equal $ordinalHarness.State.ObserverStartCount 0 "ordinal gap starts no observer"

$leaseHarness = New-ControlledRouteHarness -Mode "lease_mismatch"
$leaseRoute = Invoke-ProductionTransportRoute -RouteAitBaseUrl "http://127.0.0.1:3000" -RouteAiTalkCoreBaseUrl "http://127.0.0.1:8000" -RouteControlledChromeRootPid 1 -RouteObserverWindowMs 1000 -RouteDeadlineMs 3000 -RequestInvoker $leaseHarness.RequestInvoker -ObserverStarter $leaseHarness.ObserverStarter -SleepInvoker $leaseHarness.SleepInvoker -CoreTokenOverride "fixed-test-core-token"
Assert-Equal $leaseRoute.Value.blocker_class "lifecycle_lease_mismatch" "lease mismatch blocks route"
Assert-Equal $leaseHarness.State.CoreBodies.Count 2 "lease mismatch stops after acknowledged handoff and its owned observation"
Assert-Equal $leaseRoute.Value.observation_ingest_count 1 "lease mismatch preserves the acknowledged handoff observation count"
Assert-Equal $leaseHarness.State.ObserverStartCount 1 "lease mismatch starts observer only after handoff"

$staleHarness = New-ControlledRouteHarness -Mode "stale_replay"
$staleRoute = Invoke-ProductionTransportRoute -RouteAitBaseUrl "http://127.0.0.1:3000" -RouteAiTalkCoreBaseUrl "http://127.0.0.1:8000" -RouteControlledChromeRootPid 1 -RouteObserverWindowMs 1000 -RouteDeadlineMs 3000 -RequestInvoker $staleHarness.RequestInvoker -ObserverStarter $staleHarness.ObserverStarter -SleepInvoker $staleHarness.SleepInvoker -CoreTokenOverride "fixed-test-core-token"
Assert-Equal $staleRoute.Value.blocker_class "lifecycle_stale_generation_replay" "stale generation replay blocked"
Assert-Equal $staleHarness.State.CoreBodies.Count 0 "stale generation sends no Core event"

$unknownHarness = New-ControlledRouteHarness -Mode "ack_unknown"
$unknownRoute = Invoke-ProductionTransportRoute -RouteAitBaseUrl "http://127.0.0.1:3000" -RouteAiTalkCoreBaseUrl "http://127.0.0.1:8000" -RouteControlledChromeRootPid 1 -RouteObserverWindowMs 1000 -RouteDeadlineMs 3000 -RequestInvoker $unknownHarness.RequestInvoker -ObserverStarter $unknownHarness.ObserverStarter -SleepInvoker $unknownHarness.SleepInvoker -CoreTokenOverride "fixed-test-core-token"
Assert-Equal $unknownRoute.Value.lifecycle_ingest_count $null "ambiguous Core dispatch does not claim zero lifecycle ingest"
Assert-Equal $unknownRoute.Value.lifecycle_ingest_outcome_class "dispatched_ack_unknown" "ambiguous Core dispatch is explicit"

$timeoutHarness = New-ControlledRouteHarness -Mode "timeout"
$timeoutRoute = Invoke-ProductionTransportRoute -RouteAitBaseUrl "http://127.0.0.1:3000" -RouteAiTalkCoreBaseUrl "http://127.0.0.1:8000" -RouteControlledChromeRootPid 1 -RouteObserverWindowMs 1000 -RouteDeadlineMs 3000 -RequestInvoker $timeoutHarness.RequestInvoker -ObserverStarter $timeoutHarness.ObserverStarter -SleepInvoker $timeoutHarness.SleepInvoker -CoreTokenOverride "fixed-test-core-token"
Assert-Equal $timeoutRoute.Value.blocker_class "whole_route_timeout" "controlled observer timeout blocks route"
Assert-Equal $timeoutHarness.State.ObserverProcess.KillCount 1 "timeout kills owned observer once"
Assert-Equal $timeoutHarness.State.ObserverProcess.DisposeCount 1 "timeout disposes owned observer once"
Assert-Equal $timeoutRoute.Value.cleanup_class "route_owned_cleanup_clear" "timeout cleanup converges"

$privateMarker = "private-controller-url-marker"
$runOutput = @(
  & $pwsh.Source -NoProfile -File $ControllerPath `
    -AitBaseUrl "https://$privateMarker.invalid/path" `
    -AiTalkCoreBaseUrl "http://127.0.0.1:8000" `
    -ControlledChromeRootPid 1 `
    -Json 2>&1
) -join "`n"
Assert-Equal $LASTEXITCODE 1 "invalid configuration exits blocked"
$runResult = $runOutput | ConvertFrom-Json
Assert-Equal $runResult.blocker_class "transport_configuration_invalid" "invalid configuration fixed class"
Assert-Equal $runResult.lifecycle_ingest_count 0 "invalid route ingests no lifecycle"
Assert-Equal $runResult.observation_ingest_count 0 "invalid route ingests no observation"
Assert-Equal $runResult.route_owned_process_residue_count 0 "invalid route leaves no process"
Assert-Equal $runResult.route_owned_temp_residue_count 0 "invalid route leaves no temp"
Assert-Equal $runResult.raw_private_publication_flags $false "raw publication flag false"
Assert-True (-not $runOutput.Contains($privateMarker)) "private URL marker not echoed"

[ordered]@{
  status = "ok"
  assertions = $script:AssertionCount
  parser_errors = 0
  live_audio_invocation_count = 0
  dependency_install_count = 0
  proof_ceiling = "source_static_self_output_production_transport"
  raw_private_publication_flags = $false
} | ConvertTo-Json -Compress
