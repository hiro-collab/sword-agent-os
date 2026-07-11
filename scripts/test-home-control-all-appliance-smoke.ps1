[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:assertionCount = 0
$script:caseCount = 0
$script:mutationProbeCount = 0
$script:fixtureStage = 'none'
$script:lastOperationStage = 'none'
$stage = 'initialization'

function Assert-Condition {
    param(
        [Parameter(Mandatory)]
        [bool]$Condition,

        [Parameter(Mandatory)]
        [string]$Name
    )

    $script:assertionCount++
    if (-not $Condition) {
        throw ('assertion_failed={0}' -f $Name)
    }
}

function Assert-Contains {
    param(
        [Parameter(Mandatory)]
        [object[]]$Values,

        [Parameter(Mandatory)]
        [string]$Expected,

        [Parameter(Mandatory)]
        [string]$Name
    )

    Assert-Condition -Condition (@($Values) -ccontains $Expected) -Name $Name
}

function Get-RequiredProperty {
    param(
        [Parameter(Mandatory)]
        [object]$InputObject,

        [Parameter(Mandatory)]
        [string]$Name
    )

    $property = $InputObject.PSObject.Properties[$Name]
    Assert-Condition -Condition ($null -ne $property) -Name ('property_{0}' -f $Name)
    return $property.Value
}

function Get-FreeLoopbackPort {
    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    try {
        $listener.Start()
        return [int]$listener.LocalEndpoint.Port
    }
    finally {
        $listener.Stop()
    }
}

function Get-FakeServerSource {
    return @'
param(
    [Parameter(Mandatory)]
    [int]$Port,

    [Parameter(Mandatory)]
    [string]$ScenarioPath,

    [Parameter(Mandatory)]
    [string]$RequestLogPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$scenario = Get-Content -Raw -LiteralPath $ScenarioPath | ConvertFrom-Json
$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add(('http://127.0.0.1:{0}/' -f $Port))

function Get-ScenarioText {
    param([string]$Name)
    $property = $scenario.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) { return '' }
    return [string]$property.Value
}

function Get-TrackingClass {
    param([string]$ActionId)
    $overrides = $scenario.PSObject.Properties['tracking_overrides']
    if ($null -ne $overrides -and $null -ne $overrides.Value) {
        $property = $overrides.Value.PSObject.Properties[$ActionId]
        if ($null -ne $property) { return [string]$property.Value }
    }
    if ($ActionId -eq 'light_on') { return 'external_required' }
    if ($ActionId -eq 'fan_on') { return 'ack_only' }
    return 'tracked'
}

function Get-ScenarioMapText {
    param(
        [string]$MapName,
        [string]$Key
    )

    $mapProperty = $scenario.PSObject.Properties[$MapName]
    if ($null -eq $mapProperty -or $null -eq $mapProperty.Value) { return '' }
    $valueProperty = $mapProperty.Value.PSObject.Properties[$Key]
    if ($null -eq $valueProperty -or $null -eq $valueProperty.Value) { return '' }
    return [string]$valueProperty.Value
}

function Write-JsonResponse {
    param(
        [Parameter(Mandatory)]
        [System.Net.HttpListenerContext]$Context,

        [Parameter(Mandatory)]
        [object]$Body,

        [int]$StatusCode = 200
    )

    $bytes = [System.Text.Encoding]::UTF8.GetBytes(($Body | ConvertTo-Json -Depth 12 -Compress))
    $Context.Response.StatusCode = $StatusCode
    $Context.Response.ContentType = 'application/json'
    $Context.Response.ContentLength64 = $bytes.Length
    try {
        $Context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    }
    catch {
    }
    finally {
        $Context.Response.OutputStream.Close()
    }
}

function Write-SafeRequestRecord {
    param(
        [string]$Kind,
        [string]$ActionId
    )

    $record = [ordered]@{
        kind = $Kind
        action_id = $ActionId
    }
    Add-Content -LiteralPath $RequestLogPath -Value ($record | ConvertTo-Json -Compress) -Encoding UTF8
}

$actionIds = @(
    'light_on',
    'fan_on',
    'aircon_cool',
    'aircon_hvac_off',
    'door_open',
    'door_close',
    'vacuum_start',
    'vacuum_return'
)

try {
    $listener.Start()
    while ($listener.IsListening) {
        $context = $listener.GetContext()
        $path = [string]$context.Request.Url.AbsolutePath

        if ($path -ne '/health' -and [string]$context.Request.Headers['Authorization'] -ne 'Bearer fixture-token-000000000000000000000000') {
            Write-JsonResponse -Context $context -Body @{ status = 'unauthorized' } -StatusCode 401
            continue
        }

        if ($path -eq '/health') {
            Write-JsonResponse -Context $context -Body @{ ok = $true; status = 'ok' }
            continue
        }

        if ($path -eq '/actions') {
            $rows = @($actionIds | ForEach-Object {
                [ordered]@{
                    action_id = $_
                    state_tracking = Get-TrackingClass -ActionId $_
                }
            })
            Write-JsonResponse -Context $context -Body $rows
            continue
        }

        if ($path -match '^/actions/([^/]+)/execute$') {
            $actionId = [uri]::UnescapeDataString($Matches[1])
            Write-SafeRequestRecord -Kind 'execute' -ActionId $actionId
            if ((Get-ScenarioText -Name 'execute_timeout_action') -ceq $actionId) {
                Start-Sleep -Seconds 35
            }
            $statusOverride = Get-ScenarioMapText -MapName 'execute_status_overrides' -Key $actionId
            if (-not [string]::IsNullOrWhiteSpace($statusOverride)) {
                Write-JsonResponse -Context $context -Body @{ status = $statusOverride; executed = $false }
                continue
            }
            $failures = @($scenario.execute_failures | ForEach-Object { [string]$_ })
            if ($failures -ccontains $actionId) {
                Write-JsonResponse -Context $context -Body @{ status = 'rejected'; executed = $false }
            }
            else {
                Write-JsonResponse -Context $context -Body @{ status = 'submitted'; executed = $true }
            }
            continue
        }

        if ($path -match '^/actions/([^/]+)/state$') {
            $actionId = [uri]::UnescapeDataString($Matches[1])
            Write-SafeRequestRecord -Kind 'state' -ActionId $actionId
            $status = 'matched'
            $statusOverride = Get-ScenarioMapText -MapName 'state_status_overrides' -Key $actionId
            if (-not [string]::IsNullOrWhiteSpace($statusOverride)) {
                $status = $statusOverride
            }
            if ((Get-ScenarioText -Name 'mismatch_state_action') -ceq $actionId) {
                $status = 'mismatch'
            }
            if ((Get-ScenarioText -Name 'unavailable_state_action') -ceq $actionId) {
                $status = 'unavailable'
            }
            Write-JsonResponse -Context $context -Body @{ action_id = $actionId; status = $status }
            continue
        }

        Write-JsonResponse -Context $context -Body @{ status = 'not_found' } -StatusCode 404
    }
}
finally {
    if ($listener.IsListening) { $listener.Stop() }
    $listener.Close()
}
'@
}

function Get-FakeCameraSource {
    return @'
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$IgnoredArguments
)

$counterPath = Join-Path $PSScriptRoot 'camera-count.txt'
$backendPath = Join-Path $PSScriptRoot 'camera-backend.txt'
$count = 0
if (Test-Path -LiteralPath $counterPath) {
    $count = [int](Get-Content -Raw -LiteralPath $counterPath)
}
$count++
[System.IO.File]::WriteAllText($counterPath, [string]$count)
$values = @(10.0, 42.0, 8.0)
$brightness = $values[[Math]::Min($count - 1, $values.Count - 1)]
[ordered]@{
    ok = $true
    mean_brightness = $brightness
    backend = if (Test-Path -LiteralPath $backendPath) { [string](Get-Content -Raw -LiteralPath $backendPath) } else { 'synthetic_fixture' }
} | ConvertTo-Json -Compress
'@
}

