$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$RepoRoot = Split-Path -Parent $PSScriptRoot
$RunPath = Join-Path $RepoRoot "scripts\run-primary-system-cell-speech-test.ps1"
$assertions = 0
$outerRunId = [guid]::NewGuid().ToString("N")
$tempBase = [IO.Path]::GetTempPath()
$tempRoot = Join-Path $tempBase ("primary-system-cell-speech-test-" + $outerRunId)

function Assert-True {
  param([bool]$Condition, [string]$Message)
  $script:assertions += 1
  if (-not $Condition) { throw $Message }
}

function Assert-Equal {
  param($Actual, $Expected, [string]$Message)
  Assert-True ($Actual -ceq $Expected) "$Message; actual=$Actual expected=$Expected"
}

function Assert-FixedFailure {
  param(
    [Parameter(Mandatory = $true)][scriptblock]$Action,
    [Parameter(Mandatory = $true)][string]$Expected,
    [Parameter(Mandatory = $true)][string]$Message
  )
  $actual = "no_failure"
  try { & $Action } catch { $actual = [string]$_.Exception.Message }
  Assert-Equal $actual $Expected $Message
}

function Assert-ParserClear {
  param([Parameter(Mandatory = $true)][string]$Path)
  $tokens = $null
  $errors = $null
  [void][Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
  Assert-Equal @($errors).Count 0 "PowerShell parser must remain clear"
}

Assert-ParserClear -Path $RunPath
. $RunPath -UserStartEventName "test-dot-source-event"
$source = Get-Content -Raw -LiteralPath $RunPath

$requiredOrder = @(
  "system_output_listener_ready",
  "session_ready_published",
  "user_start_received",
  "system_output_dispatched_once",
  "user_speech_ready",
  "user_cue_published"
)
$threeRunStopwatch = [Diagnostics.Stopwatch]::StartNew()
foreach ($simulationIndex in 1..3) {
  $order = [Collections.Generic.List[string]]::new()
  Invoke-UserSessionSequence `
    -PublishSessionReady { $order.Add("session_ready_published") } `
    -WaitForUserStart {
      $order.Add("user_start_received")
      return "user_start_received"
    } `
    -StartControllerAndWaitForSystemOutputTriggerReady { $order.Add("system_output_listener_ready") } `
    -TriggerSystemOutput {
      $order.Add("system_output_dispatched_once")
      return "system_output_dispatched_once"
    } `
    -WaitForUserSpeechReady { $order.Add("user_speech_ready") } `
    -PublishUserCue { $order.Add("user_cue_published") }
  Assert-Equal ($order -join ",") ($requiredOrder -join ",") "simulation $simulationIndex must preserve exact preparation order"
}
$threeRunStopwatch.Stop()
Assert-True ($threeRunStopwatch.ElapsedMilliseconds -lt 1000) "three machine-only sequencing simulations must finish immediately"

$negativeOrder = [Collections.Generic.List[string]]::new()
Invoke-UnattendedSelfOutputSequence `
  -StartControllerAndWaitForSystemOutputTriggerReady { $negativeOrder.Add("listener") } `
  -TriggerSystemOutput {
    $negativeOrder.Add("system_output_dispatched_once")
    return "system_output_dispatched_once"
  } `
  -WaitForSuppressionWindowReady { $negativeOrder.Add("suppression_window_ready") }
Assert-Equal ($negativeOrder -join ",") `
  "listener,system_output_dispatched_once,suppression_window_ready" `
  "unattended negative sequence must start without user wait or cue"

$earlyTriggerOrder = [Collections.Generic.List[string]]::new()
Assert-FixedFailure {
  Invoke-UserSessionSequence `
    -PublishSessionReady { $earlyTriggerOrder.Add("ready") } `
    -WaitForUserStart {
      $earlyTriggerOrder.Add("invalid_start")
      return "not_ready"
    } `
    -StartControllerAndWaitForSystemOutputTriggerReady { $earlyTriggerOrder.Add("listener") } `
    -TriggerSystemOutput {
      $earlyTriggerOrder.Add("trigger")
      return "system_output_dispatched_once"
    } `
    -WaitForUserSpeechReady { $earlyTriggerOrder.Add("speech_ready") } `
    -PublishUserCue { $earlyTriggerOrder.Add("cue") }
} "user_start_not_received" "invalid user start must fail before system output"
Assert-Equal ($earlyTriggerOrder -join ",") "listener,ready,invalid_start" "invalid user start must preserve the prearmed listener but produce no trigger or cue"

$dispatchFailureOrder = [Collections.Generic.List[string]]::new()
Assert-FixedFailure {
  Invoke-UserSessionSequence `
    -PublishSessionReady { $dispatchFailureOrder.Add("ready") } `
    -WaitForUserStart {
      $dispatchFailureOrder.Add("start")
      return "user_start_received"
    } `
    -StartControllerAndWaitForSystemOutputTriggerReady { $dispatchFailureOrder.Add("listener") } `
    -TriggerSystemOutput {
      $dispatchFailureOrder.Add("invalid_dispatch")
      return "not_dispatched"
    } `
    -WaitForUserSpeechReady { $dispatchFailureOrder.Add("speech_ready") } `
    -PublishUserCue { $dispatchFailureOrder.Add("cue") }
} "test_ui_dispatch_not_ready" "invalid dispatch must fail before user-ready"
Assert-Equal ($dispatchFailureOrder -join ",") "listener,ready,start,invalid_dispatch" "invalid dispatch must produce no user-ready or cue"

$fakeClock = [pscustomobject]@{ ElapsedMilliseconds = 0L }
$fakeClockConditionCount = 0
Assert-FixedFailure {
  Wait-Until -RouteStopwatch $fakeClock -RouteDeadlineMs 100 `
    -FailureClass "preparation_deadline_exceeded" -SleepInvoker { param([int]$Milliseconds) } -Condition {
      $script:fakeClockConditionCount += 1
      $fakeClock.ElapsedMilliseconds += 60
      return $null
    }
} "preparation_deadline_exceeded" "cumulative preparation deadline must not renew between polls"
Assert-Equal $fakeClockConditionCount 2 "fake clock must exhaust one shared deadline after two cumulative steps"

