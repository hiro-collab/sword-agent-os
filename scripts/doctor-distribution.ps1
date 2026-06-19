param(
  [string]$Profile = "standard",
  [string]$DistributionManifestPath = "",
  [switch]$Json,
  [switch]$Strict,
  [switch]$RunReadiness
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$RepoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot "lib/common.ps1")

function Get-PowerShellCommand {
  $pwsh = Get-Command pwsh -ErrorAction SilentlyContinue
  if ($null -ne $pwsh) {
    return $pwsh.Source
  }
  $powershell = Get-Command powershell -ErrorAction SilentlyContinue
  if ($null -ne $powershell) {
    return $powershell.Source
  }
  return ""
}

function Add-Check {
  param(
    [System.Collections.Generic.List[object]]$Checks,
    [Parameter(Mandatory = $true)][string]$Id,
    [Parameter(Mandatory = $true)][string]$Status,
    [Parameter(Mandatory = $true)][string]$Severity,
    [Parameter(Mandatory = $true)][string]$Detail,
    [string]$Path = ""
  )
  $Checks.Add([PSCustomObject]@{
    id = $Id
    status = $Status
    severity = $Severity
    path = $Path
    detail = $Detail
  }) | Out-Null
}

function Read-EnvMap {
  param([Parameter(Mandatory = $true)][string]$Path)
  $map = @{}
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    return $map
  }
  foreach ($line in Get-Content -LiteralPath $Path) {
    if ($line -match "^\s*#" -or $line -notmatch "=") {
      continue
    }
    $index = $line.IndexOf("=")
    if ($index -le 0) {
      continue
    }
    $key = $line.Substring(0, $index).Trim()
    $value = $line.Substring($index + 1).Trim()
    if ($value.Length -ge 2) {
      $quote = $value.Substring(0, 1)
      if (($quote -eq '"' -or $quote -eq "'") -and $value.EndsWith($quote)) {
        $value = $value.Substring(1, $value.Length - 2)
      }
    }
    if (-not [string]::IsNullOrWhiteSpace($key)) {
      $map[$key] = $value
    }
  }
  return $map
}

if ([string]::IsNullOrWhiteSpace($DistributionManifestPath)) {
  $DistributionManifestPath = "manifests/distributions/$Profile.json"
}

$manifest = Read-JsonFile -Path $DistributionManifestPath
$release = Read-JsonFile -Path ([string]$manifest.release_manifest_path)
$checks = [System.Collections.Generic.List[object]]::new()

foreach ($tool in @($manifest.tool_requirements)) {
  $command = [string]$tool.command
  $optional = [bool]($tool.PSObject.Properties["optional"] -and $tool.optional)
  $found = Get-Command $command -ErrorAction SilentlyContinue
  if ($null -eq $found) {
    Add-Check -Checks $checks -Id "tool.$($tool.id)" -Status "missing" -Severity $(if ($optional) { "warning" } else { "blocker" }) -Detail "$command not found for $($tool.required_for)"
  }
  else {
    Add-Check -Checks $checks -Id "tool.$($tool.id)" -Status "ok" -Severity "info" -Detail "tool found" -Path $found.Source
  }
}

$powerShellCommand = Get-PowerShellCommand
if ([string]::IsNullOrWhiteSpace($powerShellCommand)) {
  Add-Check -Checks $checks -Id "script.check_distribution_pins" -Status "skipped" -Severity "blocker" -Detail "PowerShell command not found"
  $pinSummary = $null
}
else {
  $pinArgs = @("-NoProfile", "-File", (Join-Path $PSScriptRoot "check-distribution-pins.ps1"), "-Profile", $Profile, "-DistributionManifestPath", $DistributionManifestPath, "-Json")
  $pinOutput = & $powerShellCommand @pinArgs 2>&1
  $pinExit = $LASTEXITCODE
  if ($pinExit -ne 0) {
    Add-Check -Checks $checks -Id "script.check_distribution_pins" -Status "failed" -Severity "blocker" -Detail (($pinOutput | Select-Object -First 5) -join " | ")
    $pinSummary = $null
  }
  else {
    $pinSummary = ($pinOutput -join "`n") | ConvertFrom-Json
    Add-Check -Checks $checks -Id "script.check_distribution_pins" -Status ([string]$pinSummary.status) -Severity $(if ([string]$pinSummary.status -eq "ok") { "info" } elseif ([string]$pinSummary.status -eq "warning") { "warning" } else { "blocker" }) -Detail "pin check completed; strict violations: $($pinSummary.strict_violations)"
  }
}

