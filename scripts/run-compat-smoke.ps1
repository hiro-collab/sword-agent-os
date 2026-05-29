param(
  [string]$Profile = "thought-core-v0",
  [int]$DurationSeconds = 90,
  [string]$StackStateDir = ".cache\home-control-stack-smoke",
  [int]$HomeAssistantBridgePort = 8787,
  [int]$EnvironmentStatePort = 8790,
  [int]$MediapipePort = 8765,
  [int]$MediapipeBrowserMonitorPort = 8770,
  [int]$VisionSnapshotProcessorPort = 8776,
  [int]$AituberPort = 3000,
  [int]$TouchDesignerGuiPort = 8788,
  [int]$ThoughtCorePort = 18787,
  [int]$MediapipeReadyTimeoutSeconds = 90,
  [ValidateSet("dshow", "testsrc")]
  [string]$MediapipeVideoSource = "dshow",
  [double]$WatcherAituberHttpTimeoutSeconds = 5.0,
  [int]$TimeoutMs = 10000,
  [switch]$RunManualTurn,
  [string]$ManualTurnText = "こんにちは。起動確認です。",
  [string]$ManualSessionId = "living_room_main",
  [string]$ManualTurnId = "",
  [int]$ManualTurnTimeoutSeconds = 90,
  [switch]$RunSafeIntegrationProbes,
  [string]$HomeControlDryRunActionId = "light_on",
  [switch]$RunWatcherProbe,
  [switch]$RequireWatcherAituberForward,
  [string]$WatcherProbeText = "こんにちは。watcher経路の起動確認です。",
  [int]$WatcherProbeTimeoutSeconds = 90,
  [switch]$UseIsolatedPorts,
  [switch]$RequireVoicevox
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$RepoRoot = Split-Path -Parent $PSScriptRoot
$SmokeRoot = Join-Path $RepoRoot ".cache\compat-smoke"
$SmokeBoundParameters = @{} + $PSBoundParameters

function Resolve-CurrentPowerShell {
  $currentProcess = Get-Process -Id $PID -ErrorAction SilentlyContinue
  if ($null -ne $currentProcess -and -not [string]::IsNullOrWhiteSpace($currentProcess.Path)) {
    return $currentProcess.Path
  }
  $pwsh = Get-Command "pwsh" -ErrorAction SilentlyContinue
  if ($null -ne $pwsh) {
    return $pwsh.Source
  }
  return (Get-Command "powershell" -ErrorAction Stop).Source
}

function Resolve-RepoPath {
  param([Parameter(Mandatory = $true)][string]$Path)
  if ([System.IO.Path]::IsPathRooted($Path)) {
    return $Path
  }
  return Join-Path $RepoRoot ($Path -replace "/", [System.IO.Path]::DirectorySeparatorChar)
}

function New-Check {
  param(
    [Parameter(Mandatory = $true)][string]$Id,
    [Parameter(Mandatory = $true)][string]$Status,
    [Parameter(Mandatory = $true)][string]$Detail,
    [string]$Target = ""
  )
  return [PSCustomObject]@{
    id = $Id
    status = $Status
    target = $Target
    detail = $Detail
  }
}

function Test-HttpEndpoint {
  param(
    [Parameter(Mandatory = $true)][string]$Id,
    [Parameter(Mandatory = $true)][string]$Url
  )

  try {
    $timeoutSeconds = [Math]::Max(1, [int][Math]::Ceiling($TimeoutMs / 1000))
    $response = Invoke-WebRequest -Uri $Url -Method Get -TimeoutSec $timeoutSeconds -UseBasicParsing
    $ok = $response.StatusCode -ge 200 -and $response.StatusCode -lt 500
    return New-Check -Id $Id -Status $(if ($ok) { "ok" } else { "down" }) -Target $Url -Detail "http $($response.StatusCode)"
  }
  catch {
    $responseProperty = $_.Exception.PSObject.Properties["Response"]
    $response = if ($null -ne $responseProperty) { $responseProperty.Value } else { $null }
    if ($null -ne $response -and $null -ne $response.StatusCode) {
      return New-Check -Id $Id -Status "down" -Target $Url -Detail "http $([int]$response.StatusCode)"
    }
    return New-Check -Id $Id -Status "down" -Target $Url -Detail $_.Exception.Message
  }
}

function Test-TcpEndpoint {
  param(
    [Parameter(Mandatory = $true)][string]$Id,
    [Parameter(Mandatory = $true)][string]$HostName,
    [Parameter(Mandatory = $true)][int]$Port
  )

  $client = [System.Net.Sockets.TcpClient]::new()
  try {
    $task = $client.ConnectAsync($HostName, $Port)
    if (-not $task.Wait($TimeoutMs)) {
      return New-Check -Id $Id -Status "down" -Target "$HostName`:$Port" -Detail "timeout"
    }
    if ($client.Connected) {
      return New-Check -Id $Id -Status "ok" -Target "$HostName`:$Port" -Detail "tcp"
    }
    return New-Check -Id $Id -Status "down" -Target "$HostName`:$Port" -Detail "not connected"
  }
  catch {
    return New-Check -Id $Id -Status "down" -Target "$HostName`:$Port" -Detail $_.Exception.Message
  }
  finally {
    $client.Dispose()
  }
}

function Test-PortListening {
  param([Parameter(Mandatory = $true)][int]$Port)
  $listeners = @(Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue)
  return $listeners.Count -gt 0
}

function Read-DotEnvValue {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$Name
  )
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    return ""
  }
  foreach ($line in Get-Content -LiteralPath $Path) {
    if ($line -match "^\s*$([regex]::Escape($Name))\s*=\s*(.*)\s*$") {
      $value = $Matches[1].Trim()
      if (($value.StartsWith('"') -and $value.EndsWith('"')) -or ($value.StartsWith("'") -and $value.EndsWith("'"))) {
        $value = $value.Substring(1, $value.Length - 2)
      }
      return $value
    }
  }
  return ""
}

