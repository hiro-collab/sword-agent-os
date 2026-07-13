$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$RepoRoot = Split-Path -Parent $PSScriptRoot
$ControllerPath = Join-Path $RepoRoot "scripts\run-self-output-awareness-live-controller.ps1"
$pwsh = Get-Command pwsh -ErrorAction Stop
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("self-output-live-controller-test-" + [guid]::NewGuid().ToString("N"))
$privateToken = "PRIVATE_LIVE_CONTROLLER_TOKEN_SENTINEL"
$privateResponseMarker = "PRIVATE_TRANSCRIPT_SENTINEL"
$assertions = 0
$jobs = [System.Collections.Generic.List[object]]::new()

function Assert-True {
  param([bool]$Condition, [string]$Message)
  $script:assertions += 1
  if (-not $Condition) {
    throw $Message
  }
}

function New-EndpointResponse {
  param(
    [string]$ResultClass,
    [string]$ExpectationClass,
    [int]$CapturePacketCount = 0,
    [int]$CaptureByteCount = 0,
    [string]$SignalClass = "signal_above_floor",
    [string]$VadDecisionClass = "speech_not_detected",
    [int]$TranscriptionCount = 0,
    [int]$SubmissionCount = 0,
    [int]$TurnInputCount = 0,
    [int]$ElapsedMs = 25,
    [int]$PcmCleanupCount = 0,
    [int]$PrivateAuthorityResidueCount = 0
  )

  return [ordered]@{
    schema_version = "ai_talk_core.live_input_gate_candidate_window.v0"
    result_class = $ResultClass
    expectation_class = $ExpectationClass
    capture_packet_count = $CapturePacketCount
    capture_byte_count = $CaptureByteCount
    signal_class = $SignalClass
    vad_decision_class = $VadDecisionClass
    transcription_count = $TranscriptionCount
    submission_count = $SubmissionCount
    thought_core_turninput_count = $TurnInputCount
    elapsed_ms = $ElapsedMs
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
      $client = $listener.AcceptTcpClient()
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
  }
}

function Complete-TestServer {
  param([Parameter(Mandatory = $true)]$Server)

  $completed = Wait-Job -Job $Server.Job -Timeout 5
  Assert-True ($null -ne $completed) "test server did not complete"
  $rows = @(Receive-Job -Job $Server.Job)
  Assert-True ($Server.Job.State -ceq "Completed") "test server failed"
  Assert-True ($rows.Count -eq 1) "test server should return one request summary"
  return $rows[0]
}

function Invoke-Controller {
  param(
    [string]$BaseUrl,
    [string]$Scenario = "self_output_or_ambiguous",
    [int]$WindowMs = 100,
    [int]$DeadlineMs = 1000,
    [bool]$ProvideToken = $true
  )

  $previousToken = [System.Environment]::GetEnvironmentVariable("AI_TALK_CORE_WEB_TOKEN", "Process")
  try {
    if ($ProvideToken) {
      [System.Environment]::SetEnvironmentVariable("AI_TALK_CORE_WEB_TOKEN", $privateToken, "Process")
    } else {
      [System.Environment]::SetEnvironmentVariable("AI_TALK_CORE_WEB_TOKEN", $null, "Process")
    }
    $output = @(
      & $pwsh.Source -NoProfile -File $ControllerPath `
        -BaseUrl $BaseUrl `
        -Scenario $Scenario `
        -WindowMs $WindowMs `
        -DeadlineMs $DeadlineMs `
        -Json 2>&1
    )
    return [PSCustomObject]@{
      Code = $LASTEXITCODE
      Text = ($output -join "`n")
    }
  } finally {
    [System.Environment]::SetEnvironmentVariable("AI_TALK_CORE_WEB_TOKEN", $previousToken, "Process")
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

[System.IO.Directory]::CreateDirectory($tempRoot) | Out-Null

try {
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
  Assert-True ($negativeRequest.deadline_ms -eq 1000) "negative request deadline mismatch"

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
  Assert-True ($positive.signal_class -ceq "signal_above_floor") "positive signal class mismatch"
  Assert-True ($positive.vad_decision_class -ceq "speech_detected") "positive VAD class mismatch"
  Assert-True ($positive.transcription_count -eq 1) "positive scenario should transcribe once"
  Assert-True ($positive.submission_count -eq 1) "positive scenario should submit once"
  Assert-True ($positive.thought_core_turninput_count -eq 1) "positive scenario should materialize one TurnInput"

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

  $fixedFailureResponse = New-EndpointResponse `
    -ResultClass "voice_capture_dsp_start_failed" `
    -ExpectationClass "not_evaluated" `
    -SignalClass "not_evaluated" `
    -VadDecisionClass "not_evaluated"
  $fixedFailureServer = Start-TestServer -Response $fixedFailureResponse -StatusCode 503
  $fixedFailureRun = Invoke-Controller -BaseUrl $fixedFailureServer.BaseUrl
  [void](Complete-TestServer -Server $fixedFailureServer)
  $fixedFailure = Assert-CommonResult -Run $fixedFailureRun
  Assert-True ($fixedFailureRun.Code -ne 0) "fixed child failure must block"
  Assert-True ($fixedFailure.blocker_class -ceq "voice_capture_dsp_start_failed") "fixed child failure class must survive"

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
  $timeoutServer = Start-TestServer -Response $timeoutResponse -DelayMs 1000
  $timeoutRun = Invoke-Controller -BaseUrl $timeoutServer.BaseUrl -WindowMs 100 -DeadlineMs 300
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
