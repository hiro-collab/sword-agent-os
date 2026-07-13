[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptPath = Join-Path $PSScriptRoot "..\windows\effective-processing-inventory.ps1"
$scriptPath = [System.IO.Path]::GetFullPath($scriptPath)

$script:AssertionCount = 0

function Assert-Equal {
  param(
    [Parameter(Mandatory)]$Actual,
    [Parameter(Mandatory)]$Expected,
    [Parameter(Mandatory)][string]$Message
  )

  $script:AssertionCount += 1
  if ($Actual -ne $Expected) {
    throw "assertion_failed:$Message"
  }
}

function Assert-False {
  param(
    [Parameter(Mandatory)]$Actual,
    [Parameter(Mandatory)][string]$Message
  )

  Assert-Equal -Actual $Actual -Expected $false -Message $Message
}

function Assert-NotMatch {
  param(
    [AllowEmptyString()][string]$Actual,
    [Parameter(Mandatory)][string]$Pattern,
    [Parameter(Mandatory)][string]$Message
  )

  $script:AssertionCount += 1
  if ($Actual -match $Pattern) {
    throw "assertion_failed:$Message"
  }
}

function Invoke-Inventory {
  param([hashtable]$Parameters = @{})

  $json = (& $scriptPath @Parameters | Out-String).Trim()
  if (-not $json) {
    throw "inventory_returned_empty_output"
  }
  return [pscustomobject]@{
    Json = $json
    Value = $json | ConvertFrom-Json -Depth 10
  }
}

$default = Invoke-Inventory
Assert-Equal $default.Value.schema_version "effective_audio_processing_inventory.v0" "schema version"
Assert-Equal $default.Value.proof_ceiling "class_only_effective_processing_inventory" "proof ceiling"
Assert-Equal $default.Value.native_microphone.inventory_class "processing_unknown" "default native processing is unknown"
Assert-Equal $default.Value.native_microphone.owner_count_class "unknown" "unknown owner count"
Assert-Equal $default.Value.result_class "observation_only_processing_unknown" "unknown is observation only"

$windowsOwner = Invoke-Inventory -Parameters @{
  NativeAecOwnerClass = @("windows_voice_capture_dsp")
}
Assert-Equal $windowsOwner.Value.native_microphone.inventory_class "exactly_one_aec_owner" "Windows DSP single owner class"
Assert-Equal $windowsOwner.Value.native_microphone.owner_count_class "one" "Windows DSP owner count"
Assert-Equal $windowsOwner.Value.native_microphone.owner_classes.Count 1 "Windows DSP owner list count"
Assert-Equal $windowsOwner.Value.result_class "single_native_owner_candidate" "single owner remains candidate only"
Assert-False $windowsOwner.Value.native_microphone.exactly_one_owner_proven "declared inventory does not prove effective owner"

$normalizedWindowsOwner = Invoke-Inventory -Parameters @{
  NativeAecOwnerClass = @(" Windows_Voice_Capture_DSP ")
}
Assert-Equal $normalizedWindowsOwner.Value.native_microphone.inventory_class "exactly_one_aec_owner" "native owner trims and normalizes case"
Assert-Equal $normalizedWindowsOwner.Value.native_microphone.owner_classes[0] "windows_voice_capture_dsp" "native owner emits canonical class"

$duplicateWindowsOwner = Invoke-Inventory -Parameters @{
  NativeAecOwnerClass = @(
    "windows_voice_capture_dsp",
    " WINDOWS_VOICE_CAPTURE_DSP "
  )
}
Assert-Equal $duplicateWindowsOwner.Value.native_microphone.inventory_class "exactly_one_aec_owner" "duplicate native aliases collapse to one owner"
Assert-Equal $duplicateWindowsOwner.Value.native_microphone.owner_classes.Count 1 "duplicate native aliases have one canonical class"

$webrtcOwner = Invoke-Inventory -Parameters @{
  NativeAecOwnerClass = @("webrtc_apm_aec3")
}
Assert-Equal $webrtcOwner.Value.native_microphone.inventory_class "exactly_one_aec_owner" "WebRTC single owner class"
Assert-Equal $webrtcOwner.Value.native_microphone.owner_classes[0] "webrtc_apm_aec3" "WebRTC owner class preserved"

$doubleOwner = Invoke-Inventory -Parameters @{
  NativeAecOwnerClass = @("windows_voice_capture_dsp", "webrtc_apm_aec3")
}
Assert-Equal $doubleOwner.Value.native_microphone.inventory_class "double_aec_owner" "double AEC detected"
Assert-Equal $doubleOwner.Value.native_microphone.owner_count_class "multiple" "double AEC count class"
Assert-Equal $doubleOwner.Value.result_class "observation_only_double_aec" "double AEC is observation only"

$noOwner = Invoke-Inventory -Parameters @{
  NativeAecOwnerClass = @("none")
}
Assert-Equal $noOwner.Value.native_microphone.inventory_class "no_aec_owner" "no owner detected"
Assert-Equal $noOwner.Value.result_class "observation_only_no_aec_owner" "no owner is observation only"

$invalidCombination = Invoke-Inventory -Parameters @{
  NativeAecOwnerClass = @("none", "windows_voice_capture_dsp")
}
Assert-Equal $invalidCombination.Value.native_microphone.inventory_class "invalid_owner_combination" "contradictory owner declaration rejected"
Assert-Equal $invalidCombination.Value.result_class "observation_only_invalid_owner_combination" "contradictory owner declaration is observation only"

$unknownKnownCombination = Invoke-Inventory -Parameters @{
  NativeAecOwnerClass = @("unknown", "windows_voice_capture_dsp")
}
Assert-Equal $unknownKnownCombination.Value.native_microphone.inventory_class "invalid_owner_combination" "unknown plus known owner is contradictory"
Assert-Equal $unknownKnownCombination.Value.result_class "observation_only_invalid_owner_combination" "unknown plus known owner remains observation only"

$normalizedBrowser = Invoke-Inventory -Parameters @{
  NativeAecOwnerClass = @("windows_voice_capture_dsp")
  BrowserProcessingClass = " BROWSER_MANAGED "
}
Assert-Equal $normalizedBrowser.Value.browser_stt.processing_class "browser_managed" "browser processing trims and normalizes case"
Assert-Equal $normalizedBrowser.Value.browser_stt.ownership_boundary "browser_processing_separate" "browser processing boundary stays separate"
Assert-False $normalizedBrowser.Value.browser_stt.native_aec_authority "browser processing has no native AEC authority"

$disabledBrowser = Invoke-Inventory -Parameters @{
  NativeAecOwnerClass = @("windows_voice_capture_dsp")
  BrowserProcessingClass = "disabled"
}
Assert-Equal $disabledBrowser.Value.browser_stt.processing_class "disabled" "disabled browser processing class"
Assert-Equal $disabledBrowser.Value.result_class "observation_only_browser_processing_disabled" "disabled browser processing is observation only"

$unknownBrowser = Invoke-Inventory -Parameters @{
  NativeAecOwnerClass = @("windows_voice_capture_dsp")
  BrowserProcessingClass = "unrecognized-browser-mode"
}
Assert-Equal $unknownBrowser.Value.browser_stt.processing_class "unknown" "browser input normalized"
Assert-Equal $unknownBrowser.Value.result_class "observation_only_browser_processing_unknown" "unknown browser processing is observation only"

$testCable = Invoke-Inventory -Parameters @{
  NativeAecOwnerClass = @("windows_voice_capture_dsp")
  PreparedSampleVirtualCableClass = "test_only_active"
}
Assert-Equal $testCable.Value.prepared_sample.virtual_cable_class "test_only_active" "test cable class"
Assert-Equal $testCable.Value.prepared_sample.route_boundary "test_only" "test cable remains test only"
Assert-Equal $testCable.Value.result_class "observation_only_test_route_active" "active test cable cannot become product proof"

$normalizedTestCable = Invoke-Inventory -Parameters @{
  NativeAecOwnerClass = @("windows_voice_capture_dsp")
  PreparedSampleVirtualCableClass = " TEST_ONLY_ACTIVE "
}
Assert-Equal $normalizedTestCable.Value.prepared_sample.virtual_cable_class "test_only_active" "test cable trims and normalizes case"
Assert-Equal $normalizedTestCable.Value.prepared_sample.route_boundary "test_only" "normalized test cable remains test only"
Assert-False $normalizedTestCable.Value.prepared_sample.product_input_authority "test cable has no product input authority"

$privateMarker = "private-marker-should-never-echo"
$redacted = Invoke-Inventory -Parameters @{
  NativeAecOwnerClass = @($privateMarker)
  BrowserProcessingClass = $privateMarker
  PreparedSampleVirtualCableClass = $privateMarker
  Compact = $true
}
Assert-Equal $redacted.Value.native_microphone.inventory_class "processing_unknown" "unknown private input normalized"
Assert-NotMatch $redacted.Json ([regex]::Escape($privateMarker)) "unrecognized input is not echoed"
Assert-NotMatch $redacted.Json '([A-Za-z]:\\|file:|https?://)' "no path or URL output"
Assert-NotMatch $redacted.Json '"(device_name|device_id|endpoint_id|pid|process_id|command_line|payload)"' "no private identity fields"

foreach ($inventory in @(
    $default.Value,
    $windowsOwner.Value,
    $normalizedWindowsOwner.Value,
    $duplicateWindowsOwner.Value,
    $webrtcOwner.Value,
    $doubleOwner.Value,
    $noOwner.Value,
    $invalidCombination.Value,
    $unknownKnownCombination.Value,
    $normalizedBrowser.Value,
    $disabledBrowser.Value,
    $unknownBrowser.Value,
    $testCable.Value,
    $normalizedTestCable.Value,
    $redacted.Value
  )) {
  Assert-False $inventory.privacy.pcm_inspected "PCM remains uninspected"
  Assert-False $inventory.privacy.raw_audio_captured "raw audio remains uncaptured"
  Assert-False $inventory.privacy.raw_audio_persisted "raw audio remains unpersisted"
  Assert-False $inventory.privacy.transcript_observed "transcript remains unobserved"
  Assert-False $inventory.authority.turn_input_authority "inventory has no TurnInput authority"
  Assert-False $inventory.authority.aec_selection_authority "inventory has no AEC selection authority"
  Assert-False $inventory.authority.readiness_authority "inventory has no readiness authority"
}

[pscustomobject]@{
  status = "ok"
  assertions = $script:AssertionCount
  parser_errors = 0
  pcm_capture_count = 0
  dependency_install_count = 0
  proof_ceiling = "class_only_effective_processing_inventory"
} | ConvertTo-Json -Compress
