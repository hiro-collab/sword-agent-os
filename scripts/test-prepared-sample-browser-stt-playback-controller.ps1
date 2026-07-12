$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$RepoRoot = Split-Path -Parent $PSScriptRoot
$ControllerPath = Join-Path $RepoRoot "scripts\run-prepared-sample-browser-stt-playback-controller.ps1"
$pwsh = Get-Command pwsh -ErrorAction Stop
$node = Get-Command node -ErrorAction Stop
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("prepared-sample-controller-test-" + [guid]::NewGuid().ToString("N"))
$indexPath = Join-Path $tempRoot "local\media\media-index.json"
$audioPath = Join-Path $tempRoot "local\media\fixture-audio.bin"
$sidecarPath = Join-Path $tempRoot "_secret_inputs\prepared-sample-expected-text.v1.json"
$adapterPath = Join-Path $tempRoot "fake-playback-adapter.mjs"
$privateSentinel = "PRIVATE_EXPECTED_TEXT_SENTINEL"
$assertions = 0

function Assert-True {
  param([bool]$Condition, [string]$Message)
  $script:assertions += 1
  if (-not $Condition) {
    throw $Message
  }
}

function New-ValidEntry {
  param(
    [string]$SampleId = "voice.hello",
    [string]$ExpectedText = $privateSentinel
  )
  return [ordered]@{
    sample_id = $SampleId
    text_provenance_class = "prepared_local_sample_set"
    locale = "ja-JP"
    expected_text = $ExpectedText
    shared_publication_class = "local_only_not_shared"
  }
}

function Write-Index {
  param([string]$Kind = "audio")
  $index = [ordered]@{
    schema_version = 1
    assets = @(
      [ordered]@{
        id = "voice.hello"
        kind = $Kind
        relative_path = "local/media/fixture-audio.bin"
      }
    )
  }
  $index | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $indexPath -Encoding utf8NoBOM
}

function Write-Sidecar {
  param($Value)
  $Value | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $sidecarPath -Encoding utf8NoBOM
}

function New-ValidSidecar {
  return [ordered]@{
    schema_version = "prepared_sample_expected_text.v1"
    entries = @((New-ValidEntry))
  }
}

function Invoke-Controller {
  param(
    [string]$AssetId = "voice.hello",
    [hashtable]$TestEnvironment = @{},
    [int]$AttemptCount = 5,
    [ValidateSet("system_default", "installed_virtual_cable_pair_v1")]
    [string]$AudioRouteClass = "system_default",
    [switch]$IntegratedPresentation
  )
  $previousNodeEnv = $env:NODE_ENV
  $previousValues = @{}
  try {
    $env:NODE_ENV = "test"
    foreach ($key in $TestEnvironment.Keys) {
      $previousValues[$key] = [System.Environment]::GetEnvironmentVariable($key, "Process")
      [System.Environment]::SetEnvironmentVariable($key, [string]$TestEnvironment[$key], "Process")
    }
    $output = @(
      & $pwsh.Source -NoProfile -File $ControllerPath `
        -AssetId $AssetId `
        -WorkspaceRoot $tempRoot `
        -CollectorPath $adapterPath `
        -FfplayPath $node.Source `
        -AttemptCount $AttemptCount `
        -AudioRouteClass $AudioRouteClass `
        -IntegratedPresentation:$IntegratedPresentation `
        -Json 2>&1
    )
    $code = $LASTEXITCODE
    return [PSCustomObject]@{
      code = $code
      text = ($output -join "`n")
    }
  } finally {
    foreach ($key in $TestEnvironment.Keys) {
      [System.Environment]::SetEnvironmentVariable($key, $previousValues[$key], "Process")
    }
    if ($null -eq $previousNodeEnv) {
      Remove-Item Env:NODE_ENV -ErrorAction SilentlyContinue
    } else {
      $env:NODE_ENV = $previousNodeEnv
    }
  }
}

function Assert-NoPrivateEcho {
  param([string]$Text)
  Assert-True (-not $Text.Contains($privateSentinel)) "shared output echoed expected text"
  Assert-True (-not $Text.Contains($tempRoot)) "shared output echoed a temp path"
  Assert-True (-not $Text.Contains("fixture-audio.bin")) "shared output echoed a filename"
  Assert-True (-not $Text.Contains("SWORD_PREPARED_SAMPLE_EXPECTED_TEXT")) "shared output echoed a private environment name"
}

