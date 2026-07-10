param(
  [string]$WorkspaceRoot = "",
  [string]$SecretInputsRoot = "",
  [string]$SeedFile = "",
  [switch]$DryRun,
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
  if (Test-Path -LiteralPath (Join-Path $parentWorkspace "_secret_inputs") -PathType Container) {
    return [System.IO.Path]::GetFullPath($parentWorkspace)
  }

  return [System.IO.Path]::GetFullPath($RepoRoot)
}

function Get-SeedFile {
  param([Parameter(Mandatory = $true)][string]$ResolvedSecretRoot)

  if (-not [string]::IsNullOrWhiteSpace($SeedFile)) {
    return [System.IO.Path]::GetFullPath($SeedFile)
  }

  return Join-Path $ResolvedSecretRoot "local-media-index.seed.json"
}

function Get-SecretInputsRoot {
  param([Parameter(Mandatory = $true)][string]$ResolvedWorkspaceRoot)

  if (-not [string]::IsNullOrWhiteSpace($SecretInputsRoot)) {
    return [System.IO.Path]::GetFullPath($SecretInputsRoot)
  }

  return Join-Path $ResolvedWorkspaceRoot "_secret_inputs"
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

function Assert-SafeAssetId {
  param([Parameter(Mandatory = $true)][string]$Id)
  if ($Id -notmatch "^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$") {
    throw "asset id contains unsupported characters: $Id"
  }
}

function Assert-SafeKind {
  param([Parameter(Mandatory = $true)][string]$Kind)
  if ($Kind -notin @("video", "audio")) {
    throw "asset kind must be video or audio"
  }
}

function Assert-SafeSourcePath {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$SecretRoot
  )

  $fullPath = [System.IO.Path]::GetFullPath($Path)
  $fullSecretRoot = [System.IO.Path]::GetFullPath($SecretRoot).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)

  if (-not $fullPath.StartsWith($fullSecretRoot + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "source media must stay under _secret_inputs"
  }
  if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
    throw "source media file is missing for asset"
  }

  $extension = [System.IO.Path]::GetExtension($fullPath).ToLowerInvariant()
  if ($extension -notin @(".mp4", ".mov", ".mkv", ".webm", ".wav", ".m4a", ".mp3")) {
    throw "unsupported local media extension for asset"
  }

  return $fullPath
}

function Get-SafeOutputRelativePath {
  param(
    [Parameter(Mandatory = $true)][string]$AssetId,
    [Parameter(Mandatory = $true)][string]$SourcePath
  )

  $extension = [System.IO.Path]::GetExtension($SourcePath).ToLowerInvariant()
  $safeBase = ($AssetId -replace "[^A-Za-z0-9_.-]", "_")
  return "local/media/assets/$safeBase$extension"
}

function Write-PreparationResult {
  param(
    [Parameter(Mandatory = $true)][string]$Status,
    [Parameter(Mandatory = $true)][string]$Detail,
    [string[]]$AssetIds = @()
  )

  $indexStatus = if ($Status -eq "dry-run") { "planned" } else { "ready" }
  $assetStatus = if ($AssetIds.Count -gt 0) { $indexStatus } else { "missing-seed-assets" }
  $result = [PSCustomObject]@{
    status = $Status
    proof_layer = "local-preparation"
    detail = $Detail
    workspace = "<workspace>"
    secret_inputs_root = "<secret-inputs>"
    seed_file = "_secret_inputs/local-media-index.seed.json"
    media_index = "local/media/media-index.json"
    asset_count = $AssetIds.Count
    asset_ids = @($AssetIds)
    raw_media_shared = $false
    raw_paths_printed = $false
    raw_transcript_shared = $false
    live_action_executed = $false
    consumer_readiness_map = @(
      [PSCustomObject]@{
        id = "local.media_index"
        status = $indexStatus
        output = "local/media/media-index.json"
        consumers = @("scripts/run-local-media-replay.ps1", "scripts/start-prepared-sample-browser-stt-operator.ps1")
        proof_ceiling = "local-media-index-only"
      },
      [PSCustomObject]@{
        id = "local.media_assets"
        status = $assetStatus
        output = "local/media/assets/"
        consumers = @("gesture replay", "room-light replay", "prepared-sample browser STT operator preflight")
        proof_ceiling = "local-media-preparation-only"
      }
    )
    intentionally_not_copied = @("secrets", "tokens", "raw transcripts", "live Home Assistant config", "provider payloads")
  }

  if ($Json) {
    $result | ConvertTo-Json -Depth 6
    return
  }

  Write-Host "Sword Agent OS local media index preparation"
  Write-Host ("status={0}" -f $result.status)
  Write-Host "proof_layer=local-preparation"
  Write-Host ("detail={0}" -f $result.detail)
  Write-Host ("seed_file={0}" -f $result.seed_file)
  Write-Host ("media_index={0}" -f $result.media_index)
  Write-Host ("asset_count={0}" -f $result.asset_count)
  Write-Host ("asset_ids={0}" -f (($result.asset_ids) -join ","))
  Write-Host "consumer_map=local.media_index->run-local-media-replay.ps1,start-prepared-sample-browser-stt-operator.ps1"
  Write-Host "consumer_map=local.media_assets->gesture replay,room-light replay,prepared-sample browser-STT operator preflight / exact conversation_attempt_ref correlation"
  Write-Host "intentionally_not_copied=secrets,tokens,raw transcripts,live Home Assistant config,provider payloads"
  Write-Host "raw_media_shared=false"
  Write-Host "raw_paths_printed=false"
  Write-Host "raw_transcript_shared=false"
  Write-Host "live_action_executed=false"
}

