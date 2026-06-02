param(
  [string]$HostName = "127.0.0.1",
  [int]$Port = 8787,
  [string]$HomeAssistantServerRoot = "",
  [string]$EnvPath = "",
  [string]$ConfigPath = "",
  [string]$ExpectedActionId = "",
  [string]$ActionId = "",
  [switch]$CheckOnly,
  [switch]$CheckState,
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

function ConvertTo-CauseToken {
  param([string]$Value)

  return (($Value.ToLowerInvariant() -replace "[^a-z0-9]+", "_").Trim("_"))
}

function Write-Cause {
  param(
    [string]$Code,
    [string]$Detail = ""
  )

  if ([string]::IsNullOrWhiteSpace($Detail)) {
    Write-Host ("cause_code={0}" -f $Code)
  } else {
    Write-Host ("cause_code={0} detail={1}" -f $Code, $Detail)
  }
}

function Write-RootCauseTrace {
  param(
    [string]$ProofLayer = "live-bridge",
    [string]$Entrypoint = "helper",
    [string]$BlockedAt,
    [string]$ObservedStatus,
    [string]$CauseKind,
    [string]$Evidence,
    [string]$NextProbe,
    [string]$SafeStop = "yes",
    [string]$PhysicalActionExecuted = "no"
  )

  Write-Host "root_cause_trace:"
  Write-Host ("  proof_layer: {0}" -f $ProofLayer)
  Write-Host ("  entrypoint: {0}" -f $Entrypoint)
  Write-Host ("  blocked_at: {0}" -f $BlockedAt)
  Write-Host ("  observed_status: {0}" -f $ObservedStatus)
  Write-Host ("  cause_kind: {0}" -f $CauseKind)
  Write-Host ("  evidence: {0}" -f $Evidence)
  Write-Host ("  next_probe: {0}" -f $NextProbe)
  Write-Host ("  safe_stop: {0}" -f $SafeStop)
  Write-Host ("  physical_action_executed: {0}" -f $PhysicalActionExecuted)
}

function Get-HttpStatusDetail {
  param($ErrorRecord)

  $response = $ErrorRecord.Exception.Response
  if ($null -eq $response) {
    return "no-http-response"
  }

  $statusCode = $null
  if ($null -ne $response.StatusCode) {
    try {
      $statusCode = [int]$response.StatusCode
    } catch {
      $statusCode = [string]$response.StatusCode
    }
  }

  if ($null -eq $statusCode -or [string]::IsNullOrWhiteSpace([string]$statusCode)) {
    return "http-response-without-status"
  }

  return "http-$statusCode"
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

function Get-CauseKindForSecretStatus {
  param($Status)

  switch ($Status.class) {
    "missing" { return "missing-process-env" }
    "placeholder" { return "placeholder-secret" }
    "too-short" { return "auth-failure" }
    default { return "unknown" }
  }
}

function Get-DotEnvSecretStatus {
  param(
    [string]$Path,
    [string]$Name,
    [int]$MinimumLength
  )

  $value = Read-DotEnvValue -Path $Path -Name $Name
  $class = Get-SecretLengthClass -Value $value -MinimumLength $MinimumLength
  return [PSCustomObject]@{
    name = $Name
    value = $value
    class = $class
  }
}

function Write-SecretStatus {
  param($Status)

  Write-Host ("{0}: {1} (value hidden)" -f $Status.name, $Status.class)
}

function Get-HomeControlConfigActionCount {
  param([string]$Path)

  $inActions = $false
  $count = 0

  foreach ($line in Get-Content -LiteralPath $Path) {
    if ([string]::IsNullOrWhiteSpace($line)) {
      continue
    }

    $trimmed = $line.Trim()
    if ($trimmed.StartsWith("#")) {
      continue
    }

    if (-not $inActions) {
      if ($line -match '^\s*actions\s*:\s*$') {
        $inActions = $true
      }
      continue
    }

    if ($line -match '^\S' -and $trimmed -ne "actions:") {
      break
    }

    if ($line -match '^\s{2}([a-z0-9][a-z0-9_:-]{0,79})\s*:\s*$') {
      $count += 1
    }
  }

  return $count
}

function Get-HomeControlConfigLogPath {
  param([string]$Path)

  foreach ($line in Get-Content -LiteralPath $Path) {
    if ($line -match '^\s*log_path\s*:\s*(.+?)\s*$') {
      $value = $Matches[1].Trim()
      if (($value.StartsWith('"') -and $value.EndsWith('"')) -or
          ($value.StartsWith("'") -and $value.EndsWith("'"))) {
        $value = $value.Substring(1, $value.Length - 2)
      }
      if (-not [string]::IsNullOrWhiteSpace($value)) {
        return $value
      }
    }
  }

  return ".cache/home_control/events.jsonl"
}

function ConvertTo-DisplayLocalPath {
  param([string]$Path)

  if ([string]::IsNullOrWhiteSpace($Path)) {
    return "unknown"
  }
  if (-not [System.IO.Path]::IsPathRooted($Path)) {
    return ($Path -replace "\\", "/")
  }

  try {
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $rootPath = [System.IO.Path]::GetFullPath($RepoRoot)
    $separators = [char[]]@([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
    $rootTrimmed = $rootPath.TrimEnd($separators)
    $fullTrimmed = $fullPath.TrimEnd($separators)

    if ($fullTrimmed.Equals($rootTrimmed, [System.StringComparison]::OrdinalIgnoreCase)) {
      return "."
    }

    $rootPrefix = $rootTrimmed + [System.IO.Path]::DirectorySeparatorChar
    if ($fullPath.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
      return ($fullPath.Substring($rootPrefix.Length) -replace "\\", "/")
    }
  } catch {
    return "<absolute-local-path-hidden>"
  }

  return "<absolute-local-path-hidden>"
}

function Get-ConfigErrorKind {
  param(
    $HomeControlSecret,
    $HomeAssistantSecret
  )

  if ($HomeControlSecret.class -ne "present") {
    return "HOME_CONTROL_API_TOKEN"
  }
  if ($HomeAssistantSecret.class -ne "present") {
    return "HOME_ASSISTANT_TOKEN"
  }

  return "none"
}

function Assert-LiveReadySecret {
  param(
    $Status,
    [string]$EnvPath
  )

  if ($Status.class -ne "present") {
    $displayEnvPath = ConvertTo-DisplayLocalPath -Path $EnvPath
    $nameToken = ConvertTo-CauseToken -Value $Status.name
    $classToken = ConvertTo-CauseToken -Value $Status.class
    Write-Cause -Code "live_home_control.env.${nameToken}_${classToken}"
    Write-RootCauseTrace `
      -BlockedAt "process-env" `
      -ObservedStatus "blocked" `
      -CauseKind (Get-CauseKindForSecretStatus -Status $Status) `
      -Evidence "$($Status.name)=$($Status.class); value_hidden=true" `
      -NextProbe "update local env and rerun render-env-files -Force"
    throw "$($Status.name) is not live-ready in $displayEnvPath; update local env and rerun scripts/render-env-files.ps1 -Profile standard -Force"
  }
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
  Write-Cause -Code "live_home_control.local.checkout_missing" -Detail "home_assistant_server_root"
  Write-RootCauseTrace `
    -BlockedAt "config-load" `
    -ObservedStatus "blocked" `
    -CauseKind "missing-file" `
    -Evidence "home_assistant_server_root=missing" `
    -NextProbe "install or update the standard distribution"
  throw "Home Assistant server checkout not found: $(ConvertTo-DisplayLocalPath -Path $homeAssistantServerRootPath)"
}
if (-not (Test-Path -LiteralPath $envFilePath -PathType Leaf)) {
  Write-Cause -Code "live_home_control.local.env_missing" -Detail "home_assistant_server_env"
  Write-RootCauseTrace `
    -BlockedAt "env-render" `
    -ObservedStatus "blocked" `
    -CauseKind "missing-file" `
    -Evidence "home_assistant_server_env=missing" `
    -NextProbe "rerun render-env-files -Profile standard -Force"
  throw "Home Assistant bridge .env not found: $(ConvertTo-DisplayLocalPath -Path $envFilePath)"
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
  Write-Cause -Code "live_home_control.local.config_missing" -Detail "home_control_config"
  Write-RootCauseTrace `
    -BlockedAt "config-load" `
    -ObservedStatus "blocked" `
    -CauseKind "missing-file" `
    -Evidence "home_control_config=missing" `
    -NextProbe "render config or provide the local override"
  throw "Home Control config not found: $(ConvertTo-DisplayLocalPath -Path $configFilePath)"
}

$homeControlSecret = Get-DotEnvSecretStatus `
  -Path $envFilePath `
  -Name "HOME_CONTROL_API_TOKEN" `
  -MinimumLength 32
$homeAssistantSecret = Get-DotEnvSecretStatus `
  -Path $envFilePath `
  -Name "HOME_ASSISTANT_TOKEN" `
  -MinimumLength 16
$configActionCount = Get-HomeControlConfigActionCount -Path $configFilePath
$configLogPath = Get-HomeControlConfigLogPath -Path $configFilePath
$configErrorKind = Get-ConfigErrorKind `
  -HomeControlSecret $homeControlSecret `
  -HomeAssistantSecret $homeAssistantSecret

if (-not $CheckState) {
  Write-SecretStatus -Status $homeControlSecret
  Write-SecretStatus -Status $homeAssistantSecret
  Write-Host ("config: yaml_loaded=True action_count={0} config_error_kind={1}" -f $configActionCount, $configErrorKind)
}

Assert-LiveReadySecret -Status $homeControlSecret -EnvPath $envFilePath
Assert-LiveReadySecret -Status $homeAssistantSecret -EnvPath $envFilePath

$homeControlToken = $homeControlSecret.value

if (-not $CheckState) {
  Write-Host "Home Control bridge local inputs"
  Write-Host ("  Root   : {0}" -f (ConvertTo-DisplayLocalPath -Path $homeAssistantServerRootPath))
  Write-Host ("  Env    : {0}" -f (ConvertTo-DisplayLocalPath -Path $envFilePath))
  Write-Host ("  Config : {0}" -f (ConvertTo-DisplayLocalPath -Path $configFilePath))
  Write-Host ("  URL    : http://{0}:{1}" -f $HostName, $Port)
}

if ($CheckOnly -or $CheckState) {
  $baseUrl = "http://${HostName}:$Port"
  $stateActionId = ""
  if ($CheckState) {
    if (-not [string]::IsNullOrWhiteSpace($ActionId)) {
      $stateActionId = $ActionId
    } elseif (-not [string]::IsNullOrWhiteSpace($ExpectedActionId)) {
      $stateActionId = $ExpectedActionId
    } else {
      Write-Cause -Code "live_home_control.bridge.state_action_missing"
      Write-RootCauseTrace `
        -ProofLayer "live-ha-state" `
        -BlockedAt "state-check" `
        -ObservedStatus "blocked" `
        -CauseKind "unsafe-ticket" `
        -Evidence "state_action_id=missing" `
        -NextProbe "rerun with -CheckState -ActionId <allowed-action-id>"
      throw "-CheckState requires -ActionId or -ExpectedActionId"
    }
  }

  try {
    $health = Invoke-RestMethod -Method Get -Uri "$baseUrl/health" -TimeoutSec 10
  } catch {
    $httpDetail = Get-HttpStatusDetail -ErrorRecord $_
    Write-Cause -Code "live_home_control.bridge.health_unreachable" -Detail $httpDetail
    Write-RootCauseTrace `
      -BlockedAt "health" `
      -ObservedStatus "unavailable" `
      -CauseKind "unknown" `
      -Evidence "health_endpoint=$httpDetail" `
      -NextProbe "start bridge with helper or check port/process"
    throw "Home Control bridge /health could not be read; stop before preview/execute"
  }
  $healthStatus = [string]$health.status
  $healthOk = [bool]$health.ok
  $actionsCount = [int]$health.actions_count
  if (-not $CheckState) {
    Write-Host ("health: status={0} ok={1} actions_count={2}" -f $healthStatus, $healthOk, $actionsCount)
  }

  if (-not $healthOk -or $healthStatus -eq "config_error") {
    Write-Cause -Code "live_home_control.bridge.health_config_error" -Detail ("status={0}" -f $healthStatus)
    Write-RootCauseTrace `
      -BlockedAt "health" `
      -ObservedStatus $healthStatus `
      -CauseKind "unknown" `
      -Evidence ("health_status={0}; health_actions_count={1}; config_error_kind={2}" -f $healthStatus, $actionsCount, $configErrorKind) `
      -NextProbe "inspect config_error_kind and rerun helper -CheckOnly"
    throw "Home Control bridge is not live-ready; stop before preview/execute"
  }

  try {
    $actions = Invoke-RestMethod `
      -Method Get `
      -Uri "$baseUrl/actions" `
      -Headers @{ Authorization = "Bearer $homeControlToken" } `
      -TimeoutSec 10
  } catch {
    $httpDetail = Get-HttpStatusDetail -ErrorRecord $_
    $actionsCauseKind = if ($httpDetail -eq "http-401" -or $httpDetail -eq "http-403") { "auth-failure" } elseif ($httpDetail -eq "http-503") { "config-mismatch" } else { "unknown" }
    Write-Cause -Code "live_home_control.bridge.actions_unavailable" -Detail $httpDetail
    Write-RootCauseTrace `
      -BlockedAt "action-catalog" `
      -ObservedStatus "unavailable" `
      -CauseKind $actionsCauseKind `
      -Evidence "actions_endpoint=$httpDetail" `
      -NextProbe "check bridge auth/config and rerun helper -CheckOnly"
    throw "Home Control bridge /actions could not be read; stop before preview/execute"
  }
  $actionRows = @(Get-ActionRows -Response $actions)
  $catalogExpectedActionId = $ExpectedActionId
  if ([string]::IsNullOrWhiteSpace($catalogExpectedActionId) -and $CheckState) {
    $catalogExpectedActionId = $stateActionId
  }
  $expectedStatus = "not-requested"

  if (-not [string]::IsNullOrWhiteSpace($catalogExpectedActionId)) {
    $matches = @($actionRows | Where-Object { [string]$_.action_id -eq $catalogExpectedActionId })
    if ($matches.Count -eq 0) {
      $expectedStatus = "missing"
    } else {
      $expectedStatus = "present"
    }
  }

  if (-not $CheckState) {
    Write-Host ("actions: status=ok count={0} expected_action={1}" -f $actionRows.Count, $expectedStatus)
  }

  if ($expectedStatus -eq "missing") {
    Write-Cause -Code "live_home_control.bridge.expected_action_missing"
    Write-RootCauseTrace `
      -BlockedAt "action-catalog" `
      -ObservedStatus "blocked" `
      -CauseKind "action-not-in-catalog" `
      -Evidence ("actions_count={0}; expected_action=missing" -f $actionRows.Count) `
      -NextProbe "fix live ticket action id or Home Control mapping"
    throw "Expected action was not returned by /actions; stop before preview/execute"
  }

  if ($CheckState) {
    $encodedActionId = [System.Uri]::EscapeDataString($stateActionId)
    try {
      $state = Invoke-RestMethod `
        -Method Get `
        -Uri "$baseUrl/actions/$encodedActionId/state" `
        -Headers @{ Authorization = "Bearer $homeControlToken" } `
        -TimeoutSec 10
    } catch {
      $httpDetail = Get-HttpStatusDetail -ErrorRecord $_
      Write-Cause -Code "live_home_control.bridge.state_unavailable" -Detail $httpDetail
      Write-RootCauseTrace `
        -ProofLayer "live-ha-state" `
        -BlockedAt "state-check" `
        -ObservedStatus "unavailable" `
        -CauseKind "ha-unreachable" `
        -Evidence "state_endpoint=$httpDetail; action_id=$stateActionId" `
        -NextProbe "check bridge auth, Home Assistant availability, and rerun -CheckState"
      throw "Home Control bridge state check could not be read"
    }

    $stateStatus = [string]$state.status
    $expectedState = if ($null -eq $state.expected_state) { "none" } else { [string]$state.expected_state }
    $actualState = if ($null -eq $state.actual_state) { "none" } else { [string]$state.actual_state }
    Write-Host ("state: action_id={0} expected_state={1} actual_state={2} status={3}" -f $state.action_id, $expectedState, $actualState, $stateStatus)

    if ($stateStatus -ne "matched") {
      $stateCauseKind = if ($stateStatus -eq "unavailable") { "ha-unreachable" } elseif ($stateStatus -eq "untracked") { "config-mismatch" } else { "config-mismatch" }
      $stateCauseCode = "live_home_control.bridge.state_$stateStatus"
      Write-Cause -Code $stateCauseCode
      Write-RootCauseTrace `
        -ProofLayer "live-ha-state" `
        -BlockedAt "state-check" `
        -ObservedStatus $stateStatus `
        -CauseKind $stateCauseKind `
        -Evidence ("action_id={0}; expected_state={1}; actual_state={2}" -f $stateActionId, $expectedState, $actualState) `
        -NextProbe "wait the ticket interval, verify the ticketed action, or run a ticketed restore"
      throw "Home Assistant state check did not match the expected state"
    }

    Write-Cause -Code "none"
    Write-RootCauseTrace `
      -ProofLayer "live-ha-state" `
      -BlockedAt "none" `
      -ObservedStatus "ok" `
      -CauseKind "none" `
      -Evidence ("action_id={0}; expected_state={1}; actual_state={2}" -f $stateActionId, $expectedState, $actualState) `
      -NextProbe "optional independent physical/camera confirmation if that proof layer is required"
    return
  }

  Write-Cause -Code "none"
  Write-RootCauseTrace `
    -BlockedAt "none" `
    -ObservedStatus "ok" `
    -CauseKind "none" `
    -Evidence ("actions_count={0}; expected_action={1}" -f $actionRows.Count, $expectedStatus) `
    -NextProbe "proceed only to ticketed preview under live guardrails" `
    -SafeStop "yes"
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
$uvDisplayArguments = @($uvArguments)
$uvDisplayArguments[2] = ConvertTo-DisplayLocalPath -Path $envFilePath

Write-Host "Starting Home Control bridge with generated organ .env loaded."
Write-Host ("bridge_start: status=starting host={0} port={1} helper_pid={2}" -f $HostName, $Port, $PID)
Write-Host ("bridge_start: log_path={0}" -f (ConvertTo-DisplayLocalPath -Path $configLogPath))
Write-Host ("bridge_start: check=pwsh -NoProfile -File .\scripts\start-home-control-bridge.ps1 -CheckOnly -ExpectedActionId <allowed-action-id>")
Write-Host "bridge_start: stop=Ctrl+C"
Write-Host "Secret values are hidden."

if ($DryRun) {
  Write-Host ("dry-run: cd {0}" -f (ConvertTo-DisplayLocalPath -Path $homeAssistantServerRootPath))
  Write-Host ("dry-run: HOME_CONTROL_CONFIG={0}" -f (ConvertTo-DisplayLocalPath -Path $configFilePath))
  Write-Host ("dry-run: uv {0}" -f ($uvDisplayArguments -join " "))
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
