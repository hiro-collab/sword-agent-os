param(
  [string]$BodyPlanPath = "manifests/body-plans/system-cell-v0.json",
  [string]$DriverManifestPath = "manifests/driver-manifests/system-cell-v0.json",
  [string]$StatusPath = ".cache/agent-os/status/current.json",
  [string]$BodySchemaOutputPath = ".cache/agent-os/body-schema/current.json",
  [string]$ProjectionOutputPath = ".cache/agent-os/body-display-projection/latest.json",
  [string]$BodySchemaContractPath = "contracts/body_schema_snapshot/body_schema_snapshot.v0.schema.json",
  [string]$ProjectionContractPath = "contracts/body_display_projection/body_display_projection.v0.schema.json",
  [switch]$NoWrite,
  [switch]$Check,
  [switch]$Json
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

function Read-JsonRequired {
  param([Parameter(Mandatory = $true)][string]$Path)
  $resolved = Resolve-RepoPath $Path
  if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
    throw "JSON file not found: $resolved"
  }
  return Get-Content -Raw -LiteralPath $resolved | ConvertFrom-Json
}

function Read-JsonOptional {
  param([Parameter(Mandatory = $true)][string]$Path)
  $resolved = Resolve-RepoPath $Path
  if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
    return $null
  }
  return Get-Content -Raw -LiteralPath $resolved | ConvertFrom-Json
}

function ConvertTo-Array {
  param([object]$Value)
  if ($null -eq $Value) {
    return @()
  }
  return @($Value)
}