$mainStatements = @(
  '$userStartEvent = New-ExclusiveUserStartEvent',
  'Invoke-UserSessionSequence `',
  'result_class = "ready_for_user_session_start"',
  '-ExpectedSchema "self_output_awareness.user_start_received.v0"',
  '$script:controllerProcess = Start-OwnedProcessSuspended',
  '-ExpectedClass "ready_for_system_output_trigger"',
  '--cdp-endpoint http://127.0.0.1:9222 --timeout-ms $dispatchTimeoutMs',
  '-ExpectedClass "ready_for_user_speech"',
  'result_class = "issue_user_cue_now"'
)
foreach ($statement in $mainStatements) {
  Assert-Equal ($source.Split($statement).Count - 1) 1 "main preparation statement must occur exactly once"
}
$statementIndexes = @($mainStatements | ForEach-Object { $source.IndexOf($_) })
Assert-True ($source -match 'Invoke-UserSessionSequence[\s\S]+StartControllerAndWaitForSystemOutputTriggerReady[\s\S]+PublishSessionReady[\s\S]+WaitForUserStart') "execution helper must prearm controller before publishing readiness and waiting for user start"

Assert-True ($source -match 'selection_class\s+-cne\s+"selected_available"[\s\S]+selected_match[\s\S]+device_start_count[\s\S]+capture_count') "saved camera selection must fail closed without substitution or capture"
Assert-True ($source -match 'Get-RequiredLauncherServices[\s\S]+launcher_service_count\s*=\s*9') "Launcher boundary must remain exactly nine services"
Assert-True ($source -match 'input_availability_class\s+-ceq\s+"enabled"') "canonical body-state readiness field must remain exact"
Assert-True ($source -match '/health"[\s\S]{0,180}-Headers\s+@\{\s*"X-AI-Core-Token"\s*=\s*\$env:AI_TALK_CORE_WEB_TOKEN') "token-protected health must use the canonical per-run token"
Assert-True ($source -match '/api/self-output-awareness-transport/"[\s\S]{0,300}Test-AitLifecyclePreflightResponse') "exact AIT lifecycle endpoint must be warm and validated before controller start"
Assert-True ($source.IndexOf('/api/self-output-awareness-transport/') -lt $source.IndexOf('$script:controllerProcess = Start-OwnedProcessSuspended')) "AIT lifecycle preflight must precede controller process start"
Assert-True ($source -match 'api/stop[\s\S]+api/shutdown[\s\S]+TerminateAndWait') "standard stop must precede Job-owned process cleanup"
Assert-True ($source -match 'CleanupStopTimeoutSeconds\s*=\s*70[\s\S]+api/stop[\s\S]{0,240}-TimeoutMs\s+\(\$CleanupStopTimeoutSeconds\s*\*\s*1000\)') "standard stop must receive the bounded launcher-compatible timeout"
Assert-True ($source -match '\$stopResult\.ok\s+-isnot\s+\[bool\][\s\S]{0,120}cleanup_incomplete') "non-successful standard stop response must fail cleanup closed"
Assert-True ($source -match 'cleanup_failure_class\s*=\s*\$cleanupFailureClass') "cleanup output must publish only the fixed failure class"
foreach ($cleanupFailure in @(
    "launcher_standard_stop_failed", "launcher_shutdown_failed",
    "owned_job_cleanup_failed", "route_port_cleanup_failed",
    "run_root_cleanup_failed", "cleanup_unclassified")) {
  Assert-True ($source.Contains('"' + $cleanupFailure + '"')) "cleanup failure class must remain fixed: $cleanupFailure"
}
Assert-True ($source -match 'route_owned_processes_and_temp_cleared') "successful cleanup class must remain fixed"
Assert-True ($source -match 'controllerProcess\.ExitCode\s+-ne\s+0[\s\S]+live_controller_failed') "nonzero controller completion must fail the runner"
Assert-True ($source -match 'Get-RemainingBudgetMs[\s\S]+preparationStopwatch[\s\S]+postStartStopwatch') "preparation and post-start must use separate non-renewing clocks"
Assert-True ($source -match 'Get-ListeningOwnerPids[\s\S]+Assert-PortsClear[\s\S]+Assert-PortOwnedByRoot') "fixed ports must fail closed and match launched lineage"
Assert-True ($source -match 'SetEnvironmentVariable\("AI_TALK_CORE_WEB_TOKEN", \$previousCoreToken, "Process"\)') "process token must be restored on cleanup"
Assert-True (-not $source.Contains("PRIVATE_")) "tracked runner must not contain a private marker"