function New-ProbeResult {
  param(
    [Parameter(Mandatory = $true)][string]$Id,
    [Parameter(Mandatory = $true)][string]$Status,
    [Parameter(Mandatory = $true)][string]$Detail,
    [int]$StatusCode = 0
  )
  return [PSCustomObject]@{
    id = $Id
    status = $Status
    status_code = $StatusCode
    detail = $Detail
  }
}

function Invoke-JsonProbe {
  param(
    [Parameter(Mandatory = $true)][string]$Id,
    [Parameter(Mandatory = $true)][string]$Method,
    [Parameter(Mandatory = $true)][string]$Url,
    [hashtable]$Headers = @{},
    [object]$Body = $null,
    [scriptblock]$Validate = $null
  )

  try {
    $request = @{
      Uri = $Url
      Method = $Method
      TimeoutSec = [Math]::Max(1, [int][Math]::Ceiling($TimeoutMs / 1000))
      UseBasicParsing = $true
      Headers = $Headers
    }
    if ($null -ne $Body) {
      $request.ContentType = "application/json"
      $request.Body = ($Body | ConvertTo-Json -Depth 8)
    }
    $response = Invoke-WebRequest @request
    $payload = $null
    if (-not [string]::IsNullOrWhiteSpace($response.Content)) {
      try {
        $payload = $response.Content | ConvertFrom-Json
      }
      catch {
        return New-ProbeResult -Id $Id -Status "failed" -StatusCode ([int]$response.StatusCode) -Detail "response was not JSON"
      }
    }
    if ($null -ne $Validate) {
      $validation = & $Validate $payload
      if ($validation -is [string] -and -not [string]::IsNullOrWhiteSpace($validation)) {
        return New-ProbeResult -Id $Id -Status "failed" -StatusCode ([int]$response.StatusCode) -Detail $validation
      }
    }
    return New-ProbeResult -Id $Id -Status "ok" -StatusCode ([int]$response.StatusCode) -Detail "http $($response.StatusCode)"
  }
  catch {
    $responseProperty = $_.Exception.PSObject.Properties["Response"]
    $response = if ($null -ne $responseProperty) { $responseProperty.Value } else { $null }
    if ($null -ne $response -and $null -ne $response.StatusCode) {
      return New-ProbeResult -Id $Id -Status "failed" -StatusCode ([int]$response.StatusCode) -Detail "http $([int]$response.StatusCode)"
    }
    return New-ProbeResult -Id $Id -Status "failed" -Detail $_.Exception.Message
  }
}

function Add-Argument {
  param(
    [Parameter(Mandatory = $true)][System.Collections.Generic.List[string]]$Arguments,
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][string]$Value
  )
  $Arguments.Add($Name)
  $Arguments.Add($Value)
}

