param(
  [ValidateSet("Synthetic", "Browser", "Config")]
  [string]$Mode = "Synthetic",

  [string]$ConfigPath = "",
  [string]$OutputDir = "",

  [string]$Url = "http://127.0.0.1:18880/projection-visual/?mode=passive&visualTest=self-mirror-baseline",
  [ValidateSet("none", "context-nod", "dance")]
  [string]$Trigger = "none",

  [int]$ViewportWidth = 1920,
  [int]$ViewportHeight = 1080,
  [double]$SampleRateFps = 8,
  [int]$DurationMs = 6000,
  [int]$SettleMs = 900,
  [int]$ReadyTimeoutMs = 15000,
  [int]$TriggerAtMs = 700,
  [string]$BrowserExecutable = "",

  [string]$AnalysisRunId = "vismot_run_rr003_self_mirror_light_001",
  [string]$ScenarioId = "rr003.visible_motion.self_mirror.light.v0",
  [string]$MotionEventId = "mot_evt_rr003_self_mirror_light_001",
  [string]$StimulusInstanceId = "mot_inst_rr003_self_mirror_light_001",
  [string]$DriverResultId = "mot_drv_rr003_self_mirror_light_001",
  [string]$SourceRefId = "redacted_self_mirror_light_001",

  [switch]$Headed,
  [switch]$SkipSelfMirrorReady,
  [switch]$KeepRawFrames
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent $scriptDir
$defaultAnalysisRunId = "vismot_run_rr003_self_mirror_light_001"
$defaultScenarioId = "rr003.visible_motion.self_mirror.light.v0"
$defaultMotionEventId = "mot_evt_rr003_self_mirror_light_001"
$defaultStimulusInstanceId = "mot_inst_rr003_self_mirror_light_001"
$defaultDriverResultId = "mot_drv_rr003_self_mirror_light_001"
$defaultSourceRefId = "redacted_self_mirror_light_001"

if ($Mode -eq "Browser") {
  if ($AnalysisRunId -eq $defaultAnalysisRunId) {
    $AnalysisRunId = "vismot_run_rr003_self_mirror_browser_001"
  }
  if ($ScenarioId -eq $defaultScenarioId) {
    $ScenarioId = "rr003.visible_motion.self_mirror.browser.v0"
  }
  if ($MotionEventId -eq $defaultMotionEventId) {
    $MotionEventId = "mot_evt_rr003_self_mirror_browser_001"
  }
  if ($StimulusInstanceId -eq $defaultStimulusInstanceId) {
    $StimulusInstanceId = "mot_inst_rr003_self_mirror_browser_001"
  }
  if ($DriverResultId -eq $defaultDriverResultId) {
    $DriverResultId = "mot_drv_rr003_self_mirror_browser_001"
  }
  if ($SourceRefId -eq $defaultSourceRefId) {
    $SourceRefId = "redacted_browser_self_mirror_001"
  }
}

function Resolve-LocalPath {
  param([Parameter(Mandatory = $true)][string]$Path)
  if ([System.IO.Path]::IsPathRooted($Path)) {
    return [System.IO.Path]::GetFullPath($Path)
  }
  return [System.IO.Path]::GetFullPath((Join-Path (Get-Location) $Path))
}

function New-DefaultOutputDir {
  $stamp = [DateTimeOffset]::Now.ToString("yyyyMMdd-HHmmss")
  return Join-Path $repoRoot ".cache\agent-os\self-mirror\$stamp"
}

function New-SelfMirrorWindows {
  param(
    [int]$TriggerStartMs = 700,
    [int]$TotalDurationMs = 6000
  )
  $duration = [Math]::Max(1, $TotalDurationMs)
  $triggerStart = [Math]::Max(1, [Math]::Min($TriggerStartMs, $duration - 1))
  $activeEnd = [Math]::Max($triggerStart + 1, [Math]::Min($duration, $triggerStart + 2100))
  $releaseEnd = [Math]::Max($activeEnd + 1, [Math]::Min($duration, $activeEnd + 1400))
  $settleEnd = [Math]::Max($releaseEnd + 1, $duration)
  return @(
    @{ window_id = "pretrigger"; start_ms = 0; end_ms = $triggerStart },
    @{ window_id = "active"; start_ms = $triggerStart; end_ms = $activeEnd },
    @{ window_id = "release"; start_ms = $activeEnd; end_ms = $releaseEnd },
    @{ window_id = "settle"; start_ms = $releaseEnd; end_ms = $settleEnd }
  )
}

function New-SelfMirrorRois {
  return @(
    @{
      roi_id = "avatar_full"
      kind = "avatar"
      counts_as_avatar_motion = $true
      expected_for_pass = $true
      rect_norm = @{ x = 0.34; y = 0.04; w = 0.34; h = 0.84 }
    },
    @{
      roi_id = "avatar_face_head"
      kind = "avatar"
      counts_as_avatar_motion = $true
      expected_for_pass = $true
      rect_norm = @{ x = 0.43; y = 0.08; w = 0.18; h = 0.26 }
    },
    @{
      roi_id = "avatar_torso"
      kind = "avatar"
      counts_as_avatar_motion = $true
      expected_for_pass = $false
      rect_norm = @{ x = 0.42; y = 0.33; w = 0.20; h = 0.30 }
    },
    @{
      roi_id = "avatar_left_arm"
      kind = "avatar"
      counts_as_avatar_motion = $true
      expected_for_pass = $false
      rect_norm = @{ x = 0.33; y = 0.30; w = 0.14; h = 0.38 }
    },
    @{
      roi_id = "avatar_right_arm"
      kind = "avatar"
      counts_as_avatar_motion = $true
      expected_for_pass = $false
      rect_norm = @{ x = 0.59; y = 0.30; w = 0.14; h = 0.38 }
    },
    @{
      roi_id = "speech_bubble"
      kind = "guard_ui"
      counts_as_avatar_motion = $false
      expected_for_pass = $false
      rect_norm = @{ x = 0.17; y = 0.34; w = 0.34; h = 0.22 }
    },
    @{
      roi_id = "left_hud"
      kind = "guard_ui"
      counts_as_avatar_motion = $false
      expected_for_pass = $false
      rect_norm = @{ x = 0.00; y = 0.00; w = 0.25; h = 0.72 }
    },
    @{
      roi_id = "right_hud"
      kind = "guard_ui"
      counts_as_avatar_motion = $false
      expected_for_pass = $false
      rect_norm = @{ x = 0.75; y = 0.00; w = 0.25; h = 0.72 }
    },
    @{
      roi_id = "input_bar"
      kind = "guard_ui"
      counts_as_avatar_motion = $false
      expected_for_pass = $false
      rect_norm = @{ x = 0.05; y = 0.90; w = 0.90; h = 0.10 }
    },
    @{
      roi_id = "background_fx"
      kind = "guard_background"
      counts_as_avatar_motion = $false
      expected_for_pass = $false
      rect_norm = @{ x = 0.25; y = 0.00; w = 0.09; h = 0.24 }
    }
  )
}

function New-SelfMirrorThresholds {
  return @{
    active_motion_min_score = 0.08
    settle_motion_max_score = 0.06
    min_consecutive_samples = 2
  }
}

function New-SyntheticConfig {
  param([Parameter(Mandatory = $true)][string]$ResolvedOutputDir)
  $frameCount = [Math]::Max(2, [int][Math]::Ceiling(($DurationMs / 1000.0) * $SampleRateFps))
  return @{
    analysis_run_id = $AnalysisRunId
    scenario_id = $ScenarioId
    proof_layer = "no_live_runtime"
    motion_event_id = $MotionEventId
    stimulus_instance_id = $StimulusInstanceId
    driver_result_id = $DriverResultId
    source_ref = @{
      kind = "synthetic_test_frames"
      source_ref_id = $SourceRefId
    }
    sampling = @{
      sample_rate_fps = $SampleRateFps
    }
    synthetic_fixture = @{
      width = $ViewportWidth
      height = $ViewportHeight
      frame_count = $frameCount
      avatar_motion_roi_ids = @("avatar_full", "avatar_face_head", "avatar_torso")
      guard_motion_roi_ids = @("speech_bubble")
      motion_amplitude_px = [Math]::Max(6, [int]($ViewportWidth / 96))
    }
    windows = @(New-SelfMirrorWindows -TriggerStartMs $TriggerAtMs -TotalDurationMs $DurationMs)
    rois = New-SelfMirrorRois
    thresholds = New-SelfMirrorThresholds
  }
}

function Write-Utf8NoBomJson {
  param(
    [Parameter(Mandatory = $true)][object]$Value,
    [Parameter(Mandatory = $true)][string]$Path,
    [int]$Depth = 20
  )
  $json = $Value | ConvertTo-Json -Depth $Depth
  $encoding = [System.Text.UTF8Encoding]::new($false)
  [System.IO.File]::WriteAllText($Path, $json + [Environment]::NewLine, $encoding)
}

function Invoke-VisualAnalyzer {
  param([Parameter(Mandatory = $true)][string]$ResolvedConfigPath)
  $analyzerScript = Join-Path $scriptDir "run-visual-motion-analyzer.ps1"
  & $analyzerScript -ConfigPath $ResolvedConfigPath -OutputDir $resolvedOutputDir -Json
  if ($LASTEXITCODE -ne 0) {
    throw "Self Mirror visual analyzer failed"
  }
}

function Remove-BrowserRawInputs {
  param(
    [Parameter(Mandatory = $true)][string]$ResolvedOutputDir,
    [Parameter(Mandatory = $true)][string]$BrowserConfigPath
  )
  $rawFramesDir = Join-Path $ResolvedOutputDir "raw-browser-frames"
  foreach ($target in @($rawFramesDir, $BrowserConfigPath)) {
    if (-not (Test-Path -LiteralPath $target)) {
      continue
    }
    $resolvedTarget = [System.IO.Path]::GetFullPath($target)
    if (-not $resolvedTarget.StartsWith($ResolvedOutputDir, [System.StringComparison]::OrdinalIgnoreCase)) {
      throw "refusing to delete path outside output directory"
    }
    Remove-Item -LiteralPath $resolvedTarget -Recurse -Force
  }
}

if ([string]::IsNullOrWhiteSpace($OutputDir)) {
  $OutputDir = New-DefaultOutputDir
}
$resolvedOutputDir = Resolve-LocalPath -Path $OutputDir
New-Item -ItemType Directory -Force -Path $resolvedOutputDir | Out-Null

if ($Mode -eq "Synthetic") {
  $resolvedConfigPath = Join-Path $resolvedOutputDir "self_mirror_synthetic_config.json"
  $config = New-SyntheticConfig -ResolvedOutputDir $resolvedOutputDir
  Write-Utf8NoBomJson -Value $config -Path $resolvedConfigPath
  Invoke-VisualAnalyzer -ResolvedConfigPath $resolvedConfigPath
  Write-Host "self_mirror_mode=synthetic"
  Write-Host "raw_frames_shared=false"
  Write-Host "raw_paths_shared=false"
  Write-Host "output_dir=$resolvedOutputDir"
  exit 0
}

if ($Mode -eq "Config") {
  if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    throw "-ConfigPath is required when -Mode Config is used"
  }
  $resolvedConfigPath = Resolve-LocalPath -Path $ConfigPath
  Invoke-VisualAnalyzer -ResolvedConfigPath $resolvedConfigPath
  Write-Host "self_mirror_mode=config"
  Write-Host "raw_frames_shared=false"
  Write-Host "raw_paths_shared=false"
  Write-Host "output_dir=$resolvedOutputDir"
  exit 0
}