function Get-OptionalProperty {
  param(
    [Parameter(Mandatory = $true)]$Object,
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

function Add-AliasEntry {
  param(
    [Parameter(Mandatory = $true)][hashtable]$Map,
    [string]$Alias,
    [string]$OrganId,
    [string]$DriverId
  )
  if ([string]::IsNullOrWhiteSpace($Alias)) {
    return
  }
  $Map[$Alias] = @{
    organ_id = $OrganId
    driver_id = $DriverId
  }
}

function New-AliasMap {
  param(
    [Parameter(Mandatory = $true)]$BodyPlan,
    [Parameter(Mandatory = $true)]$DriverManifest
  )
  $map = @{}
  foreach ($organ in ConvertTo-Array $BodyPlan.organs) {
    $organId = [string]$organ.organ_id
    Add-AliasEntry -Map $map -Alias $organId -OrganId $organId -DriverId ""
  }
  foreach ($driver in ConvertTo-Array $DriverManifest.drivers) {
    $driverId = [string]$driver.driver_id
    $organId = [string]$driver.organ_id
    Add-AliasEntry -Map $map -Alias $driverId -OrganId $organId -DriverId $driverId
  }
  return $map
}

function Resolve-Alias {
  param(
    [Parameter(Mandatory = $true)][hashtable]$Map,
    [string]$Value
  )
  if ([string]::IsNullOrWhiteSpace($Value)) {
    return $null
  }
  if ($Map.ContainsKey($Value)) {
    return $Map[$Value]
  }
  return $null
}

function Convert-StateToHealth {
  param([string[]]$States)
  if ($States -contains "available") {
    return "ok"
  }
  if ($States -contains "degraded") {
    return "warn"
  }
  if (($States -contains "blocked") -or ($States -contains "unavailable") -or ($States -contains "down")) {
    return "error"
  }
  return "unknown"
}

function Convert-HealthToLevel {
  param([string]$Health)
  switch ($Health) {
    "ok" { return "ok" }
    "warn" { return "warn" }
    "error" { return "error" }
    default { return "unknown" }
  }
}

function Convert-HealthToConfidence {
  param([string]$Health)
  switch ($Health) {
    "ok" { return 1.0 }
    "warn" { return 0.7 }
    "error" { return 0.1 }
    default { return 0.3 }
  }
}

function Convert-HealthToFreshness {
  param([string]$Health)
  switch ($Health) {
    "ok" { return "fresh" }
    "warn" { return "stale" }
    "error" { return "stale" }
    default { return "unknown" }
  }
}

function Get-StatusEvidenceForOrgan {
  param(
    [Parameter(Mandatory = $true)][string]$OrganId,
    [Parameter(Mandatory = $true)][hashtable]$AliasMap,
    [object]$Status
  )
  if ($null -eq $Status) {
    return @{
      states = @()
      services = @()
      capabilities = @()
      source_refs = @()
      mapped_count = 0
    }
  }

  $states = @()
  $services = @()
  $capabilities = @()
  $sourceRefs = @()
  $mappedCount = 0

  foreach ($service in ConvertTo-Array (Get-OptionalProperty -Object $Status -Name "services" -Default @())) {
    $driverId = [string](Get-OptionalProperty -Object $service -Name "driver_id" -Default "")
    $serviceId = [string](Get-OptionalProperty -Object $service -Name "service_id" -Default "")
    $resolved = Resolve-Alias -Map $AliasMap -Value $driverId
    if ($null -eq $resolved) {
      $resolved = Resolve-Alias -Map $AliasMap -Value $serviceId
    }
    if ($null -ne $resolved -and [string]$resolved.organ_id -eq $OrganId) {
      $mappedCount += 1
      $states += [string](Get-OptionalProperty -Object $service -Name "state" -Default "unknown")
      $services += $serviceId
      $sourceRefs += "service:$serviceId"
    }
  }

  foreach ($capability in ConvertTo-Array (Get-OptionalProperty -Object $Status -Name "capabilities" -Default @())) {
    $driverId = [string](Get-OptionalProperty -Object $capability -Name "driver_id" -Default "")
    $capabilityId = [string](Get-OptionalProperty -Object $capability -Name "capability" -Default "")
    $resolved = Resolve-Alias -Map $AliasMap -Value $driverId
    if ($null -ne $resolved -and [string]$resolved.organ_id -eq $OrganId) {
      $mappedCount += 1
      $states += [string](Get-OptionalProperty -Object $capability -Name "state" -Default "unknown")
      $capabilities += $capabilityId
      $sourceRefs += "capability:$capabilityId"
    }
  }

  return @{
    states = @($states)
    services = @($services | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
    capabilities = @($capabilities | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
    source_refs = @($sourceRefs | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
    mapped_count = $mappedCount
  }
}

function Test-ExactObjectKeys {
  param(
    [object]$Value,
    [Parameter(Mandatory = $true)][string[]]$Expected
  )

  if ($null -eq $Value) {
    return $false
  }
  $actual = @($Value.PSObject.Properties.Name | Sort-Object)
  $wanted = @($Expected | Sort-Object)
  return (($actual -join "`n") -ceq ($wanted -join "`n"))
}

function Get-InputGateBodyStateForOrgan {
  param(
    [Parameter(Mandatory = $true)][string]$OrganId,
    [Parameter(Mandatory = $true)][hashtable]$AliasMap,
    [object]$Status,
    [Parameter(Mandatory = $true)][DateTimeOffset]$Now
  )

  if ($null -eq $Status -or $OrganId -cne "sense.hearing.primary") {
    return $null
  }

  $rows = @(
    ConvertTo-Array (Get-OptionalProperty -Object $Status -Name "organ_states" -Default @()) |
      Where-Object { [string](Get-OptionalProperty -Object $_ -Name "state_key" -Default "") -ceq "sense.hearing.primary.input_gate.body_state" }
  )
  if ($rows.Count -ne 1) {
    return $null
  }

  $row = $rows[0]
  $rowKeys = @(
    "state_key", "organ_id", "driver_id", "value", "observed_at",
    "received_at", "stale_after", "freshness", "confidence", "source_ref"
  )
  if (-not (Test-ExactObjectKeys -Value $row -Expected $rowKeys)) {
    return $null
  }
  if (
    [string]$row.organ_id -cne $OrganId -or
    [string]$row.driver_id -cne "browser_speech_input_driver" -or
    [string]$row.source_ref -cne "sense.hearing.primary.input_gate.body_state"
  ) {
    return $null
  }
  $resolved = Resolve-Alias -Map $AliasMap -Value ([string]$row.driver_id)
  if ($null -eq $resolved -or [string]$resolved.organ_id -cne $OrganId) {
    return $null
  }

  $value = $row.value
  $valueKeys = @(
    "schema_version", "self_state_class", "input_availability_class",
    "system_speech_intent_class", "self_output_observation_class",
    "pending_private_authority_class", "projection_freshness_class",
    "raw_private_publication_flags"
  )
  if (-not (Test-ExactObjectKeys -Value $value -Expected $valueKeys)) {
    return $null
  }
  if (
    [string]$value.schema_version -cne "input_gate_body_state.v0" -or
    [string]$value.self_state_class -cnotin @("self-speaking", "input-receivable", "ambiguity-held") -or
    [string]$value.input_availability_class -cnotin @("enabled", "disabled") -or
    [string]$value.system_speech_intent_class -cnotin @("handoff_accepted", "cooldown", "released", "missing") -or
    [string]$value.self_output_observation_class -cnotin @("matched_current", "missing") -or
    [string]$value.pending_private_authority_class -cnotin @("zero", "nonzero") -or
    [string]$value.projection_freshness_class -cnotin @("current_owner_read", "missing_owner_read") -or
    $value.raw_private_publication_flags -isnot [bool] -or
    [bool]$value.raw_private_publication_flags
  ) {
    return $null
  }
  if (
    [string]$value.projection_freshness_class -ceq "missing_owner_read" -and
    (
      [string]$value.self_state_class -cne "ambiguity-held" -or
      [string]$value.input_availability_class -cne "disabled" -or
      [string]$value.system_speech_intent_class -cne "missing" -or
      [string]$value.self_output_observation_class -cne "missing" -or
      [string]$value.pending_private_authority_class -cne "nonzero"
    )
  ) {
    return $null
  }

  try {
    $observedAt = [DateTimeOffset]::Parse([string]$row.observed_at)
    $receivedAt = [DateTimeOffset]::Parse([string]$row.received_at)
    $staleAfter = [DateTimeOffset]::Parse([string]$row.stale_after)
  }
  catch {
    return $null
  }
  if ($receivedAt -lt $observedAt -or $receivedAt -gt $Now.AddSeconds(5)) {
    return $null
  }
  $confidence = [double]$row.confidence
  $ownerReadCurrent = [string]$value.projection_freshness_class -ceq "current_owner_read"
  if ($ownerReadCurrent) {
    if (
      [string]$row.freshness -cne "fresh" -or
      $confidence -le 0 -or
      $confidence -gt 1 -or
      $Now -gt $staleAfter
    ) {
      return $null
    }
  }
  else {
    if (
      [string]$value.self_state_class -cne "ambiguity-held" -or
      [string]$row.freshness -cne "missing" -or
      $confidence -ne 0
    ) {
      return $null
    }
  }

  return [PSCustomObject]@{
    schema_version = [string]$value.schema_version
    self_state_class = [string]$value.self_state_class
    input_availability_class = [string]$value.input_availability_class
    system_speech_intent_class = [string]$value.system_speech_intent_class
    self_output_observation_class = [string]$value.self_output_observation_class
    pending_private_authority_class = [string]$value.pending_private_authority_class
    projection_freshness_class = [string]$value.projection_freshness_class
    raw_private_publication_flags = $false
    status_observed_at = $observedAt.ToString("o")
    status_freshness_class = [string]$row.freshness
    status_confidence = $confidence
    status_source_ref = [string]$row.source_ref
  }
}

function Write-JsonFile {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)]$Value,
    [int]$Depth = 12
  )
  $resolved = Resolve-RepoPath $Path
  $directory = Split-Path -Parent $resolved
  if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
  }
  $Value | ConvertTo-Json -Depth $Depth | Set-Content -LiteralPath $resolved -Encoding UTF8
}

function Test-ArrayValue {
  param([object]$Value)
  return ($null -ne $Value -and $Value -is [System.Array])
}

function Test-LocalPathString {
  param([string]$Value)
  if ([string]::IsNullOrWhiteSpace($Value)) {
    return $false
  }
  if ($Value -match "^[A-Za-z]:[\\/]") {
    return $true
  }
  if ($Value -match "^\\\\") {
    return $true
  }
  if ($Value -match "^/") {
    return $true
  }
  return $false
}

function Add-DisplaySafetyErrors {
  param(
    [Parameter(Mandatory = $true)]$Value,
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][ref]$Errors
  )

  $forbiddenPropertyNames = @(
    "raw_camera_frame",
    "raw_frame",
    "frame_bytes",
    "media_bytes",
    "image_bytes",
    "image_base64",
    "raw_conversation_log",
    "conversation_log",
    "raw_prompt",
    "prompt",
    "prompts",
    "secret",
    "secrets",
    "token",
    "access_token",
    "api_key",
    "password",
    "local_path",
    "filesystem_path",
    "action_request",
    "action_payload",
    "action_controls",
    "provides_actions"
  )

  if ($null -eq $Value) {
    return
  }

  if ($Value -is [string]) {
    if (Test-LocalPathString -Value $Value) {
      $Errors.Value += "display projection contains local path-like string at ${Path}"
    }
    return
  }

  if ($Value -is [ValueType]) {
    return
  }

  if ($Value -is [System.Array]) {
    for ($i = 0; $i -lt $Value.Count; $i += 1) {
      Add-DisplaySafetyErrors -Value $Value[$i] -Path "$Path[$i]" -Errors $Errors
    }
    return
  }

  foreach ($property in $Value.PSObject.Properties) {
    $propertyName = [string]$property.Name
    if ($forbiddenPropertyNames -contains $propertyName.ToLowerInvariant()) {
      $Errors.Value += "display projection contains forbidden property at ${Path}.${propertyName}"
    }
    Add-DisplaySafetyErrors -Value $property.Value -Path "$Path.$propertyName" -Errors $Errors
  }
}

