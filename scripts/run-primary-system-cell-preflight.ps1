param(
  [switch]$Json,
  [switch]$ListRows,
  [switch]$SkipEndpointChecks,
  [int]$LauncherPort = 8799,
  [int]$OpenAIBrokerPort = 18786,
  [int]$ThoughtCorePort = 18787,
  [int]$AituberPort = 3000,
  [int]$EnvironmentStatePort = 8790,
  [int]$VoicevoxPort = 50021,
  [int]$TimeoutSeconds = 3,
  [int]$LaunchReadinessBlockers = -1,
  [switch]$OperatorConfirmedAvatarForeground,
  [switch]$OperatorConfirmedChromeWindowHygiene,
  [switch]$OperatorConfirmedAudioHeard,
  [switch]$OperatorConfirmedAcControlSurfaceReadable,
  [switch]$OperatorConfirmedRestoreOffReadable,
  [switch]$OperatorConfirmedBrowserResponseVisible
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$RepoRoot = Split-Path -Parent $PSScriptRoot

function New-PreflightRow {
  param(
    [Parameter(Mandatory = $true)][string]$Id,
    [Parameter(Mandatory = $true)][string]$Status,
    [Parameter(Mandatory = $true)][string]$PassClass,
    [Parameter(Mandatory = $true)][string]$HoldClass,
    [Parameter(Mandatory = $true)][string]$Detail,
    [string]$Layer = "preflight"
  )

  [PSCustomObject]@{
    id = $Id
    status = $Status
    pass_class = $PassClass
    hold_class = $HoldClass
    layer = $Layer
    detail = $Detail
  }
}

function New-LocalUri {
  param(
    [Parameter(Mandatory = $true)][int]$Port,
    [Parameter(Mandatory = $true)][string]$Path
  )

  $builder = [System.UriBuilder]::new()
  $builder.Scheme = "http"
  $builder.Host = "127.0.0.1"
  $builder.Port = $Port
  $builder.Path = $Path.TrimStart("/")
  return $builder.Uri.AbsoluteUri
}

function Test-LocalEndpoint {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][int]$Port
  )

  if ($SkipEndpointChecks) {
    return [PSCustomObject]@{
      status = "not_checked"
      detail = "endpoint check skipped"
    }
  }

  try {
    $uri = New-LocalUri -Port $Port -Path $Path
    $response = Invoke-WebRequest -Uri $uri -Method Get -TimeoutSec ([Math]::Max(1, $TimeoutSeconds)) -UseBasicParsing
    $ready = ($response.StatusCode -ge 200 -and $response.StatusCode -lt 500)
    return [PSCustomObject]@{
      status = if ($ready) { "reachable" } else { "unreachable" }
      detail = if ($ready) { "http_class_ok" } else { "http_class_not_ok" }
    }
  }
  catch {
    return [PSCustomObject]@{
      status = "unreachable"
      detail = "endpoint_unavailable"
    }
  }
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
    if ($value.Length -ge 2) {
      $quote = $value.Substring(0, 1)
      if (($quote -eq '"' -or $quote -eq "'") -and $value.EndsWith($quote)) {
        return $value.Substring(1, $value.Length - 2)
      }
    }
    return $value
  }

  return ""
}

function Get-PresenceClass {
  param([AllowNull()][string]$Value)
  if ([string]::IsNullOrWhiteSpace($Value)) {
    return "missing_or_empty"
  }
  return "present"
}

function Get-BooleanEnvClass {
  param([AllowNull()][string]$Value)
  if ([string]::IsNullOrWhiteSpace($Value)) {
    return "missing_or_default_false"
  }
  $normalized = $Value.Trim().Trim('"').Trim("'").ToLowerInvariant()
  if ($normalized -in @("1", "true", "yes", "on", "enabled")) {
    return "true"
  }
  if ($normalized -in @("0", "false", "no", "off", "disabled")) {
    return "false"
  }
  return "unknown_boolean_value"
}

function Get-GitCommitClass {
  try {
    $commit = (& git -C $RepoRoot rev-parse HEAD 2>$null).Trim()
    if ($LASTEXITCODE -eq 0 -and $commit -match "^[0-9a-f]{40}$") {
      return [PSCustomObject]@{
        status = "pass"
        class = "selected_clone_current_commit"
        commit = $commit
      }
    }
  }
  catch {
  }

  return [PSCustomObject]@{
    status = "hold"
    class = "blocked_selected_clone_or_commit_unknown"
    commit = ""
  }
}

