param(
  [string]$Profile = "standard",
  [string]$DistributionManifestPath = "",
  [string]$WorkspaceRoot = "",
  [switch]$Json,
  [switch]$SkipInstallDryRun,
  [switch]$SkipLocalMediaPreview,
  [switch]$SkipVoiceGatePreview,
  [switch]$RequestVoicevoxStartup,
  [string]$VoicevoxExecutablePath = "",
  [switch]$RunNoLiveSmoke,
  [switch]$RunRuntimeHttpChecks,
  [switch]$RequestRealCamera,
  [switch]$RequestRealMic,
  [switch]$RequestVirtualAudio,
  [switch]$RequestGestureGate,
  [switch]$RequestLiveHomeAssistant,
  [switch]$ConfirmHomeAssistantTicket,
  [string]$AllowedActionId = "",
  [string]$RestoreActionId = "",
  [string]$ExpectedStateAfterAllowed = "",
  [string]$ExpectedStateAfterRestore = "",
  [int]$MaxPhysicalActions = 2,
  [int]$AituberPort = 3000
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$RepoRoot = Split-Path -Parent $PSScriptRoot
$script:Layers = @()
$script:ResolvedWorkspaceRoot = ""

function Resolve-CurrentPowerShell {
  $currentProcess = Get-Process -Id $PID -ErrorAction SilentlyContinue
  if ($null -ne $currentProcess -and -not [string]::IsNullOrWhiteSpace($currentProcess.Path)) {
    return $currentProcess.Path
  }
  $pwsh = Get-Command "pwsh" -ErrorAction SilentlyContinue
  if ($null -ne $pwsh) {
    return $pwsh.Source
  }
  return (Get-Command "powershell" -ErrorAction Stop).Source
}

function Get-WorkspaceRoot {
  if (-not [string]::IsNullOrWhiteSpace($WorkspaceRoot)) {
    return [System.IO.Path]::GetFullPath($WorkspaceRoot)
  }

  $parentWorkspace = Split-Path -Parent $RepoRoot
  $parentIndex = Join-Path $parentWorkspace "local\media\media-index.json"
  if (Test-Path -LiteralPath $parentIndex -PathType Leaf) {
    return [System.IO.Path]::GetFullPath($parentWorkspace)
  }

  return [System.IO.Path]::GetFullPath($RepoRoot)
}

function Get-RepoRevision {
  try {
    $revision = (git -C $RepoRoot rev-parse --short HEAD 2>$null) -join ""
    if (-not [string]::IsNullOrWhiteSpace($revision)) {
      return $revision
    }
  }
  catch {
  }
  return "unknown"
}

function ConvertTo-DisplayCommand {
  param(
    [Parameter(Mandatory = $true)][string]$ScriptName,
    [string[]]$Arguments = @()
  )

  $displayArguments = @()
  foreach ($argument in @($Arguments)) {
    $displayArgument = [string]$argument
    if (-not [string]::IsNullOrWhiteSpace($script:ResolvedWorkspaceRoot)) {
      $displayArgument = $displayArgument.Replace($script:ResolvedWorkspaceRoot, "<workspace>")
    }
    $displayArgument = $displayArgument.Replace($RepoRoot, "<repo>")
    $displayArguments += $displayArgument
  }
  $parts = @(".\scripts\$ScriptName") + @($displayArguments)
  return ($parts -join " ")
}

function Invoke-VerificationCommand {
  param(
    [Parameter(Mandatory = $true)][string]$ScriptName,
    [string[]]$Arguments = @()
  )

  $powerShellExe = Resolve-CurrentPowerShell
  $scriptPath = Join-Path $PSScriptRoot $ScriptName
  $command = @("-NoProfile", "-File", $scriptPath) + @($Arguments)
  $previousErrorActionPreference = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  try {
    $output = @(& $powerShellExe @command 2>&1 | ForEach-Object { [string]$_ })
    $exitCode = $LASTEXITCODE
    if ($null -eq $exitCode) {
      $exitCode = 0
    }
    return [PSCustomObject]@{
      exit_code = [int]$exitCode
      output = $output
      error = ""
    }
  }
  catch {
    return [PSCustomObject]@{
      exit_code = 1
      output = @()
      error = $_.Exception.Message
    }
  }
  finally {
    $ErrorActionPreference = $previousErrorActionPreference
  }
}

function Invoke-HttpCheck {
  param(
    [Parameter(Mandatory = $true)][string]$Url
  )

  try {
    $response = Invoke-WebRequest -Uri $Url -Method Get -TimeoutSec 5 -UseBasicParsing
    return [PSCustomObject]@{
      ok = ($response.StatusCode -ge 200 -and $response.StatusCode -lt 500)
      detail = "http $($response.StatusCode)"
    }
  }
  catch {
    return [PSCustomObject]@{
      ok = $false
      detail = "http unavailable"
    }
  }
}

function Add-Layer {
  param(
    [Parameter(Mandatory = $true)][string]$Id,
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][string]$Status,
    [Parameter(Mandatory = $true)][string]$ProofLayer,
    [Parameter(Mandatory = $true)][string]$Detail,
    [string]$Command = "",
    [string[]]$KnownGaps = @()
  )

  $script:Layers += [PSCustomObject]@{
    id = $Id
    name = $Name
    status = $Status
    proof_layer = $ProofLayer
    detail = $Detail
    command = $Command
    known_gaps = @($KnownGaps)
    raw_secret_shared = $false
    raw_media_shared = $false
    raw_frames_shared = $false
    raw_audio_shared = $false
    raw_transcript_shared = $false
    raw_screenshot_shared = $false
    generated_output_written = $false
    live_action_executed = $false
  }
}

