param(
  [string]$ProfilePath = "manifests/profiles/thought-core-v0-compat.json",
  [string]$WorkspaceRoot = "",
  [switch]$CheckEndpoints,
  [switch]$SkipPortChecks,
  [int]$HomeAssistantBridgePort = 8787,
  [int]$EnvironmentStatePort = 8790,
  [int]$MediapipePort = 8765,
  [int]$MediapipeBrowserMonitorPort = 8770,
  [int]$VisionSnapshotProcessorPort = 8776,
  [int]$AituberPort = 3000,
  [int]$TouchDesignerGuiPort = 8788,
  [int]$ThoughtCorePort = 18787,
  [switch]$UseIsolatedPorts,
  [int]$TimeoutMs = 1200
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$RepoRoot = Split-Path -Parent $PSScriptRoot
$LaunchBoundParameters = @{} + $PSBoundParameters

function Resolve-RepoPath {
  param([Parameter(Mandatory = $true)][string]$Path)
  if ([System.IO.Path]::IsPathRooted($Path)) {
    return $Path
  }
  return Join-Path $RepoRoot ($Path -replace "/", [System.IO.Path]::DirectorySeparatorChar)
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

function Resolve-WorkspacePath {
  param([Parameter(Mandatory = $true)][string]$Path)
  if ([System.IO.Path]::IsPathRooted($Path)) {
    return $Path
  }
  return Join-Path $workspace ($Path -replace "/", [System.IO.Path]::DirectorySeparatorChar)
}

function Read-Json {
  param([Parameter(Mandatory = $true)][string]$Path)
  return Get-Content -Raw -LiteralPath (Resolve-RepoPath $Path) | ConvertFrom-Json
}

function Read-DotEnvValue {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$Name
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
    if ($value.Length -ge 2) {
      $quote = $value.Substring(0, 1)
      if (($quote -eq '"' -or $quote -eq "'") -and $value.EndsWith($quote)) {
        return $value.Substring(1, $value.Length - 2)
      }
    }
    return $value
  }
  return ""
}

function Read-DotEnvFirstValue {
  param(
    [Parameter(Mandatory = $true)][string[]]$Paths,
    [Parameter(Mandatory = $true)][string]$Name
  )
  foreach ($path in $Paths) {
    $value = Read-DotEnvValue -Path $path -Name $Name
    if (-not [string]::IsNullOrWhiteSpace($value)) {
      return $value
    }
  }
  return ""
}

function Normalize-DotEnvEnumValue {
  param([string]$Value)
  $normalized = $Value.Trim()
  $commentIndex = $normalized.IndexOf(" #", [System.StringComparison]::Ordinal)
  if ($commentIndex -ge 0) {
    $normalized = $normalized.Substring(0, $commentIndex).Trim()
  }
  return $normalized.Trim().Trim('"').Trim("'")
}

function Test-PlaceholderSecretValue {
  param([AllowNull()][string]$Value)
  if ([string]::IsNullOrWhiteSpace($Value)) {
    return $false
  }
  $normalized = $Value.Trim().Trim('"').Trim("'").ToLowerInvariant()
  $exactPlaceholders = @(
    "changeme",
    "change-me",
    "test-token",
    "example-token",
    "dummy-token",
    "change-me-local-bridge-token",
    "change-me-home-assistant-token"
  )
  if ($normalized -in $exactPlaceholders) {
    return $true
  }
  foreach ($prefix in @("change-me", "replace", "example", "dummy", "your-")) {
    if ($normalized.StartsWith($prefix, [System.StringComparison]::Ordinal)) {
      return $true
    }
  }
  return $false
}

function Test-FileSameContent {
  param(
    [Parameter(Mandatory = $true)][string]$Left,
    [Parameter(Mandatory = $true)][string]$Right
  )
  if (-not (Test-Path -LiteralPath $Left -PathType Leaf)) {
    return $false
  }
  if (-not (Test-Path -LiteralPath $Right -PathType Leaf)) {
    return $false
  }
  $leftHash = (Get-FileHash -LiteralPath $Left -Algorithm SHA256).Hash
  $rightHash = (Get-FileHash -LiteralPath $Right -Algorithm SHA256).Hash
  return $leftHash -eq $rightHash
}

function Get-PortModePorts {
  param(
    [Parameter(Mandatory = $true)]$ServiceManifest,
    [Parameter(Mandatory = $true)][string]$ModeName
  )
  $modeProperty = $ServiceManifest.port_modes.PSObject.Properties[$ModeName]
  if ($null -eq $modeProperty) {
    throw "service manifest missing port mode: $ModeName"
  }
  $mode = $modeProperty.Value
  $ports = @{}
  foreach ($property in $mode.service_ports.PSObject.Properties) {
    $ports[$property.Name] = [int]$property.Value
  }
  foreach ($property in $mode.auxiliary_ports.PSObject.Properties) {
    $ports[$property.Name] = [int]$property.Value
  }
  return $ports
}

function Set-PortIfUnbound {
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][int]$Value
  )
  if (-not $LaunchBoundParameters.ContainsKey($Name)) {
    Set-Variable -Scope Script -Name $Name -Value $Value
  }
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