function Assert-ExpectedAuthorityFailure {
  param([string]$Name)
  $run = Invoke-Controller
  Assert-True ($run.code -ne 0) "$Name should fail"
  $result = $run.text | ConvertFrom-Json
  Assert-True ($result.blocker_class -ceq "prepared_sample_expected_text_authority_missing_or_invalid") "$Name should use the fixed expected-text blocker"
  Assert-NoPrivateEcho -Text $run.text
}

function Assert-CollectorFailure {
  param([Parameter(Mandatory = $true)][string]$Mode)
  $run = Invoke-Controller -TestEnvironment @{ SWORD_PREPARED_SAMPLE_TEST_COLLECTOR_MODE = $Mode }
  Assert-True ($run.code -ne 0) "$Mode collector result should fail"
  $result = $run.text | ConvertFrom-Json
  Assert-True ($result.blocker_class -ceq "prepared_sample_playback_controller_failed") "$Mode should use the fixed collector blocker"
  Assert-NoPrivateEcho -Text $run.text
}

[System.IO.Directory]::CreateDirectory((Split-Path -Parent $indexPath)) | Out-Null
[System.IO.Directory]::CreateDirectory((Split-Path -Parent $sidecarPath)) | Out-Null
[System.IO.File]::WriteAllBytes($audioPath, [byte[]](1, 2, 3, 4))

$adapterSource = @'
import { writeFileSync } from 'node:fs'

const required = [
  'SWORD_PREPARED_SAMPLE_OPERATOR_URL',
  'SWORD_PREPARED_SAMPLE_AUDIO_PATH',
  'SWORD_PREPARED_SAMPLE_EXPECTED_TEXT',
  'SWORD_PREPARED_SAMPLE_LOCALE',
  'SWORD_PREPARED_SAMPLE_LOCK_CLASS',
  'SWORD_PREPARED_SAMPLE_ATTEMPT_COUNT',
  'SWORD_PREPARED_SAMPLE_AUDIO_ROUTE_CLASS',
  'SWORD_PREPARED_SAMPLE_INTEGRATED_PRESENTATION',
]
if (!required.every((key) => process.env[key])) process.exit(2)
const forbidden = [
  'SWORD_PREPARED_SAMPLE_UNSAFE_MARKER',
  'PRIVATE_TOKEN',
  'HTTPS_PROXY',
  'NODE_OPTIONS',
]
if (forbidden.some((key) => process.env[key])) process.exit(6)
const operatorUrl = new URL(process.env.SWORD_PREPARED_SAMPLE_OPERATOR_URL)
if (operatorUrl.pathname !== '/operator/prepared-sample-stt/') process.exit(3)
const attemptCount = Number(process.env.SWORD_PREPARED_SAMPLE_ATTEMPT_COUNT)
const audioRouteClass = process.env.SWORD_PREPARED_SAMPLE_AUDIO_ROUTE_CLASS
if (audioRouteClass === 'system_default' && !process.env.SWORD_PREPARED_SAMPLE_FFPLAY_PATH) process.exit(4)
const integratedPresentation = operatorUrl.searchParams.get('integrated_presentation') === '1'
const integratedEnvironment = process.env.SWORD_PREPARED_SAMPLE_INTEGRATED_PRESENTATION === 'true'
if (integratedPresentation !== integratedEnvironment) process.exit(5)
if (integratedPresentation !== (attemptCount === 1 && audioRouteClass === 'installed_virtual_cable_pair_v1')) process.exit(5)
const stopSignals = ['', 'completed_exactly_one_attempt', 'completed_exactly_two_attempts', 'completed_exactly_three_attempts', 'completed_exactly_four_attempts', 'completed_exactly_five_attempts']
if (process.env.SWORD_PREPARED_SAMPLE_TEST_CHILD_PID_FILE) {
  writeFileSync(process.env.SWORD_PREPARED_SAMPLE_TEST_CHILD_PID_FILE, String(process.pid))
}
const result = {
  schema_version: 'prepared_sample_browser_stt_playback.v1',
  controller_status: 'completed',
  controller_stop_signal: stopSignals[attemptCount],
  attempt_count: attemptCount,
  playback_start_count: attemptCount,
  playback_exit_zero_count: attemptCount,
  result_event_count: attemptCount,
  final_result_count: attemptCount,
  content_match_stability_class: attemptCount === 5 ? 'stable_positive' : 'bounded_attempt_set_positive',
  blocker_class: null,
  cleanup_class: 'browser_closed_or_external_preserved_server_stopped_or_external_preserved_playback_processes_exited_temp_resources_deleted_volume_not_changed',
  system_volume_restore_class: 'not_changed',
  raw_audio_shared: false,
  raw_path_shared: false,
  raw_text_shared: false,
  private_environment_shared: false,
  user_heard_proven: false,
  turn_input_materialized: false,
}
switch (process.env.SWORD_PREPARED_SAMPLE_TEST_COLLECTOR_MODE) {
  case 'extra_field':
    result.extra = 'sentinel'
    break
  case 'count_as_string':
    result.attempt_count = '5'
    break
  case 'safety_true':
    result.raw_text_shared = true
    break
  case 'contradictory_completed':
    result.blocker_class = 'cleanup_incomplete'
    result.cleanup_class = 'cleanup_incomplete'
    break
  case 'completed_nonzero_exit':
    process.exitCode = 7
    break
}
console.log(JSON.stringify(result))
'@
$adapterSource | Set-Content -LiteralPath $adapterPath -Encoding utf8NoBOM

