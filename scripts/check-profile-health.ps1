param(
  [string]$ProfilePath = "manifests/profiles/thought-core-v0-compat.json",
  [switch]$ManifestOnly,
  [ValidateSet("manifest_default", "isolated_override")]
  [string]$PortMode = "manifest_default",
  [int]$TimeoutMs = 1200,
  [string]$WorkspaceRoot = "",
  [string]$StackStateDir = ""
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

function Read-Json {
  param([Parameter(Mandatory = $true)][string]$Path)
  return Get-Content -Raw -LiteralPath (Resolve-RepoPath $Path) | ConvertFrom-Json
}

function Resolve-WorkspaceRoot {
  param([string]$Path)
  if ([string]::IsNullOrWhiteSpace($Path)) {
    return $RepoRoot
  }
  if ([System.IO.Path]::IsPathRooted($Path)) {
    return $Path
  }
  return Join-Path $RepoRoot ($Path -replace "/", [System.IO.Path]::DirectorySeparatorChar)
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
    Write-Warning "Failed to read process registry: $Path"
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

function ConvertTo-StringArray {
  param([object]$Value)
  if ($null -eq $Value) {
    return @()
  }
  return @($Value | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
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
  $allowedNames = @(ConvertTo-StringArray -Value (Get-OptionalProperty -Object $Entry -Name "allowed_process_names" -Default @()))
  if ($allowedNames.Count -eq 0) {
    return $true
  }
  $processName = Normalize-ProcessName -Name ([string]$process.ProcessName)
  $allowed = @($allowedNames | ForEach-Object { Normalize-ProcessName -Name $_ })
  return $allowed -contains $processName
}

function Test-ProcessHealth {
  param(
    [Parameter(Mandatory = $true)]$Health,
    [Parameter(Mandatory = $true)][hashtable]$PidMap,
    [Parameter(Mandatory = $true)][string]$PidFile
  )
  $pidName = [string](Get-OptionalProperty -Object $Health -Name "pid_name" -Default "")
  if ([string]::IsNullOrWhiteSpace($pidName)) {
    return @{ status = "unknown"; detail = "process health missing pid_name" }
  }
  if (-not $PidMap.ContainsKey($pidName)) {
    return @{ status = "down"; detail = "not recorded in $PidFile" }
  }
  $entry = $PidMap[$pidName]
  $pidValue = [int](Get-OptionalProperty -Object $entry -Name "pid" -Default 0)
  if (Test-ProcessEntryAlive -Entry $entry) {
    return @{ status = "ok"; detail = "pid $pidValue" }
  }
  return @{ status = "down"; detail = "recorded pid $pidValue is not alive" }
}

function Test-TcpEndpoint {
  param(
    [Parameter(Mandatory = $true)][string]$HostName,
    [Parameter(Mandatory = $true)][int]$Port,
    [Parameter(Mandatory = $true)][int]$Timeout
  )

  $client = [System.Net.Sockets.TcpClient]::new()
  try {
    $task = $client.ConnectAsync($HostName, $Port)
    if (-not $task.Wait($Timeout)) {
      return @{ ok = $false; detail = "timeout" }
    }
    return @{ ok = $client.Connected; detail = "tcp" }
  }
  catch {
    return @{ ok = $false; detail = $_.Exception.Message }
  }
  finally {
    $client.Dispose()
  }
}

function Test-HttpEndpoint {
  param(
    [Parameter(Mandatory = $true)][string]$Url,
    [Parameter(Mandatory = $true)][int]$Timeout
  )

  try {
    $response = Invoke-WebRequest -Uri $Url -Method Get -TimeoutSec ([Math]::Max(1, [int][Math]::Ceiling($Timeout / 1000))) -UseBasicParsing
    return @{ ok = ($response.StatusCode -ge 200 -and $response.StatusCode -lt 500); detail = "http $($response.StatusCode)" }
  }
  catch {
    $response = Get-OptionalProperty -Object $_.Exception -Name "Response"
    if ($null -ne $response -and $null -ne $response.StatusCode) {
      return @{ ok = $false; detail = "http $([int]$response.StatusCode)" }
    }
    return @{ ok = $false; detail = $_.Exception.Message }
  }
}

$profile = Read-Json -Path $ProfilePath
$serviceManifest = Read-Json -Path ([string]$profile.service_manifest)
$resolvedWorkspaceRoot = Resolve-WorkspaceRoot -Path $WorkspaceRoot
$resolvedStackStateDir = Resolve-StackStateDir -Root $resolvedWorkspaceRoot -Path $StackStateDir
$pidFile = Join-Path $resolvedStackStateDir "pids.json"
$pidMap = Read-PidMap -Path $pidFile

$rows = foreach ($service in $serviceManifest.services) {
  $health = $service.health
  $serviceId = [string]$service.service_id
  $healthUrl = [string](Get-OptionalProperty -Object $health -Name "url" -Default "")
  if (-not [string]::IsNullOrWhiteSpace($healthUrl)) {
    $healthUrl = Convert-UrlForPortMode -Url $healthUrl -ServiceId $serviceId -ServiceManifest $serviceManifest -SelectedPortMode $PortMode
  }
  $status = "manifest"
  $detail = ""

  if (-not $ManifestOnly) {
    switch ([string]$health.type) {
      "http" {
        $result = Test-HttpEndpoint -Url $healthUrl -Timeout $TimeoutMs
        $status = if ($result.ok) { "ok" } else { "down" }
        $detail = $result.detail
      }
      "websocket" {
        $uri = [System.Uri]::new($healthUrl)
        $port = if ($uri.Port -gt 0) { $uri.Port } elseif ($uri.Scheme -eq "wss") { 443 } else { 80 }
        $result = Test-TcpEndpoint -HostName $uri.Host -Port $port -Timeout $TimeoutMs
        $status = if ($result.ok) { "ok" } else { "down" }
        $detail = $result.detail
      }
      "process" {
        $result = Test-ProcessHealth -Health $health -PidMap $pidMap -PidFile $pidFile
        $status = $result.status
        $detail = $result.detail
      }
      default {
        $status = "unknown"
        $detail = "unsupported health type: $($health.type)"
      }
    }
  }
  else {
    $url = Get-OptionalProperty -Object $health -Name "url"
    $pidName = Get-OptionalProperty -Object $health -Name "pid_name"
    if ($null -ne $url) {
      $detail = $healthUrl
    }
    elseif ($null -ne $pidName) {
      $detail = [string]$pidName
    }
  }

  [PSCustomObject]@{
    service_id = $serviceId
    layer = [string]$service.layer
    logical_service = [string]$service.logical_service
    health_type = [string]$health.type
    status = $status
    detail = $detail
  }
}

[PSCustomObject]@{
  profile_id = [string]$profile.id
  manifest_only = [bool]$ManifestOnly
  port_mode = $PortMode
  checked_at = (Get-Date).ToString("o")
  process_registry = [PSCustomObject]@{
    stack_state_dir = $resolvedStackStateDir
    pid_file = $pidFile
    recorded_processes = $pidMap.Count
  }
  services = @($rows)
} | ConvertTo-Json -Depth 5