function Add-CommandLayer {
  param(
    [Parameter(Mandatory = $true)][string]$Id,
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][string]$ProofLayer,
    [Parameter(Mandatory = $true)][string]$ScriptName,
    [string[]]$Arguments = @(),
    [string]$PassDetail = "command completed",
    [string]$FailureDetail = "command failed",
    [string]$BlockedPattern = "",
    [string]$BlockedDetail = ""
  )

  $result = Invoke-VerificationCommand -ScriptName $ScriptName -Arguments $Arguments
  $outputText = ($result.output -join "`n")
  if (-not [string]::IsNullOrWhiteSpace($result.error)) {
    $outputText = "$outputText`n$($result.error)"
  }
  $status = "pass"
  $detail = $PassDetail
  if ($result.exit_code -ne 0) {
    $status = "fail"
    $detail = $FailureDetail
  }
  if (-not [string]::IsNullOrWhiteSpace($BlockedPattern) -and $outputText -match $BlockedPattern) {
    $status = "blocked"
    $detail = $BlockedDetail
  }
  Add-Layer -Id $Id -Name $Name -Status $status -ProofLayer $ProofLayer -Detail $detail -Command (ConvertTo-DisplayCommand -ScriptName $ScriptName -Arguments $Arguments)
  return [PSCustomObject]@{
    status = $status
    exit_code = $result.exit_code
    output = $result.output
    error = $result.error
  }
}

function Add-HeldLayer {
  param(
    [Parameter(Mandatory = $true)][string]$Id,
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][string]$ProofLayer,
    [Parameter(Mandatory = $true)][string]$Detail,
    [string[]]$KnownGaps = @()
  )
  Add-Layer -Id $Id -Name $Name -Status "held" -ProofLayer $ProofLayer -Detail $Detail -KnownGaps $KnownGaps
}

function Test-TicketComplete {
  $missing = @()
  if (-not $ConfirmHomeAssistantTicket) { $missing += "ConfirmHomeAssistantTicket" }
  if ([string]::IsNullOrWhiteSpace($AllowedActionId)) { $missing += "AllowedActionId" }
  if ([string]::IsNullOrWhiteSpace($RestoreActionId)) { $missing += "RestoreActionId" }
  if ([string]::IsNullOrWhiteSpace($ExpectedStateAfterAllowed)) { $missing += "ExpectedStateAfterAllowed" }
  if ([string]::IsNullOrWhiteSpace($ExpectedStateAfterRestore)) { $missing += "ExpectedStateAfterRestore" }
  if ($MaxPhysicalActions -gt 2) { $missing += "MaxPhysicalActions<=2" }
  return [PSCustomObject]@{
    complete = ($missing.Count -eq 0)
    missing = @($missing)
  }
}