$node = Get-Command node -ErrorAction SilentlyContinue
if (-not $node) {
  throw "Node.js is required for Browser mode, but 'node' was not found on PATH."
}

$captureScript = Join-Path $scriptDir "capture-self-mirror-frames.mjs"
$captureArgs = @(
  $captureScript,
  "--url", $Url,
  "--out", $resolvedOutputDir,
  "--width", [string]$ViewportWidth,
  "--height", [string]$ViewportHeight,
  "--sample-rate-fps", [string]$SampleRateFps,
  "--duration-ms", [string]$DurationMs,
  "--settle-ms", [string]$SettleMs,
  "--ready-timeout-ms", [string]$ReadyTimeoutMs,
  "--trigger", $Trigger,
  "--trigger-at-ms", [string]$TriggerAtMs,
  "--analysis-run-id", $AnalysisRunId,
  "--scenario-id", $ScenarioId,
  "--proof-layer", "visible_motion",
  "--motion-event-id", $MotionEventId,
  "--stimulus-instance-id", $StimulusInstanceId,
  "--driver-result-id", $DriverResultId,
  "--source-ref-id", $SourceRefId
)
if (-not [string]::IsNullOrWhiteSpace($BrowserExecutable)) {
  $captureArgs += @("--browser-executable", $BrowserExecutable)
}
if ($Headed) {
  $captureArgs += "--headed"
}
if ($SkipSelfMirrorReady) {
  $captureArgs += "--skip-self-mirror-ready"
}

$browserConfigPath = Join-Path $resolvedOutputDir "self_mirror_browser_config.json"
try {
  & $node.Source @captureArgs
  if ($LASTEXITCODE -ne 0) {
    throw "browser Self Mirror capture failed"
  }

  Invoke-VisualAnalyzer -ResolvedConfigPath $browserConfigPath
}
finally {
  if (-not $KeepRawFrames) {
    Remove-BrowserRawInputs -ResolvedOutputDir $resolvedOutputDir -BrowserConfigPath $browserConfigPath
    Write-Host "raw_frame_cleanup=deleted"
  }
  else {
    Write-Host "raw_frame_cleanup=kept-local-only"
  }
}

Write-Host "self_mirror_mode=browser"
Write-Host "raw_frames_shared=false"
Write-Host "raw_paths_shared=false"
Write-Host "output_dir=$resolvedOutputDir"
