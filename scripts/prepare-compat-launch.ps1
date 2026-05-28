param(
  [string]$LegacyWorkspaceRoot = "C:\Users\kawai\works\sword-agent-system",
  [switch]$ImportLocalConfig,
  [switch]$DryRun,
  [switch]$Force
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

function Resolve-LegacyPath {
  param([Parameter(Mandatory = $true)][string]$Path)
  if ([System.IO.Path]::IsPathRooted($Path)) {
    return $Path
  }
  return Join-Path $LegacyWorkspaceRoot ($Path -replace "/", [System.IO.Path]::DirectorySeparatorChar)
}

function New-Result {
  param(
    [Parameter(Mandatory = $true)][string]$Id,
    [Parameter(Mandatory = $true)][string]$Status,
    [Parameter(Mandatory = $true)][string]$Detail,
    [string]$Path = "",
    [string]$Target = ""
  )
  return [PSCustomObject]@{
    id = $Id
    status = $Status
    path = $Path
    target = $Target
    detail = $Detail
  }
}

function Assert-TargetPath {
  param(
    [Parameter(Mandatory = $true)][string]$Id,
    [Parameter(Mandatory = $true)][string]$Path
  )
  if (-not (Test-Path -LiteralPath $Path)) {
    throw "$Id target path not found: $Path"
  }
}

function Get-LinkTarget {
  param([Parameter(Mandatory = $true)][string]$Path)
  $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
  if ($null -eq $item) {
    return ""
  }
  $target = $item.Target
  if ($target -is [array]) {
    return [string]($target | Select-Object -First 1)
  }
  return [string]$target
}

function Ensure-Junction {
  param(
    [Parameter(Mandatory = $true)][string]$Id,
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$Target
  )

  Assert-TargetPath -Id $Id -Path $Target
  if (Test-Path -LiteralPath $Path) {
    $existingTarget = Get-LinkTarget -Path $Path
    if (-not [string]::IsNullOrWhiteSpace($existingTarget)) {
      $resolvedExistingTarget = (Resolve-Path -LiteralPath $existingTarget).Path
      $resolvedTarget = (Resolve-Path -LiteralPath $Target).Path
      if ($resolvedExistingTarget -eq $resolvedTarget) {
        return New-Result -Id $Id -Status "ok" -Path $Path -Target $Target -Detail "junction already points to target"
      }
    }
    throw "$Id path already exists and is not the expected junction: $Path"
  }

  $parent = Split-Path -Parent $Path
  if (-not (Test-Path -LiteralPath $parent)) {
    if ($DryRun) {
      return New-Result -Id $Id -Status "planned" -Path $Path -Target $Target -Detail "would create parent and junction"
    }
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
  }

  if ($DryRun) {
    return New-Result -Id $Id -Status "planned" -Path $Path -Target $Target -Detail "would create junction"
  }
  New-Item -ItemType Junction -Path $Path -Target $Target | Out-Null
  return New-Result -Id $Id -Status "created" -Path $Path -Target $Target -Detail "junction created"
}

function Copy-LocalFile {
  param(
    [Parameter(Mandatory = $true)][string]$Id,
    [Parameter(Mandatory = $true)][string]$Source,
    [Parameter(Mandatory = $true)][string]$Destination
  )

  if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) {
    return New-Result -Id $Id -Status "missing-source" -Path $Destination -Target $Source -Detail "source file missing"
  }
  if ((Test-Path -LiteralPath $Destination) -and (-not $Force)) {
    return New-Result -Id $Id -Status "kept" -Path $Destination -Target $Source -Detail "destination exists; use -Force to overwrite"
  }

  $parent = Split-Path -Parent $Destination
  if (-not (Test-Path -LiteralPath $parent)) {
    if (-not $DryRun) {
      New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }
  }

  if ($DryRun) {
    return New-Result -Id $Id -Status "planned" -Path $Destination -Target $Source -Detail "would copy local-only file"
  }
  Copy-Item -LiteralPath $Source -Destination $Destination -Force:$Force
  return New-Result -Id $Id -Status "copied" -Path $Destination -Target $Source -Detail "local-only file copied"
}

$results = @()

$results += Ensure-Junction `
  -Id "layout.sword_control_plane" `
  -Path (Resolve-RepoPath "sword-control-plane") `
  -Target (Resolve-RepoPath "control-plane/sword-voice-agent")

$results += Ensure-Junction `
  -Id "layout.ai_talk_core_voice_alias" `
  -Path (Resolve-RepoPath "organs/voice/ai-talk-core") `
  -Target (Resolve-RepoPath "organs/speech-input/ai-talk-core")

if ($ImportLocalConfig) {
  $results += Copy-LocalFile `
    -Id "config.home_control_yaml" `
    -Source (Resolve-LegacyPath "organs/action/home-assistant-server/config/home-control.yaml") `
    -Destination (Resolve-RepoPath "organs/action/home-assistant-server/config/home-control.yaml")

  $results += Copy-LocalFile `
    -Id "env.home_assistant_server" `
    -Source (Resolve-LegacyPath "organs/action/home-assistant-server/.env") `
    -Destination (Resolve-RepoPath "organs/action/home-assistant-server/.env")

  $results += Copy-LocalFile `
    -Id "env.control_plane" `
    -Source (Resolve-LegacyPath "sword-control-plane/.env") `
    -Destination (Resolve-RepoPath "control-plane/sword-voice-agent/.env")

  $results += Copy-LocalFile `
    -Id "env.aituber_kit" `
    -Source (Resolve-LegacyPath "organs/expression/aituber-kit/.env") `
    -Destination (Resolve-RepoPath "organs/expression/aituber-kit/.env")

  $results += Copy-LocalFile `
    -Id "model.mediapipe_gesture_model" `
    -Source (Resolve-LegacyPath "organs/reflex/mediapipe-sword-sign/gesture_model.pkl") `
    -Destination (Resolve-RepoPath "organs/reflex/mediapipe-sword-sign/gesture_model.pkl")
}

[PSCustomObject]@{
  status = if (@($results | Where-Object { $_.status -like "missing-*" }).Count -gt 0) { "incomplete" } else { "ok" }
  dry_run = [bool]$DryRun
  import_local_config = [bool]$ImportLocalConfig
  repo_root = $RepoRoot
  legacy_workspace_root = $LegacyWorkspaceRoot
  results = @($results)
} | ConvertTo-Json -Depth 5
