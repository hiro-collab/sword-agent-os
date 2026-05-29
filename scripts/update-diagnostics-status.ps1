param(
  [string]$ProfilePath = "manifests/profiles/thought-core-v0-compat.json",
  [string]$DiagnosticPolicyPath = "manifests/diagnostics/standard.json",
  [string]$DriverManifestPath = "manifests/drivers/standard.json",
  [ValidateSet("manifest_default", "isolated_override")]
  [string]$PortMode = "manifest_default",
  [ValidateSet("strict", "process")]
  [string]$WebSocketProbeMode = "process",
  [switch]$ManifestOnly,
  [int]$TimeoutMs = 1200,
  [string]$WorkspaceRoot = "",
  [string]$StackStateDir = "",
  [switch]$NoJournal
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

function Resolve-WorkspaceRoot {
  param([string]$Path)
  if ([string]::IsNullOrWhiteSpace($Path)) {
    return $RepoRoot
  }
  if ([System.IO.Path]::IsPathRooted($Path)) {
    return $Path
  }
  return Resolve-RepoPath $Path
}

function Resolve-StackStateDir {
  param(
    [Parameter(Mandatory = $true)][string]$Root,
    [string]$Path
  )
  if ([string]::IsNullOrWhiteSpace($Path)) {
    $Path = [Environment]::GetEnvironmentVariable("HOME_CONTROL_STACK_STATE_DIR")
  }
  if ([string]::IsNullOrWhiteSpace($Path)) {
    return Join-Path $Root ".cache\home-control-stack"
  }
  if ([System.IO.Path]::IsPathRooted($Path)) {
    return $Path
  }
  return Join-Path $Root ($Path -replace "/", [System.IO.Path]::DirectorySeparatorChar)
}

function Read-Json {
  param([Parameter(Mandatory = $true)][string]$Path)
  return Get-Content -Raw -LiteralPath (Resolve-RepoPath $Path) | ConvertFrom-Json
}

function Get-OptionalProperty {
  param(
    [Parameter(Mandatory = $true)]$Object,
    [Parameter(Mandatory = $true)][string]$Name,
    [object]$Default = $null
  )
  $property = $Object.PSObject.Properties[$Name]
  if ($null -eq $property -or $null -eq $property.Value) {
    return $Default
  }
  return $property.Value
}

function ConvertTo-StringArray {
  param([object]$Value)
  if ($null -eq $Value) {
    return @()
  }
  return @($Value | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

function Ensure-DirectoryForFile {
  param([Parameter(Mandatory = $true)][string]$Path)
  $directory = Split-Path -Parent $Path
  if (-not [string]::IsNullOrWhiteSpace($directory) -and -not (Test-Path -LiteralPath $directory -PathType Container)) {
    [void](New-Item -ItemType Directory -Force -Path $directory)
  }
}

function Resolve-PolicyPath {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][DateTimeOffset]$At
  )
  $resolved = $Path
  $resolved = $resolved.Replace("%Y", $At.ToString("yyyy"))
  $resolved = $resolved.Replace("%m", $At.ToString("MM"))
  $resolved = $resolved.Replace("%d", $At.ToString("dd"))
  $resolved = $resolved.Replace("%H", $At.ToString("HH"))
  $resolved = $resolved.Replace("%M", $At.ToString("mm"))
  $resolved = $resolved.Replace("%S", $At.ToString("ss"))
  return Resolve-RepoPath $resolved
}

function Convert-UrlForPortMode {
  param(
    [Parameter(Mandatory = $true)][string]$Url,
    [Parameter(Mandatory = $true)][string]$ServiceId,
    [Parameter(Mandatory = $true)]$ServiceManifest,
    [Parameter(Mandatory = $true)][string]$SelectedPortMode
  )
  if ([string]::IsNullOrWhiteSpace($Url)) {
    return $Url
  }
  $modeProperty = $ServiceManifest.port_modes.PSObject.Properties[$SelectedPortMode]
  if ($null -eq $modeProperty) {
    return $Url
  }
  $servicePorts = Get-OptionalProperty -Object $modeProperty.Value -Name "service_ports"
  if ($null -eq $servicePorts) {
    return $Url
  }
  $portProperty = $servicePorts.PSObject.Properties[$ServiceId]
  if ($null -eq $portProperty) {
    return $Url
  }
  try {
    $builder = [System.UriBuilder]::new($Url)
    $builder.Port = [int]$portProperty.Value
    return $builder.Uri.AbsoluteUri
  }
  catch {
    return $Url
  }
}

function Read-PidMap {
  param([Parameter(Mandatory = $true)][string]$Path)
  $map = @{}
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    return $map
  }
  try {
    $raw = Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json
    foreach ($entry in @(Get-OptionalProperty -Object $raw -Name "processes" -Default @())) {
      $name = [string](Get-OptionalProperty -Object $entry -Name "name" -Default "")
      if (-not [string]::IsNullOrWhiteSpace($name)) {
        $map[$name] = $entry
      }
    }
  }
  catch {
  }
  return $map
}