function Add-PortArguments {
  param([Parameter(Mandatory = $true)][System.Collections.Generic.List[string]]$Arguments)
  Add-Argument -Arguments $Arguments -Name "-HomeAssistantBridgePort" -Value ([string]$HomeAssistantBridgePort)
  Add-Argument -Arguments $Arguments -Name "-EnvironmentStatePort" -Value ([string]$EnvironmentStatePort)
  Add-Argument -Arguments $Arguments -Name "-MediapipePort" -Value ([string]$MediapipePort)
  Add-Argument -Arguments $Arguments -Name "-MediapipeBrowserMonitorPort" -Value ([string]$MediapipeBrowserMonitorPort)
  Add-Argument -Arguments $Arguments -Name "-VisionSnapshotProcessorPort" -Value ([string]$VisionSnapshotProcessorPort)
  Add-Argument -Arguments $Arguments -Name "-AituberPort" -Value ([string]$AituberPort)
  Add-Argument -Arguments $Arguments -Name "-TouchDesignerGuiPort" -Value ([string]$TouchDesignerGuiPort)
  Add-Argument -Arguments $Arguments -Name "-ThoughtCorePort" -Value ([string]$ThoughtCorePort)
  Add-Argument -Arguments $Arguments -Name "-MediapipeReadyTimeoutSeconds" -Value ([string]$MediapipeReadyTimeoutSeconds)
  Add-Argument -Arguments $Arguments -Name "-MediapipeVideoSource" -Value $MediapipeVideoSource
  Add-Argument -Arguments $Arguments -Name "-ThoughtCoreWatchAituberHttpTimeout" -Value ([string]$WatcherAituberHttpTimeoutSeconds)
}

function Resolve-ToolPath {
  param([Parameter(Mandatory = $true)][string]$Name)
  $command = Get-Command $Name -ErrorAction SilentlyContinue
  if ($null -eq $command -and $Name -eq "uv") {
    $command = Get-Command "uv.exe" -ErrorAction SilentlyContinue
  }
  if ($null -eq $command) {
    throw "tool not found on PATH: $Name"
  }
  return [string]$command.Source
}

function ConvertTo-PowerShellSingleQuotedString {
  param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value)
  return "'{0}'" -f ($Value -replace "'", "''")
}

function Write-Utf8JsonFile {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][object]$Value
  )
  $parent = Split-Path -Parent $Path
  if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
  }
  $json = $Value | ConvertTo-Json -Depth 8
  $encoding = [System.Text.UTF8Encoding]::new($false)
  [System.IO.File]::WriteAllText($Path, $json, $encoding)
}

function Write-Utf8TextFile {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$Value
  )
  $parent = Split-Path -Parent $Path
  if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
  }
  $encoding = [System.Text.UTF8Encoding]::new($false)
  [System.IO.File]::WriteAllText($Path, $Value, $encoding)
}

function Get-ObjectProperty {
  param(
    [object]$Object,
    [Parameter(Mandatory = $true)][string]$Name
  )
  if ($null -eq $Object) {
    return $null
  }
  $property = $Object.PSObject.Properties[$Name]
  if ($null -eq $property) {
    return $null
  }
  return $property.Value
}

function Get-WatcherProbeObservation {
  param(
    [Parameter(Mandatory = $true)][string]$EventsPath,
    [Parameter(Mandatory = $true)][string]$TurnId
  )

  $completed = $false
  $forwardError = ""
  $eventCount = 0
  if (Test-Path -LiteralPath $EventsPath -PathType Leaf) {
    foreach ($line in (Get-Content -LiteralPath $EventsPath -Tail 300 -ErrorAction SilentlyContinue)) {
      if ([string]::IsNullOrWhiteSpace($line)) {
        continue
      }
      try {
        $event = $line | ConvertFrom-Json
      }
      catch {
        continue
      }
      if ([string](Get-ObjectProperty -Object $event -Name "turn_id") -ne $TurnId) {
        continue
      }
      $eventCount += 1
      $type = [string](Get-ObjectProperty -Object $event -Name "type")
      $payload = Get-ObjectProperty -Object $event -Name "payload"
      $eventType = [string](Get-ObjectProperty -Object $payload -Name "event_type")
      if ($type -eq "thought_core.completed" -or $type -eq "thought_core.response" -or ($type -eq "thought_core.stream_event" -and $eventType -eq "turn.completed")) {
        $completed = $true
      }
      if ($type -eq "aituber.forward_error" -and [string]::IsNullOrWhiteSpace($forwardError)) {
        $forwardError = [string](Get-ObjectProperty -Object $payload -Name "error")
      }
    }
  }

  return [PSCustomObject]@{
    thought_core_completed = $completed
    aituber_forward_error = $forwardError
    event_count = $eventCount
  }
}

function Set-IsolatedPortIfUnbound {
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][int]$Value
  )
  if (-not $SmokeBoundParameters.ContainsKey($Name)) {
    Set-Variable -Scope Script -Name $Name -Value $Value
  }
}