function Add-BodySchemaContractErrors {
  param(
    [Parameter(Mandatory = $true)]$BodySchema,
    [Parameter(Mandatory = $true)]$BodySchemaContract,
    [Parameter(Mandatory = $true)][ref]$Errors
  )

  if ([string](Get-OptionalProperty -Object $BodySchemaContract.properties.status_source.properties.source_id -Name "type" -Default "") -ne "string") {
    $Errors.Value += "body schema contract must expose status_source.source_id as a string"
  }
  if ($null -ne $BodySchema.status_source.PSObject.Properties["path"]) {
    $Errors.Value += "body schema status_source must not retain a local path"
  }
  if ($null -eq $BodySchema.status_source.PSObject.Properties["source_id"]) {
    $Errors.Value += "body schema status_source.source_id is missing"
  }
  elseif (Test-LocalPathString -Value ([string]$BodySchema.status_source.source_id)) {
    $Errors.Value += "body schema status_source.source_id is path-like"
  }

  $currentStateContract = $BodySchemaContract.properties.organs.items.properties.current_state
  if ($null -eq $currentStateContract -or [string](Get-OptionalProperty -Object $currentStateContract -Name "type" -Default "") -ne "object") {
    $Errors.Value += "body schema contract must expose optional current_state as an object"
  }
  foreach ($organ in @($BodySchema.organs)) {
    $currentStateProperty = $organ.PSObject.Properties["current_state"]
    if ($null -eq $currentStateProperty) {
      continue
    }
    $expectedKeys = @(
      "schema_version", "self_state_class", "input_availability_class",
      "system_speech_intent_class", "self_output_observation_class",
      "pending_private_authority_class", "projection_freshness_class",
      "raw_private_publication_flags", "status_observed_at",
      "status_freshness_class", "status_confidence", "status_source_ref"
    )
    if (-not (Test-ExactObjectKeys -Value $currentStateProperty.Value -Expected $expectedKeys)) {
      $Errors.Value += "body schema current_state fields are invalid"
      continue
    }
    if (
      [bool]$currentStateProperty.Value.raw_private_publication_flags -or
      (Test-LocalPathString -Value ([string]$currentStateProperty.Value.status_source_ref))
    ) {
      $Errors.Value += "body schema current_state contains unsafe publication data"
    }
  }
}

