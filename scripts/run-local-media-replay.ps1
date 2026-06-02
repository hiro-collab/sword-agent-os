param(
  [Parameter(Mandatory = $true)]
  [ValidateSet("camera-hub", "room-light")]
  [string]$Mode,

  [Parameter(Mandatory = $true)]
  [string]$AssetId,

  [string]$WorkspaceRoot = "",
  [int]$CameraHubPort = 8765,
  [int]$VisionSnapshotPort = 8776,
  [switch]$Json
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$RepoRoot = Split-Path -Parent $PSScriptRoot

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

function ConvertTo-SafeLocalMediaRelativePath {
  param([Parameter(Mandatory = $true)][string]$Path)
  if ([System.IO.Path]::IsPathRooted($Path)) {
    throw "media index contains an absolute path; expected local/media relative path"
  }

  $normalized = ($Path -replace "\\", "/").Trim()
  if ($normalized -notmatch "^local/media/") {
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
  param([Parameter(Mandatory = $true)][string]$RelativePath)
  return "<workspace>\" + ($RelativePath -replace "/", "\")
}

function ConvertTo-WorkspacePlaceholderUri {
  param([Parameter(Mandatory = $true)][string]$RelativePath)
  return ("file:" + "//" + "/<workspace-uri>/") + $RelativePath
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

function New-PreviewCommand {
  param(
    [Parameter(Mandatory = $true)][string]$ReplayMode,
    [Parameter(Mandatory = $true)]$Asset,
    [Parameter(Mandatory = $true)][string]$RelativePath
  )

  if ($ReplayMode -eq "camera-hub") {
    return @(
      "cd <workspace>\sword-agent-os\organs\reflex\mediapipe-sword-sign",
      ("uv run python apps\serve_camera_hub.py --host 127.0.0.1 --port {0} --replay-video {1} --no-replay-loop --interval 0.033 --gesture-every 0.1 --gesture-model-complexity 0 --publish-jpeg-every 0" -f $CameraHubPort, (ConvertTo-WorkspacePlaceholderPath -RelativePath $RelativePath))
    )
  }

  $frameId = (([string]$Asset.id) -replace "[^A-Za-z0-9_]+", "_").Trim("_")
  if ([string]::IsNullOrWhiteSpace($frameId)) {
    $frameId = "local_media_room_light"
  }
  return @(
    "cd <workspace>\sword-agent-os\organs\environment\vision-snapshot-processor",
    ("uv run python -m vision_snapshot_processor.main --host 127.0.0.1 --port {0} --camera-source {1} --frame-id {2} --processor room_light --sample-every 0.2 --min-frames 2" -f $VisionSnapshotPort, (ConvertTo-WorkspacePlaceholderUri -RelativePath $RelativePath), $frameId)
  )
}

$resolvedWorkspaceRoot = Get-WorkspaceRoot
$indexPath = Join-Path $resolvedWorkspaceRoot "local\media\media-index.json"
if (-not (Test-Path -LiteralPath $indexPath -PathType Leaf)) {
  throw "local media index not found: local/media/media-index.json; pass -WorkspaceRoot for the workspace that owns local/media"
}

$index = Get-Content -Raw -LiteralPath $indexPath | ConvertFrom-Json
$asset = Get-Asset -Index $index -Id $AssetId
$relativePath = ConvertTo-SafeLocalMediaRelativePath -Path ([string]$asset.relative_path)
$assetKind = [string](Get-OptionalProperty -Object $asset -Name "kind" -Default "")
if ($assetKind -ne "video") {
  throw "local media replay preview requires a video asset for this helper"
}
if ($Mode -eq "camera-hub" -and $AssetId -notmatch "^gesture\.") {
  throw "camera-hub preview expects a gesture.* asset id"
}
if ($Mode -eq "room-light" -and $AssetId -notmatch "^vision\.room_light\.") {
  throw "room-light preview expects a vision.room_light.* asset id"
}

$localMediaFile = Join-Path $resolvedWorkspaceRoot ($relativePath -replace "/", [System.IO.Path]::DirectorySeparatorChar)
$preview = New-PreviewCommand -ReplayMode $Mode -Asset $asset -RelativePath $relativePath

$result = [PSCustomObject]@{
  status = "preview-only"
  proof_layer = "source/static-command-preview"
  next_proof_layer = "bounded local-media replay"
  mode = $Mode
  asset_id = $AssetId
  asset_kind = $assetKind
  relative_path = $relativePath
  duration_sec = Get-OptionalProperty -Object $asset -Name "duration_sec" -Default $null
  media_index = "local/media/media-index.json"
  local_file_present = [bool](Test-Path -LiteralPath $localMediaFile -PathType Leaf)
  preview_command = $preview
  raw_media_shared = $false
  raw_transcript_shared = $false
  generated_output_written = $false
  live_action_executed = $false
}

if ($Json) {
  $result | ConvertTo-Json -Depth 6
  return
}

Write-Host "Sword Agent OS local media replay preview"
Write-Host "status=preview-only"
Write-Host "proof_layer=source/static-command-preview"
Write-Host "next_proof_layer=bounded local-media replay"
Write-Host ("mode={0}" -f $result.mode)
Write-Host ("asset_id={0}" -f $result.asset_id)
Write-Host ("relative_path={0}" -f $result.relative_path)
Write-Host ("duration_sec={0}" -f $result.duration_sec)
Write-Host ("media_index={0}" -f $result.media_index)
Write-Host ("local_file_present={0}" -f ([string]$result.local_file_present).ToLowerInvariant())
Write-Host "raw_media_shared=false"
Write-Host "raw_transcript_shared=false"
Write-Host "generated_output_written=false"
Write-Host "live_action_executed=false"
Write-Host ""
Write-Host "preview_command:"
foreach ($line in $result.preview_command) {
  Write-Host ("  {0}" -f $line)
}