$resolvedWorkspaceRoot = Get-WorkspaceRoot
$script:ResolvedWorkspaceRoot = $resolvedWorkspaceRoot
$distributionArgs = @("-Profile", $Profile)
if (-not [string]::IsNullOrWhiteSpace($DistributionManifestPath)) {
  $distributionArgs += @("-DistributionManifestPath", $DistributionManifestPath)
}

$versionResult = Add-CommandLayer `
  -Id "FIV-00" `
  -Name "Source/version summary" `
  -ProofLayer "source/static" `
  -ScriptName "show-version.ps1" `
  -Arguments ($distributionArgs + @("-Json")) `
  -PassDetail "version summary available" `
  -FailureDetail "version summary failed"

if (-not $SkipInstallDryRun) {
  Add-CommandLayer `
    -Id "FIV-01" `
    -Name "15-minute fresh install baseline dry-run" `
    -ProofLayer "source/static-dry-run" `
    -ScriptName "install-distribution.ps1" `
    -Arguments ($distributionArgs + @("-DryRun")) `
    -PassDetail "install dry-run completed; timed fresh install still requires separate fresh-clone run" `
    -FailureDetail "install dry-run failed" | Out-Null
}
else {
  Add-HeldLayer -Id "FIV-01" -Name "15-minute fresh install baseline dry-run" -ProofLayer "source/static-dry-run" -Detail "skipped by flag"
}

Add-CommandLayer `
  -Id "FIV-02a" `
  -Name "Manifest validation" `
  -ProofLayer "source/static" `
  -ScriptName "validate-manifests.ps1" `
  -PassDetail "manifest validation completed" `
  -FailureDetail "manifest validation failed" | Out-Null

Add-CommandLayer `
  -Id "FIV-02b" `
  -Name "Distribution pin check" `
  -ProofLayer "source/static" `
  -ScriptName "check-distribution-pins.ps1" `
  -Arguments ($distributionArgs + @("-Strict", "-Json")) `
  -PassDetail "pin check completed without strict violation" `
  -FailureDetail "pin check failed" `
  -BlockedPattern "git_unreadable|dubious ownership|detected dubious ownership" `
  -BlockedDetail "git_unreadable or ownership friction; rerun in normal user context before calling this a true pin mismatch" | Out-Null

if ($RunNoLiveSmoke) {
  Add-CommandLayer `
    -Id "FIV-02c" `
    -Name "Launch readiness" `
    -ProofLayer "no-live/readiness" `
    -ScriptName "check-launch-readiness.ps1" `
    -PassDetail "launch readiness completed" `
    -FailureDetail "launch readiness failed" | Out-Null
  Add-CommandLayer `
    -Id "FIV-02d" `
    -Name "Organ test packs" `
    -ProofLayer "no-live/test-pack" `
    -ScriptName "run-organ-test-packs.ps1" `
    -PassDetail "organ test packs completed" `
    -FailureDetail "organ test packs failed" | Out-Null
  Add-CommandLayer `
    -Id "FIV-02e" `
    -Name "No-camera compatibility smoke" `
    -ProofLayer "no-live/compat-smoke" `
    -ScriptName "run-compat-smoke.ps1" `
    -Arguments @("-UseIsolatedPorts", "-MediapipeVideoSource", "testsrc", "-RunManualTurn", "-RunSafeIntegrationProbes") `
    -PassDetail "no-camera compatibility smoke completed" `
    -FailureDetail "no-camera compatibility smoke failed" | Out-Null
}
else {
  Add-HeldLayer -Id "FIV-02c" -Name "No-live readiness / compatibility smoke" -ProofLayer "no-live" -Detail "held by default; run with -RunNoLiveSmoke to execute check-launch-readiness, organ test packs, and no-camera compat smoke"
}

