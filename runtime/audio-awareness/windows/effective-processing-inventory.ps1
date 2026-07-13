[CmdletBinding()]
param(
  [string[]]$NativeAecOwnerClass = @("unknown"),
  [string]$BrowserProcessingClass = "browser_managed",
  [string]$PreparedSampleVirtualCableClass = "inactive",
  [switch]$Compact
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function ConvertTo-NativeOwnerClass {
  param([AllowNull()][string]$Value)

  switch (($Value ?? "").Trim().ToLowerInvariant()) {
    "none" { return "none" }
    "windows_voice_capture_dsp" { return "windows_voice_capture_dsp" }
    "webrtc_apm_aec3" { return "webrtc_apm_aec3" }
    default { return "unknown" }
  }
}

function ConvertTo-BrowserProcessingClass {
  param([AllowNull()][string]$Value)

  switch (($Value ?? "").Trim().ToLowerInvariant()) {
    "browser_managed" { return "browser_managed" }
    "disabled" { return "disabled" }
    default { return "unknown" }
  }
}

function ConvertTo-VirtualCableClass {
  param([AllowNull()][string]$Value)

  switch (($Value ?? "").Trim().ToLowerInvariant()) {
    "inactive" { return "inactive" }
    "test_only_active" { return "test_only_active" }
    default { return "unknown" }
  }
}

$normalizedOwners = @(
  $NativeAecOwnerClass |
    ForEach-Object { ConvertTo-NativeOwnerClass -Value $_ } |
    Sort-Object -Unique
)
if ($normalizedOwners.Count -eq 0) {
  $normalizedOwners = @("unknown")
}

$knownOwners = @(
  $normalizedOwners |
    Where-Object { $_ -in @("windows_voice_capture_dsp", "webrtc_apm_aec3") }
)
$hasUnknown = $normalizedOwners -contains "unknown"
$hasNone = $normalizedOwners -contains "none"

$nativeInventoryClass = "processing_unknown"
$nativeOwnerCountClass = "unknown"
$nativeHandlingClass = "observation_only"

if (($hasUnknown -and ($hasNone -or $knownOwners.Count -gt 0)) -or
  ($hasNone -and $knownOwners.Count -gt 0)) {
  $nativeInventoryClass = "invalid_owner_combination"
  $nativeOwnerCountClass = "unknown"
} elseif ($hasUnknown) {
  $nativeInventoryClass = "processing_unknown"
  $nativeOwnerCountClass = "unknown"
} elseif ($hasNone) {
  $nativeInventoryClass = "no_aec_owner"
  $nativeOwnerCountClass = "zero"
} elseif ($knownOwners.Count -eq 1) {
  $nativeInventoryClass = "exactly_one_aec_owner"
  $nativeOwnerCountClass = "one"
  $nativeHandlingClass = "single_owner_candidate_only"
} elseif ($knownOwners.Count -gt 1) {
  $nativeInventoryClass = "double_aec_owner"
  $nativeOwnerCountClass = "multiple"
}

$browserClass = ConvertTo-BrowserProcessingClass -Value $BrowserProcessingClass
$virtualCableClass = ConvertTo-VirtualCableClass -Value $PreparedSampleVirtualCableClass

$resultClass = switch ($nativeInventoryClass) {
  "invalid_owner_combination" { "observation_only_invalid_owner_combination"; break }
  "double_aec_owner" { "observation_only_double_aec"; break }
  "processing_unknown" { "observation_only_processing_unknown"; break }
  "no_aec_owner" { "observation_only_no_aec_owner"; break }
  default {
    if ($browserClass -eq "unknown") {
      "observation_only_browser_processing_unknown"
    } elseif ($browserClass -eq "disabled") {
      "observation_only_browser_processing_disabled"
    } elseif ($virtualCableClass -eq "unknown") {
      "observation_only_virtual_cable_state_unknown"
    } elseif ($virtualCableClass -eq "test_only_active") {
      "observation_only_test_route_active"
    } else {
      "single_native_owner_candidate"
    }
  }
}

$inventory = [ordered]@{
  schema_version = "effective_audio_processing_inventory.v0"
  source_class = "declared_class_inventory"
  proof_ceiling = "class_only_effective_processing_inventory"
  result_class = $resultClass
  native_microphone = [ordered]@{
    inventory_class = $nativeInventoryClass
    owner_count_class = $nativeOwnerCountClass
    owner_classes = $normalizedOwners
    handling_class = $nativeHandlingClass
    exactly_one_owner_proven = $false
  }
  browser_stt = [ordered]@{
    processing_class = $browserClass
    ownership_boundary = "browser_processing_separate"
    native_aec_authority = $false
  }
  prepared_sample = [ordered]@{
    virtual_cable_class = $virtualCableClass
    route_boundary = "test_only"
    product_input_authority = $false
  }
  phase_boundary = [ordered]@{
    phase_1_process_loopback_observer = "separate_reviewed_route_required"
    phase_2_exactly_one_owner_selection = "not_selected_by_inventory"
    live_self_output_classification = "not_proven"
  }
  privacy = [ordered]@{
    pcm_inspected = $false
    raw_audio_captured = $false
    raw_audio_persisted = $false
    transcript_observed = $false
    private_endpoint_published = $false
    process_identity_published = $false
  }
  authority = [ordered]@{
    turn_input_authority = $false
    speech_acceptance_authority = $false
    aec_selection_authority = $false
    user_heard_authority = $false
    readiness_authority = $false
  }
  does_not_prove = @(
    "effective_processing_enabled",
    "live_process_loopback",
    "aec_effectiveness",
    "self_output_classification",
    "user_speech_separation",
    "turn_input_enforcement",
    "user_heard_audio",
    "release_readiness"
  )
}

$jsonParameters = @{
  Depth = 6
}
if ($Compact) {
  $jsonParameters.Compress = $true
}

$inventory | ConvertTo-Json @jsonParameters
