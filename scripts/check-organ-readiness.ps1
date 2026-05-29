param(
  [string]$OrganManifestPath = "manifests/organs/legacy-github.json",
  [string]$ServiceManifestPath = "manifests/services/thought-core-v0-compat.json",
  [switch]$IncludeDeferred,
  [switch]$CheckEndpoints,
  [switch]$UseIsolatedPorts,
  [int]$TimeoutMs = 1200
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$RepoRoot = Split-Path -Parent $PSScriptRoot

$IsolatedPorts = @{
  home_assistant_bridge = 18887
  environment_state_server = 18890
  thought_core_api = 18888
  mediapipe_camera_hub_stack = 18865
  vision_snapshot_processor = 18876
  aituber_kit = 18880
  touchdesigner_control_gui = 18889
}

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

function Test-RequiredPath {
  param(
    [Parameter(Mandatory = $true)][string]$OrganId,
    [Parameter(Mandatory = $true)][string]$Root,
    [Parameter(Mandatory = $true)][string]$Id,
    [Parameter(Mandatory = $true)][string]$RelativePath,
    [string]$MissingSeverity = "gap"
  )
  $path = Join-Path $Root ($RelativePath -replace "/", [System.IO.Path]::DirectorySeparatorChar)
  if (Test-Path -LiteralPath $path) {
    return New-Check -Id "local.$OrganId.$Id" -Status "ok" -Path $path -Detail "path exists"
  }
  return New-Check -Id "local.$OrganId.$Id" -Status "missing" -Severity $MissingSeverity -Path $path -Detail "local requirement missing"
}

function Invoke-Git {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string[]]$Arguments
  )
  $output = & git -C $Path @Arguments 2>$null
  return [PSCustomObject]@{
    exit_code = $LASTEXITCODE
    output = ($output -join "`n")
  }
}

function Get-GitSourceState {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$ExpectedCommit
  )
  if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
    return [PSCustomObject]@{
      status = "missing"
      branch = ""
      commit = ""
      dirty = @()
      detail = "target path missing"
    }
  }
  if (-not (Test-Path -LiteralPath (Join-Path $Path ".git"))) {
    return [PSCustomObject]@{
      status = "not_git"
      branch = ""
      commit = ""
      dirty = @()
      detail = "target path is not a git checkout"
    }
  }

  $branch = (Invoke-Git -Path $Path -Arguments @("branch", "--show-current")).output
  $commit = (Invoke-Git -Path $Path -Arguments @("rev-parse", "HEAD")).output
  $dirty = @((Invoke-Git -Path $Path -Arguments @("status", "--short")).output -split "`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

  if ($commit -eq $ExpectedCommit) {
    $status = "exact"
    $detail = "checkout matches manifest commit"
  }
  else {
    $ancestor = Invoke-Git -Path $Path -Arguments @("merge-base", "--is-ancestor", $ExpectedCommit, "HEAD")
    if ($ancestor.exit_code -eq 0) {
      $status = "ahead_of_manifest"
      $detail = "checkout is ahead of manifest commit"
    }
    else {
      $status = "mismatch"
      $detail = "checkout does not match manifest commit"
    }
  }

  if ($dirty.Count -gt 0 -and $status -eq "exact") {
    $status = "dirty"
    $detail = "checkout matches manifest commit but has working tree changes"
  }
  elseif ($dirty.Count -gt 0) {
    $detail = "$detail; working tree has changes"
  }

  return [PSCustomObject]@{
    status = $status
    branch = $branch
    commit = $commit
    dirty = @($dirty)
    detail = $detail
  }
}

function ConvertTo-ServiceTarget {
  param(
    [Parameter(Mandatory = $true)]$Service
  )
  $health = $Service.health
  $url = [string](Get-OptionalProperty -Object $health -Name "url" -Default "")
  if ([string]::IsNullOrWhiteSpace($url) -or -not $UseIsolatedPorts) {
    return $url
  }
  $serviceId = [string]$Service.service_id
  if (-not $IsolatedPorts.ContainsKey($serviceId)) {
    return $url
  }
  $uri = [System.UriBuilder]::new($url)
  $uri.Port = [int]$IsolatedPorts[$serviceId]
  return $uri.Uri.AbsoluteUri
}