function New-SmokeFixture {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Scenario
    )

    $fixtureRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('sword-hc-fake-' + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $fixtureRoot
    $serverPath = Join-Path $fixtureRoot 'fake-bridge.ps1'
    $cameraPath = Join-Path $fixtureRoot 'fake-camera.ps1'
    $scenarioPath = Join-Path $fixtureRoot 'scenario.json'
    $requestLogPath = Join-Path $fixtureRoot 'requests.jsonl'
    $cameraBackendPath = Join-Path $fixtureRoot 'camera-backend.txt'
    $stdoutPath = Join-Path $fixtureRoot 'fake-bridge.stdout'
    $stderrPath = Join-Path $fixtureRoot 'fake-bridge.stderr'
    $envPath = Join-Path $fixtureRoot '.env'

    [System.IO.File]::WriteAllText($serverPath, (Get-FakeServerSource), [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::WriteAllText($cameraPath, (Get-FakeCameraSource), [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::WriteAllText($scenarioPath, ($Scenario | ConvertTo-Json -Depth 8), [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::WriteAllText($requestLogPath, '', [System.Text.UTF8Encoding]::new($false))
    $cameraBackend = if ($Scenario.ContainsKey('camera_backend')) { [string]$Scenario.camera_backend } else { 'synthetic_fixture' }
    [System.IO.File]::WriteAllText($cameraBackendPath, $cameraBackend, [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::WriteAllText($envPath, 'HOME_CONTROL_API_TOKEN=fixture-token-000000000000000000000000', [System.Text.UTF8Encoding]::new($false))

    return [pscustomobject]@{
        Root = $fixtureRoot
        ServerPath = $serverPath
        CameraPath = $cameraPath
        ScenarioPath = $scenarioPath
        RequestLogPath = $requestLogPath
        StdoutPath = $stdoutPath
        StderrPath = $stderrPath
        Port = Get-FreeLoopbackPort
        Process = $null
    }
}

function Start-SmokeFixture {
    param(
        [Parameter(Mandatory)]
        [object]$Fixture,

        [Parameter(Mandatory)]
        [string]$PowerShellPath
    )

    $Fixture.Process = Start-Process `
        -FilePath $PowerShellPath `
        -ArgumentList @(
            '-NoLogo',
            '-NoProfile',
            '-NonInteractive',
            '-File',
            $Fixture.ServerPath,
            '-Port',
            [string]$Fixture.Port,
            '-ScenarioPath',
            $Fixture.ScenarioPath,
            '-RequestLogPath',
            $Fixture.RequestLogPath
        ) `
        -WindowStyle Hidden `
        -RedirectStandardOutput $Fixture.StdoutPath `
        -RedirectStandardError $Fixture.StderrPath `
        -PassThru

    $ready = $false
    for ($attempt = 0; $attempt -lt 50; $attempt++) {
        Start-Sleep -Milliseconds 100
        try {
            $health = Invoke-RestMethod -Method Get -Uri ('http://127.0.0.1:{0}/health' -f $Fixture.Port) -TimeoutSec 1
            if ([bool]$health.ok) {
                $ready = $true
                break
            }
        }
        catch {
        }
        if ($Fixture.Process.HasExited) { break }
    }
    Assert-Condition -Condition $ready -Name 'fixture_listener_ready'
}

function Stop-SmokeFixture {
    param(
        [Parameter(Mandatory)]
        [object]$Fixture
    )

    if ($null -ne $Fixture.Process) {
        if (-not $Fixture.Process.HasExited) {
            Stop-Process -Id $Fixture.Process.Id -Force -ErrorAction SilentlyContinue
        }
        try { $Fixture.Process.WaitForExit(5000) | Out-Null } catch {}
        $Fixture.Process.Dispose()
    }

    for ($attempt = 0; $attempt -lt 30; $attempt++) {
        $listeners = @(Get-NetTCPConnection -LocalPort $Fixture.Port -State Listen -ErrorAction SilentlyContinue)
        if ($listeners.Count -eq 0) { break }
        Start-Sleep -Milliseconds 100
    }
    Assert-Condition -Condition (@(Get-NetTCPConnection -LocalPort $Fixture.Port -State Listen -ErrorAction SilentlyContinue).Count -eq 0) -Name 'fixture_listener_stopped'

    Remove-Item -LiteralPath $Fixture.Root -Recurse -Force
    Assert-Condition -Condition (-not (Test-Path -LiteralPath $Fixture.Root)) -Name 'fixture_residue_zero'
}

function Read-SafeRequestRecords {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $records = @()
    foreach ($line in @(Get-Content -LiteralPath $Path -ErrorAction SilentlyContinue)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $records += $line | ConvertFrom-Json
    }
    return $records
}

function Invoke-SmokeCase {
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [hashtable]$Scenario,

        [switch]$SkipCamera
    )

    $script:caseCount++
    $fixture = New-SmokeFixture -Scenario $Scenario
    $powerShellPath = (Get-Process -Id $PID).Path
    $runnerPath = Join-Path $PSScriptRoot 'run-home-control-all-appliance-smoke.ps1'
    $previousTemp = [Environment]::GetEnvironmentVariable('TEMP', 'Process')
    $result = $null
    $requestRecords = @()
    try {
        $script:fixtureStage = 'fixture_start'
        $script:lastOperationStage = $script:fixtureStage
        Start-SmokeFixture -Fixture $fixture -PowerShellPath $powerShellPath
        $script:fixtureStage = 'runner_invoke'
        $script:lastOperationStage = $script:fixtureStage
        [Environment]::SetEnvironmentVariable('TEMP', $fixture.Root, 'Process')
        $runnerArguments = @{
            HostName = '127.0.0.1'
            Port = $fixture.Port
            HomeAssistantServerRoot = $fixture.Root
            CameraPython = $powerShellPath
            CameraScript = $fixture.CameraPath
            SkipCamera = $SkipCamera.IsPresent
        }
        $capture = @(& $runnerPath @runnerArguments 2>&1)
        $script:fixtureStage = 'runner_decode'
        $script:lastOperationStage = $script:fixtureStage
        $result = ($capture -join [Environment]::NewLine) | ConvertFrom-Json
        Assert-Condition -Condition (@(Get-ChildItem -LiteralPath $fixture.Root -Filter 'hc-all-*' -ErrorAction SilentlyContinue).Count -eq 0) -Name ('{0}_runner_temp_residue' -f $Name)
        $script:fixtureStage = 'request_read'
        $script:lastOperationStage = $script:fixtureStage
        $requestRecords = @(Read-SafeRequestRecords -Path $fixture.RequestLogPath)
        $script:mutationProbeCount += @($requestRecords | Where-Object { $_.kind -ceq 'execute' }).Count
    }
    finally {
        $script:fixtureStage = 'fixture_cleanup'
        [Environment]::SetEnvironmentVariable('TEMP', $previousTemp, 'Process')
        Stop-SmokeFixture -Fixture $fixture
        $script:fixtureStage = 'none'
    }

    return [pscustomobject]@{
        Name = $Name
        Result = $result
        Requests = $requestRecords
    }
}

function Assert-BaseProofSeparation {
    param(
        [Parameter(Mandatory)]
        [object]$Case
    )

    $result = $Case.Result
    Assert-Condition -Condition ([bool]$result.raw_private_publication_flags -eq $false) -Name 'raw_private_false'
    Assert-Condition -Condition ([int]$result.bounded_counts.direct_ha_bypass_count -eq 0) -Name 'direct_ha_bypass_zero'
    Assert-Contains -Values @($result.non_claims) -Expected 'no_physical_device_proof' -Name 'physical_proof_nonclaim'
    foreach ($targetName in @('light_stimulus', 'fan_command', 'aircon_cool_to_hvac_off', 'door_open_to_close', 'vacuum_start_to_return')) {
        $target = Get-RequiredProperty -InputObject $result.target_results -Name $targetName
        Assert-Condition -Condition ([string]$target.physical_proof_class -ceq 'not_claimed') -Name ('{0}_physical_not_claimed' -f $targetName)
        Assert-Contains -Values @($target.evidence_class) -Expected 'non_claimed_physical_proof' -Name ('{0}_evidence_physical_nonclaim' -f $targetName)
        Assert-Contains -Values @($target.evidence_class) -Expected 'readiness/final_non_claim' -Name ('{0}_evidence_readiness_nonclaim' -f $targetName)
        $null = Get-RequiredProperty -InputObject $target -Name 'checktracking_class'
        $null = Get-RequiredProperty -InputObject $target -Name 'restore_class'
    }
}

try {
    $runnerPath = Join-Path $PSScriptRoot 'run-home-control-all-appliance-smoke.ps1'
    $testPath = $PSCommandPath
    $stage = 'parse'
    foreach ($pathToParse in @($runnerPath, $testPath)) {
        $tokens = $null
        $parseErrors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile($pathToParse, [ref]$tokens, [ref]$parseErrors)
        Assert-Condition -Condition (@($parseErrors).Count -eq 0) -Name 'source_parse'
    }

    $stage = 'success'
    $success = Invoke-SmokeCase -Name $stage -Scenario @{ execute_failures = @(); tracking_overrides = @{}; camera_backend = 'fixture_private_camera_marker' }
    Assert-BaseProofSeparation -Case $success
    Assert-Condition -Condition ([string]$success.Result.status_class -ceq 'executed') -Name 'success_status'
    Assert-Condition -Condition ([int]$success.Result.bounded_counts.command_submission_count -eq 8) -Name 'success_submission_count'
    Assert-Condition -Condition ([int]$success.Result.bounded_counts.checktracking_action_count -eq 8) -Name 'success_tracking_count'
    Assert-Condition -Condition ([int]$success.Result.bounded_counts.checkstate_matched_count -eq 6) -Name 'success_state_match_count'
    Assert-Condition -Condition ([string]$success.Result.target_results.light_stimulus.camera_environment_estimate_class -ceq 'brightness_movement_bucketed') -Name 'success_camera_estimate'
    Assert-Condition -Condition ([string]$success.Result.camera_summary.backend_class -ceq 'available_unknown_backend') -Name 'success_camera_backend_bounded'
    Assert-Condition -Condition (($success.Result | ConvertTo-Json -Depth 20 -Compress) -notmatch 'fixture_private_camera_marker') -Name 'success_camera_marker_not_published'
    Assert-Condition -Condition ([string]$success.Result.target_results.fan_command.ha_visible_state_class -ceq 'not_claimed_command_submission_only') -Name 'success_fan_ack_only'
    Assert-Condition -Condition ([string]$success.Result.target_results.aircon_cool_to_hvac_off.restore_class -ceq 'submitted') -Name 'success_aircon_restore'
    Assert-Condition -Condition ([string]$success.Result.target_results.door_open_to_close.restore_class -ceq 'submitted') -Name 'success_door_restore'
    Assert-Condition -Condition ([string]$success.Result.target_results.vacuum_start_to_return.restore_class -ceq 'submitted') -Name 'success_vacuum_restore'
    $successExecutes = @($success.Requests | Where-Object { $_.kind -ceq 'execute' } | ForEach-Object { [string]$_.action_id })
    Assert-Condition -Condition ($successExecutes.Count -eq 8) -Name 'success_mutation_probe_count'

    $stage = 'mixed_submission_failure'
    $mixed = Invoke-SmokeCase -Name $stage -Scenario @{ execute_failures = @(); execute_status_overrides = @{ fan_on = 'fixture_private_execute_marker' }; tracking_overrides = @{} }
    Assert-BaseProofSeparation -Case $mixed
    Assert-Condition -Condition ([string]$mixed.Result.result_class -ceq 'some_appliance_commands_not_submitted') -Name 'mixed_result_class'
    Assert-Condition -Condition ([int]$mixed.Result.bounded_counts.command_submission_count -eq 7) -Name 'mixed_submission_count'
    Assert-Condition -Condition ([string]$mixed.Result.target_results.fan_command.command_submission_class -ceq 'not_submitted') -Name 'mixed_fan_not_submitted'
    Assert-Condition -Condition ([string]$mixed.Result.action_results.fan_on -ceq 'not_submitted_unknown_status') -Name 'mixed_execute_status_bounded'
    Assert-Condition -Condition (($mixed.Result | ConvertTo-Json -Depth 20 -Compress) -notmatch 'fixture_private_execute_marker') -Name 'mixed_execute_marker_not_published'
    Assert-Condition -Condition (@($mixed.Requests | Where-Object { $_.kind -ceq 'execute' }).Count -eq 8) -Name 'mixed_mutation_probe_count'

    $stage = 'command_timeout'
    $timeout = Invoke-SmokeCase -Name $stage -Scenario @{ execute_failures = @(); execute_timeout_action = 'light_on'; tracking_overrides = @{} }
    Assert-Condition -Condition ([string]$timeout.Result.blocker_class -ceq 'technical_execution_exception') -Name 'timeout_blocker_class'
    Assert-Condition -Condition ([int]$timeout.Result.bounded_counts.command_submission_count -eq 0) -Name 'timeout_submission_zero'
    Assert-Condition -Condition (@($timeout.Requests | Where-Object { $_.kind -ceq 'execute' }).Count -eq 1) -Name 'timeout_single_mutation_probe'

    $stage = 'ha_state_mismatch'
    $mismatch = Invoke-SmokeCase -Name $stage -Scenario @{ execute_failures = @(); mismatch_state_action = 'aircon_cool'; tracking_overrides = @{} }
    Assert-BaseProofSeparation -Case $mismatch
    Assert-Condition -Condition ([string]$mismatch.Result.state_results.aircon_cool -match 'mismatch') -Name 'mismatch_state_preserved'
    Assert-Condition -Condition ([int]$mismatch.Result.bounded_counts.checkstate_mismatch_count -gt 0) -Name 'mismatch_count_positive'
    Assert-Condition -Condition ([string]$mismatch.Result.target_results.aircon_cool_to_hvac_off.physical_proof_class -ceq 'not_claimed') -Name 'mismatch_not_physical'
    Assert-Condition -Condition (@($mismatch.Requests | Where-Object { $_.kind -ceq 'execute' }).Count -eq 8) -Name 'mismatch_mutation_probe_count'

    $stage = 'restore_failure_success'
    $restore = Invoke-SmokeCase -Name $stage -Scenario @{ execute_failures = @('door_close'); tracking_overrides = @{} }
    Assert-BaseProofSeparation -Case $restore
    Assert-Condition -Condition ([string]$restore.Result.target_results.aircon_cool_to_hvac_off.restore_class -ceq 'submitted') -Name 'restore_aircon_success'
    Assert-Condition -Condition ([string]$restore.Result.target_results.door_open_to_close.restore_class -ceq 'not_submitted') -Name 'restore_door_failure'
    Assert-Condition -Condition ([string]$restore.Result.target_results.vacuum_start_to_return.restore_class -ceq 'submitted') -Name 'restore_vacuum_success'
    Assert-Condition -Condition (@($restore.Requests | Where-Object { $_.kind -ceq 'execute' }).Count -eq 8) -Name 'restore_mutation_probe_count'

    $stage = 'tracking_state_disagreement'
    $disagreement = Invoke-SmokeCase -Name $stage -Scenario @{ execute_failures = @(); tracking_overrides = @{ door_open = 'ack_only' } }
    Assert-BaseProofSeparation -Case $disagreement
    Assert-Condition -Condition ([string]$disagreement.Result.tracking_results.door_open -ceq 'ack_only') -Name 'disagreement_tracking_ack_only'
    Assert-Condition -Condition ([string]$disagreement.Result.state_results.door_open -ceq 'matched') -Name 'disagreement_state_matched'
    Assert-Condition -Condition ([string]$disagreement.Result.target_results.door_open_to_close.physical_proof_class -ceq 'not_claimed') -Name 'disagreement_not_physical'
    Assert-Condition -Condition (@($disagreement.Requests | Where-Object { $_.kind -ceq 'execute' }).Count -eq 8) -Name 'disagreement_mutation_probe_count'

    $stage = 'camera_unavailable'
    $cameraUnavailable = Invoke-SmokeCase -Name $stage -Scenario @{ execute_failures = @(); tracking_overrides = @{ fan_on = 'fixture_private_tracking_marker' }; state_status_overrides = @{ aircon_cool = 'fixture_private_state_marker' } } -SkipCamera
    Assert-BaseProofSeparation -Case $cameraUnavailable
    Assert-Condition -Condition ([string]$cameraUnavailable.Result.target_results.light_stimulus.camera_environment_estimate_class -ceq 'unavailable') -Name 'camera_unavailable_class'
    Assert-Contains -Values @($cameraUnavailable.Result.target_results.light_stimulus.evidence_class) -Expected 'unavailable' -Name 'camera_unavailable_evidence'
    Assert-Condition -Condition ([string]$cameraUnavailable.Result.target_results.light_stimulus.physical_proof_class -ceq 'not_claimed') -Name 'camera_unavailable_not_physical'
    Assert-Condition -Condition ([string]$cameraUnavailable.Result.tracking_results.fan_on -ceq 'unavailable') -Name 'tracking_unknown_fail_closed'
    $cameraUnavailableSerialized = $cameraUnavailable.Result | ConvertTo-Json -Depth 20 -Compress
    Assert-Condition -Condition ($cameraUnavailableSerialized -notmatch 'fixture_private_tracking_marker') -Name 'tracking_unknown_not_published'
    Assert-Condition -Condition ([string]$cameraUnavailable.Result.state_results.aircon_cool -match '^unavailable(?:,unavailable)*$') -Name 'state_unknown_fail_closed'
    Assert-Condition -Condition ($cameraUnavailableSerialized -notmatch 'fixture_private_state_marker') -Name 'state_unknown_not_published'
    Assert-Condition -Condition (@($cameraUnavailable.Requests | Where-Object { $_.kind -ceq 'execute' }).Count -eq 8) -Name 'camera_unavailable_mutation_probe_count'

    Assert-Condition -Condition ($script:mutationProbeCount -eq 49) -Name 'aggregate_mutation_probe_count'
    Write-Output ('status=ok; cases={0}; assertions={1}; mutation_probes={2}; cleanup=fixture_residue_zero' -f $script:caseCount, $script:assertionCount, $script:mutationProbeCount)
}
catch {
    $failure = [string]$_.Exception.Message
    if ($failure -like 'assertion_failed=*') {
        [Console]::Error.WriteLine(('status=fail; stage={0}; {1}' -f $stage, $failure))
    }
    else {
        [Console]::Error.WriteLine(('status=fail; stage={0}; substage={1}; failure_class={2}' -f $stage, $script:lastOperationStage, $_.Exception.GetType().Name))
    }
    exit 1
}
