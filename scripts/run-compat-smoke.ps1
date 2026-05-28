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
  [int]$TimeoutMs = 10000,
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
$startExitCode = if ($null -ne $startProcess -and $startProcess.HasExited) { $startProcess.ExitCode } else { $null }
$status = if (
  [string]::IsNullOrWhiteSpace($smokeError) -and
  [string]::IsNullOrWhiteSpace($stopError) -and
  $failedChecks.Count -eq 0 -and
  $remainingPorts.Count -eq 0
) { "ok" } else { "failed" }

$result = [PSCustomObject]@{
  status = $status
  checked_at = (Get-Date).ToString("o")
  profile = $Profile
  duration_seconds = $DurationSeconds
  stack_state_dir = Resolve-RepoPath $StackStateDir
  port_mode = if ($UseIsolatedPorts) { "isolated_override" } else { "legacy_default" }
  errors = [PSCustomObject]@{
    smoke = $smokeError
    stop = $stopError
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
  }
}

Write-Output ($result | ConvertTo-Json -Depth 8)
if ($status -ne "ok") {
  exit 1
}
