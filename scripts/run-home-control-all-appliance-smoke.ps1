param(
  [string]$HostName = "127.0.0.1",
  [int]$Port = 8787,
  [string]$HomeAssistantServerRoot = "",
  [string]$CameraPython = "",
  [string]$CameraScript = "",
  [switch]$SkipCamera,
  [switch]$IncludeLightOff,
  [switch]$IncludeFanOff,
  [switch]$IncludeAirconWrappers,
  [switch]$IncludeVacuumPause,
  [switch]$KeepBridgeRunning
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$RepoRoot = Split-Path -Parent $PSScriptRoot
$RouteId = "HC-OP-ALL-APPLIANCE-REAL-SURFACE-SMOKE-01"

function Resolve-PathValue {
  param([string]$Value, [string]$Default)
  $candidate = if ([string]::IsNullOrWhiteSpace($Value)) { $Default } else { $Value }
  if (-not [System.IO.Path]::IsPathRooted($candidate)) {
    $candidate = Join-Path $RepoRoot $candidate
  }
  return [System.IO.Path]::GetFullPath($candidate)
}

function Resolve-DefaultCameraScript {
  if ([string]::IsNullOrWhiteSpace($env:USERPROFILE)) { return "" }
  $candidate = Join-Path $env:USERPROFILE ".codex\skills\live-camera-verification\scripts\check_camera_once.py"
  if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
  return ""
}

function Read-DotEnvValue {
  param([string]$Path, [string]$Name)
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return "" }
  foreach ($line in Get-Content -LiteralPath $Path) {
    $trimmed = $line.Trim()
    if ([string]::IsNullOrWhiteSpace($trimmed) -or $trimmed.StartsWith("#")) { continue }
    $separatorIndex = $trimmed.IndexOf("=")
    if ($separatorIndex -lt 1) { continue }
    $key = $trimmed.Substring(0, $separatorIndex).Trim()
    if ($key -ne $Name) { continue }
    $value = $trimmed.Substring($separatorIndex + 1).Trim()
    if (($value.StartsWith('"') -and $value.EndsWith('"')) -or
        ($value.StartsWith("'") -and $value.EndsWith("'"))) {
      $value = $value.Substring(1, $value.Length - 2)
    }
    return $value
  }
  return ""
}

function New-SmokeResult {
  [ordered]@{
    route_id = $RouteId
    layer = "home_control_all_appliance_real_surface_smoke"
    proof_ceiling = "ha_command_submission_camera_environment_estimate_and_ha_visible_checkstate_layers"
    status_class = "running"
    result_class = "not_complete"
    blocker_class = "none_yet"
    bounded_counts = [ordered]@{
      bridge_start_attempt = 0
      bridge_start_success = 0
      bridge_health_readiness_precheck = 0
      action_id_availability_check = 0
      camera_read_attempt_count = 0
      camera_read_success_count = 0
      light_command_submission_count = 0
      fan_command_submission_count = 0
      aircon_command_submission_count = 0
      door_command_submission_count = 0
      vacuum_command_submission_count = 0
      confirmation_challenge_count = 0
      confirmation_submit_count = 0
      live_execute_count = 0
      command_submission_count = 0
      checktracking_action_count = 0
      checktracking_tracked_count = 0
      checktracking_unavailable_count = 0
      checkstate_attempt_count = 0
      checkstate_matched_count = 0
      checkstate_mismatch_count = 0
      checkstate_unavailable_count = 0
      direct_ha_bypass_count = 0
      retry_count = 0
      raw_private_count = 0
    }
    action_results = [ordered]@{}
    tracking_results = [ordered]@{}
    state_results = [ordered]@{}
    target_results = [ordered]@{}
    camera_summary = [ordered]@{
      backend_class = "not_checked"
      before_ok = $false
      after_light_stimulus_ok = $false
      after_light_optional_restore_ok = $false
      brightness_movement_stimulus_bucket = "not_available"
      brightness_movement_restore_bucket = "not_available"
      raw_media_saved = $false
      raw_media_displayed = $false
    }
    evidence_summary = ""
    next_action_class = ""
    cleanup_class = "not_started"
    non_claims = @(
      "no_raw_ha_payload_publication",
      "no_entity_or_device_id_publication",
      "no_raw_camera_frame_saved_or_shared",
      "no_physical_device_proof",
      "external_camera_brightness_estimate_only",
      "no_all_appliance_readiness",
      "no_rr003_or_final_readiness"
    )
    raw_private_publication_flags = $false
  }
}

