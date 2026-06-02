param(
  [ValidateSet("preview", "collect-local")]
  [string]$Mode = "preview",

  [Parameter(Mandatory = $true)]
  [string]$AssetId,

  [string]$WorkspaceRoot = "",
  [string]$GateEvents = "",
  [string]$SttDiagnostic = "",
  [string]$ThoughtCoreEvents = "",
  [string]$ProofLayer = "source/static-command-preview",
  [switch]$Json
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$RepoRoot = Split-Path -Parent $PSScriptRoot
$VoiceAgentRoot = Join-Path $RepoRoot "control-plane\sword-voice-agent"

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

function Get-Asset {
  param(
    [Parameter(Mandatory = $true)]$Index,
    [Parameter(Mandatory = $true)][string]$Id
  )
  foreach ($asset in @($Index.assets)) {
    if ([string]$asset.id -eq $Id) {
      return $asset
    }
  }
  throw "asset id not found in local/media/media-index.json: $Id"
}

function ConvertTo-SafeLocalMediaRelativePath {
  param([Parameter(Mandatory = $true)][string]$Path)
  if ([System.IO.Path]::IsPathRooted($Path)) {
    throw "media index contains an absolute path; expected local/media relative path"
  }

  $normalized = ($Path -replace "\\", "/").Trim()
  if (-not [string]::IsNullOrWhiteSpace($normalized) -and $normalized -notmatch "^local/media/") {
    throw "media index path must stay under local/media"
  }

  foreach ($segment in ($normalized -split "/")) {
    if ($segment -eq "..") {
      throw "media index path must not contain parent directory segments"
    }
  }

  return $normalized
}

function ConvertTo-WorkspacePlaceholderPath {
  param([string]$RelativePath)
  if ([string]::IsNullOrWhiteSpace($RelativePath)) {
    return "<workspace>\local\media\<asset>"
  }
  return "<workspace>\" + ($RelativePath -replace "/", "\")
}

function Assert-SafeDiagnosticInput {
  param([string]$Path)
  if ([string]::IsNullOrWhiteSpace($Path)) {
    return
  }
  $name = [System.IO.Path]::GetFileName($Path).ToLowerInvariant()
  $extension = [System.IO.Path]::GetExtension($Path).ToLowerInvariant()
  if ($extension -in @(".wav", ".m4a", ".mp3", ".mp4", ".png", ".jpg", ".jpeg")) {
    throw "raw media input is not allowed for redacted voice-gate proof: $name"
  }
  if ($name -match "\.env|token|secret|credential|authorization|api[_-]?key|config") {
    throw "secret/config input is not allowed for redacted voice-gate proof: $name"
  }
}

$resolvedWorkspaceRoot = Get-WorkspaceRoot
$indexPath = Join-Path $resolvedWorkspaceRoot "local\media\media-index.json"
if (-not (Test-Path -LiteralPath $indexPath -PathType Leaf)) {
  throw "local media index not found: local/media/media-index.json; pass -WorkspaceRoot for the workspace that owns local/media"
}

$index = Get-Content -Raw -LiteralPath $indexPath | ConvertFrom-Json
$asset = Get-Asset -Index $index -Id $AssetId
$relativePath = ConvertTo-SafeLocalMediaRelativePath -Path ([string](Get-OptionalProperty -Object $asset -Name "relative_path" -Default ""))
$assetKind = [string](Get-OptionalProperty -Object $asset -Name "kind" -Default "unknown")

Assert-SafeDiagnosticInput -Path $GateEvents
Assert-SafeDiagnosticInput -Path $SttDiagnostic
Assert-SafeDiagnosticInput -Path $ThoughtCoreEvents

if ($Mode -eq "collect-local") {
  $arguments = @(
    "--cache-dir", ".uv-cache",
    "run", "python", "-m", "sword_voice_agent.apps.local_media_voice_gate_proof",
    "--asset-id", $AssetId,
    "--media-index", $indexPath,
    "--mode", "collect-local",
    "--proof-layer", $ProofLayer,
    "--print-json"
  )
  if (-not [string]::IsNullOrWhiteSpace($GateEvents)) {
    $arguments += @("--gate-events", $GateEvents)
  }
  if (-not [string]::IsNullOrWhiteSpace($SttDiagnostic)) {
    $arguments += @("--stt-diagnostic", $SttDiagnostic)
  }
  if (-not [string]::IsNullOrWhiteSpace($ThoughtCoreEvents)) {
    $arguments += @("--thought-core-events", $ThoughtCoreEvents)
  }
  Push-Location $VoiceAgentRoot
  try {
    & uv @arguments
  }
  finally {
    Pop-Location
  }
  return
}

$result = [PSCustomObject]@{
  status = "preview-only"
  proof_layer = "source/static-command-preview"
  next_proof_layer = "virtual audio"
  mode = $Mode
  asset_id = $AssetId
  asset_kind = $assetKind
  duration_sec = Get-OptionalProperty -Object $asset -Name "duration_sec" -Default $null
  media_index = "local/media/media-index.json"
  intended_helper = "sword_voice_agent.apps.local_media_voice_gate_proof"
  intended_modes = @("preview", "collect-local")
  held_proof_layers = @("virtual audio", "real mic", "browser runtime", "live Home Assistant", "long-run/stress")
  raw_media_shared = $false
  raw_transcript_shared = $false
  raw_prompt_shared = $false
  raw_response_shared = $false
  generated_output_written = $false
  live_action_executed = $false
  global_audio_changed = $false
}

if ($Json) {
  $result | ConvertTo-Json -Depth 6
  return
}

Write-Host "Sword Agent OS local media voice-gate proof preview"
Write-Host "status=preview-only"
Write-Host "proof_layer=source/static-command-preview"
Write-Host "next_proof_layer=virtual audio"
Write-Host ("mode={0}" -f $result.mode)
Write-Host ("asset_id={0}" -f $result.asset_id)
Write-Host ("asset_kind={0}" -f $result.asset_kind)
Write-Host ("duration_sec={0}" -f $result.duration_sec)
Write-Host ("media_index={0}" -f $result.media_index)
Write-Host "raw_media_shared=false"
Write-Host "raw_transcript_shared=false"
Write-Host "raw_prompt_shared=false"
Write-Host "raw_response_shared=false"
Write-Host "generated_output_written=false"
Write-Host "live_action_executed=false"
Write-Host "global_audio_changed=false"
Write-Host "no_media_playback=true"
Write-Host "no_stt_execution=true"
Write-Host "no_virtual_audio_route_change=true"
Write-Host "no_real_mic=true"
Write-Host "no_browser_runtime=true"
Write-Host "no_home_assistant_action=true"
