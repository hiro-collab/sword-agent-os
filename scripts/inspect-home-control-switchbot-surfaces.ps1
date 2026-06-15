param(
  [string]$ConfigPath = "",
  [string]$EnvPath = "",
  [int]$TimeoutSeconds = 8,
  [switch]$Json,
  [switch]$IncludePrivateEntityIds,
  [switch]$IncludePrivateStateValues
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$RepoRoot = Split-Path -Parent $PSScriptRoot

function Resolve-RepoRelativePath {
  param(
    [string]$Value,
    [string]$DefaultRelativePath
  )

  if ([string]::IsNullOrWhiteSpace($Value)) {
    return [System.IO.Path]::GetFullPath((Join-Path $RepoRoot $DefaultRelativePath))
  }
  if ([System.IO.Path]::IsPathRooted($Value)) {
    return [System.IO.Path]::GetFullPath($Value)
  }
  return [System.IO.Path]::GetFullPath((Join-Path $RepoRoot $Value))
}

function Resolve-DefaultConfigPath {
  $localLive = Join-Path $RepoRoot "local\env\home-control.live.yaml"
  if (Test-Path -LiteralPath $localLive -PathType Leaf) {
    return [System.IO.Path]::GetFullPath($localLive)
  }
  return [System.IO.Path]::GetFullPath((Join-Path $RepoRoot "organs\action\home-assistant-server\config\home-control.yaml"))
}

function ConvertTo-DisplayPath {
  param([string]$Path)

  if ([string]::IsNullOrWhiteSpace($Path)) {
    return "<none>"
  }
  try {
    $full = [System.IO.Path]::GetFullPath($Path)
    $root = [System.IO.Path]::GetFullPath($RepoRoot)
    if ($full.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) {
      return ("<repo>\" + $full.Substring($root.Length).TrimStart("\", "/"))
    }
  } catch {
  }
  return "<absolute-local-path-hidden>"
}

function ConvertFrom-YamlScalarText {
  param([string]$Value)

  if ($null -eq $Value) {
    return ""
  }
  $text = ([string]$Value).Trim()
  $text = $text -replace "\s+#.*$", ""
  $text = $text.Trim()
  if (($text.StartsWith('"') -and $text.EndsWith('"')) -or
      ($text.StartsWith("'") -and $text.EndsWith("'"))) {
    return $text.Substring(1, $text.Length - 2)
  }
  return $text
}

function ConvertFrom-YamlInlineList {
  param([string]$Value)

  $text = ConvertFrom-YamlScalarText -Value $Value
  if ([string]::IsNullOrWhiteSpace($text)) {
    return @()
  }
  if ($text.StartsWith("[") -and $text.EndsWith("]")) {
    $inner = $text.Substring(1, $text.Length - 2).Trim()
    if ([string]::IsNullOrWhiteSpace($inner)) {
      return @()
    }
    return @($inner.Split(",") | ForEach-Object {
      ConvertFrom-YamlScalarText -Value $_
    } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
  }
  return @($text)
}

function ConvertFrom-YamlBoolText {
  param([string]$Value)

  $text = ConvertFrom-YamlScalarText -Value $Value
  return $text.ToLowerInvariant() -eq "true"
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

function Get-NestedValue {
  param(
    $Object,
    [string[]]$Path
  )

  $current = $Object
  foreach ($part in $Path) {
    if ($null -eq $current) {
      return $null
    }
    $property = $current.PSObject.Properties[$part]
    if ($null -eq $property) {
      return $null
    }
    $current = $property.Value
  }
  return $current
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
  $property = $Object.PSObject.Properties[$Name]
  if ($null -eq $property -or $null -eq $property.Value) {
    return $Default
  }
  return $property.Value
}

function New-ActionInfo {
  return [ordered]@{
    ha_script = ""
    control_type = ""
    state_authority = ""
    live_test_candidate = $false
    restore_action_id = ""
    stop_action_id = ""
    terminal_action = $false
    safety_requirements = @()
    proof_ceiling = ""
    verification_mode = ""
    accepted_states = @()
    position_attribute = ""
    position_min = $null
    position_max = $null
    expected_effect_domain = ""
    expected_effect_service = ""
    expected_effect_entity_id = ""
    expected_effect_state = ""
  }
}

function Read-HomeControlConfig {
  param([string]$Path)

  $config = [ordered]@{
    home_assistant_base_url = ""
    home_assistant_token_env = "HOME_ASSISTANT_TOKEN"
    actions = [ordered]@{}
  }

  $section = ""
  $currentActionId = ""
  $nested = ""

  foreach ($line in Get-Content -LiteralPath $Path) {
    if ([string]::IsNullOrWhiteSpace($line)) {
      continue
    }
    $trimmed = $line.Trim()
    if ($trimmed.StartsWith("#")) {
      continue
    }

    if ($line -match "^home_assistant\s*:\s*$") {
      $section = "home_assistant"
      $currentActionId = ""
      $nested = ""
      continue
    }
    if ($line -match "^actions\s*:\s*$") {
      $section = "actions"
      $currentActionId = ""
      $nested = ""
      continue
    }
    if ($line -match "^\S" -and $trimmed -notin @("home_assistant:", "actions:")) {
      $section = ""
      $currentActionId = ""
      $nested = ""
    }

    if ($section -eq "home_assistant") {
      if ($line -match "^\s{2}base_url\s*:\s*(.+?)\s*$") {
        $config.home_assistant_base_url = ConvertFrom-YamlScalarText -Value $Matches[1]
      } elseif ($line -match "^\s{2}token_env\s*:\s*(.+?)\s*$") {
        $config.home_assistant_token_env = ConvertFrom-YamlScalarText -Value $Matches[1]
      }
      continue
    }

    if ($section -ne "actions") {
      continue
    }

    if ($line -match "^\s{2}([A-Za-z0-9_:-]+)\s*:\s*$") {
      $currentActionId = $Matches[1]
      $config.actions[$currentActionId] = New-ActionInfo
      $nested = ""
      continue
    }
    if ([string]::IsNullOrWhiteSpace($currentActionId)) {
      continue
    }

    $action = $config.actions[$currentActionId]
    if ($line -match "^\s{4}ha_script\s*:\s*(.+?)\s*$") {
      $action.ha_script = ConvertFrom-YamlScalarText -Value $Matches[1]
    } elseif ($line -match "^\s{4}control_type\s*:\s*(.+?)\s*$") {
      $action.control_type = ConvertFrom-YamlScalarText -Value $Matches[1]
    } elseif ($line -match "^\s{4}state_authority\s*:\s*(.+?)\s*$") {
      $action.state_authority = ConvertFrom-YamlScalarText -Value $Matches[1]
    } elseif ($line -match "^\s{4}live_test_candidate\s*:\s*(.+?)\s*$") {
      $action.live_test_candidate = ConvertFrom-YamlBoolText -Value $Matches[1]
    } elseif ($line -match "^\s{4}restore_action_id\s*:\s*(.+?)\s*$") {
      $action.restore_action_id = ConvertFrom-YamlScalarText -Value $Matches[1]
    } elseif ($line -match "^\s{4}stop_action_id\s*:\s*(.+?)\s*$") {
      $action.stop_action_id = ConvertFrom-YamlScalarText -Value $Matches[1]
    } elseif ($line -match "^\s{4}terminal_action\s*:\s*(.+?)\s*$") {
      $action.terminal_action = ConvertFrom-YamlBoolText -Value $Matches[1]
    } elseif ($line -match "^\s{4}safety_requirements\s*:\s*(.*?)\s*$") {
      $nested = "safety_requirements"
      $inlineSafety = ConvertFrom-YamlInlineList -Value $Matches[1]
      if (@($inlineSafety).Count -gt 0) {
        $action.safety_requirements = @($inlineSafety)
      }
    } elseif ($line -match "^\s{6}-\s*(.+?)\s*$" -and $nested -eq "safety_requirements") {
      $action.safety_requirements = @($action.safety_requirements + (ConvertFrom-YamlScalarText -Value $Matches[1]))
    } elseif ($line -match "^\s{4}proof_ceiling\s*:\s*(.+?)\s*$") {
      $action.proof_ceiling = ConvertFrom-YamlScalarText -Value $Matches[1]
    } elseif ($line -match "^\s{4}verification\s*:\s*$") {
      $nested = "verification"
    } elseif ($line -match "^\s{6}mode\s*:\s*(.+?)\s*$" -and $nested -eq "verification") {
      $action.verification_mode = ConvertFrom-YamlScalarText -Value $Matches[1]
    } elseif ($line -match "^\s{6}accepted_states\s*:\s*(.+?)\s*$" -and $nested -eq "verification") {
      $action.accepted_states = @(ConvertFrom-YamlInlineList -Value $Matches[1])
    } elseif ($line -match "^\s{6}position\s*:\s*$" -and $nested -eq "verification") {
      $nested = "verification.position"
    } elseif ($line -match "^\s{8}attribute\s*:\s*(.+?)\s*$" -and $nested -eq "verification.position") {
      $action.position_attribute = ConvertFrom-YamlScalarText -Value $Matches[1]
    } elseif ($line -match "^\s{8}min\s*:\s*(.+?)\s*$" -and $nested -eq "verification.position") {
      $action.position_min = ConvertFrom-YamlScalarText -Value $Matches[1]
    } elseif ($line -match "^\s{8}max\s*:\s*(.+?)\s*$" -and $nested -eq "verification.position") {
      $action.position_max = ConvertFrom-YamlScalarText -Value $Matches[1]
    } elseif ($line -match "^\s{4}expected_effect\s*:\s*$") {
      $nested = "expected_effect"
    } elseif ($line -match "^\s{6}domain\s*:\s*(.+?)\s*$" -and $nested -eq "expected_effect") {
      $action.expected_effect_domain = ConvertFrom-YamlScalarText -Value $Matches[1]
    } elseif ($line -match "^\s{6}service\s*:\s*(.+?)\s*$" -and $nested -eq "expected_effect") {
      $action.expected_effect_service = ConvertFrom-YamlScalarText -Value $Matches[1]
    } elseif ($line -match "^\s{6}entity_id\s*:\s*(.+?)\s*$" -and $nested -eq "expected_effect") {
      $action.expected_effect_entity_id = ConvertFrom-YamlScalarText -Value $Matches[1]
    } elseif ($line -match "^\s{6}expected_state\s*:\s*(.+?)\s*$" -and $nested -eq "expected_effect") {
      $action.expected_effect_state = ConvertFrom-YamlScalarText -Value $Matches[1]
    }
  }

  return [pscustomobject]$config
}

function Invoke-HaGet {
  param(
    [string]$BaseUrl,
    [string]$Path,
    [hashtable]$Headers,
    [int]$Timeout
  )

  $uri = $BaseUrl.TrimEnd("/") + $Path
  return Invoke-RestMethod -Method Get -Uri $uri -Headers $Headers -TimeoutSec $Timeout
}

function Get-HaReadErrorClass {
  param($ErrorRecord)

  $text = ""
  if ($null -ne $ErrorRecord -and $null -ne $ErrorRecord.Exception) {
    $text = [string]$ErrorRecord.Exception.Message
  }
  if ($text -match "refused|拒否") {
    return "connection_refused_or_HA_down"
  }
  if ($text -match "timed out|timeout|タイムアウト") {
    return "timeout"
  }
  if ($text -match "401|Unauthorized") {
    return "unauthorized"
  }
  if ($text -match "403|Forbidden") {
    return "forbidden"
  }
  return "read_failed"
}

function Write-BlockedPayload {
  param(
    [string]$ErrorClass,
    [string]$Stage
  )

  $payload = [pscustomobject]@{
    classification = "blocked_ha_readonly_access_unavailable"
    blocked_at = $Stage
    error_class = $ErrorClass
    config_path_class = ConvertTo-DisplayPath -Path $configFilePath
    env_path_class = if (Test-Path -LiteralPath $envFilePath -PathType Leaf) { ConvertTo-DisplayPath -Path $envFilePath } else { "missing_or_not_needed" }
    ha_readonly_access = "blocked"
    appliance_mutation = "no"
    ha_service_call = "no"
    script_turn_on = "no"
    preview_dry_run_execute = "no"
    raw_private_publication_default = (-not $IncludePrivateEntityIds -and -not $IncludePrivateStateValues)
    exact_blocker = "Home Assistant read-only API was not reachable for this helper invocation"
    does_not_prove = @(
      "Home Control pass",
      "final RR003 pass",
      "HA state authority absence"
    )
  }

  if ($Json) {
    $payload | ConvertTo-Json -Depth 8
  } else {
    Write-Host "Home Control SwitchBot read-only surface inspection"
    Write-Host ("classification={0}" -f $payload.classification)
    Write-Host ("blocked_at={0}" -f $payload.blocked_at)
    Write-Host ("error_class={0}" -f $payload.error_class)
    Write-Host "appliance_mutation=no"
    Write-Host "ha_service_call=no"
    Write-Host "script_turn_on=no"
    Write-Host ("raw_private_publication_default={0}" -f ([bool]$payload.raw_private_publication_default).ToString().ToLowerInvariant())
  }
}

function Get-DomainFromEntityId {
  param([string]$EntityId)

  if ([string]::IsNullOrWhiteSpace($EntityId) -or -not $EntityId.Contains(".")) {
    return ""
  }
  return $EntityId.Split(".")[0]
}

function Get-EntityDomainSummaries {
  param($States)

  $domains = [ordered]@{}
  foreach ($state in @($States)) {
    $entityId = [string](Get-ObjectPropertyValue -Object $state -Name "entity_id" -Default "")
    $domain = Get-DomainFromEntityId -EntityId $entityId
    if ([string]::IsNullOrWhiteSpace($domain)) {
      continue
    }
    if (-not $domains.Contains($domain)) {
      $domains[$domain] = [ordered]@{
        entity_count = 0
        supported_features_attr_count = 0
        current_position_attr_count = 0
        battery_attr_count = 0
        device_class_attr_count = 0
        unique_state_value_count = 0
        entity_ids = @()
        state_values = @()
      }
    }
    $summary = $domains[$domain]
    $summary.entity_count += 1
    $summary.entity_ids = @($summary.entity_ids + $entityId)
    $stateValue = [string](Get-ObjectPropertyValue -Object $state -Name "state" -Default "")
    if (-not [string]::IsNullOrWhiteSpace($stateValue)) {
      $summary.state_values = @($summary.state_values + $stateValue)
    }
    $attributes = Get-ObjectPropertyValue -Object $state -Name "attributes"
    if ($null -ne $attributes) {
      foreach ($attrName in @("supported_features", "current_position", "battery", "battery_level", "device_class")) {
        $attrValue = Get-ObjectPropertyValue -Object $attributes -Name $attrName
        if ($null -eq $attrValue) {
          continue
        }
        switch ($attrName) {
          "supported_features" { $summary.supported_features_attr_count += 1 }
          "current_position" { $summary.current_position_attr_count += 1 }
          "battery" { $summary.battery_attr_count += 1 }
          "battery_level" { $summary.battery_attr_count += 1 }
          "device_class" { $summary.device_class_attr_count += 1 }
        }
      }
    }
  }

  foreach ($domain in @($domains.Keys)) {
    $summary = $domains[$domain]
    $summary.unique_state_value_count = @($summary.state_values | Sort-Object -Unique).Count
    if (-not $IncludePrivateEntityIds) {
      $summary.Remove("entity_ids")
    }
    if ($IncludePrivateStateValues) {
      $summary.state_values = @($summary.state_values | Sort-Object -Unique)
    } else {
      $summary.Remove("state_values")
    }
  }

  return $domains
}

function Get-ServiceMap {
  param($Services)

  $map = [ordered]@{}
  foreach ($item in @($Services)) {
    $domain = [string](Get-ObjectPropertyValue -Object $item -Name "domain" -Default "")
    if ([string]::IsNullOrWhiteSpace($domain)) {
      continue
    }
    $servicesObject = Get-ObjectPropertyValue -Object $item -Name "services"
    $names = @()
    if ($null -ne $servicesObject) {
      $names = @($servicesObject.PSObject.Properties.Name | Sort-Object)
    }
    $map[$domain] = $names
  }
  return $map
}

function Test-ServicePresent {
  param(
    $ServiceMap,
    [string]$Domain,
    [string]$Service
  )

  if ($null -eq $ServiceMap -or -not $ServiceMap.Contains($Domain)) {
    return $false
  }
  return @($ServiceMap[$Domain]) -contains $Service
}

function Get-LiveTestDecision {
  param(
    $Action,
    [string]$ExpectedEntityClass
  )

  $blockers = @()
  if (-not [bool]$Action.live_test_candidate) {
    $blockers += "not_marked_live_test_candidate"
  }
  if ($Action.verification_mode -ne "ha_state" -or [string]::IsNullOrWhiteSpace($Action.expected_effect_entity_id)) {
    $blockers += "missing_ha_visible_success_criterion"
  } elseif ($ExpectedEntityClass -ne "readable") {
    $blockers += "expected_entity_not_readable"
  }
  if ([bool]$Action.live_test_candidate -and -not [bool]$Action.terminal_action) {
    if ([string]::IsNullOrWhiteSpace($Action.restore_action_id) -and [string]::IsNullOrWhiteSpace($Action.stop_action_id)) {
      $blockers += "missing_restore_or_stop"
    }
  }
  foreach ($requirement in @($Action.safety_requirements)) {
    if (-not [string]::IsNullOrWhiteSpace([string]$requirement)) {
      $blockers += ("safety_requirement:{0}" -f $requirement)
    }
  }

  $readiness = "test_now"
  if ($blockers.Count -gt 0) {
    if ([bool]$Action.live_test_candidate) {
      $readiness = "do_not_test_current_config"
    } else {
      $readiness = "not_live_test_candidate"
    }
  }

  return [pscustomobject]@{
    readiness = $readiness
    blockers = $blockers
  }
}

function Get-ExpectedEntityReadClass {
  param(
    [string]$EntityId,
    $States
  )

  if ([string]::IsNullOrWhiteSpace($EntityId)) {
    return "missing_expected_effect_entity"
  }
  foreach ($state in @($States)) {
    $candidate = [string](Get-ObjectPropertyValue -Object $state -Name "entity_id" -Default "")
    if ($candidate -eq $EntityId) {
      return "readable"
    }
  }
  return "not_found_in_readonly_states"
}

function Get-ActionBindingRows {
  param(
    $Config,
    $States,
    $DomainSummaries,
    $ServiceMap
  )

  $targetActions = @(
    "door_open",
    "door_close",
    "door_stop",
    "vacuum_start",
    "vacuum_pause",
    "vacuum_return"
  )

  $rows = @()
  foreach ($actionId in $targetActions) {
    $action = $null
    if ($Config.actions.Contains($actionId)) {
      $action = $Config.actions[$actionId]
    }
    if ($null -eq $action) {
      $rows += [pscustomobject]@{
        action_id = $actionId
        control_type = "missing"
        state_authority = "missing"
        verification_mode = "missing"
        current_config_binding = "missing_action"
        expected_effect_domain = "none"
        expected_entity_read_class = "missing_action"
        accepted_state_count = 0
        position_check_configured = $false
        authority_candidate = "not_configured"
        live_test_candidate = $false
        live_test_readiness = "do_not_test_current_config"
        live_test_blockers = @("missing_action")
        proof_ceiling = "none"
        restore_action_id_class = "none"
        stop_action_id_class = "none"
        terminal_action = $false
        safety_requirements = @()
        smallest_next_step = "add action metadata before testing"
      }
      continue
    }

    $expectedEntityClass = Get-ExpectedEntityReadClass -EntityId $action.expected_effect_entity_id -States $States
    $hasExpectedEffect = -not [string]::IsNullOrWhiteSpace($action.expected_effect_entity_id)
    $domain = if ($hasExpectedEffect) { $action.expected_effect_domain } else { "" }
    $positionConfigured = -not [string]::IsNullOrWhiteSpace($action.position_attribute)
    $acceptedStateCount = @($action.accepted_states).Count
    if ($acceptedStateCount -eq 0 -and -not [string]::IsNullOrWhiteSpace($action.expected_effect_state)) {
      $acceptedStateCount = 1
    }
    $liveDecision = Get-LiveTestDecision -Action $action -ExpectedEntityClass $expectedEntityClass
    $liveBlockers = if (@($liveDecision.blockers).Count -eq 0) { @() } else { @($liveDecision.blockers) }

    $binding = if ($hasExpectedEffect) { "expected_effect_bound" } else { "expected_effect_missing" }
    $candidate = "none"
    $next = "keep as current limitation"

    if ($actionId.StartsWith("door_")) {
      $coverSummary = $DomainSummaries["cover"]
      $coverPositionCount = if ($null -eq $coverSummary) { 0 } else { [int]$coverSummary.current_position_attr_count }
      if ($hasExpectedEffect -and $expectedEntityClass -eq "readable" -and $positionConfigured) {
        $candidate = "position_checkstate_configured"
        $next = "run CheckTracking/CheckState no-live, then only live-move with obstruction and restore preconditions"
      } elseif ($coverPositionCount -gt 0) {
        $candidate = "position_mapping_possible_not_bound"
        $next = "bind exact cover target plus current_position thresholds and original-position restore rule"
      } else {
        $candidate = "cover_position_authority_not_found"
        $next = "add HA cover position authority or external observation before movement tests"
      }
    } elseif ($actionId.StartsWith("vacuum_")) {
      $vacuumSummary = $DomainSummaries["vacuum"]
      $vacuumCount = if ($null -eq $vacuumSummary) { 0 } else { [int]$vacuumSummary.entity_count }
      if ($hasExpectedEffect -and $expectedEntityClass -eq "readable" -and $acceptedStateCount -gt 0) {
        $candidate = "vacuum_checkstate_configured"
        $next = "run CheckTracking/CheckState no-live; live only with no-retry return/cleanup gate"
      } elseif ($vacuumCount -gt 0) {
        $candidate = "vacuum_state_mapping_possible_not_bound"
        $next = "bind exact vacuum target plus accepted post-action states and return/stop path"
      } else {
        $candidate = "vacuum_state_authority_not_found"
        $next = "add HA vacuum state authority before start/pause/return tests"
      }
    }

    $rows += [pscustomobject]@{
      action_id = $actionId
      control_type = if ([string]::IsNullOrWhiteSpace($action.control_type)) { "missing" } else { $action.control_type }
      state_authority = if ([string]::IsNullOrWhiteSpace($action.state_authority)) { "missing" } else { $action.state_authority }
      verification_mode = if ([string]::IsNullOrWhiteSpace($action.verification_mode)) { "missing" } else { $action.verification_mode }
      current_config_binding = $binding
      expected_effect_domain = if ([string]::IsNullOrWhiteSpace($domain)) { "none" } else { $domain }
      expected_entity_read_class = $expectedEntityClass
      accepted_state_count = $acceptedStateCount
      position_check_configured = [bool]$positionConfigured
      proof_ceiling = if ([string]::IsNullOrWhiteSpace($action.proof_ceiling)) { "none" } else { $action.proof_ceiling }
      live_test_candidate = [bool]$action.live_test_candidate
      live_test_readiness = $liveDecision.readiness
      live_test_blockers = $liveBlockers
      restore_action_id_class = if ([string]::IsNullOrWhiteSpace($action.restore_action_id)) { "none" } else { "configured" }
      stop_action_id_class = if ([string]::IsNullOrWhiteSpace($action.stop_action_id)) { "none" } else { "configured" }
      terminal_action = [bool]$action.terminal_action
      safety_requirements = @($action.safety_requirements)
      authority_candidate = $candidate
      smallest_next_step = $next
    }
  }
  return $rows
}

function ConvertTo-SurfaceRecord {
  param(
    [string]$Domain,
    $DomainSummaries,
    $ServiceMap,
    [string[]]$RelevantServices
  )

  $summary = $DomainSummaries[$Domain]
  $serviceFlags = [ordered]@{}
  foreach ($serviceName in $RelevantServices) {
    $serviceFlags[$serviceName] = Test-ServicePresent -ServiceMap $ServiceMap -Domain $Domain -Service $serviceName
  }

  return [pscustomobject]@{
    domain = $Domain
    entity_count = if ($null -eq $summary) { 0 } else { $summary.entity_count }
    current_position_attr_count = if ($null -eq $summary) { 0 } else { $summary.current_position_attr_count }
    supported_features_attr_count = if ($null -eq $summary) { 0 } else { $summary.supported_features_attr_count }
    battery_attr_count = if ($null -eq $summary) { 0 } else { $summary.battery_attr_count }
    unique_state_value_count = if ($null -eq $summary) { 0 } else { $summary.unique_state_value_count }
    service_flags = [pscustomobject]$serviceFlags
    private_entity_ids = if ($IncludePrivateEntityIds -and $null -ne $summary) { $summary.entity_ids } else { @() }
    private_state_values = if ($IncludePrivateStateValues -and $null -ne $summary) { $summary.state_values } else { @() }
  }
}

$configFilePath = if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
  Resolve-DefaultConfigPath
} else {
  Resolve-RepoRelativePath -Value $ConfigPath -DefaultRelativePath "local\env\home-control.live.yaml"
}
$envFilePath = Resolve-RepoRelativePath -Value $EnvPath -DefaultRelativePath "organs\action\home-assistant-server\.env"

if (-not (Test-Path -LiteralPath $configFilePath -PathType Leaf)) {
  throw "Home Control config not found: $(ConvertTo-DisplayPath -Path $configFilePath)"
}

$config = Read-HomeControlConfig -Path $configFilePath
if ([string]::IsNullOrWhiteSpace($config.home_assistant_base_url)) {
  throw "Home Assistant base URL is missing in Home Control config. Raw path hidden."
}

$tokenEnvName = if ([string]::IsNullOrWhiteSpace($config.home_assistant_token_env)) {
  "HOME_ASSISTANT_TOKEN"
} else {
  $config.home_assistant_token_env
}
$token = [Environment]::GetEnvironmentVariable($tokenEnvName)
if ([string]::IsNullOrWhiteSpace($token)) {
  $token = Read-DotEnvValue -Path $envFilePath -Name $tokenEnvName
}
if ([string]::IsNullOrWhiteSpace($token)) {
  throw "$tokenEnvName is missing for read-only HA inspection; value hidden."
}

$headers = @{ Authorization = "Bearer $token" }
$states = $null
$services = $null
$serviceReadClass = "readable"
try {
  $states = Invoke-HaGet -BaseUrl $config.home_assistant_base_url -Path "/api/states" -Headers $headers -Timeout $TimeoutSeconds
} catch {
  Write-BlockedPayload -ErrorClass (Get-HaReadErrorClass -ErrorRecord $_) -Stage "ha_states_read"
  exit 2
}
try {
  $services = Invoke-HaGet -BaseUrl $config.home_assistant_base_url -Path "/api/services" -Headers $headers -Timeout $TimeoutSeconds
} catch {
  $serviceReadClass = "blocked_" + (Get-HaReadErrorClass -ErrorRecord $_)
  $services = @()
}

$registryClass = "not_attempted"
$switchBotRegistryEntityCount = 0
try {
  $registry = Invoke-HaGet -BaseUrl $config.home_assistant_base_url -Path "/api/config/entity_registry/list" -Headers $headers -Timeout $TimeoutSeconds
  $registryClass = "readable"
  foreach ($item in @($registry)) {
    $platform = [string](Get-ObjectPropertyValue -Object $item -Name "platform" -Default "")
    if ($platform.ToLowerInvariant().Contains("switchbot")) {
      $switchBotRegistryEntityCount += 1
    }
  }
} catch {
  $registryClass = "unavailable_or_not_permitted"
}

$domainSummaries = Get-EntityDomainSummaries -States $states
$serviceMap = Get-ServiceMap -Services $services
$surfaces = @(
  ConvertTo-SurfaceRecord -Domain "cover" -DomainSummaries $domainSummaries -ServiceMap $serviceMap -RelevantServices @("open_cover", "close_cover", "stop_cover", "set_cover_position")
  ConvertTo-SurfaceRecord -Domain "vacuum" -DomainSummaries $domainSummaries -ServiceMap $serviceMap -RelevantServices @("start", "pause", "stop", "return_to_base")
  ConvertTo-SurfaceRecord -Domain "switch" -DomainSummaries $domainSummaries -ServiceMap $serviceMap -RelevantServices @("turn_on", "turn_off", "toggle")
  ConvertTo-SurfaceRecord -Domain "light" -DomainSummaries $domainSummaries -ServiceMap $serviceMap -RelevantServices @("turn_on", "turn_off", "toggle")
  ConvertTo-SurfaceRecord -Domain "fan" -DomainSummaries $domainSummaries -ServiceMap $serviceMap -RelevantServices @("turn_on", "turn_off", "toggle")
)
$actionRows = Get-ActionBindingRows -Config $config -States $states -DomainSummaries $domainSummaries -ServiceMap $serviceMap

$payload = [pscustomobject]@{
  classification = "readonly_switchbot_home_control_surface_inspection"
  config_path_class = ConvertTo-DisplayPath -Path $configFilePath
  env_path_class = if (Test-Path -LiteralPath $envFilePath -PathType Leaf) { ConvertTo-DisplayPath -Path $envFilePath } else { "missing_or_not_needed" }
  ha_readonly_access = "ok"
  ha_services_read_class = $serviceReadClass
  appliance_mutation = "no"
  ha_service_call = "no"
  script_turn_on = "no"
  preview_dry_run_execute = "no"
  raw_private_publication_default = (-not $IncludePrivateEntityIds -and -not $IncludePrivateStateValues)
  entity_registry_class = $registryClass
  switchbot_registry_entity_count = $switchBotRegistryEntityCount
  surfaces = $surfaces
  action_rows = $actionRows
  recommended_next_steps = @(
    "door_curtain: bind exact cover target to current_position thresholds after local direction check; require obstruction and restore preconditions before live movement",
    "vacuum: bind exact vacuum target plus accepted post-action states for start/pause only if HA state labels are stable; require return/stop cleanup and floor/path safety precondition",
    "light: keep as toggle/open-loop unless a real HA state sensor or observation authority is added",
    "fan: accept switch state only if manager/user treats it as physical fan authority; otherwise require observation or sensor"
  )
  does_not_prove = @(
    "physical door obstruction safety",
    "physical vacuum path or floor safety",
    "physical light on/off for toggle devices",
    "physical fan airflow",
    "Home Control pass",
    "final RR003 pass"
  )
}

if ($Json) {
  $payload | ConvertTo-Json -Depth 12
  return
}

Write-Host "Home Control SwitchBot read-only surface inspection"
Write-Host ("classification={0}" -f $payload.classification)
Write-Host "appliance_mutation=no"
Write-Host "ha_service_call=no"
Write-Host "script_turn_on=no"
Write-Host ("ha_services_read_class={0}" -f $payload.ha_services_read_class)
Write-Host ("entity_registry_class={0}; switchbot_registry_entity_count={1}" -f $payload.entity_registry_class, $payload.switchbot_registry_entity_count)
foreach ($surface in $surfaces) {
  $serviceText = @($surface.service_flags.PSObject.Properties | ForEach-Object {
    "{0}={1}" -f $_.Name, ([bool]$_.Value).ToString().ToLowerInvariant()
  }) -join ","
  Write-Host ("surface: domain={0} entity_count={1} current_position_attr_count={2} supported_features_attr_count={3} battery_attr_count={4} unique_state_value_count={5} services={6}" -f $surface.domain, $surface.entity_count, $surface.current_position_attr_count, $surface.supported_features_attr_count, $surface.battery_attr_count, $surface.unique_state_value_count, $serviceText)
  if ($IncludePrivateEntityIds -and $surface.private_entity_ids.Count -gt 0) {
    Write-Host ("  private_entity_ids={0}" -f (@($surface.private_entity_ids) -join ","))
  }
  if ($IncludePrivateStateValues -and $surface.private_state_values.Count -gt 0) {
    Write-Host ("  private_state_values={0}" -f (@($surface.private_state_values) -join ","))
  }
}
foreach ($row in $actionRows) {
  $liveBlockersText = if (@($row.live_test_blockers).Count -eq 0) { "none" } else { @($row.live_test_blockers) -join "," }
  $safetyRequirementsText = if (@($row.safety_requirements).Count -eq 0) { "none" } else { @($row.safety_requirements) -join "," }
  Write-Host ("row: action_id={0} control_type={1} state_authority={2} verification_mode={3} binding={4} expected_domain={5} expected_entity_read_class={6} accepted_state_count={7} position_check_configured={8} proof_ceiling={9} live_test_candidate={10} live_test_readiness={11} live_test_blockers={12} restore_action={13} stop_action={14} terminal_action={15} safety_requirements={16} authority_candidate={17}" -f $row.action_id, $row.control_type, $row.state_authority, $row.verification_mode, $row.current_config_binding, $row.expected_effect_domain, $row.expected_entity_read_class, $row.accepted_state_count, ([bool]$row.position_check_configured).ToString().ToLowerInvariant(), $row.proof_ceiling, ([bool]$row.live_test_candidate).ToString().ToLowerInvariant(), $row.live_test_readiness, $liveBlockersText, $row.restore_action_id_class, $row.stop_action_id_class, ([bool]$row.terminal_action).ToString().ToLowerInvariant(), $safetyRequirementsText, $row.authority_candidate)
  Write-Host ("  next={0}" -f $row.smallest_next_step)
}
Write-Host ("raw_private_publication_default={0}" -f ([bool]$payload.raw_private_publication_default).ToString().ToLowerInvariant())
Write-Host "does_not_prove=physical_door_obstruction_safety;physical_vacuum_path_floor_safety;physical_light_toggle_on_off;physical_fan_airflow;Home_Control_pass;final_RR003_pass"