function New-Check {
  param(
    [Parameter(Mandatory = $true)][string]$Id,
    [Parameter(Mandatory = $true)][string]$Status,
    [Parameter(Mandatory = $true)][string]$Detail,
    [string]$Path = "",
    [string]$Severity = "info"
  )
  return [PSCustomObject]@{
    id = $Id
    status = $Status
    severity = $Severity
    path = $Path
    detail = $Detail
  }
}

function Test-Tool {
  param([Parameter(Mandatory = $true)][string]$Name)
  $command = Get-Command $Name -ErrorAction SilentlyContinue
  if ($null -eq $command -and $Name -eq "npm") {
    $command = Get-Command "npm.cmd" -ErrorAction SilentlyContinue
  }
  if ($null -eq $command) {
    return New-Check -Id "tool.$Name" -Status "missing" -Severity "blocker" -Detail "tool not found on PATH"
  }
  return New-Check -Id "tool.$Name" -Status "ok" -Severity "info" -Path ([string]$command.Source) -Detail "tool found"
}

function Test-PathCheck {
  param(
    [Parameter(Mandatory = $true)][string]$Id,
    [Parameter(Mandatory = $true)][string]$Path,
    [string]$MissingSeverity = "blocker",
    [string]$OkDetail = "path exists",
    [string]$MissingDetail = "path missing"
  )
  if (Test-Path -LiteralPath $Path) {
    return New-Check -Id $Id -Status "ok" -Severity "info" -Path $Path -Detail $OkDetail
  }
  return New-Check -Id $Id -Status "missing" -Severity $MissingSeverity -Path $Path -Detail $MissingDetail
}

function Add-GeneratedEnvSyncCheck {
  param(
    [Parameter(Mandatory = $true)][string]$Id,
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][string]$CentralPath,
    [Parameter(Mandatory = $true)][string]$GeneratedPath
  )
  $centralValue = Read-DotEnvValue -Path $CentralPath -Name $Name
  $generatedValue = Read-DotEnvValue -Path $GeneratedPath -Name $Name
  if (Test-PlaceholderSecretValue -Value $generatedValue) {
    return New-Check `
      -Id $Id `
      -Status "placeholder" `
      -Severity "warning" `
      -Path $GeneratedPath `
      -Detail "$Name in generated organ .env still looks like a template value; update local/env/sword-agent-os.env and rerun scripts/render-env-files.ps1 -Profile standard -Force"
  }
  if ([string]::IsNullOrWhiteSpace($centralValue)) {
    return New-Check `
      -Id $Id `
      -Status "skipped" `
      -Severity "info" `
      -Path $CentralPath `
      -Detail "$Name is not set in central env"
  }
  if ([string]::IsNullOrWhiteSpace($generatedValue)) {
    return New-Check `
      -Id $Id `
      -Status "missing" `
      -Severity "warning" `
      -Path $GeneratedPath `
      -Detail "$Name is set in central env but missing in generated organ .env; rerun scripts/render-env-files.ps1 -Profile standard -Force"
  }
  if ($centralValue -ne $generatedValue) {
    return New-Check `
      -Id $Id `
      -Status "mismatch" `
      -Severity "warning" `
      -Path $GeneratedPath `
      -Detail "$Name differs between central env and generated organ .env; rerun scripts/render-env-files.ps1 -Profile standard -Force or reconcile local overrides"
  }
  return New-Check -Id $Id -Status "ok" -Severity "info" -Path $GeneratedPath -Detail "$Name matches central env"
}

