param(
  [string]$StatusPath = ".cache/agent-os/status/current.json",
  [string]$TopologyPath = ".cache/agent-os/status/topology.json",
  [string]$EventJournalDir = ".cache/agent-os/events",
  [int]$TailEvents = 5,
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

function Read-JsonFile {
  param([Parameter(Mandatory = $true)][string]$Path)
  $resolved = Resolve-RepoPath $Path
  if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
    throw "diagnostics status file not found: $resolved. Run scripts/update-diagnostics-status.ps1 first."
  }
  return Get-Content -Raw -LiteralPath $resolved | ConvertFrom-Json
}

function Read-RecentEvents {
  param(
    [Parameter(Mandatory = $true)][string]$Directory,
    [Parameter(Mandatory = $true)][int]$Count
  )
  $resolved = Resolve-RepoPath $Directory
  if ($Count -le 0 -or -not (Test-Path -LiteralPath $resolved -PathType Container)) {
    return @()
  }
  $files = @(Get-ChildItem -LiteralPath $resolved -Filter "*.jsonl" -File | Sort-Object LastWriteTime -Descending)
  $events = @()
  foreach ($file in $files) {
    $lines = @(Get-Content -LiteralPath $file.FullName -Tail ([Math]::Max($Count, 1)))
    for ($i = $lines.Count - 1; $i -ge 0; $i -= 1) {
      try {
        $events += ($lines[$i] | ConvertFrom-Json)
      }
      catch {
      }
      if ($events.Count -ge $Count) {
        return @($events)
      }
    }
  }
  return @($events)
}

function Format-Timestamp {
  param([object]$Value)
  if ($Value -is [DateTime]) {
    return $Value.ToString("o")
  }
  if ($Value -is [DateTimeOffset]) {
    return $Value.ToString("o")
  }
  return [string]$Value
}

$status = Read-JsonFile -Path $StatusPath
$topologyResolved = Resolve-RepoPath $TopologyPath
$topology = $null
if (Test-Path -LiteralPath $topologyResolved -PathType Leaf) {
  $topology = Get-Content -Raw -LiteralPath $topologyResolved | ConvertFrom-Json
}
$events = Read-RecentEvents -Directory $EventJournalDir -Count $TailEvents

if ($Json) {
  [PSCustomObject]@{
    status = $status
    topology = $topology
    recent_events = @($events)
  } | ConvertTo-Json -Depth 12
  exit 0
}

Write-Output "Agent OS diagnostics"
Write-Output "generated_at: $(Format-Timestamp -Value $status.generated_at)"
Write-Output "profile: $($status.profile_id)"
Write-Output "port_mode: $($status.port_mode)"
if ($null -ne $status.PSObject.Properties["websocket_probe_mode"]) {
  Write-Output "websocket_probe_mode: $($status.websocket_probe_mode)"
}
Write-Output "digest: $($status.digest)"
Write-Output ""
Write-Output "Services: $($status.summary.services_available)/$($status.summary.services_total) available, $($status.summary.services_unavailable) unavailable, $($status.summary.services_unknown) unknown"
Write-Output "Capabilities: $($status.summary.capabilities_available)/$($status.summary.capabilities_total) available, $($status.summary.capabilities_unavailable) unavailable, $($status.summary.capabilities_unknown) unknown"
Write-Output ""

if ($null -ne $status.PSObject.Properties["no_provider_child_provenance_diagnostics"]) {
  $provenance = $status.no_provider_child_provenance_diagnostics
  Write-Output "No-provider child provenance:"
  Write-Output "  child_process_identity_class: $($provenance.child_process_identity_class)"
  Write-Output "  stale_or_reused_process_class: $($provenance.stale_or_reused_process_class)"
  Write-Output "  thought_core_llm_enabled_class: $($provenance.env_binding.thought_core_llm_enabled_class)"
  Write-Output "  thought_core_action_llm_enabled_class: $($provenance.env_binding.thought_core_action_llm_enabled_class)"
  Write-Output "  provider_config_presence_class: $($provenance.env_binding.provider_config_presence_class)"
  Write-Output "  start_script_env_override_class: $($provenance.env_binding.start_script_env_override_class)"
  Write-Output "  direct_dify_exclusion_class: $($provenance.provider_boundary.direct_dify_exclusion_class)"
  Write-Output "  runtime_import_provenance_class: $($provenance.source_static.runtime_import_provenance_class)"
  Write-Output "  payload_marker_class: $($provenance.payload_preflight.payload_marker_class)"
  Write-Output ""
}

Write-Output "Service states:"
$status.services |
  Select-Object service_id, state, freshness, health_type, probe_mode, detail |
  Format-Table -AutoSize |
  Out-String |
  Write-Output

Write-Output "Capability states:"
$status.capabilities |
  Select-Object capability, state, freshness, driver_id, detail |
  Format-Table -AutoSize |
  Out-String |
  Write-Output

if ($events.Count -gt 0) {
  Write-Output "Recent diagnostic events:"
  $events |
    Select-Object event_type, service_id, capability, summary |
    Format-Table -AutoSize |
    Out-String |
    Write-Output
}
else {
  Write-Output "Recent diagnostic events: none"
}
