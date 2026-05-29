param(
  [string]$StatusPath = ".cache/agent-os/status/current.json",
  [string]$TopologyPath = ".cache/agent-os/status/topology.json",
  [string]$ProfilePath = "manifests/profiles/thought-core-v0-compat.json",
  [string]$DiagnosticPolicyPath = "manifests/diagnostics/standard.json",
  [string]$DriverManifestPath = "manifests/drivers/standard.json",
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
    throw "required JSON file not found: $resolved"
  }
  return Get-Content -Raw -LiteralPath $resolved | ConvertFrom-Json
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

function Add-Issue {
  param(
    [System.Collections.Generic.List[object]]$Issues,
    [ValidateSet("error", "warning")]
    [string]$Severity,
    [Parameter(Mandatory = $true)][string]$Code,
    [Parameter(Mandatory = $true)][string]$Message,
    [string]$Subject = ""
  )
  $Issues.Add([PSCustomObject]@{
    severity = $Severity
    code = $Code
    subject = $Subject
    message = $Message
  }) | Out-Null
}

function Test-Timestamp {
  param([object]$Value)
  if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
    return $false
  }
  try {
    [void][DateTimeOffset]::Parse([string]$Value)
    return $true
  }
  catch {
    return $false
  }
}

function Test-SafeMetricText {
  param([object]$Value)
  if ($null -eq $Value) {
    return $true
  }
  $text = [string]$Value
  if ($text -match "(?i)(api[_-]?key|access[_-]?token|secret|password|bearer\s+[A-Za-z0-9._-]+)") {
    return $false
  }
  if ($text -match "^[A-Za-z]:\\") {
    return $false
  }
  if ($text -match "\\\\[^\\]+\\") {
    return $false
  }
  return $true
}

function Test-MetricRecord {
  param(
    [Parameter(Mandatory = $true)]$Metric,
    [Parameter(Mandatory = $true)][int]$Index,
    [System.Collections.Generic.List[object]]$Issues
  )
  $subject = [string](Get-OptionalProperty -Object $Metric -Name "subject" -Default "metric[$Index]")
  foreach ($required in @("metric", "subject", "value", "recorded_at", "source")) {
    $value = Get-OptionalProperty -Object $Metric -Name $required
    if ($null -eq $value -or [string]::IsNullOrWhiteSpace([string]$value)) {
      Add-Issue -Issues $Issues -Severity "error" -Code "metric.required_field_missing" -Subject $subject -Message "metric record is missing required field: $required"
    }
  }

  $metricName = [string](Get-OptionalProperty -Object $Metric -Name "metric" -Default "")
  if ($metricName -notin @("reality_divergence", "state_confidence", "feedback_match", "source_confidence")) {
    Add-Issue -Issues $Issues -Severity "warning" -Code "metric.unknown_name" -Subject $subject -Message "metric name is not in the initial v0 set: $metricName"
  }

  try {
    $numeric = [double](Get-OptionalProperty -Object $Metric -Name "value" -Default -1)
    if ($numeric -lt 0.0 -or $numeric -gt 1.0) {
      Add-Issue -Issues $Issues -Severity "error" -Code "metric.value_out_of_range" -Subject $subject -Message "metric value must be between 0.0 and 1.0 for initial neural monitoring metrics"
    }
  }
  catch {
    Add-Issue -Issues $Issues -Severity "error" -Code "metric.value_not_numeric" -Subject $subject -Message "metric value is not numeric"
  }

  foreach ($timestampField in @("recorded_at", "stale_after")) {
    $timestamp = Get-OptionalProperty -Object $Metric -Name $timestampField
    if ($null -ne $timestamp -and -not (Test-Timestamp -Value $timestamp)) {
      Add-Issue -Issues $Issues -Severity "error" -Code "metric.invalid_timestamp" -Subject $subject -Message "metric field $timestampField must be an ISO-like timestamp"
    }
  }

  foreach ($field in @("subject", "source", "basis")) {
    $value = Get-OptionalProperty -Object $Metric -Name $field
    if (-not (Test-SafeMetricText -Value $value)) {
      Add-Issue -Issues $Issues -Severity "error" -Code "metric.unsafe_text" -Subject $subject -Message "metric field $field appears to contain a secret, raw credential, or local path"
    }
  }

  foreach ($ref in ConvertTo-StringArray -Value (Get-OptionalProperty -Object $Metric -Name "evidence_refs" -Default @())) {
    if ($ref -notmatch "^(event|snapshot|turn|action):") {
      Add-Issue -Issues $Issues -Severity "error" -Code "metric.invalid_evidence_ref" -Subject $subject -Message "evidence_ref must start with event:, snapshot:, turn:, or action:: $ref"
    }
    if (-not (Test-SafeMetricText -Value $ref)) {
      Add-Issue -Issues $Issues -Severity "error" -Code "metric.unsafe_evidence_ref" -Subject $subject -Message "evidence_ref appears to contain a secret, raw credential, or local path"
    }
  }
}

