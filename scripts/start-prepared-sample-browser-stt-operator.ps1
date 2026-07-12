param(
  [Parameter(Mandatory = $true)]
  [string]$AssetId,

  [string]$ConversationAttemptRef = "",
  [string]$WorkspaceRoot = "",
  [switch]$OpenBrowser,
  [switch]$Json
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$RepoRoot = Split-Path -Parent $PSScriptRoot
$PreparedSampleIdPattern = "^[a-z][a-z0-9_.-]{2,127}$"
$ConversationAttemptRefPattern = "^m4\.prepared_sample_attempt:[a-f0-9]{32}$"
$OpaqueRefPattern = "^[a-z][a-z0-9_.:-]{2,127}$"

function Get-WorkspaceRoot {
  if (-not [string]::IsNullOrWhiteSpace($WorkspaceRoot)) {
    return [System.IO.Path]::GetFullPath($WorkspaceRoot)
  }

  $parentWorkspace = Split-Path -Parent $RepoRoot
  $parentIndex = Join-Path $parentWorkspace "local\media\media-index.json"
  if (Test-Path -LiteralPath $parentIndex -PathType Leaf) {
    return [System.IO.Path]::GetFullPath($parentWorkspace)
  }

  throw "local media workspace is required; pass -WorkspaceRoot for the workspace that owns local/media"
}

function Assert-PreparedSampleId {
  param([Parameter(Mandatory = $true)][string]$Value, [Parameter(Mandatory = $true)][string]$Label)
  if ($Value -notmatch $PreparedSampleIdPattern) {
    throw "$Label must be a prepared sample ID"
  }
}

function Assert-OpaqueRef {
  param([Parameter(Mandatory = $true)][string]$Value, [Parameter(Mandatory = $true)][string]$Label)
  if ($Value -notmatch $OpaqueRefPattern) {
    throw "$Label must be a safe opaque reference"
  }
}

function Assert-ConversationAttemptRef {
  param([Parameter(Mandatory = $true)][string]$Value)
  if ($Value -notmatch $ConversationAttemptRefPattern) {
    throw "ConversationAttemptRef must be exactly m4.prepared_sample_attempt:<32 lowercase hex>"
  }
}

function ConvertTo-SafeLocalMediaRelativePath {
  param([Parameter(Mandatory = $true)][string]$Path)
  if ([System.IO.Path]::IsPathRooted($Path)) {
    throw "media index contains an absolute path; expected a local/media relative path"
  }

  $normalized = ($Path -replace "\\", "/").Trim()
  if ($normalized -notmatch "^local/media/") {
    throw "media index path must stay under local/media"
  }
  if (($normalized -split "/") -contains "..") {
    throw "media index path must not contain parent directory segments"
  }
  return $normalized
}

function New-OpaqueRef {
  param([Parameter(Mandatory = $true)][string]$Prefix)
  return "$Prefix$([guid]::NewGuid().ToString('N'))"
}

function New-ConversationAttemptRef {
  return "m4.prepared_sample_attempt:$([guid]::NewGuid().ToString('N'))"
}

function New-SourceStaticJoinRow {
  param([Parameter(Mandatory = $true)][string]$RowName)
  return [PSCustomObject]@{
    row_name = $RowName
    observation_status = "not_observed_source_static"
    observation_count = $null
    observed_conversation_attempt_ref = $null
  }
}

Assert-PreparedSampleId -Value $AssetId -Label "AssetId"
$resolvedWorkspaceRoot = Get-WorkspaceRoot
$indexPath = Join-Path $resolvedWorkspaceRoot "local\media\media-index.json"
if (-not (Test-Path -LiteralPath $indexPath -PathType Leaf)) {
  throw "local media index not found: local/media/media-index.json"
}

$index = Get-Content -Raw -LiteralPath $indexPath | ConvertFrom-Json
if ($index.schema_version -ne 1) {
  throw "local media index schema_version must be exactly 1"
}

$matches = @($index.assets | Where-Object { [string]$_.id -eq $AssetId })
if ($matches.Count -ne 1) {
  throw "AssetId must exist exactly once in local/media/media-index.json"
}
$asset = $matches[0]
if ([string]$asset.kind -ne "audio") {
  throw "prepared sample browser STT operator requires an audio asset"
}
$relativePath = ConvertTo-SafeLocalMediaRelativePath -Path ([string]$asset.relative_path)
$selectedFile = Join-Path $resolvedWorkspaceRoot ($relativePath -replace "/", [System.IO.Path]::DirectorySeparatorChar)
if (-not (Test-Path -LiteralPath $selectedFile -PathType Leaf)) {
  throw "selected local media asset file is missing"
}

if ([string]::IsNullOrWhiteSpace($ConversationAttemptRef)) {
  $ConversationAttemptRef = New-ConversationAttemptRef
}
Assert-ConversationAttemptRef -Value $ConversationAttemptRef
$sampleIndexPreflightRef = New-OpaqueRef -Prefix "m4.sample_index_preflight_"
$sampleIndexPreflightClass = "prepared_sample_index_verified"
$sourceStaticJoinRowNames = @(
  "recognition",
  "input_gate",
  "thought_core_turninput",
  "canonical_assistant_response",
  "bubble",
  "tts",
  "bubble_tts_parity",
  "self_mirror_observation",
  "self_output_session_correlation",
  "user_heard"
)
$sourceStaticJoinEnvelope = [PSCustomObject]@{
  proof_layer = "source_static_preflight_only"
  required_row_names = $sourceStaticJoinRowNames
  rows = @($sourceStaticJoinRowNames | ForEach-Object { New-SourceStaticJoinRow -RowName $_ })
  required_conversation_attempt_ref = $ConversationAttemptRef
  whole_loop_pass_rule = "exact_same_valid_conversation_attempt_ref_across_every_required_row"
  correlation_basis = "conversation_attempt_ref_only"
  correlation_inference_prohibited_from = @("text", "message_id", "turn_id", "session_id")
  missing_or_mismatched_required_row_result = "fails_or_not_observed"
  new_service_or_schema_or_compatibility_route = $false
  raw_private_text_shared = $false
  raw_paths_shared = $false
  audio_or_media_shared = $false
  provider_payload_shared = $false
  browser_storage_shared = $false
  logs_shared = $false
  tokens_or_secrets_shared = $false
}
$query = @(
  "conversation_attempt_ref=$([uri]::EscapeDataString($ConversationAttemptRef))",
  "selected_sample_id=$([uri]::EscapeDataString($AssetId))",
  "sample_index_preflight_class=$([uri]::EscapeDataString($sampleIndexPreflightClass))",
  "sample_index_preflight_ref=$([uri]::EscapeDataString($sampleIndexPreflightRef))"
) -join "&"
$operatorUrl = "http://127.0.0.1:3000/operator/prepared-sample-stt/?$query"

$result = [PSCustomObject]@{
  status = "preflight_ready"
  proof_ceiling = "source_static_preflight_only"
  selected_asset_id = $AssetId
  selected_asset_file_exists = $true
  media_index = "local/media/media-index.json"
  conversation_attempt_ref = $ConversationAttemptRef
  sample_index_preflight_class = $sampleIndexPreflightClass
  sample_index_preflight_ref = $sampleIndexPreflightRef
  bounded_attempt_count = 5
  attempt_timeout_ms = 10000
  operator_url = $operatorUrl
  browser_open_requested = [bool]$OpenBrowser
  browser_launch_executed = $false
  raw_path_shared = $false
  raw_media_shared = $false
  raw_transcript_shared = $false
  private_input_shared = $false
  provider_payload_shared = $false
  token_or_secret_shared = $false
  browser_storage_used = $false
  audio_playback_executed = $false
  browser_page_reachability_proven = $false
  browser_stt_runtime_executed = $false
  turn_input_materialized = $false
  source_static_join_envelope = $sourceStaticJoinEnvelope
}

if ($OpenBrowser) {
  Start-Process $operatorUrl
  $result.browser_launch_executed = $true
  $result.proof_ceiling = "source_static_preflight_plus_browser_launch_only"
}

if ($Json) {
  $result | ConvertTo-Json -Depth 6
  return
}

Write-Host "status=preflight_ready"
Write-Host ("proof_ceiling={0}" -f $result.proof_ceiling)
Write-Host ("selected_asset_id={0}" -f $result.selected_asset_id)
Write-Host ("conversation_attempt_ref={0}" -f $result.conversation_attempt_ref)
Write-Host ("sample_index_preflight_class={0}" -f $result.sample_index_preflight_class)
Write-Host ("sample_index_preflight_ref={0}" -f $result.sample_index_preflight_ref)
Write-Host "bounded_attempt_count=5"
Write-Host "attempt_timeout_ms=10000"
Write-Host ("operator_url={0}" -f $result.operator_url)
Write-Host ("browser_open_requested={0}" -f ([string]$result.browser_open_requested).ToLowerInvariant())
Write-Host ("browser_launch_executed={0}" -f ([string]$result.browser_launch_executed).ToLowerInvariant())
Write-Host "raw_path_shared=false"
Write-Host "raw_media_shared=false"
Write-Host "raw_transcript_shared=false"
Write-Host "private_input_shared=false"
Write-Host "provider_payload_shared=false"
Write-Host "token_or_secret_shared=false"
Write-Host "browser_storage_used=false"
Write-Host "audio_playback_executed=false"
Write-Host "browser_page_reachability_proven=false"
Write-Host "browser_stt_runtime_executed=false"
Write-Host "turn_input_materialized=false"
Write-Host ("source_static_join_envelope_proof_layer={0}" -f $result.source_static_join_envelope.proof_layer)
Write-Host ("source_static_join_required_row_names={0}" -f ($result.source_static_join_envelope.required_row_names -join ","))
Write-Host ("source_static_join_whole_loop_pass_rule={0}" -f $result.source_static_join_envelope.whole_loop_pass_rule)
Write-Host ("source_static_join_correlation_basis={0}" -f $result.source_static_join_envelope.correlation_basis)
Write-Host ("source_static_join_missing_or_mismatched_required_row_result={0}" -f $result.source_static_join_envelope.missing_or_mismatched_required_row_result)
foreach ($row in @($result.source_static_join_envelope.rows)) {
  Write-Host ("source_static_join_row.{0}={1}" -f $row.row_name, $row.observation_status)
}