$emptyLifecyclePreflight = [pscustomobject]@{
  ok = $true
  result_class = "lifecycle_transport_empty"
  transport = $null
  raw_private_publication_flags = $false
}
Assert-True (Test-AitLifecyclePreflightResponse -Value $emptyLifecyclePreflight) "empty lifecycle response must be a valid warm preflight"
$currentLifecyclePreflight = $emptyLifecyclePreflight.PSObject.Copy()
$currentLifecyclePreflight.transport = [pscustomobject]@{
  transition_ordinal = 1
  private_payload = "must-not-pass"
}
$currentLifecyclePreflight.result_class = "lifecycle_transport_current"
Assert-True (-not (Test-AitLifecyclePreflightResponse -Value $currentLifecyclePreflight)) "non-empty or private-bearing lifecycle must fail the clean-start preflight"
$mismatchedLifecyclePreflight = $emptyLifecyclePreflight.PSObject.Copy()
$mismatchedLifecyclePreflight.result_class = "lifecycle_transport_current"
Assert-True (-not (Test-AitLifecyclePreflightResponse -Value $mismatchedLifecyclePreflight)) "transport/class mismatch must fail preflight"
$privateLifecyclePreflight = $emptyLifecyclePreflight.PSObject.Copy()
$privateLifecyclePreflight.raw_private_publication_flags = $true
Assert-True (-not (Test-AitLifecyclePreflightResponse -Value $privateLifecyclePreflight)) "private-bearing lifecycle response must fail preflight"
$extraLifecyclePreflight = $emptyLifecyclePreflight.PSObject.Copy()
$extraLifecyclePreflight | Add-Member -NotePropertyName extra -NotePropertyValue $true
Assert-True (-not (Test-AitLifecyclePreflightResponse -Value $extraLifecyclePreflight)) "extra lifecycle envelope field must fail preflight"