function Set-RouteBlocker {
  param($Result, [string]$Blocker, [string]$Summary)
  $Result.status_class = "blocked"
  $Result.result_class = "blocked_before_complete_route"
  $Result.blocker_class = $Blocker
  $Result.evidence_summary = $Summary
  $Result.next_action_class = "fix_concrete_technical_blocker_then_rerun_exact_route"
}

function Invoke-BridgeJson {
  param([string]$Method, [string]$Path, [hashtable]$Headers, [object]$Body = $null, [int]$TimeoutSec = 30)
  $uri = "http://${HostName}:$Port$Path"
  if ($null -eq $Body) {
    return Invoke-RestMethod -Method $Method -Uri $uri -Headers $Headers -TimeoutSec $TimeoutSec
  }
  $json = $Body | ConvertTo-Json -Depth 12 -Compress
  return Invoke-RestMethod -Method $Method -Uri $uri -Headers $Headers -ContentType "application/json" -Body $json -TimeoutSec $TimeoutSec
}

function ConvertTo-ActionRows {
  param($Response)
  if ($null -eq $Response) { return @() }
  $prop = $Response.PSObject.Properties["actions"]
  if ($null -ne $prop) { return @($prop.Value) }
  return @($Response)
}

function Add-SubmissionCount {
  param($Result, [string]$ActionId)
  $Result.bounded_counts.live_execute_count++
  $Result.bounded_counts.command_submission_count++
  if ($ActionId -like "light_*") { $Result.bounded_counts.light_command_submission_count++ }
  if ($ActionId -like "fan_*") { $Result.bounded_counts.fan_command_submission_count++ }
  if ($ActionId -like "aircon_*") { $Result.bounded_counts.aircon_command_submission_count++ }
  if ($ActionId -like "door_*") { $Result.bounded_counts.door_command_submission_count++ }
  if ($ActionId -like "vacuum_*") { $Result.bounded_counts.vacuum_command_submission_count++ }
}

function Get-SubmissionClass {
  param($Result, [string[]]$ActionIds)
  $classes = @($ActionIds | ForEach-Object { [string]$Result.action_results[$_] })
  if ($classes.Count -eq 0) { return "unavailable" }
  $submitted = @($classes | Where-Object { $_ -like "submitted*" })
  if ($submitted.Count -eq $classes.Count) { return "submitted" }
  if ($submitted.Count -gt 0) { return "partial_submission" }
  return "not_submitted"
}

function Get-CheckTrackingClass {
  param($Result, [string[]]$ActionIds)
  $classes = @($ActionIds | ForEach-Object { [string]$Result.tracking_results[$_] })
  if ($classes.Count -eq 0) { return "not_applicable" }
  return ($classes -join ";")
}

function ConvertTo-BoundedExecutionResultClass {
  param([string]$Status)
  switch ($Status) {
    "rejected" { return "not_submitted_rejected" }
    "failed" { return "not_submitted_failed" }
    "unavailable" { return "not_submitted_unavailable" }
    "submitted" { return "not_submitted_incomplete_submission" }
    default { return "not_submitted_unknown_status" }
  }
}

function ConvertTo-BoundedCheckTrackingClass {
  param([string]$Value)
  $allowed = @("tracked", "external_required", "ack_only", "manual_required", "unsupported", "untracked")
  if ($allowed -ccontains $Value) { return $Value }
  return "unavailable"
}

