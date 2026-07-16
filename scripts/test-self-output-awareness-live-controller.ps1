$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$RepoRoot = Split-Path -Parent $PSScriptRoot
$ControllerPath = Join-Path $RepoRoot "scripts\run-self-output-awareness-live-controller.ps1"
$pwsh = Get-Command pwsh -ErrorAction Stop
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("self-output-live-controller-test-" + [guid]::NewGuid().ToString("N"))
$fakeObserverModulePath = Join-Path $tempRoot "observer-process-fake.mjs"
$fakeProductionTransportPath = Join-Path $tempRoot "production-transport-process-fake.ps1"
$privateToken = "PRIVATE_LIVE_CONTROLLER_TOKEN_SENTINEL"
$privateResponseMarker = "PRIVATE_TRANSCRIPT_SENTINEL"
$assertions = 0
$jobs = [System.Collections.Generic.List[object]]::new()
$productionProcess = $null
$delayedListenerProcess = $null
$caseProcess = $null

function Assert-True {
  param([bool]$Condition, [string]$Message)
  $script:assertions += 1
  if (-not $Condition) {
    throw $Message
  }
}

function Assert-FixedFailure {
  param(
    [Parameter(Mandatory = $true)][scriptblock]$Action,
    [Parameter(Mandatory = $true)][string]$Expected,
    [Parameter(Mandatory = $true)][string]$Message
  )
  $actual = "no_failure"
  try { & $Action } catch { $actual = [string]$_.Exception.Message }
  Assert-True ($actual -ceq $Expected) "$Message; actual=$actual"
}

function New-EndpointResponse {
  param(
    [string]$ResultClass,
    [string]$ExpectationClass,
    [string]$AcceptedJoinClass = "",
    [int]$CapturePacketCount = 0,
    [int]$CaptureByteCount = 0,
    [string]$SignalClass = "signal_above_floor",
    [string]$VadDecisionClass = "speech_not_detected",
    [int]$TranscriptionCount = 0,
    [int]$SubmissionCount = 0,
    [int]$TurnInputCount = 0,
    [int]$ElapsedMs = 25,
    [object]$LastVadSpeechFrameOffsetMs = $null,
    [object]$UtteranceEndToCandidateResultMs = $null,
    [string]$UtteranceEndTimingClass = "",
    [object]$SttStartOffsetMs = $null,
    [object]$SttEndOffsetMs = $null,
    [object]$CanonicalAcceptOffsetMs = $null,
    [string]$CanonicalAcceptLatencyClass = "",
    [string]$InflightSinkCancellationClass = "",
    [string]$PresentationClass = "presentation_not_attempted",
    [object]$AssistantEventId = $null,
    [object]$ThoughtCoreFirstEventElapsedMs = $null,
    [int]$PcmCleanupCount = 0,
    [int]$PrivateAuthorityResidueCount = 0
  )

  if ([string]::IsNullOrWhiteSpace($UtteranceEndTimingClass)) {
    $UtteranceEndTimingClass = switch ($VadDecisionClass) {
      "speech_detected" {
        if ($null -ne $LastVadSpeechFrameOffsetMs) {
          "vad_speech_frame_available"
        } else {
          "vad_speech_frame_inconsistent"
        }
        break
      }
      "speech_not_detected" { "no_vad_speech_frame"; break }
      default { "not_evaluated" }
    }
  }
  if ($TranscriptionCount -eq 1 -and $null -eq $SttStartOffsetMs) {
    $SttStartOffsetMs = 0
    $SttEndOffsetMs = 5
  }
  if ($SubmissionCount -eq 1 -and $null -eq $CanonicalAcceptOffsetMs) {
    $CanonicalAcceptOffsetMs = 10
  }
  if ([string]::IsNullOrWhiteSpace($CanonicalAcceptLatencyClass)) {
    $CanonicalAcceptLatencyClass = if ($null -eq $CanonicalAcceptOffsetMs) {
      "not_evaluated"
    } elseif ([long]$CanonicalAcceptOffsetMs -le 2000) {
      "within_2s_target"
    } elseif ([long]$CanonicalAcceptOffsetMs -le 10000) {
      "over_2s_within_10s"
    } else {
      "over_10s"
    }
  }
  if ([string]::IsNullOrWhiteSpace($InflightSinkCancellationClass)) {
    $InflightSinkCancellationClass = if ($SubmissionCount -eq 1) {
      "not_required_within_10s"
    } else {
      "not_applicable"
    }
  }
  if ([string]::IsNullOrWhiteSpace($AcceptedJoinClass)) {
    $AcceptedJoinClass = if (
      $ResultClass -ceq "independent_user_speech_turninput_accepted"
    ) {
      "active_self_output_overlap"
    } else {
      "not_accepted"
    }
  }

  return [ordered]@{
    schema_version = "ai_talk_core.live_input_gate_candidate_window.v0"
    result_class = $ResultClass
    expectation_class = $ExpectationClass
    accepted_join_class = $AcceptedJoinClass
    capture_packet_count = $CapturePacketCount
    capture_byte_count = $CaptureByteCount
    signal_class = $SignalClass
    vad_decision_class = $VadDecisionClass
    transcription_count = $TranscriptionCount
    submission_count = $SubmissionCount
    thought_core_turninput_count = $TurnInputCount
    elapsed_ms = $ElapsedMs
    last_vad_speech_frame_offset_ms = $LastVadSpeechFrameOffsetMs
    utterance_end_to_candidate_result_ms = $UtteranceEndToCandidateResultMs
    utterance_end_timing_class = $UtteranceEndTimingClass
    stt_start_offset_ms = $SttStartOffsetMs
    stt_end_offset_ms = $SttEndOffsetMs
    canonical_accept_offset_ms = $CanonicalAcceptOffsetMs
    canonical_accept_latency_class = $CanonicalAcceptLatencyClass
    inflight_sink_cancellation_class = $InflightSinkCancellationClass
    presentation_class = $PresentationClass
    assistant_event_id = $AssistantEventId
    thought_core_first_event_elapsed_ms = $ThoughtCoreFirstEventElapsedMs
    pcm_cleanup_count = $PcmCleanupCount
    private_authority_residue_count = $PrivateAuthorityResidueCount
    raw_private_publication_flags = $false
  }
}

function Start-TestServer {
  param(
    [Parameter(Mandatory = $true)]$Response,
    [int]$StatusCode = 200,
    [int]$DelayMs = 0,
    [string]$Location = ""
  )

  $readyPath = Join-Path $tempRoot ("server-" + [guid]::NewGuid().ToString("N") + ".ready")
  $responseJson = $Response | ConvertTo-Json -Depth 6 -Compress
  $job = Start-Job -ArgumentList $readyPath, $responseJson, $StatusCode, $DelayMs, $privateToken, $Location -ScriptBlock {
    param($ReadyPath, $ResponseJson, $StatusCode, $DelayMs, $ExpectedToken, $Location)

    $listener = $null
    $client = $null
    $stream = $null
    try {
      $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
      $listener.Start()
      $port = ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port
      $readyTempPath = "$ReadyPath.tmp"
      [System.IO.File]::WriteAllText($readyTempPath, [string]$port, [System.Text.Encoding]::ASCII)
      [System.IO.File]::Move($readyTempPath, $ReadyPath)
      $acceptTask = $listener.AcceptTcpClientAsync()
      if (-not $acceptTask.Wait(5000)) {
        throw "test server accept timeout"
      }
      $client = $acceptTask.Result
      $stream = $client.GetStream()
      $stream.ReadTimeout = 5000
      $stream.WriteTimeout = 5000

      $headerBytes = [System.Collections.Generic.List[byte]]::new()
      $terminator = [byte[]](13, 10, 13, 10)
      while ($headerBytes.Count -lt 16384) {
        $value = $stream.ReadByte()
        if ($value -lt 0) {
          throw "request headers ended early"
        }
        $headerBytes.Add([byte]$value)
        if ($headerBytes.Count -ge 4) {
          $offset = $headerBytes.Count - 4
          if (
            $headerBytes[$offset] -eq $terminator[0] -and
            $headerBytes[$offset + 1] -eq $terminator[1] -and
            $headerBytes[$offset + 2] -eq $terminator[2] -and
            $headerBytes[$offset + 3] -eq $terminator[3]
          ) {
            break
          }
        }
      }
      $headers = [System.Text.Encoding]::ASCII.GetString($headerBytes.ToArray())
      $contentLengthMatch = [regex]::Match($headers, "(?im)^Content-Length:\s*(\d+)\s*$")
      if (-not $contentLengthMatch.Success) {
        throw "content length missing"
      }
      $contentLength = [int]$contentLengthMatch.Groups[1].Value
      if ($contentLength -lt 1 -or $contentLength -gt 4096) {
        throw "content length out of bounds"
      }
      $bodyBytes = [byte[]]::new($contentLength)
      $read = 0
      while ($read -lt $contentLength) {
        $count = $stream.Read($bodyBytes, $read, $contentLength - $read)
        if ($count -le 0) {
          throw "request body ended early"
        }
        $read += $count
      }
      $bodyText = [System.Text.Encoding]::UTF8.GetString($bodyBytes)
      $body = $bodyText | ConvertFrom-Json
      $firstLine = ($headers -split "`r`n")[0]
      $summary = [PSCustomObject]@{
        request_line_exact = $firstLine -ceq "POST /api/live-input-gate/candidate-window HTTP/1.1"
        token_header_exact = $headers.Contains("X-AI-Core-Token: $ExpectedToken`r`n")
        content_type_json = $headers.Contains("Content-Type: application/json; charset=utf-8`r`n")
        request_keys = @($body.PSObject.Properties.Name | Sort-Object)
        scenario = [string]$body.scenario
        window_ms = [int]$body.window_ms
        deadline_ms = [int]$body.deadline_ms
      }
      Write-Output $summary

      if ($DelayMs -gt 0) {
        Start-Sleep -Milliseconds $DelayMs
      }
      $reason = switch ($StatusCode) {
        200 { "OK" }
        302 { "Found" }
        400 { "Bad Request" }
        403 { "Forbidden" }
        404 { "Not Found" }
        409 { "Conflict" }
        503 { "Service Unavailable" }
        default { "Error" }
      }
      $responseBytes = [System.Text.Encoding]::UTF8.GetBytes($ResponseJson)
      $locationHeader = if ([string]::IsNullOrEmpty($Location)) { "" } else { "Location: $Location`r`n" }
      $responseHeaders = "HTTP/1.1 $StatusCode $reason`r`n${locationHeader}Content-Type: application/json`r`nContent-Length: $($responseBytes.Length)`r`nConnection: close`r`n`r`n"
      $headerOutput = [System.Text.Encoding]::ASCII.GetBytes($responseHeaders)
      try {
        $stream.Write($headerOutput, 0, $headerOutput.Length)
        $stream.Write($responseBytes, 0, $responseBytes.Length)
        $stream.Flush()
      } catch {
        if ($DelayMs -eq 0) {
          throw
        }
      }
    } finally {
      if ($null -ne $stream) { $stream.Dispose() }
      if ($null -ne $client) { $client.Dispose() }
      if ($null -ne $listener) { $listener.Stop() }
    }
  }
  $jobs.Add($job)

  $ready = $false
  for ($attempt = 0; $attempt -lt 150; $attempt++) {
    if (Test-Path -LiteralPath $readyPath) {
      $ready = $true
      break
    }
    if ($job.State -in @("Failed", "Stopped", "Completed")) {
      break
    }
    Start-Sleep -Milliseconds 20
  }
  if (-not $ready) {
    throw "test server did not become ready"
  }
  $port = [int]([System.IO.File]::ReadAllText($readyPath, [System.Text.Encoding]::ASCII))
  return [PSCustomObject]@{
    Job = $job
    BaseUrl = "http://127.0.0.1:$port"
    ReadyPath = $readyPath
    DelayMs = $DelayMs
    ResultClass = [string]$Response.result_class
  }
}

