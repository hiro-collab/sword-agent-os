Set-StrictMode -Version Latest

$script:BodyStateStatusKey = "sense.hearing.primary.input_gate.body_state"
$script:BodyStateSourceRef = "sense.hearing.primary.input_gate.body_state"
$script:BodyStateOrganId = "sense.hearing.primary"
$script:BodyStateDriverId = "browser_speech_input_driver"
$script:BodyStateInstanceId = "ai_talk_core_input_gate"

function Get-ObjectProperty {
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

function Assert-ExactKeys {
  param(
    [Parameter(Mandatory = $true)]$Object,
    [Parameter(Mandatory = $true)][string[]]$Expected,
    [Parameter(Mandatory = $true)][string]$Label
  )

  if ($null -eq $Object -or $Object -isnot [psobject]) {
    throw "$Label must be an object"
  }

  $actual = @($Object.PSObject.Properties.Name | Sort-Object)
  $wanted = @($Expected | Sort-Object)
  if (($actual -join "`n") -cne ($wanted -join "`n")) {
    throw "$Label fields are invalid"
  }
}

function ConvertTo-RequiredTimestamp {
  param(
    [Parameter(Mandatory = $true)]$Value,
    [Parameter(Mandatory = $true)][string]$Label
  )

  try {
    return [DateTimeOffset]::Parse(
      [string]$Value,
      [System.Globalization.CultureInfo]::InvariantCulture,
      [System.Globalization.DateTimeStyles]::RoundtripKind
    )
  }
  catch {
    throw "$Label is invalid"
  }
}

function Assert-AllowedClass {
  param(
    [Parameter(Mandatory = $true)][string]$Value,
    [Parameter(Mandatory = $true)][string[]]$Allowed,
    [Parameter(Mandatory = $true)][string]$Label
  )

  if ($Value -cnotin $Allowed) {
    throw "$Label is invalid"
  }
}

function Test-InputGateBodyStateProjection {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)]$Projection
  )

  $keys = @(
    "schema_version",
    "self_state_class",
    "input_availability_class",
    "system_speech_intent_class",
    "self_output_observation_class",
    "pending_private_authority_class",
    "projection_freshness_class",
    "raw_private_publication_flags"
  )
  Assert-ExactKeys -Object $Projection -Expected $keys -Label "input-gate body state"

  if ([string]$Projection.schema_version -cne "input_gate_body_state.v0") {
    throw "input-gate body state schema is invalid"
  }
  Assert-AllowedClass -Value ([string]$Projection.self_state_class) `
    -Allowed @("self-speaking", "input-receivable", "ambiguity-held") `
    -Label "self state class"
  Assert-AllowedClass -Value ([string]$Projection.input_availability_class) `
    -Allowed @("enabled", "disabled") `
    -Label "input availability class"
  Assert-AllowedClass -Value ([string]$Projection.system_speech_intent_class) `
    -Allowed @("handoff_accepted", "cooldown", "released", "missing") `
    -Label "system speech intent class"
  Assert-AllowedClass -Value ([string]$Projection.self_output_observation_class) `
    -Allowed @("matched_current", "missing") `
    -Label "self-output observation class"
  Assert-AllowedClass -Value ([string]$Projection.pending_private_authority_class) `
    -Allowed @("zero", "nonzero") `
    -Label "pending private authority class"
  Assert-AllowedClass -Value ([string]$Projection.projection_freshness_class) `
    -Allowed @("current_owner_read", "missing_owner_read") `
    -Label "projection freshness class"
  if ($Projection.raw_private_publication_flags -isnot [bool] -or [bool]$Projection.raw_private_publication_flags) {
    throw "raw private publication flags must be false"
  }
  if (
    [string]$Projection.projection_freshness_class -ceq "missing_owner_read" -and
    (
      [string]$Projection.self_state_class -cne "ambiguity-held" -or
      [string]$Projection.input_availability_class -cne "disabled" -or
      [string]$Projection.system_speech_intent_class -cne "missing" -or
      [string]$Projection.self_output_observation_class -cne "missing" -or
      [string]$Projection.pending_private_authority_class -cne "nonzero"
    )
  ) {
    throw "missing owner read must use the conservative tuple"
  }

  return $true
}

function Copy-InputGateBodyStateProjection {
  param([Parameter(Mandatory = $true)]$Projection)

  return [PSCustomObject]@{
    schema_version = [string]$Projection.schema_version
    self_state_class = [string]$Projection.self_state_class
    input_availability_class = [string]$Projection.input_availability_class
    system_speech_intent_class = [string]$Projection.system_speech_intent_class
    self_output_observation_class = [string]$Projection.self_output_observation_class
    pending_private_authority_class = [string]$Projection.pending_private_authority_class
    projection_freshness_class = [string]$Projection.projection_freshness_class
    raw_private_publication_flags = $false
  }
}