function Normalize-ProcessName {
  param([string]$Name)
  if ([string]::IsNullOrWhiteSpace($Name)) {
    return ""
  }
  $normalized = $Name.ToLowerInvariant()
  if ($normalized.EndsWith(".exe")) {
    return $normalized.Substring(0, $normalized.Length - 4)
  }
  return $normalized
}

function Test-ProcessStartTimeMatches {
  param(
    [Parameter(Mandatory = $true)][object]$Process,
    [string]$RecordedAt,
    [int]$GraceSeconds = 60
  )
  if ([string]::IsNullOrWhiteSpace($RecordedAt)) {
    return $true
  }
  try {
    $recorded = [DateTimeOffset]::Parse($RecordedAt)
    $processStarted = [DateTimeOffset]$Process.StartTime
    return (
      $processStarted -ge $recorded.AddSeconds(-10) -and
      $processStarted -le $recorded.AddSeconds($GraceSeconds)
    )
  }
  catch {
    return $false
  }
}

function Test-ProcessEntryAlive {
  param([Parameter(Mandatory = $true)][object]$Entry)
  $pidValue = [int](Get-OptionalProperty -Object $Entry -Name "pid" -Default 0)
  if ($pidValue -le 0) {
    return $false
  }
  $process = Get-Process -Id $pidValue -ErrorAction SilentlyContinue
  if ($null -eq $process) {
    return $false
  }
  $startedAt = [string](Get-OptionalProperty -Object $Entry -Name "started_at" -Default "")
  if (-not (Test-ProcessStartTimeMatches -Process $process -RecordedAt $startedAt -GraceSeconds 60)) {
    return $false
  }
  $allowedNames = ConvertTo-StringArray -Value (Get-OptionalProperty -Object $Entry -Name "allowed_process_names" -Default @())
  if ($allowedNames.Count -eq 0) {
    return $true
  }
  $processName = Normalize-ProcessName -Name ([string]$process.ProcessName)
  $allowed = @($allowedNames | ForEach-Object { Normalize-ProcessName -Name $_ })
  return $allowed -contains $processName
}

function Test-HttpEndpoint {
  param(
    [Parameter(Mandatory = $true)][string]$Url,
    [Parameter(Mandatory = $true)][int]$Timeout
  )
  try {
    $response = Invoke-WebRequest -Uri $Url -Method Get -TimeoutSec ([Math]::Max(1, [int][Math]::Ceiling($Timeout / 1000))) -UseBasicParsing
    $detail = "http $($response.StatusCode)"
    $state = if ($response.StatusCode -ge 200 -and $response.StatusCode -lt 400) { "available" } else { "degraded" }
    if (-not [string]::IsNullOrWhiteSpace([string]$response.Content)) {
      try {
        $payload = $response.Content | ConvertFrom-Json
        $statusProperty = $payload.PSObject.Properties["status"]
        if ($null -ne $statusProperty -and [string]$statusProperty.Value -notin @("ok", "healthy", "ready")) {
          $state = "degraded"
          $detail = "$detail status=$($statusProperty.Value)"
        }
      }
      catch {
      }
    }
    return @{ state = $state; freshness = "fresh"; detail = $detail }
  }
  catch {
    $response = Get-OptionalProperty -Object $_.Exception -Name "Response"
    if ($null -ne $response -and $null -ne $response.StatusCode) {
      return @{ state = "unavailable"; freshness = "fresh"; detail = "http $([int]$response.StatusCode)" }
    }
    return @{ state = "unavailable"; freshness = "fresh"; detail = $_.Exception.Message }
  }
}

