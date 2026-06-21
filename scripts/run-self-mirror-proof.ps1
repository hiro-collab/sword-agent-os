param(
  [ValidateSet("Synthetic", "Browser", "Config")]
  [string]$Mode = "Synthetic",

  [string]$ConfigPath = "",
  [string]$OutputDir = "",
  [string]$Scenario = "context_nod",
  [string]$ScenarioCatalogPath = "",

  [string]$Url = "http://127.0.0.1:18880/projection-visual/?mode=passive&visualTest=self-mirror-baseline",
  [ValidateSet("auto", "none", "context-nod", "dance", "expression-visible")]
  [string]$Trigger = "auto",
  [ValidateSet("default", "full-relaxed")]
  [string]$ExpressionProfile = "default",

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
  [string]$StimulusId = "",
  [string]$StimulusInstanceId = "mot_inst_rr003_self_mirror_light_001",
  [string]$RuntimeResultId = "",
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

function Resolve-LocalPath {
  param([Parameter(Mandatory = $true)][string]$Path)
  if ([System.IO.Path]::IsPathRooted($Path)) {
    return [System.IO.Path]::GetFullPath($Path)
  }
  return [System.IO.Path]::GetFullPath((Join-Path (Get-Location) $Path))
}

function Get-ObjectProperty {
  param(
    [Parameter(Mandatory = $true)][object]$Value,
    [Parameter(Mandatory = $true)][string]$Name,
    [object]$Default = $null
  )
  if ($null -ne $Value -and $Value.PSObject.Properties.Name -contains $Name) {
    return $Value.$Name
  }
  return $Default
}

function Get-SelfMirrorScenario {
  param(
    [Parameter(Mandatory = $true)][string]$CatalogPath,
    [Parameter(Mandatory = $true)][string]$ScenarioKey
  )
  if (-not (Test-Path -LiteralPath $CatalogPath -PathType Leaf)) {
    throw "Self Mirror scenario catalog not found"
  }
  $catalog = Get-Content -Raw -LiteralPath $CatalogPath | ConvertFrom-Json
  $scenarioNode = Get-ObjectProperty -Value $catalog.scenarios -Name $ScenarioKey
  if ($null -eq $scenarioNode) {
    $available = ($catalog.scenarios.PSObject.Properties.Name | Sort-Object) -join ", "
    throw "Unknown Self Mirror scenario '$ScenarioKey'. Available scenarios: $available"
  }
  return $scenarioNode
}

function New-DefaultOutputDir {
  $stamp = [DateTimeOffset]::Now.ToString("yyyyMMdd-HHmmss")
  return Join-Path $repoRoot ".cache\agent-os\self-mirror\$stamp"
}

function Write-OutputPackageLocation {
  param([Parameter(Mandatory = $true)][string]$ResolvedOutputDir)
  $outputLabel = Split-Path -Leaf $ResolvedOutputDir
  $artifacts = @(
    "self_mirror_metric_summary.json",
    "visual_motion_summary.json",
    "visual_motion_roi_timeseries.csv",
    "visual_motion_chart.html",
    "result.md",
    "manifest.json"
  )
  $vrmTelemetrySummaryPath = Join-Path $ResolvedOutputDir "vrm_model_telemetry_summary.json"
  if (Test-Path -LiteralPath $vrmTelemetrySummaryPath -PathType Leaf) {
    $artifacts += "vrm_model_telemetry_summary.json"
  }
  Write-Host "output_dir=local-redacted"
  Write-Host "output_label=$outputLabel"
  Write-Host "artifacts=$($artifacts -join ',')"
}

function New-SelfMirrorWindows {
  param(
    [Parameter(Mandatory = $true)][object]$ScenarioDefinition,
    [int]$TriggerStartMs = 700,
    [int]$TotalDurationMs = 6000
  )
  $duration = [Math]::Max(1, $TotalDurationMs)
  $triggerStart = [Math]::Max(1, [Math]::Min($TriggerStartMs, $duration - 1))
  $windowTemplate = Get-ObjectProperty -Value $ScenarioDefinition -Name "window_template" -Default ([pscustomobject]@{})
  $activeDuration = [int](Get-ObjectProperty -Value $windowTemplate -Name "active_duration_ms" -Default 2100)
  $releaseDuration = [int](Get-ObjectProperty -Value $windowTemplate -Name "release_duration_ms" -Default 1400)
  $lateWatchDuration = [int](Get-ObjectProperty -Value $windowTemplate -Name "late_watch_duration_ms" -Default 0)
  $activeEnd = [Math]::Max($triggerStart + 1, [Math]::Min($duration, $triggerStart + $activeDuration))
  $releaseEnd = [Math]::Max($activeEnd + 1, [Math]::Min($duration, $activeEnd + $releaseDuration))
  $windows = @(
    @{ window_id = "pretrigger"; start_ms = 0; end_ms = $triggerStart },
    @{ window_id = "active"; start_ms = $triggerStart; end_ms = $activeEnd },
    @{ window_id = "release"; start_ms = $activeEnd; end_ms = $releaseEnd }
  )
  $settleStart = $releaseEnd
  if ($lateWatchDuration -gt 0 -and $releaseEnd -lt $duration) {
    $lateEnd = [Math]::Max($releaseEnd + 1, [Math]::Min($duration, $releaseEnd + $lateWatchDuration))
    $windows += @{ window_id = "late_watch"; start_ms = $releaseEnd; end_ms = $lateEnd }
    $settleStart = $lateEnd
  }
  $settleEnd = [Math]::Max($settleStart + 1, $duration)
  $windows += @{ window_id = "settle"; start_ms = $settleStart; end_ms = $settleEnd }
  return $windows
}

function New-SelfMirrorRois {
  param([Parameter(Mandatory = $true)][object]$ScenarioDefinition)
  return @(Get-ObjectProperty -Value $ScenarioDefinition -Name "rois" -Default @())
}

function New-SelfMirrorThresholds {
  param([Parameter(Mandatory = $true)][object]$ScenarioDefinition)
  return Get-ObjectProperty -Value $ScenarioDefinition -Name "thresholds" -Default @{
    active_motion_min_score = 0.08
    settle_motion_max_score = 0.06
    min_consecutive_samples = 2
    threshold_too_strict_ratio = 0.75
  }
}

function New-SyntheticConfig {
  param(
    [Parameter(Mandatory = $true)][string]$ResolvedOutputDir,
    [Parameter(Mandatory = $true)][object]$ScenarioDefinition
  )
  $frameCount = [Math]::Max(2, [int][Math]::Ceiling(($DurationMs / 1000.0) * $SampleRateFps))
  $fixtureTemplate = Get-ObjectProperty -Value $ScenarioDefinition -Name "synthetic_fixture" -Default ([pscustomobject]@{})
  $minimumAmplitude = [int](Get-ObjectProperty -Value $fixtureTemplate -Name "motion_amplitude_px_min" -Default 6)
  return @{
    analysis_run_id = $AnalysisRunId
    scenario_id = $ScenarioId
    trigger = $triggerValue
    scenario = @{
      scenario_key = [string](Get-ObjectProperty -Value $ScenarioDefinition -Name "scenario_key" -Default $Scenario)
      label = [string](Get-ObjectProperty -Value $ScenarioDefinition -Name "label" -Default $Scenario)
      expected_motion = [string](Get-ObjectProperty -Value $ScenarioDefinition -Name "expected_motion" -Default "avatar_motion")
      runtime_join_required = $false
    }
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
      avatar_motion_roi_ids = @(Get-ObjectProperty -Value $fixtureTemplate -Name "avatar_motion_roi_ids" -Default @("avatar_full"))
      guard_motion_roi_ids = @(Get-ObjectProperty -Value $fixtureTemplate -Name "guard_motion_roi_ids" -Default @())
      motion_amplitude_px = [Math]::Max($minimumAmplitude, [int]($ViewportWidth / 96))
    }
    windows = @(New-SelfMirrorWindows -ScenarioDefinition $ScenarioDefinition -TriggerStartMs $TriggerAtMs -TotalDurationMs $DurationMs)
    rois = @(New-SelfMirrorRois -ScenarioDefinition $ScenarioDefinition)
    thresholds = New-SelfMirrorThresholds -ScenarioDefinition $ScenarioDefinition
    raw_frames_retained = $false
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

function Set-JsonObjectProperty {
  param(
    [Parameter(Mandatory = $true)][object]$Object,
    [Parameter(Mandatory = $true)][string]$Name,
    [object]$Value
  )
  if ($Object.PSObject.Properties.Name -contains $Name) {
    $Object.$Name = $Value
  }
  else {
    $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value
  }
}

function Update-BrowserAnalyzerConfig {
  param(
    [Parameter(Mandatory = $true)][string]$BrowserConfigPath,
    [Parameter(Mandatory = $true)][string]$CaptureManifestPath,
    [Parameter(Mandatory = $true)][object]$ScenarioDefinition,
    [Parameter(Mandatory = $true)][string]$TriggerValue,
    [Parameter(Mandatory = $true)][bool]$RetainRawFrames
  )

  $config = Get-Content -Raw -LiteralPath $BrowserConfigPath | ConvertFrom-Json
  Set-JsonObjectProperty -Object $config -Name "scenario_id" -Value $ScenarioId
  Set-JsonObjectProperty -Object $config -Name "trigger" -Value $TriggerValue
  Set-JsonObjectProperty -Object $config -Name "windows" -Value @(New-SelfMirrorWindows -ScenarioDefinition $ScenarioDefinition -TriggerStartMs $TriggerAtMs -TotalDurationMs $DurationMs)
  Set-JsonObjectProperty -Object $config -Name "rois" -Value @(New-SelfMirrorRois -ScenarioDefinition $ScenarioDefinition)
  Set-JsonObjectProperty -Object $config -Name "thresholds" -Value (New-SelfMirrorThresholds -ScenarioDefinition $ScenarioDefinition)
  Set-JsonObjectProperty -Object $config -Name "activation_sampling" -Value "event_driven"
  Set-JsonObjectProperty -Object $config -Name "evidence_export" -Value "verification_capture"
  Set-JsonObjectProperty -Object $config -Name "scenario" -Value @{
    scenario_key = [string](Get-ObjectProperty -Value $ScenarioDefinition -Name "scenario_key" -Default $Scenario)
    label = [string](Get-ObjectProperty -Value $ScenarioDefinition -Name "label" -Default $Scenario)
    expected_motion = [string](Get-ObjectProperty -Value $ScenarioDefinition -Name "expected_motion" -Default "avatar_motion")
    runtime_join_required = [bool](Get-ObjectProperty -Value $ScenarioDefinition -Name "runtime_join_required" -Default $false)
  }
  Set-JsonObjectProperty -Object $config -Name "raw_frames_retained" -Value $RetainRawFrames

  if (Test-Path -LiteralPath $CaptureManifestPath -PathType Leaf) {
    $captureManifest = Get-Content -Raw -LiteralPath $CaptureManifestPath | ConvertFrom-Json
    if ($captureManifest.PSObject.Properties.Name -contains "self_mirror_ready") {
      Set-JsonObjectProperty -Object $config -Name "capture_ready" -Value $captureManifest.self_mirror_ready
    }
    if ($captureManifest.PSObject.Properties.Name -contains "runtime_join") {
      Set-JsonObjectProperty -Object $config -Name "runtime_join" -Value $captureManifest.runtime_join
    }
    if ($captureManifest.PSObject.Properties.Name -contains "target_identity") {
      Set-JsonObjectProperty -Object $config -Name "target_identity" -Value $captureManifest.target_identity
    }
    if (
      $captureManifest.PSObject.Properties.Name -contains "trigger" -and
      $null -ne $captureManifest.trigger -and
      $captureManifest.trigger.PSObject.Properties.Name -contains "stimulus_id"
    ) {
      $manifestStimulusId = [string]$captureManifest.trigger.stimulus_id
      if (-not [string]::IsNullOrWhiteSpace($manifestStimulusId)) {
        Set-JsonObjectProperty -Object $config -Name "stimulus_id" -Value $manifestStimulusId
        if ($config.PSObject.Properties.Name -contains "runtime_join") {
          Set-JsonObjectProperty -Object $config.runtime_join -Name "stimulus_id" -Value $manifestStimulusId
        }
      }
    }
    if ($captureManifest.PSObject.Properties.Name -contains "event_timeline") {
      Set-JsonObjectProperty -Object $config -Name "event_timeline" -Value $captureManifest.event_timeline
    }
    if ($captureManifest.PSObject.Properties.Name -contains "projection_visual_diagnostics") {
      Set-JsonObjectProperty -Object $config -Name "projection_visual_diagnostics" -Value $captureManifest.projection_visual_diagnostics
    }
  }

  Write-Utf8NoBomJson -Value $config -Path $BrowserConfigPath
}

if ([string]::IsNullOrWhiteSpace($ScenarioCatalogPath)) {
  $ScenarioCatalogPath = Join-Path $repoRoot "runtime\visual-motion-analyzer\self-mirror-scenarios.json"
}
$resolvedScenarioCatalogPath = Resolve-LocalPath -Path $ScenarioCatalogPath
$scenarioDefinition = Get-SelfMirrorScenario -CatalogPath $resolvedScenarioCatalogPath -ScenarioKey $Scenario
$scenarioTrigger = [string](Get-ObjectProperty -Value $scenarioDefinition -Name "trigger" -Default "none")
$triggerValue = $Trigger
if ($Trigger -eq "auto") {
  $triggerValue = $scenarioTrigger
}
if ($Mode -eq "Browser" -and $triggerValue -notin @("none", "context-nod", "dance", "expression-visible")) {
  throw "Scenario '$Scenario' resolved to unsupported Browser trigger '$triggerValue'"
}

$modeSlug = "synthetic"
if ($Mode -eq "Browser") {
  $modeSlug = "browser"
}
$safeScenarioSlug = ($Scenario -replace '[^A-Za-z0-9]+', '_').Trim("_").ToLowerInvariant()
if ([string]::IsNullOrWhiteSpace($safeScenarioSlug)) {
  $safeScenarioSlug = "scenario"
}
if ($AnalysisRunId -eq $defaultAnalysisRunId) {
  $AnalysisRunId = "vismot_run_rr003_self_mirror_${safeScenarioSlug}_${modeSlug}_001"
}
if ($ScenarioId -eq $defaultScenarioId) {
  $ScenarioId = [string](Get-ObjectProperty -Value $scenarioDefinition -Name "scenario_id" -Default $defaultScenarioId)
}
if ($MotionEventId -eq $defaultMotionEventId) {
  $MotionEventId = "mot_evt_rr003_self_mirror_${safeScenarioSlug}_${modeSlug}_001"
}
if ($StimulusInstanceId -eq $defaultStimulusInstanceId) {
  $StimulusInstanceId = "mot_inst_rr003_self_mirror_${safeScenarioSlug}_${modeSlug}_001"
}
if ($DriverResultId -eq $defaultDriverResultId) {
  $DriverResultId = "mot_drv_rr003_self_mirror_${safeScenarioSlug}_${modeSlug}_001"
}
if ($SourceRefId -eq $defaultSourceRefId) {
  $SourceRefId = "redacted_self_mirror_${safeScenarioSlug}_${modeSlug}_001"
}

if ([string]::IsNullOrWhiteSpace($OutputDir)) {
  $OutputDir = New-DefaultOutputDir
}
$resolvedOutputDir = Resolve-LocalPath -Path $OutputDir
New-Item -ItemType Directory -Force -Path $resolvedOutputDir | Out-Null

if ($Mode -eq "Synthetic") {
  $resolvedConfigPath = Join-Path $resolvedOutputDir "self_mirror_synthetic_config.json"
  $config = New-SyntheticConfig -ResolvedOutputDir $resolvedOutputDir -ScenarioDefinition $scenarioDefinition
  $config.activation_sampling = "event_driven"
  $config.evidence_export = "verification_capture"
  Write-Utf8NoBomJson -Value $config -Path $resolvedConfigPath
  Invoke-VisualAnalyzer -ResolvedConfigPath $resolvedConfigPath
  Write-Host "proof_route=synthetic"
  Write-Host "activation_sampling=event_driven"
  Write-Host "evidence_export=verification_capture"
  Write-Host "scenario=$Scenario"
  Write-Host "raw_frames_shared=false"
  Write-Host "raw_paths_shared=false"
  Write-OutputPackageLocation -ResolvedOutputDir $resolvedOutputDir
  exit 0
}

if ($Mode -eq "Config") {
  if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    throw "-ConfigPath is required when -Mode Config is used"
  }
  $resolvedConfigPath = Resolve-LocalPath -Path $ConfigPath
  Invoke-VisualAnalyzer -ResolvedConfigPath $resolvedConfigPath
  Write-Host "proof_route=config"
  Write-Host "activation_sampling=config-defined"
  Write-Host "evidence_export=config-defined"
  Write-Host "scenario=$Scenario"
  Write-Host "raw_frames_shared=false"
  Write-Host "raw_paths_shared=false"
  Write-OutputPackageLocation -ResolvedOutputDir $resolvedOutputDir
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
  "--trigger", $triggerValue,
  "--expression-profile", $ExpressionProfile,
  "--trigger-at-ms", [string]$TriggerAtMs,
  "--analysis-run-id", $AnalysisRunId,
  "--scenario-id", $ScenarioId,
  "--proof-layer", "visible_motion",
  "--motion-event-id", $MotionEventId,
  "--stimulus-instance-id", $StimulusInstanceId,
  "--driver-result-id", $DriverResultId,
  "--source-ref-id", $SourceRefId
)
if (-not [string]::IsNullOrWhiteSpace($StimulusId)) {
  $captureArgs += @("--stimulus-id", $StimulusId)
}
if (-not [string]::IsNullOrWhiteSpace($RuntimeResultId)) {
  $captureArgs += @("--runtime-result-id", $RuntimeResultId)
}
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
$browserCaptureManifestPath = Join-Path $resolvedOutputDir "self_mirror_capture_manifest.json"
try {
  & $node.Source @captureArgs
  if ($LASTEXITCODE -ne 0) {
    throw "browser Self Mirror capture failed"
  }

  Update-BrowserAnalyzerConfig `
    -BrowserConfigPath $browserConfigPath `
    -CaptureManifestPath $browserCaptureManifestPath `
    -ScenarioDefinition $scenarioDefinition `
    -TriggerValue $triggerValue `
    -RetainRawFrames ([bool]$KeepRawFrames)
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

Write-Host "proof_route=browser"
Write-Host "activation_sampling=event_driven"
Write-Host "evidence_export=verification_capture"
Write-Host "scenario=$Scenario"
Write-Host "raw_frames_shared=false"
Write-Host "raw_paths_shared=false"
Write-OutputPackageLocation -ResolvedOutputDir $resolvedOutputDir
