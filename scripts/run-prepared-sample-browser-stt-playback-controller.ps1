param(
  [Parameter(Mandatory = $true)]
  [string]$AssetId,

  [string]$ConversationAttemptRef = "",
  [string]$WorkspaceRoot = "",
  [string]$ExpectedTextSidecar = "",
  [string]$CollectorPath = "",
  [string]$FfplayPath = "",
  [int]$AttemptCount = 5,
  [ValidateSet("system_default", "installed_virtual_cable_pair_v1")]
  [string]$AudioRouteClass = "system_default",
  [switch]$IntegratedPresentation,
  [switch]$Json
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$RepoRoot = Split-Path -Parent $PSScriptRoot
$PreparedSampleIdPattern = "^[a-z][a-z0-9_.-]{2,127}$"
$LocalePattern = "^[A-Za-z]{2,3}(?:-[A-Za-z0-9]{2,8})*$"
$ExpectedTextSchema = "prepared_sample_expected_text.v1"
$ExpectedTextFailureClass = "prepared_sample_expected_text_authority_missing_or_invalid"
$ExpectedTextFileMaxBytes = 256 * 1024
$SafeChildEnvironmentKeys = @(
  "SystemRoot",
  "WINDIR",
  "ComSpec",
  "TEMP",
  "TMP",
  "PATH",
  "PATHEXT",
  "PROCESSOR_ARCHITECTURE",
  "PROCESSOR_IDENTIFIER",
  "NUMBER_OF_PROCESSORS",
  "OS",
  "USERPROFILE",
  "LOCALAPPDATA",
  "APPDATA",
  "ProgramData",
  "ProgramFiles",
  "ProgramFiles(x86)",
  "ProgramW6432",
  "HOMEDRIVE",
  "HOMEPATH",
  "PSModulePath"
)
$result = $null
$validatedAssetId = $null
$lockStream = $null
$lockPath = $null
$lockOwned = $false
$child = $null
$startInfo = $null
$exitCode = 0
$cleanupIncomplete = $false

function Get-CompletionStopSignal {
  switch ($AttemptCount) {
    1 { return "completed_exactly_one_attempt" }
    2 { return "completed_exactly_two_attempts" }
    3 { return "completed_exactly_three_attempts" }
    4 { return "completed_exactly_four_attempts" }
    5 { return "completed_exactly_five_attempts" }
    default { Throw-Fixed -Class "prepared_sample_playback_controller_configuration_invalid" }
  }
}

function Throw-Fixed {
  param([Parameter(Mandatory = $true)][string]$Class)
  throw [System.InvalidOperationException]::new($Class)
}

function Assert-ExactKeys {
  param(
    [Parameter(Mandatory = $true)]$Value,
    [Parameter(Mandatory = $true)][string[]]$Allowed,
    [string]$FailureClass = $ExpectedTextFailureClass
  )
  if ($null -eq $Value -or $Value -isnot [PSCustomObject]) {
    Throw-Fixed -Class $FailureClass
  }
  $actual = @($Value.PSObject.Properties.Name | Sort-Object)
  $expected = @($Allowed | Sort-Object)
  if (($actual -join "`n") -cne ($expected -join "`n")) {
    Throw-Fixed -Class $FailureClass
  }
}

function Assert-CollectorInteger {
  param(
    [Parameter(Mandatory = $true)]$Value,
    [Parameter(Mandatory = $true)][int]$Minimum,
    [Parameter(Mandatory = $true)][int]$Maximum
  )
  if (
    ($Value -isnot [int] -and $Value -isnot [long]) -or
    [long]$Value -lt $Minimum -or
    [long]$Value -gt $Maximum
  ) {
    Throw-Fixed -Class "prepared_sample_playback_controller_failed"
  }
}

function Assert-CollectorResult {
  param([Parameter(Mandatory = $true)]$Value)

  $failureClass = "prepared_sample_playback_controller_failed"
  Assert-ExactKeys -Value $Value -FailureClass $failureClass -Allowed @(
    "schema_version",
    "controller_status",
    "controller_stop_signal",
    "attempt_count",
    "playback_start_count",
    "playback_exit_zero_count",
    "result_event_count",
    "final_result_count",
    "content_match_stability_class",
    "blocker_class",
    "cleanup_class",
    "system_volume_restore_class",
    "raw_audio_shared",
    "raw_path_shared",
    "raw_text_shared",
    "private_environment_shared",
    "user_heard_proven",
    "turn_input_materialized"
  )

  foreach ($field in @(
    "schema_version",
    "controller_status",
    "controller_stop_signal",
    "content_match_stability_class",
    "cleanup_class",
    "system_volume_restore_class"
  )) {
    if ($Value.$field -isnot [string]) {
      Throw-Fixed -Class $failureClass
    }
  }
  foreach ($field in @(
    "raw_audio_shared",
    "raw_path_shared",
    "raw_text_shared",
    "private_environment_shared",
    "user_heard_proven",
    "turn_input_materialized"
  )) {
    if ($Value.$field -isnot [bool] -or $Value.$field) {
      Throw-Fixed -Class $failureClass
    }
  }

  Assert-CollectorInteger -Value $Value.attempt_count -Minimum 0 -Maximum 5
  Assert-CollectorInteger -Value $Value.playback_start_count -Minimum 0 -Maximum 5
  Assert-CollectorInteger -Value $Value.playback_exit_zero_count -Minimum 0 -Maximum 5
  Assert-CollectorInteger -Value $Value.result_event_count -Minimum 0 -Maximum 100
  Assert-CollectorInteger -Value $Value.final_result_count -Minimum 0 -Maximum 5
  if (
    [long]$Value.playback_exit_zero_count -gt [long]$Value.playback_start_count -or
    [long]$Value.final_result_count -gt [long]$Value.result_event_count
  ) {
    Throw-Fixed -Class $failureClass
  }

  $completeCleanupClass = "browser_closed_or_external_preserved_server_stopped_or_external_preserved_playback_processes_exited_temp_resources_deleted_volume_not_changed"
  $allowedBlockers = @(
    "attempt_listening_not_reached",
    "bounded_attempt_count_not_met",
    "browser_audio_input_track_not_live",
    "browser_audio_output_device_unavailable",
    "browser_audio_output_sink_unavailable",
    "browser_audio_output_sink_selection_failed",
    "browser_audio_route_unavailable_or_ambiguous",
    "browser_launch_failed",
    "browser_microphone_permission_or_device_unavailable",
    "browser_stt_locale_mismatch",
    "browser_stt_no_final_result_before_timeout",
    "accepted_candidate_request_not_completed",
    "cleanup_incomplete",
    "duplicate_final_or_playback_rejected",
    "explicit_audio_input_device_required",
    "operator_server_collision",
    "operator_server_start_failed",
    "playback_exit_nonzero",
    "playback_process_start_failed",
    "prepared_sample_media_bounds_invalid",
    "prepared_sample_page_state_invalid",
    "prepared_sample_playback_controller_configuration_invalid",
    "prepared_sample_playback_controller_failed",
    "repeat_content_match_not_stable",
    "whole_route_timeout"
  )
  if (
    [string]$Value.schema_version -cne "prepared_sample_browser_stt_playback.v1" -or
    [string]$Value.system_volume_restore_class -cne "not_changed"
  ) {
    Throw-Fixed -Class $failureClass
  }

  if ([string]$Value.controller_status -ceq "completed") {
    $expectedStabilityClass = if ($AttemptCount -eq 5) { "stable_positive" } else { "bounded_attempt_set_positive" }
    if (
      [string]$Value.controller_stop_signal -cne (Get-CompletionStopSignal) -or
      [long]$Value.attempt_count -ne $AttemptCount -or
      [long]$Value.playback_start_count -ne $AttemptCount -or
      [long]$Value.playback_exit_zero_count -ne $AttemptCount -or
      [long]$Value.final_result_count -ne $AttemptCount -or
      [string]$Value.content_match_stability_class -cne $expectedStabilityClass -or
      $null -ne $Value.blocker_class -or
      [string]$Value.cleanup_class -cne $completeCleanupClass
    ) {
      Throw-Fixed -Class $failureClass
    }
    return
  }

  if (
    [string]$Value.controller_status -cne "error" -or
    $Value.blocker_class -isnot [string] -or
    -not ($allowedBlockers -ccontains [string]$Value.blocker_class) -or
    [long]$Value.attempt_count -ne 0 -or
    [string]$Value.content_match_stability_class -cne "not_observed"
  ) {
    Throw-Fixed -Class $failureClass
  }
  if ([string]$Value.blocker_class -ceq "cleanup_incomplete") {
    if (
      [string]$Value.controller_stop_signal -cne "stopped_on_cleanup_incomplete" -or
      [string]$Value.cleanup_class -cne "cleanup_incomplete"
    ) {
      Throw-Fixed -Class $failureClass
    }
  } elseif (
    [string]$Value.controller_stop_signal -cne "stopped_on_first_fail_closed_blocker" -or
    [string]$Value.cleanup_class -cne $completeCleanupClass
  ) {
    Throw-Fixed -Class $failureClass
  }
}

function Stop-OwnedChild {
  if ($null -eq $child) {
    return $true
  }
  if ($env:NODE_ENV -ceq "test" -and $env:SWORD_PREPARED_SAMPLE_TEST_CHILD_CLEANUP_FAILURE -ceq "true") {
    return $false
  }
  try {
    if (-not $child.HasExited) {
      $child.Kill($true)
      if (-not $child.WaitForExit(5000)) {
        return $false
      }
    }
    return $child.HasExited
  } catch {
    return $false
  }
}

function Resolve-WorkspaceRoot {
  if (-not [string]::IsNullOrWhiteSpace($WorkspaceRoot)) {
    return [System.IO.Path]::GetFullPath($WorkspaceRoot)
  }
  $candidate = Split-Path -Parent $RepoRoot
  if (Test-Path -LiteralPath (Join-Path $candidate "local\media\media-index.json") -PathType Leaf) {
    return [System.IO.Path]::GetFullPath($candidate)
  }
  Throw-Fixed -Class "prepared_sample_index_or_file_mismatch"
}

function ConvertTo-SafeRelativeMediaPath {
  param([Parameter(Mandatory = $true)][string]$Path)
  if ([string]::IsNullOrWhiteSpace($Path) -or [System.IO.Path]::IsPathRooted($Path)) {
    Throw-Fixed -Class "prepared_sample_index_or_file_mismatch"
  }
  $normalized = ($Path -replace "\\", "/").Trim()
  if ($normalized -notmatch "^local/media/" -or (($normalized -split "/") -contains "..")) {
    Throw-Fixed -Class "prepared_sample_index_or_file_mismatch"
  }
  return $normalized
}

function Test-TextHasControlCharacter {
  param([Parameter(Mandatory = $true)][string]$Text)
  foreach ($character in $Text.ToCharArray()) {
    if ([char]::IsControl($character)) {
      return $true
    }
  }
  return $false
}

function Get-UnicodeScalarCount {
  param([Parameter(Mandatory = $true)][string]$Text)
  $count = 0
  for ($index = 0; $index -lt $Text.Length; $index += 1) {
    $character = $Text[$index]
    if ([char]::IsHighSurrogate($character)) {
      if (
        $index + 1 -ge $Text.Length -or
        -not [char]::IsLowSurrogate($Text[$index + 1])
      ) {
        Throw-Fixed -Class $ExpectedTextFailureClass
      }
      $index += 1
    } elseif ([char]::IsLowSurrogate($character)) {
      Throw-Fixed -Class $ExpectedTextFailureClass
    }
    $count += 1
  }
  return $count
}

function New-FixedFailureResult {
  param([Parameter(Mandatory = $true)][string]$BlockerClass)
  $cleanupFailed = $BlockerClass -ceq "cleanup_incomplete"
  return [PSCustomObject]@{
    schema_version = "prepared_sample_browser_stt_playback.v1"
    controller_status = "error"
    controller_stop_signal = if ($cleanupFailed) { "stopped_on_cleanup_incomplete" } else { "stopped_before_or_on_first_fail_closed_blocker" }
    selected_asset_id = $validatedAssetId
    attempt_count = 0
    playback_start_count = 0
    playback_exit_zero_count = 0
    result_event_count = 0
    final_result_count = 0
    content_match_stability_class = "not_observed"
    blocker_class = $BlockerClass
    cleanup_class = if ($cleanupFailed) { "cleanup_incomplete" } else { "controller_lock_released_child_process_absent_or_exited_private_environment_not_retained" }
    system_volume_restore_class = "not_changed"
    raw_audio_shared = $false
    raw_path_shared = $false
    raw_text_shared = $false
    private_environment_shared = $false
    user_heard_proven = $false
    turn_input_materialized = $false
  }
}

try {
  if ($AttemptCount -lt 1 -or $AttemptCount -gt 5) {
    Throw-Fixed -Class "prepared_sample_playback_controller_configuration_invalid"
  }
  $integratedRouteSelected = $AudioRouteClass -ceq "installed_virtual_cable_pair_v1"
  if (
    [bool]$IntegratedPresentation -ne $integratedRouteSelected -or
    ($AttemptCount -eq 1) -ne $integratedRouteSelected
  ) {
    Throw-Fixed -Class "prepared_sample_playback_controller_configuration_invalid"
  }
  if ($AssetId -notmatch $PreparedSampleIdPattern) {
    Throw-Fixed -Class "prepared_sample_index_or_file_mismatch"
  }
  $validatedAssetId = $AssetId

  $resolvedWorkspaceRoot = Resolve-WorkspaceRoot
  $indexPath = Join-Path $resolvedWorkspaceRoot "local\media\media-index.json"
  if (-not (Test-Path -LiteralPath $indexPath -PathType Leaf)) {
    Throw-Fixed -Class "prepared_sample_index_or_file_mismatch"
  }
  try {
    $index = Get-Content -Raw -LiteralPath $indexPath | ConvertFrom-Json
  } catch {
    Throw-Fixed -Class "prepared_sample_index_or_file_mismatch"
  }
  if ($index.schema_version -ne 1 -or $null -eq $index.assets) {
    Throw-Fixed -Class "prepared_sample_index_or_file_mismatch"
  }
  $assetMatches = @($index.assets | Where-Object { [string]$_.id -ceq $AssetId })
  if ($assetMatches.Count -ne 1) {
    Throw-Fixed -Class "prepared_sample_index_or_file_mismatch"
  }
  $relativePath = ConvertTo-SafeRelativeMediaPath -Path ([string]$assetMatches[0].relative_path)
  $audioPath = Join-Path $resolvedWorkspaceRoot ($relativePath -replace "/", [System.IO.Path]::DirectorySeparatorChar)
  if (-not (Test-Path -LiteralPath $audioPath -PathType Leaf)) {
    Throw-Fixed -Class "prepared_sample_index_or_file_mismatch"
  }

  $defaultExpectedTextSidecar = Join-Path $resolvedWorkspaceRoot "_secret_inputs\prepared-sample-expected-text.v1.json"
  if ([string]::IsNullOrWhiteSpace($ExpectedTextSidecar)) {
    $ExpectedTextSidecar = $defaultExpectedTextSidecar
  } elseif (
    $env:NODE_ENV -cne "test" -and
    [System.IO.Path]::GetFullPath($ExpectedTextSidecar) -cne [System.IO.Path]::GetFullPath($defaultExpectedTextSidecar)
  ) {
    Throw-Fixed -Class $ExpectedTextFailureClass
  }
  if (-not (Test-Path -LiteralPath $ExpectedTextSidecar -PathType Leaf)) {
    Throw-Fixed -Class $ExpectedTextFailureClass
  }
  try {
    if ((Get-Item -LiteralPath $ExpectedTextSidecar).Length -gt $ExpectedTextFileMaxBytes) {
      Throw-Fixed -Class $ExpectedTextFailureClass
    }
  } catch {
    Throw-Fixed -Class $ExpectedTextFailureClass
  }
  try {
    $authority = Get-Content -Raw -LiteralPath $ExpectedTextSidecar | ConvertFrom-Json
  } catch {
    Throw-Fixed -Class $ExpectedTextFailureClass
  }
  Assert-ExactKeys -Value $authority -Allowed @("schema_version", "entries")
  if ([string]$authority.schema_version -cne $ExpectedTextSchema) {
    Throw-Fixed -Class $ExpectedTextFailureClass
  }
  if ($authority.entries -isnot [System.Array]) {
    Throw-Fixed -Class $ExpectedTextFailureClass
  }
  $entries = @($authority.entries)
  if ($entries.Count -lt 1 -or $entries.Count -gt 128) {
    Throw-Fixed -Class $ExpectedTextFailureClass
  }

  $seenIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
  foreach ($entry in $entries) {
    Assert-ExactKeys -Value $entry -Allowed @(
      "sample_id",
      "text_provenance_class",
      "locale",
      "expected_text",
      "shared_publication_class"
    )
    foreach ($field in @(
      "sample_id",
      "text_provenance_class",
      "locale",
      "expected_text",
      "shared_publication_class"
    )) {
      if ($entry.$field -isnot [string]) {
        Throw-Fixed -Class $ExpectedTextFailureClass
      }
    }
    $sampleId = [string]$entry.sample_id
    $expectedText = [string]$entry.expected_text
    $locale = [string]$entry.locale
    if ($sampleId -notmatch $PreparedSampleIdPattern -or -not $seenIds.Add($sampleId)) {
      Throw-Fixed -Class $ExpectedTextFailureClass
    }
    if ([string]$entry.text_provenance_class -cne "prepared_local_sample_set") {
      Throw-Fixed -Class $ExpectedTextFailureClass
    }
    if ($locale.Length -gt 35 -or $locale -notmatch $LocalePattern) {
      Throw-Fixed -Class $ExpectedTextFailureClass
    }
    if (
      [string]::IsNullOrWhiteSpace($expectedText) -or
      (Get-UnicodeScalarCount -Text $expectedText) -gt 512 -or
      (Test-TextHasControlCharacter -Text $expectedText)
    ) {
      Throw-Fixed -Class $ExpectedTextFailureClass
    }
    if ([string]$entry.shared_publication_class -cne "local_only_not_shared") {
      Throw-Fixed -Class $ExpectedTextFailureClass
    }
    $joinedAssets = @($index.assets | Where-Object { [string]$_.id -ceq $sampleId })
    if ($joinedAssets.Count -ne 1 -or [string]$joinedAssets[0].kind -cne "audio") {
      Throw-Fixed -Class $ExpectedTextFailureClass
    }
  }
  $entryMatches = @($entries | Where-Object { [string]$_.sample_id -ceq $AssetId })
  if ($entryMatches.Count -ne 1) {
    Throw-Fixed -Class $ExpectedTextFailureClass
  }
  $selectedEntry = $entryMatches[0]

  $lockDirectory = Join-Path $resolvedWorkspaceRoot ".cache"
  [System.IO.Directory]::CreateDirectory($lockDirectory) | Out-Null
  $lockPath = Join-Path $lockDirectory "prepared-sample-browser-stt-playback-controller.lock"
  try {
    $lockStream = [System.IO.File]::Open(
      $lockPath,
      [System.IO.FileMode]::CreateNew,
      [System.IO.FileAccess]::ReadWrite,
      [System.IO.FileShare]::None
    )
    $lockOwned = $true
  } catch {
    Throw-Fixed -Class "controller_lock_held"
  }

  $preflightPath = Join-Path $RepoRoot "scripts\start-prepared-sample-browser-stt-operator.ps1"
  try {
    $preflightOutput = & $preflightPath `
      -AssetId $AssetId `
      -ConversationAttemptRef $ConversationAttemptRef `
      -WorkspaceRoot $resolvedWorkspaceRoot `
      -AttemptCount $AttemptCount `
      -AudioRouteClass $AudioRouteClass `
      -IntegratedPresentation:$IntegratedPresentation `
      -Json
    $preflight = ($preflightOutput -join "`n") | ConvertFrom-Json
  } catch {
    Throw-Fixed -Class "prepared_sample_index_or_file_mismatch"
  }
  if (
    $preflight.status -cne "preflight_ready" -or
    $preflight.bounded_attempt_count -ne $AttemptCount -or
    $preflight.attempt_timeout_ms -ne 10000 -or
    [string]$preflight.audio_route_class -cne $AudioRouteClass -or
    [bool]$preflight.integrated_presentation -ne [bool]$IntegratedPresentation
  ) {
    Throw-Fixed -Class "prepared_sample_index_or_file_mismatch"
  }

  $aitRoot = Join-Path $RepoRoot "organs\expression\aituber-kit"
  if ([string]::IsNullOrWhiteSpace($CollectorPath)) {
    $CollectorPath = Join-Path $aitRoot "scripts\collect-prepared-sample-browser-stt-playback.mjs"
  } elseif ($env:NODE_ENV -cne "test") {
    Throw-Fixed -Class "prepared_sample_playback_controller_configuration_invalid"
  }
  if (-not (Test-Path -LiteralPath $CollectorPath -PathType Leaf)) {
    Throw-Fixed -Class "prepared_sample_playback_controller_configuration_invalid"
  }
  $node = Get-Command node -ErrorAction SilentlyContinue
  if ($null -eq $node) {
    Throw-Fixed -Class "node_unavailable"
  }
  if ($AudioRouteClass -ceq "system_default" -and [string]::IsNullOrWhiteSpace($FfplayPath)) {
    $ffplay = Get-Command ffplay -ErrorAction SilentlyContinue
    if ($null -eq $ffplay) {
      Throw-Fixed -Class "ffplay_unavailable"
    }
    $FfplayPath = $ffplay.Source
  } elseif ($AudioRouteClass -ceq "system_default" -and $env:NODE_ENV -cne "test") {
    Throw-Fixed -Class "prepared_sample_playback_controller_configuration_invalid"
  }

  $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
  $startInfo.FileName = $node.Source
  $startInfo.WorkingDirectory = $aitRoot
  $startInfo.UseShellExecute = $false
  $startInfo.CreateNoWindow = $true
  $startInfo.RedirectStandardOutput = $true
  $startInfo.RedirectStandardError = $true
  $startInfo.ArgumentList.Add($CollectorPath)
  $startInfo.Environment.Clear()
  foreach ($key in $SafeChildEnvironmentKeys) {
    $value = [System.Environment]::GetEnvironmentVariable($key, "Process")
    if (-not [string]::IsNullOrEmpty($value)) {
      $startInfo.Environment[$key] = $value
    }
  }
  if ($env:NODE_ENV -ceq "test") {
    foreach ($key in @(
      "SWORD_PREPARED_SAMPLE_TEST_COLLECTOR_MODE",
      "SWORD_PREPARED_SAMPLE_TEST_CHILD_PID_FILE"
    )) {
      $value = [System.Environment]::GetEnvironmentVariable($key, "Process")
      if (-not [string]::IsNullOrEmpty($value)) {
        $startInfo.Environment[$key] = $value
      }
    }
  }
  $startInfo.Environment["SWORD_PREPARED_SAMPLE_OPERATOR_URL"] = [string]$preflight.operator_url
  $startInfo.Environment["SWORD_PREPARED_SAMPLE_AUDIO_PATH"] = $audioPath
  $startInfo.Environment["SWORD_PREPARED_SAMPLE_EXPECTED_TEXT"] = [string]$selectedEntry.expected_text
  $startInfo.Environment["SWORD_PREPARED_SAMPLE_LOCALE"] = [string]$selectedEntry.locale
  $startInfo.Environment["SWORD_PREPARED_SAMPLE_FFPLAY_PATH"] = $FfplayPath
  $startInfo.Environment["SWORD_PREPARED_SAMPLE_LOCK_CLASS"] = "held_by_parent"
  $startInfo.Environment["SWORD_PREPARED_SAMPLE_ATTEMPT_COUNT"] = [string]$AttemptCount
  $startInfo.Environment["SWORD_PREPARED_SAMPLE_AUDIO_ROUTE_CLASS"] = $AudioRouteClass
  $startInfo.Environment["SWORD_PREPARED_SAMPLE_INTEGRATED_PRESENTATION"] = ([string][bool]$IntegratedPresentation).ToLowerInvariant()

  $child = [System.Diagnostics.Process]::new()
  $child.StartInfo = $startInfo
  if (-not $child.Start()) {
    Throw-Fixed -Class "browser_launch_failed"
  }
  $stdoutTask = $child.StandardOutput.ReadToEndAsync()
  $stderrTask = $child.StandardError.ReadToEndAsync()
  if (-not $child.WaitForExit(95000)) {
    if (-not (Stop-OwnedChild)) {
      Throw-Fixed -Class "cleanup_incomplete"
    }
    Throw-Fixed -Class "whole_route_timeout"
  }
  $stdout = $stdoutTask.GetAwaiter().GetResult()
  $stderr = $stderrTask.GetAwaiter().GetResult()
  $privateValues = @(
    [string]$selectedEntry.expected_text,
    $audioPath,
    $ExpectedTextSidecar
  )
  foreach ($privateValue in $privateValues) {
    if (
      -not [string]::IsNullOrEmpty($privateValue) -and
      ($stdout.Contains($privateValue) -or $stderr.Contains($privateValue))
    ) {
      Throw-Fixed -Class "raw_private_publication_risk"
    }
  }
  try {
    $collectorResult = $stdout | ConvertFrom-Json
  } catch {
    Throw-Fixed -Class "prepared_sample_playback_controller_failed"
  }
  Assert-CollectorResult -Value $collectorResult
  $collectorCompleted = [string]$collectorResult.controller_status -ceq "completed"
  if (
    ($collectorCompleted -and $child.ExitCode -ne 0) -or
    (-not $collectorCompleted -and $child.ExitCode -eq 0)
  ) {
    Throw-Fixed -Class "prepared_sample_playback_controller_failed"
  }
  $result = $collectorResult
  $result | Add-Member -NotePropertyName selected_asset_id -NotePropertyValue $validatedAssetId
  $result | Add-Member -NotePropertyName conversation_attempt_ref -NotePropertyValue ([string]$preflight.conversation_attempt_ref)
  if (-not $collectorCompleted) {
    $exitCode = 1
  }
} catch {
  $allowedFailureClasses = @(
    $ExpectedTextFailureClass,
    "browser_launch_failed",
    "cleanup_incomplete",
    "controller_lock_held",
    "ffplay_unavailable",
    "node_unavailable",
    "prepared_sample_index_or_file_mismatch",
    "prepared_sample_playback_controller_configuration_invalid",
    "prepared_sample_playback_controller_failed",
    "raw_private_publication_risk",
    "whole_route_timeout"
  )
  $failureClass = if ($allowedFailureClasses -ccontains $_.Exception.Message) {
    $_.Exception.Message
  } else {
    "prepared_sample_playback_controller_failed"
  }
  $result = New-FixedFailureResult -BlockerClass $failureClass
  $exitCode = 1
} finally {
  if (-not (Stop-OwnedChild)) {
    $cleanupIncomplete = $true
  }
  if ($null -ne $lockStream) {
    try {
      $lockStream.Dispose()
    } catch {
      $cleanupIncomplete = $true
    }
  }
  if ($lockOwned -and $null -ne $lockPath) {
    if ($env:NODE_ENV -ceq "test" -and $env:SWORD_PREPARED_SAMPLE_TEST_LOCK_CLEANUP_FAILURE -ceq "true") {
      $cleanupIncomplete = $true
    } else {
      try {
        if (Test-Path -LiteralPath $lockPath) {
          Remove-Item -LiteralPath $lockPath -Force
        }
      } catch {
        $cleanupIncomplete = $true
      }
      if (Test-Path -LiteralPath $lockPath) {
        $cleanupIncomplete = $true
      }
    }
  }
  if ($null -ne $startInfo) {
    foreach ($key in @(
      "SWORD_PREPARED_SAMPLE_OPERATOR_URL",
      "SWORD_PREPARED_SAMPLE_AUDIO_PATH",
      "SWORD_PREPARED_SAMPLE_EXPECTED_TEXT",
      "SWORD_PREPARED_SAMPLE_LOCALE",
      "SWORD_PREPARED_SAMPLE_FFPLAY_PATH",
      "SWORD_PREPARED_SAMPLE_LOCK_CLASS",
      "SWORD_PREPARED_SAMPLE_ATTEMPT_COUNT",
      "SWORD_PREPARED_SAMPLE_AUDIO_ROUTE_CLASS",
      "SWORD_PREPARED_SAMPLE_INTEGRATED_PRESENTATION"
    )) {
      [void]$startInfo.Environment.Remove($key)
    }
  }
  $selectedEntry = $null
  $authority = $null
  $audioPath = $null
  $ExpectedTextSidecar = ""
  if ($cleanupIncomplete) {
    $result = New-FixedFailureResult -BlockerClass "cleanup_incomplete"
    $exitCode = 1
  }
}

if ($Json) {
  $result | ConvertTo-Json -Depth 6 -Compress
} else {
  foreach ($property in $result.PSObject.Properties) {
    if ($property.Value -is [bool]) {
      Write-Host ("{0}={1}" -f $property.Name, ([string]$property.Value).ToLowerInvariant())
    } elseif ($null -ne $property.Value -and $property.Value -isnot [System.Collections.IEnumerable]) {
      Write-Host ("{0}={1}" -f $property.Name, $property.Value)
    }
  }
}

if ($exitCode -eq 1) {
  exit 1
}