function Test-HttpEndpoint {
  param(
    [Parameter(Mandatory = $true)][string]$Id,
    [Parameter(Mandatory = $true)][string]$Url
  )
  if (-not $CheckEndpoints) {
    return New-Check -Id $Id -Status "skipped" -Severity "info" -Path $Url -Detail "endpoint check skipped"
  }
  try {
    $timeoutSeconds = [Math]::Max(1, [int][Math]::Ceiling($TimeoutMs / 1000))
    $response = Invoke-WebRequest -Uri $Url -Method Get -TimeoutSec $timeoutSeconds -UseBasicParsing
    return New-Check -Id $Id -Status "ok" -Severity "info" -Path $Url -Detail "http $($response.StatusCode)"
  }
  catch {
    return New-Check -Id $Id -Status "missing" -Severity "warning" -Path $Url -Detail $_.Exception.Message
  }
}

function Test-LaunchPort {
  param(
    [Parameter(Mandatory = $true)][string]$Id,
    [Parameter(Mandatory = $true)][int]$Port
  )
  if ($SkipPortChecks) {
    return New-Check -Id $Id -Status "skipped" -Severity "info" -Path ([string]$Port) -Detail "port check skipped"
  }
  $listeners = @(Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue)
  if ($listeners.Count -eq 0) {
    return New-Check -Id $Id -Status "ok" -Severity "info" -Path ([string]$Port) -Detail "port available"
  }
  $ownerPid = [int]($listeners | Select-Object -First 1).OwningProcess
  $process = Get-Process -Id $ownerPid -ErrorAction SilentlyContinue
  $processName = if ($null -ne $process) { [string]$process.ProcessName } else { "unknown" }
  return New-Check -Id $Id -Status "in-use" -Severity "blocker" -Path ([string]$Port) -Detail "port is already used by pid $ownerPid $processName"
}

$workspace = Resolve-WorkspaceRoot -Path $WorkspaceRoot
$profile = Read-Json -Path $ProfilePath
$serviceManifest = Read-Json -Path ([string]$profile.service_manifest)

if ($UseIsolatedPorts) {
  $isolatedPorts = Get-PortModePorts -ServiceManifest $serviceManifest -ModeName "isolated_override"
  Set-PortIfUnbound -Name "HomeAssistantBridgePort" -Value $isolatedPorts["home_assistant_bridge"]
  Set-PortIfUnbound -Name "EnvironmentStatePort" -Value $isolatedPorts["environment_state_server"]
  Set-PortIfUnbound -Name "MediapipePort" -Value $isolatedPorts["mediapipe_camera_hub_stack"]
  Set-PortIfUnbound -Name "MediapipeBrowserMonitorPort" -Value $isolatedPorts["mediapipe_browser_monitor"]
  Set-PortIfUnbound -Name "VisionSnapshotProcessorPort" -Value $isolatedPorts["vision_snapshot_processor"]
  Set-PortIfUnbound -Name "AituberPort" -Value $isolatedPorts["aituber_kit"]
  Set-PortIfUnbound -Name "TouchDesignerGuiPort" -Value $isolatedPorts["touchdesigner_control_gui"]
  Set-PortIfUnbound -Name "ThoughtCorePort" -Value $isolatedPorts["thought_core_api"]
}

$checks = @()

