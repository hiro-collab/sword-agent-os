param(
  [string]$HostName = "127.0.0.1",
  [int]$Port = 8787,
  [string]$EnvPath = "",
  [string]$ConfigPath = "",
  [string]$HomeAssistantServerRoot = "",
  [string]$PythonCommand = "",
  [int]$CameraIndex = 0,
  [ValidateSet("auto", "dshow", "msmf")]
  [string]$CameraBackend = "dshow",
  [int]$BrightnessFrames = 24,
  [int]$BrightnessWarmup = 12,
  [int]$WaitSeconds = 4,
  [double]$MinDelta = 5.0,
  [string]$OffActionId = "light_off",
  [string]$OnActionId = "light_on",
  [switch]$UseExistingBridge,
  [switch]$ConfirmLiveLightTicket,
  [switch]$DryRun,
  [switch]$Json
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$RepoRoot = Split-Path -Parent $PSScriptRoot
$MeasureScript = Join-Path $PSScriptRoot "measure-camera-brightness.py"

function Resolve-RepoRelativePath {
  param(
    [string]$Value,
    [string]$DefaultRelativePath
  )

  if ([string]::IsNullOrWhiteSpace($Value)) {
    return [System.IO.Path]::GetFullPath((Join-Path $RepoRoot $DefaultRelativePath))
  }
  if ([System.IO.Path]::IsPathRooted($Value)) {
    return [System.IO.Path]::GetFullPath($Value)
  }
  return [System.IO.Path]::GetFullPath((Join-Path $RepoRoot $Value))
}

function Resolve-CurrentPowerShell {
  $currentProcess = Get-Process -Id $PID -ErrorAction SilentlyContinue
  if ($null -ne $currentProcess -and -not [string]::IsNullOrWhiteSpace($currentProcess.Path)) {
    return $currentProcess.Path
  }
  $pwsh = Get-Command pwsh -ErrorAction SilentlyContinue
  if ($null -ne $pwsh) {
    return $pwsh.Source
  }
  return (Get-Command powershell -ErrorAction Stop).Source
}

function Resolve-PythonCommand {
  if (-not [string]::IsNullOrWhiteSpace($PythonCommand)) {
    return $PythonCommand
  }

  $candidates = @(
    "organs\environment\vision-snapshot-processor\.venv\Scripts\python.exe",
    "organs\reflex\mediapipe-sword-sign\.venv\Scripts\python.exe"
  )
  foreach ($candidate in $candidates) {
    $path = Join-Path $RepoRoot $candidate
    if (Test-Path -LiteralPath $path -PathType Leaf) {
      return [System.IO.Path]::GetFullPath($path)
    }
  }

  throw "No project Python with OpenCV found. Install the standard distribution or pass -PythonCommand explicitly."
}

function ConvertTo-DisplayPath {
  param([string]$Path)

  if ([string]::IsNullOrWhiteSpace($Path)) {
    return "<none>"
  }
  $full = [System.IO.Path]::GetFullPath($Path)
  return $full.Replace($RepoRoot, "<repo>")
}

function ConvertTo-RedactedText {
  param([string]$Text)

  if ([string]::IsNullOrWhiteSpace($Text)) {
    return ""
  }

  $redacted = $Text.Replace($RepoRoot, "<repo>")
  $redacted = $redacted -replace "Bearer\s+[A-Za-z0-9._~+/=-]+", "Bearer <redacted>"
  $redacted = $redacted -replace "(HOME_[A-Z_]*TOKEN\s*[:=]\s*)(\S+)", '${1}<redacted>'
  return $redacted
}

function Get-TextTail {
  param(
    [string]$Path,
    [int]$LineCount = 16
  )

  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    return ""
  }

  return ConvertTo-RedactedText -Text ((Get-Content -LiteralPath $Path -Tail $LineCount) -join " | ")
}

function Get-BridgeExitCause {
  param([string]$Text)

  if ($Text -match "Failed to query Python interpreter|os error 5|Access is denied|アクセスが拒否") {
    return "uv_python_access_denied"
  }
  if ($Text -match "Failed to initialize cache") {
    return "uv_cache_access_denied"
  }
  if ($Text -match "address already in use|Only one usage of each socket address|WinError 10048") {
    return "port_in_use"
  }
  return "bridge_process_exited"
}