function Test-WebSocketEndpoint {
  param(
    [Parameter(Mandatory = $true)][string]$Url,
    [Parameter(Mandatory = $true)][int]$Timeout
  )
  $socket = [System.Net.WebSockets.ClientWebSocket]::new()
  $cts = [System.Threading.CancellationTokenSource]::new()
  try {
    $cts.CancelAfter($Timeout)
    $task = $socket.ConnectAsync([System.Uri]::new($Url), $cts.Token)
    if (-not $task.Wait($Timeout)) {
      return @{ state = "unavailable"; freshness = "fresh"; detail = "timeout" }
    }
    if ($task.IsFaulted) {
      $message = if ($null -ne $task.Exception -and $null -ne $task.Exception.InnerException) {
        $task.Exception.InnerException.Message
      }
      else {
        "websocket handshake failed"
      }
      return @{ state = "unavailable"; freshness = "fresh"; detail = $message }
    }
    if ($socket.State -eq [System.Net.WebSockets.WebSocketState]::Open) {
      try {
        $closeTask = $socket.CloseAsync(
          [System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure,
          "diagnostics probe",
          [System.Threading.CancellationToken]::None
        )
        [void]$closeTask.Wait([Math]::Min($Timeout, 500))
      }
      catch {
      }
      return @{ state = "available"; freshness = "fresh"; detail = "websocket handshake" }
    }
    return @{ state = "unavailable"; freshness = "fresh"; detail = "websocket state $($socket.State)" }
  }
  catch {
    return @{ state = "unavailable"; freshness = "fresh"; detail = $_.Exception.Message }
  }
  finally {
    $cts.Dispose()
    $socket.Dispose()
  }
}

function Test-ProcessHealth {
  param(
    [Parameter(Mandatory = $true)]$Health,
    [Parameter(Mandatory = $true)][hashtable]$PidMap,
    [Parameter(Mandatory = $true)][string]$PidFile
  )
  $pidName = [string](Get-OptionalProperty -Object $Health -Name "pid_name" -Default "")
  if ([string]::IsNullOrWhiteSpace($pidName)) {
    return @{ state = "unknown"; freshness = "missing"; detail = "process health missing pid_name" }
  }
  if (-not $PidMap.ContainsKey($pidName)) {
    return @{ state = "unavailable"; freshness = "fresh"; detail = "not recorded in $PidFile" }
  }
  $entry = $PidMap[$pidName]
  $pidValue = [int](Get-OptionalProperty -Object $entry -Name "pid" -Default 0)
  if (Test-ProcessEntryAlive -Entry $entry) {
    return @{ state = "available"; freshness = "fresh"; detail = "pid $pidValue" }
  }
  return @{ state = "unavailable"; freshness = "fresh"; detail = "recorded pid $pidValue is not alive" }
}

function Test-ServiceProcessEvidence {
  param(
    [Parameter(Mandatory = $true)][string]$ServiceId,
    [Parameter(Mandatory = $true)][hashtable]$PidMap,
    [Parameter(Mandatory = $true)][string]$PidFile
  )
  if (-not $PidMap.ContainsKey($ServiceId)) {
    return @{ state = "unavailable"; freshness = "fresh"; detail = "service process not recorded in $PidFile" }
  }
  $entry = $PidMap[$ServiceId]
  $pidValue = [int](Get-OptionalProperty -Object $entry -Name "pid" -Default 0)
  if (Test-ProcessEntryAlive -Entry $entry) {
    return @{ state = "available"; freshness = "fresh"; detail = "pid $pidValue; websocket strict probe skipped" }
  }
  return @{ state = "unavailable"; freshness = "fresh"; detail = "recorded service pid $pidValue is not alive" }
}

function New-ManifestOnlyResult {
  param([Parameter(Mandatory = $true)]$Health)
  $target = [string](Get-OptionalProperty -Object $Health -Name "url" -Default "")
  if ([string]::IsNullOrWhiteSpace($target)) {
    $target = [string](Get-OptionalProperty -Object $Health -Name "pid_name" -Default "")
  }
  return @{ state = "unknown"; freshness = "missing"; detail = $target }
}

function Get-ServiceDriver {
  param(
    [Parameter(Mandatory = $true)][string]$ServiceId,
    [Parameter(Mandatory = $true)]$DriverManifest
  )
  foreach ($driver in @($DriverManifest.organ_drivers)) {
    if ($ServiceId -in (ConvertTo-StringArray -Value (Get-OptionalProperty -Object $driver -Name "target_services" -Default @()))) {
      return $driver
    }
  }
  return $null
}

function ConvertTo-CapabilityState {
  param([object[]]$ServiceStates = @())
  if ($null -eq $ServiceStates) {
    $ServiceStates = @()
  }
  if ($ServiceStates.Count -eq 0) {
    return @{ state = "unknown"; freshness = "missing"; detail = "no target service evidence" }
  }
  $states = @($ServiceStates | ForEach-Object { [string]$_.state })
  $freshnessValues = @($ServiceStates | ForEach-Object { [string]$_.freshness })
  $freshness = if ("missing" -in $freshnessValues) { "missing" } elseif ("stale" -in $freshnessValues) { "stale" } else { "fresh" }
  if ("blocked" -in $states) {
    return @{ state = "blocked"; freshness = $freshness; detail = "one or more required services blocked" }
  }
  if ("unavailable" -in $states) {
    return @{ state = "unavailable"; freshness = $freshness; detail = "one or more required services unavailable" }
  }
  if ("degraded" -in $states) {
    return @{ state = "degraded"; freshness = $freshness; detail = "one or more required services degraded" }
  }
  if (@($states | Where-Object { $_ -eq "available" }).Count -eq $states.Count) {
    return @{ state = "available"; freshness = $freshness; detail = "required service evidence available" }
  }
  return @{ state = "unknown"; freshness = $freshness; detail = "required service evidence incomplete" }
}

function Test-StaticDriverEvidence {
  param(
    [Parameter(Mandatory = $true)]$Driver,
    [Parameter(Mandatory = $true)][string]$Root,
    [Parameter(Mandatory = $true)][bool]$ManifestOnlyMode
  )
  $evidence = @(Get-OptionalProperty -Object $Driver -Name "static_evidence" -Default @())
  if ($evidence.Count -eq 0) {
    return $null
  }
  if ($ManifestOnlyMode) {
    return @{
      state = "unknown"
      freshness = "missing"
      confidence = "low"
      detail = "static evidence not probed in manifest-only mode"
    }
  }

  $present = @()
  $missingRequired = @()
  $missingOptional = @()
  foreach ($entry in $evidence) {
    $id = [string](Get-OptionalProperty -Object $entry -Name "id" -Default "")
    if ([string]::IsNullOrWhiteSpace($id)) {
      $id = "unnamed_static_evidence"
    }
    $type = [string](Get-OptionalProperty -Object $entry -Name "type" -Default "")
    $path = [string](Get-OptionalProperty -Object $entry -Name "path" -Default "")
    $required = [bool](Get-OptionalProperty -Object $entry -Name "required" -Default $true)
    $ok = $false
    if ($type -eq "path_exists" -and -not [string]::IsNullOrWhiteSpace($path)) {
      $resolved = if ([System.IO.Path]::IsPathRooted($path)) {
        $path
      }
      else {
        Join-Path $Root ($path -replace "/", [System.IO.Path]::DirectorySeparatorChar)
      }
      $ok = Test-Path -LiteralPath $resolved
    }
    if ($ok) {
      $present += $id
    }
    elseif ($required) {
      $missingRequired += $id
    }
    else {
      $missingOptional += $id
    }
  }

  if ($missingRequired.Count -gt 0) {
    return @{
      state = "unavailable"
      freshness = "fresh"
      confidence = "medium"
      detail = "missing required static evidence: $($missingRequired -join ', ')"
    }
  }
  if ($missingOptional.Count -gt 0) {
    return @{
      state = "degraded"
      freshness = "fresh"
      confidence = "medium"
      detail = "static evidence available with optional gaps: $($missingOptional -join ', ')"
    }
  }
  return @{
    state = "available"
    freshness = "fresh"
    confidence = "medium"
    detail = "static evidence available: $($present -join ', ')"
  }
}

function Convert-ConfidenceToMetricValue {
  param([object]$Value)
  if ($null -eq $Value) {
    return 0.2
  }
  if ($Value -is [int] -or $Value -is [long] -or $Value -is [double] -or $Value -is [decimal]) {
    return [Math]::Max(0.0, [Math]::Min(1.0, [double]$Value))
  }
  switch (([string]$Value).ToLowerInvariant()) {
    "high" { return 0.9 }
    "medium" { return 0.6 }
    "low" { return 0.35 }
    "unknown" { return 0.2 }
    default { return 0.2 }
  }
}

function Get-StaleAfterTimestamp {
  param(
    [Parameter(Mandatory = $true)][string]$RecordedAt,
    [object]$StaleAfterSeconds
  )
  $seconds = 30
  try {
    $seconds = [Math]::Max(1, [int]$StaleAfterSeconds)
  }
  catch {
    $seconds = 30
  }
  try {
    return ([DateTimeOffset]::Parse($RecordedAt)).AddSeconds($seconds).ToString("o")
  }
  catch {
    return ([DateTimeOffset]::Now).AddSeconds($seconds).ToString("o")
  }
}

function New-MetricRecord {
  param(
    [Parameter(Mandatory = $true)][string]$Metric,
    [Parameter(Mandatory = $true)][string]$Subject,
    [Parameter(Mandatory = $true)][double]$Value,
    [Parameter(Mandatory = $true)][string]$RecordedAt,
    [Parameter(Mandatory = $true)][string]$StaleAfter,
    [Parameter(Mandatory = $true)][string]$Source,
    [string[]]$Provenance = @(),
    [Parameter(Mandatory = $true)][string]$Basis,
    [string[]]$EvidenceRefs = @()
  )
  [PSCustomObject]@{
    metric = $Metric
    subject = $Subject
    value = [Math]::Round([Math]::Max(0.0, [Math]::Min(1.0, $Value)), 4)
    recorded_at = $RecordedAt
    stale_after = $StaleAfter
    source = $Source
    provenance = @($Provenance | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    basis = $Basis
    evidence_refs = @($EvidenceRefs | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
  }
}

function New-CurrentMetricRecords {
  param(
    [object[]]$Services = @(),
    [object[]]$Capabilities = @(),
    [Parameter(Mandatory = $true)][string]$TopologySnapshotId
  )
  $records = @()
  foreach ($service in @($Services | Sort-Object service_id)) {
    $serviceId = [string]$service.service_id
    $recordedAt = [string]$service.observed_at
    $driverId = [string]$service.driver_id
    $source = if ([string]::IsNullOrWhiteSpace($driverId)) { "diagnostics.status-store" } else { "driver:$driverId" }
    $records += New-MetricRecord `
      -Metric "source_confidence" `
      -Subject "service:$serviceId" `
      -Value (Convert-ConfidenceToMetricValue -Value $service.confidence) `
      -RecordedAt $recordedAt `
      -StaleAfter (Get-StaleAfterTimestamp -RecordedAt $recordedAt -StaleAfterSeconds $service.stale_after_seconds) `
      -Source $source `
      -Provenance @([string]$service.layer, $driverId, $serviceId) `
      -Basis "service_health_$($service.state)_$($service.freshness)" `
      -EvidenceRefs @("snapshot:$TopologySnapshotId")
  }
  foreach ($capability in @($Capabilities | Sort-Object driver_id, capability)) {
    $capabilityName = [string]$capability.capability
    $recordedAt = [string]$capability.observed_at
    $driverId = [string]$capability.driver_id
    $records += New-MetricRecord `
      -Metric "state_confidence" `
      -Subject "capability:$capabilityName" `
      -Value (Convert-ConfidenceToMetricValue -Value $capability.confidence) `
      -RecordedAt $recordedAt `
      -StaleAfter (Get-StaleAfterTimestamp -RecordedAt $recordedAt -StaleAfterSeconds $capability.stale_after_seconds) `
      -Source "diagnostics.status-store" `
      -Provenance (@($driverId) + @($capability.service_ids | ForEach-Object { [string]$_ })) `
      -Basis "capability_from_service_evidence_$($capability.state)_$($capability.freshness)" `
      -EvidenceRefs @("snapshot:$TopologySnapshotId")
  }
  return @($records)
}

function New-DigestInput {
  param([Parameter(Mandatory = $true)]$Status)
  $services = @($Status.services | Sort-Object service_id | ForEach-Object {
    [PSCustomObject]@{
      service_id = $_.service_id
      state = $_.state
      freshness = $_.freshness
      detail = $_.detail
      health_target = $_.health_target
    }
  })
  $capabilities = @($Status.capabilities | Sort-Object capability, driver_id | ForEach-Object {
    [PSCustomObject]@{
      capability = $_.capability
      driver_id = $_.driver_id
      state = $_.state
      freshness = $_.freshness
      detail = $_.detail
    }
  })
  return [PSCustomObject]@{
    services = $services
    capabilities = $capabilities
  }
}

function Get-ObjectDigest {
  param([Parameter(Mandatory = $true)]$Value)
  $json = $Value | ConvertTo-Json -Depth 12 -Compress
  $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try {
    $hash = $sha.ComputeHash($bytes)
    return ([BitConverter]::ToString($hash)).Replace("-", "").ToLowerInvariant()
  }
  finally {
    $sha.Dispose()
  }
}

function New-EventId {
  param([Parameter(Mandatory = $true)][int]$Index)
  return "evt_$((Get-Date).ToString("yyyyMMddHHmmssfff"))_$Index"
}

function New-ObservationId {
  param(
    [Parameter(Mandatory = $true)][string]$Kind,
    [Parameter(Mandatory = $true)][string]$Id,
    [Parameter(Mandatory = $true)][int]$Index
  )
  $safeId = ($Id -replace "[^A-Za-z0-9_.-]", "_")
  return "obs_$Kind`_$safeId`_$Index"
}

function Get-PreviousByKey {
  param(
    [object[]]$Items,
    [Parameter(Mandatory = $true)][string]$KeyProperty
  )
  $map = @{}
  foreach ($item in @($Items)) {
    $key = [string](Get-OptionalProperty -Object $item -Name $KeyProperty -Default "")
    if (-not [string]::IsNullOrWhiteSpace($key)) {
      $map[$key] = $item
    }
  }
  return $map
}

function New-StateChangeEvents {
  param(
    $PreviousStatus,
    [Parameter(Mandatory = $true)]$CurrentStatus,
    [Parameter(Mandatory = $true)][DateTimeOffset]$Now
  )
  $events = @()
  $eventIndex = 0

  if ($null -eq $PreviousStatus) {
    $eventIndex += 1
    $events += [PSCustomObject]@{
      event_id = New-EventId -Index $eventIndex
      event_type = "diagnostics.status_initialized"
      observed_at = $Now.ToString("o")
      received_at = $Now.ToString("o")
      summary = "diagnostics status initialized"
      digest = $CurrentStatus.digest
      service_counts = $CurrentStatus.summary
    }
    return @($events)
  }

  $previousServices = Get-PreviousByKey -Items @($PreviousStatus.services) -KeyProperty "service_id"
  foreach ($service in @($CurrentStatus.services | Sort-Object service_id)) {
    $serviceId = [string]$service.service_id
    if (-not $previousServices.ContainsKey($serviceId)) {
      $eventIndex += 1
      $events += [PSCustomObject]@{
        event_id = New-EventId -Index $eventIndex
        event_type = "diagnostics.service_observed"
        observed_at = $Now.ToString("o")
        received_at = $Now.ToString("o")
        service_id = $serviceId
        after = [PSCustomObject]@{ state = $service.state; freshness = $service.freshness; detail = $service.detail }
        summary = "service $serviceId observed as $($service.state)"
      }
      continue
    }
    $before = $previousServices[$serviceId]
    if (
      [string]$before.state -ne [string]$service.state -or
      [string]$before.freshness -ne [string]$service.freshness -or
      [string]$before.detail -ne [string]$service.detail
    ) {
      $eventIndex += 1
      $events += [PSCustomObject]@{
        event_id = New-EventId -Index $eventIndex
        event_type = "diagnostics.service_state_changed"
        observed_at = $Now.ToString("o")
        received_at = $Now.ToString("o")
        service_id = $serviceId
        before = [PSCustomObject]@{ state = $before.state; freshness = $before.freshness; detail = $before.detail }
        after = [PSCustomObject]@{ state = $service.state; freshness = $service.freshness; detail = $service.detail }
        summary = "service $serviceId changed from $($before.state) to $($service.state)"
      }
    }
  }

  $previousCapabilityMap = @{}
  foreach ($capability in @($PreviousStatus.capabilities)) {
    $key = "$($capability.driver_id)::$($capability.capability)"
    $previousCapabilityMap[$key] = $capability
  }
  foreach ($capability in @($CurrentStatus.capabilities | Sort-Object driver_id, capability)) {
    $key = "$($capability.driver_id)::$($capability.capability)"
    if (-not $previousCapabilityMap.ContainsKey($key)) {
      $eventIndex += 1
      $events += [PSCustomObject]@{
        event_id = New-EventId -Index $eventIndex
        event_type = "diagnostics.capability_observed"
        observed_at = $Now.ToString("o")
        received_at = $Now.ToString("o")
        driver_id = $capability.driver_id
        capability = $capability.capability
        after = [PSCustomObject]@{ state = $capability.state; freshness = $capability.freshness; detail = $capability.detail }
        summary = "capability $($capability.capability) observed as $($capability.state)"
      }
      continue
    }
    $before = $previousCapabilityMap[$key]
    if (
      [string]$before.state -ne [string]$capability.state -or
      [string]$before.freshness -ne [string]$capability.freshness -or
      [string]$before.detail -ne [string]$capability.detail
    ) {
      $eventIndex += 1
      $events += [PSCustomObject]@{
        event_id = New-EventId -Index $eventIndex
        event_type = "diagnostics.capability_state_changed"
        observed_at = $Now.ToString("o")
        received_at = $Now.ToString("o")
        driver_id = $capability.driver_id
        capability = $capability.capability
        before = [PSCustomObject]@{ state = $before.state; freshness = $before.freshness; detail = $before.detail }
        after = [PSCustomObject]@{ state = $capability.state; freshness = $capability.freshness; detail = $capability.detail }
        summary = "capability $($capability.capability) changed from $($before.state) to $($capability.state)"
      }
    }
  }

  return @($events)
}

function Write-JsonFile {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)]$Value
  )
  Ensure-DirectoryForFile -Path $Path
  $json = $Value | ConvertTo-Json -Depth 14
  Set-Content -LiteralPath $Path -Value $json -Encoding UTF8
}

