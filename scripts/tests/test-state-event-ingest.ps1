param()

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$ModulePath = Join-Path $RepoRoot "runtime\state-event-ingest\StateEventIngest.psm1"
Import-Module -Name $ModulePath -Force
$Assertions = 0

function Assert-True {
  param(
    [Parameter(Mandatory = $true)][bool]$Condition,
    [Parameter(Mandatory = $true)][string]$Message
  )
  $script:Assertions += 1
  if (-not $Condition) {
    throw $Message
  }
}

function Assert-ThrowsWithoutMarker {
  param(
    [Parameter(Mandatory = $true)][scriptblock]$Action,
    [Parameter(Mandatory = $true)][string]$Marker,
    [Parameter(Mandatory = $true)][string]$Message
  )
  $script:Assertions += 2
  $threw = $false
  try {
    & $Action
  }
  catch {
    $threw = $true
    if ([string]$_.Exception.Message -like "*$Marker*") {
      throw "$Message echoed private input"
    }
  }
  if (-not $threw) {
    throw "$Message did not fail closed"
  }
}

function New-Projection {
  param(
    [string]$SelfState = "input-receivable",
    [string]$Availability = "enabled",
    [string]$Intent = "released",
    [string]$Observation = "matched_current",
    [string]$Pending = "zero",
    [string]$Freshness = "current_owner_read"
  )
  return [PSCustomObject]@{
    schema_version = "input_gate_body_state.v0"
    self_state_class = $SelfState
    input_availability_class = $Availability
    system_speech_intent_class = $Intent
    self_output_observation_class = $Observation
    pending_private_authority_class = $Pending
    projection_freshness_class = $Freshness
    raw_private_publication_flags = $false
  }
}

function New-Envelope {
  param(
    [Parameter(Mandatory = $true)]$Projection,
    [Parameter(Mandatory = $true)][DateTimeOffset]$ObservedAt,
    [int]$FreshnessMs = 5000,
    [double]$Confidence = 1.0,
    [string]$DriverId = "browser_speech_input_driver"
  )
  return [PSCustomObject]@{
    schema_version = "event_ingest.v0"
    ingest_id = "ing_body_state_test"
    event = [PSCustomObject]@{
      event_id = "evt_body_state_test"
      event_type = "sense.hearing.input_gate.body_state"
      event_level = 1
      reported_at = $ObservedAt.ToString("o")
      source = [PSCustomObject]@{
        origin = "system"
        organ_id = "sense.hearing.primary"
        driver_id = $DriverId
        instance_id = "ai_talk_core_input_gate"
      }
      payload = [PSCustomObject]@{
        schema_version = "input_gate_body_state.event.v0"
        status_key = "sense.hearing.primary.input_gate.body_state"
        raw_private_publication_flags = $false
      }
      redaction = "summary_only"
      dry_run = $false
      driver_kind = "compat_adapter"
    }
    status_patch = [PSCustomObject]@{
      schema_version = "status_patch.v0"
      patch_id = "sp_body_state_test"
      updates = @(
        [PSCustomObject]@{
          key = "sense.hearing.primary.input_gate.body_state"
          value = $Projection
          observed_at = $ObservedAt.ToString("o")
          freshness_ms = $FreshnessMs
          confidence = $Confidence
          source_ref = "sense.hearing.primary.input_gate.body_state"
        }
      )
    }
  }
}

$observedAt = [DateTimeOffset]::Parse("2026-07-14T10:00:00Z")
$receivedAt = $observedAt.AddSeconds(1)
$status = [PSCustomObject]@{ services = @(); capabilities = @() }
$projection = New-Projection
$result = Invoke-StateEventIngest `
  -Envelope (New-Envelope -Projection $projection -ObservedAt $observedAt) `
  -CurrentStatus $status `
  -ReceivedAt $receivedAt
$row = @($result.organ_states)[0]
Assert-True -Condition (@($result.organ_states).Count -eq 1) -Message "valid owner state was not stored once"
Assert-True -Condition ([string]$row.organ_id -ceq "sense.hearing.primary") -Message "owner organ changed"
Assert-True -Condition ([string]$row.value.self_state_class -ceq "input-receivable") -Message "owner class was not copied"
Assert-True -Condition ([string]$row.freshness -ceq "fresh") -Message "current owner state was not fresh"
Assert-True -Condition ([double]$row.confidence -eq 1.0) -Message "owner confidence changed"
Assert-True -Condition (-not [bool]$row.value.raw_private_publication_flags) -Message "private publication flag changed"

$speaking = New-Projection `
  -SelfState "self-speaking" `
  -Intent "handoff_accepted" `
  -Observation "matched_current"
