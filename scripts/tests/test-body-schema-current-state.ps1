param()

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$BuilderPath = Join-Path $RepoRoot "scripts\build-body-schema-snapshot.ps1"
$TempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("sword-body-schema-current-state-" + [guid]::NewGuid().ToString("N"))
$StatusPath = Join-Path $TempRoot "status.json"
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

function New-Status {
  param(
    [Parameter(Mandatory = $true)][DateTimeOffset]$ObservedAt,
    [Parameter(Mandatory = $true)][DateTimeOffset]$StaleAfter,
    [string]$DriverId = "browser_speech_input_driver",
    [string]$SelfState = "input-receivable",
    [string]$Availability = "enabled",
    [string]$Intent = "released",
    [string]$Observation = "matched_current",
    [string]$Pending = "zero",
    [string]$ProjectionFreshness = "current_owner_read",
    [string]$RowFreshness = "fresh",
    [double]$Confidence = 1.0,
    [switch]$AddUnexpectedField
  )

  $value = [PSCustomObject]@{
    schema_version = "input_gate_body_state.v0"
    self_state_class = $SelfState
    input_availability_class = $Availability
    system_speech_intent_class = $Intent
    self_output_observation_class = $Observation
    pending_private_authority_class = $Pending
    projection_freshness_class = $ProjectionFreshness
    raw_private_publication_flags = $false
  }
  if ($AddUnexpectedField) {
    $value | Add-Member -NotePropertyName "caller_vad_authority" -NotePropertyValue $true
  }

  return [PSCustomObject]@{
    services = @()
    capabilities = @()
    organ_states = @(
      [PSCustomObject]@{
        state_key = "sense.hearing.primary.input_gate.body_state"
        organ_id = "sense.hearing.primary"
        driver_id = $DriverId
        value = $value
        observed_at = $ObservedAt.ToString("o")
        received_at = $ObservedAt.ToString("o")
        stale_after = $StaleAfter.ToString("o")
        freshness = $RowFreshness
        confidence = $Confidence
        source_ref = "sense.hearing.primary.input_gate.body_state"
      }
    )
  }
}

function Invoke-Builder {
  param([Parameter(Mandatory = $true)]$Status)

  $Status | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $StatusPath -Encoding UTF8
  $shellPath = (Get-Process -Id $PID).Path
  $output = & $shellPath -NoProfile -File $BuilderPath -StatusPath $StatusPath -Check -NoWrite -Json
  if ($LASTEXITCODE -ne 0) {
    throw "body schema builder failed"
  }
  return ($output -join "`n") | ConvertFrom-Json
}