function Add-ProjectionContractErrors {
  param(
    [Parameter(Mandatory = $true)]$Projection,
    [Parameter(Mandatory = $true)]$ProjectionContract,
    [Parameter(Mandatory = $true)][ref]$Errors
  )

  foreach ($requiredName in @($ProjectionContract.required)) {
    if ($null -eq $Projection.PSObject.Properties[[string]$requiredName]) {
      $Errors.Value += "body display projection missing required field: $requiredName"
    }
  }

  foreach ($arrayField in @("modes", "nodes", "routes", "source_refs")) {
    $contractType = [string](Get-OptionalProperty -Object $ProjectionContract.properties.$arrayField -Name "type" -Default "")
    if ($contractType -ne "array") {
      $Errors.Value += "body display projection contract field '$arrayField' must be array"
    }
    if (-not (Test-ArrayValue -Value $Projection.$arrayField)) {
      $Errors.Value += "body display projection generated field '$arrayField' must be array"
    }
  }

  foreach ($node in @($Projection.nodes)) {
    foreach ($requiredNodeField in @("node_id", "label", "level", "health", "activity", "freshness", "confidence", "source_refs")) {
      if ($null -eq $node.PSObject.Properties[$requiredNodeField]) {
        $Errors.Value += "body display projection node missing required field: $requiredNodeField"
      }
    }
    if ($null -ne $node.PSObject.Properties["provides_actions"]) {
      $Errors.Value += "body display projection node must not expose provides_actions"
    }
  }

  foreach ($sourceRef in @($Projection.source_refs)) {
    if ([string]$sourceRef -notmatch "^[A-Za-z0-9_.:-]+$") {
      $Errors.Value += "body display projection has unsafe source_ref: $sourceRef"
    }
  }

  Add-DisplaySafetyErrors -Value $Projection -Path "body_display_projection" -Errors $Errors
}