$centralEnvPath = Resolve-RepoPath ([string]$manifest.env.central_env_path)
$centralTemplatePath = Resolve-RepoPath ([string]$manifest.env.central_template_path)
if (Test-Path -LiteralPath $centralTemplatePath -PathType Leaf) {
  Add-Check -Checks $checks -Id "env.central_template" -Status "ok" -Severity "info" -Detail "central env template exists" -Path ([string]$manifest.env.central_template_path)
}
else {
  Add-Check -Checks $checks -Id "env.central_template" -Status "missing" -Severity "blocker" -Detail "central env template is missing" -Path ([string]$manifest.env.central_template_path)
}

$centralEnv = @{}
if (Test-Path -LiteralPath $centralEnvPath -PathType Leaf) {
  $centralEnv = Read-EnvMap -Path $centralEnvPath
  Add-Check -Checks $checks -Id "env.central" -Status "ok" -Severity "info" -Detail "central env exists" -Path ([string]$manifest.env.central_env_path)
}
else {
  Add-Check -Checks $checks -Id "env.central" -Status "missing" -Severity "warning" -Detail "central env is missing; run install-distribution or render-env-files" -Path ([string]$manifest.env.central_env_path)
}

foreach ($target in @($manifest.env.targets)) {
  $targetPath = Resolve-RepoPath ([string]$target.target_path)
  if (Test-Path -LiteralPath $targetPath -PathType Leaf) {
    Add-Check -Checks $checks -Id "env.target.$($target.id)" -Status "ok" -Severity "info" -Detail "generated env target exists" -Path ([string]$target.target_path)
  }
  else {
    Add-Check -Checks $checks -Id "env.target.$($target.id)" -Status "missing" -Severity "warning" -Detail "generated env target is missing; run render-env-files" -Path ([string]$target.target_path)
  }
}

$gestureModelPath = Resolve-RepoPath "organs/reflex/mediapipe-sword-sign/gesture_model.pkl"
if (Test-Path -LiteralPath $gestureModelPath -PathType Leaf) {
  Add-Check -Checks $checks -Id "asset.gesture_model" -Status "ok" -Severity "info" -Detail "local gesture model is present" -Path "organs/reflex/mediapipe-sword-sign/gesture_model.pkl"
}
else {
  Add-Check -Checks $checks -Id "asset.gesture_model" -Status "missing" -Severity "warning" -Detail "local gesture model is missing; camera/gesture proof should stay separate" -Path "organs/reflex/mediapipe-sword-sign/gesture_model.pkl"
}

