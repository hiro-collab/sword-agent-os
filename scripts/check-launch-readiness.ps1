param(
  [string]$ProfilePath = "manifests/profiles/thought-core-v0-compat.json",
  [string]$WorkspaceRoot = "",
  [switch]$CheckEndpoints,
  [int]$TimeoutMs = 1200
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$RepoRoot = Split-Path -Parent $PSScriptRoot

function Resolve-RepoPath {
  param([Parameter(Mandatory = $true)][string]$Path)
  if ([System.IO.Path]::IsPathRooted($Path)) {
    return $Path
  }
  return Join-Path $RepoRoot ($Path -replace "/", [System.IO.Path]::DirectorySeparatorChar)
}

function Resolve-WorkspaceRoot {
  param([string]$Path)
  if ([string]::IsNullOrWhiteSpace($Path)) {
    return $RepoRoot
  }
  if ([System.IO.Path]::IsPathRooted($Path)) {
    return $Path
  }
  return Join-Path $RepoRoot ($Path -replace "/", [System.IO.Path]::DirectorySeparatorChar)
}

function Read-Json {
  param([Parameter(Mandatory = $true)][string]$Path)
  return Get-Content -Raw -LiteralPath (Resolve-RepoPath $Path) | ConvertFrom-Json
}

function Get-OptionalProperty {
  param(
    [Parameter(Mandatory = $true)]$Object,
    [Parameter(Mandatory = $true)][string]$Name,
    [object]$Default = $null
  )
  $property = $Object.PSObject.Properties[$Name]
  if ($null -eq $property -or $null -eq $property.Value) {
    return $Default
  }
  return $property.Value
}

function New-Check {
  param(
    [Parameter(Mandatory = $true)][string]$Id,
    [Parameter(Mandatory = $true)][string]$Status,
    [Parameter(Mandatory = $true)][string]$Detail,
    [string]$Path = "",
    [string]$Severity = "info"
  )
  return [PSCustomObject]@{
    id = $Id
    status = $Status
    severity = $Severity
    path = $Path
    detail = $Detail
  }
}

function Test-Tool {
  param([Parameter(Mandatory = $true)][string]$Name)
  $command = Get-Command $Name -ErrorAction SilentlyContinue
  if ($null -eq $command -and $Name -eq "npm") {
    $command = Get-Command "npm.cmd" -ErrorAction SilentlyContinue
  }
  if ($null -eq $command) {
    return New-Check -Id "tool.$Name" -Status "missing" -Severity "blocker" -Detail "tool not found on PATH"
  }
  return New-Check -Id "tool.$Name" -Status "ok" -Severity "info" -Path ([string]$command.Source) -Detail "tool found"
}

function Test-PathCheck {
  param(
    [Parameter(Mandatory = $true)][string]$Id,
    [Parameter(Mandatory = $true)][string]$Path,
    [string]$MissingSeverity = "blocker",
    [string]$OkDetail = "path exists",
    [string]$MissingDetail = "path missing"
  )
  if (Test-Path -LiteralPath $Path) {
    return New-Check -Id $Id -Status "ok" -Severity "info" -Path $Path -Detail $OkDetail
  }
  return New-Check -Id $Id -Status "missing" -Severity $MissingSeverity -Path $Path -Detail $MissingDetail
}

function Test-HttpEndpoint {
  param(
    [Parameter(Mandatory = $true)][string]$Id,
    [Parameter(Mandatory = $true)][string]$Url
  )
  if (-not $CheckEndpoints) {
    return New-Check -Id $Id -Status "skipped" -Severity "info" -Path $Url -Detail "endpoint check skipped"
  }
  try {
    $timeoutSeconds = [Math]::Max(1, [int][Math]::Ceiling($TimeoutMs / 1000))
    $response = Invoke-WebRequest -Uri $Url -Method Get -TimeoutSec $timeoutSeconds -UseBasicParsing
    return New-Check -Id $Id -Status "ok" -Severity "info" -Path $Url -Detail "http $($response.StatusCode)"
  }
  catch {
    return New-Check -Id $Id -Status "missing" -Severity "warning" -Path $Url -Detail $_.Exception.Message
  }
}

$workspace = Resolve-WorkspaceRoot -Path $WorkspaceRoot
$profile = Read-Json -Path $ProfilePath
$serviceManifest = Read-Json -Path ([string]$profile.service_manifest)

$checks = @()

foreach ($service in $serviceManifest.services) {
  $targetPath = [string](Get-OptionalProperty -Object $service -Name "target_path" -Default "")
  if (-not [string]::IsNullOrWhiteSpace($targetPath)) {
    $checks += Test-PathCheck `
      -Id "service_target.$($service.service_id)" `
      -Path (Resolve-RepoPath $targetPath) `
      -MissingSeverity "blocker" `
      -OkDetail "service target available" `
      -MissingDetail "service target missing"
  }
}

$checks += Test-Tool -Name "git"
$checks += Test-Tool -Name "uv"
$checks += Test-Tool -Name "node"
$checks += Test-Tool -Name "npm"

$homeAssistantRoot = Resolve-RepoPath "organs/action/home-assistant-server"
$aituberRoot = Resolve-RepoPath "organs/expression/aituber-kit"
$touchDesignerRoot = Resolve-RepoPath "organs/display/touchdesigner-ai-controller"
$mediapipeRoot = Resolve-RepoPath "organs/reflex/mediapipe-sword-sign"
$controlPlaneRoot = Resolve-RepoPath "control-plane/sword-voice-agent"

$checks += Test-PathCheck -Id "local.home_control_config" -Path (Join-Path $homeAssistantRoot "config\home-control.yaml") -MissingSeverity "blocker" -MissingDetail "Home Assistant action config is local-only"
$checks += Test-PathCheck -Id "local.home_assistant_env" -Path (Join-Path $homeAssistantRoot ".env") -MissingSeverity "blocker" -MissingDetail "Home Assistant token env is local-only"
$checks += Test-PathCheck -Id "local.control_plane_env" -Path (Join-Path $controlPlaneRoot ".env") -MissingSeverity "warning" -MissingDetail "control-plane env is local-only"
$checks += Test-PathCheck -Id "local.aituber_env" -Path (Join-Path $aituberRoot ".env") -MissingSeverity "warning" -MissingDetail "AITuber env is local-only"
$checks += Test-PathCheck -Id "local.touchdesigner_server" -Path (Join-Path $touchDesignerRoot "tools\server.js") -MissingSeverity "blocker" -MissingDetail "TouchDesigner control GUI server entry missing"
$checks += Test-PathCheck -Id "local.mediapipe_camera_hub_launcher" -Path (Join-Path $mediapipeRoot "scripts\start_camera_hub_stack.bat") -MissingSeverity "blocker" -MissingDetail "MediaPipe camera hub launcher missing"

$vrmFiles = @()
$vrmRoot = Join-Path $aituberRoot "public\vrm"
if (Test-Path -LiteralPath $vrmRoot -PathType Container) {
  $vrmFiles = @(Get-ChildItem -LiteralPath $vrmRoot -Filter "*.vrm" -File -ErrorAction SilentlyContinue)
}
if ($vrmFiles.Count -gt 0) {
  $checks += New-Check -Id "local.vrm_assets" -Status "ok" -Severity "info" -Path $vrmRoot -Detail "$($vrmFiles.Count) VRM asset(s)"
}
else {
  $checks += New-Check -Id "local.vrm_assets" -Status "missing" -Severity "warning" -Path $vrmRoot -Detail "VRM assets are local-only"
}

$legacyControlPlaneAlias = Join-Path $workspace "sword-control-plane"
$legacyAiTalkCoreAlias = Join-Path $workspace "organs\voice\ai-talk-core"
$checks += Test-PathCheck -Id "legacy_delegate_layout.sword_control_plane_alias" -Path $legacyControlPlaneAlias -MissingSeverity "warning" -MissingDetail "legacy delegate expects sword-control-plane unless native launch adapter overrides roots"
$checks += Test-PathCheck -Id "legacy_delegate_layout.ai_talk_core_voice_alias" -Path $legacyAiTalkCoreAlias -MissingSeverity "warning" -MissingDetail "legacy watcher expects organs/voice/ai-talk-core; Agent OS imports it under organs/speech-input"

$checks += Test-HttpEndpoint -Id "endpoint.voicevox" -Url "http://127.0.0.1:50021/version"

$blockers = @($checks | Where-Object { $_.severity -eq "blocker" -and $_.status -ne "ok" })
$warnings = @($checks | Where-Object { $_.severity -eq "warning" -and $_.status -ne "ok" })

[PSCustomObject]@{
  profile_id = [string]$profile.id
  checked_at = (Get-Date).ToString("o")
  status = if ($blockers.Count -gt 0) { "blocked" } elseif ($warnings.Count -gt 0) { "warning" } else { "ok" }
  workspace_root = $workspace
  counts = [PSCustomObject]@{
    checks = $checks.Count
    blockers = $blockers.Count
    warnings = $warnings.Count
  }
  checks = @($checks)
} | ConvertTo-Json -Depth 6