if ($RunRuntimeHttpChecks) {
  $runtimeUrls = @(
    "http://127.0.0.1:$AituberPort/",
    "http://127.0.0.1:$AituberPort/projection-visual/",
    "http://127.0.0.1:$AituberPort/projection-visual/?visualTest=idle-neutral"
  )
  $failed = @()
  foreach ($url in $runtimeUrls) {
    $check = Invoke-HttpCheck -Url $url
    if (-not $check.ok) {
      $failed += $url
    }
  }
  if ($failed.Count -eq 0) {
    Add-Layer -Id "FIV-03" -Name "Runtime/browser reachability" -Status "pass" -ProofLayer "browser-runtime/http" -Detail "AITuber root and projection visual routes responded"
  }
  else {
    Add-Layer -Id "FIV-03" -Name "Runtime/browser reachability" -Status "blocked" -ProofLayer "browser-runtime/http" -Detail "one or more HTTP routes unavailable; confirm launcher/stack/root before claiming runtime/browser pass" -KnownGaps @("no raw screenshot captured")
  }
}
else {
  Add-HeldLayer -Id "FIV-03" -Name "Runtime/browser reachability" -ProofLayer "browser-runtime" -Detail "held by default; run with -RunRuntimeHttpChecks after starting the fresh-clone stack"
}

if (-not $SkipLocalMediaPreview) {
  Add-CommandLayer `
    -Id "FIV-04" `
    -Name "Local media index preparation dry-run" `
    -ProofLayer "local-preparation/dry-run" `
    -ScriptName "prepare-local-media-index.ps1" `
    -Arguments @("-WorkspaceRoot", $resolvedWorkspaceRoot, "-DryRun", "-Json") `
    -PassDetail "local media seed is readable and index preparation can be previewed without copying media" `
    -FailureDetail "local media index preparation dry-run failed" `
    -BlockedPattern "local media seed file not found|secret input root not found|source media file is missing" `
    -BlockedDetail "local media seed/private inputs unavailable; create _secret_inputs/local-media-index.seed.json before replay previews can pass" | Out-Null

  $gestureAssets = @("gesture.sword.20260603", "gesture.victory.20260603", "gesture.open_hand.20260603")
  foreach ($assetId in $gestureAssets) {
    Add-CommandLayer `
      -Id "FIV-05" `
      -Name "Local gesture replay preview: $assetId" `
      -ProofLayer "source/static-command-preview" `
      -ScriptName "run-local-media-replay.ps1" `
      -Arguments @("-Mode", "camera-hub", "-AssetId", $assetId, "-WorkspaceRoot", $resolvedWorkspaceRoot, "-Json") `
      -PassDetail "gesture replay command preview available; bounded replay not executed" `
      -FailureDetail "gesture replay command preview failed" `
      -BlockedPattern "local media index not found|asset id not found|local_file_present.*false" `
      -BlockedDetail "local media asset/index unavailable; preview cannot prove replay" | Out-Null
  }

  $roomLightAssets = @("vision.room_light.on.20260603", "vision.room_light.off.20260603")
  foreach ($assetId in $roomLightAssets) {
    Add-CommandLayer `
      -Id "FIV-06" `
      -Name "Local room-light replay preview: $assetId" `
      -ProofLayer "source/static-command-preview" `
      -ScriptName "run-local-media-replay.ps1" `
      -Arguments @("-Mode", "room-light", "-AssetId", $assetId, "-WorkspaceRoot", $resolvedWorkspaceRoot, "-Json") `
      -PassDetail "room-light replay command preview available; bounded replay not executed" `
      -FailureDetail "room-light replay command preview failed" `
      -BlockedPattern "local media index not found|asset id not found|local_file_present.*false" `
      -BlockedDetail "local media asset/index unavailable; preview cannot prove replay" | Out-Null
  }
}
else {
  Add-HeldLayer -Id "FIV-04" -Name "Local media index preparation dry-run" -ProofLayer "local-preparation/dry-run" -Detail "skipped by flag"
  Add-HeldLayer -Id "FIV-05" -Name "Local gesture replay previews" -ProofLayer "source/static-command-preview" -Detail "skipped by flag"
  Add-HeldLayer -Id "FIV-06" -Name "Local room-light replay previews" -ProofLayer "source/static-command-preview" -Detail "skipped by flag"
}

if (-not $SkipVoiceGatePreview) {
  Add-CommandLayer `
    -Id "FIV-11a" `
    -Name "Voice/gate redacted preview" `
    -ProofLayer "source/static-command-preview" `
    -ScriptName "test-local-media-voice-gate.ps1" `
    -Arguments @("-Mode", "preview", "-AssetId", "voice.hello", "-WorkspaceRoot", $resolvedWorkspaceRoot, "-Json") `
    -PassDetail "voice/gate redacted preview available; STT, browser, and virtual audio not executed" `
    -FailureDetail "voice/gate redacted preview failed" `
    -BlockedPattern "local media index not found|asset id not found" `
    -BlockedDetail "voice asset/index unavailable; preview cannot prove voice/gate path" | Out-Null
}
else {
  Add-HeldLayer -Id "FIV-11a" -Name "Voice/gate redacted preview" -ProofLayer "source/static-command-preview" -Detail "skipped by flag"
}