$issues = [System.Collections.Generic.List[object]]::new()

$profile = Read-JsonFile -Path $ProfilePath
$diagnosticPolicy = Read-JsonFile -Path $DiagnosticPolicyPath
$driverManifest = Read-JsonFile -Path $DriverManifestPath
$status = Read-JsonFile -Path $StatusPath
$topology = Read-JsonFile -Path $TopologyPath

$allowedStates = ConvertTo-StringArray -Value $diagnosticPolicy.observation_envelope.state_values
$allowedFreshness = ConvertTo-StringArray -Value $diagnosticPolicy.observation_envelope.freshness_values

if ([string](Get-OptionalProperty -Object $status -Name "schema_version" -Default "") -ne "diagnostics.status.v0") {
  Add-Issue -Issues $issues -Severity "error" -Code "status.schema_version" -Message "status schema_version must be diagnostics.status.v0"
}
if ([string](Get-OptionalProperty -Object $topology -Name "schema_version" -Default "") -ne "diagnostics.topology.v0") {
  Add-Issue -Issues $issues -Severity "error" -Code "topology.schema_version" -Message "topology schema_version must be diagnostics.topology.v0"
}
if ([string]::IsNullOrWhiteSpace([string](Get-OptionalProperty -Object $topology -Name "topology_snapshot_id" -Default ""))) {
  Add-Issue -Issues $issues -Severity "error" -Code "topology.snapshot_id_missing" -Message "topology snapshot must carry topology_snapshot_id"
}

$statusServices = @($status.services)
$statusServiceIds = @($statusServices | ForEach-Object { [string]$_.service_id })
foreach ($serviceId in ConvertTo-StringArray -Value $profile.required_services) {
  if ($serviceId -notin $statusServiceIds) {
    Add-Issue -Issues $issues -Severity "error" -Code "status.required_service_missing" -Subject $serviceId -Message "required service is missing from diagnostics status"
  }
}
foreach ($service in $statusServices) {
  $serviceId = [string]$service.service_id
  if ([string]$service.state -notin $allowedStates) {
    Add-Issue -Issues $issues -Severity "error" -Code "status.invalid_service_state" -Subject $serviceId -Message "service state is outside diagnostic policy"
  }
  if ([string]$service.freshness -notin $allowedFreshness) {
    Add-Issue -Issues $issues -Severity "error" -Code "status.invalid_service_freshness" -Subject $serviceId -Message "service freshness is outside diagnostic policy"
  }
  foreach ($field in @("observation_id", "driver_id", "observed_at", "received_at", "tier", "confidence", "summary")) {
    $value = Get-OptionalProperty -Object $service -Name $field
    if ($null -eq $value -or [string]::IsNullOrWhiteSpace([string]$value)) {
      Add-Issue -Issues $issues -Severity "error" -Code "status.required_service_field_missing" -Subject $serviceId -Message "service field $field is required by the diagnostic observation envelope"
    }
    elseif ($field -in @("observed_at", "received_at") -and -not (Test-Timestamp -Value $value)) {
      Add-Issue -Issues $issues -Severity "error" -Code "status.invalid_service_timestamp" -Subject $serviceId -Message "service field $field must be an ISO-like timestamp"
    }
  }
}