foreach ($service in $serviceManifest.services) {
  $targetPath = [string](Get-OptionalProperty -Object $service -Name "target_path" -Default "")
  if (-not [string]::IsNullOrWhiteSpace($targetPath)) {
    $checks += Test-PathCheck `
      -Id "service_target.$($service.service_id)" `
      -Path (Resolve-WorkspacePath $targetPath) `
      -MissingSeverity "blocker" `
      -OkDetail "service target available" `
      -MissingDetail "service target missing"
  }
}

$checks += Test-Tool -Name "git"
$checks += Test-Tool -Name "uv"
$checks += Test-Tool -Name "node"
$checks += Test-Tool -Name "npm"

$checks += Test-LaunchPort -Id "port.home_assistant_bridge" -Port $HomeAssistantBridgePort
$checks += Test-LaunchPort -Id "port.environment_state_server" -Port $EnvironmentStatePort
$checks += Test-LaunchPort -Id "port.thought_core_api" -Port $ThoughtCorePort
$checks += Test-LaunchPort -Id "port.mediapipe_camera_hub_stack" -Port $MediapipePort
$checks += Test-LaunchPort -Id "port.mediapipe_browser_monitor" -Port $MediapipeBrowserMonitorPort
$checks += Test-LaunchPort -Id "port.vision_snapshot_processor" -Port $VisionSnapshotProcessorPort
$checks += Test-LaunchPort -Id "port.aituber_kit" -Port $AituberPort
$checks += Test-LaunchPort -Id "port.touchdesigner_control_gui" -Port $TouchDesignerGuiPort

$homeAssistantRoot = Resolve-WorkspacePath "organs/action/home-assistant-server"
$aituberRoot = Resolve-WorkspacePath "organs/expression/aituber-kit"
$touchDesignerRoot = Resolve-WorkspacePath "organs/display/touchdesigner-ai-controller"
$mediapipeRoot = Resolve-WorkspacePath "organs/reflex/mediapipe-sword-sign"
$controlPlaneRoot = Resolve-WorkspacePath "control-plane/sword-voice-agent"
$speechInputRoot = Resolve-WorkspacePath "organs/speech-input/ai-talk-core"
$centralEnvPath = Resolve-WorkspacePath "local/env/sword-agent-os.env"
$controlPlaneEnvPath = Join-Path $controlPlaneRoot ".env"
$thoughtCoreEnvPath = Join-Path $controlPlaneRoot "services\thought-core\.env"
$homeAssistantEnvPath = Join-Path $homeAssistantRoot ".env"
$homeControlConfigPath = Join-Path $homeAssistantRoot "config\home-control.yaml"
$homeControlExamplePath = Join-Path $homeAssistantRoot "config\home-control.example.yaml"
$aituberEnvPath = Join-Path $aituberRoot ".env"

$checks += Test-PathCheck -Id "local.home_control_config" -Path $homeControlConfigPath -MissingSeverity "blocker" -MissingDetail "Home Assistant action config is local-only"
$checks += Test-PathCheck -Id "local.home_assistant_env" -Path $homeAssistantEnvPath -MissingSeverity "blocker" -MissingDetail "Home Assistant token env is local-only"
$checks += Test-PathCheck -Id "local.control_plane_env" -Path $controlPlaneEnvPath -MissingSeverity "warning" -MissingDetail "control-plane env is local-only"
$checks += Test-PathCheck -Id "local.aituber_env" -Path $aituberEnvPath -MissingSeverity "warning" -MissingDetail "AITuber env is local-only"
$checks += Test-PathCheck -Id "local.touchdesigner_server" -Path (Join-Path $touchDesignerRoot "tools\server.js") -MissingSeverity "blocker" -MissingDetail "Display runtime GUI server entry missing"
$checks += Test-PathCheck -Id "local.mediapipe_camera_hub_launcher" -Path (Join-Path $mediapipeRoot "scripts\start_camera_hub_stack.bat") -MissingSeverity "blocker" -MissingDetail "MediaPipe camera hub launcher missing"
$checks += Test-PathCheck -Id "local.mediapipe_gesture_model" -Path (Join-Path $mediapipeRoot "gesture_model.pkl") -MissingSeverity "blocker" -MissingDetail "gesture_model.pkl is local-only and required for Camera Hub gesture classification. If you already have the model, place it at organs/reflex/mediapipe-sword-sign/gesture_model.pkl. If you do not have it yet, keep camera/gesture readiness and runtime proof separate from device-free source/static or no-live setup; without it startup can fail with model_not_found and Camera Hub topics timeout."

$envReadPaths = @($centralEnvPath, $controlPlaneEnvPath, $thoughtCoreEnvPath, $homeAssistantEnvPath)
$toolsAdapter = (Normalize-DotEnvEnumValue -Value (Read-DotEnvFirstValue -Paths $envReadPaths -Name "THOUGHT_CORE_TOOLS_ADAPTER")).ToLowerInvariant()
$homeAssistantToken = Read-DotEnvFirstValue -Paths @($centralEnvPath, $homeAssistantEnvPath) -Name "HOME_ASSISTANT_TOKEN"
if ([string]::IsNullOrWhiteSpace($toolsAdapter)) {
  $checks += New-Check -Id "local.thought_core_tools_adapter" -Status "missing" -Severity "warning" -Path $centralEnvPath -Detail "THOUGHT_CORE_TOOLS_ADAPTER is not set; Thought Core may fall back to mock/no-live behavior"
}
elseif ($toolsAdapter -in @("mock", "local_mock", "local-mock")) {
  $detail = "THOUGHT_CORE_TOOLS_ADAPTER=mock: home actions are no-live simulations and are not sent to real Home Assistant"
  $severity = "info"
  if (-not [string]::IsNullOrWhiteSpace($homeAssistantToken)) {
    $detail = "$detail, even though HOME_ASSISTANT_TOKEN is present"
    $severity = "warning"
  }
  $checks += New-Check -Id "local.thought_core_tools_adapter" -Status "mock" -Severity $severity -Path $centralEnvPath -Detail $detail
}
elseif ($toolsAdapter -in @("home_control", "home-control", "bridge")) {
  $checks += New-Check -Id "local.thought_core_tools_adapter" -Status "ok" -Severity "info" -Path $centralEnvPath -Detail "Thought Core home actions are configured for the local Home Control bridge"
}
else {
  $checks += New-Check -Id "local.thought_core_tools_adapter" -Status "unknown" -Severity "warning" -Path $centralEnvPath -Detail "Unknown THOUGHT_CORE_TOOLS_ADAPTER value; expected mock or home_control"
}

$checks += Add-GeneratedEnvSyncCheck -Id "local.home_control_api_token_sync" -Name "HOME_CONTROL_API_TOKEN" -CentralPath $centralEnvPath -GeneratedPath $homeAssistantEnvPath
$checks += Add-GeneratedEnvSyncCheck -Id "local.environment_api_token_sync" -Name "ENVIRONMENT_API_TOKEN" -CentralPath $centralEnvPath -GeneratedPath $homeAssistantEnvPath
$checks += Add-GeneratedEnvSyncCheck -Id "local.home_assistant_token_sync" -Name "HOME_ASSISTANT_TOKEN" -CentralPath $centralEnvPath -GeneratedPath $homeAssistantEnvPath

if ($toolsAdapter -in @("home_control", "home-control", "bridge")) {
  if (Test-FileSameContent -Left $homeControlConfigPath -Right $homeControlExamplePath) {
    $checks += New-Check `
      -Id "local.home_control_config_customized" `
      -Status "example" `
      -Severity "warning" `
      -Path $homeControlConfigPath `
      -Detail "Home Control config still matches the example demo mapping; replace Home Assistant base_url, scripts, and expected_effect entity IDs before expecting live appliance state in Environment State"
  }
  elseif (Test-Path -LiteralPath $homeControlConfigPath -PathType Leaf) {
    $checks += New-Check -Id "local.home_control_config_customized" -Status "ok" -Severity "info" -Path $homeControlConfigPath -Detail "Home Control config differs from the public example"
  }
}