try {
  Write-Index
  Write-Sidecar -Value (New-ValidSidecar)
  $validRun = Invoke-Controller
  Assert-True ($validRun.code -eq 0) "valid controller fixture should pass"
  $validResult = $validRun.text | ConvertFrom-Json
  Assert-True ($validResult.controller_status -ceq "completed") "valid controller should complete"
  Assert-True ($validResult.attempt_count -eq 5) "valid controller should retain five attempts"
  Assert-True ($validResult.final_result_count -eq 5) "valid controller should retain five final results"
  Assert-NoPrivateEcho -Text $validRun.text
  Assert-True (-not (Test-Path -LiteralPath (Join-Path $tempRoot ".cache\prepared-sample-browser-stt-playback-controller.lock"))) "valid controller should release its lock"

  $integratedRun = Invoke-Controller `
    -AttemptCount 1 `
    -AudioRouteClass "installed_virtual_cable_pair_v1" `
    -IntegratedPresentation
  Assert-True ($integratedRun.code -eq 0) "integrated controller fixture should pass"
  $integratedResult = $integratedRun.text | ConvertFrom-Json
  Assert-True ($integratedResult.attempt_count -eq 1) "integrated controller should run exactly one attempt"
  Assert-True ($integratedResult.playback_start_count -eq 1) "integrated controller should start exactly one playback"
  Assert-True ($integratedResult.final_result_count -eq 1) "integrated controller should accept exactly one final"
  Assert-True ($integratedResult.controller_stop_signal -ceq "completed_exactly_one_attempt") "integrated controller should use the fixed single-attempt stop signal"
  Assert-NoPrivateEcho -Text $integratedRun.text

  $twoAttemptRun = Invoke-Controller -AttemptCount 2
  Assert-True ($twoAttemptRun.code -eq 0) "bounded component count 2 should pass"
  $twoAttemptResult = $twoAttemptRun.text | ConvertFrom-Json
  Assert-True ($twoAttemptResult.attempt_count -eq 2) "bounded component count should reach the collector"

  $minimalEnvironmentRun = Invoke-Controller -TestEnvironment @{
    SWORD_PREPARED_SAMPLE_UNSAFE_MARKER = "must-not-cross"
    PRIVATE_TOKEN = "must-not-cross"
    HTTPS_PROXY = "http://must-not-cross.invalid"
    NODE_OPTIONS = "--no-warnings"
  }
  Assert-True ($minimalEnvironmentRun.code -eq 0) "minimal child environment should exclude arbitrary, token, proxy, and NODE_OPTIONS values"
  Assert-NoPrivateEcho -Text $minimalEnvironmentRun.text

  foreach ($invalidAttemptCount in @(0, 6)) {
    $invalidCountRun = Invoke-Controller -AttemptCount $invalidAttemptCount
    Assert-True ($invalidCountRun.code -ne 0) "invalid attempt count $invalidAttemptCount should fail"
    $invalidCountResult = $invalidCountRun.text | ConvertFrom-Json
    Assert-True ($invalidCountResult.blocker_class -ceq "prepared_sample_playback_controller_configuration_invalid") "invalid attempt count should use the fixed configuration blocker"
    Assert-NoPrivateEcho -Text $invalidCountRun.text
  }
  $invalidIntegratedCountRun = Invoke-Controller -AttemptCount 2 -AudioRouteClass "installed_virtual_cable_pair_v1"
  Assert-True ($invalidIntegratedCountRun.code -ne 0) "virtual-pair integrated route should reject more than one attempt"
  Assert-True (($invalidIntegratedCountRun.text | ConvertFrom-Json).blocker_class -ceq "prepared_sample_playback_controller_configuration_invalid") "invalid integrated count should use the fixed configuration blocker"
  $pairWithoutMarkerRun = Invoke-Controller -AttemptCount 1 -AudioRouteClass "installed_virtual_cable_pair_v1"
  Assert-True ($pairWithoutMarkerRun.code -ne 0) "virtual pair without integrated marker should fail"
  Assert-True (($pairWithoutMarkerRun.text | ConvertFrom-Json).blocker_class -ceq "prepared_sample_playback_controller_configuration_invalid") "virtual pair without marker should use the fixed configuration blocker"
  $singleSystemRun = Invoke-Controller -AttemptCount 1
  Assert-True ($singleSystemRun.code -ne 0) "system-default single attempt should fail"
  Assert-True (($singleSystemRun.text | ConvertFrom-Json).blocker_class -ceq "prepared_sample_playback_controller_configuration_invalid") "system-default single attempt should use the fixed configuration blocker"
  $invalidPresentationRun = Invoke-Controller -IntegratedPresentation
  Assert-True ($invalidPresentationRun.code -ne 0) "presentation marker should reject the default route"
  Assert-True (($invalidPresentationRun.text | ConvertFrom-Json).blocker_class -ceq "prepared_sample_playback_controller_configuration_invalid") "invalid presentation marker should use the fixed configuration blocker"

  $invalidAssetId = "C:\private\UNTRUSTED_ASSET_SENTINEL.wav"
  $invalidAssetRun = Invoke-Controller -AssetId $invalidAssetId
  Assert-True ($invalidAssetRun.code -ne 0) "path-like asset id should fail"
  $invalidAssetResult = $invalidAssetRun.text | ConvertFrom-Json
  Assert-True ($invalidAssetResult.blocker_class -ceq "prepared_sample_index_or_file_mismatch") "path-like asset id should use the fixed index blocker"
  Assert-True ($null -eq $invalidAssetResult.selected_asset_id) "unvalidated asset id should not be reflected"
  Assert-True (-not $invalidAssetRun.text.Contains($invalidAssetId)) "path-like asset id should not be echoed"

  foreach ($collectorMode in @(
    "extra_field",
    "count_as_string",
    "safety_true",
    "contradictory_completed"
  )) {
    Assert-CollectorFailure -Mode $collectorMode
  }

  $childPidPath = Join-Path $tempRoot "completed-nonzero-child.pid"
  $completedNonzeroRun = Invoke-Controller -TestEnvironment @{
    SWORD_PREPARED_SAMPLE_TEST_COLLECTOR_MODE = "completed_nonzero_exit"
    SWORD_PREPARED_SAMPLE_TEST_CHILD_PID_FILE = $childPidPath
  }
  Assert-True ($completedNonzeroRun.code -ne 0) "completed collector JSON with nonzero child exit should fail"
  $completedNonzeroResult = $completedNonzeroRun.text | ConvertFrom-Json
  Assert-True ($completedNonzeroResult.controller_status -ceq "error") "nonzero child exit should replace the completed collector status"
  Assert-True ($completedNonzeroResult.blocker_class -ceq "prepared_sample_playback_controller_failed") "nonzero child exit should use the fixed controller blocker"
  Assert-True (Test-Path -LiteralPath $childPidPath -PathType Leaf) "nonzero child fixture should record its owned PID"
  $completedNonzeroPid = [int](Get-Content -Raw -LiteralPath $childPidPath)
  Assert-True ($null -eq (Get-Process -Id $completedNonzeroPid -ErrorAction SilentlyContinue)) "nonzero child should be absent before the Parent result returns"
  Assert-True (-not (Test-Path -LiteralPath (Join-Path $tempRoot ".cache\prepared-sample-browser-stt-playback-controller.lock"))) "nonzero child exit should still release the owned lock"
  Assert-NoPrivateEcho -Text $completedNonzeroRun.text

  $childCleanupRun = Invoke-Controller -TestEnvironment @{
    SWORD_PREPARED_SAMPLE_TEST_CHILD_CLEANUP_FAILURE = "true"
  }
  Assert-True ($childCleanupRun.code -ne 0) "unverified child cleanup should fail"
  $childCleanupResult = $childCleanupRun.text | ConvertFrom-Json
  Assert-True ($childCleanupResult.blocker_class -ceq "cleanup_incomplete") "unverified child cleanup should use the fixed cleanup blocker"
  Assert-True ($childCleanupResult.cleanup_class -ceq "cleanup_incomplete") "unverified child cleanup should not report convergence"
  Assert-NoPrivateEcho -Text $childCleanupRun.text

  $scalarBoundaryText = [char]::ConvertFromUtf32(0x1F600) * 512
  Write-Sidecar -Value ([ordered]@{
    schema_version = "prepared_sample_expected_text.v1"
    entries = @((New-ValidEntry -ExpectedText $scalarBoundaryText))
  })
  $scalarBoundaryRun = Invoke-Controller
  Assert-True ($scalarBoundaryRun.code -eq 0) "512 Unicode scalar values should pass"
  Assert-True (-not $scalarBoundaryRun.text.Contains($scalarBoundaryText)) "shared output echoed scalar-boundary expected text"

  Remove-Item -LiteralPath $sidecarPath -Force
  Assert-ExpectedAuthorityFailure -Name "missing sidecar"

  $invalidCases = @(
    [PSCustomObject]@{
      name = "wrong schema"
      value = [ordered]@{ schema_version = "wrong"; entries = @((New-ValidEntry)) }
    },
    [PSCustomObject]@{
      name = "entries is not an array"
      value = [ordered]@{ schema_version = "prepared_sample_expected_text.v1"; entries = (New-ValidEntry) }
    },
    [PSCustomObject]@{
      name = "duplicate sample"
      value = [ordered]@{ schema_version = "prepared_sample_expected_text.v1"; entries = @((New-ValidEntry), (New-ValidEntry)) }
    },
    [PSCustomObject]@{
      name = "extra top field"
      value = [ordered]@{ schema_version = "prepared_sample_expected_text.v1"; entries = @((New-ValidEntry)); extra = "sentinel" }
    },
    [PSCustomObject]@{
      name = "extra entry field"
      value = [ordered]@{ schema_version = "prepared_sample_expected_text.v1"; entries = @([ordered]@{ sample_id = "voice.hello"; text_provenance_class = "prepared_local_sample_set"; locale = "ja-JP"; expected_text = $privateSentinel; shared_publication_class = "local_only_not_shared"; extra = "sentinel" }) }
    },
    [PSCustomObject]@{
      name = "blank text"
      value = [ordered]@{ schema_version = "prepared_sample_expected_text.v1"; entries = @([ordered]@{ sample_id = "voice.hello"; text_provenance_class = "prepared_local_sample_set"; locale = "ja-JP"; expected_text = " "; shared_publication_class = "local_only_not_shared" }) }
    },
    [PSCustomObject]@{
      name = "text is not a string"
      value = [ordered]@{ schema_version = "prepared_sample_expected_text.v1"; entries = @([ordered]@{ sample_id = "voice.hello"; text_provenance_class = "prepared_local_sample_set"; locale = "ja-JP"; expected_text = 123; shared_publication_class = "local_only_not_shared" }) }
    },
    [PSCustomObject]@{
      name = "oversized text"
      value = [ordered]@{ schema_version = "prepared_sample_expected_text.v1"; entries = @([ordered]@{ sample_id = "voice.hello"; text_provenance_class = "prepared_local_sample_set"; locale = "ja-JP"; expected_text = ("x" * 513); shared_publication_class = "local_only_not_shared" }) }
    },
    [PSCustomObject]@{
      name = "control character"
      value = [ordered]@{ schema_version = "prepared_sample_expected_text.v1"; entries = @([ordered]@{ sample_id = "voice.hello"; text_provenance_class = "prepared_local_sample_set"; locale = "ja-JP"; expected_text = "line`nbreak"; shared_publication_class = "local_only_not_shared" }) }
    },
    [PSCustomObject]@{
      name = "wrong provenance"
      value = [ordered]@{ schema_version = "prepared_sample_expected_text.v1"; entries = @([ordered]@{ sample_id = "voice.hello"; text_provenance_class = "generated"; locale = "ja-JP"; expected_text = $privateSentinel; shared_publication_class = "local_only_not_shared" }) }
    },
    [PSCustomObject]@{
      name = "wrong locale"
      value = [ordered]@{ schema_version = "prepared_sample_expected_text.v1"; entries = @([ordered]@{ sample_id = "voice.hello"; text_provenance_class = "prepared_local_sample_set"; locale = "bad_locale"; expected_text = $privateSentinel; shared_publication_class = "local_only_not_shared" }) }
    },
    [PSCustomObject]@{
      name = "wrong publication"
      value = [ordered]@{ schema_version = "prepared_sample_expected_text.v1"; entries = @([ordered]@{ sample_id = "voice.hello"; text_provenance_class = "prepared_local_sample_set"; locale = "ja-JP"; expected_text = $privateSentinel; shared_publication_class = "shared" }) }
    },
    [PSCustomObject]@{
      name = "sample absent from index"
      value = [ordered]@{ schema_version = "prepared_sample_expected_text.v1"; entries = @((New-ValidEntry -SampleId "voice.missing")) }
    }
  )

  foreach ($case in $invalidCases) {
    Write-Sidecar -Value $case.value
    Assert-ExpectedAuthorityFailure -Name $case.name
  }

  [System.IO.File]::WriteAllText($sidecarPath, " " * ((256 * 1024) + 1))
  Assert-ExpectedAuthorityFailure -Name "oversized sidecar file"

  Write-Index -Kind "video"
  Write-Sidecar -Value (New-ValidSidecar)
  Assert-ExpectedAuthorityFailure -Name "non-audio media kind"
  Write-Index

  Write-Sidecar -Value (New-ValidSidecar)
  $lockDirectory = Join-Path $tempRoot ".cache"
  [System.IO.Directory]::CreateDirectory($lockDirectory) | Out-Null
  $lockPath = Join-Path $lockDirectory "prepared-sample-browser-stt-playback-controller.lock"
  $heldLock = [System.IO.File]::Open($lockPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
  try {
    $lockRun = Invoke-Controller
    Assert-True ($lockRun.code -ne 0) "held lock should fail"
    $lockResult = $lockRun.text | ConvertFrom-Json
    Assert-True ($lockResult.blocker_class -ceq "controller_lock_held") "held lock should use fixed blocker"
    Assert-NoPrivateEcho -Text $lockRun.text
  } finally {
    $heldLock.Dispose()
    Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue
  }

  [System.IO.File]::WriteAllText($lockPath, "preexisting")
  try {
    $preexistingLockRun = Invoke-Controller
    Assert-True ($preexistingLockRun.code -ne 0) "preexisting lock should fail"
    $preexistingLockResult = $preexistingLockRun.text | ConvertFrom-Json
    Assert-True ($preexistingLockResult.blocker_class -ceq "controller_lock_held") "preexisting lock should use fixed blocker"
    Assert-True (Test-Path -LiteralPath $lockPath -PathType Leaf) "controller should retain a lock it did not acquire"
    Assert-NoPrivateEcho -Text $preexistingLockRun.text
  } finally {
    Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue
  }

  $lockCleanupRun = Invoke-Controller -TestEnvironment @{
    SWORD_PREPARED_SAMPLE_TEST_LOCK_CLEANUP_FAILURE = "true"
  }
  Assert-True ($lockCleanupRun.code -ne 0) "unverified owned lock cleanup should fail"
  $lockCleanupResult = $lockCleanupRun.text | ConvertFrom-Json
  Assert-True ($lockCleanupResult.blocker_class -ceq "cleanup_incomplete") "unverified owned lock cleanup should use the fixed cleanup blocker"
  Assert-True ($lockCleanupResult.cleanup_class -ceq "cleanup_incomplete") "unverified owned lock cleanup should not report convergence"
  Assert-True (Test-Path -LiteralPath $lockPath -PathType Leaf) "failed owned lock cleanup should retain the lock"
  Assert-NoPrivateEcho -Text $lockCleanupRun.text
  Remove-Item -LiteralPath $lockPath -Force

  Write-Output "status=ok"
  Write-Output "assertions=$assertions"
  Write-Output "runtime_actions=0"
  Write-Output "raw_private_publication_flags=false"
} finally {
  Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