if ($RequestRealCamera) {
  $gestureModelPath = Join-Path $RepoRoot "organs\reflex\mediapipe-sword-sign\gesture_model.pkl"
  if (Test-Path -LiteralPath $gestureModelPath -PathType Leaf) {
    Add-Layer -Id "FIV-07" -Name "Real camera Camera Hub readiness" -Status "blocked" -ProofLayer "real-camera" -Detail "real camera flag supplied, but this helper has no camera executor yet; use a bounded device proof lane"
    Add-Layer -Id "FIV-08" -Name "Real camera sword-sign positive observation" -Status "blocked" -ProofLayer "real-camera/gesture" -Detail "gesture model is present, but positive event collection is not implemented by this helper"
  }
  else {
    Add-Layer -Id "FIV-07" -Name "Real camera Camera Hub readiness" -Status "blocked" -ProofLayer "real-camera" -Detail "gesture_model.pkl is missing or unreadable; camera/gesture proof must stay separate"
    Add-Layer -Id "FIV-08" -Name "Real camera sword-sign positive observation" -Status "blocked" -ProofLayer "real-camera/gesture" -Detail "gesture_model.pkl is required before claiming sword-sign positive observation"
  }
}
else {
  Add-HeldLayer -Id "FIV-07" -Name "Real camera Camera Hub readiness" -ProofLayer "real-camera" -Detail "held by default; request with -RequestRealCamera"
  Add-HeldLayer -Id "FIV-08" -Name "Real camera sword-sign positive observation" -ProofLayer "real-camera/gesture" -Detail "held by default; camera readiness alone is not gesture pass"
}