function Append-JsonLines {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [object[]]$Events = @()
  )
  if ($null -eq $Events) {
    $Events = @()
  }
  if ($Events.Count -eq 0) {
    return
  }
  Ensure-DirectoryForFile -Path $Path
  foreach ($event in $Events) {
    Add-Content -LiteralPath $Path -Value ($event | ConvertTo-Json -Depth 10 -Compress) -Encoding UTF8
  }
}

$now = [DateTimeOffset]::Now
$workspace = Resolve-WorkspaceRoot -Path $WorkspaceRoot
$stackState = Resolve-StackStateDir -Root $workspace -Path $StackStateDir
$pidFile = Join-Path $stackState "pids.json"

$profile = Read-Json -Path $ProfilePath
$serviceManifest = Read-Json -Path ([string]$profile.service_manifest)
$diagnosticPolicy = Read-Json -Path $DiagnosticPolicyPath
$driverManifest = Read-Json -Path $DriverManifestPath
$pidMap = Read-PidMap -Path $pidFile

$statusPath = Resolve-PolicyPath -Path ([string]$diagnosticPolicy.stores.status_store.path) -At $now
$topologyPath = Resolve-PolicyPath -Path ([string]$diagnosticPolicy.stores.topology_store.path) -At $now
$eventJournalPath = Resolve-PolicyPath -Path ([string]$diagnosticPolicy.stores.event_journal.path_pattern) -At $now

