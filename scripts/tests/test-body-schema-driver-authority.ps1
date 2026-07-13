param()

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$ServicesPath = Join-Path $RepoRoot "manifests/services/standard.json"
$DiagnosticDriversPath = Join-Path $RepoRoot "manifests/drivers/standard.json"
$BodyDriversPath = Join-Path $RepoRoot "manifests/driver-manifests/system-cell-v0.json"
$BuilderPath = Join-Path $RepoRoot "scripts/build-body-schema-snapshot.ps1"
$TempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("sword-body-schema-driver-map-" + [guid]::NewGuid().ToString("N"))
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

try {
  $services = Get-Content -Raw -LiteralPath $ServicesPath | ConvertFrom-Json
  $diagnosticDrivers = Get-Content -Raw -LiteralPath $DiagnosticDriversPath | ConvertFrom-Json
  $bodyDrivers = Get-Content -Raw -LiteralPath $BodyDriversPath | ConvertFrom-Json
  $bodyDriverById = @{}
  foreach ($driver in @($bodyDrivers.drivers)) {
    $bodyDriverById[[string]$driver.driver_id] = $driver
  }

  $diagnosticDriverByService = @{}
  foreach ($driver in @($diagnosticDrivers.organ_drivers)) {
    $driverId = [string]$driver.driver_id
    Assert-True -Condition $bodyDriverById.ContainsKey($driverId) -Message "diagnostic driver lacks canonical body authority"
    foreach ($serviceId in @($driver.target_services | ForEach-Object { [string]$_ })) {
      Assert-True -Condition (-not $diagnosticDriverByService.ContainsKey($serviceId)) -Message "service has duplicate diagnostic drivers"
      $diagnosticDriverByService[$serviceId] = $driverId
    }
  }

  $serviceRows = @()
  foreach ($service in @($services.services)) {
    $serviceId = [string]$service.service_id
    if (-not $diagnosticDriverByService.ContainsKey($serviceId)) {
      continue
    }
    $serviceRows += [PSCustomObject]@{
      service_id = $serviceId
      driver_id = [string]$diagnosticDriverByService[$serviceId]
      state = "available"
    }
  }
  Assert-True -Condition ($serviceRows.Count -gt 0) -Message "no mapped standard services were available for the fixture"

  New-Item -ItemType Directory -Path $TempRoot -Force | Out-Null
  [PSCustomObject]@{
    services = @($serviceRows)
    capabilities = @()
  } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $StatusPath -Encoding UTF8

  $shellPath = (Get-Process -Id $PID).Path
  $builderOutput = & $shellPath -NoProfile -File $BuilderPath -StatusPath $StatusPath -Check -NoWrite -Json
  Assert-True -Condition ($LASTEXITCODE -eq 0) -Message "body schema builder failed"
  $result = ($builderOutput -join "`n") | ConvertFrom-Json
  Assert-True -Condition ([string]$result.status -eq "ok") -Message "body schema result was not ok"
  Assert-True -Condition ([int]$result.body_schema.status_source.mapped_entries -eq $serviceRows.Count) -Message "body schema left standard service evidence unmapped"

  $mappedSourceCount = @(
    $result.body_schema.organs |
      ForEach-Object { @($_.source_refs) } |
      Where-Object { [string]$_ -like "service:*" }
  ).Count
  Assert-True -Condition ($mappedSourceCount -eq $serviceRows.Count) -Message "body schema source refs do not match mapped services"

  Write-Output ("status=ok; assertions={0}; mapped_status_entries={1}; unmapped=0" -f $Assertions, $serviceRows.Count)
}
finally {
  if (Test-Path -LiteralPath $TempRoot) {
    Remove-Item -LiteralPath $TempRoot -Recurse -Force -ErrorAction SilentlyContinue
  }
}