[void](Test-InputGateBodyStateProjection -Projection $speaking)
Assert-True -Condition $true -Message "matching queue and render evidence should remain valid"

$marker = "private-aec-marker-do-not-echo"
$injected = New-Projection
$injected | Add-Member -NotePropertyName "aec_result" -NotePropertyValue $marker
Assert-ThrowsWithoutMarker `
  -Action { Invoke-StateEventIngest -Envelope (New-Envelope -Projection $injected -ObservedAt $observedAt) -CurrentStatus ([PSCustomObject]@{}) -ReceivedAt $receivedAt | Out-Null } `
  -Marker $marker `
  -Message "injected non-owner field"

$queueOnly = New-Projection `
  -SelfState "self-speaking" `
  -Intent "handoff_accepted" `
  -Observation "missing"
$queueOnlyResult = Invoke-StateEventIngest `
  -Envelope (New-Envelope -Projection $queueOnly -ObservedAt $observedAt) `
  -CurrentStatus ([PSCustomObject]@{}) `
  -ReceivedAt $receivedAt
Assert-True -Condition ([string]$queueOnlyResult.organ_states[0].value.self_state_class -ceq "self-speaking") -Message "ingest recomputed the owner class"
Assert-True -Condition ([string]$queueOnlyResult.organ_states[0].value.self_output_observation_class -ceq "missing") -Message "ingest changed owner evidence"

Assert-ThrowsWithoutMarker `
  -Action { Invoke-StateEventIngest -Envelope (New-Envelope -Projection (New-Projection) -ObservedAt $observedAt -DriverId "hearing_audio_awareness_observer_driver") -CurrentStatus ([PSCustomObject]@{}) -ReceivedAt $receivedAt | Out-Null } `
  -Marker $marker `
  -Message "wrong driver authority"

Assert-ThrowsWithoutMarker `
  -Action { Invoke-StateEventIngest -Envelope (New-Envelope -Projection (New-Projection) -ObservedAt $observedAt) -CurrentStatus ([PSCustomObject]@{}) -ReceivedAt $observedAt.AddSeconds(6) | Out-Null } `
  -Marker $marker `
  -Message "stale owner state"

$missing = New-Projection `
  -SelfState "ambiguity-held" `
  -Availability "disabled" `
  -Intent "missing" `
  -Observation "missing" `
  -Pending "nonzero" `
  -Freshness "missing_owner_read"
$missingResult = Invoke-StateEventIngest `
  -Envelope (New-Envelope -Projection $missing -ObservedAt $observedAt -FreshnessMs 0 -Confidence 0) `
  -CurrentStatus ([PSCustomObject]@{}) `
  -ReceivedAt $receivedAt
Assert-True -Condition ([string]$missingResult.organ_states[0].value.self_state_class -ceq "ambiguity-held") -Message "missing owner read did not fail closed"
Assert-True -Condition ([string]$missingResult.organ_states[0].freshness -ceq "missing") -Message "missing owner read freshness changed"

$optimisticMissing = New-Projection -Freshness "missing_owner_read"
Assert-ThrowsWithoutMarker `
  -Action { Invoke-StateEventIngest -Envelope (New-Envelope -Projection $optimisticMissing -ObservedAt $observedAt -FreshnessMs 0 -Confidence 0) -CurrentStatus ([PSCustomObject]@{}) -ReceivedAt $receivedAt | Out-Null } `
  -Marker $marker `
  -Message "optimistic missing-owner projection"

Write-Output ("status=ok; assertions={0}; raw_private_publication_flags=false" -f $Assertions)
