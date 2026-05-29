param(
  [string]$TestPackPath = "manifests/tests/organ-test-packs/standard.json",
  [string]$StatusPath = ".cache/agent-os/status/current.json",
  [string]$TopologyPath = ".cache/agent-os/status/topology.json",
  [ValidateSet("auto", "replay", "live", "manual", "deep")]
  [string[]]$Modes = @(),
  [ValidateSet("manifest_default", "isolated_override")]
  [string]$PortMode = "manifest_default",
  [int]$TimeoutMs = 3000,
  [switch]$NoRefreshDiagnostics,
  [switch]$AllowSideEffects,
  [switch]$Json
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

function Read-JsonFile {
  param([Parameter(Mandatory = $true)][string]$Path)
  $resolved = Resolve-RepoPath $Path
  if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
    throw "JSON file not found: $resolved"
  }
  return Get-Content -Raw -LiteralPath $resolved | ConvertFrom-Json
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

function ConvertTo-StringArray {
  param([object]$Value)
  if ($null -eq $Value) {
    return @()
  }
  return @($Value | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

function Test-SafePackText {
  param([object]$Value)
  if ($null -eq $Value) {
    return $true
  }
  $text = [string]$Value
  if ($text.Length -gt 480) {
    return $false
  }
  if ($text -match "(?i)(api[_-]?key|x-api-key|access[_-]?token|refresh[_-]?token|secret|password|passwd|pwd|authorization\s*[:=]|bearer\s+[A-Za-z0-9._-]+)") {
    return $false
  }
  if ($text -match "(?i)(^|[_ -])(system|user|assistant)?[_ -]?prompt\s*[:=]") {
    return $false
  }
  if ($text -match "(^|[:=])[A-Za-z]:[\\/]") {
    return $false
  }
  if ($text -match "\\\\[^\\]+\\") {
    return $false
  }
  if ($text -match "(^|[:=])(/Users/|/home/|/mnt/|/var/|/tmp/|/etc/|~[\\/]|\.{1,2}[\\/])") {
    return $false
  }
  if ($text -match "(?i)(^|[\\/:=])[^\\/:=]+\.(log|jsonl|pcap|har)(\b|$)") {
    return $false
  }
  return $true
}

function Test-SafePackPath {
  param([string]$Path)
  if ([string]::IsNullOrWhiteSpace($Path)) {
    return $false
  }
  if ([System.IO.Path]::IsPathRooted($Path)) {
    return $false
  }
  $normalized = $Path -replace "\\", "/"
  if ($normalized -match "(^|/)\.\.(/|$)") {
    return $false
  }
  return Test-SafePackText -Value $Path
}

function Test-SafeFixtureCandidate {
  param([string]$Path)
  if (-not (Test-SafePackPath -Path $Path)) {
    return $false
  }
  return ($Path -replace "\\", "/") -match "^\.cache/agent-os/fixtures/[A-Za-z0-9_.-]+\.(mp4|mov|webm|jpg|jpeg|png|webp)$"
}

function Test-SafeHttpPath {
  param([string]$Path)
  if ([string]::IsNullOrWhiteSpace($Path)) {
    return $true
  }
  $normalized = $Path -replace "\\", "/"
  if ($normalized -notmatch "^/[A-Za-z0-9._~!`$&'()*+,;=:@/-]+$") {
    return $false
  }
  if ($normalized -match "(^|/)\.\.(/|$)") {
    return $false
  }
  if ($normalized -match "//") {
    return $false
  }
  return $true
}

function Get-FixtureLabel {
  param(
    [Parameter(Mandatory = $true)]$Test,
    [Parameter(Mandatory = $true)][string]$TestId
  )
  $label = [string](Get-OptionalProperty -Object $Test -Name "fixture_label" -Default "")
  if ([string]::IsNullOrWhiteSpace($label)) {
    return $TestId
  }
  return $label
}

function Assert-TestPackSafety {
  param([Parameter(Mandatory = $true)]$TestPack)
  foreach ($pack in @($TestPack.packs)) {
    foreach ($test in @($pack.tests)) {
      $testId = [string]$test.id
      $type = [string]$test.type
      if ($type -eq "path_exists") {
        $path = [string](Get-OptionalProperty -Object $test -Name "path" -Default "")
        if (-not (Test-SafePackPath -Path $path)) {
          throw "organ test $testId has unsafe path_exists path"
        }
      }
      if ($type -eq "http_health") {
        $path = [string](Get-OptionalProperty -Object $test -Name "path" -Default "")
        if (-not (Test-SafeHttpPath -Path $path)) {
          throw "organ test $testId has unsafe http_health path"
        }
      }
      if ($type -eq "replay_fixture") {
        $label = [string](Get-OptionalProperty -Object $test -Name "fixture_label" -Default "")
        if ($label -notmatch "^[A-Za-z0-9_-]+$") {
          throw "organ test $testId must declare a safe fixture_label"
        }
        foreach ($candidate in ConvertTo-StringArray -Value (Get-OptionalProperty -Object $test -Name "fixture_candidates" -Default @())) {
          if (-not (Test-SafeFixtureCandidate -Path $candidate)) {
            throw "organ test $testId has unsafe replay fixture candidate"
          }
        }
      }
      foreach ($field in @("instructions", "evidence_policy")) {
        $value = Get-OptionalProperty -Object $test -Name $field
        if (-not (Test-SafePackText -Value $value)) {
          throw "organ test $testId has unsafe text in $field"
        }
      }
    }
  }
}

function New-TestResult {
  param(
    [Parameter(Mandatory = $true)][string]$PackId,
    [Parameter(Mandatory = $true)][string]$TestId,
    [Parameter(Mandatory = $true)][string]$Mode,
    [Parameter(Mandatory = $true)][string]$Type,
    [ValidateSet("pass", "fail", "blocked", "manual", "skipped")]
    [Parameter(Mandatory = $true)][string]$Result,
    [Parameter(Mandatory = $true)][string]$Detail,
    [string]$EvidenceRef = ""
  )
  [PSCustomObject]@{
    pack_id = $PackId
    test_id = $TestId
    mode = $Mode
    type = $Type
    result = $Result
    detail = $Detail
    evidence_ref = $EvidenceRef
  }
}

function Get-ServiceById {
  param(
    [Parameter(Mandatory = $true)]$ServiceManifest,
    [Parameter(Mandatory = $true)][string]$ServiceId
  )
  foreach ($service in @($ServiceManifest.services)) {
    if ([string]$service.service_id -eq $ServiceId) {
      return $service
    }
  }
  return $null
}

function Convert-ServiceUrlForPortMode {
  param(
    [Parameter(Mandatory = $true)][string]$Url,
    [Parameter(Mandatory = $true)][string]$ServiceId,
    [Parameter(Mandatory = $true)]$ServiceManifest,
    [Parameter(Mandatory = $true)][string]$SelectedPortMode
  )
  if ([string]::IsNullOrWhiteSpace($Url)) {
    return $Url
  }
  $mode = Get-OptionalProperty -Object $ServiceManifest.port_modes -Name $SelectedPortMode
  if ($null -eq $mode) {
    return $Url
  }
  $servicePorts = Get-OptionalProperty -Object $mode -Name "service_ports"
  if ($null -eq $servicePorts) {
    return $Url
  }
  $portProperty = $servicePorts.PSObject.Properties[$ServiceId]
  if ($null -eq $portProperty) {
    return $Url
  }
  try {
    $builder = [System.UriBuilder]::new($Url)
    $builder.Port = [int]$portProperty.Value
    return $builder.Uri.AbsoluteUri
  }
  catch {
    return $Url
  }
}

function Get-ServiceHealthUrl {
  param(
    [Parameter(Mandatory = $true)]$ServiceManifest,
    [Parameter(Mandatory = $true)][string]$ServiceId,
    [string]$Path = ""
  )
  $service = Get-ServiceById -ServiceManifest $ServiceManifest -ServiceId $ServiceId
  if ($null -eq $service) {
    return ""
  }
  $url = [string](Get-OptionalProperty -Object $service.health -Name "url" -Default "")
  $url = Convert-ServiceUrlForPortMode -Url $url -ServiceId $ServiceId -ServiceManifest $ServiceManifest -SelectedPortMode $PortMode
  if ([string]::IsNullOrWhiteSpace($Path)) {
    return $url
  }
  try {
    $builder = [System.UriBuilder]::new($url)
    $builder.Path = $Path.TrimStart("/")
    $builder.Query = ""
    return $builder.Uri.AbsoluteUri
  }
  catch {
    return $url
  }
}

function Test-HttpHealth {
  param([Parameter(Mandatory = $true)][string]$Url)
  if ([string]::IsNullOrWhiteSpace($Url)) {
    return @{ result = "blocked"; detail = "service has no HTTP URL" }
  }
  try {
    $timeoutSeconds = [Math]::Max(1, [int][Math]::Ceiling($TimeoutMs / 1000))
    $response = Invoke-WebRequest -Uri $Url -Method Get -TimeoutSec $timeoutSeconds -UseBasicParsing
    if ($response.StatusCode -ge 200 -and $response.StatusCode -lt 300) {
      return @{ result = "pass"; detail = "http $($response.StatusCode)" }
    }
    return @{ result = "fail"; detail = "http $($response.StatusCode)" }
  }
  catch {
    return @{ result = "blocked"; detail = $_.Exception.Message }
  }
}

function Test-WebSocketHealth {
  param([Parameter(Mandatory = $true)][string]$Url)
  if ([string]::IsNullOrWhiteSpace($Url)) {
    return @{ result = "blocked"; detail = "service has no WebSocket URL" }
  }
  $socket = [System.Net.WebSockets.ClientWebSocket]::new()
  $cts = [System.Threading.CancellationTokenSource]::new()
  try {
    $cts.CancelAfter($TimeoutMs)
    $task = $socket.ConnectAsync([System.Uri]::new($Url), $cts.Token)
    if (-not $task.Wait($TimeoutMs)) {
      return @{ result = "blocked"; detail = "timeout" }
    }
    if ($task.IsFaulted) {
      $message = if ($null -ne $task.Exception -and $null -ne $task.Exception.InnerException) {
        $task.Exception.InnerException.Message
      }
      else {
        "websocket handshake failed"
      }
      return @{ result = "blocked"; detail = $message }
    }
    if ($socket.State -eq [System.Net.WebSockets.WebSocketState]::Open) {
      try {
        $closeTask = $socket.CloseAsync(
          [System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure,
          "organ test pack probe",
          [System.Threading.CancellationToken]::None
        )
        [void]$closeTask.Wait([Math]::Min($TimeoutMs, 500))
      }
      catch {
      }
      return @{ result = "pass"; detail = "websocket handshake" }
    }
    return @{ result = "fail"; detail = "websocket state $($socket.State)" }
  }
  catch {
    return @{ result = "blocked"; detail = $_.Exception.Message }
  }
  finally {
    $cts.Dispose()
    $socket.Dispose()
  }
}

function Invoke-TestCommand {
  param([Parameter(Mandatory = $true)]$Test)
  $executable = [string](Get-OptionalProperty -Object $Test -Name "executable" -Default "")
  if ([string]::IsNullOrWhiteSpace($executable)) {
    return @{ result = "blocked"; detail = "command missing executable" }
  }
  $args = ConvertTo-StringArray -Value (Get-OptionalProperty -Object $Test -Name "args" -Default @())
  $expected = [int](Get-OptionalProperty -Object $Test -Name "expect_exit_code" -Default 0)
  $output = & $executable @args 2>&1
  $exitCode = $LASTEXITCODE
  if ($exitCode -eq $expected) {
    return @{ result = "pass"; detail = "exit $exitCode" }
  }
  $tail = (($output | Select-Object -Last 3) -join " ")
  if ($tail.Length -gt 240) {
    $tail = $tail.Substring(0, 240)
  }
  return @{ result = "fail"; detail = "exit $exitCode; $tail" }
}

function Get-DiagnosticsService {
  param(
    [object]$Status,
    [Parameter(Mandatory = $true)][string]$ServiceId
  )
  foreach ($service in @($Status.services)) {
    if ([string]$service.service_id -eq $ServiceId) {
      return $service
    }
  }
  return $null
}

function Get-DiagnosticsCapability {
  param(
    [object]$Status,
    [Parameter(Mandatory = $true)][string]$Capability
  )
  foreach ($entry in @($Status.capabilities)) {
    if ([string]$entry.capability -eq $Capability) {
      return $entry
    }
  }
  return $null
}

function Invoke-PackTest {
  param(
    [Parameter(Mandatory = $true)][string]$PackId,
    [Parameter(Mandatory = $true)]$Test,
    [Parameter(Mandatory = $true)][string[]]$SelectedModes,
    [object]$Status,
    [Parameter(Mandatory = $true)]$ServiceManifest
  )
  $testId = [string]$Test.id
  $mode = [string]$Test.mode
  $type = [string]$Test.type
  if ($mode -notin $SelectedModes) {
    return New-TestResult -PackId $PackId -TestId $testId -Mode $mode -Type $type -Result "skipped" -Detail "mode not selected"
  }

  switch ($type) {
    "path_exists" {
      $path = [string]$Test.path
      $resolved = Resolve-RepoPath $path
      if (Test-Path -LiteralPath $resolved) {
        return New-TestResult -PackId $PackId -TestId $testId -Mode $mode -Type $type -Result "pass" -Detail "path exists: $path"
      }
      $missingResult = [string](Get-OptionalProperty -Object $Test -Name "missing_result" -Default "fail")
      if ($missingResult -notin @("fail", "blocked")) {
        $missingResult = "fail"
      }
      return New-TestResult -PackId $PackId -TestId $testId -Mode $mode -Type $type -Result $missingResult -Detail "path missing: $path"
    }
    "diagnostics_service" {
      $serviceId = [string]$Test.service_id
      $service = Get-DiagnosticsService -Status $Status -ServiceId $serviceId
      if ($null -eq $service) {
        return New-TestResult -PackId $PackId -TestId $testId -Mode $mode -Type $type -Result "fail" -Detail "service missing from diagnostics status: $serviceId"
      }
      return New-TestResult -PackId $PackId -TestId $testId -Mode $mode -Type $type -Result "pass" -Detail "service present with state=$($service.state) freshness=$($service.freshness)" -EvidenceRef "snapshot:diagnostics-status-current"
    }
    "diagnostics_capability" {
      $capability = [string]$Test.capability
      $entry = Get-DiagnosticsCapability -Status $Status -Capability $capability
      if ($null -eq $entry) {
        return New-TestResult -PackId $PackId -TestId $testId -Mode $mode -Type $type -Result "fail" -Detail "capability missing from diagnostics status: $capability"
      }
      return New-TestResult -PackId $PackId -TestId $testId -Mode $mode -Type $type -Result "pass" -Detail "capability present with state=$($entry.state) freshness=$($entry.freshness)" -EvidenceRef "snapshot:diagnostics-status-current"
    }
    "http_health" {
      $serviceId = [string]$Test.service_id
      $path = [string](Get-OptionalProperty -Object $Test -Name "path" -Default "")
      $url = Get-ServiceHealthUrl -ServiceManifest $ServiceManifest -ServiceId $serviceId -Path $path
      $probe = Test-HttpHealth -Url $url
      return New-TestResult -PackId $PackId -TestId $testId -Mode $mode -Type $type -Result $probe.result -Detail "$serviceId $($probe.detail)"
    }
    "websocket_health" {
      $serviceId = [string]$Test.service_id
      $url = Get-ServiceHealthUrl -ServiceManifest $ServiceManifest -ServiceId $serviceId
      $probe = Test-WebSocketHealth -Url $url
      return New-TestResult -PackId $PackId -TestId $testId -Mode $mode -Type $type -Result $probe.result -Detail "$serviceId $($probe.detail)"
    }
    "replay_fixture" {
      $fixtureLabel = Get-FixtureLabel -Test $Test -TestId $testId
      foreach ($candidate in ConvertTo-StringArray -Value (Get-OptionalProperty -Object $Test -Name "fixture_candidates" -Default @())) {
        if (Test-Path -LiteralPath (Resolve-RepoPath $candidate) -PathType Leaf) {
          return New-TestResult -PackId $PackId -TestId $testId -Mode $mode -Type $type -Result "pass" -Detail "local replay fixture present: $fixtureLabel"
        }
      }
      return New-TestResult -PackId $PackId -TestId $testId -Mode $mode -Type $type -Result "blocked" -Detail "local replay fixture not available: $fixtureLabel"
    }
    "side_effect_gate" {
      if (-not $AllowSideEffects) {
        return New-TestResult -PackId $PackId -TestId $testId -Mode $mode -Type $type -Result "blocked" -Detail "requires -AllowSideEffects"
      }
      return New-TestResult -PackId $PackId -TestId $testId -Mode $mode -Type $type -Result "manual" -Detail ([string]$Test.instructions)
    }
    "manual_check" {
      return New-TestResult -PackId $PackId -TestId $testId -Mode $mode -Type $type -Result "manual" -Detail ([string]$Test.instructions)
    }
    "command" {
      $probe = Invoke-TestCommand -Test $Test
      return New-TestResult -PackId $PackId -TestId $testId -Mode $mode -Type $type -Result $probe.result -Detail $probe.detail
    }
    default {
      return New-TestResult -PackId $PackId -TestId $testId -Mode $mode -Type $type -Result "blocked" -Detail "unsupported test type: $type"
    }
  }
}

$testPack = Read-JsonFile -Path $TestPackPath
Assert-TestPackSafety -TestPack $testPack
if ($Modes.Count -eq 0) {
  $Modes = ConvertTo-StringArray -Value (Get-OptionalProperty -Object $testPack -Name "default_modes" -Default @("auto"))
}
$Modes = @($Modes | Select-Object -Unique)

$serviceManifest = Read-JsonFile -Path ([string]$testPack.service_manifest)

if (-not $NoRefreshDiagnostics) {
  $updateArgs = @{
    PortMode = $PortMode
    NoJournal = $true
    TimeoutMs = $TimeoutMs
  }
  if ("live" -notin $Modes) {
    $updateArgs.ManifestOnly = $true
  }
  [void](& (Join-Path $PSScriptRoot "update-diagnostics-status.ps1") @updateArgs)
}

$status = Read-JsonFile -Path $StatusPath
$topology = $null
$topologyResolved = Resolve-RepoPath $TopologyPath
if (Test-Path -LiteralPath $topologyResolved -PathType Leaf) {
  $topology = Read-JsonFile -Path $TopologyPath
}

$results = @()
foreach ($pack in @($testPack.packs)) {
  $packId = [string]$pack.organ_id
  foreach ($test in @($pack.tests)) {
    $results += Invoke-PackTest -PackId $packId -Test $test -SelectedModes $Modes -Status $status -ServiceManifest $serviceManifest
  }
}

$activeResults = @($results | Where-Object { $_.result -ne "skipped" })
$summary = [PSCustomObject]@{
  status = if (@($activeResults | Where-Object { $_.result -eq "fail" }).Count -gt 0) {
    "failed"
  }
  elseif (@($activeResults | Where-Object { $_.result -eq "blocked" }).Count -gt 0) {
    "blocked"
  }
  elseif (@($activeResults | Where-Object { $_.result -eq "manual" }).Count -gt 0) {
    "manual"
  }
  else {
    "ok"
  }
  generated_at = (Get-Date).ToString("o")
  test_pack_id = [string]$testPack.id
  modes = @($Modes)
  port_mode = $PortMode
  allow_side_effects = [bool]$AllowSideEffects
  packs = @($testPack.packs).Count
  tests_total = $results.Count
  tests_selected = $activeResults.Count
  pass = @($activeResults | Where-Object { $_.result -eq "pass" }).Count
  fail = @($activeResults | Where-Object { $_.result -eq "fail" }).Count
  blocked = @($activeResults | Where-Object { $_.result -eq "blocked" }).Count
  manual = @($activeResults | Where-Object { $_.result -eq "manual" }).Count
  skipped = @($results | Where-Object { $_.result -eq "skipped" }).Count
  topology_snapshot_id = if ($null -ne $topology) { [string](Get-OptionalProperty -Object $topology -Name "topology_snapshot_id" -Default "") } else { "" }
}

$output = [PSCustomObject]@{
  summary = $summary
  results = @($results)
}

if ($Json) {
  $output | ConvertTo-Json -Depth 9
}
else {
  Write-Output "Agent OS organ test packs: $($summary.status)"
  Write-Output "modes=$($Modes -join ',') port_mode=$PortMode selected=$($summary.tests_selected) pass=$($summary.pass) fail=$($summary.fail) blocked=$($summary.blocked) manual=$($summary.manual) skipped=$($summary.skipped)"
  foreach ($result in $activeResults) {
    Write-Output "- [$($result.result)] $($result.test_id): $($result.detail)"
  }
}

if ($summary.fail -gt 0) {
  exit 1
}