function Read-DotEnvValue {
  param(
    [string]$Path,
    [string]$Name
  )

  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    return ""
  }

  foreach ($line in Get-Content -LiteralPath $Path) {
    $trimmed = $line.Trim()
    if ([string]::IsNullOrWhiteSpace($trimmed) -or $trimmed.StartsWith("#")) {
      continue
    }
    $separatorIndex = $trimmed.IndexOf("=")
    if ($separatorIndex -lt 1) {
      continue
    }
    $key = $trimmed.Substring(0, $separatorIndex).Trim()
    if ($key -ne $Name) {
      continue
    }
    $value = $trimmed.Substring($separatorIndex + 1).Trim()
    if (($value.StartsWith('"') -and $value.EndsWith('"')) -or
        ($value.StartsWith("'") -and $value.EndsWith("'"))) {
      $value = $value.Substring(1, $value.Length - 2)
    }
    return $value
  }
  return ""
}

function Invoke-CameraBrightness {
  param([string]$Label)

  $python = Resolve-PythonCommand
  $arguments = @(
    $MeasureScript,
    "--camera-index", [string]$CameraIndex,
    "--backend", $CameraBackend,
    "--frames", [string]$BrightnessFrames,
    "--warmup", [string]$BrightnessWarmup
  )
  $output = @(& $python @arguments 2>&1 | ForEach-Object { [string]$_ })
  $exitCode = if ($null -eq $LASTEXITCODE) { 0 } else { $LASTEXITCODE }
  $text = ($output -join "`n").Trim()
  if ([string]::IsNullOrWhiteSpace($text)) {
    throw "camera brightness helper returned no output for $Label"
  }
  $jsonLine = @($output | Where-Object { $_.Trim().StartsWith("{") } | Select-Object -Last 1)[0]
  $payload = $jsonLine | ConvertFrom-Json
  $payload | Add-Member -NotePropertyName label -NotePropertyValue $Label -Force
  $payload | Add-Member -NotePropertyName exit_code -NotePropertyValue $exitCode -Force
  return $payload
}

function Invoke-ApiJson {
  param(
    [Parameter(Mandatory = $true)][string]$Method,
    [Parameter(Mandatory = $true)][string]$Url,
    [hashtable]$Headers = @{},
    [object]$Body = $null
  )

  $invokeArgs = @{
    Method = $Method
    Uri = $Url
    TimeoutSec = 10
  }
  if ($Headers.Count -gt 0) {
    $invokeArgs.Headers = $Headers
  }
  if ($null -ne $Body) {
    $invokeArgs.ContentType = "application/json"
    $invokeArgs.Body = ($Body | ConvertTo-Json -Depth 10)
  }
  return Invoke-RestMethod @invokeArgs
}

function Invoke-LightAction {
  param(
    [string]$ActionId,
    [string]$Stage,
    [string]$RequestPrefix,
    [hashtable]$Headers,
    [string]$BaseUrl
  )

  $encodedActionId = [System.Uri]::EscapeDataString($ActionId)
  $preview = Invoke-ApiJson `
    -Method "Post" `
    -Url "$BaseUrl/actions/$encodedActionId/preview" `
    -Headers $Headers `
    -Body @{ source = "rr003-physical-light-proof"; user_text = "redacted physical light proof preview" }

  $dryBody = @{
    source = "rr003-physical-light-proof"
    request_id = "$RequestPrefix-$Stage-dry-run"
    user_text = "redacted physical light proof dry-run"
    dry_run = $true
  }
  if ($preview.confirmation_required) {
    $dryBody.confirmed = $true
    $dryBody.confirmation_token = $preview.confirmation_token
  }
  $dryRun = Invoke-ApiJson `
    -Method "Post" `
    -Url "$BaseUrl/actions/$encodedActionId/execute" `
    -Headers $Headers `
    -Body $dryBody

  $executeStatus = "skipped"
  $executeExecuted = $false
  $executeSubmitted = $false
  if ($ConfirmLiveLightTicket) {
    $executePreview = Invoke-ApiJson `
      -Method "Post" `
      -Url "$BaseUrl/actions/$encodedActionId/preview" `
      -Headers $Headers `
      -Body @{ source = "rr003-physical-light-proof"; user_text = "redacted physical light proof execute preview" }

    $executeBody = @{
      source = "rr003-physical-light-proof"
      request_id = "$RequestPrefix-$Stage-live"
      user_text = "redacted physical light proof execute"
      dry_run = $false
    }
    if ($executePreview.confirmation_required) {
      $executeBody.confirmed = $true
      $executeBody.confirmation_token = $executePreview.confirmation_token
    }
    $execute = Invoke-ApiJson `
      -Method "Post" `
      -Url "$BaseUrl/actions/$encodedActionId/execute" `
      -Headers $Headers `
      -Body $executeBody
    $executeStatus = [string]$execute.status
    $executeExecuted = [bool]$execute.executed
    $executeSubmitted = ($executeStatus -eq "submitted" -and $executeExecuted)
  }

  return [PSCustomObject]@{
    action_id = $ActionId
    stage = $Stage
    preview_status = [string]$preview.status
    dry_run_status = [string]$dryRun.status
    execute_status = $executeStatus
    execute_submitted = $executeSubmitted
  }
}