$vrmFiles = @()
$vrmRoot = Join-Path $aituberRoot "public\vrm"
if (Test-Path -LiteralPath $vrmRoot -PathType Container) {
  $vrmFiles = @(Get-ChildItem -LiteralPath $vrmRoot -Filter "*.vrm" -File -ErrorAction SilentlyContinue)
}
if ($vrmFiles.Count -gt 0) {
  $checks += New-Check -Id "local.vrm_assets" -Status "ok" -Severity "info" -Path $vrmRoot -Detail "$($vrmFiles.Count) VRM asset(s)"
}
else {
  $checks += New-Check -Id "local.vrm_assets" -Status "missing" -Severity "warning" -Path $vrmRoot -Detail "VRM assets are local-only; place licensed .vrm files under organs/expression/aituber-kit/public/vrm and set NEXT_PUBLIC_SELECTED_VRM_PATH for avatar rendering"
}
if (Test-Path -LiteralPath $aituberEnvPath -PathType Leaf) {
  $selectedVrmPath = Read-DotEnvValue -Path $aituberEnvPath -Name "NEXT_PUBLIC_SELECTED_VRM_PATH"
  if ([string]::IsNullOrWhiteSpace($selectedVrmPath)) {
    $checks += New-Check -Id "local.vrm_selected_path" -Status "missing" -Severity "warning" -Path $aituberEnvPath -Detail "NEXT_PUBLIC_SELECTED_VRM_PATH is not set; avatar rendering may fall back to the app default or fail to select a model"
  }
  elseif (-not $selectedVrmPath.StartsWith("/vrm/")) {
    $checks += New-Check -Id "local.vrm_selected_path" -Status "invalid" -Severity "warning" -Path $aituberEnvPath -Detail "NEXT_PUBLIC_SELECTED_VRM_PATH should usually be /vrm/<file>.vrm for assets under organs/expression/aituber-kit/public/vrm"
  }
  else {
    $selectedVrmRelative = $selectedVrmPath.Substring("/vrm/".Length) -replace "/", [System.IO.Path]::DirectorySeparatorChar
    $vrmRootFullPath = [System.IO.Path]::GetFullPath((Join-Path $vrmRoot "."))
    $selectedVrmFullPath = [System.IO.Path]::GetFullPath((Join-Path $vrmRoot $selectedVrmRelative))
    if (-not $selectedVrmFullPath.StartsWith($vrmRootFullPath, [System.StringComparison]::OrdinalIgnoreCase)) {
      $checks += New-Check -Id "local.vrm_selected_model" -Status "invalid" -Severity "warning" -Path $aituberEnvPath -Detail "NEXT_PUBLIC_SELECTED_VRM_PATH must resolve under organs/expression/aituber-kit/public/vrm"
    }
    elseif (Test-Path -LiteralPath $selectedVrmFullPath -PathType Leaf) {
      $checks += New-Check -Id "local.vrm_selected_model" -Status "ok" -Severity "info" -Path $selectedVrmFullPath -Detail "selected VRM asset exists"
    }
    else {
      $checks += New-Check -Id "local.vrm_selected_model" -Status "missing" -Severity "warning" -Path $selectedVrmFullPath -Detail "NEXT_PUBLIC_SELECTED_VRM_PATH=$selectedVrmPath does not resolve to a local file; place the licensed .vrm under organs/expression/aituber-kit/public/vrm or update NEXT_PUBLIC_SELECTED_VRM_PATH"
    }
  }
}