$rootIdentity = [pscustomobject]@{ ProcessId = 100; CreationIdentity = "1000" }
$processRows = @(
  [pscustomobject]@{ ProcessId = 100; ParentProcessId = 1; CreationDate = "1000" },
  [pscustomobject]@{ ProcessId = 101; ParentProcessId = 100; CreationDate = "1100" },
  [pscustomobject]@{ ProcessId = 102; ParentProcessId = 101; CreationDate = "1200" },
  [pscustomobject]@{ ProcessId = 103; ParentProcessId = 100; CreationDate = "900" },
  [pscustomobject]@{ ProcessId = 200; ParentProcessId = 1; CreationDate = "1000" }
)
$ownedRows = @(Resolve-OwnedProcessRows -RootIdentities @($rootIdentity) -ProcessRows $processRows)
Assert-Equal (($ownedRows.ProcessId | Sort-Object) -join ",") "100,101,102" "only current root identity and newer descendants may be owned"
Assert-Equal @($ownedRows | Where-Object { $_.ProcessId -eq 103 }).Count 0 "older PID-parent artifact must not become owned"
Assert-Equal @($ownedRows | Where-Object { $_.ProcessId -eq 200 }).Count 0 "unrelated process must not become owned"
$orphanRows = @(
  [pscustomobject]@{ ProcessId = 101; ParentProcessId = 100; CreationDate = "1100" },
  [pscustomobject]@{ ProcessId = 102; ParentProcessId = 101; CreationDate = "1200" }
)
Assert-Equal @(Resolve-OwnedProcessRows -RootIdentities @($rootIdentity) -ProcessRows $orphanRows).Count 0 "missing-root descendants must not be inferred from PID alone"
Assert-True (Test-RootIdentityAmbiguity -RootIdentities @($rootIdentity) -ProcessRows $orphanRows) "missing root with surviving descendants must fail cleanup as ambiguous"

$reusedRootRows = @([pscustomobject]@{ ProcessId = 100; ParentProcessId = 1; CreationDate = "2000" })
Assert-True (Test-RootIdentityConflict -RootIdentities @($rootIdentity) -ProcessRows $reusedRootRows) "reused root PID must be classified as an identity conflict"
Assert-Equal @(Resolve-OwnedProcessRows -RootIdentities @($rootIdentity) -ProcessRows $reusedRootRows).Count 0 "reused root PID must not be owned"
$reusedThenExitedRows = @(
  [pscustomobject]@{ ProcessId = 201; ParentProcessId = 100; CreationDate = "3000" }
)
Assert-Equal @(Resolve-OwnedProcessRows -RootIdentities @($rootIdentity) -ProcessRows $reusedThenExitedRows).Count 0 "child of a reused-then-exited parent PID must not be owned"
Assert-True (Test-RootIdentityAmbiguity -RootIdentities @($rootIdentity) -ProcessRows $reusedThenExitedRows) "reused-then-exited parent PID must fail cleanup as ambiguous"
Assert-True (-not $source.Contains("Stop-Process")) "cleanup must not terminate by a reusable bare PID"
Assert-True ($source -match 'AssignProcessToJobObject[\s\S]+TerminateJobObject[\s\S]+ActiveProcessCount') "Windows Job membership must own termination and residue proof"
Assert-Equal ($source.Split('Start-OwnedProcessSuspended -Job $ownedJob').Count - 1) 4 "all four route roots must use atomic suspended Job launch"
Assert-Equal ($source.Split('Start-Process -FilePath').Count - 1) 0 "route runner must not launch an unassigned process before Job membership"
Assert-True ($source -match 'CreateProcess[\s\S]+AssignProcessToJobObject[\s\S]+ResumeThread') "native route launch must assign the suspended root before resuming application code"
Assert-True ($source -match 'TerminateCreatedProcess[\s\S]+WaitForSingleObject[\s\S]+cleanup_incomplete') "pre-Job failure cleanup must require exact-handle termination completion"
Assert-Equal (Resolve-OwnedProcessStartFailureClass -FailureClass "cleanup_incomplete") `
  "cleanup_incomplete" "native cleanup failure must remain exact through the production PowerShell boundary"
Assert-Equal (Resolve-OwnedProcessStartFailureClass -FailureClass "unexpected_private_failure") `
  "owned_process_start_failed" "unknown native failure must remain fixed and nonpublishing"

function New-AssignmentFailureMutationType {
  param(
    [Parameter(Mandatory = $true)][string]$Namespace,
    [switch]$ForceCleanupProofFailure
  )
  $typeMatch = [regex]::Match(
    $source, "(?s)Add-Type -TypeDefinition @'\r?\n(?<body>.*?)\r?\n'@")
  Assert-True $typeMatch.Success "embedded Job type source must remain extractable for mutation coverage"
  $typeSource = $typeMatch.Groups["body"].Value
  $typeSource = $typeSource.Replace(
    "namespace SwordAgentOS.Runtime {", "namespace $Namespace {")
  $typeSource = $typeSource.Replace(
    "if (!AssignProcessToJobObject(handle, created.Process)) {", "if (arguments != null) {")
  if ($ForceCleanupProofFailure) {
    $typeSource = $typeSource.Replace(
      "return waitResult == 0;", "return false;")
  }
  $types = @(Add-Type -TypeDefinition $typeSource -PassThru)
  return @($types | Where-Object { $_.FullName -ceq "$Namespace.OwnedProcessJob" })[0]
}