function Wait-BridgeHealth {
  param(
    [string]$BaseUrl,
    [int]$TimeoutSeconds,
    [System.Diagnostics.Process]$BridgeProcess = $null,
    [string]$StdoutPath = "",
    [string]$StderrPath = ""
  )

  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  do {
    try {
      $health = Invoke-ApiJson -Method "Get" -Url "$BaseUrl/health"
      if ([bool]$health.ok) {
        return $health
      }
    }
    catch {
    }

    if ($null -ne $BridgeProcess -and $BridgeProcess.HasExited) {
      $stdoutTail = Get-TextTail -Path $StdoutPath
      $stderrTail = Get-TextTail -Path $StderrPath
      $causeText = "$stdoutTail $stderrTail"
      $causeKind = Get-BridgeExitCause -Text $causeText
      throw "Home Control bridge exited before health: cause_kind=$causeKind; exit_code=$($BridgeProcess.ExitCode); stderr_tail=$stderrTail"
    }
    Start-Sleep -Milliseconds 500
  } while ((Get-Date) -lt $deadline)

  $stderrTailOnTimeout = Get-TextTail -Path $StderrPath
  $causeKindOnTimeout = Get-BridgeExitCause -Text $stderrTailOnTimeout
  throw "Home Control bridge did not become healthy before timeout: cause_kind=$causeKindOnTimeout; stderr_tail=$stderrTailOnTimeout"
}

$envFilePath = Resolve-RepoRelativePath -Value $EnvPath -DefaultRelativePath "organs\action\home-assistant-server\.env"
$homeAssistantServerRootPath = Resolve-RepoRelativePath -Value $HomeAssistantServerRoot -DefaultRelativePath "organs\action\home-assistant-server"
$configFilePath = if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
  ""
} else {
  Resolve-RepoRelativePath -Value $ConfigPath -DefaultRelativePath "organs\action\home-assistant-server\config\home-control.yaml"
}
$baseUrl = "http://${HostName}:$Port"

if ($DryRun) {
  $dryRunPayload = [PSCustomObject]@{
    status = "dry-run"
    proof_model = "home-control-light-physical-proof"
    base_url = "loopback"
    env = ConvertTo-DisplayPath -Path $envFilePath
    home_assistant_server_root = ConvertTo-DisplayPath -Path $homeAssistantServerRootPath
    off_action_id = $OffActionId
    on_action_id = $OnActionId
    confirm_live_light_ticket = [bool]$ConfirmLiveLightTicket
    raw_media_saved = $false
    raw_media_shared = $false
    raw_secret_shared = $false
    live_action_executed = $false
  }
  if ($Json) {
    $dryRunPayload | ConvertTo-Json -Depth 8
  } else {
    Write-Host "Home Control physical light proof dry-run"
    Write-Host "status=dry-run"
    Write-Host "live_action_executed=false"
  }
  return
}

if (-not (Test-Path -LiteralPath $envFilePath -PathType Leaf)) {
  throw "Generated Home Control .env not found: $(ConvertTo-DisplayPath -Path $envFilePath)"
}

