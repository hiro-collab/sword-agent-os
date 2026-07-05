param(
  [string]$EnvironmentStateUrl = "",
  [string]$DisplayStatusUrl = "http://127.0.0.1:8788/api/status",
  [int]$BaselineSamples = 5,
  [int]$FollowupSamples = 5,
  [double]$IntervalSeconds = 1.0,
  [int]$ManualChangeWindowSeconds = 8,
  [double]$MaterialProbabilityDelta = 0.15,
  [int]$TimeoutSeconds = 4,
  [switch]$SkipManualChange,
  [switch]$DryRun,
  [switch]$Json
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$RepoRoot = Split-Path -Parent $PSScriptRoot

function Resolve-RepoPath {
  param([Parameter(Mandatory = $true)][string]$Path)
  if ([System.IO.Path]::IsPathRooted($Path)) {
    return [System.IO.Path]::GetFullPath($Path)
  }
  return [System.IO.Path]::GetFullPath((Join-Path $RepoRoot ($Path -replace "/", [System.IO.Path]::DirectorySeparatorChar)))
}

function Read-DotEnvMap {
  param([Parameter(Mandatory = $true)][string]$Path)

  $map = [ordered]@{}
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    return ,$map
  }

  foreach ($line in Get-Content -LiteralPath $Path) {
    $trimmed = $line.Trim()
    if ([string]::IsNullOrWhiteSpace($trimmed) -or $trimmed.StartsWith("#")) {
      continue
    }
    $separatorIndex = $trimmed.IndexOf("=")
    if ($separatorIndex -lt 1) {
      continue
    }
    $key = $trimmed.Substring(0, $separatorIndex).Trim()
    $value = $trimmed.Substring($separatorIndex + 1).Trim()
    if ($value.Length -ge 2) {
      $quote = $value.Substring(0, 1)
      if (($quote -eq '"' -or $quote -eq "'") -and $value.EndsWith($quote)) {
        $value = $value.Substring(1, $value.Length - 2)
      }
    }
    $map[$key] = $value
  }
  return ,$map
}

function Get-MapValue {
  param(
    [object]$Map,
    [Parameter(Mandatory = $true)][string]$Name,
    [string]$Default = ""
  )

  if ($null -eq $Map) {
    return $Default
  }
  if ($Map.Contains($Name)) {
    return [string]$Map[$Name]
  }
  return $Default
}

function Get-ObjectProperty {
  param(
    [object]$Object,
    [Parameter(Mandatory = $true)][string]$Name,
    [object]$Default = $null
  )

  if ($null -eq $Object) {
    return $Default
  }
  $property = $Object.PSObject.Properties[$Name]
  if ($null -eq $property -or $null -eq $property.Value) {
    return $Default
  }
  return $property.Value
}

function ConvertTo-AdapterMode {
  param([string]$Value)

  $normalized = ([string]$Value).Trim().ToLowerInvariant() -replace "[-\s]+", "_"
  if ($normalized -in @("mock", "local_mock", "no_live", "dry_run")) {
    return "mock"
  }
  if ($normalized -in @("home_control", "home_assistant", "live_home", "bridge")) {
    return "home_control"
  }
  return "unknown"
}

function Get-TokenStatus {
  param([string]$Value)

  $trimmed = ([string]$Value).Trim()
  if ([string]::IsNullOrWhiteSpace($trimmed)) {
    return "missing"
  }
  if (
    $trimmed -match "^REPLACE_WITH_" -or
    $trimmed -match "^CHANGE_ME" -or
    $trimmed -match "^YOUR_" -or
    $trimmed -match "CHANGEME" -or
    $trimmed.Length -lt 16
  ) {
    return "placeholder"
  }
  return "present"
}

function Get-FirstEnvValue {
  param(
    [object[]]$Maps,
    [Parameter(Mandatory = $true)][string]$Name
  )

  foreach ($map in $Maps) {
    $value = Get-MapValue -Map $map -Name $Name
    if (-not [string]::IsNullOrWhiteSpace($value)) {
      return $value
    }
  }
  return ""
}

