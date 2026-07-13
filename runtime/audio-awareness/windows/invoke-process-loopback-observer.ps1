[CmdletBinding()]
param(
  [string]$Mode = "capability_only",
  [int]$TargetProcessId = 0,
  [int]$WindowMs = 1000,
  [int]$DeadlineMs = 3000,
  [switch]$Compact
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function ConvertTo-ModeClass {
  param([AllowNull()][string]$Value)

  switch (($Value ?? "").Trim().ToLowerInvariant()) {
    "capability_only" { return "capability_only" }
    "synthetic_render" { return "synthetic_render" }
    "synthetic_silence" { return "synthetic_silence" }
    "live_process_tree" { return "live_process_tree" }
    default { return "invalid" }
  }
}

function ConvertTo-FailureClass {
  param([AllowNull()][string]$Value)

  $allowed = @(
    "backend_missing",
    "target_process_lease_missing",
    "target_process_lease_invalid",
    "target_process_lease_exited",
    "target_process_lease_expired",
    "target_process_lease_identity_mismatch",
    "observation_bounds_invalid",
    "observation_deadline_exceeded",
    "process_loopback_activation_start_failed",
    "process_loopback_activation_failed",
    "process_loopback_activation_abandoned",
    "process_loopback_initialize_failed",
    "process_loopback_capture_service_failed",
    "process_loopback_start_failed",
    "process_loopback_packet_query_failed",
    "process_loopback_buffer_get_failed",
    "process_loopback_buffer_release_failed",
    "process_loopback_stop_failed",
    "process_loopback_cleanup_failed",
    "process_loopback_lifecycle_invariant_failed",
    "process_loopback_not_initialized",
    "process_loopback_observer_failed"
  )
  $text = [string]($Value ?? "")
  return $(if ($allowed -contains $text) { $text } else { "process_loopback_observer_failed" })
}

function New-ClassOnlyOutput {
  param(
    [Parameter(Mandatory)][string]$SourceClass,
    [Parameter(Mandatory)][string]$ProofCeiling,
    [Parameter(Mandatory)][string]$ResultClass,
    [Parameter(Mandatory)][string]$CapabilityClass,
    [Parameter(Mandatory)][string]$AttributionClass,
    [Parameter(Mandatory)][string]$CleanupClass,
    [int]$ObservedWindowMs = 0,
    [int]$PacketCount = 0,
    [long]$FrameCount = 0,
    [long]$NonSilentFrameCount = 0,
    [long]$SilentFrameCount = 0,
    [int]$CaptureStartCount = 0,
    [int]$CaptureStopAttemptCount = 0,
    [int]$CaptureStopCount = 0,
    [int]$BufferReleaseCount = 0,
    [int]$ResourceReleaseCount = 0,
    [int]$CancelCount = 0,
    [bool]$LiveCaptureUsed = $false
  )

  $residueCount = $(if ($CleanupClass -eq "cleanup_not_proven") {
      $null
    } else {
      0
    })

  return [ordered]@{
    schema_version = "process_loopback_observation.v0"
    source_class = $SourceClass
    proof_ceiling = $ProofCeiling
    result_class = $ResultClass
    capability_class = $CapabilityClass
    attribution_class = $AttributionClass
    observation = [ordered]@{
      window_ms = $ObservedWindowMs
      packet_count = $PacketCount
      frame_count = $FrameCount
      non_silent_frame_count = $NonSilentFrameCount
      silent_frame_count = $SilentFrameCount
      live_capture_used = $LiveCaptureUsed
    }
    lifecycle = [ordered]@{
      capture_start_count = $CaptureStartCount
      capture_stop_attempt_count = $CaptureStopAttemptCount
      capture_stop_count = $CaptureStopCount
      buffer_release_count = $BufferReleaseCount
      resource_release_count = $ResourceReleaseCount
      cancel_count = $CancelCount
      cleanup_class = $CleanupClass
      owned_process_residue_count = $residueCount
      temporary_residue_count = $residueCount
    }
    privacy = [ordered]@{
      raw_pcm_published = $false
      raw_audio_persisted = $false
      transcript_observed = $false
      target_process_identity_published = $false
      device_or_endpoint_identity_published = $false
      private_path_published = $false
      payload_published = $false
    }
    authority = [ordered]@{
      microphone_capture_authority = $false
      turn_input_authority = $false
      speech_acceptance_authority = $false
      aec_selection_authority = $false
      user_heard_authority = $false
      readiness_authority = $false
    }
    does_not_prove = @(
      "microphone_capture",
      "aec_effectiveness",
      "self_output_classification",
      "user_speech_separation",
      "turn_input_enforcement",
      "user_heard_audio",
      "release_readiness"
    )
  }
}

function Write-ClassOnlyOutput {
  param([Parameter(Mandatory)]$Value)

  $parameters = @{ Depth = 7 }
  if ($Compact) {
    $parameters.Compress = $true
  }
  $Value | ConvertTo-Json @parameters
}

$modeClass = ConvertTo-ModeClass -Value $Mode
if ($modeClass -eq "invalid") {
  Write-ClassOnlyOutput (New-ClassOnlyOutput `
      -SourceClass "source_static_guard" `
      -ProofCeiling "source_static_process_loopback_guard" `
      -ResultClass "invalid_mode" `
      -CapabilityClass "not_checked" `
      -AttributionClass "not_attempted" `
      -CleanupClass "no_runtime_started")
  return
}

$sourcePath = Join-Path $PSScriptRoot "ProcessLoopbackObserver.cs"
try {
  if (-not ("SwordAgentOS.AudioAwareness.ProcessLoopbackObserver" -as [type])) {
    Add-Type -LiteralPath $sourcePath
  }
} catch {
  Write-ClassOnlyOutput (New-ClassOnlyOutput `
      -SourceClass "source_static_guard" `
      -ProofCeiling "source_static_process_loopback_guard" `
      -ResultClass "source_compile_failed" `
      -CapabilityClass "not_checked" `
      -AttributionClass "not_attempted" `
      -CleanupClass "no_runtime_started")
  return
}

$capability = [SwordAgentOS.AudioAwareness.ProcessLoopbackObserver]::GetCapability()
if ($modeClass -eq "capability_only") {
  Write-ClassOnlyOutput (New-ClassOnlyOutput `
      -SourceClass "capability_probe" `
      -ProofCeiling "class_only_process_loopback_capability" `
      -ResultClass $capability.CapabilityClass `
      -CapabilityClass $capability.CapabilityClass `
      -AttributionClass "not_attempted" `
      -CleanupClass "no_runtime_started")
  return
}

if ($modeClass -in @("synthetic_render", "synthetic_silence")) {
  $fixture = [SwordAgentOS.AudioAwareness.ProcessLoopbackObserver]::CreateSyntheticFixture(
    $modeClass -eq "synthetic_render")
  Write-ClassOnlyOutput (New-ClassOnlyOutput `
      -SourceClass $fixture.SourceClass `
      -ProofCeiling "source_static_process_loopback_fixture" `
      -ResultClass $fixture.ResultClass `
      -CapabilityClass $capability.CapabilityClass `
      -AttributionClass $fixture.AttributionClass `
      -CleanupClass "no_runtime_started" `
      -ObservedWindowMs $fixture.WindowMs `
      -PacketCount $fixture.PacketCount `
      -FrameCount $fixture.FrameCount `
      -NonSilentFrameCount $fixture.NonSilentFrameCount `
      -SilentFrameCount $fixture.SilentFrameCount)
  return
}

if ($TargetProcessId -le 0) {
  Write-ClassOnlyOutput (New-ClassOnlyOutput `
      -SourceClass "live_process_loopback" `
      -ProofCeiling "process_loopback_observation_summary_only" `
      -ResultClass "target_process_lease_missing" `
      -CapabilityClass $capability.CapabilityClass `
      -AttributionClass "not_attempted" `
      -CleanupClass "no_runtime_started")
  return
}

if ($capability.CapabilityClass -ne "process_loopback_capability_available") {
  Write-ClassOnlyOutput (New-ClassOnlyOutput `
      -SourceClass "live_process_loopback" `
      -ProofCeiling "process_loopback_observation_summary_only" `
      -ResultClass "process_loopback_capability_unavailable" `
      -CapabilityClass $capability.CapabilityClass `
      -AttributionClass "not_attempted" `
      -CleanupClass "no_runtime_started")
  return
}

try {
  $leaseTtlMs = [Math]::Min(15000, [Math]::Max(250, $DeadlineMs + 1000))
  $lease = [SwordAgentOS.AudioAwareness.ProcessLoopbackObserver]::AcquireProcessLease(
    $TargetProcessId,
    $leaseTtlMs)
  $task = [SwordAgentOS.AudioAwareness.ProcessLoopbackObserver]::ObserveAsync(
    $lease,
    $WindowMs,
    $DeadlineMs,
    [System.Threading.CancellationToken]::None)
  $result = $task.GetAwaiter().GetResult()
  Write-ClassOnlyOutput (New-ClassOnlyOutput `
      -SourceClass $result.SourceClass `
      -ProofCeiling "process_loopback_observation_summary_only" `
      -ResultClass $result.ResultClass `
      -CapabilityClass $capability.CapabilityClass `
      -AttributionClass $result.AttributionClass `
      -CleanupClass "route_owned_cleanup_clear" `
      -ObservedWindowMs $result.WindowMs `
      -PacketCount $result.PacketCount `
      -FrameCount $result.FrameCount `
      -NonSilentFrameCount $result.NonSilentFrameCount `
      -SilentFrameCount $result.SilentFrameCount `
      -CaptureStartCount $result.CaptureStartCount `
      -CaptureStopAttemptCount $result.CaptureStopAttemptCount `
      -CaptureStopCount $result.CaptureStopCount `
      -BufferReleaseCount $result.BufferReleaseCount `
      -ResourceReleaseCount $result.ResourceReleaseCount `
      -CancelCount $result.CancelCount `
      -LiveCaptureUsed $true)
} catch {
  $failureClass = "process_loopback_observer_failed"
  $exception = $_.Exception
  while ($null -ne $exception) {
    if ($exception.GetType().FullName -eq
      "SwordAgentOS.AudioAwareness.ProcessLoopbackObserverException") {
      $failureClass = ConvertTo-FailureClass -Value $exception.FailureClass
      break
    }
    $exception = $exception.InnerException
  }
  $leaseFailure = $failureClass -match '^target_process_lease_'
  Write-ClassOnlyOutput (New-ClassOnlyOutput `
      -SourceClass "live_process_loopback" `
      -ProofCeiling "process_loopback_observation_summary_only" `
      -ResultClass $failureClass `
      -CapabilityClass $capability.CapabilityClass `
      -AttributionClass $(if ($leaseFailure) { "not_attempted" } else { "target_process_tree_requested" }) `
      -CleanupClass $(if ($leaseFailure) { "no_runtime_started" } else { "cleanup_not_proven" }))
}
