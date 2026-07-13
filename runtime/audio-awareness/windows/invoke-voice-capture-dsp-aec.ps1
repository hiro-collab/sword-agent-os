[CmdletBinding()]
param(
  [ValidateSet("capability_only", "live_source")]
  [string]$Mode = "capability_only",
  [int]$WindowMs = 1000,
  [int]$DeadlineMs = 3000,
  [switch]$Compact
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function ConvertTo-FailureClass {
  param([AllowNull()][string]$Value)

  $allowed = @(
    "processed_pcm_pipe_lease_invalid",
    "processed_pcm_pipe_owner_unavailable",
    "processed_pcm_pipe_lease_missing",
    "processed_pcm_pipe_lease_expired",
    "processed_pcm_pipe_server_identity_mismatch",
    "processed_pcm_pipe_private_input_timeout",
    "processed_pcm_pipe_connect_failed",
    "processed_pcm_pipe_connect_timeout",
    "processed_pcm_pipe_handshake_failed",
    "processed_pcm_pipe_write_failed",
    "live_aec_backend_or_sink_missing",
    "live_aec_bounds_invalid",
    "live_aec_processed_packet_invalid",
    "live_aec_deadline_exceeded",
    "live_aec_cleanup_failed",
    "live_aec_lifecycle_invariant_failed",
    "voice_capture_dsp_activation_failed",
    "voice_capture_dsp_configuration_failed",
    "voice_capture_dsp_output_format_failed",
    "voice_capture_dsp_start_failed",
    "voice_capture_dsp_not_started",
    "voice_capture_dsp_process_output_failed",
    "voice_capture_dsp_stop_failed",
    "live_aec_observer_failed"
  )
  $text = [string]($Value ?? "")
  return $(if ($allowed -contains $text) { $text } else { "live_aec_observer_failed" })
}

function New-ClassOnlyOutput {
  param(
    [Parameter(Mandatory)][string]$ResultClass,
    [Parameter(Mandatory)][string]$CapabilityClass,
    [Parameter(Mandatory)][string]$CleanupClass,
    [string]$SourceClass = "windows_voice_capture_dsp_source_mode",
    [string]$OwnerClass = "windows_voice_capture_dsp",
    [int]$WindowMsValue = 0,
    [int]$PacketCount = 0,
    [long]$ProcessedByteCount = 0,
    [int]$BackendActivateCount = 0,
    [int]$CaptureStartCount = 0,
    [int]$CaptureStopAttemptCount = 0,
    [int]$CaptureStopCount = 0,
    [int]$BackendResourceReleaseCount = 0,
    [int]$SinkConnectCount = 0,
    [int]$SinkWriteCount = 0,
    [int]$SinkReleaseCount = 0,
    [int]$CancelCount = 0,
    [bool]$LiveCaptureUsed = $false,
    [bool]$ExactlyOneAecOwner = $false
  )

  $residue = $(if ($CleanupClass -eq "cleanup_not_proven") { $null } else { 0 })
  return [ordered]@{
    schema_version = "voice_capture_dsp_aec_observation.v0"
    proof_ceiling = $(if ($LiveCaptureUsed) {
        "local_windows_voice_capture_dsp_reachability_only"
      } else {
        "source_static_live_aec_adapter_contract"
      })
    result_class = $ResultClass
    capability_class = $CapabilityClass
    owner_class = $OwnerClass
    source_class = $SourceClass
    observation = [ordered]@{
      window_ms = $WindowMsValue
      packet_count = $PacketCount
      processed_byte_count = $ProcessedByteCount
      live_capture_used = $LiveCaptureUsed
    }
    lifecycle = [ordered]@{
      backend_activate_count = $BackendActivateCount
      capture_start_count = $CaptureStartCount
      capture_stop_attempt_count = $CaptureStopAttemptCount
      capture_stop_count = $CaptureStopCount
      backend_resource_release_count = $BackendResourceReleaseCount
      sink_connect_count = $SinkConnectCount
      sink_write_count = $SinkWriteCount
      sink_release_count = $SinkReleaseCount
      cancel_count = $CancelCount
      cleanup_class = $CleanupClass
      owned_process_residue_count = $residue
      pipe_residue_count = $residue
      temporary_file_residue_count = $residue
    }
    privacy = [ordered]@{
      render_reference_published = $false
      raw_pcm_published = $false
      raw_audio_persisted = $false
      transcript_observed = $false
      pipe_name_published = $false
      process_or_device_identity_published = $false
      private_path_published = $false
      payload_published = $false
    }
    authority = [ordered]@{
      exactly_one_aec_owner = $ExactlyOneAecOwner
      render_reference_turn_input_authority = $false
      processed_near_end_turn_input_authority = $false
      thought_core_turn_input_authority = $false
      user_heard_authority = $false
      readiness_authority = $false
    }
    does_not_prove = @(
      "live_barge_in",
      "self_output_turn_input_blocking",
      "genuine_user_speech_acceptance",
      "aec_effectiveness",
      "subjective_audio_quality",
      "user_heard_audio",
      "release_readiness"
    )
  }
}

function Write-ClassOnlyOutput {
  param([Parameter(Mandatory)]$Value)

  $parameters = @{ Depth = 7 }
  if ($Compact) { $parameters.Compress = $true }
  $Value | ConvertTo-Json @parameters
}

function Read-PrivateLeasePacket {
  if (-not [Console]::IsInputRedirected) { return $null }
  $readTask = [Console]::In.ReadLineAsync()
  if (-not $readTask.Wait(1000)) {
    return [pscustomobject]@{ failure_class = "processed_pcm_pipe_private_input_timeout" }
  }
  $line = $readTask.GetAwaiter().GetResult()
  if ([string]::IsNullOrWhiteSpace($line)) { return $null }
  try {
    return $line | ConvertFrom-Json -Depth 8
  } catch {
    return [pscustomobject]@{ failure_class = "processed_pcm_pipe_lease_invalid" }
  }
}

$sourcePath = Join-Path $PSScriptRoot "VoiceCaptureDspAec.cs"
try {
  if (-not ("SwordAgentOS.AudioAwareness.VoiceCaptureDspAec" -as [type])) {
    Add-Type -LiteralPath $sourcePath
  }
} catch {
  Write-ClassOnlyOutput (New-ClassOnlyOutput `
      -ResultClass "source_compile_failed" `
      -CapabilityClass "not_checked" `
      -CleanupClass "no_runtime_started")
  return
}

$capability = [SwordAgentOS.AudioAwareness.VoiceCaptureDspAec]::GetCapability()
if ($Mode -eq "capability_only") {
  Write-ClassOnlyOutput (New-ClassOnlyOutput `
      -ResultClass $capability.CapabilityClass `
      -CapabilityClass $capability.CapabilityClass `
      -CleanupClass "no_runtime_started")
  return
}

$leasePacket = Read-PrivateLeasePacket
if ($null -eq $leasePacket) {
  Write-ClassOnlyOutput (New-ClassOnlyOutput `
      -ResultClass "processed_pcm_pipe_lease_missing" `
      -CapabilityClass $capability.CapabilityClass `
      -CleanupClass "no_runtime_started")
  return
}

if ($null -ne $leasePacket.PSObject.Properties["failure_class"]) {
  Write-ClassOnlyOutput (New-ClassOnlyOutput `
      -ResultClass (ConvertTo-FailureClass -Value $leasePacket.failure_class) `
      -CapabilityClass $capability.CapabilityClass `
      -CleanupClass "no_runtime_started")
  return
}

if ($capability.CapabilityClass -ne "voice_capture_dsp_capability_available") {
  Write-ClassOnlyOutput (New-ClassOnlyOutput `
      -ResultClass $capability.CapabilityClass `
      -CapabilityClass $capability.CapabilityClass `
      -CleanupClass "no_runtime_started")
  return
}

try {
  $required = @(
    "pipe_name",
    "nonce",
    "server_process_id",
    "server_creation_utc_ticks",
    "expires_utc_ticks",
    "aec_owner_selection_class",
    "selected_owner_class",
    "processing_mode_class"
  )
  foreach ($name in $required) {
    if ($null -eq $leasePacket.PSObject.Properties[$name]) {
      throw [SwordAgentOS.AudioAwareness.VoiceCaptureDspException]::new(
        "processed_pcm_pipe_lease_invalid")
    }
  }
  $lease = [SwordAgentOS.AudioAwareness.VoiceCaptureDspAec]::AcquirePipeLease(
    [string]$leasePacket.pipe_name,
    [string]$leasePacket.nonce,
    [int]$leasePacket.server_process_id,
    [long]$leasePacket.server_creation_utc_ticks,
    [long]$leasePacket.expires_utc_ticks,
    [string]$leasePacket.aec_owner_selection_class,
    [string]$leasePacket.selected_owner_class,
    [string]$leasePacket.processing_mode_class)
  $result = [SwordAgentOS.AudioAwareness.VoiceCaptureDspAec]::ObserveAsync(
    $lease,
    $WindowMs,
    $DeadlineMs,
    [System.Threading.CancellationToken]::None).GetAwaiter().GetResult()
  Write-ClassOnlyOutput (New-ClassOnlyOutput `
      -ResultClass $result.ResultClass `
      -CapabilityClass $capability.CapabilityClass `
      -CleanupClass "route_owned_cleanup_clear" `
      -SourceClass $result.SourceClass `
      -OwnerClass $result.OwnerClass `
      -WindowMsValue $result.WindowMs `
      -PacketCount $result.PacketCount `
      -ProcessedByteCount $result.ProcessedByteCount `
      -BackendActivateCount $result.BackendActivateCount `
      -CaptureStartCount $result.CaptureStartCount `
      -CaptureStopAttemptCount $result.CaptureStopAttemptCount `
      -CaptureStopCount $result.CaptureStopCount `
      -BackendResourceReleaseCount $result.BackendResourceReleaseCount `
      -SinkConnectCount $result.SinkConnectCount `
      -SinkWriteCount $result.SinkWriteCount `
      -SinkReleaseCount $result.SinkReleaseCount `
      -CancelCount $result.CancelCount `
      -LiveCaptureUsed $true `
      -ExactlyOneAecOwner $true)
} catch {
  $failureClass = "live_aec_observer_failed"
  $exception = $_.Exception
  while ($null -ne $exception) {
    if ($exception.GetType().FullName -eq
      "SwordAgentOS.AudioAwareness.VoiceCaptureDspException") {
      $failureClass = ConvertTo-FailureClass -Value $exception.FailureClass
      break
    }
    $exception = $exception.InnerException
  }
  $noRuntime = $failureClass -match '^processed_pcm_pipe_lease_'
  Write-ClassOnlyOutput (New-ClassOnlyOutput `
      -ResultClass $failureClass `
      -CapabilityClass $capability.CapabilityClass `
      -CleanupClass $(if ($noRuntime) { "no_runtime_started" } else { "cleanup_not_proven" }))
}