function ConvertTo-BoundedStateStatus {
  param([string]$Status)
  $allowed = @("matched", "mismatch", "unavailable", "external_required", "ack_only", "manual_required", "unsupported", "position_unavailable")
  if ($allowed -ccontains $Status) { return $Status }
  return "unavailable"
}

function ConvertTo-BoundedCameraBackendClass {
  param([string]$Backend, [bool]$Available)
  if (-not $Available) { return "unavailable" }
  $allowed = @("dshow", "msmf", "avfoundation", "v4l2", "synthetic_fixture")
  if ($allowed -ccontains $Backend) { return $Backend }
  return "available_unknown_backend"
}

function Set-TargetResult {
  param(
    $Result,
    [string]$TargetGroup,
    [string[]]$ActionIds,
    [string[]]$EvidenceClasses,
    [string[]]$RestoreActionIds = @(),
    [string]$HaVisibleStateClass = "not_checked",
    [string]$CameraEnvironmentEstimateClass = "not_applicable",
    [string[]]$Limitations = @()
  )
  $checkTrackingClass = Get-CheckTrackingClass -Result $Result -ActionIds $ActionIds
  $normalizedEvidenceClasses = @($EvidenceClasses + @("checktracking_metadata", "non_claimed_physical_proof", "readiness/final_non_claim"))
  if ($HaVisibleStateClass -match "unavailable|failed" -or $CameraEnvironmentEstimateClass -eq "unavailable" -or $checkTrackingClass -match "unavailable") {
    $normalizedEvidenceClasses += "unavailable"
  }
  $normalizedEvidenceClasses = @($normalizedEvidenceClasses | Select-Object -Unique)
  $Result.target_results[$TargetGroup] = [ordered]@{
    target_group = $TargetGroup
    action_ids = $ActionIds
    evidence_class = $normalizedEvidenceClasses
    checktracking_class = $checkTrackingClass
    command_submission_class = Get-SubmissionClass -Result $Result -ActionIds $ActionIds
    restore_action_ids = $RestoreActionIds
    restore_class = if ($RestoreActionIds.Count -eq 0) { "not_applicable" } else { Get-SubmissionClass -Result $Result -ActionIds $RestoreActionIds }
    ha_visible_state_class = $HaVisibleStateClass
    camera_environment_estimate_class = $CameraEnvironmentEstimateClass
    physical_proof_class = "not_claimed"
    limitations = $Limitations
  }
}

function Invoke-ActionExecute {
  param([string]$ActionId, [hashtable]$Headers, $Result)
  $requestId = "route_" + [guid]::NewGuid().ToString("N")
  $body = @{ source = "overall_test_ladder"; request_id = $requestId }
  $first = Invoke-BridgeJson -Method Post -Path ("/actions/{0}/execute" -f [uri]::EscapeDataString($ActionId)) -Headers $Headers -Body $body
  if ([string]$first.status -eq "confirmation_required") {
    $Result.bounded_counts.confirmation_challenge_count++
    if ([string]::IsNullOrWhiteSpace([string]$first.confirmation_token)) {
      return "confirmation_required_without_token"
    }
    $confirmBody = @{
      source = "overall_test_ladder"
      request_id = $requestId
      confirmed = $true
      confirmation_token = [string]$first.confirmation_token
    }
    $second = Invoke-BridgeJson -Method Post -Path ("/actions/{0}/execute" -f [uri]::EscapeDataString($ActionId)) -Headers $Headers -Body $confirmBody
    $Result.bounded_counts.confirmation_submit_count++
    if ([string]$second.status -eq "submitted" -and [bool]$second.executed) {
      Add-SubmissionCount -Result $Result -ActionId $ActionId
      return "submitted_after_confirmation"
    }
    return ConvertTo-BoundedExecutionResultClass -Status ([string]$second.status)
  }
  if ([string]$first.status -eq "submitted" -and [bool]$first.executed) {
    Add-SubmissionCount -Result $Result -ActionId $ActionId
    return "submitted_without_confirmation"
  }
  return ConvertTo-BoundedExecutionResultClass -Status ([string]$first.status)
}