if ($UseIsolatedPorts) {
  Set-IsolatedPortIfUnbound -Name "HomeAssistantBridgePort" -Value 18887
  Set-IsolatedPortIfUnbound -Name "EnvironmentStatePort" -Value 18890
  Set-IsolatedPortIfUnbound -Name "MediapipePort" -Value 18865
  Set-IsolatedPortIfUnbound -Name "MediapipeBrowserMonitorPort" -Value 18870
  Set-IsolatedPortIfUnbound -Name "VisionSnapshotProcessorPort" -Value 18876
  Set-IsolatedPortIfUnbound -Name "AituberPort" -Value 18880
  Set-IsolatedPortIfUnbound -Name "TouchDesignerGuiPort" -Value 18889
  Set-IsolatedPortIfUnbound -Name "ThoughtCorePort" -Value 18888
}

if (-not (Test-Path -LiteralPath $SmokeRoot -PathType Container)) {
  New-Item -ItemType Directory -Force -Path $SmokeRoot | Out-Null
}

$readinessParams = @{
  HomeAssistantBridgePort = $HomeAssistantBridgePort
  EnvironmentStatePort = $EnvironmentStatePort
  MediapipePort = $MediapipePort
  MediapipeBrowserMonitorPort = $MediapipeBrowserMonitorPort
  VisionSnapshotProcessorPort = $VisionSnapshotProcessorPort
  AituberPort = $AituberPort
  TouchDesignerGuiPort = $TouchDesignerGuiPort
  ThoughtCorePort = $ThoughtCorePort
}
if ($RequireVoicevox) {
  $readinessParams.CheckEndpoints = $true
}
$readinessOutput = & (Join-Path $PSScriptRoot "check-launch-readiness.ps1") @readinessParams
$readiness = ($readinessOutput | Out-String | ConvertFrom-Json)
if ([string]$readiness.status -eq "blocked") {
  $blockedResult = [PSCustomObject]@{
    status = "blocked"
    checked_at = (Get-Date).ToString("o")
    readiness = $readiness
  } | ConvertTo-Json -Depth 8
  Write-Output $blockedResult
  exit 1
}

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$startStdout = Join-Path $SmokeRoot "start-$timestamp.out.log"
$startStderr = Join-Path $SmokeRoot "start-$timestamp.err.log"
$stopStdout = Join-Path $SmokeRoot "stop-$timestamp.out.log"
$stopStderr = Join-Path $SmokeRoot "stop-$timestamp.err.log"

$powerShell = Resolve-CurrentPowerShell
$startProcess = $null
$stopExitCode = $null
$stopError = ""
$smokeError = ""
$checks = @()
$integrationProbes = @()
$organReadiness = $null
$watcherProbe = [PSCustomObject]@{
  enabled = [bool]$RunWatcherProbe
  status = if ($RunWatcherProbe) { "pending" } else { "skipped" }
  detail = ""
  turn_id = ""
  thought_core_completed = $false
  aituber_forward_observed = $false
  aituber_forward_error = ""
  require_aituber_forward = [bool]$RequireWatcherAituberForward
  events_path = (Resolve-RepoPath -Path (Join-Path $StackStateDir "thought-core-watcher\events.jsonl"))
  handoff_json = ""
  aituber_client_id = "thought-core"
}
$watcherRestoreError = ""
$watcherBackup = [PSCustomObject]@{
  json_path = ""
  text_path = ""
  json_backup = ""
  text_backup = ""
  json_existed = $false
  text_existed = $false
}
$manualTurn = [PSCustomObject]@{
  enabled = [bool]$RunManualTurn
  status = if ($RunManualTurn) { "pending" } else { "skipped" }
  exit_code = $null
  timed_out = $false
  turn_id = ""
  stdout = ""
  stderr = ""
  status_dir = ""
}

