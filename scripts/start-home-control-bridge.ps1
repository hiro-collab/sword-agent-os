param(
  [string]$HostName = "127.0.0.1",
  [int]$Port = 8787,
  [string]$HomeAssistantServerRoot = "",
  [string]$EnvPath = "",
  [string]$ConfigPath = "",
  [string]$ExpectedActionId = "",
  [switch]$CheckOnly,
  [switch]$DryRun
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$RepoRoot = Split-Path -Parent $PSScriptRoot

function Resolve-RepoRelativePath {
  param(
    [string]$Value,
    [string]$DefaultRelativePath
  )

  $candidate = $Value
  if ([string]::IsNullOrWhiteSpace($candidate)) {
    $candidate = Join-Path $RepoRoot $DefaultRelativePath
  } elseif (-not [System.IO.Path]::IsPathRooted($candidate)) {
    $candidate = Join-Path $RepoRoot $candidate
  }

  return [System.IO.Path]::GetFullPath($candidate)
}

function Resolve-RootRelativePath {
  param(
    [string]$Value,
    [string]$RootPath,
    [string]$DefaultRelativePath
  )

  $candidate = $Value
  if ([string]::IsNullOrWhiteSpace($candidate)) {
    $candidate = Join-Path $RootPath $DefaultRelativePath
  } elseif (-not [System.IO.Path]::IsPathRooted($candidate)) {
    $candidate = Join-Path $RootPath $candidate
  }

  return [System.IO.Path]::GetFullPath($candidate)
}

function ConvertTo-UvEnvFilePath {
  param([string]$Path)

  return ($Path -replace "\\", "/")
}

function Read-DotEnvValue {
  param(
    [string]$Path,
    [string]$Name
  )

  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    return ""
  }

  foreach ($line in Get-Content -LiteralPath $Path) {
    $trimmed = $line.Trim()
    if ([string]::IsNullOrWhiteSpace($trimmed) -or $trimmed.StartsWith("#")) {
      continue
    }

    $separatorIndex = $trimmed.IndexOf("=")
    if ($separatorIndex -lt 1) {
      continue
    }

    $key = $trimmed.Substring(0, $separatorIndex).Trim()
    if ($key -ne $Name) {
      continue
    }

    $value = $trimmed.Substring($separatorIndex + 1).Trim()
    if (($value.StartsWith('"') -and $value.EndsWith('"')) -or
        ($value.StartsWith("'") -and $value.EndsWith("'"))) {
      $value = $value.Substring(1, $value.Length - 2)
    }
    return $value
  }

  return ""
}

function Test-PlaceholderSecret {
  param([string]$Value)

  if ([string]::IsNullOrWhiteSpace($Value)) {
    return $true
  }

  $lower = $Value.Trim().ToLowerInvariant()
  $placeholderNeedles = @(
    "changeme",
    "change-me",
    "replace-me",
    "replace_with",
    "example",
    "dummy",
    "placeholder",
    "your-token",
    "your_token",
    "token-here",
    "token_here"
  )

  foreach ($needle in $placeholderNeedles) {
    if ($lower.Contains($needle)) {
      return $true
    }
  }

  return $false
}

function Get-SecretLengthClass {
  param(
    [string]$Value,
    [int]$MinimumLength
  )

  if ([string]::IsNullOrWhiteSpace($Value)) {
    return "missing"
  }
  if (Test-PlaceholderSecret -Value $Value) {
    return "placeholder"
  }
  if ($Value.Length -lt $MinimumLength) {
    return "too-short"
  }
  return "present"
}

function Get-RequiredDotEnvSecret {
  param(
    [string]$Path,
    [string]$Name,
    [int]$MinimumLength
  )

  $value = Read-DotEnvValue -Path $Path -Name $Name
  $class = Get-SecretLengthClass -Value $value -MinimumLength $MinimumLength
  Write-Host ("{0}: {1} (value hidden)" -f $Name, $class)

  if ($class -ne "present") {
    throw "$Name is not live-ready in $Path; update local env and rerun scripts/render-env-files.ps1 -Profile standard -Force"
  }

  return $value
}

function Get-ActionRows {
  param($Response)

  if ($null -eq $Response) {
    return @()
  }

  if ($Response -is [System.Array]) {
    return @($Response)
  }

  $actionsProperty = $Response.PSObject.Properties["actions"]
  if ($null -ne $actionsProperty) {
    return @($actionsProperty.Value)
  }

  return @($Response)
}

$homeAssistantServerRootPath = Resolve-RepoRelativePath `
  -Value $HomeAssistantServerRoot `
  -DefaultRelativePath "organs/action/home-assistant-server"