function Get-LauncherWorkspaceClass {
  if ($SkipEndpointChecks) {
    return "not_checked"
  }

  try {
    $statusUri = New-LocalUri -Port $LauncherPort -Path "/api/status"
    $payload = Invoke-RestMethod -Uri $statusUri -Method Get -TimeoutSec ([Math]::Max(1, $TimeoutSeconds))
    $workspaceRoot = [string]$payload.workspaceRoot
    if ([string]::IsNullOrWhiteSpace($workspaceRoot)) {
      return "launcher_workspace_unknown"
    }
    $expected = [System.IO.Path]::GetFullPath($RepoRoot)
    $actual = [System.IO.Path]::GetFullPath($workspaceRoot)
    if ($actual.Equals($expected, [System.StringComparison]::OrdinalIgnoreCase)) {
      return "selected_repo_workspace"
    }
    return "launcher_workspace_mismatch"
  }
  catch {
    return "launcher_workspace_unreadable"
  }
}

function Get-AudioAwarenessSourceStaticClass {
  $scriptPath = Join-Path $RepoRoot "scripts\check-audio-awareness-readiness.ps1"
  if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
    return [PSCustomObject]@{
      status = "hold"
      class = "readiness_script_missing"
      detail = "check-audio-awareness-readiness.ps1 missing"
    }
  }

  try {
    $output = & powershell -NoProfile -ExecutionPolicy Bypass -File $scriptPath -Json 2>$null
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
      return [PSCustomObject]@{
        status = "hold"
        class = "readiness_script_failed"
        detail = "exit_code=$exitCode"
      }
    }
    $payload = ($output -join "`n") | ConvertFrom-Json
    $status = [string]$payload.status
    return [PSCustomObject]@{
      status = if ($status -eq "pass") { "pass" } else { "hold" }
      class = if ($status -eq "pass") { "source_static_ready" } else { "source_static_not_ready" }
      detail = "readiness_status=$status; proof_ceiling=$($payload.proof_ceiling)"
    }
  }
  catch {
    return [PSCustomObject]@{
      status = "hold"
      class = "readiness_script_unreadable"
      detail = "readiness_json_unavailable"
    }
  }
}

function Get-DemoSafeDefaultsClass {
  $defaultsPath = Join-Path $RepoRoot "manifests\demo-safe-settings\defaults.json"
  if (-not (Test-Path -LiteralPath $defaultsPath -PathType Leaf)) {
    return [PSCustomObject]@{
      status = "hold"
      class = "demo_safe_defaults_missing"
      detail = "tracked_defaults_missing"
    }
  }

  try {
    $payload = Get-Content -Raw -LiteralPath $defaultsPath | ConvertFrom-Json
    $rows = @($payload.rows)
    $enabledRows = @($rows | Where-Object { [bool]$_.enabled })
    $required = @($payload.preflight_required_row_ids | ForEach-Object { [string]$_ })
    $ids = @($rows | ForEach-Object { [string]$_.id })
    $duplicateIdCount = $ids.Count - @($ids | Select-Object -Unique).Count
    $missing = @($required | Where-Object { $_ -notin $ids })
    $pass = (
      [string]$payload.schema_version -eq "demo_safe_settings.v0" -and
      -not [bool]$payload.fresh_clone_default_enabled -and
      $enabledRows.Count -eq 0 -and
      $required.Count -gt 0 -and
      $missing.Count -eq 0 -and
      $duplicateIdCount -eq 0
    )
    return [PSCustomObject]@{
      status = if ($pass) { "pass" } else { "hold" }
      class = if ($pass) { "tracked_defaults_all_off" } else { "tracked_defaults_incomplete_or_enabled" }
      detail = ("canonical_source=manifests/demo-safe-settings/defaults.json; rows={0}; required={1}; enabled={2}; missing_required={3}; duplicate_ids={4}; local_override_class=launcher_state_dir_gitignored_demo_settings_json" -f $rows.Count, $required.Count, $enabledRows.Count, $missing.Count, $duplicateIdCount)
    }
  }
  catch {
    return [PSCustomObject]@{
      status = "hold"
      class = "demo_safe_defaults_unreadable"
      detail = "tracked_defaults_json_unreadable"
    }
  }
}