function Get-StateClassOnce {
  param([string]$ActionId, [hashtable]$Headers, $Result)
  try {
    $state = Invoke-BridgeJson -Method Get -Path ("/actions/{0}/state" -f [uri]::EscapeDataString($ActionId)) -Headers $Headers -TimeoutSec 15
    $class = ConvertTo-BoundedStateStatus -Status ([string]$state.status)
    $Result.bounded_counts.checkstate_attempt_count++
    if ($class -eq "matched") { $Result.bounded_counts.checkstate_matched_count++ }
    elseif ($class -eq "mismatch") { $Result.bounded_counts.checkstate_mismatch_count++ }
    else { $Result.bounded_counts.checkstate_unavailable_count++ }
    return $class
  } catch {
    $Result.bounded_counts.checkstate_attempt_count++
    $Result.bounded_counts.checkstate_unavailable_count++
    return "state_read_failed"
  }
}

function Wait-StateClass {
  param([string]$ActionId, [hashtable]$Headers, $Result, [int]$MaxSeconds, [int]$IntervalSeconds = 5)
  $classes = @()
  $deadline = (Get-Date).AddSeconds($MaxSeconds)
  do {
    $class = Get-StateClassOnce -ActionId $ActionId -Headers $Headers -Result $Result
    $classes += $class
    if ($class -eq "matched") { break }
    if ((Get-Date).AddSeconds($IntervalSeconds) -gt $deadline) { break }
    Start-Sleep -Seconds $IntervalSeconds
  } while ((Get-Date) -lt $deadline)
  return ($classes -join ",")
}

function Get-BrightnessBucket {
  param([double]$Delta)
  $abs = [math]::Abs($Delta)
  if ($abs -lt 3) { return "none_or_tiny" }
  if ($abs -lt 12) { return "small" }
  if ($abs -lt 35) { return "medium" }
  return "large"
}

function Read-CameraSummary {
  param($Result)
  $Result.bounded_counts.camera_read_attempt_count++
  if ($SkipCamera) { return @{ ok = $false; brightness = $null; backend = "skipped" } }
  if (-not (Test-Path -LiteralPath $CameraPython -PathType Leaf) -or
      -not (Test-Path -LiteralPath $CameraScript -PathType Leaf)) {
    return @{ ok = $false; brightness = $null; backend = "missing_python_or_script" }
  }
  try {
    $out = & $CameraPython $CameraScript --camera-index 0 --backend dshow --width 640 --height 480 --fps 30 --warmup-reads 2 2>$null
    $obj = $out | ConvertFrom-Json
    if ([bool]$obj.ok) {
      $Result.bounded_counts.camera_read_success_count++
      return @{ ok = $true; brightness = [double]$obj.mean_brightness; backend = [string]$obj.backend }
    }
    return @{ ok = $false; brightness = $null; backend = "camera_read_failed" }
  } catch {
    return @{ ok = $false; brightness = $null; backend = "camera_exception" }
  }
}

