param(
  [Parameter(Position = 0)]
  [ValidateSet("status", "verify", "doctor", "start", "stop", "hold-live")]
  [string]$Command = "status",
  [string]$Profile = "standard",
  [string]$RuntimeProfile = "thought-core-v0",
  [ValidateSet("manifest_default", "isolated_override")]
  [string]$PortMode = "manifest_default",
  [int]$TimeoutMs = 1200,
  [switch]$NoLive,
  [switch]$Run,
  [switch]$DryRun,
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
  Write-Host ("runtime_profile={0}" -f $RuntimeProfile)
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
    note = "Local hold marker only; this does not execute Start Stack, Home Assistant actions, providers, browser, camera, or device routes."
    updated_at = (Get-Date).ToString("o")
  }

  if (-not $DryRun) {
    $holdDir = Join-Path $RepoRoot ".cache\agent-os\control"
    New-Item -ItemType Directory -Force -Path $holdDir | Out-Null
    $hold | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $holdDir "hold-live.json") -Encoding UTF8
  }

  $hold | ConvertTo-Json -Depth 4
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
    Invoke-RepoScript -RelativeScript "scripts\system.ps1" -Arguments @("status", "-Profile", $RuntimeProfile, "-ManifestOnly", "-PortMode", $PortMode, "-TimeoutMs", ([string]$TimeoutMs))
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
      Write-FrontDoorHeader -ProofLayer "runtime-start"
      Invoke-RepoScript -RelativeScript "scripts\system.ps1" -Arguments @("start", "-Profile", $RuntimeProfile, "-LegacyDelegate", "-PortMode", $PortMode)
    }
    else {
      Write-FrontDoorHeader -ProofLayer "source-static-command-preview"
      Write-Host "Start Stack preview only. Add -Run only under an explicit runtime execution lease."
      Invoke-RepoScript -RelativeScript "scripts\system.ps1" -Arguments @("start", "-Profile", $RuntimeProfile, "-DryRun", "-PortMode", $PortMode)
    }
  }
  "stop" {
    if ($Run) {
      Write-FrontDoorHeader -ProofLayer "runtime-stop"
      $stopArgs = @("stop", "-Profile", $RuntimeProfile, "-LegacyDelegate", "-PortMode", $PortMode)
      if ($Force) {
        $stopArgs += "-Force"
      }
      Invoke-RepoScript -RelativeScript "scripts\system.ps1" -Arguments $stopArgs
    }
    else {
      Write-FrontDoorHeader -ProofLayer "source-static-command-preview"
      Write-Host "Stop preview only. Add -Run only when stopping launcher-owned runtime children is explicitly in scope."
      Invoke-RepoScript -RelativeScript "scripts\system.ps1" -Arguments @("stop", "-Profile", $RuntimeProfile, "-DryRun", "-PortMode", $PortMode)
    }
  }
  "hold-live" {
    Write-FrontDoorHeader -ProofLayer "safe-local-control-hold"
    Write-HoldLiveState
  }
}