$homeControlToken = Read-DotEnvValue -Path $envFilePath -Name "HOME_CONTROL_API_TOKEN"
if ([string]::IsNullOrWhiteSpace($homeControlToken) -or $homeControlToken.Length -lt 32) {
  throw "HOME_CONTROL_API_TOKEN is missing or too short in generated env; value hidden."
}

$headers = @{ Authorization = "Bearer $homeControlToken" }
$bridgeProcess = $null
$bridgeStdoutPath = ""
$bridgeStderrPath = ""
$startedBridge = $false
$runId = "rr003-light-proof-{0}" -f (Get-Date -Format "yyyyMMddHHmmss")

try {
  if (-not $UseExistingBridge) {
    $powerShellExe = Resolve-CurrentPowerShell
    $bridgeScript = Join-Path $PSScriptRoot "start-home-control-bridge.ps1"
    $bridgeLogDir = Join-Path $RepoRoot ".cache\home_control\light-proof"
    New-Item -ItemType Directory -Force -Path $bridgeLogDir | Out-Null
    $bridgeStdoutPath = Join-Path $bridgeLogDir "$runId-bridge.out.log"
    $bridgeStderrPath = Join-Path $bridgeLogDir "$runId-bridge.err.log"
    $bridgeArguments = @(
      "-NoProfile",
      "-File", $bridgeScript,
      "-HostName", $HostName,
      "-Port", [string]$Port,
      "-EnvPath", $envFilePath,
      "-HomeAssistantServerRoot", $homeAssistantServerRootPath
    )
    if (-not [string]::IsNullOrWhiteSpace($configFilePath)) {
      $bridgeArguments += @("-ConfigPath", $configFilePath)
    }
    $bridgeProcess = Start-Process `
      -FilePath $powerShellExe `
      -ArgumentList $bridgeArguments `
      -WindowStyle Hidden `
      -RedirectStandardOutput $bridgeStdoutPath `
      -RedirectStandardError $bridgeStderrPath `
      -PassThru
    $startedBridge = $true
  }

  $health = Wait-BridgeHealth `
    -BaseUrl $baseUrl `
    -TimeoutSeconds 30 `
    -BridgeProcess $bridgeProcess `
    -StdoutPath $bridgeStdoutPath `
    -StderrPath $bridgeStderrPath
  $actions = Invoke-ApiJson -Method "Get" -Url "$baseUrl/actions" -Headers $headers
  $actionRows = @($actions)
  $requiredActions = @($OffActionId, $OnActionId)
  foreach ($requiredAction in $requiredActions) {
    if (@($actionRows | Where-Object { [string]$_.action_id -eq $requiredAction }).Count -eq 0) {
      throw "Required action is not in the Home Control catalog: $requiredAction"
    }
  }

  $initialBrightness = Invoke-CameraBrightness -Label "initial"

  $offAction = Invoke-LightAction -ActionId $OffActionId -Stage "off-baseline" -RequestPrefix $runId -Headers $headers -BaseUrl $baseUrl
  Start-Sleep -Seconds $WaitSeconds
  $offBrightness = Invoke-CameraBrightness -Label "off-baseline"

  $onAction = Invoke-LightAction -ActionId $OnActionId -Stage "on-observation" -RequestPrefix $runId -Headers $headers -BaseUrl $baseUrl
  Start-Sleep -Seconds $WaitSeconds
  $onBrightness = Invoke-CameraBrightness -Label "on-observation"

  $restoreAction = Invoke-LightAction -ActionId $OffActionId -Stage "restore-off" -RequestPrefix $runId -Headers $headers -BaseUrl $baseUrl
  Start-Sleep -Seconds $WaitSeconds
  $restoreBrightness = Invoke-CameraBrightness -Label "restore-off"

  $deltaOnVsOff = [Math]::Round(([double]$onBrightness.mean_brightness - [double]$offBrightness.mean_brightness), 3)
  $deltaOnVsRestore = [Math]::Round(([double]$onBrightness.mean_brightness - [double]$restoreBrightness.mean_brightness), 3)
  $restoreReturnDelta = [Math]::Round(([double]$restoreBrightness.mean_brightness - [double]$offBrightness.mean_brightness), 3)
  $invertedDeltaOffVsOn = [Math]::Round(([double]$offBrightness.mean_brightness - [double]$onBrightness.mean_brightness), 3)
  $invertedDeltaRestoreVsOn = [Math]::Round(([double]$restoreBrightness.mean_brightness - [double]$onBrightness.mean_brightness), 3)
  $commandsSubmitted = (
    [bool]$offAction.execute_submitted -and
    [bool]$onAction.execute_submitted -and
    [bool]$restoreAction.execute_submitted
  )
  $physicalObserved = ($deltaOnVsOff -ge $MinDelta -and $deltaOnVsRestore -ge $MinDelta)
  $physicalInverted = ($invertedDeltaOffVsOn -ge $MinDelta -and $invertedDeltaRestoreVsOn -ge $MinDelta)
  $restoreObserved = ([Math]::Abs($restoreReturnDelta) -le $MinDelta)
  $physicalObservationLabel = if ($physicalObserved) {
    "pass"
  } elseif ($physicalInverted) {
    "inverted"
  } else {
    "not-reproduced"
  }
  $status = if (-not $ConfirmLiveLightTicket) {
    "preview-only"
  } elseif ($commandsSubmitted -and $physicalObservationLabel -eq "pass" -and $restoreObserved) {
    "pass"
  } elseif ($commandsSubmitted) {
    "partial"
  } else {
    "blocked"
  }

  $payload = [PSCustomObject]@{
    status = $status
    proof_model = "home-control-light-physical-proof"
    proof_layer = "live-execute + physical-observation"
    bridge_health = [string]$health.status
    action_sequence = @($OffActionId, $OnActionId, $OffActionId)
    operation_count = if ($ConfirmLiveLightTicket) { 3 } else { 0 }
    command_submission = if ($commandsSubmitted) { "pass" } elseif ($ConfirmLiveLightTicket) { "blocked" } else { "preview-only" }
    physical_brightness_observation = $physicalObservationLabel
    restore_observed = if ($restoreObserved) { "pass" } else { "not-reproduced" }
    min_delta = $MinDelta
    brightness = [PSCustomObject]@{
      initial_mean = $initialBrightness.mean_brightness
      off_mean = $offBrightness.mean_brightness
      on_mean = $onBrightness.mean_brightness
      restore_mean = $restoreBrightness.mean_brightness
      delta_on_vs_off = $deltaOnVsOff
      delta_on_vs_restore = $deltaOnVsRestore
      restore_return_delta = $restoreReturnDelta
      inverted_delta_off_vs_on = $invertedDeltaOffVsOn
      inverted_delta_restore_vs_on = $invertedDeltaRestoreVsOn
    }
    actions = @($offAction, $onAction, $restoreAction)
    raw_media_saved = $false
    raw_media_shared = $false
    raw_audio_shared = $false
    raw_transcript_shared = $false
    raw_secret_shared = $false
    raw_ha_payload_shared = $false
    entity_id_shared = $false
    private_path_shared = $false
    live_action_executed = [bool]$ConfirmLiveLightTicket
    cleanup = [PSCustomObject]@{
      started_bridge = $startedBridge
      bridge_process_id = if ($startedBridge) { "<redacted-process-id>" } else { "existing" }
    }
    non_claims = @(
      "not_ha_state_matched_proof",
      "not_broad_home_assistant_coverage",
      "not_raw_media_proof",
      "inverted_brightness_is_not_expected_on_proof"
    )
  }

  if ($Json) {
    $payload | ConvertTo-Json -Depth 12
  } else {
    Write-Host "Home Control physical light proof"
    Write-Host ("status={0}" -f $payload.status)
    Write-Host ("command_submission={0}" -f $payload.command_submission)
    Write-Host ("physical_brightness_observation={0}" -f $payload.physical_brightness_observation)
    Write-Host ("restore_observed={0}" -f $payload.restore_observed)
    Write-Host ("brightness: off={0} on={1} restore={2} delta_on_vs_off={3} delta_on_vs_restore={4}" -f $payload.brightness.off_mean, $payload.brightness.on_mean, $payload.brightness.restore_mean, $payload.brightness.delta_on_vs_off, $payload.brightness.delta_on_vs_restore)
    Write-Host "raw_media_saved=false raw_media_shared=false raw_secret_shared=false entity_id_shared=false"
  }
}
finally {
  if ($startedBridge -and $null -ne $bridgeProcess) {
    Stop-Process -Id $bridgeProcess.Id -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 500
  }
}