$legacyControlPlaneAlias = Join-Path $workspace "sword-control-plane"
$legacyAiTalkCoreAlias = Join-Path $workspace "organs\voice\ai-talk-core"
if (Test-Path -LiteralPath $controlPlaneRoot -PathType Container) {
  $checks += New-Check -Id "native_delegate_layout.control_plane" -Status "ok" -Severity "info" -Path $controlPlaneRoot -Detail "native control-plane layout available"
}
else {
  $checks += Test-PathCheck `
    -Id "legacy_delegate_layout.sword_control_plane_alias" `
    -Path $legacyControlPlaneAlias `
    -MissingSeverity "warning" `
    -OkDetail "native control-plane path missing; legacy alias fallback available" `
    -MissingDetail "native control-plane path missing; legacy alias fallback also missing"
}
if (Test-Path -LiteralPath $speechInputRoot -PathType Container) {
  $checks += New-Check -Id "native_delegate_layout.ai_talk_core" -Status "ok" -Severity "info" -Path $speechInputRoot -Detail "native speech-input layout available"
}
else {
  $checks += Test-PathCheck `
    -Id "legacy_delegate_layout.ai_talk_core_voice_alias" `
    -Path $legacyAiTalkCoreAlias `
    -MissingSeverity "warning" `
    -OkDetail "native speech-input path missing; legacy voice alias fallback available" `
    -MissingDetail "native speech-input path missing; legacy voice alias fallback also missing"
}

$checks += Test-HttpEndpoint -Id "endpoint.voicevox" -Url "http://127.0.0.1:50021/version"

$blockers = @($checks | Where-Object { $_.severity -eq "blocker" -and $_.status -ne "ok" })
$warnings = @($checks | Where-Object { $_.severity -eq "warning" -and $_.status -ne "ok" })

[PSCustomObject]@{
  profile_id = [string]$profile.id
  checked_at = (Get-Date).ToString("o")
  status = if ($blockers.Count -gt 0) { "blocked" } elseif ($warnings.Count -gt 0) { "warning" } else { "ok" }
  workspace_root = $workspace
  port_mode = if ($UseIsolatedPorts) { "isolated_override" } else { "manifest_default" }
  ports = [PSCustomObject]@{
    home_assistant_bridge = $HomeAssistantBridgePort
    environment_state_server = $EnvironmentStatePort
    thought_core_api = $ThoughtCorePort
    mediapipe_camera_hub_stack = $MediapipePort
    mediapipe_browser_monitor = $MediapipeBrowserMonitorPort
    vision_snapshot_processor = $VisionSnapshotProcessorPort
    aituber_kit = $AituberPort
    touchdesigner_control_gui = $TouchDesignerGuiPort
  }
  counts = [PSCustomObject]@{
    checks = $checks.Count
    blockers = $blockers.Count
    warnings = $warnings.Count
  }
  checks = @($checks)
} | ConvertTo-Json -Depth 6