try {
  New-Item -ItemType Directory -Path $TempRoot -Force | Out-Null
  $now = [DateTimeOffset]::Now
  $current = Invoke-Builder -Status (New-Status -ObservedAt $now -StaleAfter $now.AddSeconds(30))
  $hearing = @($current.body_schema.organs | Where-Object { [string]$_.organ_id -ceq "sense.hearing.primary" })[0]
  $otherCurrentStates = @($current.body_schema.organs | Where-Object { [string]$_.organ_id -cne "sense.hearing.primary" -and $null -ne $_.PSObject.Properties["current_state"] })

  Assert-True -Condition ([string]$current.status -ceq "ok") -Message "current-state body schema was not valid"
  Assert-True -Condition ([int]$current.body_schema.status_source.mapped_entries -eq 1) -Message "current owner row was not counted once"
  Assert-True -Condition ($null -ne $hearing.PSObject.Properties["current_state"]) -Message "hearing current state was not projected"
  Assert-True -Condition ([string]$hearing.current_state.self_state_class -ceq "input-receivable") -Message "Body Schema recomputed owner class"
  Assert-True -Condition ([string]$hearing.current_state.system_speech_intent_class -ceq "released") -Message "Body Schema changed owner lifecycle class"
  Assert-True -Condition ([string]$hearing.current_state.status_freshness_class -ceq "fresh") -Message "Body Schema changed status freshness"
  Assert-True -Condition ([double]$hearing.current_state.status_confidence -eq 1.0) -Message "Body Schema changed status confidence"
  Assert-True -Condition (-not [bool]$hearing.current_state.raw_private_publication_flags) -Message "Body Schema enabled private publication"
  Assert-True -Condition ($otherCurrentStates.Count -eq 0) -Message "hearing state was copied to another organ"
  Assert-True -Condition (@($hearing.source_refs) -contains "status:sense.hearing.primary.input_gate.body_state") -Message "Body Schema lost the logical status source"

  $rendered = $hearing.current_state | ConvertTo-Json -Depth 6 -Compress
  Assert-True -Condition ($rendered -notmatch '[A-Za-z]:\\|https?://|transcript|pcm|device') -Message "Body Schema retained forbidden private data"

  $ownerAuthored = Invoke-Builder -Status (New-Status `
    -ObservedAt $now `
    -StaleAfter $now.AddSeconds(30) `
    -SelfState "self-speaking" `
    -Intent "released" `
    -Observation "missing")
  $ownerAuthoredHearing = @($ownerAuthored.body_schema.organs | Where-Object { [string]$_.organ_id -ceq "sense.hearing.primary" })[0]
  Assert-True -Condition ([string]$ownerAuthoredHearing.current_state.self_state_class -ceq "self-speaking") -Message "Body Schema recomputed the owner class"
  Assert-True -Condition ([string]$ownerAuthoredHearing.current_state.self_output_observation_class -ceq "missing") -Message "Body Schema changed owner evidence"

  $stale = Invoke-Builder -Status (New-Status -ObservedAt $now.AddSeconds(-10) -StaleAfter $now.AddSeconds(-1))
  $staleHearing = @($stale.body_schema.organs | Where-Object { [string]$_.organ_id -ceq "sense.hearing.primary" })[0]
  Assert-True -Condition ($null -eq $staleHearing.PSObject.Properties["current_state"]) -Message "stale owner state was projected"
  Assert-True -Condition ([int]$stale.body_schema.status_source.mapped_entries -eq 0) -Message "stale owner state was counted"

  $wrongOwner = Invoke-Builder -Status (New-Status -ObservedAt $now -StaleAfter $now.AddSeconds(30) -DriverId "not_a_canonical_driver")
  $wrongOwnerHearing = @($wrongOwner.body_schema.organs | Where-Object { [string]$_.organ_id -ceq "sense.hearing.primary" })[0]
  Assert-True -Condition ($null -eq $wrongOwnerHearing.PSObject.Properties["current_state"]) -Message "wrong driver authority was projected"

  $observerOwner = Invoke-Builder -Status (New-Status -ObservedAt $now -StaleAfter $now.AddSeconds(30) -DriverId "hearing_audio_awareness_observer_driver")
  $observerOwnerHearing = @($observerOwner.body_schema.organs | Where-Object { [string]$_.organ_id -ceq "sense.hearing.primary" })[0]
  Assert-True -Condition ($null -eq $observerOwnerHearing.PSObject.Properties["current_state"]) -Message "same-organ non-owner driver was projected"

  $optimisticMissing = Invoke-Builder -Status (New-Status `
    -ObservedAt $now `
    -StaleAfter $now `
    -SelfState "ambiguity-held" `
    -ProjectionFreshness "missing_owner_read" `
    -RowFreshness "missing" `
    -Confidence 0)
  $optimisticMissingHearing = @($optimisticMissing.body_schema.organs | Where-Object { [string]$_.organ_id -ceq "sense.hearing.primary" })[0]
  Assert-True -Condition ($null -eq $optimisticMissingHearing.PSObject.Properties["current_state"]) -Message "optimistic missing-owner fields were projected"

  $injected = Invoke-Builder -Status (New-Status -ObservedAt $now -StaleAfter $now.AddSeconds(30) -AddUnexpectedField)
  $injectedHearing = @($injected.body_schema.organs | Where-Object { [string]$_.organ_id -ceq "sense.hearing.primary" })[0]
  Assert-True -Condition ($null -eq $injectedHearing.PSObject.Properties["current_state"]) -Message "unexpected authority field was projected"

  Write-Output ("status=ok; assertions={0}; current_state_copied=1; stale_rejected=1; raw_private_publication_flags=false; temp_residue=0" -f $Assertions)
}
finally {
  if (Test-Path -LiteralPath $StatusPath -PathType Leaf) {
    Remove-Item -LiteralPath $StatusPath -Force
  }
  if (Test-Path -LiteralPath $TempRoot -PathType Container) {
    if (@(Get-ChildItem -LiteralPath $TempRoot -Force).Count -ne 0) {
      throw "owned Body Schema fixture cleanup is incomplete"
    }
    Remove-Item -LiteralPath $TempRoot -Force
  }
}
