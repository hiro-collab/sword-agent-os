param(
  [string]$ProfilePath = "manifests/profiles/thought-core-v0-compat.json",
  [switch]$ManifestOnly,
  [int]$TimeoutMs = 1200
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

function Get-OptionalProperty {
  param(
    [Parameter(Mandatory = $true)]$Object,
    [Parameter(Mandatory = $true)][string]$Name
  )
  $property = $Object.PSObject.Properties[$Name]
  if ($null -eq $property) {
    return $null
  }
  return $property.Value
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

$rows = foreach ($service in $serviceManifest.services) {
  $health = $service.health
  $status = "manifest"
  $detail = ""

  if (-not $ManifestOnly) {
    switch ([string]$health.type) {
      "http" {
        $result = Test-HttpEndpoint -Url ([string]$health.url) -Timeout $TimeoutMs
        $status = if ($result.ok) { "ok" } else { "down" }
        $detail = $result.detail
      }
      "websocket" {
        $uri = [System.Uri]::new([string]$health.url)
        $port = if ($uri.Port -gt 0) { $uri.Port } elseif ($uri.Scheme -eq "wss") { 443 } else { 80 }
        $result = Test-TcpEndpoint -HostName $uri.Host -Port $port -Timeout $TimeoutMs
        $status = if ($result.ok) { "ok" } else { "down" }
        $detail = $result.detail
      }
      "process" {
        $status = "unknown"
        $detail = "process registry not implemented"
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
      $detail = [string]$url
    }
    elseif ($null -ne $pidName) {
      $detail = [string]$pidName
    }
  }

  [PSCustomObject]@{
    service_id = [string]$service.service_id
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
  checked_at = (Get-Date).ToString("o")
  services = @($rows)
} | ConvertTo-Json -Depth 5