$resolvedWorkspaceRoot = Get-WorkspaceRoot
$secretRoot = Get-SecretInputsRoot -ResolvedWorkspaceRoot $resolvedWorkspaceRoot
$resolvedSeedFile = Get-SeedFile -ResolvedSecretRoot $secretRoot
$indexPath = Join-Path $resolvedWorkspaceRoot "local\media\media-index.json"
$assetRoot = Join-Path $resolvedWorkspaceRoot "local\media\assets"

if (-not (Test-Path -LiteralPath $resolvedSeedFile -PathType Leaf)) {
  Write-PreparationResult -Status "blocked" -Detail "local media seed file not found"
  exit 1
}

if (-not (Test-Path -LiteralPath $secretRoot -PathType Container)) {
  Write-PreparationResult -Status "blocked" -Detail "secret input root not found"
  exit 1
}

$seed = Get-Content -Raw -LiteralPath $resolvedSeedFile | ConvertFrom-Json
$assets = @()
$copies = @()
$seenAssetIds = @{}

foreach ($asset in @($seed.assets)) {
  $id = [string](Get-OptionalProperty -Object $asset -Name "id" -Default "")
  $kind = [string](Get-OptionalProperty -Object $asset -Name "kind" -Default "")
  $source = [string](Get-OptionalProperty -Object $asset -Name "source_path" -Default "")

  if ([string]::IsNullOrWhiteSpace($id)) {
    throw "seed asset is missing id"
  }
  if ([string]::IsNullOrWhiteSpace($kind)) {
    throw "seed asset is missing kind"
  }
  if ([string]::IsNullOrWhiteSpace($source)) {
    throw "seed asset is missing source_path"
  }

  Assert-SafeAssetId -Id $id
  if ($seenAssetIds.ContainsKey($id)) {
    Write-PreparationResult -Status "blocked" -Detail "duplicate asset id in seed"
    exit 1
  }
  $seenAssetIds[$id] = $true
  Assert-SafeKind -Kind $kind

  if (-not [System.IO.Path]::IsPathRooted($source)) {
    $source = Join-Path $secretRoot $source
  }
  $sourcePath = Assert-SafeSourcePath -Path $source -SecretRoot $secretRoot
  $relativePath = Get-SafeOutputRelativePath -AssetId $id -SourcePath $sourcePath
  $targetPath = Join-Path $resolvedWorkspaceRoot ($relativePath -replace "/", [System.IO.Path]::DirectorySeparatorChar)

  $assetRecord = [ordered]@{
    id = $id
    kind = $kind
    relative_path = $relativePath
  }

  $duration = Get-OptionalProperty -Object $asset -Name "duration_sec" -Default $null
  if ($null -ne $duration) {
    $assetRecord.duration_sec = $duration
  }

  $assets += [PSCustomObject]$assetRecord
  $copies += [PSCustomObject]@{
    id = $id
    source_path = $sourcePath
    target_path = $targetPath
  }
}

$index = [ordered]@{
  schema_version = 1
  generated_by = "scripts/prepare-local-media-index.ps1"
  assets = $assets
}

if (-not $DryRun) {
  New-Item -ItemType Directory -Force -Path $assetRoot | Out-Null
  foreach ($copy in $copies) {
    Copy-Item -LiteralPath $copy.source_path -Destination $copy.target_path -Force
  }
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $indexPath) | Out-Null
  $index | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $indexPath -Encoding UTF8
}

Write-PreparationResult `
  -Status $(if ($DryRun) { "dry-run" } else { "ok" }) `
  -Detail $(if ($DryRun) { "local media index preparation can run" } else { "local media index prepared" }) `
  -AssetIds @($assets | ForEach-Object { $_.id })
