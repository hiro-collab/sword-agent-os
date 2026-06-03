param(
  [string]$WorkspaceRoot = "",
  [string]$SampleDir = "",
  [int]$Windows = 5,
  [ValidateSet("windows", "all-frames")]
  [string]$SamplingMode = "windows",
  [int]$FrameStep = 1,
  [switch]$Json
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$RepoRoot = Split-Path -Parent $PSScriptRoot

function Get-WorkspaceRoot {
  if (-not [string]::IsNullOrWhiteSpace($WorkspaceRoot)) {
    return [System.IO.Path]::GetFullPath($WorkspaceRoot)
  }

  $parentWorkspace = Split-Path -Parent $RepoRoot
  $sampleRoot = Join-Path $parentWorkspace "local\media\movie\sample20260604"
  if (Test-Path -LiteralPath $sampleRoot -PathType Container) {
    return [System.IO.Path]::GetFullPath($parentWorkspace)
  }

  return [System.IO.Path]::GetFullPath($RepoRoot)
}

function Invoke-SampleEvaluation {
  param(
    [Parameter(Mandatory = $true)][string]$VideoPath,
    [Parameter(Mandatory = $true)][string]$SampleId,
    [Parameter(Mandatory = $true)][string]$ExpectedState,
    [Parameter(Mandatory = $true)][string]$ProcessorSrc
  )

  $visionRoot = Join-Path $RepoRoot "organs\environment\vision-snapshot-processor"
  $pythonScript = Join-Path $PSScriptRoot "evaluate-room-light-video.py"
  $arguments = @(
    "--cache-dir",
    ".uv-cache",
    "run",
    "python",
    $pythonScript,
    "--video",
    $VideoPath,
    "--sample-id",
    $SampleId,
    "--expected-electric-state",
    $ExpectedState,
    "--processor-src",
    $ProcessorSrc,
    "--windows",
    ([string]$Windows),
    "--sampling-mode",
    $SamplingMode,
    "--frame-step",
    ([string]$FrameStep),
    "--json"
  )

  $previousErrorActionPreference = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  try {
    $output = @(Push-Location $visionRoot; try { & uv @arguments 2>&1 | ForEach-Object { [string]$_ } } finally { Pop-Location })
    $exitCode = $LASTEXITCODE
    if ($null -eq $exitCode) {
      $exitCode = 0
    }
  }
  finally {
    $ErrorActionPreference = $previousErrorActionPreference
  }

  $text = ($output -join "`n").Trim()
  if ($exitCode -ne 0 -and [string]::IsNullOrWhiteSpace($text)) {
    return [PSCustomObject]@{
      sample_id = $SampleId
      expected_electric_state = $ExpectedState
      classification = "blocked"
      note = "evaluation command failed without JSON output"
      raw_media_shared = $false
      raw_frames_shared = $false
      generated_model_written = $false
    }
  }

  try {
    $jsonText = $text
    $jsonStart = $jsonText.IndexOf("{")
    $jsonEnd = $jsonText.LastIndexOf("}")
    if ($jsonStart -gt 0 -and $jsonEnd -gt $jsonStart) {
      $jsonText = $jsonText.Substring($jsonStart, ($jsonEnd - $jsonStart + 1))
    }
    return ($jsonText | ConvertFrom-Json)
  }
  catch {
    return [PSCustomObject]@{
      sample_id = $SampleId
      expected_electric_state = $ExpectedState
      classification = "blocked"
      note = "evaluation output could not be parsed"
      raw_media_shared = $false
      raw_frames_shared = $false
      generated_model_written = $false
    }
  }
}

$resolvedWorkspaceRoot = Get-WorkspaceRoot
if ([string]::IsNullOrWhiteSpace($SampleDir)) {
  $SampleDir = Join-Path $resolvedWorkspaceRoot "local\media\movie\sample20260604"
}
else {
  $SampleDir = [System.IO.Path]::GetFullPath($SampleDir)
}

$samples = @(
  [PSCustomObject]@{
    sample_id = "light_off_in_sunshine"
    file_name = "light_off_in_sunshine.mp4"
    expected = "off"
  },
  [PSCustomObject]@{
    sample_id = "light_on_in_sunshine"
    file_name = "light_on_in_sunshine.mp4"
    expected = "on"
  }
)

$processorSrc = Join-Path $RepoRoot "organs\environment\vision-snapshot-processor\src"
$results = @()
foreach ($sample in $samples) {
  $videoPath = Join-Path $SampleDir ([string]$sample.file_name)
  if (-not (Test-Path -LiteralPath $videoPath -PathType Leaf)) {
    $results += [PSCustomObject]@{
      sample_id = [string]$sample.sample_id
      expected_electric_state = [string]$sample.expected
      classification = "blocked"
      note = "sample file missing"
      raw_media_shared = $false
      raw_frames_shared = $false
      generated_model_written = $false
    }
    continue
  }
  $results += Invoke-SampleEvaluation -VideoPath $videoPath -SampleId ([string]$sample.sample_id) -ExpectedState ([string]$sample.expected) -ProcessorSrc $processorSrc
}

$classifications = @($results | ForEach-Object { [string]$_.classification })
$overall = "pass"
if ($classifications -contains "blocked") {
  $overall = "blocked"
}
elseif ($classifications -contains "fail") {
  $overall = "fail"
}
elseif ($classifications -contains "partial") {
  $overall = "partial"
}

$payload = [PSCustomObject]@{
  status = $overall
  proof_layer = "local-media/direct-file-evaluation"
  route = "direct_file_helper"
  sample_set = "sample20260604"
  sample_count = $samples.Count
  windows_per_sample = $Windows
  sampling_mode = $SamplingMode
  frame_step = $FrameStep
  result_safety = @{
    raw_media_shared = $false
    raw_frames_shared = $false
    raw_screenshot_shared = $false
    generated_model_written = $false
    generated_frames_written = $false
  }
  results = @($results)
}

if ($Json) {
  $payload | ConvertTo-Json -Depth 8
  return
}

Write-Host "Sword Agent OS sunshine room-light evaluation"
Write-Host ("status={0}" -f $payload.status)
Write-Host "proof_layer=local-media/direct-file-evaluation"
Write-Host "route=direct_file_helper"
Write-Host "sample_set=sample20260604"
Write-Host ("sample_count={0}" -f $payload.sample_count)
Write-Host ("windows_per_sample={0}" -f $payload.windows_per_sample)
Write-Host ("sampling_mode={0}" -f $payload.sampling_mode)
Write-Host ("frame_step={0}" -f $payload.frame_step)
Write-Host "raw_media_shared=false"
Write-Host "raw_frames_shared=false"
Write-Host "raw_screenshot_shared=false"
Write-Host "generated_model_written=false"
Write-Host ""
Write-Host "samples:"
foreach ($result in @($payload.results)) {
  Write-Host ("  - {0}: {1} expected={2}" -f $result.sample_id, $result.classification, $result.expected_electric_state)
}