$statusCapabilities = @($status.capabilities)
$capabilityKeys = @($statusCapabilities | ForEach-Object { "$($_.driver_id)::$($_.capability)" })
foreach ($driver in @($driverManifest.organ_drivers)) {
  $driverId = [string]$driver.driver_id
  foreach ($capability in ConvertTo-StringArray -Value $driver.capabilities) {
    $key = "$driverId::$capability"
    if ($key -notin $capabilityKeys) {
      Add-Issue -Issues $issues -Severity "error" -Code "status.driver_capability_missing" -Subject $key -Message "declared organ-driver capability is missing from diagnostics status"
    }
  }
}
foreach ($capability in $statusCapabilities) {
  $subject = "$($capability.driver_id)::$($capability.capability)"
  foreach ($field in @("observation_id", "capability", "driver_id", "organ_id", "observed_at", "received_at", "confidence", "summary")) {
    $value = Get-OptionalProperty -Object $capability -Name $field
    if ($null -eq $value -or [string]::IsNullOrWhiteSpace([string]$value)) {
      Add-Issue -Issues $issues -Severity "error" -Code "status.required_capability_field_missing" -Subject $subject -Message "capability field $field is required by the diagnostic observation envelope"
    }
    elseif ($field -in @("observed_at", "received_at") -and -not (Test-Timestamp -Value $value)) {
      Add-Issue -Issues $issues -Severity "error" -Code "status.invalid_capability_timestamp" -Subject $subject -Message "capability field $field must be an ISO-like timestamp"
    }
  }
  if ([string]$capability.state -notin $allowedStates) {
    Add-Issue -Issues $issues -Severity "error" -Code "status.invalid_capability_state" -Subject $subject -Message "capability state is outside diagnostic policy"
  }
  if ([string]$capability.freshness -notin $allowedFreshness) {
    Add-Issue -Issues $issues -Severity "error" -Code "status.invalid_capability_freshness" -Subject $subject -Message "capability freshness is outside diagnostic policy"
  }
}

$metrics = @()
$metricsObject = Get-OptionalProperty -Object $topology -Name "metrics"
if ($null -ne $metricsObject) {
  $metrics = @(Get-OptionalProperty -Object $metricsObject -Name "current" -Default @())
}
if ($metrics.Count -eq 0) {
  Add-Issue -Issues $issues -Severity "error" -Code "topology.metrics_missing" -Message "topology snapshot must expose current metric records under metrics.current[]"
}
for ($i = 0; $i -lt $metrics.Count; $i += 1) {
  Test-MetricRecord -Metric $metrics[$i] -Index $i -Issues $issues
}

$errorCount = @($issues | Where-Object { $_.severity -eq "error" }).Count
$warningCount = @($issues | Where-Object { $_.severity -eq "warning" }).Count
$resultStatus = if ($errorCount -gt 0) { "failed" } elseif ($warningCount -gt 0) { "warning" } else { "ok" }

$result = [PSCustomObject]@{
  status = $resultStatus
  errors = $errorCount
  warnings = $warningCount
  services = $statusServices.Count
  capabilities = $statusCapabilities.Count
  current_metrics = $metrics.Count
  issues = @($issues)
}

if ($Json) {
  $result | ConvertTo-Json -Depth 8
}
else {
  Write-Output "Agent OS neural monitoring contract: $resultStatus"
  Write-Output "services=$($result.services) capabilities=$($result.capabilities) current_metrics=$($result.current_metrics) errors=$errorCount warnings=$warningCount"
  foreach ($issue in $issues) {
    $prefix = "[$($issue.severity)] $($issue.code)"
    if (-not [string]::IsNullOrWhiteSpace([string]$issue.subject)) {
      $prefix = "$prefix $($issue.subject)"
    }
    Write-Output "$prefix - $($issue.message)"
  }
}

if ($errorCount -gt 0) {
  exit 1
}
