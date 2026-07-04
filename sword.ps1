param(
  [Parameter(Position = 0)]
  [ValidateSet("status", "verify", "doctor", "start", "stop", "hold-live", "ladder")]
  [string]$Command = "status",
  [string]$Profile = "standard",
  [ValidateSet("manifest_default", "isolated_override")]
  [string]$PortMode = "manifest_default",
  [ValidateSet("daily-confidence-smoke")]
  [string]$LadderMode = "daily-confidence-smoke",
  [int]$TimeoutMs = 1200,
  [switch]$NoLive,
  [switch]$Run,
  [switch]$DryRun,
  [switch]$Json,
  [switch]$Force
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$RepoRoot = $PSScriptRoot

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

function Invoke-RepoScript {
  param(
    [Parameter(Mandatory = $true)][string]$RelativeScript,
    [string[]]$Arguments = @()
  )

  $scriptPath = Join-Path $RepoRoot $RelativeScript
  if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
    throw "script missing: $RelativeScript"
  }

  & $PowerShellCommand -NoProfile -File $scriptPath @Arguments
  $exitCode = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }
  if ($exitCode -ne 0) {
    throw "command failed ($exitCode): $RelativeScript $($Arguments -join ' ')"
  }
}

function Write-FrontDoorHeader {
  param([Parameter(Mandatory = $true)][string]$ProofLayer)

  Write-Host "Sword Agent OS front door"
  Write-Host ("command={0}" -f $Command)
  Write-Host ("profile={0}" -f $Profile)
  Write-Host ("proof_layer={0}" -f $ProofLayer)
  Write-Host "default_safety=no-live/no-device"
  Write-Host "raw_private_publication=false"
  Write-Host ""
}

function Write-HoldLiveState {
  $hold = [ordered]@{
    status = if ($DryRun) { "planned" } else { "active" }
    proof_layer = "safe-local-control-hold"
    live_home_assistant_actions_allowed = $false
    provider_calls_allowed = $false
    browser_or_camera_operations_allowed = $false
    broad_cleanup_allowed = $false
    approval_bypass_allowed = $false
    raw_private_publication = $false
    note = "Local hold marker only; this does not execute the runtime stack, Home Assistant actions, providers, browser, camera, or device routes."
    updated_at = (Get-Date).ToString("o")
  }

  if (-not $DryRun) {
    $holdDir = Join-Path $RepoRoot ".cache\agent-os\control"
    New-Item -ItemType Directory -Force -Path $holdDir | Out-Null
    $hold | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $holdDir "hold-live.json") -Encoding UTF8
  }

  $hold | ConvertTo-Json -Depth 4
}

function Write-LadderRunBlockedOutput {
  $block = [ordered]@{
    route_id = "OVERALL-TEST-LADDER-FRONT-DOOR-INVENTORY-V2-SOURCE-STATIC-01"
    status_class = "blocked"
    result_class = "runtime_or_device_layers_require_exact_route"
    blocker_class = "separate_exact_route_required"
    proof_ceiling = "source_static_front_door_inventory_only"
    next_action_class = "open_exact_runtime_or_device_route_if_selected"
    raw_private_publication_flags = $false
    non_claims = @(
      "not_rr003_or_final_readiness",
      "not_runtime_or_device_operation",
      "not_broad_runner_implementation"
    )
  }

  if ($Json) {
    $block | ConvertTo-Json -Depth 4
    return
  }

  Write-Output "Sword Agent OS overall test ladder v2"
  Write-Output "status_class=blocked"
  Write-Output "result_class=runtime_or_device_layers_require_exact_route"
  Write-Output "blocker_class=separate_exact_route_required"
  Write-Output "proof_ceiling=source_static_front_door_inventory_only"
  Write-Output "next_action_class=open_exact_runtime_or_device_route_if_selected"
  Write-Output "raw_private_publication_flags=false"
  Write-Output "non_claims=not_rr003_or_final_readiness,not_runtime_or_device_operation,not_broad_runner_implementation"
}