function Assert-NoMutationProcess {
  param([Parameter(Mandatory = $true)][string]$Marker)
  $matches = @(
    Get-CimInstance Win32_Process -ErrorAction Stop |
      Where-Object { [string]$_.CommandLine -clike "*$Marker*" }
  )
  Assert-Equal $matches.Count 0 "exact suspended mutation process must not remain"
}

$cleanupSuccessType = New-AssignmentFailureMutationType `
  -Namespace "SwordAgentOS.RuntimeAssignmentCleanupSuccess"
$cleanupSuccessJob = [Activator]::CreateInstance($cleanupSuccessType)
$cleanupSuccessMarker = [guid]::NewGuid().ToString("N")
try {
  [string]$cleanupSuccessClass = $null
  $cleanupSuccessProcess = $cleanupSuccessJob.StartSuspended(
    "C:\Program Files\PowerShell\7\pwsh.exe",
    [string[]]@("-NoProfile", "-Command", "Start-Sleep -Seconds 30 # $cleanupSuccessMarker"),
    [ref]$cleanupSuccessClass)
  Assert-True ($null -eq $cleanupSuccessProcess) "forced assignment failure must not return a process"
  Assert-Equal $cleanupSuccessClass "owned_job_assignment_failed" "proved exact suspended cleanup may retain the fixed assignment blocker"
  Assert-Equal $cleanupSuccessJob.ActiveProcessCount 0 "pre-assignment cleanup must not create Job membership"
  Assert-NoMutationProcess -Marker $cleanupSuccessMarker
} finally {
  $cleanupSuccessJob.Dispose()
}

$cleanupFailureType = New-AssignmentFailureMutationType `
  -Namespace "SwordAgentOS.RuntimeAssignmentCleanupFailure" -ForceCleanupProofFailure
$cleanupFailureJob = [Activator]::CreateInstance($cleanupFailureType)
$cleanupFailureMarker = [guid]::NewGuid().ToString("N")
try {
  [string]$cleanupFailureClass = $null
  $cleanupFailureProcess = $cleanupFailureJob.StartSuspended(
    "C:\Program Files\PowerShell\7\pwsh.exe",
    [string[]]@("-NoProfile", "-Command", "Start-Sleep -Seconds 30 # $cleanupFailureMarker"),
    [ref]$cleanupFailureClass)
  Assert-True ($null -eq $cleanupFailureProcess) "cleanup-proof failure must not return a process"
  Assert-Equal $cleanupFailureClass "cleanup_incomplete" "unproved pre-assignment cleanup must fail closed"
  Assert-Equal $cleanupFailureJob.ActiveProcessCount 0 "failed cleanup proof must not be misreported through Job membership"
  Assert-NoMutationProcess -Marker $cleanupFailureMarker
} finally {
  $cleanupFailureJob.Dispose()
}

$eventName = "primary-system-cell-speech-test-" + [guid]::NewGuid().ToString("N")
$startEvent = New-ExclusiveUserStartEvent -Name $eventName
try {
  Assert-True (-not $startEvent.WaitOne(0)) "new user-start event must begin unsignaled"
  Assert-FixedFailure {
    [void](New-ExclusiveUserStartEvent -Name $eventName)
  } "user_start_event_collision" "second owner of the same user-start event must fail closed"
  Assert-True $startEvent.Set() "user-start event must accept the signal"
  Assert-True $startEvent.WaitOne(0) "controller must observe the user-start signal"
  Assert-True $startEvent.WaitOne(0) "transport child must observe the same manual-reset signal"
  [void]$startEvent.Reset()
  Assert-True (-not $startEvent.WaitOne(0)) "manual reset must return the event to an unsignaled state"
} finally {
  $startEvent.Dispose()
}