$previousStatus = $null
if (Test-Path -LiteralPath $statusPath -PathType Leaf) {
  try {
    $previousStatus = Get-Content -Raw -LiteralPath $statusPath | ConvertFrom-Json
  }
  catch {
    $previousStatus = $null
  }
}

$services = @()
$serviceStateMap = @{}
$serviceIndex = 0
foreach ($service in @($serviceManifest.services)) {
  $serviceIndex += 1
  $serviceId = [string]$service.service_id
  $health = $service.health
  $healthType = [string]$health.type
  $healthTarget = [string](Get-OptionalProperty -Object $health -Name "url" -Default "")
  if (-not [string]::IsNullOrWhiteSpace($healthTarget)) {
    $healthTarget = Convert-UrlForPortMode -Url $healthTarget -ServiceId $serviceId -ServiceManifest $serviceManifest -SelectedPortMode $PortMode
  }

  if ($ManifestOnly) {
    $probe = New-ManifestOnlyResult -Health $health
  }
  else {
    switch ($healthType) {
      "http" {
        $probe = Test-HttpEndpoint -Url $healthTarget -Timeout $TimeoutMs
      }
      "websocket" {
        if ($WebSocketProbeMode -eq "process") {
          $probe = Test-ServiceProcessEvidence -ServiceId $serviceId -PidMap $pidMap -PidFile $pidFile
        }
        else {
          $probe = Test-WebSocketEndpoint -Url $healthTarget -Timeout $TimeoutMs
        }
      }
      "process" {
        $probe = Test-ProcessHealth -Health $health -PidMap $pidMap -PidFile $pidFile
      }
      default {
        $probe = @{ state = "unknown"; freshness = "missing"; detail = "unsupported health type: $healthType" }
      }
    }
  }

  $driver = Get-ServiceDriver -ServiceId $serviceId -DriverManifest $driverManifest
  $driverId = if ($null -ne $driver) { [string]$driver.driver_id } else { "" }
  $observation = [PSCustomObject]@{
    observation_id = New-ObservationId -Kind "service" -Id $serviceId -Index $serviceIndex
    service_id = $serviceId
    organ_id = [string]$service.organ_id
    layer = [string]$service.layer
    logical_service = [string]$service.logical_service
    driver_id = $driverId
    tier = if ($healthType -eq "process" -or ($healthType -eq "websocket" -and $WebSocketProbeMode -eq "process")) { "light" } else { "standard" }
    health_type = $healthType
    probe_mode = if ($healthType -eq "websocket") { $WebSocketProbeMode } else { $healthType }
    health_target = if ([string]::IsNullOrWhiteSpace($healthTarget)) { [string](Get-OptionalProperty -Object $health -Name "pid_name" -Default "") } else { $healthTarget }
    state = [string]$probe.state
    freshness = [string]$probe.freshness
    confidence = if ($ManifestOnly) { "low" } elseif ($healthType -eq "websocket" -and $WebSocketProbeMode -eq "process") { "medium" } elseif ([string]$probe.state -eq "available") { "high" } else { "medium" }
    summary = "service $serviceId observed as $($probe.state)"
    observed_at = $now.ToString("o")
    received_at = $now.ToString("o")
    stale_after_seconds = if ($healthType -eq "process" -or ($healthType -eq "websocket" -and $WebSocketProbeMode -eq "process")) { 10 } else { 30 }
    detail = [string]$probe.detail
  }
  $services += $observation
  $serviceStateMap[$serviceId] = $observation
}

