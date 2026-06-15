param(
  [string]$HostName = "127.0.0.1",
  [int]$Port = 8787,
  [string]$HomeAssistantServerRoot = "",
  [string]$EnvPath = "",
  [string]$ConfigPath = "",
  [string]$UvCacheDir = "",
  [string]$ExpectedActionId = "",
  [string]$ActionId = "",
  [switch]$CheckOnly,
  [switch]$CheckTracking,
  [switch]$CheckState,
  [switch]$SelfTestTracking,
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

function Resolve-UvCacheDir {
  param([string]$Value)

  $candidate = $Value
  if ([string]::IsNullOrWhiteSpace($candidate)) {
    $candidate = Join-Path $homeAssistantServerRootPath ".uv-cache"
  } elseif (-not [System.IO.Path]::IsPathRooted($candidate)) {
    $candidate = Join-Path $RepoRoot $candidate
  }

  return [System.IO.Path]::GetFullPath($candidate)
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
  Write-Host "  action_execution_scope: this_helper_invocation"
}

function Get-HttpStatusDetail {
  param($ErrorRecord)

  if ($null -eq $ErrorRecord -or $null -eq $ErrorRecord.Exception) {
    return "no-http-response"
  }

  $responseProperty = $ErrorRecord.Exception.PSObject.Properties["Response"]
  if ($null -eq $responseProperty) {
    return "no-http-response"
  }

  $response = $responseProperty.Value
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

function Get-ObjectPropertyValue {
  param(
    $Object,
    [string]$Name,
    $Default = $null
  )

  if ($null -eq $Object) {
    return $Default
  }
  if ($Object -is [System.Collections.IDictionary] -and $Object.Contains($Name)) {
    return $Object[$Name]
  }

  $property = $Object.PSObject.Properties[$Name]
  if ($null -eq $property) {
    return $Default
  }
  if ($null -eq $property.Value) {
    return $Default
  }

  return $property.Value
}

function ConvertTo-NoneText {
  param($Value)

  if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
    return "none"
  }

  return [string]$Value
}

function ConvertTo-BooleanText {
  param($Value)

  if ($null -eq $Value) {
    return "false"
  }
  if ($Value -is [bool]) {
    return $Value.ToString().ToLowerInvariant()
  }
  $text = [string]$Value
  if ([string]::IsNullOrWhiteSpace($text)) {
    return "false"
  }
  return $text.ToLowerInvariant()
}

function ConvertTo-StringArray {
  param($Value)

  if ($null -eq $Value) {
    return @()
  }
  if ($Value -is [string]) {
    if ([string]::IsNullOrWhiteSpace($Value)) {
      return @()
    }
    return @([string]$Value)
  }

  return @($Value | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object { [string]$_ })
}

function ConvertTo-ListText {
  param($Value)

  $items = @(ConvertTo-StringArray -Value $Value)
  if ($items.Count -eq 0) {
    return "none"
  }
  return ($items -join ",")
}

function Get-PositionExpectationText {
  param(
    [string]$Attribute,
    $Min,
    $Max
  )

  if ([string]::IsNullOrWhiteSpace($Attribute) -or $Attribute -eq "none") {
    return "none"
  }

  $minText = ConvertTo-NoneText -Value $Min
  $maxText = ConvertTo-NoneText -Value $Max
  if ($minText -ne "none" -and $maxText -ne "none") {
    return ("{0}<={1}<={2}" -f $minText, $Attribute, $maxText)
  }
  if ($minText -ne "none") {
    return ("{0}>={1}" -f $Attribute, $minText)
  }
  if ($maxText -ne "none") {
    return ("{0}<={1}" -f $Attribute, $maxText)
  }

  return "none"
}

function Get-PositionProofDisplay {
  param($Action)

  $positionProof = Get-ObjectPropertyValue -Object $Action -Name "position_proof"
  if ($null -eq $positionProof) {
    $verification = Get-ObjectPropertyValue -Object $Action -Name "verification"
    $positionProof = Get-ObjectPropertyValue -Object $verification -Name "position"
  }

  $attribute = ConvertTo-NoneText -Value (Get-ObjectPropertyValue -Object $positionProof -Name "attribute")
  $min = Get-ObjectPropertyValue -Object $positionProof -Name "min"
  $max = Get-ObjectPropertyValue -Object $positionProof -Name "max"

  return [pscustomobject]@{
    Attribute = $attribute
    Expected = Get-PositionExpectationText -Attribute $attribute -Min $min -Max $max
  }
}

function Get-ActionTrackingProbe {
  param(
    $Action,
    [string]$ActionId
  )

  $effect = Get-ObjectPropertyValue -Object $Action -Name "expected_effect"
  $trackingRaw = Get-ObjectPropertyValue -Object $Action -Name "state_tracking"
  $trackingStatus = if ($null -eq $trackingRaw -or [string]::IsNullOrWhiteSpace([string]$trackingRaw)) {
    if ($null -eq $effect) { "untracked" } else { "tracked" }
  } else {
    [string]$trackingRaw
  }

  $verificationRaw = Get-ObjectPropertyValue -Object $Action -Name "verification_mode"
  $verificationMode = if ($null -eq $verificationRaw -or [string]::IsNullOrWhiteSpace([string]$verificationRaw)) { "legacy" } else { [string]$verificationRaw }
  $controlTypeRaw = Get-ObjectPropertyValue -Object $Action -Name "control_type"
  $controlType = if ($null -eq $controlTypeRaw -or [string]::IsNullOrWhiteSpace([string]$controlTypeRaw)) { "legacy" } else { [string]$controlTypeRaw }
  $stateAuthorityRaw = Get-ObjectPropertyValue -Object $Action -Name "state_authority"
  $stateAuthority = if ($null -eq $stateAuthorityRaw -or [string]::IsNullOrWhiteSpace([string]$stateAuthorityRaw)) { "legacy" } else { [string]$stateAuthorityRaw }
  $effectExpectedStateRaw = Get-ObjectPropertyValue -Object $effect -Name "expected_state"
  $effectExpectedState = if ($null -eq $effectExpectedStateRaw -or [string]::IsNullOrWhiteSpace([string]$effectExpectedStateRaw)) { "none" } else { [string]$effectExpectedStateRaw }
  $acceptedStatesRaw = Get-ObjectPropertyValue -Object $Action -Name "expected_states"
  $acceptedStates = @()
  if ($null -ne $acceptedStatesRaw) {
    $acceptedStates = @($acceptedStatesRaw | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object { [string]$_ })
  }
  if ($acceptedStates.Count -eq 0 -and $effectExpectedState -ne "none") {
    $acceptedStates = @($effectExpectedState)
  }
  $acceptedStatesText = if ($acceptedStates.Count -eq 0) { "none" } else { $acceptedStates -join "," }
  $settleSecondsRaw = Get-ObjectPropertyValue -Object $Action -Name "settle_seconds"
  $settleSeconds = if ($null -eq $settleSecondsRaw -or [string]::IsNullOrWhiteSpace([string]$settleSecondsRaw)) { "0" } else { [string]$settleSecondsRaw }
  $timeoutSecondsRaw = Get-ObjectPropertyValue -Object $Action -Name "timeout_seconds"
  $timeoutSeconds = if ($null -eq $timeoutSecondsRaw -or [string]::IsNullOrWhiteSpace([string]$timeoutSecondsRaw)) { "0" } else { [string]$timeoutSecondsRaw }
  $positionDisplay = Get-PositionProofDisplay -Action $Action
  $proofCeiling = ConvertTo-NoneText -Value (Get-ObjectPropertyValue -Object $Action -Name "proof_ceiling")
  $liveTestCandidate = ConvertTo-BooleanText -Value (Get-ObjectPropertyValue -Object $Action -Name "live_test_candidate")
  $liveTestReadiness = ConvertTo-NoneText -Value (Get-ObjectPropertyValue -Object $Action -Name "live_test_readiness")
  $liveTestBlockers = ConvertTo-ListText -Value (Get-ObjectPropertyValue -Object $Action -Name "live_test_blockers")
  $restoreActionId = ConvertTo-NoneText -Value (Get-ObjectPropertyValue -Object $Action -Name "restore_action_id")
  $stopActionId = ConvertTo-NoneText -Value (Get-ObjectPropertyValue -Object $Action -Name "stop_action_id")
  $terminalAction = ConvertTo-BooleanText -Value (Get-ObjectPropertyValue -Object $Action -Name "terminal_action")
  $safetyRequirements = ConvertTo-ListText -Value (Get-ObjectPropertyValue -Object $Action -Name "safety_requirements")

  return [pscustomobject]@{
    ActionId = $ActionId
    TrackingStatus = $trackingStatus
    VerificationMode = $verificationMode
    ControlType = $controlType
    StateAuthority = $stateAuthority
    ExpectedState = $effectExpectedState
    ExpectedStates = $acceptedStatesText
    PositionAttribute = $positionDisplay.Attribute
    ExpectedPosition = $positionDisplay.Expected
    SettleSeconds = $settleSeconds
    TimeoutSeconds = $timeoutSeconds
    ProofCeiling = $proofCeiling
    LiveTestCandidate = $liveTestCandidate
    LiveTestReadiness = $liveTestReadiness
    LiveTestBlockers = $liveTestBlockers
    RestoreActionId = $restoreActionId
    StopActionId = $stopActionId
    TerminalAction = $terminalAction
    SafetyRequirements = $safetyRequirements
    CanProduceHaStateProof = ($trackingStatus -eq "tracked")
  }
}

function Assert-TrackingSelfTest {
  param(
    [bool]$Condition,
    [string]$Message
  )

  if (-not $Condition) {
    throw "tracking self-test failed: $Message"
  }
}

function Invoke-TrackingSelfTest {
  $legacyTracked = [pscustomobject]@{
    action_id = "legacy_tracked"
    expected_effect = [pscustomobject]@{ expected_state = "on" }
  }
  $newTracked = [pscustomobject]@{
    action_id = "new_tracked"
    control_type = "stateful_target"
    state_authority = "ha_entity"
    verification_mode = "ha_state"
    state_tracking = "tracked"
    expected_effect = [pscustomobject]@{ expected_state = "off" }
    position_proof = [pscustomobject]@{ attribute = "current_position"; min = 95; max = 100 }
    expected_states = @("off", "closed")
    settle_seconds = 2
    timeout_seconds = 30
    proof_ceiling = "ha_visible_state_checkstate_layer"
    live_test_candidate = $true
    live_test_readiness = "test_now"
    live_test_blockers = @()
    restore_action_id = "restore_action"
    terminal_action = $false
    safety_requirements = @()
  }
  $externalRequired = [pscustomobject]@{
    action_id = "external_required"
    control_type = "stateless_toggle"
    state_authority = "open_loop"
    verification_mode = "external_observation"
    state_tracking = "external_required"
    expected_effect = [pscustomobject]@{ expected_state = "on" }
  }
  $ackOnly = [pscustomobject]@{
    action_id = "ack_only"
    control_type = "stateless_command"
    state_authority = "submitted_only"
    verification_mode = "command_ack_only"
    state_tracking = "ack_only"
  }

  $legacyProbe = Get-ActionTrackingProbe -Action $legacyTracked -ActionId "legacy_tracked"
  Assert-TrackingSelfTest -Condition ($legacyProbe.CanProduceHaStateProof -and $legacyProbe.VerificationMode -eq "legacy" -and $legacyProbe.ExpectedState -eq "on") -Message "legacy /actions payload should fall back to tracked when expected_effect exists"
  Write-Host ("tracking_self_test: legacy_tracked={0}" -f $legacyProbe.TrackingStatus)

  $newProbe = Get-ActionTrackingProbe -Action $newTracked -ActionId "new_tracked"
  Assert-TrackingSelfTest -Condition ($newProbe.CanProduceHaStateProof -and $newProbe.ControlType -eq "stateful_target" -and $newProbe.StateAuthority -eq "ha_entity" -and $newProbe.VerificationMode -eq "ha_state" -and $newProbe.ExpectedState -eq "off" -and $newProbe.ExpectedStates -eq "off,closed" -and $newProbe.PositionAttribute -eq "current_position" -and $newProbe.ExpectedPosition -eq "95<=current_position<=100" -and $newProbe.SettleSeconds -eq "2" -and $newProbe.TimeoutSeconds -eq "30" -and $newProbe.ProofCeiling -eq "ha_visible_state_checkstate_layer" -and $newProbe.LiveTestReadiness -eq "test_now" -and $newProbe.RestoreActionId -eq "restore_action") -Message "new tracked metadata should remain HA state proof capable"
  Write-Host ("tracking_self_test: new_tracked={0}" -f $newProbe.TrackingStatus)

  $externalProbe = Get-ActionTrackingProbe -Action $externalRequired -ActionId "external_required"
  Assert-TrackingSelfTest -Condition ((-not $externalProbe.CanProduceHaStateProof) -and $externalProbe.TrackingStatus -eq "external_required") -Message "external_required must not be treated as HA state proof"
  Write-Host "tracking_self_test: external_required=blocked"

  $ackProbe = Get-ActionTrackingProbe -Action $ackOnly -ActionId "ack_only"
  Assert-TrackingSelfTest -Condition ((-not $ackProbe.CanProduceHaStateProof) -and $ackProbe.TrackingStatus -eq "ack_only") -Message "ack_only must not be treated as HA state proof"
  Write-Host "tracking_self_test: ack_only=blocked"

  $fixtureRows = @($legacyTracked, $newTracked, $externalRequired, $ackOnly)
  $missingRows = @($fixtureRows | Where-Object { [string]$_.action_id -eq "missing_action" })
  Assert-TrackingSelfTest -Condition ($missingRows.Count -eq 0) -Message "missing action should remain a hard stop before preview/execute"
  Write-Host "tracking_self_test: missing_action=blocked"
  Write-Host "tracking self-test: ok"
}

if ($SelfTestTracking) {
  Invoke-TrackingSelfTest
  return
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

if ($CheckOnly -or $CheckState -or $CheckTracking) {
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
  $trackingActionId = ""
  if ($CheckTracking) {
    if (-not [string]::IsNullOrWhiteSpace($ActionId)) {
      $trackingActionId = $ActionId
    } elseif (-not [string]::IsNullOrWhiteSpace($ExpectedActionId)) {
      $trackingActionId = $ExpectedActionId
    } else {
      Write-Cause -Code "live_home_control.bridge.state_tracking_action_missing"
      Write-RootCauseTrace `
        -BlockedAt "state-tracking" `
        -ObservedStatus "blocked" `
        -CauseKind "unsafe-ticket" `
        -Evidence "tracking_action_id=missing" `
        -NextProbe "rerun with -CheckTracking -ActionId <allowed-action-id>"
      throw "-CheckTracking requires -ActionId or -ExpectedActionId"
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
  if ([string]::IsNullOrWhiteSpace($catalogExpectedActionId) -and $CheckTracking) {
    $catalogExpectedActionId = $trackingActionId
  }
  $expectedStatus = "not-requested"
  $matchedActions = @()

  if (-not [string]::IsNullOrWhiteSpace($catalogExpectedActionId)) {
    $matchedActions = @($actionRows | Where-Object { [string]$_.action_id -eq $catalogExpectedActionId })
    if ($matchedActions.Count -eq 0) {
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

  if ($CheckTracking) {
    $trackingAction = $null
    if ($matchedActions.Count -gt 0) {
      $trackingAction = $matchedActions[0]
    } else {
      $trackingAction = @($actionRows | Where-Object { [string]$_.action_id -eq $trackingActionId })[0]
    }

    $trackingProbe = Get-ActionTrackingProbe -Action $trackingAction -ActionId $trackingActionId

    if (-not $trackingProbe.CanProduceHaStateProof) {
      $trackingCauseSuffix = $trackingProbe.TrackingStatus
      if ([string]::IsNullOrWhiteSpace($trackingCauseSuffix)) {
        $trackingCauseSuffix = "untracked"
      }
      Write-Host ("tracking: action_id={0} control_type={1} state_authority={2} verification_mode={3} state_tracking={4} expected_state=none expected_states={5} expected_position={6} settle_seconds={7} timeout_seconds={8} proof_ceiling={9} live_test_candidate={10} live_test_readiness={11} live_test_blockers={12} restore_action={13} stop_action={14} terminal_action={15} safety_requirements={16} status={4}" -f $trackingProbe.ActionId, $trackingProbe.ControlType, $trackingProbe.StateAuthority, $trackingProbe.VerificationMode, $trackingProbe.TrackingStatus, $trackingProbe.ExpectedStates, $trackingProbe.ExpectedPosition, $trackingProbe.SettleSeconds, $trackingProbe.TimeoutSeconds, $trackingProbe.ProofCeiling, $trackingProbe.LiveTestCandidate, $trackingProbe.LiveTestReadiness, $trackingProbe.LiveTestBlockers, $trackingProbe.RestoreActionId, $trackingProbe.StopActionId, $trackingProbe.TerminalAction, $trackingProbe.SafetyRequirements)
      Write-Cause -Code ("live_home_control.bridge.state_tracking_{0}" -f $trackingCauseSuffix)
      Write-RootCauseTrace `
        -BlockedAt "state-tracking" `
        -ObservedStatus "warning" `
        -CauseKind "config-mismatch" `
        -Evidence ("action_id={0}; control_type={1}; state_authority={2}; verification_mode={3}; state_tracking={4}; expected_states={5}; expected_position={6}; settle_seconds={7}; timeout_seconds={8}; proof_ceiling={9}; live_test_readiness={10}; live_test_blockers={11}; restore_action={12}; stop_action={13}; terminal_action={14}; safety_requirements={15}" -f $trackingProbe.ActionId, $trackingProbe.ControlType, $trackingProbe.StateAuthority, $trackingProbe.VerificationMode, $trackingProbe.TrackingStatus, $trackingProbe.ExpectedStates, $trackingProbe.ExpectedPosition, $trackingProbe.SettleSeconds, $trackingProbe.TimeoutSeconds, $trackingProbe.ProofCeiling, $trackingProbe.LiveTestReadiness, $trackingProbe.LiveTestBlockers, $trackingProbe.RestoreActionId, $trackingProbe.StopActionId, $trackingProbe.TerminalAction, $trackingProbe.SafetyRequirements) `
        -NextProbe "use preview/dry-run only; require external/manual proof before claiming physical state"
      throw "Action cannot produce a Home Assistant state proof."
    }

    Write-Host ("tracking: action_id={0} control_type={1} state_authority={2} verification_mode={3} state_tracking=tracked expected_state={4} expected_states={5} expected_position={6} settle_seconds={7} timeout_seconds={8} proof_ceiling={9} live_test_candidate={10} live_test_readiness={11} live_test_blockers={12} restore_action={13} stop_action={14} terminal_action={15} safety_requirements={16} status=tracked" -f $trackingProbe.ActionId, $trackingProbe.ControlType, $trackingProbe.StateAuthority, $trackingProbe.VerificationMode, $trackingProbe.ExpectedState, $trackingProbe.ExpectedStates, $trackingProbe.ExpectedPosition, $trackingProbe.SettleSeconds, $trackingProbe.TimeoutSeconds, $trackingProbe.ProofCeiling, $trackingProbe.LiveTestCandidate, $trackingProbe.LiveTestReadiness, $trackingProbe.LiveTestBlockers, $trackingProbe.RestoreActionId, $trackingProbe.StopActionId, $trackingProbe.TerminalAction, $trackingProbe.SafetyRequirements)
    Write-Cause -Code "none"
    Write-RootCauseTrace `
      -BlockedAt "none" `
      -ObservedStatus "ok" `
      -CauseKind "none" `
      -Evidence ("action_id={0}; control_type={1}; state_authority={2}; verification_mode={3}; state_tracking=tracked; expected_state={4}; expected_states={5}; expected_position={6}; settle_seconds={7}; timeout_seconds={8}; proof_ceiling={9}; live_test_readiness={10}; live_test_blockers={11}; restore_action={12}; stop_action={13}; terminal_action={14}; safety_requirements={15}" -f $trackingProbe.ActionId, $trackingProbe.ControlType, $trackingProbe.StateAuthority, $trackingProbe.VerificationMode, $trackingProbe.ExpectedState, $trackingProbe.ExpectedStates, $trackingProbe.ExpectedPosition, $trackingProbe.SettleSeconds, $trackingProbe.TimeoutSeconds, $trackingProbe.ProofCeiling, $trackingProbe.LiveTestReadiness, $trackingProbe.LiveTestBlockers, $trackingProbe.RestoreActionId, $trackingProbe.StopActionId, $trackingProbe.TerminalAction, $trackingProbe.SafetyRequirements) `
      -NextProbe "proceed only to ticketed preview/dry-run; use -CheckState only after execute/wait or restore/wait" `
      -SafeStop "yes"
    return
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
    $stateExpectedStatesRaw = Get-ObjectPropertyValue -Object $state -Name "expected_states"
    $stateExpectedStates = @()
    if ($null -ne $stateExpectedStatesRaw) {
      $stateExpectedStates = @($stateExpectedStatesRaw | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object { [string]$_ })
    }
    if ($stateExpectedStates.Count -eq 0 -and $expectedState -ne "none") {
      $stateExpectedStates = @($expectedState)
    }
    $stateExpectedStatesText = if ($stateExpectedStates.Count -eq 0) { "none" } else { $stateExpectedStates -join "," }
    $actualState = if ($null -eq $state.actual_state) { "none" } else { [string]$state.actual_state }
    $positionAttribute = ConvertTo-NoneText -Value (Get-ObjectPropertyValue -Object $state -Name "position_attribute")
    $expectedPositionMin = Get-ObjectPropertyValue -Object $state -Name "expected_position_min"
    $expectedPositionMax = Get-ObjectPropertyValue -Object $state -Name "expected_position_max"
    $expectedPosition = Get-PositionExpectationText -Attribute $positionAttribute -Min $expectedPositionMin -Max $expectedPositionMax
    $actualPosition = ConvertTo-NoneText -Value (Get-ObjectPropertyValue -Object $state -Name "actual_position")
    $positionStatus = ConvertTo-NoneText -Value (Get-ObjectPropertyValue -Object $state -Name "position_status")
    Write-Host ("state: action_id={0} expected_state={1} expected_states={2} actual_state={3} expected_position={4} actual_position={5} position_status={6} status={7}" -f $state.action_id, $expectedState, $stateExpectedStatesText, $actualState, $expectedPosition, $actualPosition, $positionStatus, $stateStatus)

    if ($stateStatus -ne "matched") {
      $stateCauseKind = if ($stateStatus -eq "unavailable") { "ha-unreachable" } else { "config-mismatch" }
      $stateCauseCode = "live_home_control.bridge.state_$stateStatus"
      Write-Cause -Code $stateCauseCode
      $stateNextProbe = if ($stateStatus -eq "external_required") {
        "use external/manual proof before claiming physical state"
      } elseif ($stateStatus -eq "ack_only") {
        "do not claim appliance state from command acknowledgement"
      } elseif ($stateStatus -eq "manual_required") {
        "collect manual confirmation as a separate proof layer"
      } elseif ($stateStatus -eq "unsupported") {
        "fix action verification metadata or use another proof layer"
      } elseif ($stateStatus -eq "position_unavailable") {
        "check that the target HA entity exposes current_position and rerun after the ticketed wait"
      } else {
        "wait the ticket interval, verify the ticketed action, or run a ticketed restore"
      }
      Write-RootCauseTrace `
        -ProofLayer "live-ha-state" `
        -BlockedAt "state-check" `
        -ObservedStatus $stateStatus `
        -CauseKind $stateCauseKind `
        -Evidence ("action_id={0}; expected_state={1}; expected_states={2}; actual_state={3}; expected_position={4}; actual_position={5}; position_status={6}" -f $stateActionId, $expectedState, $stateExpectedStatesText, $actualState, $expectedPosition, $actualPosition, $positionStatus) `
        -NextProbe $stateNextProbe
      throw "Home Assistant state check did not produce a matched HA state proof"
    }

    Write-Cause -Code "none"
    Write-RootCauseTrace `
      -ProofLayer "live-ha-state" `
      -BlockedAt "none" `
      -ObservedStatus "ok" `
      -CauseKind "none" `
      -Evidence ("action_id={0}; expected_state={1}; expected_states={2}; actual_state={3}; expected_position={4}; actual_position={5}; position_status={6}" -f $stateActionId, $expectedState, $stateExpectedStatesText, $actualState, $expectedPosition, $actualPosition, $positionStatus) `
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
$uvCachePath = Resolve-UvCacheDir -Value $UvCacheDir
$uvCacheDisplayPath = ConvertTo-DisplayLocalPath -Path $uvCachePath
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
Write-Host ("bridge_start: uv_cache={0}" -f $uvCacheDisplayPath)
Write-Host ("bridge_start: check=pwsh -NoProfile -File .\scripts\start-home-control-bridge.ps1 -CheckOnly -ExpectedActionId <allowed-action-id>")
Write-Host "bridge_start: stop=Ctrl+C"
Write-Host "Secret values are hidden."

if ($DryRun) {
  Write-Host ("dry-run: cd {0}" -f (ConvertTo-DisplayLocalPath -Path $homeAssistantServerRootPath))
  Write-Host ("dry-run: HOME_CONTROL_CONFIG={0}" -f (ConvertTo-DisplayLocalPath -Path $configFilePath))
  Write-Host ("dry-run: UV_CACHE_DIR={0}" -f $uvCacheDisplayPath)
  Write-Host ("dry-run: uv {0}" -f ($uvDisplayArguments -join " "))
  return
}

$oldHomeControlConfig = [Environment]::GetEnvironmentVariable("HOME_CONTROL_CONFIG")
$oldUvCacheDir = [Environment]::GetEnvironmentVariable("UV_CACHE_DIR")
try {
  $env:HOME_CONTROL_CONFIG = $configFilePath
  New-Item -ItemType Directory -Force -Path $uvCachePath | Out-Null
  $env:UV_CACHE_DIR = $uvCachePath
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
  if ($null -eq $oldUvCacheDir) {
    Remove-Item Env:\UV_CACHE_DIR -ErrorAction SilentlyContinue
  } else {
    $env:UV_CACHE_DIR = $oldUvCacheDir
  }
}

exit $exitCode