function Complete-TestServer {
  param([Parameter(Mandatory = $true)]$Server)

  $completed = Wait-Job -Job $Server.Job -Timeout 5
  Assert-True ($null -ne $completed) "test server did not complete"
  try {
    $rows = @(Receive-Job -Job $Server.Job -ErrorAction Stop)
  } catch {
    throw (
      "test server failed; result_class={0}; delay_ms={1}" -f
        $Server.ResultClass,
        $Server.DelayMs
    )
  }
  Assert-True ($Server.Job.State -ceq "Completed") "test server failed"
  Assert-True ($rows.Count -eq 1) "test server should return one request summary"
  return $rows[0]
}

function Initialize-TestObserverProcessFake {
  $source = @'
import fs from "node:fs";

const mode = process.env.SWORD_TEST_OBSERVER_MODE || "success";
const receiptPath = process.env.SWORD_TEST_OBSERVER_RECEIPT || "";
const pidReceiptPath = process.env.SWORD_TEST_OBSERVER_PID_RECEIPT || "";
if (pidReceiptPath) {
  fs.writeFileSync(pidReceiptPath, String(process.pid), {
    encoding: "ascii",
    flag: "wx",
  });
}
if (mode === "early_exit") {
  process.exit(4);
}
if (mode === "delayed_arm") {
  await new Promise((resolve) => setTimeout(resolve, 500));
}
if (mode === "over_preparation_arm") {
  await new Promise((resolve) => setTimeout(resolve, 1500));
}

process.stdout.write('{"schema_version":"primary_system_cell_visible_response_observer_arm.v1","result_class":"observer_armed","raw_private_publication_flags":false}\n');
let input = "";
for await (const chunk of process.stdin) {
  input += chunk;
}
const lines = input.split(/\r?\n/u).filter((value) => value.length > 0);
const messageId = lines.length === 1 ? lines[0] : null;
const safeId =
  typeof messageId === "string" &&
  /^[A-Za-z0-9_.:-]{1,128}$/u.test(messageId) &&
  !/(?:private|secret|token|path|url)/iu.test(messageId);
if (receiptPath) {
  fs.writeFileSync(
    receiptPath,
    JSON.stringify({
      line_count: lines.length,
      safe_id: safeId,
      raw_private_publication_flags: false,
    }),
    { encoding: "utf8", flag: "wx" },
  );
}

if (mode === "timeout") {
  await new Promise((resolve) => setTimeout(resolve, 30000));
  process.exit(5);
}
if (!safeId) {
  process.exit(6);
}
if (mode === "mismatch") {
  process.stdout.write('{"schema_version":"primary_system_cell_visible_response_observation.v1","result_class":"visible_response_timeout","visible_match_count":0,"observed_at_wall":null,"observer_elapsed_ms":100,"cleanup_class":"observer_socket_released","raw_private_publication_flags":false}\n');
  process.exit(1);
}

process.stdout.write(
  JSON.stringify({
    schema_version: "primary_system_cell_visible_response_observation.v1",
    result_class: "visible_response_observed",
    visible_match_count: 1,
    observed_at_wall: new Date(Date.now() + 250).toISOString().replace("Z", "0000Z"),
    observer_elapsed_ms: 100,
    cleanup_class: "observer_socket_released",
    raw_private_publication_flags: false,
  }) + "\n",
);
process.exit(0);
'@
  [System.IO.File]::WriteAllText(
    $fakeObserverModulePath,
    $source,
    [System.Text.UTF8Encoding]::new($false)
  )
  Assert-True ([System.IO.File]::Exists($fakeObserverModulePath)) "observer process fake module was not created"
}

function Initialize-TestProductionTransportProcessFake {
  $source = @'
param(
  [Parameter(Mandatory = $true)][string]$TriggerPath,
  [Parameter(Mandatory = $true)][string]$ResultPath,
  [Parameter(Mandatory = $true)][string]$Mode
)
$ErrorActionPreference = "Stop"
if ($Mode -ceq "delayed_listener") {
  Start-Sleep -Milliseconds 5500
}
[System.IO.File]::WriteAllText(
  "$TriggerPath.listener",
  "listening",
  [System.Text.Encoding]::ASCII)
[Console]::Out.WriteLine($(if ($Mode -ceq "bad_listener") {
  '{"schema_version":"invalid"}'
} else {
  '{"schema_version":"self_output_awareness.production_transport_listener.v0","result_class":"waiting_for_self_output","raw_private_publication_flags":false}'
}))
[Console]::Out.Flush()
if ($Mode -ceq "bad_listener") { exit 7 }
$deadline = [System.Diagnostics.Stopwatch]::StartNew()
while (-not [System.IO.File]::Exists($TriggerPath)) {
  if ($deadline.ElapsedMilliseconds -gt 5000) { exit 6 }
  Start-Sleep -Milliseconds 10
}
[System.IO.File]::WriteAllText(
  "$TriggerPath.arm",
  "armed",
  [System.Text.Encoding]::ASCII)
[Console]::Out.WriteLine($(if ($Mode -ceq "bad_arm") {
  '{"schema_version":"invalid"}'
} else {
  '{"schema_version":"self_output_awareness.production_transport_arm.v0","result_class":"overlap_join_ready","raw_private_publication_flags":false}'
}))
[Console]::Out.Flush()
if ($Mode -ceq "bad_arm") { exit 8 }
if ($Mode -ceq "timeout") {
  Start-Sleep -Seconds 30
  exit 5
}
if ($Mode -ceq "stderr") {
  [Console]::Error.WriteLine("fixed_child_failure")
  exit 4
}
if ($Mode -ceq "bad_output") {
  [Console]::Out.WriteLine('{"schema_version":"invalid"}')
  exit 0
}
[Console]::Out.WriteLine(
  [System.IO.File]::ReadAllText($ResultPath, [System.Text.Encoding]::UTF8))
exit 0
'@
  [System.IO.File]::WriteAllText(
    $fakeProductionTransportPath,
    $source,
    [System.Text.UTF8Encoding]::new($false))
  Assert-True ([System.IO.File]::Exists($fakeProductionTransportPath)) "production transport fake was not created"
}