$validControllerResult = [ordered]@{}
foreach ($key in Get-ExpectedControllerResultKeys) { $validControllerResult[$key] = $null }
$validControllerResult.schema_version = "self_output_awareness.live_controller.v0"
$validControllerResult.controller_status = "completed"
$validControllerResult.scenario = "independent_current_session_user_speech"
$validControllerResult.result_class = "independent_user_speech_turninput_accepted"
$validControllerResult.transcription_count = 1
$validControllerResult.submission_count = 1
$validControllerResult.thought_core_turninput_count = 1
$validControllerResult.route_owned_process_residue_count = 0
$validControllerResult.route_owned_temp_residue_count = 0
$validControllerResult.route_owned_request_residue_count = 0
$validControllerResult.cleanup_class = "controller_http_resources_disposed_endpoint_pcm_and_authority_clear"
$validControllerResult.blocker_class = $null
$validControllerResult.raw_audio_shared = $false
$validControllerResult.raw_text_shared = $false
$validControllerResult.private_identifier_shared = $false
$validControllerResult.private_environment_shared = $false
$validControllerResult.raw_private_publication_flags = $false
$validatedControllerResult = Assert-ControllerSuccessResult `
  -Value ([pscustomobject]$validControllerResult) -ExpectedMode "genuine_user_speech"
Assert-Equal $validatedControllerResult.result_class "independent_user_speech_turninput_accepted" "canonical child result must validate"

$negativeControllerResult = ([pscustomobject]$validControllerResult | ConvertTo-Json -Depth 8) | ConvertFrom-Json
$negativeControllerResult.scenario = "self_output_or_ambiguous"
$negativeControllerResult.result_class = "self_output_or_ambiguous_confirmed"
$negativeControllerResult.accepted_join_class = "not_accepted"
$negativeControllerResult.transcription_count = 0
$negativeControllerResult.submission_count = 0
$negativeControllerResult.thought_core_turninput_count = 0
$negativeControllerResult.first_non_silent_audio_observation_class = "process_tree_render_observed"
$negativeControllerResult.utterance_end_to_first_visible_ms = $null
$negativeControllerResult.utterance_end_to_first_audio_ms = $null
$validatedNegativeResult = Assert-ControllerSuccessResult `
  -Value $negativeControllerResult -ExpectedMode "unattended_self_output_suppression"
