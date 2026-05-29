param(
  [string]$ProfilePath = "manifests/profiles/standard.json"
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
    [Parameter(Mandatory = $true)][string]$Name,
    [object]$Default = $null
  )
  $property = $Object.PSObject.Properties[$Name]
  if ($null -eq $property -or $null -eq $property.Value) {
    return $Default
  }
  return $property.Value
}

function Resolve-RuntimeComponentPath {
  param([Parameter(Mandatory = $true)][string]$Component)
  if ($Component -eq "turn-router") {
    return Resolve-RepoPath "runtime/routers/turn-router"
  }
  return Resolve-RepoPath "runtime/$Component"
}

function ConvertTo-StringArray {
  param([object]$Value)
  if ($null -eq $Value) {
    return @()
  }
  return @($Value | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

function New-ReflexResult {
  param(
    [Parameter(Mandatory = $true)][string]$Status,
    [Parameter(Mandatory = $true)][string]$StartupStage,
    [Parameter(Mandatory = $true)][string]$Detail,
    [string]$ProfileId = "",
    [string[]]$RequiredRuntime = @(),
    [string[]]$StartupStages = @(),
    [string[]]$MissingRuntime = @(),
    [string[]]$Errors = @(),
    [string]$NextStage = ""
  )

  [PSCustomObject]@{
    status = $Status
    startup_stage = $StartupStage
    reflex_id = "basic_runtime_reflex"
    checked_at = (Get-Date).ToString("o")
    profile_id = $ProfileId
    detail = $Detail
    required_runtime = @($RequiredRuntime)
    startup_stages = @($StartupStages)
    missing_runtime = @($MissingRuntime)
    errors = @($Errors)
    next_stage = $NextStage
  }
}

try {
  $profile = Read-Json -Path $ProfilePath
  $profileId = [string](Get-OptionalProperty -Object $profile -Name "id" -Default "")
  $requiredRuntime = ConvertTo-StringArray -Value (Get-OptionalProperty -Object $profile -Name "required_runtime" -Default @())
  $healthModel = Get-OptionalProperty -Object $profile -Name "health_model"
  if ($null -eq $healthModel) {
    throw "profile has no health_model"
  }

  $bootCriticalCapabilities = ConvertTo-StringArray -Value (Get-OptionalProperty -Object $healthModel -Name "boot_critical_capabilities" -Default @())
  $startupStageObjects = @(Get-OptionalProperty -Object $healthModel -Name "startup_stages" -Default @())
  $startupStages = @($startupStageObjects | ForEach-Object { [string](Get-OptionalProperty -Object $_ -Name "stage" -Default "") } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
  $minimumAliveStage = [string](Get-OptionalProperty -Object $healthModel -Name "minimum_alive_stage" -Default "reflex_alive")
  $minimumReadyStage = [string](Get-OptionalProperty -Object $healthModel -Name "minimum_ready_stage" -Default "")

  $missingRuntime = @()
  foreach ($component in $requiredRuntime) {
    $componentPath = Resolve-RuntimeComponentPath -Component $component
    if (-not (Test-Path -LiteralPath $componentPath -PathType Container)) {
      $missingRuntime += $component
    }
  }

  $errors = @()
  if ($requiredRuntime.Count -eq 0) {
    $errors += "profile has no required_runtime entries"
  }
  if (-not ("basic_runtime_reflex" -in $bootCriticalCapabilities)) {
    $errors += "basic_runtime_reflex is not boot-critical"
  }
  if (-not ("reflex_alive" -in $startupStages)) {
    $errors += "reflex_alive startup stage is missing"
  }
  if ($missingRuntime.Count -gt 0) {
    $errors += "required runtime component skeletons are missing"
  }

  if ($errors.Count -gt 0) {
    New-ReflexResult `
      -Status "nonresponsive" `
      -StartupStage "nonresponsive" `
      -Detail "basic runtime reflex could not establish minimum liveness" `
      -ProfileId $profileId `
      -RequiredRuntime $requiredRuntime `
      -StartupStages $startupStages `
      -MissingRuntime $missingRuntime `
      -Errors $errors `
      -NextStage $minimumReadyStage |
      ConvertTo-Json -Depth 6
    exit 1
  }

  New-ReflexResult `
    -Status "ok" `
    -StartupStage $minimumAliveStage `
    -Detail "profile and runtime component skeletons are readable" `
    -ProfileId $profileId `
    -RequiredRuntime $requiredRuntime `
    -StartupStages $startupStages `
    -MissingRuntime @() `
    -Errors @() `
    -NextStage $minimumReadyStage |
    ConvertTo-Json -Depth 6
  exit 0
}
catch {
  New-ReflexResult `
    -Status "nonresponsive" `
    -StartupStage "nonresponsive" `
    -Detail "basic runtime reflex failed before liveness was established" `
    -Errors @($_.Exception.Message) |
    ConvertTo-Json -Depth 6
  exit 1
}