$homeAssistantServerRootPath = Resolve-PathValue -Value $HomeAssistantServerRoot -Default "organs\action\home-assistant-server"
if ([string]::IsNullOrWhiteSpace($CameraPython)) {
  $CameraPython = Join-Path $RepoRoot "organs\reflex\mediapipe-sword-sign\.venv\Scripts\python.exe"
}
$CameraPython = Resolve-PathValue -Value $CameraPython -Default $CameraPython
if ([string]::IsNullOrWhiteSpace($CameraScript)) {
  $CameraScript = Resolve-DefaultCameraScript
} elseif (-not [System.IO.Path]::IsPathRooted($CameraScript)) {
  $CameraScript = Resolve-PathValue -Value $CameraScript -Default $CameraScript
}
$result = New-SmokeResult
$token = Read-DotEnvValue -Path (Join-Path $homeAssistantServerRootPath ".env") -Name "HOME_CONTROL_API_TOKEN"
if ([string]::IsNullOrWhiteSpace($token)) {
  Set-RouteBlocker -Result $result -Blocker "missing_credential_or_config" -Summary "bridge API token missing from local env class; no appliance command submitted"
  $result | ConvertTo-Json -Depth 20
  exit 0
}

$headers = @{ Authorization = "Bearer $token" }
$process = $null
$stdoutPath = Join-Path $env:TEMP ("hc-all-" + [guid]::NewGuid().ToString("N") + ".out.log")
$stderrPath = Join-Path $env:TEMP ("hc-all-" + [guid]::NewGuid().ToString("N") + ".err.log")