$bodyPlan = Read-JsonRequired -Path $BodyPlanPath
$driverManifest = Read-JsonRequired -Path $DriverManifestPath
$status = Read-JsonOptional -Path $StatusPath
$aliasMap = New-AliasMap -BodyPlan $bodyPlan -DriverManifest $driverManifest
$generatedAt = [DateTimeOffset]::Now.ToString("o")

$organs = @()
$nodes = @()
$mappedStatusCount = 0

foreach ($organ in ConvertTo-Array $bodyPlan.organs) {
  $organId = [string]$organ.organ_id
  $evidence = Get-StatusEvidenceForOrgan -OrganId $organId -AliasMap $aliasMap -Status $status
  $currentState = Get-InputGateBodyStateForOrgan -OrganId $organId -AliasMap $aliasMap -Status $status -Now ([DateTimeOffset]$generatedAt)
  $mappedStatusCount += [int]$evidence.mapped_count
  if ($null -ne $currentState) {
    $mappedStatusCount += 1
  }
  $states = [string[]]$evidence.states
  $health = Convert-StateToHealth -States $states
  $freshness = Convert-HealthToFreshness -Health $health
  $confidence = Convert-HealthToConfidence -Health $health
  $driverRefs = @(ConvertTo-Array $organ.driver_manifest_refs | ForEach-Object { [string]$_ })
  $organSourceRefs = @($evidence.source_refs)
  if ($null -ne $currentState) {
    $organSourceRefs += "status:$($currentState.status_source_ref)"
  }

  $organRecord = [PSCustomObject]@{
    organ_id = $organId
    role = [string]$organ.role
    required = [bool]$organ.required
    driver_refs = $driverRefs
    health = $health
    freshness = $freshness
    confidence = $confidence
    services = @($evidence.services)
    capabilities = @($evidence.capabilities)
    source_refs = @($organSourceRefs | Select-Object -Unique)
  }
  if ($null -ne $currentState) {
    $organRecord | Add-Member -NotePropertyName "current_state" -NotePropertyValue $currentState
  }
  $organs += $organRecord

  $nodes += [PSCustomObject]@{
    node_id = $organId
    label = [string]$organ.role
    level = Convert-HealthToLevel -Health $health
    health = $health
    activity = "idle"
    freshness = $freshness
    confidence = $confidence
    source_refs = @($organSourceRefs | Select-Object -Unique)
  }
}

