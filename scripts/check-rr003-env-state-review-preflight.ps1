param(
  [string]$EnvironmentStateUrl = "",
  [string]$DisplayStatusUrl = "http://127.0.0.1:8788/api/status",
  [int]$BaselineSamples = 5,
  [int]$FollowupSamples = 5,
  [double]$IntervalSeconds = 1.0,
  [int]$ManualChangeWindowSeconds = 8,
  [double]$MaterialCueLikelihoodDelta = 0.15,
  [int]$TimeoutSeconds = 4,
  [switch]$SkipManualChange,
  [switch]$DryRun,
  [string]$RoomLightFixturePath = "tests/fixtures/room-light-shared-vectors.v1.json",
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

function Assert-FixtureCondition {
  param(
    [Parameter(Mandatory = $true)][bool]$Condition,
    [Parameter(Mandatory = $true)][string]$Message
  )

  if (-not $Condition) {
    throw "room-light shared fixture: $Message"
  }
}

function Assert-FixtureFields {
  param(
    [Parameter(Mandatory = $true)][object]$Object,
    [Parameter(Mandatory = $true)][string[]]$Required,
    [Parameter(Mandatory = $true)][string[]]$Allowed,
    [Parameter(Mandatory = $true)][string]$Context
  )

  Assert-FixtureCondition ($null -ne $Object) "$Context must be an object"
  $actual = @($Object.PSObject.Properties.Name)
  foreach ($name in $actual) {
    Assert-FixtureCondition ($name -cin $Allowed) "$Context contains disallowed field '$name'"
  }
  foreach ($name in $Required) {
    Assert-FixtureCondition ($name -cin $actual) "$Context is missing required field '$name'"
  }
}

function Copy-FixtureValue {
  param([Parameter(Mandatory = $true)][object]$Value)

  return ($Value | ConvertTo-Json -Depth 12 -Compress | ConvertFrom-Json -DateKind String)
}

function Read-RoomLightSharedFixture {
  param([Parameter(Mandatory = $true)][string]$Path)

  $resolvedPath = Resolve-RepoPath -Path $Path
  Assert-FixtureCondition (Test-Path -LiteralPath $resolvedPath -PathType Leaf) "configured fixture is missing"
  $expectedPath = Resolve-RepoPath -Path "tests/fixtures/room-light-shared-vectors.v1.json"
  Assert-FixtureCondition ([string]::Equals($resolvedPath, $expectedPath, [System.StringComparison]::OrdinalIgnoreCase)) "only the owned room-light shared fixture is accepted"
  try {
    $fixture = Get-Content -Raw -LiteralPath $resolvedPath | ConvertFrom-Json -DateKind String
  }
  catch {
    throw "room-light shared fixture: configured fixture is malformed JSON"
  }

  Assert-FixtureFields -Object $fixture -Required @("fixture_version", "fixture_kind", "unknown_field_sentinel", "cases") -Allowed @("fixture_version", "fixture_kind", "unknown_field_sentinel", "cases") -Context "root"
  Assert-FixtureCondition ($fixture.fixture_version -is [string] -and $fixture.fixture_version -ceq "room-light-shared-vectors.v1") "fixture_version mismatch"
  Assert-FixtureCondition ($fixture.fixture_kind -is [string] -and $fixture.fixture_kind -ceq "non_schema_test_vectors") "fixture_kind mismatch"
  Assert-FixtureCondition ($fixture.unknown_field_sentinel -is [string] -and $fixture.unknown_field_sentinel -ceq "fixed-unknown-room-light-sentinel-7e57") "unknown sentinel mismatch"

  $expectedCaseIds = @(
    "canonical_camera_hub",
    "canonical_vision_snapshot_processor",
    "malformed_nested_sequence",
    "wrong_numeric_type",
    "nonfinite_numeric",
    "out_of_range_numeric",
    "wrong_case",
    "stale_freshness",
    "reversed_ordered_nonclaims",
    "non_room_light",
    "unknown_field_non_echo",
    "wrong_proof_ceiling",
    "responsiveness_same_identity_material_movement",
    "responsiveness_changed_identity_no_material_movement",
    "responsiveness_changed_identity_material_movement"
  )
  $cases = @($fixture.cases)
  Assert-FixtureCondition ($cases.Count -eq $expectedCaseIds.Count) "case count mismatch"

  $observationRequired = @("type", "schema_version", "observation_bucket", "confidence", "daylight_ambiguity", "cue_likelihoods", "source", "source_class", "observed_at", "observation_id", "source_snapshot_id", "sequence", "model", "freshness", "proof_ceiling", "does_not_prove")
  $observationAllowed = @($observationRequired + "unknown_test_field")
  for ($index = 0; $index -lt $cases.Count; $index += 1) {
    $case = $cases[$index]
    $context = "case[$index]"
    Assert-FixtureFields -Object $case -Required @("case_id", "baseline", "followup", "expected") -Allowed @("case_id", "baseline", "followup", "expected", "synthetic_numeric_class") -Context $context
    Assert-FixtureCondition ($case.case_id -is [string] -and $case.case_id -ceq $expectedCaseIds[$index]) "$context case_id/order mismatch"
    foreach ($sampleName in @("baseline", "followup")) {
      $sample = Get-ObjectProperty -Object $case -Name $sampleName
      Assert-FixtureFields -Object $sample -Required $observationRequired -Allowed $observationAllowed -Context "$context.$sampleName"
      Assert-FixtureFields -Object $sample.cue_likelihoods -Required @("warm_light", "daylight", "darkness") -Allowed @("warm_light", "daylight", "darkness") -Context "$context.$sampleName.cue_likelihoods"
      Assert-FixtureFields -Object $sample.sequence -Required @("first_frame_id", "last_frame_id", "frame_count", "temporal_window_ms") -Allowed @("first_frame_id", "last_frame_id", "frame_count", "temporal_window_ms") -Context "$context.$sampleName.sequence"
      Assert-FixtureFields -Object $sample.model -Required @("name", "kind") -Allowed @("name", "kind") -Context "$context.$sampleName.model"
      Assert-FixtureFields -Object $sample.freshness -Required @("level") -Allowed @("level") -Context "$context.$sampleName.freshness"
    }
    $baselineUnknown = $null -ne $case.baseline.PSObject.Properties["unknown_test_field"]
    $followupUnknown = $null -ne $case.followup.PSObject.Properties["unknown_test_field"]
    if ($case.case_id -ceq "unknown_field_non_echo") {
      Assert-FixtureCondition (-not $baselineUnknown) "$context baseline must not contain the unknown sentinel"
      Assert-FixtureCondition ($followupUnknown -and $case.followup.unknown_test_field -is [string] -and $case.followup.unknown_test_field -ceq $fixture.unknown_field_sentinel) "$context followup sentinel mismatch"
    }
    else {
      Assert-FixtureCondition (-not $baselineUnknown -and -not $followupUnknown) "$context must not contain the unknown sentinel field"
    }
    Assert-FixtureFields -Object $case.expected -Required @("validation_class", "claim_class", "responsiveness_class", "delta_class", "unknown_echo_class") -Allowed @("validation_class", "claim_class", "responsiveness_class", "delta_class", "unknown_echo_class") -Context "$context.expected"
    Assert-FixtureCondition ($case.expected.validation_class -is [string] -and $case.expected.validation_class -cin @("valid", "invalid")) "$context expected validation class is invalid"
    Assert-FixtureCondition ($case.expected.claim_class -is [string] -and $case.expected.claim_class -cin @("unavailable", "available-but-not-decisive-camera-environment-estimate", "camera-environment-estimate-high-confidence")) "$context expected claim class is invalid"
    Assert-FixtureCondition ($case.expected.responsiveness_class -is [string] -and $case.expected.responsiveness_class -cin @("pass", "partial", "fail")) "$context expected responsiveness class is invalid"
    Assert-FixtureCondition ($case.expected.delta_class -is [string] -and $case.expected.delta_class -cin @("noncanonical_camera_environment_estimate", "material_camera_environment_estimate_change_with_new_observation", "material_camera_environment_estimate_change_without_new_observation", "new_observation_without_material_camera_environment_estimate_change", "no_material_camera_environment_estimate_change")) "$context expected delta class is invalid"
    Assert-FixtureCondition ($case.expected.unknown_echo_class -is [string] -and $case.expected.unknown_echo_class -ceq "not_echoed") "$context expected unknown echo class is invalid"
    $syntheticNumericClass = Get-ObjectProperty -Object $case -Name "synthetic_numeric_class" -Default "none"
    Assert-FixtureCondition ($syntheticNumericClass -is [string] -and $syntheticNumericClass -cin @("none", "followup_confidence_nan")) "$context synthetic_numeric_class is invalid"
    if ($case.case_id -ceq "nonfinite_numeric") {
      Assert-FixtureCondition ($null -ne $case.PSObject.Properties["synthetic_numeric_class"] -and $syntheticNumericClass -ceq "followup_confidence_nan") "$context must carry the fixed nonfinite marker"
    }
    else {
      Assert-FixtureCondition ($null -eq $case.PSObject.Properties["synthetic_numeric_class"]) "$context must not carry a synthetic numeric marker"
    }
  }

  return $fixture
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

function ConvertTo-NullableInt64 {
  param([object]$Value)

  if ($null -eq $Value) {
    return $null
  }
  if ($Value -is [string] -and $Value -notmatch "^-?\d+$") {
    return $null
  }
  try {
    $number = [Int64]$Value
    if ($Value -is [double] -or $Value -is [single] -or $Value -is [decimal]) {
      if ([double]$Value -ne [double]$number) {
        return $null
      }
    }
    return $number
  }
  catch {
    return $null
  }
}

function Test-IsFiniteDouble {
  param([object]$Value)

  $number = ConvertTo-NullableDouble -Value $Value
  if ($null -eq $number) {
    return $false
  }
  return -not [double]::IsNaN($number) -and -not [double]::IsInfinity($number)
}

function Test-CanonicalJsonNumber {
  param([object]$Value)

  if ($null -eq $Value -or $Value -is [bool]) {
    return $false
  }
  if ($Value -isnot [sbyte] -and $Value -isnot [byte] -and $Value -isnot [int16] -and $Value -isnot [uint16] -and $Value -isnot [int32] -and $Value -isnot [uint32] -and $Value -isnot [int64] -and $Value -isnot [uint64] -and $Value -isnot [single] -and $Value -isnot [double] -and $Value -isnot [decimal]) {
    return $false
  }
  $number = [double]$Value
  return -not [double]::IsNaN($number) -and -not [double]::IsInfinity($number)
}

function Test-CanonicalJsonInteger {
  param([object]$Value)

  if (-not (Test-CanonicalJsonNumber -Value $Value)) {
    return $false
  }
  return $null -ne (ConvertTo-NullableInt64 -Value $Value)
}

function Test-CanonicalRoomLightIdentifier {
  param([object]$Value)

  return $Value -is [string] -and -not [string]::IsNullOrWhiteSpace($Value) -and $Value -match "^[\x21-\x7E]{1,160}$"
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

  $vision = Get-ObjectProperty -Object $Payload -Name "vision"
  $roomLight = Get-ObjectProperty -Object $vision -Name "room_light"
  if ($null -eq $roomLight) {
    return $null
  }

  $cueLikelihoods = Get-ObjectProperty -Object $roomLight -Name "cue_likelihoods"
  $freshness = Get-ObjectProperty -Object $roomLight -Name "freshness"

  return [PSCustomObject]@{
    type = Get-ObjectProperty -Object $roomLight -Name "type"
    schema_version = Get-ObjectProperty -Object $roomLight -Name "schema_version"
    observation_bucket = Get-ObjectProperty -Object $roomLight -Name "observation_bucket"
    confidence = Get-ObjectProperty -Object $roomLight -Name "confidence"
    daylight_ambiguity = Get-ObjectProperty -Object $roomLight -Name "daylight_ambiguity"
    cue_likelihoods = [PSCustomObject]@{
      warm_light = Get-ObjectProperty -Object $cueLikelihoods -Name "warm_light"
      daylight = Get-ObjectProperty -Object $cueLikelihoods -Name "daylight"
      darkness = Get-ObjectProperty -Object $cueLikelihoods -Name "darkness"
    }
    source = Get-ObjectProperty -Object $roomLight -Name "source"
    source_class = Get-ObjectProperty -Object $roomLight -Name "source_class"
    observed_at = Get-ObjectProperty -Object $roomLight -Name "observed_at"
    observation_id = Get-ObjectProperty -Object $roomLight -Name "observation_id"
    source_snapshot_id = Get-ObjectProperty -Object $roomLight -Name "source_snapshot_id"
    sequence = Get-ObjectProperty -Object $roomLight -Name "sequence"
    model = Get-ObjectProperty -Object $roomLight -Name "model"
    freshness = $freshness
    proof_ceiling = Get-ObjectProperty -Object $roomLight -Name "proof_ceiling"
    does_not_prove = Get-ObjectProperty -Object $roomLight -Name "does_not_prove"
  }
}

function Get-RoomLightCanonicalValidation {
  param([object]$RoomLight)

  $errors = New-Object System.Collections.Generic.List[string]
  if ($null -eq $RoomLight) {
    $errors.Add("missing_room_light")
  }
  else {
    $type = Get-ObjectProperty -Object $RoomLight -Name "type"
    if ($type -isnot [string] -or $type -cne "room_light_observation") {
      $errors.Add("type")
    }
    $schemaVersion = Get-ObjectProperty -Object $RoomLight -Name "schema_version"
    if (-not (Test-CanonicalJsonInteger -Value $schemaVersion) -or (ConvertTo-NullableInt64 -Value $schemaVersion) -ne 1) {
      $errors.Add("schema_version")
    }
    $observationBucket = Get-ObjectProperty -Object $RoomLight -Name "observation_bucket"
    if ($observationBucket -isnot [string] -or $observationBucket -cnotin @("dark", "dim", "balanced", "bright")) {
      $errors.Add("observation_bucket")
    }

    foreach ($field in @("confidence")) {
      $value = Get-ObjectProperty -Object $RoomLight -Name $field
      if (-not (Test-CanonicalJsonNumber -Value $value) -or $value -lt 0 -or $value -gt 1) {
        $errors.Add($field)
      }
    }
    $cues = Get-ObjectProperty -Object $RoomLight -Name "cue_likelihoods"
    foreach ($field in @("warm_light", "daylight", "darkness")) {
      $value = Get-ObjectProperty -Object $cues -Name $field
      if (-not (Test-CanonicalJsonNumber -Value $value) -or $value -lt 0 -or $value -gt 1) {
        $errors.Add("cue_likelihoods_$field")
      }
    }

    $daylightAmbiguity = Get-ObjectProperty -Object $RoomLight -Name "daylight_ambiguity"
    if ($daylightAmbiguity -isnot [string] -or $daylightAmbiguity -cnotin @("low", "medium", "high")) {
      $errors.Add("daylight_ambiguity")
    }
    $source = Get-ObjectProperty -Object $RoomLight -Name "source"
    if ($source -isnot [string] -or $source -cnotin @("camera_hub", "vision_snapshot_processor")) {
      $errors.Add("source")
    }
    $sourceClass = Get-ObjectProperty -Object $RoomLight -Name "source_class"
    if ($sourceClass -isnot [string] -or $sourceClass -cne "camera_environment_estimate") {
      $errors.Add("source_class")
    }

    $observedAt = Get-ObjectProperty -Object $RoomLight -Name "observed_at"
    $parsedObservedAt = [DateTimeOffset]::MinValue
    if ($observedAt -isnot [string] -or [string]::IsNullOrWhiteSpace($observedAt) -or -not [DateTimeOffset]::TryParse($observedAt, [ref]$parsedObservedAt)) {
      $errors.Add("observed_at")
    }
    foreach ($field in @("observation_id", "source_snapshot_id")) {
      if (-not (Test-CanonicalRoomLightIdentifier -Value (Get-ObjectProperty -Object $RoomLight -Name $field))) {
        $errors.Add($field)
      }
    }

    $sequence = Get-ObjectProperty -Object $RoomLight -Name "sequence"
    $firstFrameIdValue = Get-ObjectProperty -Object $sequence -Name "first_frame_id"
    $lastFrameIdValue = Get-ObjectProperty -Object $sequence -Name "last_frame_id"
    $frameCountValue = Get-ObjectProperty -Object $sequence -Name "frame_count"
    $temporalWindowMsValue = Get-ObjectProperty -Object $sequence -Name "temporal_window_ms"
    $firstFrameId = if (Test-CanonicalJsonInteger -Value $firstFrameIdValue) { ConvertTo-NullableInt64 -Value $firstFrameIdValue } else { $null }
    $lastFrameId = if (Test-CanonicalJsonInteger -Value $lastFrameIdValue) { ConvertTo-NullableInt64 -Value $lastFrameIdValue } else { $null }
    $frameCount = if (Test-CanonicalJsonInteger -Value $frameCountValue) { ConvertTo-NullableInt64 -Value $frameCountValue } else { $null }
    $temporalWindowMs = if (Test-CanonicalJsonInteger -Value $temporalWindowMsValue) { ConvertTo-NullableInt64 -Value $temporalWindowMsValue } else { $null }
    if ($null -eq $sequence) { $errors.Add("sequence") }
    if ($null -eq $firstFrameId -or $firstFrameId -lt 0) { $errors.Add("first_frame_id") }
    if ($null -eq $lastFrameId -or $lastFrameId -lt 0 -or ($null -ne $firstFrameId -and $lastFrameId -lt $firstFrameId)) { $errors.Add("last_frame_id") }
    if ($null -eq $frameCount -or $frameCount -le 0 -or ($null -ne $firstFrameId -and $null -ne $lastFrameId -and $frameCount -gt ($lastFrameId - $firstFrameId + 1))) { $errors.Add("frame_count") }
    if ($null -eq $temporalWindowMs -or $temporalWindowMs -lt 0) { $errors.Add("temporal_window_ms") }

    $model = Get-ObjectProperty -Object $RoomLight -Name "model"
    $modelName = Get-ObjectProperty -Object $model -Name "name"
    if ($modelName -isnot [string] -or $modelName -cne "room-light-heuristic-snapshot-v3") {
      $errors.Add("model_name")
    }
    $modelKind = Get-ObjectProperty -Object $model -Name "kind"
    if ($modelKind -isnot [string] -or $modelKind -cne "heuristic") {
      $errors.Add("model_kind")
    }
    $proofCeiling = Get-ObjectProperty -Object $RoomLight -Name "proof_ceiling"
    if ($proofCeiling -isnot [string] -or $proofCeiling -cne "camera_environment_estimate_only") {
      $errors.Add("proof_ceiling")
    }
    $doesNotProve = Get-ObjectProperty -Object $RoomLight -Name "does_not_prove"
    $requiredNonClaims = @("physical_room_light_state", "home_assistant_light_state")
    if ($doesNotProve -isnot [System.Collections.IList] -or $doesNotProve.Count -ne $requiredNonClaims.Count) {
      $errors.Add("does_not_prove")
    }
    else {
      for ($index = 0; $index -lt $requiredNonClaims.Count; $index += 1) {
        if ($doesNotProve[$index] -isnot [string] -or $doesNotProve[$index] -cne $requiredNonClaims[$index]) {
          $errors.Add("does_not_prove")
          break
        }
      }
    }

    $freshness = Get-ObjectProperty -Object $RoomLight -Name "freshness"
    if ($null -ne $freshness) {
      $freshnessLevel = Get-ObjectProperty -Object $freshness -Name "level"
      if ($freshnessLevel -isnot [string] -or $freshnessLevel -cnotin @("fresh", "recent", "stale")) {
        $errors.Add("freshness")
      }
    }
  }

  return [PSCustomObject]@{
    valid = $errors.Count -eq 0
    status = if ($errors.Count -eq 0) { "valid" } else { "invalid" }
    error_count = $errors.Count
    error_classes = @($errors | Select-Object -Unique)
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
  $roomLightObservedAt = if ($null -ne $roomLight) { $roomLight.observed_at } else { "" }
  $roomLightSourceSnapshotId = if ($null -ne $roomLight) { $roomLight.source_snapshot_id } else { "" }
  $advanceMarker = "{0}|{1}|{2}|{3}|{4}" -f `
    (Get-ObjectProperty -Object $payload -Name "sequence" -Default ""), `
    (Get-ObjectProperty -Object $payload -Name "snapshot_id" -Default ""), `
    $sourceMarker, `
    $roomLightObservedAt, `
    $roomLightSourceSnapshotId

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

  $validation = Get-RoomLightCanonicalValidation -RoomLight $RoomLight
  if (-not [bool]$validation.valid) {
    return "unavailable"
  }
  $freshness = Get-ObjectProperty -Object $RoomLight -Name "freshness"
  $freshnessLevel = ([string](Get-ObjectProperty -Object $freshness -Name "level" -Default "")).ToLowerInvariant()
  if ($freshnessLevel -eq "stale") {
    return "unavailable"
  }
  $bucket = ([string](Get-ObjectProperty -Object $RoomLight -Name "observation_bucket" -Default "")).ToLowerInvariant()
  $confidence = ConvertTo-NullableDouble (Get-ObjectProperty -Object $RoomLight -Name "confidence")
  $daylightAmbiguity = ([string](Get-ObjectProperty -Object $RoomLight -Name "daylight_ambiguity" -Default "")).ToLowerInvariant()
  if ($bucket -notin @("dark", "dim", "balanced", "bright") -or $null -eq $confidence -or $confidence -lt 0.7 -or $daylightAmbiguity -ne "low") {
    return "available-but-not-decisive-camera-environment-estimate"
  }
  return "camera-environment-estimate-high-confidence"
}

function Get-RoomLightDelta {
  param(
    [object]$Before,
    [object]$After
  )

  $beforeValidation = Get-RoomLightCanonicalValidation -RoomLight $Before
  $afterValidation = Get-RoomLightCanonicalValidation -RoomLight $After
  if (-not [bool]$beforeValidation.valid -or -not [bool]$afterValidation.valid) {
    return [PSCustomObject]@{
      material = $false
      bucket_changed = $false
      cue_likelihood_delta_max = $null
      observation_changed = $false
      canonical_before = $beforeValidation.status
      canonical_after = $afterValidation.status
      detail = "noncanonical_camera_environment_estimate"
    }
  }

  $validBuckets = @("dark", "dim", "balanced", "bright")
  $beforeBucket = ([string](Get-ObjectProperty -Object $Before -Name "observation_bucket" -Default "")).ToLowerInvariant()
  $afterBucket = ([string](Get-ObjectProperty -Object $After -Name "observation_bucket" -Default "")).ToLowerInvariant()
  $bucketChanged = $beforeBucket -in $validBuckets -and $afterBucket -in $validBuckets -and $beforeBucket -ne $afterBucket
  $sourceSnapshotChanged = [string](Get-ObjectProperty -Object $Before -Name "source_snapshot_id" -Default "") -ne [string](Get-ObjectProperty -Object $After -Name "source_snapshot_id" -Default "")
  $observationChanged = [string](Get-ObjectProperty -Object $Before -Name "observation_id" -Default "") -ne [string](Get-ObjectProperty -Object $After -Name "observation_id" -Default "")
  $beforeCues = Get-ObjectProperty -Object $Before -Name "cue_likelihoods"
  $afterCues = Get-ObjectProperty -Object $After -Name "cue_likelihoods"
  $deltas = @()
  foreach ($field in @("warm_light", "daylight", "darkness")) {
    $left = ConvertTo-NullableDouble (Get-ObjectProperty -Object $beforeCues -Name $field)
    $right = ConvertTo-NullableDouble (Get-ObjectProperty -Object $afterCues -Name $field)
    if ($null -ne $left -and $null -ne $right) {
      $deltas += [Math]::Abs($right - $left)
    }
  }
  $deltaMax = if ($deltas.Count -gt 0) { [Math]::Round((($deltas | Measure-Object -Maximum).Maximum), 4) } else { $null }
  $materialEstimateChange = $bucketChanged -or ($null -ne $deltaMax -and $deltaMax -ge $MaterialCueLikelihoodDelta)
  $material = $observationChanged -and $materialEstimateChange

  return [PSCustomObject]@{
    material = $material
    bucket_changed = $bucketChanged
    cue_likelihood_delta_max = $deltaMax
    observation_changed = $observationChanged
    source_snapshot_changed = $sourceSnapshotChanged
    canonical_before = $beforeValidation.status
    canonical_after = $afterValidation.status
    detail = if ($material) {
      "material_camera_environment_estimate_change_with_new_observation"
    }
    elseif ($materialEstimateChange) {
      "material_camera_environment_estimate_change_without_new_observation"
    }
    elseif ($observationChanged) {
      "new_observation_without_material_camera_environment_estimate_change"
    }
    else {
      "no_material_camera_environment_estimate_change"
    }
  }
}

function Get-RoomLightResponsiveness {
  param(
    [object[]]$Baseline,
    [object[]]$Followup,
    [string]$Claim,
    [bool]$ManualChangeSkipped = $SkipManualChange
  )

  if ($ManualChangeSkipped) {
    return [PSCustomObject]@{
      status = "partial"
      delta = $null
      detail = "camera_environment_estimate_manual_change_window_skipped"
      proof_ceiling = "camera_environment_estimate_only"
    }
  }

  $beforeSample = Get-LastOkSample -Samples $Baseline
  $afterSample = Get-LastOkSample -Samples $Followup
  if ($null -eq $beforeSample -or $null -eq $afterSample) {
    return [PSCustomObject]@{
      status = "fail"
      delta = $null
      detail = "camera_environment_estimate_missing_ok_sample"
      proof_ceiling = "camera_environment_estimate_only"
    }
  }

  $delta = Get-RoomLightDelta -Before $beforeSample.room_light -After $afterSample.room_light
  if (-not [bool]$delta.material) {
    return [PSCustomObject]@{
      status = "fail"
      delta = $delta
      detail = "no_material_camera_environment_estimate_change"
      proof_ceiling = "camera_environment_estimate_only"
    }
  }
  $afterClaim = Get-RoomLightClaim -RoomLight $afterSample.room_light
  if ($Claim -eq "camera-environment-estimate-high-confidence" -and $afterClaim -eq "camera-environment-estimate-high-confidence") {
    return [PSCustomObject]@{
      status = "pass"
      delta = $delta
      detail = "material_change_with_high_confidence_camera_environment_estimate"
      proof_ceiling = "camera_environment_estimate_only"
    }
  }
  return [PSCustomObject]@{
    status = "partial"
    delta = $delta
    detail = "material_change_but_camera_environment_estimate_not_decisive"
    proof_ceiling = "camera_environment_estimate_only"
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
    $RoomLightClaim -eq "camera-environment-estimate-high-confidence" -and
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
  $sharedFixture = Read-RoomLightSharedFixture -Path $RoomLightFixturePath
  $fixtureCaseResults = @()
  foreach ($fixtureCase in @($sharedFixture.cases)) {
    $baselineObservation = Copy-FixtureValue -Value $fixtureCase.baseline
    $followupObservation = Copy-FixtureValue -Value $fixtureCase.followup
    if ((Get-ObjectProperty -Object $fixtureCase -Name "synthetic_numeric_class" -Default "none") -ceq "followup_confidence_nan") {
      $followupObservation.confidence = [double]::NaN
    }

    $validation = Get-RoomLightCanonicalValidation -RoomLight $followupObservation
    $claim = Get-RoomLightClaim -RoomLight $followupObservation
    $responsiveness = Get-RoomLightResponsiveness `
      -Baseline @([PSCustomObject]@{ ok = $true; room_light = $baselineObservation }) `
      -Followup @([PSCustomObject]@{ ok = $true; room_light = $followupObservation }) `
      -Claim $claim `
      -ManualChangeSkipped $false
    $summary = Get-RoomLightSummary -Payload ([PSCustomObject]@{ vision = [PSCustomObject]@{ room_light = $followupObservation } })
    $summaryJson = $summary | ConvertTo-Json -Depth 8 -Compress
    $unknownEchoClass = if ($summaryJson.Contains([string]$sharedFixture.unknown_field_sentinel, [System.StringComparison]::Ordinal)) { "echoed" } else { "not_echoed" }
    $deltaClass = if ($null -eq $responsiveness.delta) { "none" } else { [string]$responsiveness.delta.detail }
    $actual = [ordered]@{
      validation_class = [string]$validation.status
      claim_class = [string]$claim
      responsiveness_class = [string]$responsiveness.status
      delta_class = $deltaClass
      unknown_echo_class = $unknownEchoClass
    }
    $mismatches = @($actual.Keys | Where-Object { $actual[$_] -cne [string](Get-ObjectProperty -Object $fixtureCase.expected -Name $_) })
    $fixtureCaseResults += [PSCustomObject]@{
      case_id = [string]$fixtureCase.case_id
      expected_class = if ($mismatches.Count -eq 0) { "matched" } else { "mismatch" }
      mismatch_fields = @($mismatches)
      validation_errors = @($validation.error_classes)
      actual_classes = [PSCustomObject]$actual
      status = if ($mismatches.Count -eq 0) { "pass" } else { "fail" }
    }
  }
  $sharedFixtureStatus = if (@($fixtureCaseResults | Where-Object { $_.status -ne "pass" }).Count -eq 0) { "pass" } else { "fail" }
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
    room_light_shared_fixture = [PSCustomObject]@{
      fixture_version = [string]$sharedFixture.fixture_version
      fixture_kind = [string]$sharedFixture.fixture_kind
      status = $sharedFixtureStatus
      case_count = $fixtureCaseResults.Count
      validation_count = $fixtureCaseResults.Count
      cases = @($fixtureCaseResults | ForEach-Object {
        [PSCustomObject]@{
          case_id = $_.case_id
          expected_class = $_.expected_class
          mismatch_fields = @($_.mismatch_fields)
          validation_errors = @($_.validation_errors)
          actual_classes = $_.actual_classes
          status = $_.status
        }
      })
    }
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
    Write-Host ("room_light_shared_fixture={0} case_count={1}" -f $sharedFixtureStatus, $fixtureCaseResults.Count)
    Write-Host "raw_media_saved=false raw_secret_shared=false live_appliance_action_executed=false"
  }
  if ($sharedFixtureStatus -ne "pass") {
    exit 1
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
    "not_electric_light_state_truth",
    "not_physical_switch_position_truth",
    "not_physical_room_illuminance",
    "not_live_appliance_execution",
    "bridge_ok_is_connection_only_not_live_mode",
    "daylight_ambiguity_or_low_confidence_is_not_decisive_camera_environment_estimate",
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