$rows = @()
$fallbacks = [ordered]@{
  projection_foreground = "blocked_projection_visual_avatar_surface_not_foregrounded"
  chrome_window_hygiene = "blocked_multiple_chrome_windows_route_owned_avatar_surface_not_foregrounded_without_touching_unrelated_user_windows"
  audio_awareness_source_static = "blocked_audio_awareness_source_static_readiness"
  local_tts_playback = "blocked_local_tts_playback_not_confirmed"
  browser_response_binding = "blocked_projection_visual_conversation_response_not_rendered_message_receiver_client_binding_missing_or_not_consuming"
  ac_control_surface = "blocked_chrome_home_assistant_ac_control_surface_not_visible_or_restore_unreadable"
  cleanup = "blocked_route_owned_runtime_cleanup_failed"
}

if ($ListRows) {
  $rows += New-PreflightRow -Id "selected_clone" -Status "not_evaluated" -PassClass "selected_clone_current_commit" -HoldClass "blocked_selected_clone_or_commit_unknown" -Detail "git commit must be readable for the selected clone"
  $rows += New-PreflightRow -Id "launch_blocker_summary" -Status "not_evaluated" -PassClass "launch_blockers_0" -HoldClass "blocked_launch_has_blockers" -Detail "run check-launch-readiness and pass -LaunchReadinessBlockers 0 when setup blockers are cleared"
  $rows += New-PreflightRow -Id "demo_safe_settings" -Status "not_evaluated" -PassClass "tracked_defaults_all_off" -HoldClass "blocked_demo_safe_defaults_missing_or_enabled" -Detail "tracked defaults are the canonical inventory; all candidates start disabled; local overrides stay gitignored"
  $rows += New-PreflightRow -Id "launcher" -Status "not_evaluated" -PassClass "reachable" -HoldClass "blocked_launcher_unreachable" -Detail "Launch Manager local status endpoint must be reachable"
  $rows += New-PreflightRow -Id "openai_provider_broker" -Status "not_evaluated" -PassClass "reachable_no_provider_request" -HoldClass "blocked_openai_provider_broker_unreachable" -Detail "credential-isolated broker health must be reachable; this preflight does not read a key or make an upstream request"
  $rows += New-PreflightRow -Id "thought_core" -Status "not_evaluated" -PassClass "reachable_no_provider_mode" -HoldClass "blocked_thought_core_runtime_unreachable" -Detail "Thought Core health must be reachable without provider calls"
  $rows += New-PreflightRow -Id "aituber_projection_visual" -Status "not_evaluated" -PassClass "reachable" -HoldClass "blocked_aituber_projection_visual_unreachable" -Detail "AITuber/Projection Visual local surface must be reachable"
  $rows += New-PreflightRow -Id "projection_foreground" -Status "not_evaluated" -PassClass "projection_visual_surface_foreground_confirmed" -HoldClass $fallbacks.projection_foreground -Detail "operator or browser control must confirm the Projection Visual surface is in front"
  $rows += New-PreflightRow -Id "chrome_window_hygiene" -Status "not_evaluated" -PassClass "route_owned_surface_targeted_without_unrelated_window_changes" -HoldClass $fallbacks.chrome_window_hygiene -Detail "do not close or retarget unrelated user Chrome windows"
  $rows += New-PreflightRow -Id "voicevox_endpoint" -Status "not_evaluated" -PassClass "endpoint_reachable_only" -HoldClass "blocked_voicevox_endpoint_unreachable" -Detail "VOICEVOX endpoint readiness is service readiness only"
  $rows += New-PreflightRow -Id "audio_awareness_source_static" -Status "not_evaluated" -PassClass "source_static_ready" -HoldClass $fallbacks.audio_awareness_source_static -Detail "source/static no-live readiness only; does not capture PC output, microphone, browser audio, provider STT/TTS, or Home Assistant state"
  $rows += New-PreflightRow -Id "local_audio_playback" -Status "not_evaluated" -PassClass "explicit_audio_observation_confirmed" -HoldClass $fallbacks.local_tts_playback -Detail "audible audio claim needs explicit local playback status or user observation"
  $rows += New-PreflightRow -Id "browser_response_binding" -Status "not_evaluated" -PassClass "message_receiver_client_binding_consuming" -HoldClass $fallbacks.browser_response_binding -Detail "browser-visible response needs a consuming message receiver/client binding"
  $rows += New-PreflightRow -Id "ac_control_surface" -Status "not_evaluated" -PassClass "visible_current_state_and_restore_target_readable" -HoldClass $fallbacks.ac_control_surface -Detail "Chrome/Home Assistant AC fallback needs visible current state and restore/off target"
  $rows += New-PreflightRow -Id "service_down_relevance" -Status "not_evaluated" -PassClass "down_services_classified_route_blocking_or_nonblocking" -HoldClass "blocked_service_down_relevance_unknown" -Detail "down services must be classified as route-blocking, non-blocking, or out of scope"
  $rows += New-PreflightRow -Id "cleanup_path" -Status "not_evaluated" -PassClass "route_owned_cleanup_available" -HoldClass $fallbacks.cleanup -Detail "route-owned cleanup path must be available before presentation"
}
else {
  $git = Get-GitCommitClass
  $rows += New-PreflightRow `
    -Id "selected_clone" `
    -Status $git.status `
    -PassClass "selected_clone_current_commit" `
    -HoldClass "blocked_selected_clone_or_commit_unknown" `
    -Detail ("commit_class={0}" -f $git.class)

  $launchReadinessStatus = if ($LaunchReadinessBlockers -eq 0) { "pass" } else { "hold" }
  $launchReadinessDetail = if ($LaunchReadinessBlockers -lt 0) {
    "not_supplied; run scripts/check-launch-readiness.ps1 first or pass -LaunchReadinessBlockers 0"
  }
  else {
    "blockers={0}" -f $LaunchReadinessBlockers
  }
  $rows += New-PreflightRow `
    -Id "launch_blocker_summary" `
    -Status $launchReadinessStatus `
    -PassClass "launch_blockers_0" `
    -HoldClass "blocked_launch_has_blockers" `
    -Detail $launchReadinessDetail

  $demoSafeDefaults = Get-DemoSafeDefaultsClass
  $rows += New-PreflightRow `
    -Id "demo_safe_settings" `
    -Status $demoSafeDefaults.status `
    -PassClass "tracked_defaults_all_off" `
    -HoldClass "blocked_demo_safe_defaults_missing_or_enabled" `
    -Detail $demoSafeDefaults.detail

  $launcher = Test-LocalEndpoint -Path "/api/status" -Port $LauncherPort
  $launcherWorkspaceClass = Get-LauncherWorkspaceClass
  $rows += New-PreflightRow `
    -Id "launcher" `
    -Status $(if ($launcher.status -eq "reachable" -and $launcherWorkspaceClass -in @("selected_repo_workspace", "not_checked")) { "pass" } else { "hold" }) `
    -PassClass "reachable" `
    -HoldClass "blocked_launcher_unreachable" `
    -Detail ("endpoint={0}; workspace_class={1}" -f $launcher.status, $launcherWorkspaceClass)

  $openAIBroker = Test-LocalEndpoint -Path "/health" -Port $OpenAIBrokerPort
  $rows += New-PreflightRow `
    -Id "openai_provider_broker" `
    -Status $(if ($openAIBroker.status -eq "reachable") { "pass" } elseif ($openAIBroker.status -eq "not_checked") { "info" } else { "hold" }) `
    -PassClass "reachable_no_provider_request" `
    -HoldClass "blocked_openai_provider_broker_unreachable" `
    -Detail ("endpoint={0}; port={1}; secret_source_class=thought-core-existing-env-v1; credential_owner=openai_provider_broker; provider_network_call=false" -f $openAIBroker.status, $OpenAIBrokerPort)

  $thoughtCore = Test-LocalEndpoint -Path "/health" -Port $ThoughtCorePort
  $rows += New-PreflightRow `
    -Id "thought_core" `
    -Status $(if ($thoughtCore.status -eq "reachable") { "pass" } elseif ($thoughtCore.status -eq "not_checked") { "info" } else { "hold" }) `
    -PassClass "reachable_no_provider_mode" `
    -HoldClass "blocked_thought_core_runtime_unreachable" `
    -Detail ("endpoint={0}; provider_network_call=false" -f $thoughtCore.status)

  $aituberRoot = Test-LocalEndpoint -Path "/" -Port $AituberPort
  $projection = Test-LocalEndpoint -Path "/projection-visual/" -Port $AituberPort
  $rows += New-PreflightRow `
    -Id "aituber_projection_visual" `
    -Status $(if ($aituberRoot.status -eq "reachable" -and $projection.status -eq "reachable") { "pass" } elseif ($aituberRoot.status -eq "not_checked") { "info" } else { "hold" }) `
    -PassClass "reachable" `
    -HoldClass "blocked_aituber_projection_visual_unreachable" `
    -Detail ("aituber={0}; projection_visual={1}" -f $aituberRoot.status, $projection.status)

  $rows += New-PreflightRow `
    -Id "projection_foreground" `
    -Status $(if ($OperatorConfirmedAvatarForeground) { "pass" } else { "hold" }) `
    -PassClass "projection_visual_surface_foreground_confirmed" `
    -HoldClass $fallbacks.projection_foreground `
    -Detail "requires operator or browser-control confirmation; this script does not open or retarget Chrome"

  $rows += New-PreflightRow `
    -Id "chrome_window_hygiene" `
    -Status $(if ($OperatorConfirmedChromeWindowHygiene) { "pass" } else { "hold" }) `
    -PassClass "route_owned_surface_targeted_without_unrelated_window_changes" `
    -HoldClass $fallbacks.chrome_window_hygiene `
    -Detail "confirm no unrelated user Chrome window was closed or retargeted"

  $voicevox = Test-LocalEndpoint -Path "/version" -Port $VoicevoxPort
  $rows += New-PreflightRow `
    -Id "voicevox_endpoint" `
    -Status $(if ($voicevox.status -eq "reachable") { "pass" } elseif ($voicevox.status -eq "not_checked") { "info" } else { "hold" }) `
    -PassClass "reachable" `
    -HoldClass "blocked_voicevox_endpoint_unreachable" `
    -Detail ("endpoint={0}; service_readiness_only=true" -f $voicevox.status)

  $audioAwareness = Get-AudioAwarenessSourceStaticClass
  $rows += New-PreflightRow `
    -Id "audio_awareness_source_static" `
    -Status $audioAwareness.status `
    -PassClass "source_static_ready" `
    -HoldClass $fallbacks.audio_awareness_source_static `
    -Detail ("{0}; no_live_capture=true; no_raw_audio_or_transcript=true" -f $audioAwareness.detail)

  $rows += New-PreflightRow `
    -Id "local_audio_playback" `
    -Status $(if ($OperatorConfirmedAudioHeard) { "pass" } else { "hold" }) `
    -PassClass "explicit_audio_observation_confirmed" `
    -HoldClass $fallbacks.local_tts_playback `
    -Detail "VOICEVOX endpoint readiness is not an audible playback claim; pass only when explicit audio observation is supplied"

  $aituberEnvPath = Join-Path $RepoRoot "organs\expression\aituber-kit\.env"
  $receiverClass = Get-BooleanEnvClass -Value (Read-DotEnvValue -Path $aituberEnvPath -Name "NEXT_PUBLIC_MESSAGE_RECEIVER_ENABLED")
  $clientClass = Get-PresenceClass -Value (Read-DotEnvValue -Path $aituberEnvPath -Name "NEXT_PUBLIC_CLIENT_ID")
  $bindingPass = ($receiverClass -eq "true" -and $clientClass -eq "present" -and $OperatorConfirmedBrowserResponseVisible)
  $rows += New-PreflightRow `
    -Id "browser_response_binding" `
    -Status $(if ($bindingPass) { "pass" } else { "hold" }) `
    -PassClass "message_receiver_client_binding_consuming" `
    -HoldClass $fallbacks.browser_response_binding `
    -Detail ("receiver_class={0}; client_id_class={1}; browser_response_observed={2}" -f $receiverClass, $clientClass, [bool]$OperatorConfirmedBrowserResponseVisible)

  $acPass = ($OperatorConfirmedAcControlSurfaceReadable -and $OperatorConfirmedRestoreOffReadable)
  $rows += New-PreflightRow `
    -Id "ac_control_surface" `
    -Status $(if ($acPass) { "pass" } else { "hold" }) `
    -PassClass "visible_current_state_and_restore_target_readable" `
    -HoldClass $fallbacks.ac_control_surface `
    -Detail ("current_state_readable={0}; restore_off_readable={1}; action_max=1; restore_max=1; retry=0; broad_loop=0; ha_service_api_bypass=0" -f [bool]$OperatorConfirmedAcControlSurfaceReadable, [bool]$OperatorConfirmedRestoreOffReadable)

  $envState = Test-LocalEndpoint -Path "/health" -Port $EnvironmentStatePort
  $rows += New-PreflightRow `
    -Id "service_down_relevance" `
    -Status "pass" `
    -PassClass "down_services_classified_route_blocking_or_nonblocking" `
    -HoldClass "blocked_service_down_relevance_unknown" `
    -Detail ("environment_state={0}; home_control_actions_catalog=not_required_for_chrome_ha_fallback; mediapipe_vision_touchdesigner=out_of_scope_unless_selected" -f $envState.status)

  $stopLauncherPath = Join-Path $RepoRoot "scripts\stop-launcher.ps1"
  $cleanupPass = Test-Path -LiteralPath $stopLauncherPath -PathType Leaf
  $rows += New-PreflightRow `
    -Id "cleanup_path" `
    -Status $(if ($cleanupPass) { "pass" } else { "hold" }) `
    -PassClass "route_owned_cleanup_available" `
    -HoldClass $fallbacks.cleanup `
    -Detail "use launcher stop path first; verify route-owned ports/listeners and fresh-clone processes after stop"
}