Assert-Equal $validatedNegativeResult.result_class "self_output_or_ambiguous_confirmed" `
  "unattended negative child result must validate"
$negativeControllerResult.thought_core_turninput_count = 1
Assert-FixedFailure {
  [void](Assert-ControllerSuccessResult -Value $negativeControllerResult `
      -ExpectedMode "unattended_self_output_suppression")
} "live_controller_result_invalid" "negative mode must reject any TurnInput"
$negativeControllerResult.thought_core_turninput_count = 0
$negativeControllerResult.utterance_end_to_first_audio_ms = 1
Assert-FixedFailure {
  [void](Assert-ControllerSuccessResult -Value $negativeControllerResult `
      -ExpectedMode "unattended_self_output_suppression")
} "live_controller_result_invalid" "negative mode must reject fabricated utterance latency"

$extraFieldResult = ([pscustomobject]$validControllerResult | ConvertTo-Json -Depth 8) | ConvertFrom-Json
$extraFieldResult | Add-Member -NotePropertyName raw_transcript -NotePropertyValue "must-not-pass"
Assert-FixedFailure {
  [void](Assert-ControllerSuccessResult -Value $extraFieldResult `
      -ExpectedMode "genuine_user_speech")
} "live_controller_result_invalid" "extra raw child field must fail closed"
$privateFlagResult = ([pscustomobject]$validControllerResult | ConvertTo-Json -Depth 8) | ConvertFrom-Json
$privateFlagResult.private_identifier_shared = $true
Assert-FixedFailure {
  [void](Assert-ControllerSuccessResult -Value $privateFlagResult `
      -ExpectedMode "genuine_user_speech")
} "live_controller_result_invalid" "private child publication flag must fail closed"

$launcherMutationCount = 0
Assert-FixedFailure {
  [void](Invoke-OwnedLauncherMutation -RootIdentity $rootIdentity `
    -OwnershipVerifier { param($Identity) Throw-Fixed -Class "route_port_owner_mismatch" } `
    -MutationInvoker { $script:launcherMutationCount += 1 })
} "route_port_owner_mismatch" "launcher port takeover must fail before a mutating request"
Assert-Equal $launcherMutationCount 0 "launcher mutation must be suppressed on owner mismatch"
[void](Invoke-OwnedLauncherMutation -RootIdentity $rootIdentity `
  -OwnershipVerifier { param($Identity) } `
  -MutationInvoker { $script:launcherMutationCount += 1; return "sent" })
Assert-Equal $launcherMutationCount 1 "matching launcher ownership permits exactly one mutation"
Assert-True ($source -match 'Invoke-OwnedLauncherMutation[\s\S]+api/start') "Launcher start must use fresh owner verification"
Assert-True ($source -match 'api/stop[\s\S]+Invoke-OwnedLauncherMutation[\s\S]+api/shutdown') "Launcher stop and shutdown must each use fresh owner verification"

$job = $null
$jobParent = $null
$outsideProcess = $null
[void][IO.Directory]::CreateDirectory($tempRoot)
[IO.File]::WriteAllText((Join-Path $tempRoot ".owned-run"), $outerRunId, [Text.Encoding]::ASCII)
$earlyControllerPath = Join-Path $tempRoot "early-controller.json"
$earlyControllerResult = ([pscustomobject]$validControllerResult | ConvertTo-Json -Depth 8) | ConvertFrom-Json
$earlyControllerResult.controller_status = "error"
$earlyControllerResult.result_class = "not_completed"
$earlyControllerResult.blocker_class = "production_transport_unavailable"
$earlyControllerResult.cleanup_class = "controller_http_resources_disposed_no_request_started"
[IO.File]::WriteAllText(
  $earlyControllerPath,
  ($earlyControllerResult | ConvertTo-Json -Depth 8 -Compress),
  [Text.Encoding]::UTF8)
Assert-Equal (Get-EarlyControllerBlockerClass -OutputPath $earlyControllerPath) `
  "production_transport_unavailable" "safe early controller result must retain its fixed blocker"
$earlyControllerResult.scenario = "invalid"
[IO.File]::WriteAllText(
  $earlyControllerPath,
  ($earlyControllerResult | ConvertTo-Json -Depth 8 -Compress),
  [Text.Encoding]::UTF8)
Assert-True ($null -eq (Get-EarlyControllerBlockerClass -OutputPath $earlyControllerPath)) `
  "invalid scenario must not pair with a production transport blocker"
$earlyControllerResult.blocker_class = "live_controller_configuration_invalid"
[IO.File]::WriteAllText(
  $earlyControllerPath,
  ($earlyControllerResult | ConvertTo-Json -Depth 8 -Compress),
  [Text.Encoding]::UTF8)
Assert-Equal (Get-EarlyControllerBlockerClass -OutputPath $earlyControllerPath) `
  "live_controller_configuration_invalid" "configuration failure may retain the controller's safe invalid scenario"
$earlyControllerResult.scenario = "independent_current_session_user_speech"
$earlyControllerResult.blocker_class = "unbounded_private_failure"
[IO.File]::WriteAllText(
  $earlyControllerPath,
  ($earlyControllerResult | ConvertTo-Json -Depth 8 -Compress),
  [Text.Encoding]::UTF8)
Assert-True ($null -eq (Get-EarlyControllerBlockerClass -OutputPath $earlyControllerPath)) `
  "unknown early controller blocker must fail closed to the generic parent class"
$oversizeControllerPath = Join-Path $tempRoot "oversize-controller.json"
[IO.File]::WriteAllText($oversizeControllerPath, ("x" * 16385), [Text.Encoding]::ASCII)
Assert-True ($null -eq (Get-EarlyControllerBlockerClass -OutputPath $oversizeControllerPath)) `
  "oversize early controller output must be rejected before JSON materialization"
Assert-True ($source -match 'Process\.HasExited[\s\S]{0,220}Get-EarlyControllerBlockerClass') `
  "controller exit must consume the safe child-result contract before generic classification"
try {
  $job = [SwordAgentOS.Runtime.OwnedProcessJob]::new()
  $outsideProcess = Start-Process -FilePath "C:\Program Files\PowerShell\7\pwsh.exe" `
    -ArgumentList @("-NoProfile", "-Command", "Start-Sleep -Seconds 30") `
    -PassThru -WindowStyle Hidden
  $nestedCommand = @'
Write-Output "job-parent-output"
[Console]::Error.WriteLine("job-parent-error")
[Console]::Out.Flush()
[Console]::Error.Flush()
Start-Sleep -Milliseconds 2000
[void](Start-Process -FilePath "C:\Program Files\PowerShell\7\pwsh.exe" -ArgumentList @("-NoProfile", "-Command", "Start-Sleep -Seconds 30"))
'@
  $encodedNestedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($nestedCommand))
  $jobOutputPath = Join-Path $tempRoot "job-parent.out.log"
  $jobErrorPath = Join-Path $tempRoot "job-parent.err.log"
  $jobParent = Start-OwnedProcessSuspended -Job $job `
    -FilePath "C:\Program Files\PowerShell\7\pwsh.exe" `
    -ArgumentList @("-NoProfile", "-EncodedCommand", $encodedNestedCommand) `
    -StandardOutputPath $jobOutputPath -StandardErrorPath $jobErrorPath
  $streamingStopwatch = [Diagnostics.Stopwatch]::StartNew()
  $streamingVisible = $false
  while ($streamingStopwatch.ElapsedMilliseconds -lt 1500 -and -not $jobParent.HasExited) {
    $outputText = $(if (Test-Path -LiteralPath $jobOutputPath) {
        Get-Content -Raw -LiteralPath $jobOutputPath -ErrorAction SilentlyContinue
      } else { "" })
    $errorText = $(if (Test-Path -LiteralPath $jobErrorPath) {
        Get-Content -Raw -LiteralPath $jobErrorPath -ErrorAction SilentlyContinue
      } else { "" })
    if (
      -not [string]::IsNullOrWhiteSpace($outputText) -and
      -not [string]::IsNullOrWhiteSpace($errorText) -and
      $outputText.Trim() -ceq "job-parent-output" -and
      $errorText.Trim() -ceq "job-parent-error"
    ) {
      $streamingVisible = $true
      break
    }
    Start-Sleep -Milliseconds 20
  }
  Assert-True $streamingVisible "atomic wrapper output must be readable while the owned child is still alive"
  Assert-True (-not $jobParent.HasExited) "streaming visibility must precede child exit"
  Assert-True $jobParent.WaitForExit(5000) "Job parent must exit after creating its child"
  Assert-Equal (Get-Content -Raw -LiteralPath $jobOutputPath).Trim() "job-parent-output" "atomic wrapper must preserve standard output redirection"
  Assert-Equal (Get-Content -Raw -LiteralPath $jobErrorPath).Trim() "job-parent-error" "atomic wrapper must preserve standard error redirection"
  Assert-True ($job.ActiveProcessCount -ge 1) "Job must retain descendants after the launched root exits"
  Assert-True $job.TerminateAndWait(3000) "Job termination must converge without PID enumeration"
  Assert-Equal $job.ActiveProcessCount 0 "Job-owned process residue must be zero"
  Assert-True (-not $outsideProcess.HasExited) "Job termination must preserve a same-kind process outside the Job"
} finally {
  if ($null -ne $job) {
    try { [void]$job.TerminateAndWait(1000) } catch {}
    $job.Dispose()
  }
  if ($null -ne $outsideProcess -and -not $outsideProcess.HasExited) {
    $outsideProcess.Kill($true)
    [void]$outsideProcess.WaitForExit(2000)
  }
  if ($null -ne $jobParent) { $jobParent.Dispose() }
  if ($null -ne $outsideProcess) { $outsideProcess.Dispose() }
}

try {
  $ownedBase = Join-Path $tempRoot "owned"
  [void][IO.Directory]::CreateDirectory($ownedBase)
  $runId = [guid]::NewGuid().ToString("N")
  $ownedPath = Join-Path $ownedBase "primary-system-cell-speech-test-$runId"
  [void][IO.Directory]::CreateDirectory($ownedPath)
  [IO.File]::WriteAllText((Join-Path $ownedPath ".owned-run"), $runId, [Text.Encoding]::ASCII)
  [IO.File]::WriteAllText((Join-Path $ownedPath "fixture.txt"), "same-run", [Text.Encoding]::ASCII)
  Remove-OwnedRunRoot -Path $ownedPath -OwnedBase $ownedBase -RunId $runId
  Assert-True (-not (Test-Path -LiteralPath $ownedPath)) "same-run owned root must be removed exactly"

  $wrongRunId = [guid]::NewGuid().ToString("N")
  $wrongPath = Join-Path $ownedBase "primary-system-cell-speech-test-$wrongRunId"
  [void][IO.Directory]::CreateDirectory($wrongPath)
  [IO.File]::WriteAllText((Join-Path $wrongPath ".owned-run"), "different-owner", [Text.Encoding]::ASCII)
  Assert-FixedFailure {
    Remove-OwnedRunRoot -Path $wrongPath -OwnedBase $ownedBase -RunId $wrongRunId
  } "cleanup_incomplete" "mismatched ownership marker must stop exact cleanup"
  Assert-True (Test-Path -LiteralPath $wrongPath) "mismatched ownership marker must preserve the target"
} finally {
  if (Test-Path -LiteralPath $tempRoot) {
    Remove-OwnedRunRoot -Path $tempRoot -OwnedBase $tempBase -RunId $outerRunId
  }
}

Write-Output "status=ok"
Write-Output ("assertions={0}" -f $assertions)
Write-Output "live_runtime_invocation_count=0"
Write-Output "owned_job_helper_process_count=3"
Write-Output "raw_private_publication_flags=false"
