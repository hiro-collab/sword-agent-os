$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Get-FileDigestClass {
  param([Parameter(Mandatory = $true)][string]$Path)
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    return "missing"
  }
  $hash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
  return "sha256_16:$($hash.Substring(0, 16))"
}

function Get-EnvValueClass {
  param(
    [AllowNull()][string]$Value,
    [bool]$Found = $true
  )
  if (-not $Found) {
    return "absent"
  }
  if ([string]::IsNullOrWhiteSpace($Value)) {
    return "empty"
  }
  $normalized = $Value.Trim().Trim('"').Trim("'").ToLowerInvariant()
  if ($normalized -in @("0", "false", "no", "off", "disabled")) {
    return "disabled_literal"
  }
  if ($normalized -in @("1", "true", "yes", "on", "enabled")) {
    return "enabled_literal"
  }
  if ($normalized.Contains("<") -or $normalized.Contains(">")) {
    return "placeholder_like"
  }
  return "present_redacted"
}

function New-ClassMapFromNames {
  param([Parameter(Mandatory = $true)][string[]]$Names)
  $map = [ordered]@{}
  foreach ($name in $Names) {
    $map[$name] = "absent"
  }
  return $map
}

function Read-ProcessEnvClassMap {
  param([Parameter(Mandatory = $true)][string[]]$Names)
  $classes = New-ClassMapFromNames -Names $Names
  foreach ($name in $Names) {
    $value = [Environment]::GetEnvironmentVariable($name, "Process")
    $classes[$name] = Get-EnvValueClass -Value $value -Found (-not [string]::IsNullOrWhiteSpace($value))
  }
  return [PSCustomObject]$classes
}

function Read-DotEnvClassMap {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string[]]$Names
  )
  $classes = New-ClassMapFromNames -Names $Names
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    return [PSCustomObject]@{
      file_class = "missing"
      values = [PSCustomObject]$classes
    }
  }
  foreach ($line in Get-Content -LiteralPath $Path) {
    $trimmed = $line.Trim()
    if ($trimmed.Length -eq 0 -or $trimmed.StartsWith("#")) {
      continue
    }
    if ($trimmed.StartsWith("export ")) {
      $trimmed = $trimmed.Substring(7).Trim()
    }
    $separator = $trimmed.IndexOf("=")
    if ($separator -lt 1) {
      continue
    }
    $key = $trimmed.Substring(0, $separator).Trim()
    if ($key -notin $Names) {
      continue
    }
    $value = $trimmed.Substring($separator + 1).Trim()
    if (
      ($value.StartsWith('"') -and $value.EndsWith('"')) -or
      ($value.StartsWith("'") -and $value.EndsWith("'"))
    ) {
      $value = $value.Substring(1, $value.Length - 2)
    }
    $classes[$key] = Get-EnvValueClass -Value $value -Found $true
  }
  return [PSCustomObject]@{
    file_class = "present"
    values = [PSCustomObject]$classes
  }
}

function Get-ClassProperty {
  param(
    [Parameter(Mandatory = $true)]$Object,
    [Parameter(Mandatory = $true)][string]$Name
  )
  $property = $Object.PSObject.Properties[$Name]
  if ($null -eq $property) {
    return "absent"
  }
  return [string]$property.Value
}

function Resolve-LaunchManagerInjectedEnvClass {
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)]$ProcessClasses,
    [Parameter(Mandatory = $true)]$ThoughtCoreServiceEnvClasses
  )
  $processClass = Get-ClassProperty -Object $ProcessClasses -Name $Name
  if ($processClass -ne "absent" -and $processClass -ne "empty") {
    return $processClass
  }
  return Get-ClassProperty -Object $ThoughtCoreServiceEnvClasses.values -Name $Name
}

function Resolve-StartScriptImportedEnvClass {
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)]$LaunchManagerClasses,
    [Parameter(Mandatory = $true)]$ControlPlaneEnvClasses
  )
  $controlPlaneClass = Get-ClassProperty -Object $ControlPlaneEnvClasses.values -Name $Name
  if ($controlPlaneClass -ne "absent") {
    return $controlPlaneClass
  }
  return Get-ClassProperty -Object $LaunchManagerClasses -Name $Name
}