$capabilities = @()
$capabilityIndex = 0
foreach ($driver in @($driverManifest.organ_drivers)) {
  $driverId = [string]$driver.driver_id
  $targetServices = ConvertTo-StringArray -Value (Get-OptionalProperty -Object $driver -Name "target_services" -Default @())
  $targetStates = @()
  foreach ($targetService in $targetServices) {
    if ($serviceStateMap.ContainsKey($targetService)) {
      $targetStates += $serviceStateMap[$targetService]
    }
  }
  $staticEvidenceState = if ($targetStates.Count -eq 0) {
    Test-StaticDriverEvidence -Driver $driver -Root $workspace -ManifestOnlyMode ([bool]$ManifestOnly)
  }
  else {
    $null
  }
  $capabilityState = if ($null -ne $staticEvidenceState) {
    $staticEvidenceState
  }
  else {
    ConvertTo-CapabilityState -ServiceStates $targetStates
  }
  foreach ($capability in (ConvertTo-StringArray -Value (Get-OptionalProperty -Object $driver -Name "capabilities" -Default @()))) {
    $capabilityIndex += 1
    $capabilities += [PSCustomObject]@{
      observation_id = New-ObservationId -Kind "capability" -Id "$driverId-$capability" -Index $capabilityIndex
      capability = $capability
      driver_id = $driverId
      organ_id = [string]$driver.organ_id
      service_ids = @($targetServices)
      state = [string]$capabilityState.state
      freshness = [string]$capabilityState.freshness
      confidence = if ($null -ne $staticEvidenceState) { [string]$staticEvidenceState.confidence } elseif ($targetStates.Count -gt 0 -and -not $ManifestOnly) { "medium" } else { "low" }
      summary = "capability $capability observed as $($capabilityState.state)"
      observed_at = $now.ToString("o")
      received_at = $now.ToString("o")
      stale_after_seconds = 30
      detail = [string]$capabilityState.detail
    }
  }
}