function Write-LauncherCommandPreview {
  param([Parameter(Mandatory = $true)][ValidateSet("start", "stop")][string]$Action)

  Write-Host ("mode=launcher-{0}-preview" -f $Action)
  Write-Host ("launcher_wrapper=scripts\{0}-launcher.ps1" -f $Action)
  Write-Host ("port_mode={0}" -f $PortMode)
  Write-Host "run_required=true"
  Write-Host "runtime_action_executed=false"
  Write-Host "home_assistant_command_submission=false"
  Write-Host "provider_network_calls=false"
  Write-Host "capture_media=false"
  Write-Host ""

  $readinessArgs = @("-SkipPortChecks")
  if ($PortMode -eq "isolated_override") {
    $readinessArgs += "-UseIsolatedPorts"
  }
  Invoke-RepoScript -RelativeScript "scripts\check-launch-readiness.ps1" -Arguments $readinessArgs
}

$PowerShellCommand = Resolve-CurrentPowerShell

if ($Run -and $NoLive) {
  throw "-Run and -NoLive cannot be combined. Omit -Run for no-live command previews."
}

switch ($Command) {
  "status" {
    Write-FrontDoorHeader -ProofLayer "source-status/no-live"
    Invoke-RepoScript -RelativeScript "scripts\show-version.ps1" -Arguments @("-Profile", $Profile)
    Write-Host ""
    Invoke-RepoScript -RelativeScript "scripts\check-profile-health.ps1" -Arguments @("-ManifestOnly", "-PortMode", $PortMode, "-TimeoutMs", ([string]$TimeoutMs))
  }
  "verify" {
    Write-FrontDoorHeader -ProofLayer "source-static/no-live"
    Invoke-RepoScript -RelativeScript "scripts\validate-manifests.ps1"
    Invoke-RepoScript -RelativeScript "scripts\check-distribution-pins.ps1" -Arguments @("-Profile", $Profile, "-Strict")
    Invoke-RepoScript -RelativeScript "scripts\check-launch-readiness.ps1" -Arguments @("-SkipPortChecks")
  }
  "doctor" {
    Write-FrontDoorHeader -ProofLayer "distribution-doctor/no-live"
    Invoke-RepoScript -RelativeScript "scripts\doctor-distribution.ps1" -Arguments @("-Profile", $Profile, "-RunReadiness")
  }
  "start" {
    if ($Run) {
      Write-FrontDoorHeader -ProofLayer "launcher-start/readiness"
      Invoke-RepoScript -RelativeScript "scripts\start-launcher.ps1" -Arguments @("-PortMode", $PortMode, "-ReuseExisting")
      Write-Host ""
      Invoke-RepoScript -RelativeScript "scripts\check-profile-health.ps1" -Arguments @("-ManifestOnly", "-PortMode", $PortMode, "-TimeoutMs", ([string]$TimeoutMs))
    }
    else {
      Write-FrontDoorHeader -ProofLayer "source-static-command-preview"
      Write-Host "Launcher command preview only. Add -Run only under an explicit runtime execution lease."
      Write-LauncherCommandPreview -Action "start"
    }
  }
  "stop" {
    if ($Run) {
      Write-FrontDoorHeader -ProofLayer "launcher-stop/readiness"
      $stopArgs = @("-TimeoutSeconds", ([string][Math]::Ceiling($TimeoutMs / 1000)))
      if ($Force) {
        $stopArgs += "-Force"
      }
      Invoke-RepoScript -RelativeScript "scripts\stop-launcher.ps1" -Arguments $stopArgs
    }
    else {
      Write-FrontDoorHeader -ProofLayer "source-static-command-preview"
      Write-Host "Stop preview only. Add -Run only when stopping launcher-owned runtime children is explicitly in scope."
      Write-LauncherCommandPreview -Action "stop"
    }
  }
  "hold-live" {
    Write-FrontDoorHeader -ProofLayer "safe-local-control-hold"
    Write-HoldLiveState
  }
  "ladder" {
    if ($Run) {
      Write-LadderRunBlockedOutput
      exit 2
    }

    $ladderArgs = @("-Mode", $LadderMode)
    if ($Json) {
      $ladderArgs += "-Json"
    }
    Invoke-RepoScript -RelativeScript "scripts\run-overall-test-ladder-v2.ps1" -Arguments $ladderArgs
  }
}