function New-ProductionTransportResult {
  param([Parameter(Mandatory = $true)][long]$FirstAudioWallMs)

  return [ordered]@{
    schema_version = "self_output_awareness.production_transport.v0"
    status = "completed"
    result_class = "production_self_output_transport_completed"
    blocker_class = $null
    lifecycle_ingest_count = 3
    observation_ingest_count = 1
    lifecycle_ingest_outcome_class = "acknowledged"
    observation_ingest_outcome_class = "acknowledged"
    ait_poll_count = 4
    core_request_count = 4
    final_lifecycle_state = "released"
    observer_result_class = "process_tree_render_observed"
    first_non_silent_frame_offset_ms = 25
    first_non_silent_observed_at_utc_ms = $FirstAudioWallMs
    handoff_pickup_ms = 50
    cooldown_pickup_ms = 75
    released_pickup_ms = 100
    observation_ingest_ms = 125
    overlap_join_ready_class = "overlap_join_ready"
    elapsed_ms = 150
    latency_requirement_status = "first_non_silent_wall_timestamp_available"
    cleanup_class = "route_owned_cleanup_clear"
    route_owned_process_residue_count = 0
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
}

function New-ProductionTransportProcessFactory {
  param(
    [Parameter(Mandatory = $true)][string]$TriggerPath,
    [Parameter(Mandatory = $true)][string]$ResultPath,
    [Parameter(Mandatory = $true)][string]$Mode
  )

  $capturedPwshPath = [string]$pwsh.Source
  $capturedTransportPath = [string]$fakeProductionTransportPath
  return {
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $capturedPwshPath
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    [void]$startInfo.Environment.Remove("AI_TALK_CORE_WEB_TOKEN")
    foreach ($argument in @(
        "-NoProfile", "-File", $capturedTransportPath,
        "-TriggerPath", $TriggerPath,
        "-ResultPath", $ResultPath,
        "-Mode", $Mode
      )) {
      [void]$startInfo.ArgumentList.Add($argument)
    }
    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    return $process
  }.GetNewClosure()
}
function Invoke-Controller {
  param(
    [string]$BaseUrl,
    [string]$AitBaseUrl = "http://127.0.0.1:3000",
    [string]$Scenario = "self_output_or_ambiguous",
    [int]$WindowMs = 100,
    [int]$DeadlineMs = 1000,
    [string]$CdpEndpoint = "",
    [int]$ControlledChromeRootPid = 0,
    [int]$AudioObserverWindowMs = 3000,
    [int]$PreparationDeadlineMs = 20000,
    [bool]$ProvideToken = $true,
    [string]$ObserverMode = "",
    [string]$ObserverReceiptPath = "",
    [string]$ObserverPidReceiptPath = "",
    [bool]$EmitSelfOutputSuppressionReadySignal = $false
  )

  $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
  $startInfo.FileName = $pwsh.Source
  $startInfo.UseShellExecute = $false
  $startInfo.CreateNoWindow = $true
  $startInfo.RedirectStandardOutput = $true
  $startInfo.RedirectStandardError = $true
  foreach ($argument in @(
    "-NoProfile", "-File", $ControllerPath,
    "-BaseUrl", $BaseUrl,
    "-AitBaseUrl", $AitBaseUrl,
    "-Scenario", $Scenario,
    "-WindowMs", [string]$WindowMs,
    "-DeadlineMs", [string]$DeadlineMs,
    "-CdpEndpoint", $CdpEndpoint,
    "-ControlledChromeRootPid", [string]$ControlledChromeRootPid,
    "-AudioObserverWindowMs", [string]$AudioObserverWindowMs,
    "-PreparationDeadlineMs", [string]$PreparationDeadlineMs,
    "-Json"
  )) {
    [void]$startInfo.ArgumentList.Add($argument)
  }
  if ($EmitSelfOutputSuppressionReadySignal) {
    [void]$startInfo.ArgumentList.Add("-EmitSelfOutputSuppressionReadySignal")
  }
  if ($ProvideToken) {
    $startInfo.Environment["AI_TALK_CORE_WEB_TOKEN"] = $privateToken
  } else {
    [void]$startInfo.Environment.Remove("AI_TALK_CORE_WEB_TOKEN")
  }
  if (-not [string]::IsNullOrWhiteSpace($ObserverMode)) {
    $fakeObserverModuleUri = [System.Uri]::new($fakeObserverModulePath).AbsoluteUri
    $startInfo.Environment["NODE_OPTIONS"] = "--import=$fakeObserverModuleUri"
    $startInfo.Environment["SWORD_TEST_OBSERVER_MODE"] = $ObserverMode
    $startInfo.Environment["SWORD_TEST_OBSERVER_RECEIPT"] = $ObserverReceiptPath
    $startInfo.Environment["SWORD_TEST_OBSERVER_PID_RECEIPT"] = $ObserverPidReceiptPath
  }

  $process = [System.Diagnostics.Process]::new()
  $process.StartInfo = $startInfo
  try {
    Assert-True ($process.Start()) "controller process did not start"
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit([Math]::Max(15000, $DeadlineMs + 5000))) {
      $process.Kill($true)
      throw "controller process exceeded test boundary"
    }
    $stdout = $stdoutTask.Result.Trim()
    $stderr = $stderrTask.Result.Trim()
    Assert-True ([string]::IsNullOrWhiteSpace($stderr)) "controller wrote unexpected stderr"
    return [PSCustomObject]@{
      Code = $process.ExitCode
      Text = $stdout
    }
  } finally {
    if (-not $process.HasExited) {
      try { $process.Kill($true) } catch {}
    }
    $process.Dispose()
  }
}

function Assert-NoPrivateEcho {
  param([Parameter(Mandatory = $true)][string]$Text)

  Assert-True (-not $Text.Contains($privateToken)) "controller echoed the API token"
  Assert-True (-not $Text.Contains($privateResponseMarker)) "controller echoed a private endpoint field"
  Assert-True (-not $Text.Contains($tempRoot)) "controller echoed a temp path"
  Assert-True (-not $Text.Contains("candidate-window")) "controller echoed the endpoint path"
}

function Assert-CommonResult {
  param([Parameter(Mandatory = $true)]$Run)

  $result = $Run.Text | ConvertFrom-Json
  Assert-True ($result.schema_version -ceq "self_output_awareness.live_controller.v0") "controller schema mismatch"
  Assert-True ($result.raw_private_publication_flags -eq $false) "raw-private flag must stay false"
  Assert-True ($result.raw_audio_shared -eq $false) "raw audio must stay private"
  Assert-True ($result.raw_text_shared -eq $false) "raw text must stay private"
  Assert-True ($result.private_identifier_shared -eq $false) "private identifiers must stay private"
  Assert-True ($result.private_environment_shared -eq $false) "private environment must stay private"
  Assert-True ($result.route_owned_process_residue_count -eq 0) "controller must not leave a process"
  Assert-True ($result.route_owned_temp_residue_count -eq 0) "controller must not leave temp residue"
  Assert-True ($result.route_owned_request_residue_count -eq 0) "controller must dispose the request"
  Assert-NoPrivateEcho -Text $Run.Text
  return $result
}

function Assert-ObserverProcessReceipt {
  param([Parameter(Mandatory = $true)][string]$Path)

  Assert-True ([System.IO.File]::Exists($Path)) "observer process fake receipt missing"
  $receiptText = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
  $receipt = $receiptText | ConvertFrom-Json
  Assert-True ((@($receipt.PSObject.Properties.Name | Sort-Object) -join ",") -ceq "line_count,raw_private_publication_flags,safe_id") "observer process fake receipt keys mismatch"
  Assert-True ($receipt.line_count -eq 1) "controller must write exactly one observer id line"
  Assert-True ($receipt.safe_id -eq $true) "observer process fake did not receive one safe opaque id"
  Assert-True ($receipt.raw_private_publication_flags -eq $false) "observer process fake receipt privacy flag mismatch"
  Assert-True (-not $receiptText.Contains("evt-live-visible-1")) "observer process fake receipt must not persist the opaque id"
}

function Assert-ObserverProcessZeroIdReceipt {
  param([Parameter(Mandatory = $true)][string]$Path)

  Assert-True ([System.IO.File]::Exists($Path)) "observer zero-id receipt missing"
  $receiptText = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
  $receipt = $receiptText | ConvertFrom-Json
  Assert-True ($receipt.line_count -eq 0) "timed-out route must not write an observer id"
  Assert-True ($receipt.safe_id -eq $false) "timed-out route must not classify a safe observer id"
  Assert-True ($receipt.raw_private_publication_flags -eq $false) "observer zero-id receipt privacy flag mismatch"
  Assert-True (-not $receiptText.Contains("evt-live-visible-1")) "observer zero-id receipt must not persist the opaque id"
}

[System.IO.Directory]::CreateDirectory($tempRoot) | Out-Null
Initialize-TestObserverProcessFake
Initialize-TestProductionTransportProcessFake
. $ControllerPath
$controllerSource = Get-Content -LiteralPath $ControllerPath -Raw
$readySignal = New-UserSpeechReadySignal
Assert-True ((@($readySignal.Keys | Sort-Object) -join ",") -ceq
  "raw_private_publication_flags,result_class,schema_version") "ready signal keys must be exact"
Assert-True ($readySignal.schema_version -ceq
  "self_output_awareness.live_controller_ready.v0") "ready signal schema mismatch"
Assert-True ($readySignal.result_class -ceq "ready_for_user_speech") "ready signal class mismatch"
Assert-True ($readySignal.raw_private_publication_flags -is [bool] -and
  -not [bool]$readySignal.raw_private_publication_flags) "ready signal privacy mismatch"
$systemTriggerReadySignal = New-SystemOutputTriggerReadySignal
Assert-True ((@($systemTriggerReadySignal.Keys | Sort-Object) -join ",") -ceq
  "raw_private_publication_flags,result_class,schema_version") "system-output trigger signal keys must be exact"
Assert-True ($systemTriggerReadySignal.schema_version -ceq
  "self_output_awareness.system_output_trigger_ready.v0") "system-output trigger signal schema mismatch"
Assert-True ($systemTriggerReadySignal.result_class -ceq
  "ready_for_system_output_trigger") "system-output trigger signal class mismatch"
Assert-True ($systemTriggerReadySignal.raw_private_publication_flags -is [bool] -and
  -not [bool]$systemTriggerReadySignal.raw_private_publication_flags) "system-output trigger signal privacy mismatch"
$userStartReceivedSignal = New-UserStartReceivedSignal
Assert-True ((@($userStartReceivedSignal.Keys | Sort-Object) -join ",") -ceq
  "raw_private_publication_flags,result_class,schema_version") "user-start signal keys must be exact"
Assert-True ($userStartReceivedSignal.schema_version -ceq
  "self_output_awareness.user_start_received.v0") "user-start signal schema mismatch"
Assert-True ($userStartReceivedSignal.result_class -ceq "user_start_received") "user-start signal class mismatch"
Assert-True ($userStartReceivedSignal.raw_private_publication_flags -is [bool] -and
  -not [bool]$userStartReceivedSignal.raw_private_publication_flags) "user-start signal privacy mismatch"

$userStartEventName = "live-controller-user-start-" + [guid]::NewGuid().ToString("N")
$createdUserStartEvent = $false
$userStartEvent = [Threading.EventWaitHandle]::new(
  $false, [Threading.EventResetMode]::ManualReset, $userStartEventName, [ref]$createdUserStartEvent)
try {
  Assert-True $createdUserStartEvent "controller test start event must have one owner"
  Assert-True $userStartEvent.Set() "controller test start event must accept a signal"
  Wait-ForUserStartEvent -Name $userStartEventName -HoldMs 1000
} finally {
  $userStartEvent.Dispose()
}
Assert-FixedFailure {
  Wait-ForUserStartEvent -Name ("missing-user-start-" + [guid]::NewGuid().ToString("N")) -HoldMs 1000
} "user_start_event_unavailable" "missing controller start event must fail closed"
Assert-FixedFailure {
  Wait-ForUserStartEvent -Name "short" -HoldMs 999
} "live_controller_configuration_invalid" "invalid controller start event must fail closed"