$selectedVrm = ""
if ($centralEnv.ContainsKey("NEXT_PUBLIC_SELECTED_VRM_PATH")) {
  $selectedVrm = [string]$centralEnv["NEXT_PUBLIC_SELECTED_VRM_PATH"]
}
else {
  $aituberEnvPath = Resolve-RepoPath "organs/expression/aituber-kit/.env"
  $aituberEnv = Read-EnvMap -Path $aituberEnvPath
  if ($aituberEnv.ContainsKey("NEXT_PUBLIC_SELECTED_VRM_PATH")) {
    $selectedVrm = [string]$aituberEnv["NEXT_PUBLIC_SELECTED_VRM_PATH"]
  }
}
if ([string]::IsNullOrWhiteSpace($selectedVrm)) {
  Add-Check -Checks $checks -Id "asset.selected_vrm" -Status "unknown" -Severity "warning" -Detail "NEXT_PUBLIC_SELECTED_VRM_PATH is not set in readable env files"
}
else {
  $relativeVrm = $selectedVrm.TrimStart("/") -replace "/", [System.IO.Path]::DirectorySeparatorChar
  $vrmPath = Resolve-RepoPath (Join-Path "organs/expression/aituber-kit/public" $relativeVrm)
  if (Test-Path -LiteralPath $vrmPath -PathType Leaf) {
    Add-Check -Checks $checks -Id "asset.selected_vrm" -Status "ok" -Severity "info" -Detail "selected VRM asset exists" -Path $selectedVrm
  }
  else {
    Add-Check -Checks $checks -Id "asset.selected_vrm" -Status "missing" -Severity "blocker" -Detail "selected VRM path does not resolve to an installed asset" -Path $selectedVrm
  }
}

if ($RunReadiness -and [string]::IsNullOrWhiteSpace($powerShellCommand)) {
  Add-Check -Checks $checks -Id "readiness.launch" -Status "skipped" -Severity "blocker" -Detail "PowerShell command not found"
}
elseif ($RunReadiness) {
  $readinessOutput = & $powerShellCommand -NoProfile -File (Join-Path $PSScriptRoot "check-launch-readiness.ps1") -SkipPortChecks 2>&1
  $readinessExit = $LASTEXITCODE
  if ($readinessExit -ne 0) {
    Add-Check -Checks $checks -Id "readiness.launch" -Status "failed" -Severity "blocker" -Detail (($readinessOutput | Select-Object -First 5) -join " | ")
  }
  else {
    try {
      $readiness = ($readinessOutput -join "`n") | ConvertFrom-Json
      Add-Check -Checks $checks -Id "readiness.launch" -Status ([string]$readiness.status) -Severity $(if ([string]$readiness.status -eq "ok") { "info" } elseif ([string]$readiness.status -eq "warning") { "warning" } else { "blocker" }) -Detail "check-launch-readiness completed with SkipPortChecks"
    }
    catch {
      Add-Check -Checks $checks -Id "readiness.launch" -Status "unreadable" -Severity "warning" -Detail "readiness output was not JSON"
    }
  }
}

$blockers = @($checks | Where-Object { [string]$_.severity -eq "blocker" })
$warnings = @($checks | Where-Object { [string]$_.severity -eq "warning" })
$status = "ok"
if ($blockers.Count -gt 0) {
  $status = "blocked"
}
elseif ($warnings.Count -gt 0) {
  $status = "warning"
}

$summary = [PSCustomObject]@{
  status = $status
  profile = $Profile
  os_version = [string]$release.os_version
  distribution_version = [string]$release.distribution_version
  checks = @($checks)
  pin_summary = $pinSummary
}

if ($Json) {
  $summary | ConvertTo-Json -Depth 12
}
else {
  Write-Host "Sword Agent OS distribution doctor"
  Write-Host "  Profile              : $Profile"
  Write-Host "  OS version           : $($release.os_version)"
  Write-Host "  Distribution version : $($release.distribution_version)"
  Write-Host "  Status               : $status"
  Write-Host ""
  foreach ($check in $checks) {
    Write-Host ("{0,-8} {1,-38} {2}" -f $check.severity, $check.id, $check.status)
    if ([string]$check.severity -ne "info") {
      Write-Host "  $($check.detail)"
    }
  }
  if ($null -ne $pinSummary) {
    Write-Host ""
    Write-Host "Pin summary:"
    foreach ($key in $pinSummary.counts.PSObject.Properties.Name) {
      Write-Host "  ${key}: $($pinSummary.counts.$key)"
    }
  }
}

if ($Strict -and $status -ne "ok") {
  exit 1
}
exit 0