function ConvertTo-EnvironmentCurrentUrl {
  param(
    [string]$ExplicitUrl,
    [string]$EnvUrl
  )

  $candidate = if (-not [string]::IsNullOrWhiteSpace($ExplicitUrl)) {
    $ExplicitUrl
  }
  elseif (-not [string]::IsNullOrWhiteSpace($EnvUrl)) {
    $EnvUrl
  }
  else {
    "http://127.0.0.1:8790/environment/current"
  }

  $trimmed = $candidate.Trim()
  if ($trimmed -match "/environment/current(\?.*)?$") {
    return $trimmed
  }
  return ($trimmed.TrimEnd("/") + "/environment/current")
}

function Invoke-JsonGet {
  param(
    [Parameter(Mandatory = $true)][string]$Url,
    [hashtable]$Headers = @{}
  )

  try {
    $request = @{
      Uri = $Url
      Method = "Get"
      TimeoutSec = $TimeoutSeconds
      UseBasicParsing = $true
    }
    if ($Headers.Count -gt 0) {
      $request.Headers = $Headers
    }
    $response = Invoke-WebRequest @request
    $payload = if ([string]::IsNullOrWhiteSpace([string]$response.Content)) {
      $null
    }
    else {
      $response.Content | ConvertFrom-Json
    }
    return [PSCustomObject]@{
      ok = $true
      status_code = [int]$response.StatusCode
      payload = $payload
      error = ""
    }
  }
  catch {
    $responseProperty = $_.Exception.PSObject.Properties["Response"]
    $response = if ($null -ne $responseProperty) { $responseProperty.Value } else { $null }
    $statusCode = 0
    if ($null -ne $response -and $null -ne $response.StatusCode) {
      $statusCode = [int]$response.StatusCode
    }
    return [PSCustomObject]@{
      ok = $false
      status_code = $statusCode
      payload = $null
      error = $_.Exception.Message
    }
  }
}

function ConvertTo-NullableDouble {
  param([object]$Value)

  if ($null -eq $Value) {
    return $null
  }
  try {
    return [double]$Value
  }
  catch {
    return $null
  }
}

function Get-SourceSummary {
  param(
    [object]$Sources,
    [Parameter(Mandatory = $true)][string]$SourceName
  )

  $source = Get-ObjectProperty -Object $Sources -Name $SourceName
  if ($null -eq $source) {
    return [PSCustomObject]@{
      label = "unavailable"
      available = $false
      stale = $true
      age_ms = $null
      updated_at = ""
      detail = "missing"
    }
  }

  $freshness = Get-ObjectProperty -Object $source -Name "freshness"
  $age = ConvertTo-NullableDouble (Get-ObjectProperty -Object $freshness -Name "age_ms" -Default (Get-ObjectProperty -Object $source -Name "age_ms"))
  $level = [string](Get-ObjectProperty -Object $freshness -Name "level" -Default "")
  $availableValue = Get-ObjectProperty -Object $source -Name "available" -Default $null
  $staleValue = Get-ObjectProperty -Object $source -Name "stale" -Default $null
  $available = if ($null -eq $availableValue) { $true } else { [bool]$availableValue }
  $stale = if ($null -eq $staleValue) { $false } else { [bool]$staleValue }
  $updatedAt = [string](Get-ObjectProperty -Object $freshness -Name "updated_at" -Default (Get-ObjectProperty -Object $source -Name "updated_at" -Default ""))

  $label = "recent"
  if (-not $available) {
    $label = "unavailable"
  }
  elseif ($stale -or $level -eq "stale") {
    $label = "stale"
  }
  elseif ($level -in @("fresh", "recent")) {
    $label = $level
  }
  elseif ($null -ne $age) {
    if ($age -le 5000) {
      $label = "fresh"
    }
    elseif ($age -le 30000) {
      $label = "recent"
    }
    else {
      $label = "stale"
    }
  }

  return [PSCustomObject]@{
    label = $label
    available = $available
    stale = $stale
    age_ms = $age
    updated_at = $updatedAt
    detail = if ([string]::IsNullOrWhiteSpace($level)) { "level_unspecified" } else { "level=$level" }
  }
}

