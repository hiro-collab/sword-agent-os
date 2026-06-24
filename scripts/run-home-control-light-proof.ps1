param(
  [string]$HostName = "127.0.0.1",
  [int]$Port = 8787,
  [string]$EnvPath = "",
  [string]$ConfigPath = "",
  [string]$HomeAssistantServerRoot = "",
  [string]$PythonCommand = "",
  [string]$ToggleActionId = "light_toggle",
  [string]$OffActionId = "light_off",
  [string]$OnActionId = "light_on",
  [int]$CameraIndex = 0,
  [int]$WarmupSeconds = 2,
  [int]$ObservationSeconds = 5,
  [int]$RestoreSeconds = 2,
  [double]$MinBrightnessDelta = 12.0,
  [switch]$UseExistingBridge,
  [switch]$ConfirmLiveLightTicket,
  [switch]$DryRun,
  [switch]$Json
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$null = $HostName
$null = $Port
$null = $EnvPath
$null = $ConfigPath
$null = $HomeAssistantServerRoot
$null = $PythonCommand
$null = $OffActionId
$null = $OnActionId
$null = $CameraIndex
$null = $WarmupSeconds
$null = $ObservationSeconds
$null = $RestoreSeconds
$null = $MinBrightnessDelta
$null = $UseExistingBridge
$null = $ConfirmLiveLightTicket
$null = $DryRun

$payload = [ordered]@{
  status = "blocked"
  classification = "retired_directional_light_on_off_proof_helper"
  exact_blocker_if_any = "blocked_light_on_light_off_directional_semantics_untrusted_for_toggle_only_device"
  replacement_action_id_class = $ToggleActionId
  action_model = "light_toggle_only_open_loop_external_observation_required"
  route = "HOME-CONTROL-LIGHT-TOGGLE-SEMANTICS-CLEANUP-01"
  preview_count = 0
  dry_run_count = 0
  live_execute_count = 0
  command_submission_count = 0
  check_tracking_count = 0
  check_state_count = 0
  camera_capture_count = 0
  restore_count = 0
  raw_private_publication_flags = $false
  proof_ceiling = "source_static_light_toggle_semantics_cleanup_only"
  non_claims = @(
    "no_light_on_or_off_directional_capability_claim",
    "no_HA_visible_light_state_claim",
    "no_physical_light_proof",
    "no_Home_Control_command_submission"
  )
}

if ($Json) {
  $payload | ConvertTo-Json -Depth 4
  exit 0
}

Write-Host "classification=$($payload.classification)"
Write-Host "exact_blocker_if_any=$($payload.exact_blocker_if_any)"
Write-Host "replacement_action_id_class=$($payload.replacement_action_id_class)"
Write-Host "action_model=$($payload.action_model)"
Write-Host "counts=preview0,dry_run0,live_execute0,command_submission0,CheckTracking0,CheckState0,camera0,restore0"
Write-Host "proof_ceiling=$($payload.proof_ceiling)"
Write-Host "raw_private_publication_flags=false"