$summary = [PSCustomObject]@{
  services_total = $services.Count
  services_available = @($services | Where-Object { $_.state -eq "available" }).Count
  services_degraded = @($services | Where-Object { $_.state -eq "degraded" }).Count
  services_unavailable = @($services | Where-Object { $_.state -eq "unavailable" }).Count
  services_blocked = @($services | Where-Object { $_.state -eq "blocked" }).Count
  services_unknown = @($services | Where-Object { $_.state -eq "unknown" }).Count
  capabilities_total = $capabilities.Count
  capabilities_available = @($capabilities | Where-Object { $_.state -eq "available" }).Count
  capabilities_degraded = @($capabilities | Where-Object { $_.state -eq "degraded" }).Count
  capabilities_unavailable = @($capabilities | Where-Object { $_.state -eq "unavailable" }).Count
  capabilities_blocked = @($capabilities | Where-Object { $_.state -eq "blocked" }).Count
  capabilities_unknown = @($capabilities | Where-Object { $_.state -eq "unknown" }).Count
}

$status = [PSCustomObject]@{
  schema_version = "diagnostics.status.v0"
  generated_at = $now.ToString("o")
  profile_id = [string]$profile.id
  diagnostic_policy_id = [string]$diagnosticPolicy.id
  driver_manifest_id = [string]$driverManifest.id
  port_mode = $PortMode
  websocket_probe_mode = $WebSocketProbeMode
  manifest_only = [bool]$ManifestOnly
  workspace_root = $workspace
  process_registry = [PSCustomObject]@{
    stack_state_dir = $stackState
    pid_file = $pidFile
    recorded_processes = $pidMap.Count
  }
  summary = $summary
  services = @($services | Sort-Object service_id)
  capabilities = @($capabilities | Sort-Object driver_id, capability)
}
$status | Add-Member -NotePropertyName "digest" -NotePropertyValue (Get-ObjectDigest -Value (New-DigestInput -Status $status))
$status | Add-Member -NotePropertyName "stores" -NotePropertyValue ([PSCustomObject]@{
  status_store = $statusPath
  topology_store = $topologyPath
  event_journal = $eventJournalPath
})