try {
  $healthOk = $false
  try {
    $health = Invoke-RestMethod -Method Get -Uri "http://${HostName}:$Port/health" -TimeoutSec 3
    $result.bounded_counts.bridge_health_readiness_precheck++
    if ([bool]$health.ok -and [string]$health.status -ne "config_error") { $healthOk = $true }
  } catch {}

  if (-not $healthOk) {
    $result.bounded_counts.bridge_start_attempt = 1
    $uv = (Get-Command uv -ErrorAction Stop).Source
    $process = Start-Process `
      -FilePath $uv `
      -ArgumentList @(
        "run",
        "--env-file",
        ".env",
        "python",
        "-m",
        "uvicorn",
        "home_control_bridge.main:app",
        "--host",
        $HostName,
        "--port",
        ([string]$Port)
      ) `
      -WorkingDirectory $homeAssistantServerRootPath `
      -WindowStyle Hidden `
      -RedirectStandardOutput $stdoutPath `
      -RedirectStandardError $stderrPath `
      -PassThru
    for ($i = 0; $i -lt 45; $i++) {
      Start-Sleep -Milliseconds 1000
      try {
        $health = Invoke-RestMethod -Method Get -Uri "http://${HostName}:$Port/health" -TimeoutSec 3
        $result.bounded_counts.bridge_health_readiness_precheck++
        if ([bool]$health.ok -and [string]$health.status -ne "config_error") {
          $healthOk = $true
          $result.bounded_counts.bridge_start_success = 1
          break
        }
      } catch {}
      if ($process.HasExited) { break }
    }
  }
  if (-not $healthOk) {
    Set-RouteBlocker -Result $result -Blocker "ha_or_bridge_or_tool_unreachable" -Summary "route-owned bridge did not become health-ready; no appliance command submitted"
    return
  }

  $actionsResponse = Invoke-BridgeJson -Method Get -Path "/actions" -Headers $headers
  $result.bounded_counts.action_id_availability_check = 1
  $actionRows = @(ConvertTo-ActionRows -Response $actionsResponse)
  $actionIds = @($actionRows | ForEach-Object { [string]$_.action_id })
  $targetPlan = [ordered]@{
    light_stimulus = @("light_on")
    fan_command = @("fan_on")
    aircon_cool_to_hvac_off = @("aircon_cool", "aircon_hvac_off")
    door_open_to_close = @("door_open", "door_close")
    vacuum_start_to_return = @("vacuum_start", "vacuum_return")
  }
  if ($IncludeLightOff) {
    $targetPlan["light_off_optional"] = @("light_off")
  }
  if ($IncludeFanOff) {
    $targetPlan["fan_off_optional"] = @("fan_off")
  }
  if ($IncludeAirconWrappers) {
    $targetPlan["aircon_wrapper_command_optional"] = @("aircon_on", "aircon_off")
  }
  if ($IncludeVacuumPause) {
    $targetPlan["vacuum_pause_optional"] = @("vacuum_pause")
  }
  $plannedActions = @($targetPlan.Values | ForEach-Object { $_ } | Select-Object -Unique)
  $missing = @($plannedActions | Where-Object { $_ -notin $actionIds })
  if ($missing.Count -gt 0) {
    Set-RouteBlocker -Result $result -Blocker "missing_or_ambiguous_action_id" -Summary ("planned appliance action ids missing count=" + $missing.Count + "; no batch commands submitted")
    return
  }
  foreach ($actionId in $plannedActions) {
    $row = @($actionRows | Where-Object { [string]$_.action_id -ceq $actionId }) | Select-Object -First 1
    $trackingProperty = if ($null -eq $row) { $null } else { $row.PSObject.Properties["state_tracking"] }
    $trackingClass = if ($null -eq $trackingProperty) { "unavailable" } else { ConvertTo-BoundedCheckTrackingClass -Value ([string]$trackingProperty.Value) }
    $result.tracking_results[$actionId] = $trackingClass
    $result.bounded_counts.checktracking_action_count++
    if ($trackingClass -eq "tracked") {
      $result.bounded_counts.checktracking_tracked_count++
    }
    if ($trackingClass -eq "unavailable") {
      $result.bounded_counts.checktracking_unavailable_count++
    }
  }

  $camBefore = Read-CameraSummary -Result $result
  $result.camera_summary.before_ok = [bool]$camBefore.ok
  $result.camera_summary.backend_class = ConvertTo-BoundedCameraBackendClass -Backend ([string]$camBefore.backend) -Available ([bool]$camBefore.ok)

  $result.action_results["light_on"] = Invoke-ActionExecute -ActionId "light_on" -Headers $headers -Result $result
  Start-Sleep -Seconds 3
  $camOn = Read-CameraSummary -Result $result
  $result.camera_summary.after_light_stimulus_ok = [bool]$camOn.ok
  if ($camBefore.ok -and $camOn.ok) {
    $result.camera_summary.brightness_movement_stimulus_bucket = Get-BrightnessBucket -Delta ([double]$camOn.brightness - [double]$camBefore.brightness)
  }
  if ($IncludeLightOff) {
    $result.action_results["light_off"] = Invoke-ActionExecute -ActionId "light_off" -Headers $headers -Result $result
    Start-Sleep -Seconds 3
    $camOff = Read-CameraSummary -Result $result
    $result.camera_summary.after_light_optional_restore_ok = [bool]$camOff.ok
    if ($camOn.ok -and $camOff.ok) {
      $result.camera_summary.brightness_movement_restore_bucket = Get-BrightnessBucket -Delta ([double]$camOff.brightness - [double]$camOn.brightness)
    }
  }
  $lightCameraClass = if ($camBefore.ok -and $camOn.ok) { "brightness_movement_bucketed" } else { "unavailable" }
  Set-TargetResult -Result $result `
    -TargetGroup "light_stimulus" `
    -ActionIds $targetPlan["light_stimulus"] `
    -EvidenceClasses @("command_submission", "camera_environment_estimate") `
    -HaVisibleStateClass "not_claimed_for_light_stimulus" `
    -CameraEnvironmentEstimateClass $lightCameraClass `
    -Limitations @("external_camera_brightness_estimate_only", "turn_on_off_proof_not_claimed")

  if ($IncludeLightOff) {
    $lightOptionalCameraClass = if ($camOn.ok -and $camOff.ok) { "brightness_movement_bucketed" } else { "unavailable" }
    Set-TargetResult -Result $result `
      -TargetGroup "light_off_optional" `
      -ActionIds $targetPlan["light_off_optional"] `
      -EvidenceClasses @("command_submission", "camera_environment_estimate") `
      -HaVisibleStateClass "not_claimed_for_light_optional_restore" `
      -CameraEnvironmentEstimateClass $lightOptionalCameraClass `
      -Limitations @("optional_light_restore_not_default_smoke_target", "external_camera_brightness_estimate_only", "turn_on_off_proof_not_claimed")
  }

  foreach ($action in $targetPlan["fan_command"]) {
    $result.action_results[$action] = Invoke-ActionExecute -ActionId $action -Headers $headers -Result $result
    Start-Sleep -Seconds 2
  }
  Set-TargetResult -Result $result `
    -TargetGroup "fan_command" `
    -ActionIds $targetPlan["fan_command"] `
    -EvidenceClasses @("command_submission") `
    -HaVisibleStateClass "not_claimed_command_submission_only" `
    -Limitations @("fan_observation_route_not_included")

  if ($IncludeFanOff) {
    foreach ($action in $targetPlan["fan_off_optional"]) {
      $result.action_results[$action] = Invoke-ActionExecute -ActionId $action -Headers $headers -Result $result
      Start-Sleep -Seconds 2
    }
    Set-TargetResult -Result $result `
      -TargetGroup "fan_off_optional" `
      -ActionIds $targetPlan["fan_off_optional"] `
      -EvidenceClasses @("command_submission") `
      -HaVisibleStateClass "not_claimed_command_submission_only" `
      -Limitations @("optional_fan_off_not_default_smoke_target", "fan_observation_route_not_included")
  }

  if ($IncludeAirconWrappers) {
    foreach ($action in $targetPlan["aircon_wrapper_command_optional"]) {
      $result.action_results[$action] = Invoke-ActionExecute -ActionId $action -Headers $headers -Result $result
      Start-Sleep -Seconds 2
    }
    Set-TargetResult -Result $result `
      -TargetGroup "aircon_wrapper_command_optional" `
      -ActionIds $targetPlan["aircon_wrapper_command_optional"] `
      -EvidenceClasses @("command_submission") `
      -HaVisibleStateClass "not_claimed_command_submission_only" `
      -Limitations @("aircon_wrapper_state_proof_not_claimed")
  }

  $result.action_results["aircon_cool"] = Invoke-ActionExecute -ActionId "aircon_cool" -Headers $headers -Result $result
  Start-Sleep -Seconds 2
  $result.state_results["aircon_cool"] = Wait-StateClass -ActionId "aircon_cool" -Headers $headers -Result $result -MaxSeconds 20
  $result.action_results["aircon_hvac_off"] = Invoke-ActionExecute -ActionId "aircon_hvac_off" -Headers $headers -Result $result
  $result.state_results["aircon_hvac_off"] = Wait-StateClass -ActionId "aircon_hvac_off" -Headers $headers -Result $result -MaxSeconds 20
  Set-TargetResult -Result $result `
    -TargetGroup "aircon_cool_to_hvac_off" `
    -ActionIds $targetPlan["aircon_cool_to_hvac_off"] `
    -EvidenceClasses @("command_submission", "ha_visible_state") `
    -RestoreActionIds @("aircon_hvac_off") `
    -HaVisibleStateClass ([string]$result.state_results["aircon_cool"] + ";" + [string]$result.state_results["aircon_hvac_off"])

  $result.action_results["door_open"] = Invoke-ActionExecute -ActionId "door_open" -Headers $headers -Result $result
  $result.state_results["door_open"] = Wait-StateClass -ActionId "door_open" -Headers $headers -Result $result -MaxSeconds 65 -IntervalSeconds 8
  $result.action_results["door_close"] = Invoke-ActionExecute -ActionId "door_close" -Headers $headers -Result $result
  $result.state_results["door_close"] = Wait-StateClass -ActionId "door_close" -Headers $headers -Result $result -MaxSeconds 65 -IntervalSeconds 8
  Set-TargetResult -Result $result `
    -TargetGroup "door_open_to_close" `
    -ActionIds $targetPlan["door_open_to_close"] `
    -EvidenceClasses @("command_submission", "ha_visible_state") `
    -RestoreActionIds @("door_close") `
    -HaVisibleStateClass ([string]$result.state_results["door_open"] + ";" + [string]$result.state_results["door_close"])

  $result.action_results["vacuum_start"] = Invoke-ActionExecute -ActionId "vacuum_start" -Headers $headers -Result $result
  $result.state_results["vacuum_start"] = Wait-StateClass -ActionId "vacuum_start" -Headers $headers -Result $result -MaxSeconds 75 -IntervalSeconds 10
  if ($IncludeVacuumPause) {
    $result.action_results["vacuum_pause"] = Invoke-ActionExecute -ActionId "vacuum_pause" -Headers $headers -Result $result
    $result.state_results["vacuum_pause"] = Wait-StateClass -ActionId "vacuum_pause" -Headers $headers -Result $result -MaxSeconds 60 -IntervalSeconds 10
    Set-TargetResult -Result $result `
      -TargetGroup "vacuum_pause_optional" `
      -ActionIds $targetPlan["vacuum_pause_optional"] `
      -EvidenceClasses @("command_submission", "ha_visible_state") `
      -HaVisibleStateClass ([string]$result.state_results["vacuum_pause"]) `
      -Limitations @("optional_pause_target_not_default_smoke_pair")
  }
  $result.action_results["vacuum_return"] = Invoke-ActionExecute -ActionId "vacuum_return" -Headers $headers -Result $result
  $result.state_results["vacuum_return"] = Wait-StateClass -ActionId "vacuum_return" -Headers $headers -Result $result -MaxSeconds 75 -IntervalSeconds 10
  Set-TargetResult -Result $result `
    -TargetGroup "vacuum_start_to_return" `
    -ActionIds $targetPlan["vacuum_start_to_return"] `
    -EvidenceClasses @("command_submission", "ha_visible_state") `
    -RestoreActionIds @("vacuum_return") `
    -HaVisibleStateClass ([string]$result.state_results["vacuum_start"] + ";" + [string]$result.state_results["vacuum_return"])

  $notSubmitted = @($result.action_results.GetEnumerator() | Where-Object { [string]$_.Value -notlike "submitted*" })
  if ($notSubmitted.Count -gt 0) {
    $result.status_class = "executed_partial"
    $result.result_class = "some_appliance_commands_not_submitted"
    $result.blocker_class = "command_submission_failure"
    $result.evidence_summary = "not submitted action count=$($notSubmitted.Count)"
  } else {
    $result.status_class = "executed"
    $result.result_class = "all_selected_target_group_commands_submitted_with_layer_specific_observations"
    $result.blocker_class = "none_for_command_submission_layer"
    $result.evidence_summary = "all selected target-group command submissions reached submitted class; external camera brightness estimate and HA-visible state observations recorded as separate proof layers; physical proof not claimed"
  }
  $result.next_action_class = "inspect_any_mismatched_ha_state_mappings_or_run_external_observation_where_needed"
} catch {
  Set-RouteBlocker -Result $result -Blocker "technical_execution_exception" -Summary ("batch route threw class=" + $_.Exception.GetType().Name + "; raw details withheld")
} finally {
  if ($null -ne $process -and -not $process.HasExited -and -not $KeepBridgeRunning) {
    try { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue } catch {}
  }
  try {
    $connections = @(Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue)
    foreach ($connection in $connections) {
      if ($null -ne $process -and -not $KeepBridgeRunning) {
        Stop-Process -Id ([int]$connection.OwningProcess) -Force -ErrorAction SilentlyContinue
      }
    }
  } catch {}
  $result.cleanup_class = if ($KeepBridgeRunning) { "bridge_left_running_by_request" } else { "route_owned_bridge_processes_stop_attempted" }
  Remove-Item -LiteralPath $stdoutPath, $stderrPath -ErrorAction SilentlyContinue
  $result | ConvertTo-Json -Depth 20
}
