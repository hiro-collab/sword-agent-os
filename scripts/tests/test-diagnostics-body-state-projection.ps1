param()

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$UpdaterPath = Join-Path $RepoRoot "scripts\update-diagnostics-status.ps1"
$PolicyPath = Join-Path $RepoRoot "manifests\diagnostics\standard.json"
$TempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("sword-body-state-diagnostics-" + [guid]::NewGuid().ToString("N"))
$TempPolicyPath = Join-Path $TempRoot "diagnostics.json"
$StatusPath = Join-Path $TempRoot "status.json"
$TopologyPath = Join-Path $TempRoot "topology.json"
$JournalPath = Join-Path $TempRoot "events.jsonl"
$StackPath = Join-Path $TempRoot "stack"
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

try {
  New-Item -ItemType Directory -Path $TempRoot -Force | Out-Null
  $policy = Get-Content -Raw -LiteralPath $PolicyPath | ConvertFrom-Json
  $policy.stores.status_store.path = $StatusPath
  $policy.stores.topology_store.path = $TopologyPath
  $policy.stores.event_journal.path_pattern = $JournalPath
  $policy | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $TempPolicyPath -Encoding UTF8

  $shellPath = (Get-Process -Id $PID).Path
  $output = & $shellPath -NoProfile -File $UpdaterPath `
    -DiagnosticPolicyPath $TempPolicyPath `
    -WorkspaceRoot $RepoRoot `
    -StackStateDir $StackPath `
    -ManifestOnly `
    -NoJournal
  Assert-True -Condition ($LASTEXITCODE -eq 0) -Message "diagnostics update failed"
  $summary = ($output -join "`n") | ConvertFrom-Json
  $status = Get-Content -Raw -LiteralPath $StatusPath | ConvertFrom-Json
  $rows = @($status.organ_states)

  Assert-True -Condition ([string]$summary.input_gate_body_state_class -ceq "ambiguity-held") -Message "manifest-only projection did not fail closed"
  Assert-True -Condition ([string]$summary.input_gate_body_state_freshness -ceq "missing_owner_read") -Message "manifest-only projection freshness changed"
  Assert-True -Condition ($rows.Count -eq 1) -Message "diagnostics did not store exactly one hearing owner row"
  Assert-True -Condition ([string]$rows[0].organ_id -ceq "sense.hearing.primary") -Message "diagnostics changed hearing owner"
  Assert-True -Condition ([string]$rows[0].value.self_state_class -ceq "ambiguity-held") -Message "diagnostics inferred an optimistic state"
  Assert-True -Condition ([string]$rows[0].value.projection_freshness_class -ceq "missing_owner_read") -Message "diagnostics upgraded missing owner evidence"
  Assert-True -Condition ([double]$rows[0].confidence -eq 0) -Message "diagnostics upgraded missing owner confidence"
  Assert-True -Condition (-not [bool]$rows[0].value.raw_private_publication_flags) -Message "diagnostics enabled private publication"
  Assert-True -Condition (-not (Test-Path -LiteralPath $JournalPath)) -Message "NoJournal diagnostics wrote an event journal"

  $renderedRow = $rows[0] | ConvertTo-Json -Depth 8 -Compress
  Assert-True -Condition ($renderedRow -notmatch '[A-Za-z]:\\|https?://|transcript|pcm|device') -Message "bounded body-state row leaked forbidden data"

  $updaterSource = Get-Content -Raw -LiteralPath $UpdaterPath
  Assert-True -Condition ($updaterSource -match 'X-AI-Core-Token') -Message "protected owner read is missing the fixed token header"
  Assert-True -Condition ($updaterSource -match 'AI_TALK_CORE_WEB_TOKEN') -Message "protected owner read is missing process-token lookup"
  Assert-True -Condition ($updaterSource -match 'Convert-UrlForPortMode') -Message "owner read does not follow the selected canonical port mode"

  Write-Output ("status=ok; assertions={0}; owner_read=missing; raw_private_publication_flags=false; temp_residue=0" -f $Assertions)
}
finally {
  foreach ($ownedFile in @($JournalPath, $TopologyPath, $StatusPath, $TempPolicyPath)) {
    if (Test-Path -LiteralPath $ownedFile -PathType Leaf) {
      Remove-Item -LiteralPath $ownedFile -Force
    }
  }
  foreach ($ownedDirectory in @($StackPath, $TempRoot)) {
    if (Test-Path -LiteralPath $ownedDirectory -PathType Container) {
      if (@(Get-ChildItem -LiteralPath $ownedDirectory -Force).Count -ne 0) {
        throw "owned diagnostics fixture cleanup is incomplete"
      }
      Remove-Item -LiteralPath $ownedDirectory -Force
    }
  }
}