$transportStartStatement = '$productionTransportProcess = Start-ProductionTransportChild'
$triggerReadyStatement = '$systemTriggerReadySignal = New-SystemOutputTriggerReadySignal'
$userStartWaitStatement = 'Wait-ForUserStartEvent -Name $UserStartEventName'
$preparationRestartStatement = '$controllerStopwatch.Restart()'
$userStartReceivedStatement = '$userStartReceivedSignal = New-UserStartReceivedSignal'
$overlapWaitStatement = 'Wait-ProductionTransportOverlapReady `'
$userClockStatement = '$userPhaseStopwatch = [System.Diagnostics.Stopwatch]::StartNew()'
$userReadyStatement = '$readySignal = New-UserSpeechReadySignal'
$negativeReadyStatement = '$readySignal = New-SelfOutputSuppressionReadySignal'
$routeOperationElapsedStatement = '$routeOperationElapsedMs = [long]$(if ($null -ne $userPhaseStopwatch)'
foreach ($exactMainStatement in @(
    $transportStartStatement,
    $triggerReadyStatement,
    $userStartWaitStatement,
    $preparationRestartStatement,
    $userStartReceivedStatement,
    $overlapWaitStatement,
    $userClockStatement,
    $userReadyStatement,
    $negativeReadyStatement,
    $routeOperationElapsedStatement
  )) {
  Assert-True (($controllerSource.Split($exactMainStatement).Count - 1) -eq 1) `
    "main-path preparation statement must occur exactly once: $exactMainStatement"
}
$transportStartIndex = $controllerSource.IndexOf($transportStartStatement)
$triggerReadyIndex = $controllerSource.IndexOf($triggerReadyStatement, $transportStartIndex)
$userStartWaitIndex = $controllerSource.IndexOf($userStartWaitStatement, $triggerReadyIndex)
$preparationRestartIndex = $controllerSource.IndexOf($preparationRestartStatement, $userStartWaitIndex)
$visibleObserverIndex = $controllerSource.IndexOf('$visibleObserverProcess = Start-VisibleResponseObserver', $preparationRestartIndex)
$userStartReceivedIndex = $controllerSource.IndexOf($userStartReceivedStatement, $visibleObserverIndex)
$overlapWaitIndex = $controllerSource.IndexOf($overlapWaitStatement, $userStartReceivedIndex)
$userClockIndex = $controllerSource.IndexOf($userClockStatement, $overlapWaitIndex)
$userReadyIndex = $controllerSource.IndexOf($userReadyStatement, $userClockIndex)
$candidateBudgetIndex = $controllerSource.IndexOf('$httpBudgetMs = Get-RemainingRouteBudgetMs', $userReadyIndex)
Assert-True ($transportStartIndex -ge 0 -and $triggerReadyIndex -gt $transportStartIndex -and
  $userStartWaitIndex -gt $triggerReadyIndex -and
  $preparationRestartIndex -gt $userStartWaitIndex -and
  $visibleObserverIndex -gt $preparationRestartIndex -and
  $userStartReceivedIndex -gt $visibleObserverIndex -and
  $overlapWaitIndex -gt $userStartReceivedIndex -and $userClockIndex -gt $overlapWaitIndex -and
  $userReadyIndex -gt $userClockIndex -and $candidateBudgetIndex -gt $userReadyIndex) `
  "listener, held user start, visible observer, overlap join, user clock, user-ready, and candidate request order must be exact"
$negativeReady = New-SelfOutputSuppressionReadySignal
Assert-True (
  (@($negativeReady.Keys | Sort-Object) -join ",") -ceq
    "raw_private_publication_flags,result_class,schema_version" -and
  $negativeReady.schema_version -ceq "self_output_awareness.live_controller_ready.v0" -and
  $negativeReady.result_class -ceq "ready_for_self_output_suppression_window" -and
  $negativeReady.raw_private_publication_flags -is [bool] -and
  -not [bool]$negativeReady.raw_private_publication_flags
) "negative ready signal must remain fixed and nonpublishing"
Assert-True ($controllerSource -match
  'EmitUserSpeechReadySignal\s+-or\s+\$EmitSelfOutputSuppressionReadySignal[\s\S]+New-SystemOutputTriggerReadySignal') `
  "both controlled modes must expose one system-output trigger readiness signal"
Assert-True ($controllerSource -match
  'self_output_or_ambiguous[\s\S]+firstNonSilentAudioObservationClass[\s\S]+utteranceEndToFirstAudioMs') `
  "negative process-tree audio observation must remain separate from utterance-derived latency"
Assert-True (Test-AcceptedJoinClass `
  -AcceptedJoinClass "active_self_output_overlap" `
  -ResultClass "independent_user_speech_turninput_accepted" `
  -ControlledChromeRootPid 1) "controlled concurrent run must accept active overlap"
Assert-True (-not (Test-AcceptedJoinClass `
  -AcceptedJoinClass "released_normal_input" `
  -ResultClass "independent_user_speech_turninput_accepted" `
  -ControlledChromeRootPid 1)) "controlled concurrent run must reject released normal input"
Assert-True (Test-AcceptedJoinClass `
  -AcceptedJoinClass "released_normal_input" `
  -ResultClass "independent_user_speech_turninput_accepted" `
  -ControlledChromeRootPid 0) "standalone positive run may accept released normal input"
Assert-True (Test-AcceptedJoinClass `
  -AcceptedJoinClass "not_accepted" `
  -ResultClass "self_output_or_ambiguous_confirmed" `
  -ControlledChromeRootPid 0) "negative run must retain not-accepted join"