$envFilePath = Resolve-RootRelativePath `
  -Value $EnvPath `
  -RootPath $homeAssistantServerRootPath `
  -DefaultRelativePath ".env"

if (-not (Test-Path -LiteralPath $homeAssistantServerRootPath -PathType Container)) {
  throw "Home Assistant server checkout not found: $homeAssistantServerRootPath"
}
if (-not (Test-Path -LiteralPath $envFilePath -PathType Leaf)) {
  throw "Home Assistant bridge .env not found: $envFilePath"
}

$configPathFromEnv = Read-DotEnvValue -Path $envFilePath -Name "HOME_CONTROL_CONFIG"
if (-not [string]::IsNullOrWhiteSpace($ConfigPath)) {
  $configPathValue = $ConfigPath
} elseif (-not [string]::IsNullOrWhiteSpace($configPathFromEnv)) {
  $configPathValue = $configPathFromEnv
} else {
  $configPathValue = "config/home-control.yaml"
}
$configFilePath = Resolve-RootRelativePath `
  -Value $configPathValue `
  -RootPath $homeAssistantServerRootPath `
  -DefaultRelativePath "config/home-control.yaml"

if (-not (Test-Path -LiteralPath $configFilePath -PathType Leaf)) {
  throw "Home Control config not found: $configFilePath"
}

$homeControlToken = Get-RequiredDotEnvSecret `
  -Path $envFilePath `
  -Name "HOME_CONTROL_API_TOKEN" `
  -MinimumLength 32
$null = Get-RequiredDotEnvSecret `
  -Path $envFilePath `
  -Name "HOME_ASSISTANT_TOKEN" `
  -MinimumLength 16

Write-Host "Home Control bridge local inputs"
Write-Host ("  Root   : {0}" -f $homeAssistantServerRootPath)
Write-Host ("  Env    : {0}" -f $envFilePath)
Write-Host ("  Config : {0}" -f $configFilePath)
Write-Host ("  URL    : http://{0}:{1}" -f $HostName, $Port)

if ($CheckOnly) {
  $baseUrl = "http://${HostName}:$Port"
  $health = Invoke-RestMethod -Method Get -Uri "$baseUrl/health" -TimeoutSec 10
  $healthStatus = [string]$health.status
  $healthOk = [bool]$health.ok
  $actionsCount = [int]$health.actions_count
  Write-Host ("health: status={0} ok={1} actions_count={2}" -f $healthStatus, $healthOk, $actionsCount)

  if (-not $healthOk -or $healthStatus -eq "config_error") {
    throw "Home Control bridge is not live-ready; stop before preview/execute"
  }

  $actions = Invoke-RestMethod `
    -Method Get `
    -Uri "$baseUrl/actions" `
    -Headers @{ Authorization = "Bearer $homeControlToken" } `
    -TimeoutSec 10
  $actionRows = @(Get-ActionRows -Response $actions)
  $expectedStatus = "not-requested"

  if (-not [string]::IsNullOrWhiteSpace($ExpectedActionId)) {
    $matches = @($actionRows | Where-Object { [string]$_.action_id -eq $ExpectedActionId })
    if ($matches.Count -eq 0) {
      $expectedStatus = "missing"
    } else {
      $expectedStatus = "present"
    }
  }

  Write-Host ("actions: status=ok count={0} expected_action={1}" -f $actionRows.Count, $expectedStatus)

  if ($expectedStatus -eq "missing") {
    throw "Expected action was not returned by /actions; stop before preview/execute"
  }

  return
}

$uvCommand = Get-Command uv -ErrorAction Stop
$uvEnvFilePath = ConvertTo-UvEnvFilePath -Path $envFilePath
$uvArguments = @(
  "run",
  "--env-file",
  $uvEnvFilePath,
  "python",
  "-m",
  "uvicorn",
  "home_control_bridge.main:app",
  "--host",
  $HostName,
  "--port",
  [string]$Port
)

Write-Host "Starting Home Control bridge with generated organ .env loaded."
Write-Host "Secret values are hidden. Stop this terminal with Ctrl+C when done."

if ($DryRun) {
  Write-Host ("dry-run: cd {0}" -f $homeAssistantServerRootPath)
  Write-Host ("dry-run: HOME_CONTROL_CONFIG={0}" -f $configFilePath)
  Write-Host ("dry-run: uv {0}" -f ($uvArguments -join " "))
  return
}

$oldHomeControlConfig = [Environment]::GetEnvironmentVariable("HOME_CONTROL_CONFIG")
try {
  $env:HOME_CONTROL_CONFIG = $configFilePath
  Push-Location -LiteralPath $homeAssistantServerRootPath
  try {
    & $uvCommand.Source @uvArguments
    $exitCode = if ($null -ne $LASTEXITCODE) { $LASTEXITCODE } else { 0 }
  } finally {
    Pop-Location
  }
} finally {
  if ($null -eq $oldHomeControlConfig) {
    Remove-Item Env:\HOME_CONTROL_CONFIG -ErrorAction SilentlyContinue
  } else {
    $env:HOME_CONTROL_CONFIG = $oldHomeControlConfig
  }
}

exit $exitCode