function New-NoProviderChildProvenanceDiagnostics {
  param(
    [Parameter(Mandatory = $true)]$Profile,
    [Parameter(Mandatory = $true)]$ServiceManifest,
    [Parameter(Mandatory = $true)][hashtable]$PidMap,
    [Parameter(Mandatory = $true)][string]$Workspace,
    [Parameter(Mandatory = $true)][string]$StackState,
    [Parameter(Mandatory = $true)][bool]$ManifestOnlyMode
  )

  $trackedNames = @(
    "THOUGHT_CORE_LLM_ENABLED",
    "THOUGHT_CORE_ACTION_LLM_ENABLED",
    "THOUGHT_CORE_LLM_BASE_URL",
    "THOUGHT_CORE_LLM_PROVIDER",
    "THOUGHT_CORE_LLM_TIMEOUT_S",
    "THOUGHT_CORE_LLM_API_KEY",
    "THOUGHT_CORE_LLM_MODEL",
    "OPENAI_BASE_URL",
    "OPENAI_API_KEY",
    "OPENAI_MODEL"
  )
  $processClasses = Read-ProcessEnvClassMap -Names $trackedNames
  $centralEnvClasses = Read-DotEnvClassMap -Path (Join-Path $Workspace "local\env\sword-agent-os.env") -Names $trackedNames
  $controlPlaneEnvClasses = Read-DotEnvClassMap -Path (Join-Path $Workspace "control-plane\core\.env") -Names $trackedNames
  $thoughtCoreServiceEnvClasses = Read-DotEnvClassMap -Path (Join-Path $Workspace "control-plane\core\services\thought-core\.env") -Names $trackedNames

  $launchManagerClasses = [ordered]@{}
  $startScriptClasses = [ordered]@{}
  foreach ($name in $trackedNames) {
    $launchManagerClasses[$name] = Resolve-LaunchManagerInjectedEnvClass `
      -Name $name `
      -ProcessClasses $processClasses `
      -ThoughtCoreServiceEnvClasses $thoughtCoreServiceEnvClasses
  }
  $launchManagerClassesObject = [PSCustomObject]$launchManagerClasses
  foreach ($name in $trackedNames) {
    $startScriptClasses[$name] = Resolve-StartScriptImportedEnvClass `
      -Name $name `
      -LaunchManagerClasses $launchManagerClassesObject `
      -ControlPlaneEnvClasses $controlPlaneEnvClasses
  }
  $startScriptClassesObject = [PSCustomObject]$startScriptClasses

  $pidEntry = $null
  if ($PidMap.ContainsKey("openai_provider_broker")) {
    $pidEntry = $PidMap["openai_provider_broker"]
  }
  elseif ($PidMap.ContainsKey("thought_core_api")) {
    $pidEntry = $PidMap["thought_core_api"]
  }
  $childClass = "no_recorded_child_process"
  $staleClass = "no_registry_entry"
  $pidRegistryFileClass = if (Test-Path -LiteralPath (Join-Path $StackState "pids.json") -PathType Leaf) { "present" } else { "missing" }
  if ($null -ne $pidEntry) {
    if (Test-ProcessEntryAlive -Entry $pidEntry) {
      $childClass = "recorded_child_alive_by_pid_registry"
      $staleClass = "start_time_matches_recorded_pid"
    }
    else {
      $childClass = "recorded_child_not_alive_or_stale"
      $staleClass = "recorded_pid_missing_or_start_time_mismatch"
    }
  }

  $providerConfigPresence = if (
    (Get-ClassProperty -Object $startScriptClassesObject -Name "THOUGHT_CORE_LLM_API_KEY") -ne "absent" -or
    (Get-ClassProperty -Object $startScriptClassesObject -Name "OPENAI_API_KEY") -ne "absent" -or
    (Get-ClassProperty -Object $startScriptClassesObject -Name "THOUGHT_CORE_LLM_BASE_URL") -ne "absent" -or
    (Get-ClassProperty -Object $startScriptClassesObject -Name "OPENAI_BASE_URL") -ne "absent"
  ) {
    "present_redacted"
  }
  else {
    "absent"
  }

  $llmLaunchClass = Get-ClassProperty -Object $launchManagerClassesObject -Name "THOUGHT_CORE_LLM_ENABLED"
  $llmStartScriptClass = Get-ClassProperty -Object $startScriptClassesObject -Name "THOUGHT_CORE_LLM_ENABLED"
  $llmOverrideClass = if ($llmLaunchClass -eq "absent" -and $llmStartScriptClass -eq "absent") {
    "no_binding_seen"
  }
  elseif ($llmLaunchClass -ne $llmStartScriptClass) {
    "start_script_env_import_changes_class"
  }
  else {
    "same_class_or_single_source"
  }

  $sourceRoot = Join-Path $Workspace "control-plane\core\services\thought-core\src\thought_core"
  $inputUnderstandingPath = Join-Path $sourceRoot "input_understanding.py"
  $loopPath = Join-Path $sourceRoot "loop.py"
  $serverPath = Join-Path $sourceRoot "server.py"
  $standardBrokerPort = [int]$ServiceManifest.port_modes.manifest_default.service_ports.openai_provider_broker
  $isolatedBrokerPort = [int]$ServiceManifest.port_modes.isolated_override.service_ports.openai_provider_broker

  return [PSCustomObject]@{
    schema_version = "no_provider_child_provenance_diagnostics.v0"
    proof_layer = "source-no-live"
    selected_profile_id = [string]$Profile.id
    service_manifest_id = [string]$ServiceManifest.id
    manifest_only = $ManifestOnlyMode
    pid_registry_file_class = $pidRegistryFileClass
    child_process_identity_class = $childClass
    stale_or_reused_process_class = $staleClass
    env_binding = [PSCustomObject]@{
      launch_manager_injected_classes = $launchManagerClassesObject
      start_script_imported_classes = $startScriptClassesObject
      final_child_effective_class = "not_observed_without_child_env_snapshot"
      thought_core_llm_enabled_class = $llmStartScriptClass
      thought_core_action_llm_enabled_class = Get-ClassProperty -Object $startScriptClassesObject -Name "THOUGHT_CORE_ACTION_LLM_ENABLED"
      provider_config_presence_class = $providerConfigPresence
      start_script_env_override_class = $llmOverrideClass
      env_source_file_classes = [PSCustomObject]@{
        central_env = $centralEnvClasses.file_class
        control_plane_env = $controlPlaneEnvClasses.file_class
        thought_core_service_env = $thoughtCoreServiceEnvClasses.file_class
      }
    }
    provider_boundary = [PSCustomObject]@{
      broker_secret_source_class = "thought-core-existing-env-v1"
      broker_credential_owner_class = "openai_provider_broker_only"
      broker_standard_port = $standardBrokerPort
      broker_isolated_port = $isolatedBrokerPort
      thought_core_credential_class = "credential_free"
      no_provider_binding_runtime_proven = $false
      provider_bearing_runtime_scope_allowed = $false
    }
    source_static = [PSCustomObject]@{
      input_understanding_hash_class = Get-FileDigestClass -Path $inputUnderstandingPath
      loop_hash_class = Get-FileDigestClass -Path $loopPath
      server_hash_class = Get-FileDigestClass -Path $serverPath
      source_static_is_runtime_import_proof = $false
      runtime_import_provenance_class = "not_observed_without_child_import_snapshot"
    }
    payload_preflight = [PSCustomObject]@{
      required_payload_class = "happy_expression_motion_request"
      payload_marker_class = "missing_status_surface"
      payload_marker_hash_class = "missing_status_surface"
      top_level_marker_class_evidence = "not_observed"
      raw_payload_included = $false
    }
    safety = [PSCustomObject]@{
      raw_input_included = $false
      raw_response_included = $false
      provider_payload_included = $false
      env_values_included = $false
      private_paths_included = $false
      runtime_turn_performed = $false
      provider_call_performed = $false
    }
    does_not_prove = @(
      "final_child_no_provider_binding",
      "running_import_path",
      "motion_request_mapping_runtime_pass",
      "provider_absence_during_turn",
      "whole_system_pass",
      "review_ready"
    )
  }
}