if ($RequestVoicevoxStartup) {
  $voicevoxArgs = @("-Json", "-StartIfNeeded")
  if (-not [string]::IsNullOrWhiteSpace($VoicevoxExecutablePath)) {
    $voicevoxArgs += @("-ExecutablePath", $VoicevoxExecutablePath)
  }
  $voicevoxResult = Invoke-VerificationCommand -ScriptName "check-voicevox-readiness.ps1" -Arguments $voicevoxArgs
  $voicevoxOutput = ($voicevoxResult.output -join "`n")
  if ($voicevoxResult.exit_code -ne 0) {
    Add-Layer -Id "FIV-09A" -Name "VOICEVOX endpoint/startup readiness" -Status "blocked" -ProofLayer "speech-output/voicevox-readiness" -Detail "VOICEVOX readiness helper failed; classify speech-output layer separately from general install"
  }
  else {
    try {
      $voicevoxJson = $voicevoxOutput | ConvertFrom-Json
      $voicevoxStatus = "blocked"
      if ([string]$voicevoxJson.classification -eq "pass") {
        $voicevoxStatus = "pass"
      }
      elseif ([string]$voicevoxJson.classification -eq "skipped") {
        $voicevoxStatus = "held"
      }
      $voicevoxDetail = "VOICEVOX {0}; endpoint_initial={1}; discovery={2}; source={3}; after_start={4}" -f `
        ([string]$voicevoxJson.classification), `
        ([string]$voicevoxJson.endpoint_initial), `
        ([string]$voicevoxJson.executable_discovery), `
        ([string]$voicevoxJson.executable_source), `
        ([string]$voicevoxJson.endpoint_after_start)
      Add-Layer -Id "FIV-09A" -Name "VOICEVOX endpoint/startup readiness" -Status $voicevoxStatus -ProofLayer "speech-output/voicevox-readiness" -Detail $voicevoxDetail -Command (ConvertTo-DisplayCommand -ScriptName "check-voicevox-readiness.ps1" -Arguments $voicevoxArgs)
    }
    catch {
      Add-Layer -Id "FIV-09A" -Name "VOICEVOX endpoint/startup readiness" -Status "blocked" -ProofLayer "speech-output/voicevox-readiness" -Detail "VOICEVOX readiness helper output could not be parsed"
    }
  }
}
else {
  Add-HeldLayer -Id "FIV-09A" -Name "VOICEVOX endpoint/startup readiness" -ProofLayer "speech-output/voicevox-readiness" -Detail "held by default; request with -RequestVoicevoxStartup when speech output is in scope"
}

if ($RequestVirtualAudio -or $RequestRealMic) {
  Add-Layer -Id "FIV-09B" -Name "Virtual-audio / real-mic speech path" -Status "blocked" -ProofLayer "audio/virtual-or-real" -Detail "audio proof flag supplied, but this helper does not change audio routes or execute STT; use an explicit diagnostic generator lane"
}
else {
  Add-HeldLayer -Id "FIV-09B" -Name "Virtual-audio / real-mic speech path" -ProofLayer "audio/virtual-or-real" -Detail "held by default; request with -RequestVirtualAudio or -RequestRealMic"
}

if ($RequestGestureGate) {
  Add-Layer -Id "FIV-10" -Name "Gesture to voice input gate" -Status "blocked" -ProofLayer "gesture-gate/browser-runtime" -Detail "gesture-gate flag supplied, but this helper needs external redacted gate events before it can collect a pass"
}
else {
  Add-HeldLayer -Id "FIV-10" -Name "Gesture to voice input gate" -ProofLayer "gesture-gate/browser-runtime" -Detail "held by default; requires positive gesture event and speech gate transition"
}

Add-HeldLayer -Id "FIV-11" -Name "STT heard sample vs Thought Core interpreted sample" -ProofLayer "runtime/thought-core-boundary" -Detail "held by default; feed redacted STT and Thought Core diagnostics through the voice-gate collector"

if ($RequestLiveHomeAssistant) {
  $ticket = Test-TicketComplete
  if ($ticket.complete) {
    Add-CommandLayer `
      -Id "FIV-12a" `
      -Name "Home Assistant bridge preflight" `
      -ProofLayer "home-assistant/dry-run-preflight" `
      -ScriptName "start-home-control-bridge.ps1" `
      -Arguments @("-CheckOnly") `
      -PassDetail "Home Assistant bridge preflight completed; no physical action executed" `
      -FailureDetail "Home Assistant bridge preflight failed" | Out-Null
    Add-CommandLayer `
      -Id "FIV-12b" `
      -Name "Home Assistant allowed action state tracking metadata" `
      -ProofLayer "home-assistant/state-tracking" `
      -ScriptName "start-home-control-bridge.ps1" `
      -Arguments @("-CheckTracking", "-ActionId", $AllowedActionId) `
      -PassDetail "allowed action state-tracking metadata check completed; no physical action executed" `
      -FailureDetail "allowed action state-tracking metadata check failed" | Out-Null
    Add-HeldLayer -Id "FIV-12c" -Name "Post-action Home Assistant state confirmation" -ProofLayer "home-assistant/post-action-state-check" -Detail "held until a ticketed execute/wait or restore/wait has occurred"
    Add-Layer -Id "FIV-13" -Name "Ticketed physical action plus restore" -Status "blocked" -ProofLayer "home-assistant/live-ticketed" -Detail "ticket fields are complete, but this helper intentionally does not execute physical actions; use the documented preview/dry-run/execute ladder under a single live owner"
  }
  else {
    Add-Layer -Id "FIV-12" -Name "Home Assistant health / preview / dry-run" -Status "blocked" -ProofLayer "home-assistant/dry-run-preflight" -Detail ("live HA requested but ticket fields are incomplete: {0}" -f ($ticket.missing -join ", "))
    Add-Layer -Id "FIV-13" -Name "Ticketed physical action plus restore" -Status "held" -ProofLayer "home-assistant/live-ticketed" -Detail "physical action held until action/restore ids, expected states, max count, and stop conditions are supplied"
  }
}
else {
  Add-HeldLayer -Id "FIV-12" -Name "Home Assistant health / preview / dry-run" -ProofLayer "home-assistant/dry-run" -Detail "held by default; request with -RequestLiveHomeAssistant for preflight only"
  Add-HeldLayer -Id "FIV-13" -Name "Ticketed physical action plus restore" -ProofLayer "home-assistant/live-ticketed" -Detail "held by default; physical action is never executed without a complete ticket"
}

Add-HeldLayer -Id "FIV-14" -Name "Physical/state confirmation" -ProofLayer "physical-state-confirmation" -Detail "held until a specific confirmation method is opened"

$failCount = @($script:Layers | Where-Object { $_.status -eq "fail" }).Count
$blockedCount = @($script:Layers | Where-Object { $_.status -eq "blocked" }).Count
$heldCount = @($script:Layers | Where-Object { $_.status -eq "held" }).Count
$passCount = @($script:Layers | Where-Object { $_.status -eq "pass" }).Count

$overallStatus = "ok"
if ($failCount -gt 0) {
  $overallStatus = "fail"
}
elseif ($blockedCount -gt 0) {
  $overallStatus = "partial"
}

$payload = [PSCustomObject]@{
  status = $overallStatus
  source_commit = Get-RepoRevision
  profile = $Profile
  proof_model = "layered-full-install-verification"
  default_safety = "no-live/no-device"
  pass = $passCount
  fail = $failCount
  blocked = $blockedCount
  held = $heldCount
  raw_secret_shared = $false
  raw_media_shared = $false
  raw_frames_shared = $false
  raw_audio_shared = $false
  raw_transcript_shared = $false
  raw_screenshot_shared = $false
  live_action_executed = $false
  global_audio_changed_by_script = $false
  layers = @($script:Layers)
}

if ($Json) {
  $payload | ConvertTo-Json -Depth 8
  return
}

Write-Host "Sword Agent OS full install verification"
Write-Host ("status={0}" -f $payload.status)
Write-Host ("source_commit={0}" -f $payload.source_commit)
Write-Host ("profile={0}" -f $payload.profile)
Write-Host "default_safety=no-live/no-device"
Write-Host ("pass={0} fail={1} blocked={2} held={3}" -f $passCount, $failCount, $blockedCount, $heldCount)
Write-Host "raw_secret_shared=false"
Write-Host "raw_media_shared=false"
Write-Host "raw_frames_shared=false"
Write-Host "raw_audio_shared=false"
Write-Host "raw_transcript_shared=false"
Write-Host "raw_screenshot_shared=false"
Write-Host "live_action_executed=false"
Write-Host "global_audio_changed_by_script=false"
Write-Host ""
Write-Host "layers:"
foreach ($layer in @($script:Layers)) {
  Write-Host ("  - {0}: {1} [{2}] {3}" -f $layer.id, $layer.status, $layer.proof_layer, $layer.name)
  Write-Host ("    {0}" -f $layer.detail)
}