function Get-RoomLightSummary {
  param([object]$Payload)

  $stateQueries = Get-ObjectProperty -Object $Payload -Name "state_queries"
  $roomLight = Get-ObjectProperty -Object $stateQueries -Name "room_light"
  if ($null -eq $roomLight) {
    return [PSCustomObject]@{
      available = $false
      stale = $true
      state = "unknown"
      confidence_label = "none"
      electric_on_probability = $null
      daylight_present_probability = $null
      dark_probability = $null
      updated_at = ""
      source_snapshot_id = ""
      freshness_level = "stale"
      evidence = "missing"
    }
  }

  $evidence = Get-ObjectProperty -Object $roomLight -Name "evidence"
  $freshness = Get-ObjectProperty -Object $roomLight -Name "freshness"
  $state = [string](Get-ObjectProperty -Object $roomLight -Name "state" -Default "unknown")
  $confidence = [string](Get-ObjectProperty -Object $roomLight -Name "confidence_label" -Default "none")

  return [PSCustomObject]@{
    available = [bool](Get-ObjectProperty -Object $roomLight -Name "available" -Default $false)
    stale = [bool](Get-ObjectProperty -Object $roomLight -Name "stale" -Default $true)
    state = $state
    confidence_label = $confidence
    electric_on_probability = ConvertTo-NullableDouble (Get-ObjectProperty -Object $evidence -Name "electric_on_probability")
    daylight_present_probability = ConvertTo-NullableDouble (Get-ObjectProperty -Object $evidence -Name "daylight_present_probability")
    dark_probability = ConvertTo-NullableDouble (Get-ObjectProperty -Object $evidence -Name "dark_probability")
    updated_at = [string](Get-ObjectProperty -Object $roomLight -Name "updated_at" -Default "")
    source_snapshot_id = [string](Get-ObjectProperty -Object $roomLight -Name "source_snapshot_id" -Default "")
    freshness_level = [string](Get-ObjectProperty -Object $freshness -Name "level" -Default "")
    evidence = "summary_only"
  }
}