$bodySchema = [PSCustomObject]@{
  schema_version = "body_schema_snapshot.v0"
  generated_at = $generatedAt
  organism_id = [string]$bodyPlan.organism_id
  organism_name = [string]$bodyPlan.organism_name
  body_plan_id = [string]$bodyPlan.body_plan_id
  body_plan_version = [string]$bodyPlan.body_plan_version
  agency_profile_id = Get-OptionalProperty -Object $bodyPlan -Name "agency_profile_id" -Default $null
  status_source = [PSCustomObject]@{
    source_id = "status-store.current"
    present = ($null -ne $status)
    mapped_entries = $mappedStatusCount
  }
  organs = @($organs)
}

$frameId = "bdp_" + ([DateTimeOffset]::Now.UtcDateTime.ToString("yyyyMMddTHHmmssfffZ"))
$projection = [PSCustomObject]@{
  schema_version = "body_display_projection.v0"
  frame_id = $frameId
  frame_kind = "full"
  seq = 1
  timestamp = $generatedAt
  primary_mode = "operator"
  modes = @("operator", "passive")
  nodes = @($nodes)
  routes = @()
  source_refs = @("body_plan:$($bodyPlan.body_plan_id)", "body_schema:$frameId")
}

$errors = @()
if ($Check) {
  $bodySchemaContract = Read-JsonRequired -Path $BodySchemaContractPath
  $projectionContract = Read-JsonRequired -Path $ProjectionContractPath
  $requiredIds = @("thought.core", "reflex.core", "action.boundary", "environment.state", "sense.vision.primary", "display.projection", "memory.event_journal", "memory.status_store", "body.schema")
  $organIds = @($organs | ForEach-Object { [string]$_.organ_id })
  foreach ($requiredId in $requiredIds) {
    if ($requiredId -notin $organIds) {
      $errors += "missing required organ: $requiredId"
    }
  }
  if ($nodes.Count -ne $organs.Count) {
    $errors += "projection node count does not match body schema organ count"
  }
  foreach ($organ in $organs) {
    foreach ($driverRef in @($organ.driver_refs)) {
      $resolved = Resolve-Alias -Map $aliasMap -Value $driverRef
      if ($null -eq $resolved) {
        $errors += "unresolved driver ref: $driverRef"
      }
    }
  }
  Add-BodySchemaContractErrors -BodySchema $bodySchema -BodySchemaContract $bodySchemaContract -Errors ([ref]$errors)
  Add-ProjectionContractErrors -Projection $projection -ProjectionContract $projectionContract -Errors ([ref]$errors)
}

if (-not $NoWrite) {
  Write-JsonFile -Path $BodySchemaOutputPath -Value $bodySchema -Depth 12
  Write-JsonFile -Path $ProjectionOutputPath -Value $projection -Depth 12
}

if ($errors.Count -gt 0) {
  [PSCustomObject]@{
    status = "fail"
    errors = @($errors)
  } | ConvertTo-Json -Depth 8
  exit 1
}

if ($Json) {
  [PSCustomObject]@{
    status = "ok"
    body_schema = $bodySchema
    body_display_projection = $projection
  } | ConvertTo-Json -Depth 14
  exit 0
}

[PSCustomObject]@{
  status = "ok"
  organism_id = [string]$bodyPlan.organism_id
  body_plan_id = [string]$bodyPlan.body_plan_id
  organ_count = $organs.Count
  projection_nodes = $nodes.Count
  status_present = ($null -ne $status)
  mapped_status_entries = $mappedStatusCount
  body_schema_path = if ($NoWrite) { $null } else { $BodySchemaOutputPath }
  projection_path = if ($NoWrite) { $null } else { $ProjectionOutputPath }
} | ConvertTo-Json -Depth 8
