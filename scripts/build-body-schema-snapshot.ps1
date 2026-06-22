param(
  [string]$BodyPlanPath = "manifests/body-plans/system-cell-v0.json",
  [string]$DriverManifestPath = "manifests/driver-manifests/system-cell-v0.json",
  [string]$CompatAliasesPath = "manifests/compat-aliases/legacy-service-aliases.json",
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
    [Parameter(Mandatory = $true)]$DriverManifest,
    [Parameter(Mandatory = $true)]$CompatAliases
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
  foreach ($alias in ConvertTo-Array $CompatAliases.aliases) {
    Add-AliasEntry `
      -Map $map `
      -Alias ([string]$alias.legacy) `
      -OrganId ([string]$alias.canonical_organ_id) `
      -DriverId ([string]$alias.canonical_driver_id)
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
$compatAliases = Read-JsonRequired -Path $CompatAliasesPath
$status = Read-JsonOptional -Path $StatusPath
$aliasMap = New-AliasMap -BodyPlan $bodyPlan -DriverManifest $driverManifest -CompatAliases $compatAliases
$generatedAt = [DateTimeOffset]::Now.ToString("o")

$organs = @()
$nodes = @()
$mappedStatusCount = 0

foreach ($organ in ConvertTo-Array $bodyPlan.organs) {
  $organId = [string]$organ.organ_id
  $evidence = Get-StatusEvidenceForOrgan -OrganId $organId -AliasMap $aliasMap -Status $status
  $mappedStatusCount += [int]$evidence.mapped_count
  $states = [string[]]$evidence.states
  $health = Convert-StateToHealth -States $states
  $freshness = Convert-HealthToFreshness -Health $health
  $confidence = Convert-HealthToConfidence -Health $health
  $driverRefs = @(ConvertTo-Array $organ.driver_manifest_refs | ForEach-Object { [string]$_ })

  $organs += [PSCustomObject]@{
    organ_id = $organId
    role = [string]$organ.role
    required = [bool]$organ.required
    driver_refs = $driverRefs
    health = $health
    freshness = $freshness
    confidence = $confidence
    services = @($evidence.services)
    capabilities = @($evidence.capabilities)
    source_refs = @($evidence.source_refs)
  }

  $nodes += [PSCustomObject]@{
    node_id = $organId
    label = [string]$organ.role
    level = Convert-HealthToLevel -Health $health
    health = $health
    activity = "idle"
    freshness = $freshness
    confidence = $confidence
    source_refs = @($evidence.source_refs)
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