function Test-TcpEndpoint {
  param(
    [Parameter(Mandatory = $true)][string]$HostName,
    [Parameter(Mandatory = $true)][int]$Port
  )
  $client = [System.Net.Sockets.TcpClient]::new()
  try {
    $task = $client.ConnectAsync($HostName, $Port)
    if (-not $task.Wait($TimeoutMs)) {
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

function Test-WebSocketEndpoint {
  param([Parameter(Mandatory = $true)][string]$Url)
  $socket = [System.Net.WebSockets.ClientWebSocket]::new()
  $cts = [System.Threading.CancellationTokenSource]::new()
  try {
    $cts.CancelAfter($TimeoutMs)
    $task = $socket.ConnectAsync([System.Uri]::new($Url), $cts.Token)
    if (-not $task.Wait($TimeoutMs)) {
      return @{ ok = $false; detail = "timeout" }
    }
    if ($task.IsFaulted) {
      $message = if ($null -ne $task.Exception -and $null -ne $task.Exception.InnerException) {
        $task.Exception.InnerException.Message
      }
      else {
        "websocket handshake failed"
      }
      return @{ ok = $false; detail = $message }
    }
    if ($socket.State -eq [System.Net.WebSockets.WebSocketState]::Open) {
      try {
        $closeTask = $socket.CloseAsync(
          [System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure,
          "readiness probe",
          [System.Threading.CancellationToken]::None
        )
        [void]$closeTask.Wait([Math]::Min($TimeoutMs, 500))
      }
      catch {
      }
      return @{ ok = $true; detail = "websocket handshake" }
    }
    return @{ ok = $false; detail = "websocket state $($socket.State)" }
  }
  catch {
    return @{ ok = $false; detail = $_.Exception.Message }
  }
  finally {
    $cts.Dispose()
    $socket.Dispose()
  }
}

function Test-HttpEndpoint {
  param([Parameter(Mandatory = $true)][string]$Url)
  try {
    $timeoutSeconds = [Math]::Max(1, [int][Math]::Ceiling($TimeoutMs / 1000))
    $response = Invoke-WebRequest -Uri $Url -Method Get -TimeoutSec $timeoutSeconds -UseBasicParsing
    $status = if ($response.StatusCode -ge 200 -and $response.StatusCode -lt 500) { "ok" } else { "down" }
    $detail = "http $($response.StatusCode)"
    if ($Url -match "/health/?$" -and -not [string]::IsNullOrWhiteSpace([string]$response.Content)) {
      try {
        $payload = $response.Content | ConvertFrom-Json
        $okProperty = $payload.PSObject.Properties["ok"]
        $statusProperty = $payload.PSObject.Properties["status"]
        if ($null -ne $okProperty -and $okProperty.Value -eq $false) {
          $status = "degraded"
          $detail = "$detail; payload ok=false"
        }
        elseif ($null -ne $statusProperty -and [string]$statusProperty.Value -notin @("ok", "healthy", "ready")) {
          $status = "degraded"
          $detail = "$detail; payload status=$($statusProperty.Value)"
        }
      }
      catch {
      }
    }
    return @{ ok = ($status -eq "ok"); status = $status; detail = $detail }
  }
  catch {
    $response = Get-OptionalProperty -Object $_.Exception -Name "Response"
    if ($null -ne $response -and $null -ne $response.StatusCode) {
      return @{ ok = $false; status = "down"; detail = "http $([int]$response.StatusCode)" }
    }
    return @{ ok = $false; status = "down"; detail = $_.Exception.Message }
  }
}

function Test-ServiceHealth {
  param([Parameter(Mandatory = $true)]$Service)
  $healthType = [string]$Service.health.type
  $target = ConvertTo-ServiceTarget -Service $Service

  if (-not $CheckEndpoints) {
    $detail = if ([string]::IsNullOrWhiteSpace($target)) { "endpoint check skipped" } else { $target }
    return [PSCustomObject]@{
      service_id = [string]$Service.service_id
      health_type = $healthType
      status = "skipped"
      target = $target
      detail = $detail
    }
  }

  switch ($healthType) {
    "http" {
      $result = Test-HttpEndpoint -Url $target
      $serviceStatus = if ($result.ContainsKey("status")) { [string]$result["status"] } elseif ($result.ok) { "ok" } else { "down" }
      return [PSCustomObject]@{
        service_id = [string]$Service.service_id
        health_type = $healthType
        status = $serviceStatus
        target = $target
        detail = $result.detail
      }
    }
    "websocket" {
      $result = Test-WebSocketEndpoint -Url $target
      return [PSCustomObject]@{
        service_id = [string]$Service.service_id
        health_type = $healthType
        status = if ($result.ok) { "ok" } else { "down" }
        target = $target
        detail = $result.detail
      }
    }
    "process" {
      return [PSCustomObject]@{
        service_id = [string]$Service.service_id
        health_type = $healthType
        status = "skipped"
        target = [string](Get-OptionalProperty -Object $Service.health -Name "pid_name" -Default "")
        detail = "process health belongs to stack process-registry checks"
      }
    }
    default {
      return [PSCustomObject]@{
        service_id = [string]$Service.service_id
        health_type = $healthType
        status = "unknown"
        target = $target
        detail = "unsupported health type"
      }
    }
  }
}

function Get-LocalRequirements {
  param([Parameter(Mandatory = $true)][string]$OrganId)
  switch ($OrganId) {
    "ai-talk-core" {
      return @(
        @{ id = "sample_audio"; path = "data/sample_audio.mp3"; severity = "gap" },
        @{ id = "web_launcher"; path = "start_web.ps1"; severity = "gap" }
      )
    }
    "mediapipe-sword-sign" {
      return @(
        @{ id = "gesture_model"; path = "gesture_model.pkl"; severity = "gap" },
        @{ id = "camera_hub_launcher"; path = "scripts/start_camera_hub_stack.bat"; severity = "blocker" }
      )
    }
    "environment-state-server" {
      return @(
        @{ id = "package"; path = "pyproject.toml"; severity = "blocker" }
      )
    }
    "vision-snapshot-processor" {
      return @(
        @{ id = "package"; path = "pyproject.toml"; severity = "blocker" }
      )
    }
    "home-assistant-server" {
      return @(
        @{ id = "home_control_config"; path = "config/home-control.yaml"; severity = "gap" },
        @{ id = "env"; path = ".env"; severity = "gap" }
      )
    }
    "tts-service" {
      return @(
        @{ id = "package"; path = "pyproject.toml"; severity = "blocker" }
      )
    }
    "aituber-kit" {
      return @(
        @{ id = "package"; path = "package.json"; severity = "blocker" },
        @{ id = "env"; path = ".env"; severity = "gap" },
        @{ id = "vrm_dir"; path = "public/vrm"; severity = "gap" }
      )
    }
    "touchdesigner-ai-controller" {
      return @(
        @{ id = "server"; path = "tools/server.js"; severity = "blocker" },
        @{ id = "touchdesigner_dir"; path = "touchdesigner"; severity = "gap" }
      )
    }
    "system-house-renderer" {
      return @(
        @{ id = "package"; path = "pyproject.toml"; severity = "blocker" }
      )
    }
    default {
      return @()
    }
  }
}

function Get-SafeCheckCommands {
  param([Parameter(Mandatory = $true)][string]$OrganId)
  switch ($OrganId) {
    "ai-talk-core" { return @("uv run python smoke_test.py") }
    "mediapipe-sword-sign" { return @("uv run --with pytest --with pytest-asyncio python -m pytest tests") }
    "environment-state-server" { return @("uv run python -m unittest discover -s tests") }
    "vision-snapshot-processor" { return @("uv run python -m unittest discover -s tests") }
    "home-assistant-server" { return @("uv run --extra dev python -m pytest tests") }
    "tts-service" { return @("uv run python -m unittest discover -s tests") }
    "aituber-kit" { return @("npm test -- --runInBand src/__tests__/pages/api/messages.test.ts src/__tests__/pages/api/thoughtCoreChat.test.ts src/__tests__/utils/serverUrlSecurity.test.ts", "npm run build") }
    "touchdesigner-ai-controller" { return @("node --check tools/server.js") }
    "system-house-renderer" { return @("uv run python -m unittest discover -s tests") }
    default { return @() }
  }
}

$organManifest = Read-Json -Path $OrganManifestPath
$serviceManifest = Read-Json -Path $ServiceManifestPath

$servicesByOrgan = @{}
foreach ($service in @($serviceManifest.services)) {
  $organId = [string]$service.organ_id
  if (-not $servicesByOrgan.ContainsKey($organId)) {
    $servicesByOrgan[$organId] = @()
  }
  $servicesByOrgan[$organId] = @($servicesByOrgan[$organId]) + $service
}

$excluded = @()
$rows = @()
foreach ($source in @($organManifest.sources)) {
  $organId = [string]$source.organ_id
  $adoption = [string]$source.adoption
  if ($adoption -eq "deferred_reference" -and -not $IncludeDeferred) {
    $excluded += [PSCustomObject]@{
      organ_id = $organId
      reason = "deferred_reference"
      target_path = [string]$source.target_path
    }
    continue
  }

  $targetPath = Resolve-RepoPath ([string]$source.target_path)
  $gitState = Get-GitSourceState -Path $targetPath -ExpectedCommit ([string]$source.commit)
  $checks = @()
  $sourceSeverity = if ($gitState.status -in @("missing", "not_git", "mismatch")) { "blocker" } elseif ($gitState.status -in @("ahead_of_manifest", "dirty")) { "warning" } else { "info" }
  $checks += New-Check -Id "source.$organId" -Status $gitState.status -Severity $sourceSeverity -Path $targetPath -Detail $gitState.detail

  foreach ($requirement in @(Get-LocalRequirements -OrganId $organId)) {
    $checks += Test-RequiredPath -OrganId $organId -Root $targetPath -Id ([string]$requirement.id) -RelativePath ([string]$requirement.path) -MissingSeverity ([string]$requirement.severity)
  }

  $organServices = @()
  if ($servicesByOrgan.ContainsKey($organId)) {
    $organServices = @($servicesByOrgan[$organId])
  }
  $serviceHealth = @()
  foreach ($service in $organServices) {
    $serviceHealth += Test-ServiceHealth -Service $service
  }

  $blockers = @($checks | Where-Object { $_.severity -eq "blocker" -and $_.status -ne "ok" -and $_.status -ne "exact" })
  $warnings = @($checks | Where-Object { $_.severity -eq "warning" -and $_.status -ne "ok" -and $_.status -ne "exact" })
  $gaps = @($checks | Where-Object { $_.severity -eq "gap" -and $_.status -ne "ok" })
  $downServices = @($serviceHealth | Where-Object { $_.status -in @("down", "unknown") })
  $impairedServices = @($serviceHealth | Where-Object { $_.status -in @("down", "unknown", "degraded") })
  $okServices = @($serviceHealth | Where-Object { $_.status -eq "ok" })

  $validationResult = "pass"
  $availabilityState = "available"
  if ($blockers.Count -gt 0) {
    $validationResult = "blocked"
    $availabilityState = "blocked"
  }
  elseif ($CheckEndpoints -and $downServices.Count -gt 0 -and $okServices.Count -eq 0 -and $serviceHealth.Count -gt 0) {
    $validationResult = "unavailable"
    $availabilityState = "unavailable"
  }
  elseif ($CheckEndpoints -and $downServices.Count -gt 0) {
    $validationResult = "degraded"
    $availabilityState = "degraded"
  }
  elseif ($CheckEndpoints -and $impairedServices.Count -gt 0) {
    $validationResult = "degraded"
    $availabilityState = "degraded"
  }
  elseif ($warnings.Count -gt 0 -or $gaps.Count -gt 0) {
    $validationResult = "degraded"
    $availabilityState = "degraded"
  }

  $ladderLevel = if ($CheckEndpoints -and $serviceHealth.Count -gt 0 -and $impairedServices.Count -eq 0) { 5 } elseif ($checks.Count -gt 1) { 3 } else { 1 }
  $ladderName = switch ($ladderLevel) {
    5 { "service_health_probe" }
    3 { "static_contract_and_local_gap_inventory" }
    1 { "source_bootstrap" }
    default { "unknown" }
  }

  $rows += [PSCustomObject]@{
    organ_id = $organId
    organ_role = [string]$source.organ_role
    logical_role = [string]$source.logical_role
    adoption = $adoption
    target_path = [string]$source.target_path
    source_ref = [PSCustomObject]@{
      repo_url = [string]$source.repo_url
      branch = [string]$source.branch
      manifest_commit = [string]$source.commit
      current_branch = [string]$gitState.branch
      current_commit = [string]$gitState.commit
      source_status = [string]$gitState.status
      dirty = @($gitState.dirty)
    }
    ladder_level = $ladderLevel
    ladder_name = $ladderName
    validation_result = $validationResult
    availability_state = $availabilityState
    safe_check_commands = @(Get-SafeCheckCommands -OrganId $organId)
    checks = @($checks)
    service_health = @($serviceHealth)
    local_gaps = @($gaps | ForEach-Object { $_.path })
    notes = [string]$source.notes
  }
}

$counts = [PSCustomObject]@{
  organs = $rows.Count
  pass = @($rows | Where-Object { $_.validation_result -eq "pass" }).Count
  degraded = @($rows | Where-Object { $_.validation_result -eq "degraded" }).Count
  unavailable = @($rows | Where-Object { $_.validation_result -eq "unavailable" }).Count
  blocked = @($rows | Where-Object { $_.validation_result -eq "blocked" }).Count
  excluded = $excluded.Count
}

$status = if ($counts.blocked -gt 0) {
  "blocked"
}
elseif ($counts.unavailable -gt 0 -or $counts.degraded -gt 0) {
  "degraded"
}
else {
  "ok"
}

[PSCustomObject]@{
  status = $status
  checked_at = (Get-Date).ToString("o")
  check_endpoints = [bool]$CheckEndpoints
  port_mode = if ($UseIsolatedPorts) { "isolated_override" } else { "manifest_default" }
  validation_result_values = @("pass", "degraded", "unavailable", "blocked", "not_yet_checked")
  availability_state_values = @("available", "degraded", "unavailable", "blocked")
  counts = $counts
  organs = @($rows)
  excluded = @($excluded)
} | ConvertTo-Json -Depth 9