function New-EnvironmentSample {
  param(
    [Parameter(Mandatory = $true)][string]$Phase,
    [Parameter(Mandatory = $true)][int]$Index,
    [Parameter(Mandatory = $true)][string]$Url,
    [hashtable]$Headers
  )

  $probe = Invoke-JsonGet -Url $Url -Headers $Headers
  $payload = $probe.payload
  $sources = Get-ObjectProperty -Object $payload -Name "sources"
  $sourceSummaries = [ordered]@{}
  foreach ($sourceName in @("home_assistant", "camera_hub", "vision_snapshot_processor", "home_assistant_events")) {
    $sourceSummaries[$sourceName] = Get-SourceSummary -Sources $sources -SourceName $sourceName
  }
  $roomLight = Get-RoomLightSummary -Payload $payload
  $sourceMarker = (@($sourceSummaries.Values | ForEach-Object { "{0}:{1}:{2}" -f $_.label, $_.updated_at, $_.age_ms }) -join "|")
  $advanceMarker = "{0}|{1}|{2}|{3}|{4}" -f `
    (Get-ObjectProperty -Object $payload -Name "sequence" -Default ""), `
    (Get-ObjectProperty -Object $payload -Name "snapshot_id" -Default ""), `
    $sourceMarker, `
    $roomLight.updated_at, `
    $roomLight.source_snapshot_id

  return [PSCustomObject]@{
    phase = $Phase
    index = $Index
    ok = [bool]$probe.ok
    status_code = [int]$probe.status_code
    error_class = if ($probe.ok) { "" } elseif ($probe.status_code -eq 401 -or $probe.status_code -eq 403) { "auth_required_or_rejected" } elseif ($probe.status_code -gt 0) { "http_error" } else { "connection_error" }
    checked_at = (Get-Date).ToString("o")
    sequence = Get-ObjectProperty -Object $payload -Name "sequence" -Default $null
    snapshot_id = [string](Get-ObjectProperty -Object $payload -Name "snapshot_id" -Default "")
    source_freshness = [PSCustomObject]$sourceSummaries
    room_light = $roomLight
    advance_marker = $advanceMarker
  }
}

function Collect-EnvironmentSamples {
  param(
    [Parameter(Mandatory = $true)][string]$Phase,
    [Parameter(Mandatory = $true)][int]$Count,
    [Parameter(Mandatory = $true)][string]$Url,
    [hashtable]$Headers
  )

  $samples = @()
  if ($Count -le 0) {
    return $samples
  }

  for ($index = 0; $index -lt $Count; $index += 1) {
    $samples += New-EnvironmentSample -Phase $Phase -Index $index -Url $Url -Headers $Headers
    if ($index -lt ($Count - 1) -and $IntervalSeconds -gt 0) {
      Start-Sleep -Milliseconds ([int][Math]::Max(0, [Math]::Round($IntervalSeconds * 1000)))
    }
  }
  return $samples
}

function Get-EnvironmentUpdateStatus {
  param([object[]]$Samples)

  $okSamples = @($Samples | Where-Object { $_.ok })
  if ($okSamples.Count -eq 0) {
    return "fail"
  }
  if ($okSamples.Count -lt 2) {
    return "partial"
  }
  $markers = @($okSamples | ForEach-Object { [string]$_.advance_marker } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
  if ($markers.Count -gt 1) {
    return "pass"
  }
  return "partial"
}

function Get-LastOkSample {
  param([object[]]$Samples)
  $okSamples = @($Samples | Where-Object { $_.ok } | Select-Object -Last 1)
  if ($okSamples.Count -eq 0) {
    return $null
  }
  return $okSamples[0]
}

function Get-RoomLightClaim {
  param([object]$RoomLight)

  if ($null -eq $RoomLight -or -not [bool]$RoomLight.available -or [bool]$RoomLight.stale) {
    return "unavailable"
  }
  $state = ([string]$RoomLight.state).ToLowerInvariant()
  $confidence = ([string]$RoomLight.confidence_label).ToLowerInvariant()
  if ($state -notin @("on", "off") -or $confidence -notin @("high")) {
    return "available-but-not-decisive-camera-light-estimate"
  }
  return "camera-light-estimate-high-confidence"
}

function Get-RoomLightDelta {
  param(
    [object]$Before,
    [object]$After
  )

  if ($null -eq $Before -or $null -eq $After) {
    return [PSCustomObject]@{
      material = $false
      state_changed = $false
      probability_delta_max = $null
      snapshot_changed = $false
      detail = "missing_sample"
    }
  }

  $stateChanged = [string]$Before.state -ne [string]$After.state
  $snapshotChanged = [string]$Before.source_snapshot_id -ne [string]$After.source_snapshot_id -or [string]$Before.updated_at -ne [string]$After.updated_at
  $deltas = @()
  foreach ($field in @("electric_on_probability", "daylight_present_probability", "dark_probability")) {
    $left = ConvertTo-NullableDouble (Get-ObjectProperty -Object $Before -Name $field)
    $right = ConvertTo-NullableDouble (Get-ObjectProperty -Object $After -Name $field)
    if ($null -ne $left -and $null -ne $right) {
      $deltas += [Math]::Abs($right - $left)
    }
  }
  $deltaMax = if ($deltas.Count -gt 0) { [Math]::Round((($deltas | Measure-Object -Maximum).Maximum), 4) } else { $null }
  $material = $stateChanged -or ($null -ne $deltaMax -and $deltaMax -ge $MaterialProbabilityDelta)

  return [PSCustomObject]@{
    material = $material
    state_changed = $stateChanged
    probability_delta_max = $deltaMax
    snapshot_changed = $snapshotChanged
    detail = if ($material) { "material_change" } elseif ($snapshotChanged) { "snapshot_changed_without_material_light_change" } else { "no_material_change" }
  }
}

function Get-RoomLightResponsiveness {
  param(
    [object[]]$Baseline,
    [object[]]$Followup,
    [string]$Claim
  )

  if ($SkipManualChange) {
    return [PSCustomObject]@{
      status = "partial"
      delta = $null
      detail = "manual_change_window_skipped"
    }
  }

  $beforeSample = Get-LastOkSample -Samples $Baseline
  $afterSample = Get-LastOkSample -Samples $Followup
  if ($null -eq $beforeSample -or $null -eq $afterSample) {
    return [PSCustomObject]@{
      status = "fail"
      delta = $null
      detail = "missing_ok_sample"
    }
  }

  $delta = Get-RoomLightDelta -Before $beforeSample.room_light -After $afterSample.room_light
  if (-not [bool]$delta.material) {
    return [PSCustomObject]@{
      status = "fail"
      delta = $delta
      detail = "no_material_room_light_change"
    }
  }
  if ($Claim -eq "camera-light-estimate-high-confidence") {
    return [PSCustomObject]@{
      status = "pass"
      delta = $delta
      detail = "material_change_with_high_confidence_camera_light_estimate"
    }
  }
  return [PSCustomObject]@{
    status = "partial"
    delta = $delta
    detail = "material_change_but_low_confidence_or_daylight"
  }
}

function Get-HudStatusSummary {
  param(
    [string]$Url,
    [string]$ExpectedMode
  )

  if ([string]::IsNullOrWhiteSpace($Url)) {
    return [PSCustomObject]@{
      visibility = "not_checked"
      mode = "unknown"
      bridge_state = "unknown"
      detail = "display_status_url_empty"
    }
  }

  $probe = Invoke-JsonGet -Url $Url
  if (-not $probe.ok -or $null -eq $probe.payload) {
    return [PSCustomObject]@{
      visibility = "not_checked"
      mode = "unknown"
      bridge_state = "unknown"
      detail = if ($probe.status_code -gt 0) { "http_$($probe.status_code)" } else { "status_endpoint_unavailable" }
    }
  }

  $payload = $probe.payload
  $modeNode = Get-ObjectProperty -Object $payload -Name "homeActionMode"
  $rawMode = [string](Get-ObjectProperty -Object $modeNode -Name "mode" -Default "")
  $mode = ConvertTo-AdapterMode -Value $rawMode
  if ($rawMode -eq "live_home") {
    $mode = "home_control"
  }
  $services = Get-ObjectProperty -Object $payload -Name "services"
  $bridge = Get-ObjectProperty -Object $services -Name "home_assistant_bridge"
  $bridgeState = [string](Get-ObjectProperty -Object $bridge -Name "state" -Default "unknown")

  $visibility = "partial"
  $detail = "mode_unknown_or_env_unknown"
  if ($mode -ne "unknown" -and $ExpectedMode -ne "unknown" -and $mode -eq $ExpectedMode) {
    $visibility = "pass"
    $detail = "hud_mode_matches_env"
  }
  elseif ($mode -ne "unknown" -and $ExpectedMode -ne "unknown" -and $mode -ne $ExpectedMode) {
    $visibility = "fail"
    $detail = "hud_mode_mismatch"
  }

  return [PSCustomObject]@{
    visibility = $visibility
    mode = $mode
    bridge_state = $bridgeState
    detail = $detail
  }
}

function ConvertTo-OverallStatus {
  param(
    [string]$EnvironmentStatePeriodicUpdate,
    [object]$SourceFreshness,
    [string]$RoomLightResponsiveness,
    [string]$RoomLightClaim,
    [string]$HomeActionMode,
    [string]$HudModeVisibility
  )

  if ($EnvironmentStatePeriodicUpdate -eq "fail") {
    return "fail"
  }
  $sourceValues = @(
    $SourceFreshness.home_assistant,
    $SourceFreshness.camera_hub,
    $SourceFreshness.vision_snapshot_processor,
    $SourceFreshness.home_assistant_events
  )
  if (@($sourceValues | Where-Object { $_ -eq "unavailable" }).Count -gt 0) {
    return "partial"
  }
  if (
    $EnvironmentStatePeriodicUpdate -eq "pass" -and
    @($sourceValues | Where-Object { $_ -in @("fresh", "recent") }).Count -eq 4 -and
    $RoomLightResponsiveness -eq "pass" -and
    $RoomLightClaim -eq "camera-light-estimate-high-confidence" -and
    $HomeActionMode -ne "unknown" -and
    $HudModeVisibility -eq "pass"
  ) {
    return "pass"
  }
  return "partial"
}

$centralEnvPath = Resolve-RepoPath "local/env/sword-agent-os.env"
$controlPlaneEnvPath = Resolve-RepoPath "control-plane/core/.env"
$thoughtCoreEnvPath = Resolve-RepoPath "control-plane/core/services/thought-core/.env"
$homeAssistantEnvPath = Resolve-RepoPath "organs/action/home-assistant-server/.env"
$centralEnv = Read-DotEnvMap -Path $centralEnvPath
$controlPlaneEnv = Read-DotEnvMap -Path $controlPlaneEnvPath
$thoughtCoreEnv = Read-DotEnvMap -Path $thoughtCoreEnvPath
$homeAssistantEnv = Read-DotEnvMap -Path $homeAssistantEnvPath

$centralAdapter = ConvertTo-AdapterMode -Value (Get-MapValue -Map $centralEnv -Name "THOUGHT_CORE_TOOLS_ADAPTER")
$controlPlaneAdapter = ConvertTo-AdapterMode -Value (Get-MapValue -Map $controlPlaneEnv -Name "THOUGHT_CORE_TOOLS_ADAPTER")
$thoughtCoreAdapter = ConvertTo-AdapterMode -Value (Get-MapValue -Map $thoughtCoreEnv -Name "THOUGHT_CORE_TOOLS_ADAPTER")
$generatedAdapter = if ($thoughtCoreAdapter -ne "unknown") { $thoughtCoreAdapter } elseif ($controlPlaneAdapter -ne "unknown") { $controlPlaneAdapter } else { "unknown" }
$effectiveAdapter = if ($generatedAdapter -ne "unknown") { $generatedAdapter } elseif ($centralAdapter -ne "unknown") { $centralAdapter } else { "unknown" }
$adapterConsistency = if ($centralAdapter -eq "unknown" -or $generatedAdapter -eq "unknown") {
  "partial"
}
elseif ($centralAdapter -eq $generatedAdapter) {
  "pass"
}
else {
  "fail"
}

$environmentToken = Get-FirstEnvValue -Maps @($homeAssistantEnv, $centralEnv) -Name "ENVIRONMENT_API_TOKEN"
if ([string]::IsNullOrWhiteSpace($environmentToken)) {
  $environmentToken = Get-FirstEnvValue -Maps @($homeAssistantEnv, $centralEnv) -Name "HOME_CONTROL_API_TOKEN"
}
$environmentTokenStatus = Get-TokenStatus -Value $environmentToken
$headers = @{}
if ($environmentTokenStatus -eq "present") {
  $headers["Authorization"] = "Bearer $environmentToken"
}

$environmentCurrentUrl = ConvertTo-EnvironmentCurrentUrl `
  -ExplicitUrl $EnvironmentStateUrl `
  -EnvUrl (Get-MapValue -Map $centralEnv -Name "ENVIRONMENT_STATE_URL")

if ($DryRun) {
  $dryRunResult = [PSCustomObject]@{
    status = "dry-run"
    checked_at = (Get-Date).ToString("o")
    environment_current_endpoint = "loopback:/environment/current"
    display_status_endpoint = "loopback:/api/status"
    baseline_samples = $BaselineSamples
    followup_samples = $FollowupSamples
    manual_change_window_seconds = $ManualChangeWindowSeconds
    skip_manual_change = [bool]$SkipManualChange
    home_action_mode = $effectiveAdapter
    adapter_consistency = $adapterConsistency
    token_status = [PSCustomObject]@{
      environment_api_token = $environmentTokenStatus
      home_control_api_token = Get-TokenStatus -Value (Get-FirstEnvValue -Maps @($homeAssistantEnv, $centralEnv) -Name "HOME_CONTROL_API_TOKEN")
      home_assistant_token = Get-TokenStatus -Value (Get-FirstEnvValue -Maps @($homeAssistantEnv, $centralEnv) -Name "HOME_ASSISTANT_TOKEN")
    }
    raw_media_saved = $false
    raw_media_shared = $false
    raw_secret_shared = $false
    live_appliance_action_executed = $false
  }
  if ($Json) {
    $dryRunResult | ConvertTo-Json -Depth 8
  }
  else {
    Write-Host "RR003 Environment State review preflight dry-run"
    Write-Host "status=dry-run"
    Write-Host "environment_current_endpoint=loopback:/environment/current"
    Write-Host "display_status_endpoint=loopback:/api/status"
    Write-Host ("home_action_mode={0}" -f $effectiveAdapter)
    Write-Host "raw_media_saved=false raw_secret_shared=false live_appliance_action_executed=false"
  }
  return
}

$baseline = @(Collect-EnvironmentSamples -Phase "baseline" -Count $BaselineSamples -Url $environmentCurrentUrl -Headers $headers)
if (-not $SkipManualChange) {
  Write-Information "Change the visible room-light condition now. The helper will sample again after the bounded wait window." -InformationAction Continue
  if ($ManualChangeWindowSeconds -gt 0) {
    Start-Sleep -Seconds $ManualChangeWindowSeconds
  }
}
$followup = @(Collect-EnvironmentSamples -Phase "followup" -Count $FollowupSamples -Url $environmentCurrentUrl -Headers $headers)
$allSamples = @($baseline + $followup)
$lastSample = Get-LastOkSample -Samples $allSamples

$periodicUpdate = Get-EnvironmentUpdateStatus -Samples $allSamples
$sourceFreshness = [PSCustomObject]@{
  home_assistant = if ($null -ne $lastSample) { $lastSample.source_freshness.home_assistant.label } else { "unavailable" }
  camera_hub = if ($null -ne $lastSample) { $lastSample.source_freshness.camera_hub.label } else { "unavailable" }
  vision_snapshot_processor = if ($null -ne $lastSample) { $lastSample.source_freshness.vision_snapshot_processor.label } else { "unavailable" }
  home_assistant_events = if ($null -ne $lastSample) { $lastSample.source_freshness.home_assistant_events.label } else { "unavailable" }
}
$roomLight = if ($null -ne $lastSample) { $lastSample.room_light } else { $null }
$roomLightClaim = Get-RoomLightClaim -RoomLight $roomLight
$roomLightResponsiveness = Get-RoomLightResponsiveness -Baseline $baseline -Followup $followup -Claim $roomLightClaim
$hud = Get-HudStatusSummary -Url $DisplayStatusUrl -ExpectedMode $effectiveAdapter

$overall = ConvertTo-OverallStatus `
  -EnvironmentStatePeriodicUpdate $periodicUpdate `
  -SourceFreshness $sourceFreshness `
  -RoomLightResponsiveness $roomLightResponsiveness.status `
  -RoomLightClaim $roomLightClaim `
  -HomeActionMode $effectiveAdapter `
  -HudModeVisibility $hud.visibility

$result = [PSCustomObject]@{
  overall = $overall
  checked_at = (Get-Date).ToString("o")
  environment_state_periodic_update = $periodicUpdate
  source_freshness = $sourceFreshness
  room_light_responsiveness = $roomLightResponsiveness.status
  room_light_claim = $roomLightClaim
  home_action_mode = $effectiveAdapter
  hud_mode_visibility = $hud.visibility
  details = [PSCustomObject]@{
    endpoint = "loopback:/environment/current"
    display_status_endpoint = "loopback:/api/status"
    baseline_samples_ok = @($baseline | Where-Object { $_.ok }).Count
    baseline_samples_total = @($baseline).Count
    followup_samples_ok = @($followup | Where-Object { $_.ok }).Count
    followup_samples_total = @($followup).Count
    adapter = [PSCustomObject]@{
      central_env = $centralAdapter
      generated_control_plane_env = $controlPlaneAdapter
      generated_thought_core_service_env = $thoughtCoreAdapter
      generated_thought_core_env = $generatedAdapter
      consistency = $adapterConsistency
    }
    token_status = [PSCustomObject]@{
      environment_api_token = $environmentTokenStatus
      home_control_api_token = Get-TokenStatus -Value (Get-FirstEnvValue -Maps @($homeAssistantEnv, $centralEnv) -Name "HOME_CONTROL_API_TOKEN")
      home_assistant_token = Get-TokenStatus -Value (Get-FirstEnvValue -Maps @($homeAssistantEnv, $centralEnv) -Name "HOME_ASSISTANT_TOKEN")
    }
    room_light = $roomLight
    room_light_delta = $roomLightResponsiveness.delta
    hud = $hud
  }
  non_claims = @(
    "not_raw_camera_or_media_proof",
    "not_home_assistant_physical_state_proof",
    "not_open_loop_appliance_on_off_proof",
    "not_live_appliance_execution",
    "bridge_ok_is_connection_only_not_live_mode",
    "unknown_daylight_or_low_confidence_is_not_robust_electric_light_recognition",
    "not_rr003_representative_pass",
    "not_strict_distribution_release_green"
  )
  raw_media_saved = $false
  raw_media_shared = $false
  raw_secret_shared = $false
  live_appliance_action_executed = $false
}

if ($Json) {
  $result | ConvertTo-Json -Depth 12
}
else {
  Write-Host "RR003 Environment State review preflight"
  Write-Host ("overall: {0}" -f $result.overall)
  Write-Host ("environment_state_periodic_update: {0}" -f $result.environment_state_periodic_update)
  Write-Host "source_freshness:"
  Write-Host ("  home_assistant: {0}" -f $result.source_freshness.home_assistant)
  Write-Host ("  camera_hub: {0}" -f $result.source_freshness.camera_hub)
  Write-Host ("  vision_snapshot_processor: {0}" -f $result.source_freshness.vision_snapshot_processor)
  Write-Host ("  home_assistant_events: {0}" -f $result.source_freshness.home_assistant_events)
  Write-Host ("room_light_responsiveness: {0}" -f $result.room_light_responsiveness)
  Write-Host ("room_light_claim: {0}" -f $result.room_light_claim)
  Write-Host ("home_action_mode: {0}" -f $result.home_action_mode)
  Write-Host ("hud_mode_visibility: {0}" -f $result.hud_mode_visibility)
  Write-Host ("samples: baseline {0}/{1}, followup {2}/{3}" -f $result.details.baseline_samples_ok, $result.details.baseline_samples_total, $result.details.followup_samples_ok, $result.details.followup_samples_total)
  Write-Host ("tokens: environment_api_token={0}, home_control_api_token={1}, home_assistant_token={2}" -f $result.details.token_status.environment_api_token, $result.details.token_status.home_control_api_token, $result.details.token_status.home_assistant_token)
  Write-Host "non_claims:"
  foreach ($claim in $result.non_claims) {
    Write-Host ("  - {0}" -f $claim)
  }
}

if ($overall -eq "fail") {
  exit 1
}