Assert-True (-not (Test-AcceptedJoinClass `
  -AcceptedJoinClass "active_self_output_overlap" `
  -ResultClass "self_output_or_ambiguous_confirmed" `
  -ControlledChromeRootPid 0)) "negative run must reject an accepted overlap claim"
Assert-True ($controllerSource -match 'Start-ProductionTransportChild[\s\S]+Wait-ProductionTransportOverlapReady[\s\S]+\$endpointRequestStartedAtWallMs\s*=') "production transport must observe the overlap join before the D1 request starts"
Assert-True ($controllerSource -match '\$userPhaseStopwatch\s*=\s*\[System\.Diagnostics\.Stopwatch\]::StartNew\(\)[\s\S]+\$httpBudgetMs\s*=\s*Get-RemainingRouteBudgetMs') "post-ready route budget must start after the observed self-output join"
Assert-True ($controllerSource -match 'Get-RemainingPreparationBudgetMs[\s\S]+\$PreparationDeadlineMs[\s\S]+Start-ProductionTransportChild') "preparation must use its own bounded deadline"
Assert-True ($controllerSource -match 'Complete-ProductionTransportChild[\s\S]+first_non_silent_observed_at_utc_ms[\s\S]+utteranceEndToFirstAudioMs') "production result must feed the bounded first-audio delta"
Assert-True ($controllerSource -match 'candidate_authority[\s\S]+acceptance_authority[\s\S]+turn_input_authority') "production result validation must retain false authority fields"

try {
  $fixedNowUtcMs = [System.DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
  $fixedFirstAudioWallMs = $fixedNowUtcMs - 100
  $fixedUtteranceEndWallMs = $fixedFirstAudioWallMs - 250
  $productionResultPath = Join-Path $tempRoot "production-success.json"
  [System.IO.File]::WriteAllText(
    $productionResultPath,
    (New-ProductionTransportResult `
      -FirstAudioWallMs $fixedFirstAudioWallMs | ConvertTo-Json -Depth 6 -Compress),
    [System.Text.UTF8Encoding]::new($false))
  $threeRunStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
  foreach ($simulationIndex in 1..3) {
    $productionTriggerPath = Join-Path $tempRoot "production-success-$simulationIndex.trigger"
    $productionFactory = New-ProductionTransportProcessFactory `
      -TriggerPath $productionTriggerPath `
      -ResultPath $productionResultPath `
      -Mode "success"
    $listenerStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $productionProcess = Start-ProductionTransportChild `
      -AitEndpoint ([System.Uri]"http://127.0.0.1:3000/") `
      -AiTalkCoreEndpoint ([System.Uri]"http://127.0.0.1:8000/") `
      -ChromeRootPid 1 `
      -ObserverWindowMs 1000 `
      -ArmTimeoutMs 3000 `
      -RouteDeadlineMs 10000 `
      -ProcessFactory $productionFactory
    $listenerStopwatch.Stop()
    Assert-True ($listenerStopwatch.ElapsedMilliseconds -lt 2000) "simulation $simulationIndex listener readiness must be immediate"
    Assert-True ([System.IO.File]::Exists("$productionTriggerPath.listener")) "simulation $simulationIndex must report listener readiness"
    Assert-True (-not [System.IO.File]::Exists("$productionTriggerPath.arm")) "simulation $simulationIndex must not report overlap before the system-output trigger"
    Assert-True (-not [System.IO.File]::Exists($productionTriggerPath)) "simulation $simulationIndex trigger must remain absent while listener waits"
    Assert-True (-not $productionProcess.HasExited) "simulation $simulationIndex listener must remain ready"
    [System.IO.File]::WriteAllText(
      $productionTriggerPath,
      "triggered",
      [System.Text.Encoding]::ASCII)
    $overlapStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    Wait-ProductionTransportOverlapReady -Process $productionProcess -TimeoutMs 2000
    $overlapStopwatch.Stop()
    Assert-True ($overlapStopwatch.ElapsedMilliseconds -lt 1000) "simulation $simulationIndex overlap readiness must follow the trigger promptly"
    Assert-True ([System.IO.File]::Exists("$productionTriggerPath.arm")) "simulation $simulationIndex must report overlap after the trigger"
    $productionValue = Complete-ProductionTransportChild `
      -Process $productionProcess `
      -TimeoutMs 3000 `
      -RouteDeadlineMs 10000
    $productionProcess.Dispose()
    $productionProcess = $null
    Assert-True ($productionValue.first_non_silent_observed_at_utc_ms -eq $fixedFirstAudioWallMs) "simulation $simulationIndex must preserve the fixed first-audio wall"
  }
  $threeRunStopwatch.Stop()
  Assert-True ($threeRunStopwatch.ElapsedMilliseconds -lt 6000) "three preparation simulations must complete in seconds"

  $delayedListenerTriggerPath = Join-Path $tempRoot "production-delayed-listener.trigger"
  $delayedListenerFactory = New-ProductionTransportProcessFactory `
    -TriggerPath $delayedListenerTriggerPath `
    -ResultPath $productionResultPath `
    -Mode "delayed_listener"
  $delayedListenerStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
  $delayedListenerProcess = Start-ProductionTransportChild `
    -AitEndpoint ([System.Uri]"http://127.0.0.1:3000/") `
    -AiTalkCoreEndpoint ([System.Uri]"http://127.0.0.1:8000/") `
    -ChromeRootPid 1 `
    -ObserverWindowMs 1000 `
    -ArmTimeoutMs 6000 `
    -RouteDeadlineMs 10000 `
    -ProcessFactory $delayedListenerFactory
  $delayedListenerStopwatch.Stop()
  Assert-True ($delayedListenerStopwatch.ElapsedMilliseconds -ge 5000) "production listener must tolerate a real response beyond the former five-second cap"
  Assert-True ($delayedListenerStopwatch.ElapsedMilliseconds -lt 6500) "production listener delay must stay bounded"
  [System.IO.File]::WriteAllText(
    $delayedListenerTriggerPath,
    "triggered",
    [System.Text.Encoding]::ASCII)
  Wait-ProductionTransportOverlapReady -Process $delayedListenerProcess -TimeoutMs 2000
  $delayedListenerValue = Complete-ProductionTransportChild `
    -Process $delayedListenerProcess `
    -TimeoutMs 3000 `
    -RouteDeadlineMs 10000
  $delayedListenerProcess.Dispose()
  $delayedListenerProcess = $null
  Assert-True ($delayedListenerValue.result_class -ceq "production_self_output_transport_completed") "delayed production listener must complete through the normal fixed result"
  $fixedAudioDelta = Resolve-UtteranceEndToFirstAudioMs `
    -UtteranceEndWallMs $fixedUtteranceEndWallMs `
    -FirstAudioWallMs $fixedFirstAudioWallMs `
    -RouteDeadlineMs 10000 `
    -ObservedNowUtcMs $fixedNowUtcMs
  Assert-True ($fixedAudioDelta -eq 250) "Parent must derive the exact utterance-end to first-audio delta"
  Assert-FixedFailure {
    Resolve-UtteranceEndToFirstAudioMs `
      -UtteranceEndWallMs $fixedFirstAudioWallMs `
      -FirstAudioWallMs ($fixedFirstAudioWallMs - 1) `
      -RouteDeadlineMs 10000 `
      -ObservedNowUtcMs $fixedNowUtcMs
  } "production_transport_not_completed" "negative first-audio delta must fail closed"
  Assert-FixedFailure {
    Resolve-UtteranceEndToFirstAudioMs `
      -UtteranceEndWallMs ($fixedFirstAudioWallMs - 10001) `
      -FirstAudioWallMs $fixedFirstAudioWallMs `
      -RouteDeadlineMs 10000 `
      -ObservedNowUtcMs $fixedNowUtcMs
  } "production_transport_not_completed" "over-deadline first-audio delta must fail closed"
  Assert-FixedFailure {
    Resolve-UtteranceEndToFirstAudioMs `
      -UtteranceEndWallMs $fixedUtteranceEndWallMs `
      -FirstAudioWallMs ($fixedNowUtcMs + 1001) `
      -RouteDeadlineMs 10000 `
      -ObservedNowUtcMs $fixedNowUtcMs
  } "production_transport_not_completed" "future first-audio wall must fail closed at Parent"

  $badListenerTriggerPath = Join-Path $tempRoot "production-bad-listener.trigger"
  $badListenerFactory = New-ProductionTransportProcessFactory `
    -TriggerPath $badListenerTriggerPath `
    -ResultPath $productionResultPath `
    -Mode "bad_listener"
  Assert-FixedFailure {
    Start-ProductionTransportChild `
      -AitEndpoint ([System.Uri]"http://127.0.0.1:3000/") `
      -AiTalkCoreEndpoint ([System.Uri]"http://127.0.0.1:8000/") `
      -ChromeRootPid 1 `
      -ObserverWindowMs 1000 `
      -ArmTimeoutMs 1000 `
      -RouteDeadlineMs 10000 `
      -ProcessFactory $badListenerFactory
  } "production_transport_unavailable" "malformed listener readiness must fail closed before the system-output trigger"
  Assert-True (-not [System.IO.File]::Exists($badListenerTriggerPath)) "malformed listener readiness must not create a trigger"

  $badArmTriggerPath = Join-Path $tempRoot "production-bad-arm.trigger"
  $badArmFactory = New-ProductionTransportProcessFactory `
    -TriggerPath $badArmTriggerPath `
    -ResultPath $productionResultPath `
    -Mode "bad_arm"
  $caseProcess = Start-ProductionTransportChild `
    -AitEndpoint ([System.Uri]"http://127.0.0.1:3000/") `
    -AiTalkCoreEndpoint ([System.Uri]"http://127.0.0.1:8000/") `
    -ChromeRootPid 1 `
    -ObserverWindowMs 1000 `
    -ArmTimeoutMs 1000 `
    -RouteDeadlineMs 10000 `
    -ProcessFactory $badArmFactory
  $badArmProcessId = $caseProcess.Id
  [System.IO.File]::WriteAllText(
    $badArmTriggerPath,
    "triggered",
    [System.Text.Encoding]::ASCII)
  Assert-FixedFailure {
    Wait-ProductionTransportOverlapReady -Process $caseProcess -TimeoutMs 1000
  } "production_transport_unavailable" "malformed overlap readiness must fail closed"
  Assert-True (Stop-ProductionTransportChild -Process $caseProcess) "malformed overlap readiness cleanup must be exact"
  $caseProcess = $null
  Start-Sleep -Milliseconds 20
  Assert-True ($null -eq (Get-Process -Id $badArmProcessId -ErrorAction SilentlyContinue)) "malformed overlap readiness must leave zero process residue"

  foreach ($mode in @("bad_output", "stderr", "timeout")) {
    $caseTriggerPath = Join-Path $tempRoot "production-$mode.trigger"
    $caseResultPath = Join-Path $tempRoot "production-$mode.json"
    [System.IO.File]::WriteAllText(
      $caseResultPath,
      (New-ProductionTransportResult `
        -FirstAudioWallMs $fixedFirstAudioWallMs | ConvertTo-Json -Depth 6 -Compress),
      [System.Text.UTF8Encoding]::new($false))
    $caseFactory = New-ProductionTransportProcessFactory `
      -TriggerPath $caseTriggerPath `
      -ResultPath $caseResultPath `
      -Mode $mode
    $caseProcess = Start-ProductionTransportChild `
      -AitEndpoint ([System.Uri]"http://127.0.0.1:3000/") `
      -AiTalkCoreEndpoint ([System.Uri]"http://127.0.0.1:8000/") `
      -ChromeRootPid 1 `
      -ObserverWindowMs 1000 `
      -ArmTimeoutMs 1000 `
      -RouteDeadlineMs 10000 `
      -ProcessFactory $caseFactory
    $caseProcessId = $caseProcess.Id
    [System.IO.File]::WriteAllText(
      $caseTriggerPath,
      "triggered",
      [System.Text.Encoding]::ASCII)
    Wait-ProductionTransportOverlapReady -Process $caseProcess -TimeoutMs 1000
    $expectedFailure = $(if ($mode -ceq "timeout") {
        "whole_route_timeout"
      } else {
        "production_transport_not_completed"
      })
    Assert-FixedFailure {
      Complete-ProductionTransportChild `
        -Process $caseProcess `
        -TimeoutMs 100 `
        -RouteDeadlineMs 1000
    } $expectedFailure "production child $mode must fail with a fixed class"
    Assert-True (Stop-ProductionTransportChild -Process $caseProcess) "production child $mode cleanup must be exact"
    $caseProcess = $null
    Start-Sleep -Milliseconds 20
    Assert-True ($null -eq (Get-Process -Id $caseProcessId -ErrorAction SilentlyContinue)) "production child $mode must leave zero process residue"
  }

  $negativeResponse = New-EndpointResponse `
    -ResultClass "self_output_or_ambiguous_confirmed" `
    -ExpectationClass "matched" `
    -CapturePacketCount 10 `
    -CaptureByteCount 3200 `
    -ElapsedMs 75 `
    -PcmCleanupCount 1
  $negativeServer = Start-TestServer -Response $negativeResponse
  $negativeRun = Invoke-Controller -BaseUrl $negativeServer.BaseUrl
  $negativeRequest = Complete-TestServer -Server $negativeServer
  $negative = Assert-CommonResult -Run $negativeRun
  Assert-True ($negativeRun.Code -eq 0) "negative scenario should complete"
  Assert-True ($negative.controller_status -ceq "completed") "negative scenario status mismatch"
  Assert-True ($negative.scenario -ceq "self_output_or_ambiguous") "negative result scenario mismatch"
  Assert-True ($negative.result_class -ceq "self_output_or_ambiguous_confirmed") "negative result mismatch"
  Assert-True ($negative.accepted_join_class -ceq "not_accepted") "negative accepted-join class mismatch"
  Assert-True ($negative.signal_class -ceq "signal_above_floor") "negative signal class mismatch"
  Assert-True ($negative.vad_decision_class -ceq "speech_not_detected") "negative VAD class mismatch"
  Assert-True ($negative.transcription_count -eq 0) "negative scenario must not transcribe"
  Assert-True ($negative.submission_count -eq 0) "negative scenario must not submit"
  Assert-True ($negative.thought_core_turninput_count -eq 0) "negative scenario must not materialize TurnInput"
  Assert-True ($negative.cleanup_class -ceq "controller_http_resources_disposed_endpoint_pcm_and_authority_clear") "negative cleanup mismatch"
  Assert-True ($negative.deadline_class -ceq "within_deadline") "negative deadline mismatch"
  Assert-True ($negative.endpoint_completion_class -ceq "completed_response_observed") "negative endpoint completion mismatch"
  Assert-True $negativeRequest.request_line_exact "controller request path mismatch"
  Assert-True $negativeRequest.token_header_exact "controller token header mismatch"
  Assert-True $negativeRequest.content_type_json "controller content type mismatch"
  Assert-True (($negativeRequest.request_keys -join ",") -ceq "deadline_ms,scenario,window_ms") "controller request keys must be exact"
  Assert-True ($negativeRequest.scenario -ceq "self_output_or_ambiguous") "negative request scenario mismatch"
  Assert-True ($negativeRequest.window_ms -eq 100) "negative request window mismatch"
  Assert-True ($negativeRequest.deadline_ms -ge 300) "negative request deadline must preserve the endpoint minimum"
  Assert-True ($negativeRequest.deadline_ms -le 1000) "negative request deadline must not exceed the route budget"

  $positiveResponse = New-EndpointResponse `
    -ResultClass "independent_user_speech_turninput_accepted" `
    -ExpectationClass "matched" `
    -CapturePacketCount 12 `
    -CaptureByteCount 3840 `
    -TranscriptionCount 1 `
    -SubmissionCount 1 `
    -TurnInputCount 1 `
    -VadDecisionClass "speech_detected" `
    -ElapsedMs 90 `
    -LastVadSpeechFrameOffsetMs 80 `
    -UtteranceEndToCandidateResultMs 10 `
    -PresentationClass "aituber_presentation_forwarded" `
    -AssistantEventId "evt-live-visible-1" `
    -ThoughtCoreFirstEventElapsedMs 35 `
    -PcmCleanupCount 1
  $positiveServer = Start-TestServer -Response $positiveResponse
  $positiveRun = Invoke-Controller `
    -BaseUrl $positiveServer.BaseUrl `
    -Scenario "independent_current_session_user_speech"
  [void](Complete-TestServer -Server $positiveServer)
  $positive = Assert-CommonResult -Run $positiveRun
  Assert-True ($positiveRun.Code -eq 0) "positive scenario should complete"
  Assert-True ($positive.controller_status -ceq "completed") "positive status mismatch"
  Assert-True ($positive.scenario -ceq "independent_current_session_user_speech") "positive result scenario mismatch"
  Assert-True ($positive.accepted_join_class -ceq "active_self_output_overlap") "positive accepted-join class mismatch"
  Assert-True ($positive.signal_class -ceq "signal_above_floor") "positive signal class mismatch"
  Assert-True ($positive.vad_decision_class -ceq "speech_detected") "positive VAD class mismatch"
  Assert-True ($positive.transcription_count -eq 1) "positive scenario should transcribe once"
  Assert-True ($positive.submission_count -eq 1) "positive scenario should submit once"
  Assert-True ($positive.thought_core_turninput_count -eq 1) "positive scenario should materialize one TurnInput"
  Assert-True ($positive.last_vad_speech_frame_offset_ms -eq 80) "positive scenario should preserve the last VAD speech frame offset"
  Assert-True ($positive.utterance_end_to_candidate_result_ms -eq 10) "positive scenario should preserve utterance-end to candidate-result timing"
  Assert-True ($positive.utterance_end_timing_class -ceq "vad_speech_frame_available") "positive utterance-end timing class mismatch"
  Assert-True ($positive.presentation_class -ceq "aituber_presentation_forwarded") "positive presentation class mismatch"
  Assert-True ($positive.thought_core_first_event_elapsed_ms -eq 35) "positive first-event timing mismatch"
  Assert-True ($positive.visible_response_class -ceq "not_observed") "positive visible proof must remain explicit without CDP"
  Assert-True ($positive.visible_match_count -eq 0) "positive visible count must remain zero without CDP"
  Assert-True ($null -eq $positive.utterance_end_to_first_visible_ms) "positive visible latency must remain unavailable without CDP"
  Assert-True (-not $positiveRun.Text.Contains("evt-live-visible-1")) "controller must not publish the assistant event id"

  $visibleReceipt = Join-Path $tempRoot "observer-success.receipt.json"
  $visibleServer = Start-TestServer -Response $positiveResponse -DelayMs 120
  $visibleRun = Invoke-Controller `
    -BaseUrl $visibleServer.BaseUrl `
    -Scenario "independent_current_session_user_speech" `
    -DeadlineMs 5000 `
    -CdpEndpoint "http://127.0.0.1:9222/" `
    -ObserverMode "success" `
    -ObserverReceiptPath $visibleReceipt
  [void](Complete-TestServer -Server $visibleServer)
  $visible = Assert-CommonResult -Run $visibleRun
  Assert-ObserverProcessReceipt -Path $visibleReceipt
  Assert-True ($visibleRun.Code -eq 0) (
    "correlated visible scenario should complete; blocker={0}; class={1}; count={2}; elapsed={3}" -f
      $visible.blocker_class,
      $visible.visible_response_class,
      $visible.visible_match_count,
      $visible.utterance_end_to_first_visible_ms
  )
  Assert-True ($visible.visible_response_class -ceq "visible_response_observed") "visible response class mismatch"
  Assert-True ($visible.visible_match_count -eq 1) "visible response count mismatch"
  Assert-True ($visible.first_visible_observer_elapsed_ms -ge 0) "visible observer timing missing"
  Assert-True ($visible.utterance_end_to_first_visible_ms -ge 0) "utterance-end to visible timing missing"
  Assert-True ($visible.utterance_end_to_first_visible_ms -le 5000) "utterance-end to visible timing exceeded deadline"
  Assert-True ($visible.first_non_silent_audio_observation_class -ceq "not_observed") "visible-only route must not claim audio observation"
  Assert-True ($null -eq $visible.utterance_end_to_first_audio_ms) "visible-only route must not claim audio latency"
  Assert-True (-not $visibleRun.Text.Contains("evt-live-visible-1")) "correlated visible run must not publish the assistant event id"

  $mismatchedReceipt = Join-Path $tempRoot "observer-mismatch.receipt.json"
  $mismatchedVisibleServer = Start-TestServer -Response $positiveResponse
  $mismatchedVisibleRun = Invoke-Controller `
    -BaseUrl $mismatchedVisibleServer.BaseUrl `
    -Scenario "independent_current_session_user_speech" `
    -DeadlineMs 5000 `
    -CdpEndpoint "http://127.0.0.1:9222/" `
    -ObserverMode "mismatch" `
    -ObserverReceiptPath $mismatchedReceipt
  [void](Complete-TestServer -Server $mismatchedVisibleServer)
  $mismatchedVisible = Assert-CommonResult -Run $mismatchedVisibleRun
  Assert-ObserverProcessReceipt -Path $mismatchedReceipt
  Assert-True ($mismatchedVisibleRun.Code -ne 0) "changed visible id must fail closed"
  Assert-True ($mismatchedVisible.blocker_class -ceq "visible_response_not_observed") "changed visible id blocker mismatch"
  Assert-True ($mismatchedVisible.visible_match_count -eq 0) "changed visible id must observe zero matches"
  Assert-True (-not $mismatchedVisibleRun.Text.Contains("evt-live-visible-1")) "changed visible id run must not publish the assistant event id"

  $observerTimeoutReceipt = Join-Path $tempRoot "observer-timeout.receipt.json"
  $observerTimeoutServer = Start-TestServer -Response $positiveResponse
  $observerTimeoutStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
  $observerTimeoutRun = Invoke-Controller `
    -BaseUrl $observerTimeoutServer.BaseUrl `
    -Scenario "independent_current_session_user_speech" `
    -DeadlineMs 5000 `
    -CdpEndpoint "http://127.0.0.1:9222/" `
    -ObserverMode "timeout" `
    -ObserverReceiptPath $observerTimeoutReceipt
  $observerTimeoutStopwatch.Stop()
  [void](Complete-TestServer -Server $observerTimeoutServer)
  $observerTimeout = Assert-CommonResult -Run $observerTimeoutRun
  Assert-ObserverProcessReceipt -Path $observerTimeoutReceipt
  Assert-True ($observerTimeoutRun.Code -ne 0) "observer timeout must fail closed"
  Assert-True ($observerTimeout.blocker_class -ceq "visible_response_not_observed") "observer timeout blocker mismatch"
  Assert-True ($observerTimeout.deadline_ms -eq 5000) "observer timeout must preserve the 5000ms product deadline"
  Assert-True ($observerTimeout.cleanup_class -ceq "controller_http_resources_disposed_endpoint_pcm_and_authority_clear") "observer timeout cleanup mismatch"
  Assert-True ($observerTimeoutStopwatch.ElapsedMilliseconds -lt 7000) (
    "observer timeout exceeded bounded test duration: {0}ms" -f
      $observerTimeoutStopwatch.ElapsedMilliseconds)

  $observerEarlyExitRun = Invoke-Controller `
    -BaseUrl "http://127.0.0.1:65534" `
    -Scenario "independent_current_session_user_speech" `
    -DeadlineMs 3000 `
    -CdpEndpoint "http://127.0.0.1:9222/" `
    -ObserverMode "early_exit"
  $observerEarlyExit = Assert-CommonResult -Run $observerEarlyExitRun
  Assert-True ($observerEarlyExitRun.Code -ne 0) "observer early exit must fail closed"
  Assert-True ($observerEarlyExit.blocker_class -ceq "visible_response_observer_unavailable") "observer early-exit blocker mismatch"

  $observerPreparationPidReceipt = Join-Path $tempRoot "observer-preparation.pid"
  $observerPreparationStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
  $observerPreparationRun = Invoke-Controller `
    -BaseUrl "http://127.0.0.1:65534" `
    -Scenario "independent_current_session_user_speech" `
    -DeadlineMs 5000 `
    -PreparationDeadlineMs 1000 `
    -CdpEndpoint "http://127.0.0.1:9222/" `
    -ObserverMode "over_preparation_arm" `
    -ObserverPidReceiptPath $observerPreparationPidReceipt
  $observerPreparationStopwatch.Stop()
  $observerPreparation = Assert-CommonResult -Run $observerPreparationRun
  Assert-True ($observerPreparationRun.Code -ne 0) "observer arm beyond preparation must fail closed"
  Assert-True ($observerPreparation.blocker_class -ceq "visible_response_observer_unavailable") "observer preparation blocker mismatch"
  Assert-True ($observerPreparation.route_owned_process_residue_count -eq 0) "observer preparation timeout must leave zero child residue"
  Assert-True ($observerPreparationStopwatch.ElapsedMilliseconds -lt 2500) "observer preparation timeout exceeded its bounded wall duration"
  Assert-True ([System.IO.File]::Exists($observerPreparationPidReceipt)) "observer preparation PID receipt missing"
  $observerPreparationPid = [int]([System.IO.File]::ReadAllText(
      $observerPreparationPidReceipt,
      [System.Text.Encoding]::ASCII))
  Assert-True ($null -eq (Get-Process -Id $observerPreparationPid -ErrorAction SilentlyContinue)) "observer preparation timeout left a live child process"

  $sharedDeadlineReceipt = Join-Path $tempRoot "observer-shared-deadline.receipt.json"
  $sharedDeadlineServer = Start-TestServer -Response $positiveResponse -DelayMs 4500
  $sharedDeadlineStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
  $sharedDeadlineRun = Invoke-Controller `
    -BaseUrl $sharedDeadlineServer.BaseUrl `
    -Scenario "independent_current_session_user_speech" `
    -DeadlineMs 5000 `
    -CdpEndpoint "http://127.0.0.1:9222/" `
    -ObserverMode "delayed_arm" `
    -ObserverReceiptPath $sharedDeadlineReceipt
  $sharedDeadlineStopwatch.Stop()
  [void](Complete-TestServer -Server $sharedDeadlineServer)
  $sharedDeadline = Assert-CommonResult -Run $sharedDeadlineRun
  Assert-ObserverProcessZeroIdReceipt -Path $sharedDeadlineReceipt
  Assert-True ($sharedDeadlineRun.Code -ne 0) "combined arm and HTTP delay must fail closed"
  Assert-True ($sharedDeadline.blocker_class -ceq "whole_route_timeout") "shared deadline blocker mismatch"
  Assert-True ($sharedDeadline.controller_elapsed_ms -le 5100) "controller renewed the route deadline across blocking phases"
  Assert-True (
    $controllerSource.IndexOf($routeOperationElapsedStatement, [StringComparison]::Ordinal) -lt
      $controllerSource.IndexOf(
        'foreach ($resource in @($response, $content, $request, $client, $cancellation, $handler))',
        [StringComparison]::Ordinal)
  ) "controller elapsed time must freeze before bounded cleanup"
  Assert-True ($sharedDeadlineStopwatch.ElapsedMilliseconds -lt 6500) "shared deadline test exceeded its bounded wall duration"

  $presentationFailureResponse = New-EndpointResponse `
    -ResultClass "independent_user_speech_turninput_accepted" `
    -ExpectationClass "matched" `
    -CapturePacketCount 12 `
    -CaptureByteCount 3840 `
    -TranscriptionCount 1 `
    -SubmissionCount 1 `
    -TurnInputCount 1 `
    -VadDecisionClass "speech_detected" `
    -ElapsedMs 90 `
    -LastVadSpeechFrameOffsetMs 80 `
    -UtteranceEndToCandidateResultMs 10 `
    -PresentationClass "aituber_presentation_not_forwarded" `
    -PcmCleanupCount 1
  $presentationFailureServer = Start-TestServer -Response $presentationFailureResponse
  $presentationFailureRun = Invoke-Controller `
    -BaseUrl $presentationFailureServer.BaseUrl `
    -Scenario "independent_current_session_user_speech"
  [void](Complete-TestServer -Server $presentationFailureServer)
  $presentationFailure = Assert-CommonResult -Run $presentationFailureRun
  Assert-True ($presentationFailureRun.Code -eq 0) "presentation failure must not rewrite accepted TurnInput"
  Assert-True ($presentationFailure.submission_count -eq 1) "presentation failure must preserve submission count"
  Assert-True ($presentationFailure.thought_core_turninput_count -eq 1) "presentation failure must preserve TurnInput count"
  Assert-True ($presentationFailure.presentation_class -ceq "aituber_presentation_not_forwarded") "presentation failure class mismatch"

  $mismatchResponse = New-EndpointResponse `
    -ResultClass "scenario_expectation_not_met" `
    -ExpectationClass "mismatch" `
    -CapturePacketCount 8 `
    -CaptureByteCount 2560 `
    -ElapsedMs 60 `
    -PcmCleanupCount 1
  $mismatchServer = Start-TestServer -Response $mismatchResponse
  $mismatchRun = Invoke-Controller `
    -BaseUrl $mismatchServer.BaseUrl `
    -Scenario "independent_current_session_user_speech"
  [void](Complete-TestServer -Server $mismatchServer)
  $mismatch = Assert-CommonResult -Run $mismatchRun
  Assert-True ($mismatchRun.Code -ne 0) "expectation mismatch must block"
  Assert-True ($mismatch.controller_status -ceq "blocked") "expectation mismatch status mismatch"
  Assert-True ($mismatch.blocker_class -ceq "scenario_expectation_not_met") "expectation mismatch blocker mismatch"
  Assert-True ($mismatch.submission_count -eq 0) "expectation mismatch must submit zero"

  $extraFieldResponse = New-EndpointResponse `
    -ResultClass "self_output_or_ambiguous_confirmed" `
    -ExpectationClass "matched" `
    -CapturePacketCount 10 `
    -CaptureByteCount 3200 `
    -PcmCleanupCount 1
  $extraFieldResponse.transcript = $privateResponseMarker
  $extraServer = Start-TestServer -Response $extraFieldResponse
  $extraRun = Invoke-Controller -BaseUrl $extraServer.BaseUrl
  [void](Complete-TestServer -Server $extraServer)
  $extra = Assert-CommonResult -Run $extraRun
  Assert-True ($extraRun.Code -ne 0) "extra response field must fail closed"
  Assert-True ($extra.blocker_class -ceq "live_controller_endpoint_response_invalid") "extra field blocker mismatch"

  $privateIdResponse = New-EndpointResponse `
    -ResultClass "independent_user_speech_turninput_accepted" `
    -ExpectationClass "matched" `
    -CapturePacketCount 12 `
    -CaptureByteCount 3840 `
    -TranscriptionCount 1 `
    -SubmissionCount 1 `
    -TurnInputCount 1 `
    -VadDecisionClass "speech_detected" `
    -ElapsedMs 90 `
    -LastVadSpeechFrameOffsetMs 80 `
    -UtteranceEndToCandidateResultMs 10 `
    -PresentationClass "aituber_presentation_forwarded" `
    -AssistantEventId "evt.private.marker" `
    -ThoughtCoreFirstEventElapsedMs 35 `
    -PcmCleanupCount 1
  $privateIdServer = Start-TestServer -Response $privateIdResponse
  $privateIdRun = Invoke-Controller `
    -BaseUrl $privateIdServer.BaseUrl `
    -Scenario "independent_current_session_user_speech"
  [void](Complete-TestServer -Server $privateIdServer)
  $privateId = Assert-CommonResult -Run $privateIdRun
  Assert-True ($privateIdRun.Code -ne 0) "private-like event id must fail closed"
  Assert-True ($privateId.blocker_class -ceq "live_controller_endpoint_response_invalid") "private-like event id blocker mismatch"
  Assert-True (-not $privateIdRun.Text.Contains("evt.private.marker")) "private-like event id must not echo"

  $invalidDiagnosticResponse = New-EndpointResponse `
    -ResultClass "self_output_or_ambiguous_confirmed" `
    -ExpectationClass "matched" `
    -CapturePacketCount 10 `
    -CaptureByteCount 3200 `
    -PcmCleanupCount 1
  $invalidDiagnosticResponse.signal_class = $privateResponseMarker
  $invalidDiagnosticServer = Start-TestServer -Response $invalidDiagnosticResponse
  $invalidDiagnosticRun = Invoke-Controller -BaseUrl $invalidDiagnosticServer.BaseUrl
  [void](Complete-TestServer -Server $invalidDiagnosticServer)
  $invalidDiagnostic = Assert-CommonResult -Run $invalidDiagnosticRun
  Assert-True ($invalidDiagnosticRun.Code -ne 0) "invalid diagnostic class must fail closed"
  Assert-True ($invalidDiagnostic.blocker_class -ceq "live_controller_endpoint_response_invalid") "invalid diagnostic blocker mismatch"

  $invalidVadResponse = New-EndpointResponse `
    -ResultClass "self_output_or_ambiguous_confirmed" `
    -ExpectationClass "matched" `
    -CapturePacketCount 10 `
    -CaptureByteCount 3200 `
    -PcmCleanupCount 1
  $invalidVadResponse.vad_decision_class = $privateResponseMarker
  $invalidVadServer = Start-TestServer -Response $invalidVadResponse
  $invalidVadRun = Invoke-Controller -BaseUrl $invalidVadServer.BaseUrl
  [void](Complete-TestServer -Server $invalidVadServer)
  $invalidVad = Assert-CommonResult -Run $invalidVadRun
  Assert-True ($invalidVadRun.Code -ne 0) "invalid VAD class must fail closed"
  Assert-True ($invalidVad.blocker_class -ceq "live_controller_endpoint_response_invalid") "invalid VAD blocker mismatch"

  $unexpectedTimingResponse = New-EndpointResponse `
    -ResultClass "self_output_or_ambiguous_confirmed" `
    -ExpectationClass "matched" `
    -CapturePacketCount 10 `
    -CaptureByteCount 3200 `
    -LastVadSpeechFrameOffsetMs 10 `
    -ElapsedMs 25 `
    -PcmCleanupCount 1
  $unexpectedTimingServer = Start-TestServer -Response $unexpectedTimingResponse
  $unexpectedTimingRun = Invoke-Controller -BaseUrl $unexpectedTimingServer.BaseUrl
  [void](Complete-TestServer -Server $unexpectedTimingServer)
  $unexpectedTiming = Assert-CommonResult -Run $unexpectedTimingRun
  Assert-True ($unexpectedTimingRun.Code -ne 0) "no-speech timing offset must fail closed"
  Assert-True ($unexpectedTiming.blocker_class -ceq "live_controller_endpoint_response_invalid") "no-speech timing blocker mismatch"

  $timingSumMismatchResponse = New-EndpointResponse `
    -ResultClass "independent_user_speech_turninput_accepted" `
    -ExpectationClass "matched" `
    -CapturePacketCount 12 `
    -CaptureByteCount 3840 `
    -TranscriptionCount 1 `
    -SubmissionCount 1 `
    -TurnInputCount 1 `
    -VadDecisionClass "speech_detected" `
    -ElapsedMs 90 `
    -LastVadSpeechFrameOffsetMs 80 `
    -UtteranceEndToCandidateResultMs 11 `
    -PcmCleanupCount 1
  $timingSumMismatchServer = Start-TestServer -Response $timingSumMismatchResponse
  $timingSumMismatchRun = Invoke-Controller -BaseUrl $timingSumMismatchServer.BaseUrl -Scenario "independent_current_session_user_speech"
  [void](Complete-TestServer -Server $timingSumMismatchServer)
  $timingSumMismatch = Assert-CommonResult -Run $timingSumMismatchRun
  Assert-True ($timingSumMismatchRun.Code -ne 0) "timing sum mismatch must fail closed"
  Assert-True ($timingSumMismatch.blocker_class -ceq "live_controller_endpoint_response_invalid") "timing sum mismatch blocker mismatch"

  $impossibleDiagnosticResponse = New-EndpointResponse `
    -ResultClass "self_output_or_ambiguous_confirmed" `
    -ExpectationClass "matched" `
    -CapturePacketCount 10 `
    -CaptureByteCount 3200 `
    -SignalClass "all_zero" `
    -VadDecisionClass "speech_detected" `
    -PcmCleanupCount 1
  $impossibleDiagnosticServer = Start-TestServer -Response $impossibleDiagnosticResponse
  $impossibleDiagnosticRun = Invoke-Controller -BaseUrl $impossibleDiagnosticServer.BaseUrl
  [void](Complete-TestServer -Server $impossibleDiagnosticServer)
  $impossibleDiagnostic = Assert-CommonResult -Run $impossibleDiagnosticRun
  Assert-True ($impossibleDiagnosticRun.Code -ne 0) "impossible diagnostic combination must fail closed"
  Assert-True ($impossibleDiagnostic.blocker_class -ceq "live_controller_endpoint_response_invalid") "impossible diagnostic blocker mismatch"

  $reversedOrderingResponse = New-EndpointResponse `
    -ResultClass "live_candidate_processing_failed" `
    -ExpectationClass "not_evaluated" `
    -CapturePacketCount 10 `
    -CaptureByteCount 3200 `
    -SignalClass "not_evaluated" `
    -VadDecisionClass "speech_not_detected" `
    -PcmCleanupCount 1
  $reversedOrderingServer = Start-TestServer -Response $reversedOrderingResponse -StatusCode 503
  $reversedOrderingRun = Invoke-Controller -BaseUrl $reversedOrderingServer.BaseUrl
  [void](Complete-TestServer -Server $reversedOrderingServer)
  $reversedOrdering = Assert-CommonResult -Run $reversedOrderingRun
  Assert-True ($reversedOrderingRun.Code -ne 0) "reversed diagnostic ordering must fail closed"
  Assert-True ($reversedOrdering.blocker_class -ceq "live_controller_endpoint_response_invalid") "reversed diagnostic ordering blocker mismatch"

  $vadFailureResponse = New-EndpointResponse `
    -ResultClass "live_candidate_processing_failed" `
    -ExpectationClass "not_evaluated" `
    -CapturePacketCount 10 `
    -CaptureByteCount 3200 `
    -SignalClass "signal_above_floor" `
    -VadDecisionClass "not_evaluated" `
    -PcmCleanupCount 1
  $vadFailureServer = Start-TestServer -Response $vadFailureResponse -StatusCode 503
  $vadFailureRun = Invoke-Controller -BaseUrl $vadFailureServer.BaseUrl
  [void](Complete-TestServer -Server $vadFailureServer)
  $vadFailure = Assert-CommonResult -Run $vadFailureRun
  Assert-True ($vadFailureRun.Code -ne 0) "VAD failure should remain a blocking result"
  Assert-True ($vadFailure.blocker_class -ceq "live_candidate_processing_failed") "VAD failure class must survive"
  Assert-True ($vadFailure.cleanup_class -ceq "controller_http_resources_disposed_endpoint_pcm_and_authority_clear") "VAD failure cleanup mismatch"

  $countMismatchResponse = New-EndpointResponse `
    -ResultClass "independent_user_speech_turninput_accepted" `
    -ExpectationClass "matched" `
    -CapturePacketCount 10 `
    -CaptureByteCount 3200 `
    -TranscriptionCount 1 `
    -SubmissionCount 1 `
    -TurnInputCount 0 `
    -PcmCleanupCount 1
  $countServer = Start-TestServer -Response $countMismatchResponse
  $countRun = Invoke-Controller `
    -BaseUrl $countServer.BaseUrl `
    -Scenario "independent_current_session_user_speech"
  [void](Complete-TestServer -Server $countServer)
  $countMismatch = Assert-CommonResult -Run $countRun
  Assert-True ($countRun.Code -ne 0) "count mismatch must fail closed"
  Assert-True ($countMismatch.blocker_class -ceq "live_controller_endpoint_response_invalid") "count mismatch blocker mismatch"

  foreach ($fixedFailureClass in @(
      "voice_capture_dsp_start_failed",
      "live_aec_quality_metrics_cleanup_failed",
      "live_aec_quality_metrics_invariant_failed"
    )) {
    $fixedFailureResponse = New-EndpointResponse `
      -ResultClass $fixedFailureClass `
      -ExpectationClass "not_evaluated" `
      -SignalClass "not_evaluated" `
      -VadDecisionClass "not_evaluated"
    $fixedFailureServer = Start-TestServer -Response $fixedFailureResponse -StatusCode 503
    $fixedFailureRun = Invoke-Controller -BaseUrl $fixedFailureServer.BaseUrl
    [void](Complete-TestServer -Server $fixedFailureServer)
    $fixedFailure = Assert-CommonResult -Run $fixedFailureRun
    Assert-True ($fixedFailureRun.Code -ne 0) "fixed child failure must block"
    Assert-True ($fixedFailure.blocker_class -ceq $fixedFailureClass) "fixed child failure class must survive"
  }

  $redirectServer = Start-TestServer `
    -Response $negativeResponse `
    -StatusCode 302 `
    -Location "http://192.0.2.1/private-target"
  $redirectRun = Invoke-Controller -BaseUrl $redirectServer.BaseUrl
  [void](Complete-TestServer -Server $redirectServer)
  $redirect = Assert-CommonResult -Run $redirectRun
  Assert-True ($redirectRun.Code -ne 0) "redirect response must fail closed"
  Assert-True ($redirect.blocker_class -ceq "live_controller_endpoint_response_invalid") "redirect blocker mismatch"
  Assert-True ($redirect.http_status_class -ceq "unexpected_status") "redirect must not be followed"

  $timeoutResponse = New-EndpointResponse `
    -ResultClass "self_output_or_ambiguous_confirmed" `
    -ExpectationClass "matched" `
    -CapturePacketCount 10 `
    -CaptureByteCount 3200 `
    -PcmCleanupCount 1
  $timeoutServer = Start-TestServer -Response $timeoutResponse -DelayMs 1500
  $timeoutRun = Invoke-Controller -BaseUrl $timeoutServer.BaseUrl -WindowMs 100 -DeadlineMs 1000
  [void](Complete-TestServer -Server $timeoutServer)
  $timeout = Assert-CommonResult -Run $timeoutRun
  Assert-True ($timeoutRun.Code -ne 0) "timeout must fail closed"
  Assert-True ($timeout.blocker_class -ceq "whole_route_timeout") "timeout blocker mismatch"
  Assert-True ($timeout.deadline_class -ceq "exceeded") "timeout deadline class mismatch"
  Assert-True ($timeout.endpoint_completion_class -ceq "unverified_after_transport_end") "timeout endpoint completion must remain unverified"
  Assert-True ($timeout.cleanup_class -ceq "controller_http_resources_disposed_endpoint_completion_unverified") "timeout cleanup must not claim endpoint completion"
  Assert-True ($timeout.submission_count -eq 0) "timeout must submit zero"

  $missingTokenRun = Invoke-Controller `
    -BaseUrl "http://127.0.0.1:65534" `
    -ProvideToken $false
  $missingToken = Assert-CommonResult -Run $missingTokenRun
  Assert-True ($missingTokenRun.Code -ne 0) "missing token must fail"
  Assert-True ($missingToken.blocker_class -ceq "live_controller_token_unavailable") "missing token blocker mismatch"

  $nonLoopbackRun = Invoke-Controller -BaseUrl "http://192.0.2.1:8000"
  $nonLoopback = Assert-CommonResult -Run $nonLoopbackRun
  Assert-True ($nonLoopbackRun.Code -ne 0) "non-loopback URL must fail"
  Assert-True ($nonLoopback.blocker_class -ceq "live_controller_configuration_invalid") "non-loopback blocker mismatch"

  $invalidBoundsRun = Invoke-Controller `
    -BaseUrl "http://127.0.0.1:65534" `
    -WindowMs 3000 `
    -DeadlineMs 3100
  $invalidBounds = Assert-CommonResult -Run $invalidBoundsRun
  Assert-True ($invalidBoundsRun.Code -ne 0) "invalid bounds must fail"
  Assert-True ($invalidBounds.blocker_class -ceq "live_controller_configuration_invalid") "invalid bounds blocker mismatch"

  $audioWithoutVisibleRun = Invoke-Controller `
    -BaseUrl "http://127.0.0.1:65534" `
    -Scenario "independent_current_session_user_speech" `
    -DeadlineMs 5000 `
    -ControlledChromeRootPid 1
  $audioWithoutVisible = Assert-CommonResult -Run $audioWithoutVisibleRun
  Assert-True ($audioWithoutVisibleRun.Code -ne 0) "audio join without visible observer must fail before child start"
  Assert-True ($audioWithoutVisible.blocker_class -ceq "live_controller_configuration_invalid") "audio join without visible observer blocker mismatch"

  $audioDeadlineRun = Invoke-Controller `
    -BaseUrl "http://127.0.0.1:65534" `
    -Scenario "independent_current_session_user_speech" `
    -DeadlineMs 3500 `
    -PreparationDeadlineMs 3500 `
    -CdpEndpoint "http://127.0.0.1:9222/" `
    -ControlledChromeRootPid 1 `
    -AudioObserverWindowMs 3000
  $audioDeadline = Assert-CommonResult -Run $audioDeadlineRun
  Assert-True ($audioDeadlineRun.Code -ne 0) "audio join without enough preparation budget must fail before child start"
  Assert-True ($audioDeadline.blocker_class -ceq "live_controller_configuration_invalid") "audio preparation-budget blocker mismatch"

  $invalidScenarioMarker = "PRIVATE_INVALID_SCENARIO_SENTINEL"
  $invalidScenarioRun = Invoke-Controller `
    -BaseUrl "http://127.0.0.1:65534" `
    -Scenario $invalidScenarioMarker
  $invalidScenario = Assert-CommonResult -Run $invalidScenarioRun
  Assert-True ($invalidScenarioRun.Code -ne 0) "invalid scenario must fail"
  Assert-True ($invalidScenario.blocker_class -ceq "live_controller_configuration_invalid") "invalid scenario blocker mismatch"
  Assert-True ($invalidScenario.scenario -ceq "invalid") "invalid scenario must normalize to a fixed class"
  Assert-True (-not $invalidScenarioRun.Text.Contains($invalidScenarioMarker)) "invalid scenario must not echo"

  Write-Output "status=ok"
  Write-Output ("assertions={0}" -f $assertions)
  Write-Output "raw_private_publication_flags=false"
} finally {
  foreach ($ownedProcess in @($productionProcess, $delayedListenerProcess, $caseProcess)) {
    if ($null -ne $ownedProcess) {
      [void](Stop-ProductionTransportChild -Process $ownedProcess)
    }
  }
  foreach ($job in $jobs) {
    if ($job.State -notin @("Completed", "Failed", "Stopped")) {
      Stop-Job -Job $job -ErrorAction SilentlyContinue
    }
    Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
  }
  if (Test-Path -LiteralPath $tempRoot) {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force
  }
}