$topologySnapshotId = "topology_$($now.UtcDateTime.ToString("yyyyMMddTHHmmssfffZ"))"
$currentMetrics = New-CurrentMetricRecords -Services @($services) -Capabilities @($capabilities) -TopologySnapshotId $topologySnapshotId

$topology = [PSCustomObject]@{
  schema_version = "diagnostics.topology.v0"
  topology_snapshot_id = $topologySnapshotId
  generated_at = $now.ToString("o")
  profile_id = [string]$profile.id
  port_mode = $PortMode
  nodes = @($services | ForEach-Object {
    [PSCustomObject]@{
      id = $_.service_id
      type = "organ_service"
      organ_id = $_.organ_id
      layer = $_.layer
      logical_service = $_.logical_service
      state = $_.state
      freshness = $_.freshness
    }
  })
  capabilities = @($capabilities | ForEach-Object {
    [PSCustomObject]@{
      id = "$($_.driver_id):$($_.capability)"
      capability = $_.capability
      driver_id = $_.driver_id
      organ_id = $_.organ_id
      service_ids = @($_.service_ids)
      state = $_.state
      freshness = $_.freshness
    }
  })
  edges = @($capabilities | ForEach-Object {
    $capability = $_
    foreach ($serviceId in @($capability.service_ids)) {
      [PSCustomObject]@{
        from = $serviceId
        to = "$($capability.driver_id):$($capability.capability)"
        relation = "provides_capability_evidence"
      }
    }
  })
  metrics = [PSCustomObject]@{
    current = @($currentMetrics)
  }
}

$events = @(New-StateChangeEvents -PreviousStatus $previousStatus -CurrentStatus $status -Now $now)

Write-JsonFile -Path $statusPath -Value $status
Write-JsonFile -Path $topologyPath -Value $topology
if (-not $NoJournal) {
  Append-JsonLines -Path $eventJournalPath -Events @($events)
}

[PSCustomObject]@{
  status = "ok"
  generated_at = $now.ToString("o")
  profile_id = [string]$profile.id
  port_mode = $PortMode
  websocket_probe_mode = $WebSocketProbeMode
  manifest_only = [bool]$ManifestOnly
  status_path = $statusPath
  topology_path = $topologyPath
  event_journal_path = $eventJournalPath
  events_appended = if ($NoJournal) { 0 } else { $events.Count }
  services = $summary.services_total
  services_available = $summary.services_available
  services_unavailable = $summary.services_unavailable
  capabilities = $summary.capabilities_total
  capabilities_available = $summary.capabilities_available
  capabilities_unavailable = $summary.capabilities_unavailable
  capabilities_unknown = $summary.capabilities_unknown
  digest = $status.digest
} | ConvertTo-Json -Depth 6