function Invoke-StateEventIngest {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)]$Envelope,
    [Parameter(Mandatory = $true)]$CurrentStatus,
    [DateTimeOffset]$ReceivedAt = [DateTimeOffset]::UtcNow
  )

  Assert-ExactKeys -Object $Envelope `
    -Expected @("schema_version", "ingest_id", "event", "status_patch") `
    -Label "ingest envelope"
  if ([string]$Envelope.schema_version -cne "event_ingest.v0") {
    throw "ingest envelope schema is invalid"
  }
  if ([string]$Envelope.ingest_id -notmatch '^ing_[A-Za-z0-9_.:-]+$') {
    throw "ingest id is invalid"
  }

  $event = $Envelope.event
  Assert-ExactKeys -Object $event `
    -Expected @("event_id", "event_type", "event_level", "reported_at", "source", "payload", "redaction", "dry_run", "driver_kind") `
    -Label "ingest event"
  if (
    [string]$event.event_id -notmatch '^evt_[A-Za-z0-9_.:-]+$' -or
    [string]$event.event_type -cne "sense.hearing.input_gate.body_state" -or
    [int]$event.event_level -ne 1 -or
    [string]$event.redaction -cne "summary_only" -or
    $event.dry_run -isnot [bool] -or
    [bool]$event.dry_run -or
    [string]$event.driver_kind -cne "compat_adapter"
  ) {
    throw "ingest event fields are invalid"
  }

  $source = $event.source
  Assert-ExactKeys -Object $source `
    -Expected @("origin", "organ_id", "driver_id", "instance_id") `
    -Label "ingest source"
  if (
    [string]$source.origin -cne "system" -or
    [string]$source.organ_id -cne $script:BodyStateOrganId -or
    [string]$source.driver_id -cne $script:BodyStateDriverId -or
    [string]$source.instance_id -cne $script:BodyStateInstanceId
  ) {
    throw "ingest source authority is invalid"
  }

  Assert-ExactKeys -Object $event.payload `
    -Expected @("schema_version", "status_key", "raw_private_publication_flags") `
    -Label "ingest event payload"
  if (
    [string]$event.payload.schema_version -cne "input_gate_body_state.event.v0" -or
    [string]$event.payload.status_key -cne $script:BodyStateStatusKey -or
    $event.payload.raw_private_publication_flags -isnot [bool] -or
    [bool]$event.payload.raw_private_publication_flags
  ) {
    throw "ingest event payload is invalid"
  }

  $patch = $Envelope.status_patch
  Assert-ExactKeys -Object $patch `
    -Expected @("schema_version", "patch_id", "updates") `
    -Label "status patch"
  if (
    [string]$patch.schema_version -cne "status_patch.v0" -or
    [string]$patch.patch_id -notmatch '^sp_[A-Za-z0-9_.:-]+$' -or
    @($patch.updates).Count -ne 1
  ) {
    throw "status patch fields are invalid"
  }

  $update = @($patch.updates)[0]
  Assert-ExactKeys -Object $update `
    -Expected @("key", "value", "observed_at", "freshness_ms", "confidence", "source_ref") `
    -Label "status update"
  if (
    [string]$update.key -cne $script:BodyStateStatusKey -or
    [string]$update.source_ref -cne $script:BodyStateSourceRef
  ) {
    throw "status update authority is invalid"
  }
  if ([int]$update.freshness_ms -lt 0 -or [int]$update.freshness_ms -gt 5000) {
    throw "status update freshness is invalid"
  }
  $confidence = [double]$update.confidence
  if ($confidence -lt 0 -or $confidence -gt 1) {
    throw "status update confidence is invalid"
  }

  [void](Test-InputGateBodyStateProjection -Projection $update.value)
  $reportedAt = ConvertTo-RequiredTimestamp -Value $event.reported_at -Label "reported timestamp"
  $observedAt = ConvertTo-RequiredTimestamp -Value $update.observed_at -Label "observed timestamp"
  if ($reportedAt -lt $observedAt -or $reportedAt -gt $ReceivedAt.AddSeconds(5)) {
    throw "ingest event timing is invalid"
  }

  $ownerReadCurrent = [string]$update.value.projection_freshness_class -ceq "current_owner_read"
  if ($ownerReadCurrent) {
    if (
      [int]$update.freshness_ms -le 0 -or
      $confidence -le 0 -or
      $ReceivedAt -gt $observedAt.AddMilliseconds([int]$update.freshness_ms)
    ) {
      throw "current owner projection is stale"
    }
    $freshness = "fresh"
  }
  else {
    if ([int]$update.freshness_ms -ne 0 -or $confidence -ne 0) {
      throw "missing owner projection metadata is invalid"
    }
    $freshness = "missing"
  }

  $row = [PSCustomObject]@{
    state_key = $script:BodyStateStatusKey
    organ_id = $script:BodyStateOrganId
    driver_id = $script:BodyStateDriverId
    value = Copy-InputGateBodyStateProjection -Projection $update.value
    observed_at = $observedAt.ToString("o")
    received_at = $ReceivedAt.ToString("o")
    stale_after = $observedAt.AddMilliseconds([int]$update.freshness_ms).ToString("o")
    freshness = $freshness
    confidence = $confidence
    source_ref = $script:BodyStateSourceRef
  }

  $existing = @(Get-ObjectProperty -Object $CurrentStatus -Name "organ_states" -Default @())
  $kept = @($existing | Where-Object { [string](Get-ObjectProperty -Object $_ -Name "state_key" -Default "") -cne $script:BodyStateStatusKey })
  $CurrentStatus | Add-Member -NotePropertyName "organ_states" -NotePropertyValue @($kept + $row) -Force
  return $CurrentStatus
}

Export-ModuleMember -Function Test-InputGateBodyStateProjection, Invoke-StateEventIngest