try {
  $startArguments = [System.Collections.Generic.List[string]]::new()
  foreach ($argument in @("-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", (Join-Path $PSScriptRoot "system.ps1"), "start", "-Profile", $Profile, "-LegacyDelegate", "-StackStateDir", $StackStateDir)) {
    $startArguments.Add([string]$argument)
  }
  if (-not $RequireVoicevox) {
    $startArguments.Add("-SkipVoicevoxCheck")
  }
  Add-PortArguments -Arguments $startArguments

  $startProcess = Start-Process `
    -FilePath $powerShell `
    -ArgumentList ([string[]]$startArguments.ToArray()) `
    -WorkingDirectory $RepoRoot `
    -PassThru `
    -WindowStyle Hidden `
    -RedirectStandardOutput $startStdout `
    -RedirectStandardError $startStderr

  Start-Sleep -Seconds ([Math]::Max(1, $DurationSeconds))

  $checks += Test-HttpEndpoint -Id "home_assistant_bridge" -Url "http://127.0.0.1:$HomeAssistantBridgePort/health"
  $checks += Test-HttpEndpoint -Id "environment_state_server" -Url "http://127.0.0.1:$EnvironmentStatePort/health"
  $checks += Test-HttpEndpoint -Id "thought_core_api" -Url "http://127.0.0.1:$ThoughtCorePort/health"
  $checks += Test-TcpEndpoint -Id "mediapipe_camera_hub_stack" -HostName "127.0.0.1" -Port $MediapipePort
  $checks += Test-TcpEndpoint -Id "vision_snapshot_processor" -HostName "127.0.0.1" -Port $VisionSnapshotProcessorPort
  $checks += Test-HttpEndpoint -Id "aituber_kit" -Url "http://127.0.0.1:$AituberPort"
  $checks += Test-HttpEndpoint -Id "touchdesigner_control_gui" -Url "http://127.0.0.1:$TouchDesignerGuiPort"
  if ($RequireVoicevox) {
    $checks += Test-HttpEndpoint -Id "voicevox" -Url "http://127.0.0.1:50021/version"
  }

  if ($RunManualTurn) {
    $turnId = if ([string]::IsNullOrWhiteSpace($ManualTurnId)) {
      "turn_smoke_{0}" -f (Get-Date -Format "yyyyMMdd_HHmmss")
    }
    else {
      $ManualTurnId
    }
    $turnStdout = Join-Path $SmokeRoot "turn-$timestamp.out.log"
    $turnStderr = Join-Path $SmokeRoot "turn-$timestamp.err.log"
    $turnStatusDir = Resolve-RepoPath (Join-Path $StackStateDir "manual-turn-status")
    $controlPlaneRoot = Resolve-RepoPath "control-plane\sword-voice-agent"
    $uv = Resolve-ToolPath -Name "uv"
    $turnScript = @"
`$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new(`$false)
`$OutputEncoding = [System.Text.UTF8Encoding]::new(`$false)
`$env:PYTHONUTF8 = "1"
`$env:PYTHONIOENCODING = "utf-8"
`$env:THOUGHT_CORE_BASE_URL = "http://127.0.0.1:$ThoughtCorePort"
Set-Location -LiteralPath $(ConvertTo-PowerShellSingleQuotedString -Value $controlPlaneRoot)
& $(ConvertTo-PowerShellSingleQuotedString -Value $uv) run sword-thought-core-handoff --text $(ConvertTo-PowerShellSingleQuotedString -Value $ManualTurnText) --session-id $(ConvertTo-PowerShellSingleQuotedString -Value $ManualSessionId) --turn-id $(ConvertTo-PowerShellSingleQuotedString -Value $turnId) --status-dir $(ConvertTo-PowerShellSingleQuotedString -Value $turnStatusDir) --print-events
exit `$LASTEXITCODE
"@
    $encodedTurnScript = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($turnScript))
    $turnProcess = Start-Process `
      -FilePath $powerShell `
      -ArgumentList @("-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass", "-EncodedCommand", $encodedTurnScript) `
      -WorkingDirectory $controlPlaneRoot `
      -PassThru `
      -WindowStyle Hidden `
      -RedirectStandardOutput $turnStdout `
      -RedirectStandardError $turnStderr
    $timedOut = -not $turnProcess.WaitForExit([Math]::Max(1, $ManualTurnTimeoutSeconds) * 1000)
    if ($timedOut) {
      Stop-Process -Id $turnProcess.Id -Force -ErrorAction SilentlyContinue
    }
    $manualTurn = [PSCustomObject]@{
      enabled = $true
      status = if ((-not $timedOut) -and $turnProcess.ExitCode -eq 0) { "ok" } else { "failed" }
      exit_code = if ($timedOut) { $null } else { $turnProcess.ExitCode }
      timed_out = $timedOut
      turn_id = $turnId
      stdout = $turnStdout
      stderr = $turnStderr
      status_dir = $turnStatusDir
    }
  }

  if ($RunSafeIntegrationProbes) {
    $homeAssistantEnvPath = Resolve-RepoPath "organs\action\home-assistant-server\.env"
    $homeControlToken = Read-DotEnvValue -Path $homeAssistantEnvPath -Name "HOME_CONTROL_API_TOKEN"
    $environmentToken = Read-DotEnvValue -Path $homeAssistantEnvPath -Name "ENVIRONMENT_API_TOKEN"
    if ([string]::IsNullOrWhiteSpace($environmentToken)) {
      $environmentToken = $homeControlToken
    }

    if ([string]::IsNullOrWhiteSpace($environmentToken)) {
      $integrationProbes += New-ProbeResult -Id "environment_current" -Status "failed" -Detail "environment token missing"
    }
    else {
      $integrationProbes += Invoke-JsonProbe `
        -Id "environment_current" `
        -Method "GET" `
        -Url "http://127.0.0.1:$EnvironmentStatePort/environment/current" `
        -Headers @{ Authorization = "Bearer $environmentToken" } `
        -Validate {
          param($Payload)
          if ($null -eq $Payload) { return "empty response" }
          if (-not $Payload.PSObject.Properties["snapshot_id"]) { return "missing snapshot_id" }
          return ""
        }
    }

    $clientId = "sword-smoke"
    $messageUrl = "http://127.0.0.1:$AituberPort/api/messages/?clientId=$clientId&type=direct_send"
    $integrationProbes += Invoke-JsonProbe `
      -Id "aituber_direct_send_post" `
      -Method "POST" `
      -Url $messageUrl `
      -Body @{ messages = @("Agent OS smoke direct_send probe") } `
      -Validate {
        param($Payload)
        if ($null -eq $Payload) { return "empty response" }
        if ([string]$Payload.message -ne "Successfully sent") { return "unexpected response" }
        return ""
      }
    $integrationProbes += Invoke-JsonProbe `
      -Id "aituber_direct_send_get" `
      -Method "GET" `
      -Url $messageUrl `
      -Validate {
        param($Payload)
        if ($null -eq $Payload -or $null -eq $Payload.messages) { return "missing messages" }
        if (@($Payload.messages).Count -lt 1) { return "message queue empty" }
        return ""
      }

    if ([string]::IsNullOrWhiteSpace($homeControlToken)) {
      $integrationProbes += New-ProbeResult -Id "home_control_dry_run" -Status "failed" -Detail "home control token missing"
    }
    else {
      $integrationProbes += Invoke-JsonProbe `
        -Id "home_control_dry_run" `
        -Method "POST" `
        -Url "http://127.0.0.1:$HomeAssistantBridgePort/actions/$HomeControlDryRunActionId/execute" `
        -Headers @{ Authorization = "Bearer $homeControlToken" } `
        -Body @{
          source = "agent_os_smoke"
          request_id = "smoke-$timestamp"
          user_text = "Agent OS dry-run probe"
          dry_run = $true
        } `
        -Validate {
          param($Payload)
          if ($null -eq $Payload) { return "empty response" }
          if ([string]$Payload.status -ne "dry_run") { return "expected dry_run status" }
          return ""
        }
    }
  }

  if ($RunWatcherProbe) {
    $watcherTurnId = "turn_watcher_smoke_{0}" -f (Get-Date -Format "yyyyMMdd_HHmmss")
    $handoffDir = Resolve-RepoPath "organs\voice\ai-talk-core\.cache\codex"
    $handoffJson = Join-Path $handoffDir "web_latest.json"
    $handoffText = Join-Path $handoffDir "web_latest.txt"
    $watcherBackup = [PSCustomObject]@{
      json_path = $handoffJson
      text_path = $handoffText
      json_backup = Join-Path $SmokeRoot "web_latest-$timestamp.json.bak"
      text_backup = Join-Path $SmokeRoot "web_latest-$timestamp.txt.bak"
      json_existed = Test-Path -LiteralPath $handoffJson -PathType Leaf
      text_existed = Test-Path -LiteralPath $handoffText -PathType Leaf
    }
    if ($watcherBackup.json_existed) {
      Copy-Item -LiteralPath $handoffJson -Destination $watcherBackup.json_backup -Force
    }
    if ($watcherBackup.text_existed) {
      Copy-Item -LiteralPath $handoffText -Destination $watcherBackup.text_backup -Force
    }

    Write-Utf8JsonFile -Path $handoffJson -Value @{
      transcript = $WatcherProbeText
      command = $WatcherProbeText
      turn_id = $watcherTurnId
    }
    Write-Utf8TextFile -Path $handoffText -Value "Voice transcript:`n$WatcherProbeText`n"

    $clientId = "thought-core"
    $queueUrl = "http://127.0.0.1:$AituberPort/api/messages/?clientId=$clientId&type=direct_send"
    $eventsPath = Resolve-RepoPath (Join-Path $StackStateDir "thought-core-watcher\events.jsonl")
    $watcherPollSeconds = 2
    $watcherAttempts = [Math]::Max(1, [int][Math]::Ceiling([Math]::Max(1, $WatcherProbeTimeoutSeconds) / $watcherPollSeconds))
    $watcherRequestTimeoutSeconds = [Math]::Min(3, [Math]::Max(1, [int][Math]::Ceiling($TimeoutMs / 1000)))
    $probeStatus = "failed"
    $probeDetail = "timed out waiting for watcher Thought Core completion"
    $thoughtCoreCompleted = $false
    $aituberForwardObserved = $false
    $aituberForwardError = ""
    $watcherEventCount = 0
    for ($watcherAttempt = 0; $watcherAttempt -lt $watcherAttempts; $watcherAttempt += 1) {
      Start-Sleep -Seconds $watcherPollSeconds
      $observation = Get-WatcherProbeObservation -EventsPath $eventsPath -TurnId $watcherTurnId
      $thoughtCoreCompleted = [bool]$observation.thought_core_completed
      $watcherEventCount = [int]$observation.event_count
      if (-not [string]::IsNullOrWhiteSpace([string]$observation.aituber_forward_error)) {
        $aituberForwardError = [string]$observation.aituber_forward_error
      }
      try {
        $response = Invoke-WebRequest -Uri $queueUrl -Method GET -TimeoutSec $watcherRequestTimeoutSeconds -UseBasicParsing
        $payload = $response.Content | ConvertFrom-Json
        if ($null -ne $payload -and $null -ne $payload.messages -and @($payload.messages).Count -gt 0) {
          $aituberForwardObserved = $true
        }
      }
      catch {
        if (-not $thoughtCoreCompleted) {
          $probeDetail = $_.Exception.Message
        }
      }

      if ($thoughtCoreCompleted -and (-not $RequireWatcherAituberForward -or $aituberForwardObserved)) {
        $probeStatus = "ok"
        if ($RequireWatcherAituberForward) {
          $probeDetail = "watcher completed Thought Core turn and AITuber forward was observed"
        }
        elseif ($aituberForwardObserved) {
          $probeDetail = "watcher completed Thought Core turn and AITuber forward was observed"
        }
        elseif (-not [string]::IsNullOrWhiteSpace($aituberForwardError)) {
          $probeDetail = "watcher completed Thought Core turn; AITuber forward strict check disabled; forward_error observed: $aituberForwardError"
        }
        else {
          $probeDetail = "watcher completed Thought Core turn; AITuber forward strict check disabled"
        }
        break
      }
    }

    if ($probeStatus -ne "ok") {
      if ($thoughtCoreCompleted -and $RequireWatcherAituberForward -and -not $aituberForwardObserved) {
        if (-not [string]::IsNullOrWhiteSpace($aituberForwardError)) {
          $probeDetail = "watcher completed Thought Core turn but AITuber forward was not observed; forward_error: $aituberForwardError"
        }
        else {
          $probeDetail = "watcher completed Thought Core turn but AITuber forward was not observed"
        }
      }
      elseif ($watcherEventCount -gt 0) {
        $probeDetail = "watcher events observed but Thought Core completion was not observed"
      }
    }

    $watcherProbe = [PSCustomObject]@{
      enabled = $true
      status = $probeStatus
      detail = $probeDetail
      turn_id = $watcherTurnId
      thought_core_completed = $thoughtCoreCompleted
      aituber_forward_observed = $aituberForwardObserved
      aituber_forward_error = $aituberForwardError
      require_aituber_forward = [bool]$RequireWatcherAituberForward
      watcher_event_count = $watcherEventCount
      events_path = $eventsPath
      handoff_json = $handoffJson
      aituber_client_id = $clientId
    }
  }

  $organReadinessParams = @{
    CheckEndpoints = $true
    TimeoutMs = $TimeoutMs
  }
  if ($UseIsolatedPorts) {
    $organReadinessParams.UseIsolatedPorts = $true
  }
  $organReadinessOutput = & (Join-Path $PSScriptRoot "check-organ-readiness.ps1") @organReadinessParams
  $organReadiness = ($organReadinessOutput | Out-String | ConvertFrom-Json)
}
catch {
  $smokeError = $_.Exception.Message
}
finally {
  try {
    $stopArguments = [System.Collections.Generic.List[string]]::new()
    foreach ($argument in @("-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", (Join-Path $PSScriptRoot "system.ps1"), "stop", "-Profile", $Profile, "-LegacyDelegate", "-Force", "-StackStateDir", $StackStateDir)) {
      $stopArguments.Add([string]$argument)
    }
    Add-PortArguments -Arguments $stopArguments

    $stopProcess = Start-Process `
      -FilePath $powerShell `
      -ArgumentList ([string[]]$stopArguments.ToArray()) `
      -WorkingDirectory $RepoRoot `
      -PassThru `
      -WindowStyle Hidden `
      -RedirectStandardOutput $stopStdout `
      -RedirectStandardError $stopStderr
    $stopProcess.WaitForExit()
    $stopExitCode = $stopProcess.ExitCode
  }
  catch {
    $stopError = $_.Exception.Message
  }

  if ($null -ne $startProcess -and -not $startProcess.HasExited) {
    $startProcess.WaitForExit(5000) | Out-Null
    if (-not $startProcess.HasExited) {
      Stop-Process -Id $startProcess.Id -Force -ErrorAction SilentlyContinue
    }
  }

  if ($RunWatcherProbe -and -not [string]::IsNullOrWhiteSpace($watcherBackup.json_path)) {
    try {
      if ($watcherBackup.json_existed) {
        Copy-Item -LiteralPath $watcherBackup.json_backup -Destination $watcherBackup.json_path -Force
      }
      elseif (Test-Path -LiteralPath $watcherBackup.json_path -PathType Leaf) {
        Remove-Item -LiteralPath $watcherBackup.json_path -Force
      }
      if ($watcherBackup.text_existed) {
        Copy-Item -LiteralPath $watcherBackup.text_backup -Destination $watcherBackup.text_path -Force
      }
      elseif (Test-Path -LiteralPath $watcherBackup.text_path -PathType Leaf) {
        Remove-Item -LiteralPath $watcherBackup.text_path -Force
      }
    }
    catch {
      $watcherRestoreError = $_.Exception.Message
    }
  }
}

$ports = @(
  $HomeAssistantBridgePort,
  $EnvironmentStatePort,
  $MediapipePort,
  $MediapipeBrowserMonitorPort,
  $VisionSnapshotProcessorPort,
  $AituberPort,
  $TouchDesignerGuiPort,
  $ThoughtCorePort
)
$remainingPorts = @($ports | Where-Object { Test-PortListening -Port $_ })
$failedChecks = @($checks | Where-Object { $_.status -ne "ok" })
$failedIntegrationProbes = @($integrationProbes | Where-Object { $_.status -ne "ok" })
$organReadinessBlocked = $false
if ($null -ne $organReadiness -and $null -ne $organReadiness.counts) {
  $organReadinessBlocked = [int]$organReadiness.counts.blocked -gt 0
}
$startExitCode = if ($null -ne $startProcess -and $startProcess.HasExited) { $startProcess.ExitCode } else { $null }
$status = if (
  [string]::IsNullOrWhiteSpace($smokeError) -and
  [string]::IsNullOrWhiteSpace($stopError) -and
  $failedChecks.Count -eq 0 -and
  $failedIntegrationProbes.Count -eq 0 -and
  (-not $organReadinessBlocked) -and
  ((-not $RunManualTurn) -or $manualTurn.status -eq "ok") -and
  ((-not $RunWatcherProbe) -or ($watcherProbe.status -eq "ok" -and [string]::IsNullOrWhiteSpace($watcherRestoreError))) -and
  $remainingPorts.Count -eq 0
) { "ok" } else { "failed" }

$result = [PSCustomObject]@{
  status = $status
  checked_at = (Get-Date).ToString("o")
  profile = $Profile
  duration_seconds = $DurationSeconds
  stack_state_dir = Resolve-RepoPath $StackStateDir
  port_mode = if ($UseIsolatedPorts) { "isolated_override" } else { "legacy_default" }
  mediapipe_ready_timeout_seconds = $MediapipeReadyTimeoutSeconds
  mediapipe_video_source = $MediapipeVideoSource
  watcher_aituber_http_timeout_seconds = $WatcherAituberHttpTimeoutSeconds
  errors = [PSCustomObject]@{
    smoke = $smokeError
    stop = $stopError
    watcher_restore = $watcherRestoreError
  }
  ports = [PSCustomObject]@{
    home_assistant_bridge = $HomeAssistantBridgePort
    environment_state_server = $EnvironmentStatePort
    mediapipe_camera_hub_stack = $MediapipePort
    mediapipe_browser_monitor = $MediapipeBrowserMonitorPort
    vision_snapshot_processor = $VisionSnapshotProcessorPort
    aituber_kit = $AituberPort
    touchdesigner_control_gui = $TouchDesignerGuiPort
    thought_core_api = $ThoughtCorePort
  }
  readiness_status = [string]$readiness.status
  checks = @($checks)
  integration_probes = @($integrationProbes)
  organ_readiness = $organReadiness
  manual_turn = $manualTurn
  watcher_probe = $watcherProbe
  remaining_ports = @($remainingPorts)
  processes = [PSCustomObject]@{
    start_pid = if ($null -ne $startProcess) { $startProcess.Id } else { $null }
    start_exit_code = $startExitCode
    stop_exit_code = $stopExitCode
  }
  logs = [PSCustomObject]@{
    start_stdout = $startStdout
    start_stderr = $startStderr
    stop_stdout = $stopStdout
    stop_stderr = $stopStderr
    turn_stdout = $manualTurn.stdout
    turn_stderr = $manualTurn.stderr
  }
}

Write-Output ($result | ConvertTo-Json -Depth 8)
if ($status -ne "ok") {
  exit 1
}