$holds = @($rows | Where-Object { $_.status -eq "hold" })
$passes = @($rows | Where-Object { $_.status -eq "pass" })
$infos = @($rows | Where-Object { $_.status -eq "info" -or $_.status -eq "not_evaluated" })

$result = [PSCustomObject]@{
  route_id = "PRIMARY-SYSTEM-CELL-PRESENTATION-PREFLIGHT-01"
  entrypoint_class = "bounded_user_visible_route_preflight"
  default_safety = [PSCustomObject]@{
    provider_network_stt_tts = $false
    live_microphone_or_camera_capture = $false
    live_pc_output_capture = $false
    home_assistant_command_submission = $false
    home_control_actions_catalog_success_claim = $false
    raw_audio_or_transcript_publication = $false
    raw_private_publication = $false
  }
  status = if ($ListRows) { "rows_listed" } elseif ($holds.Count -gt 0) { "hold" } else { "pass" }
  counts = [PSCustomObject]@{
    rows = $rows.Count
    pass = $passes.Count
    hold = $holds.Count
    info_or_not_evaluated = $infos.Count
  }
  rows = @($rows)
  fallback_strings = $fallbacks
  proof_layer_notes = [PSCustomObject]@{
    local_playback = "explicit local playback or user-observation layer only"
    audio_awareness_source_static = "contract and no-live source/static readiness only"
    user_observed_audio = "observation layer; keep separate from browser TTS summary"
    browser_tts_or_speech_summary = "claim only when the browser surface consumes and reports it"
    avatar_screen = "foreground/display layer only"
    browser_visible_response = "claim only when conversation response renders on the browser surface"
    browser_visible_motion = "separate from model-state or motion request events"
    physical_device_observation = "separate external or physical proof layer"
  }
  chrome_home_assistant_ac_fallback = [PSCustomObject]@{
    positive_action_max = 1
    restore_off_max = 1
    restore_required_when_needed_and_readable = $true
    retry_max = 0
    broad_unrelated_loop_max = 0
    ha_service_api_bypass_max = 0
    actions_catalog_success_claim = $false
  }
  cleanup_rerunability = "stop route-owned launcher/runtime first; verify route-owned ports/listeners clear; do not stop unrelated user processes"
  raw_private_publication_flags = $false
  non_claims = @(
    "no runtime/live appliance operation performed by this preflight",
    "no provider/network STT/TTS",
    "no live PC-output/microphone/browser STT/camera/media capture",
    "no raw audio or transcript publication",
    "no Home Control /actions catalog success",
    "no physical/device proof",
    "no release/final RR003 pass or route-ready claim"
  )
}

if ($Json) {
  $result | ConvertTo-Json -Depth 8
  return
}

Write-Host "Primary System Cell presentation preflight"
Write-Host ("status={0}" -f $result.status)
Write-Host ("rows={0} pass={1} hold={2}" -f $result.counts.rows, $result.counts.pass, $result.counts.hold)
foreach ($row in $rows) {
  Write-Host ("{0}: {1} pass={2} hold={3} detail={4}" -f $row.id, $row.status, $row.pass_class, $row.hold_class, $row.detail)
}
Write-Host "raw_private_publication_flags=false"
Write-Host "non_claims=no_runtime_live_appliance_operation,no_provider_network_stt_tts,no_live_pc_output_microphone_browser_stt_camera_media_capture,no_raw_audio_or_transcript_publication,no_home_control_actions_catalog_success,no_physical_device_proof,no_final_rr003_pass"
