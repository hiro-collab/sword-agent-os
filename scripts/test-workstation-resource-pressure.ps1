[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:assertionCount = 0
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

function Assert-ExactSequence {
    param(
        [Parameter(Mandatory)]
        [object[]]$Actual,

        [Parameter(Mandatory)]
        [object[]]$Expected,

        [Parameter(Mandatory)]
        [string]$Name
    )

    Assert-Condition -Condition ($Actual.Count -eq $Expected.Count) -Name ($Name + '_count')
    if ($Actual.Count -ne $Expected.Count) {
        return
    }

    for ($index = 0; $index -lt $Expected.Count; $index++) {
        Assert-Condition -Condition ([string]$Actual[$index] -ceq [string]$Expected[$index]) -Name ('{0}_{1}' -f $Name, $index)
    }
}

function Get-PropertyNames {
    param(
        [Parameter(Mandatory)]
        [object]$InputObject
    )

    return @($InputObject.PSObject.Properties.Name)
}

function New-TestProcessSnapshotRow {
    param(
        [Parameter(Mandatory)]
        [int]$ProcessId,

        [Parameter(Mandatory)]
        [string]$ProcessName,

        [Parameter(Mandatory)]
        [double]$CpuSeconds,

        [Parameter(Mandatory)]
        [int64]$PrivateBytes,

        [Parameter(Mandatory)]
        [int64]$WorkingSetBytes
    )

    return [pscustomobject][ordered]@{
        pid               = $ProcessId
        process_name      = $ProcessName
        cpu_seconds       = $CpuSeconds
        private_bytes     = $PrivateBytes
        working_set_bytes = $WorkingSetBytes
    }
}

function New-TestProcessIdentity {
    param(
        [Parameter(Mandatory)]
        [int]$ProcessId,

        [Parameter(Mandatory)]
        [int]$ParentPid,

        [Parameter(Mandatory)]
        [string]$ProcessName
    )

    return [pscustomobject][ordered]@{
        process_id  = $ProcessId
        parent_pid  = $ParentPid
        process_name = $ProcessName
    }
}

function New-DeterministicPressureFixture {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$FirstSnapshot,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$SecondSnapshot,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$ProcessIdentities,

        [Parameter(Mandatory)]
        [int]$LogicalProcessorCount,

        [Parameter(Mandatory)]
        [int64]$CommittedBytes,

        [Parameter(Mandatory)]
        [int64]$CommitLimitBytes,

        [Parameter(Mandatory)]
        [double]$PercentCommittedBytesInUse,

        [Parameter(Mandatory)]
        [int64]$TotalVisibleMemoryKilobytes,

        [Parameter(Mandatory)]
        [int64]$FreePhysicalMemoryKilobytes
    )

    return [pscustomobject][ordered]@{
        first_snapshot                  = @($FirstSnapshot)
        second_snapshot                 = @($SecondSnapshot)
        process_identities              = @($ProcessIdentities)
        logical_processor_count         = $LogicalProcessorCount
        committed_bytes                 = $CommittedBytes
        commit_limit_bytes              = $CommitLimitBytes
        percent_committed_bytes_in_use  = $PercentCommittedBytesInUse
        total_visible_memory_kilobytes  = $TotalVisibleMemoryKilobytes
        free_physical_memory_kilobytes  = $FreePhysicalMemoryKilobytes
    }
}

function Invoke-DeterministicPressureFixture {
    param(
        [Parameter(Mandatory)]
        [string]$PowerShellPath,

        [Parameter(Mandatory)]
        [string]$HarnessPath,

        [Parameter(Mandatory)]
        [string]$FixturePath,

        [Parameter(Mandatory)]
        [string]$ErrorPath,

        [Parameter(Mandatory)]
        [string]$UtilityPath,

        [Parameter(Mandatory)]
        [object]$Fixture
    )

    $Fixture |
        ConvertTo-Json -Depth 10 |
        Set-Content -LiteralPath $FixturePath -Encoding utf8NoBOM

    $childOutput = @(
        & $PowerShellPath -NoProfile -File $HarnessPath `
            -UtilityPath $UtilityPath `
            -FixturePath $FixturePath `
            2> $ErrorPath
    )
    $childExitCode = $LASTEXITCODE
    $childErrorLength = if (Test-Path -LiteralPath $ErrorPath -PathType Leaf) {
        [int64](Get-Item -LiteralPath $ErrorPath -Force).Length
    }
    else {
        [int64]0
    }
    if ($childExitCode -ne 0 -or $childErrorLength -ne 0) {
        $expectedFailureEnvelope = 'fixture_error_class=fixture_execution_failed;error_id=fixture_execution_failed'
        $reportedFixedFailure = $false
        if ($childErrorLength -gt 0 -and $childErrorLength -le 160) {
            $reportedFixedFailure = (
                (Get-Content -Raw -LiteralPath $ErrorPath).Trim() -ceq
                $expectedFailureEnvelope
            )
        }
        if ($reportedFixedFailure) {
            throw 'assertion_failed=deterministic_fixture_child_reported_failure'
        }
        throw 'assertion_failed=deterministic_fixture_child_failed'
    }

    return (($childOutput -join [Environment]::NewLine) | ConvertFrom-Json)
}

function Assert-NonReparseDirectoryAncestorChain {
    param(
        [Parameter(Mandatory)]
        [string]$DirectoryPath,

        [scriptblock]$ItemResolver = {
            param([string]$LiteralPath)
            Get-Item -LiteralPath $LiteralPath -Force
        }
    )

    $currentItem = & $ItemResolver $DirectoryPath
    if ($null -eq $currentItem -or -not [bool]$currentItem.PSIsContainer) {
        throw 'deterministic_fixture_ancestor_not_directory'
    }

    $visitedPaths = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )
    while ($null -ne $currentItem) {
        $currentPath = [string]$currentItem.FullName
        if ([string]::IsNullOrWhiteSpace($currentPath) -or -not $visitedPaths.Add($currentPath)) {
            throw 'deterministic_fixture_ancestor_chain_invalid'
        }
        if (($currentItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'deterministic_fixture_ancestor_reparse'
        }
        $currentItem = $currentItem.Parent
    }
}

function Assert-DeterministicFixtureParentSafe {
    param(
        [Parameter(Mandatory)]
        [string]$RepositoryRoot,

        [Parameter(Mandatory)]
        [string]$FixtureParent
    )

    Assert-NonReparseDirectoryAncestorChain -DirectoryPath $RepositoryRoot
    Assert-NonReparseDirectoryAncestorChain -DirectoryPath $FixtureParent

    $repositoryItem = Get-Item -LiteralPath $RepositoryRoot -Force
    $parentItem = Get-Item -LiteralPath $FixtureParent -Force
    $expectedParentPath = [IO.Path]::GetFullPath(
        (Join-Path $repositoryItem.FullName '.tmp')
    )
    if ([IO.Path]::GetFullPath($parentItem.FullName) -cne $expectedParentPath) {
        throw 'deterministic_fixture_parent_path_invalid'
    }
    if ($null -eq $parentItem.Parent -or $parentItem.Parent.FullName -cne $repositoryItem.FullName) {
        throw 'deterministic_fixture_parent_relation_invalid'
    }
}

function Remove-OwnedDeterministicFixtureRoot {
    param(
        [Parameter(Mandatory)]
        [string]$RootPath,

        [Parameter(Mandatory)]
        [string]$ExpectedRunId,

        [Parameter(Mandatory)]
        [string]$ExpectedParent,

        [Parameter(Mandatory)]
        [string]$ExpectedRepositoryRoot,

        [Parameter(Mandatory)]
        [bool]$MarkerWasCreated
    )

    if (-not (Test-Path -LiteralPath $RootPath -PathType Container)) {
        return
    }

    Assert-DeterministicFixtureParentSafe `
        -RepositoryRoot $ExpectedRepositoryRoot `
        -FixtureParent $ExpectedParent

    $rootItem = Get-Item -LiteralPath $RootPath -Force
    if ($rootItem.Parent.FullName -cne $ExpectedParent) {
        throw 'deterministic_fixture_root_outside_parent'
    }
    if ($rootItem.Name -cne ('workstation-pressure-fixture-{0}' -f $ExpectedRunId)) {
        throw 'deterministic_fixture_root_name_invalid'
    }
    if (($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'deterministic_fixture_root_reparse'
    }

    if (-not $MarkerWasCreated) {
        $unmarkedEntries = @(Get-ChildItem -LiteralPath $RootPath -Force)
        if ($unmarkedEntries.Count -ne 0) {
            throw 'deterministic_fixture_unmarked_root_not_empty'
        }
        Remove-Item -LiteralPath $RootPath -Force
        if (Test-Path -LiteralPath $RootPath) {
            throw 'deterministic_fixture_cleanup_incomplete'
        }
        return
    }

    $markerPath = Join-Path $RootPath '.owned-fixture'
    if (-not (Test-Path -LiteralPath $markerPath -PathType Leaf)) {
        throw 'deterministic_fixture_marker_missing'
    }
    $markerValue = (Get-Content -Raw -LiteralPath $markerPath).Trim()
    if ($markerValue -cne $ExpectedRunId) {
        throw 'deterministic_fixture_marker_mismatch'
    }

    $reparseEntries = @(
        Get-ChildItem -LiteralPath $RootPath -Force -Recurse |
            Where-Object {
                ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0
            }
    )
    if ($reparseEntries.Count -ne 0) {
        throw 'deterministic_fixture_child_reparse'
    }

    Remove-Item -LiteralPath $RootPath -Recurse -Force
    if (Test-Path -LiteralPath $RootPath) {
        throw 'deterministic_fixture_cleanup_incomplete'
    }
}

try {
    $utilityPath = Join-Path -Path $PSScriptRoot -ChildPath 'get-workstation-resource-pressure.ps1'
    $testPath = $PSCommandPath

    $stage = 'parse'
    foreach ($pathToParse in @($utilityPath, $testPath)) {
        $tokens = $null
        $parseErrors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile(
            $pathToParse,
            [ref]$tokens,
            [ref]$parseErrors
        )
        Assert-Condition -Condition (@($parseErrors).Count -eq 0) -Name 'source_parse'
    }

    $stage = 'static_source'
    $utilitySource = [System.IO.File]::ReadAllText($utilityPath)
    $forbiddenSourceTerms = @(
        'CommandLine'
        'ExecutablePath'
        'MainWindowTitle'
        'Stop-Process'
        'Start-Process'
        'Set-Content'
        'Add-Content'
        'Out-File'
        'Start-Transcript'
    )
    foreach ($term in $forbiddenSourceTerms) {
        Assert-Condition -Condition ($utilitySource -notmatch [regex]::Escape($term)) -Name 'static_source_surface'
    }

    $stage = 'deterministic_fixture_setup'
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $fixtureParent = Join-Path $repoRoot '.tmp'
    $fixtureRunId = [Guid]::NewGuid().ToString('N')
    $fixtureRoot = Join-Path $fixtureParent ('workstation-pressure-fixture-{0}' -f $fixtureRunId)
    $fixtureRootCreated = $false
    $fixtureMarkerCreated = $false
    $fixturePath = Join-Path $fixtureRoot 'fixture.json'
    $fixtureErrorPath = Join-Path $fixtureRoot 'child.err'
    $fixtureHarnessPath = Join-Path $fixtureRoot 'invoke-fixture.ps1'
    $fixtureFailureHarnessPath = Join-Path $fixtureRoot 'invoke-fixture-failure.ps1'
    $fixturePowerShellPath = Join-Path $PSHOME 'pwsh.exe'
    if (-not (Test-Path -LiteralPath $fixturePowerShellPath -PathType Leaf)) {
        throw 'deterministic_fixture_powershell_missing'
    }

    try {
        Assert-NonReparseDirectoryAncestorChain -DirectoryPath $repoRoot
        if (-not (Test-Path -LiteralPath $fixtureParent)) {
            [void](New-Item -ItemType Directory -Path $fixtureParent)
        }
        Assert-DeterministicFixtureParentSafe `
            -RepositoryRoot $repoRoot `
            -FixtureParent $fixtureParent

        $fakeReparseItem = [pscustomobject]@{
            PSIsContainer = $true
            FullName      = 'C:\synthetic-reparse'
            Attributes    = [IO.FileAttributes]::ReparsePoint
            Parent        = $null
        }
        $fakeReparseResolver = {
            param([string]$LiteralPath)
            return $fakeReparseItem
        }.GetNewClosure()
        $reparseMutationRejected = $false
        try {
            Assert-NonReparseDirectoryAncestorChain `
                -DirectoryPath 'C:\synthetic-reparse' `
                -ItemResolver $fakeReparseResolver
        }
        catch {
            $reparseMutationRejected = (
                [string]$_.Exception.Message -ceq
                'deterministic_fixture_ancestor_reparse'
            )
        }
        Assert-Condition -Condition $reparseMutationRejected -Name 'deterministic_fixture_parent_reparse_rejected'

        $preMarkerRunId = [Guid]::NewGuid().ToString('N')
        $preMarkerRoot = Join-Path $fixtureParent ('workstation-pressure-fixture-{0}' -f $preMarkerRunId)
        $preMarkerCreated = $false
        $preMarkerFailureObserved = $false
        try {
            Assert-DeterministicFixtureParentSafe `
                -RepositoryRoot $repoRoot `
                -FixtureParent $fixtureParent
            [void](New-Item -ItemType Directory -Path $preMarkerRoot)
            $preMarkerCreated = $true
            throw 'deterministic_fixture_setup_failure_probe'
        }
        catch {
            $preMarkerFailureObserved = (
                [string]$_.Exception.Message -ceq
                'deterministic_fixture_setup_failure_probe'
            )
        }
        finally {
            if ($preMarkerCreated) {
                Remove-OwnedDeterministicFixtureRoot `
                    -RootPath $preMarkerRoot `
                    -ExpectedRunId $preMarkerRunId `
                    -ExpectedParent $fixtureParent `
                    -ExpectedRepositoryRoot $repoRoot `
                    -MarkerWasCreated $false
            }
        }
        Assert-Condition -Condition $preMarkerFailureObserved -Name 'deterministic_fixture_pre_marker_failure_observed'
        Assert-Condition -Condition (-not (Test-Path -LiteralPath $preMarkerRoot)) -Name 'deterministic_fixture_pre_marker_cleanup'

        Assert-DeterministicFixtureParentSafe `
            -RepositoryRoot $repoRoot `
            -FixtureParent $fixtureParent
        [void](New-Item -ItemType Directory -Path $fixtureRoot)
        $fixtureRootCreated = $true
        Set-Content -LiteralPath (Join-Path $fixtureRoot '.owned-fixture') -Value $fixtureRunId -Encoding ascii -NoNewline
        $fixtureMarkerCreated = $true

    $fixtureHarness = @'
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$UtilityPath,

    [Parameter(Mandatory)]
    [string]$FixturePath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$global:pressureFixture = Get-Content -Raw -LiteralPath $FixturePath | ConvertFrom-Json
$global:pressureProcessCallCount = 0

function global:Get-Process {
    [CmdletBinding()]
    param()

    $global:pressureProcessCallCount++
    $rows = if ($global:pressureProcessCallCount -eq 1) {
        @($global:pressureFixture.first_snapshot)
    }
    else {
        @($global:pressureFixture.second_snapshot)
    }

    foreach ($row in $rows) {
        [pscustomobject]@{
            Id                  = [int]$row.pid
            ProcessName         = [string]$row.process_name
            CPU                 = [double]$row.cpu_seconds
            PrivateMemorySize64 = [int64]$row.private_bytes
            WorkingSet64        = [int64]$row.working_set_bytes
        }
    }
}

function global:Get-CimInstance {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ClassName,

        [Parameter()]
        [string[]]$Property
    )

    switch -CaseSensitive ($ClassName) {
        'Win32_ComputerSystem' {
            return [pscustomobject]@{
                NumberOfLogicalProcessors = [int]$global:pressureFixture.logical_processor_count
            }
        }
        'Win32_Process' {
            return @(
                foreach ($row in @($global:pressureFixture.process_identities)) {
                    [pscustomobject]@{
                        ProcessId       = [int]$row.process_id
                        ParentProcessId = [int]$row.parent_pid
                        Name            = [string]$row.process_name
                    }
                }
            )
        }
        'Win32_OperatingSystem' {
            return [pscustomobject]@{
                TotalVisibleMemorySize = [int64]$global:pressureFixture.total_visible_memory_kilobytes
                FreePhysicalMemory     = [int64]$global:pressureFixture.free_physical_memory_kilobytes
            }
        }
        'Win32_PerfFormattedData_PerfOS_Memory' {
            return [pscustomobject]@{
                CommittedBytes             = [int64]$global:pressureFixture.committed_bytes
                CommitLimit                = [int64]$global:pressureFixture.commit_limit_bytes
                PercentCommittedBytesInUse = [double]$global:pressureFixture.percent_committed_bytes_in_use
            }
        }
        default {
            throw 'deterministic_fixture_cim_class_invalid'
        }
    }
}

function global:Start-Sleep {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [int]$Milliseconds
    )

    [Threading.Thread]::Sleep(500)
}

try {
    & $UtilityPath -SampleIntervalSeconds 0.25 -Json
}
catch {
    [Console]::Error.WriteLine(
        'fixture_error_class=fixture_execution_failed;error_id=fixture_execution_failed'
    )
    exit 1
}
'@
    Set-Content -LiteralPath $fixtureHarnessPath -Value $fixtureHarness -Encoding utf8NoBOM

        $rawFailureHarness = @'
param(
    [Parameter(Mandatory)]
    [string]$UtilityPath,

    [Parameter(Mandatory)]
    [string]$FixturePath
)

[Console]::Error.WriteLine('C:\private\identity\process.exe token_secret')
exit 1
'@
        Set-Content -LiteralPath $fixtureFailureHarnessPath -Value $rawFailureHarness -Encoding utf8NoBOM
        $rawFailureClass = $null
        try {
            $null = Invoke-DeterministicPressureFixture `
                -PowerShellPath $fixturePowerShellPath `
                -HarnessPath $fixtureFailureHarnessPath `
                -FixturePath $fixturePath `
                -ErrorPath $fixtureErrorPath `
                -UtilityPath $utilityPath `
                -Fixture ([pscustomobject]@{ probe = $true })
        }
        catch {
            $rawFailureClass = [string]$_.Exception.Message
        }
        Assert-Condition `
            -Condition ($rawFailureClass -ceq 'assertion_failed=deterministic_fixture_child_failed') `
            -Name 'deterministic_fixture_raw_stderr_non_echo'

        $stage = 'deterministic_calculation_contract'
        $firstSnapshot = @(
            (New-TestProcessSnapshotRow -ProcessId 100 -ProcessName 'node' -CpuSeconds 10.0 -PrivateBytes 1000 -WorkingSetBytes 1500)
            (New-TestProcessSnapshotRow -ProcessId 101 -ProcessName 'chrome' -CpuSeconds 5.0 -PrivateBytes 2000 -WorkingSetBytes 2500)
            (New-TestProcessSnapshotRow -ProcessId 102 -ProcessName 'oldname' -CpuSeconds 1.0 -PrivateBytes 500 -WorkingSetBytes 600)
            (New-TestProcessSnapshotRow -ProcessId 140 -ProcessName 'node' -CpuSeconds 0.0 -PrivateBytes 100 -WorkingSetBytes 200)
            (New-TestProcessSnapshotRow -ProcessId 141 -ProcessName 'node' -CpuSeconds 10.0 -PrivateBytes 2000 -WorkingSetBytes 2200)
        )
        $secondSnapshot = @(
            (New-TestProcessSnapshotRow -ProcessId 100 -ProcessName 'node' -CpuSeconds 10.4 -PrivateBytes 1400 -WorkingSetBytes 1600)
            (New-TestProcessSnapshotRow -ProcessId 102 -ProcessName 'codex' -CpuSeconds 9.0 -PrivateBytes 700 -WorkingSetBytes 800)
            (New-TestProcessSnapshotRow -ProcessId 103 -ProcessName 'touchdesigner' -CpuSeconds 1.0 -PrivateBytes 3000 -WorkingSetBytes 3300)
            (New-TestProcessSnapshotRow -ProcessId 104 -ProcessName 'node' -CpuSeconds 0.0 -PrivateBytes 100 -WorkingSetBytes 120)
            (New-TestProcessSnapshotRow -ProcessId 105 -ProcessName 'node' -CpuSeconds 0.0 -PrivateBytes 110 -WorkingSetBytes 130)
            (New-TestProcessSnapshotRow -ProcessId 106 -ProcessName 'node' -CpuSeconds 0.0 -PrivateBytes 120 -WorkingSetBytes 140)
            (New-TestProcessSnapshotRow -ProcessId 110 -ProcessName 'node' -CpuSeconds 0.0 -PrivateBytes 130 -WorkingSetBytes 150)
            (New-TestProcessSnapshotRow -ProcessId 120 -ProcessName 'node' -CpuSeconds 0.0 -PrivateBytes 140 -WorkingSetBytes 160)
            (New-TestProcessSnapshotRow -ProcessId 140 -ProcessName 'node' -CpuSeconds 999.0 -PrivateBytes 200 -WorkingSetBytes 300)
            (New-TestProcessSnapshotRow -ProcessId 141 -ProcessName 'node' -CpuSeconds 5.0 -PrivateBytes 1000 -WorkingSetBytes 1200)
        )
        $identities = @(
            (New-TestProcessIdentity -ProcessId 100 -ParentPid 0 -ProcessName 'node.exe')
            (New-TestProcessIdentity -ProcessId 102 -ParentPid 0 -ProcessName 'codex.exe')
            (New-TestProcessIdentity -ProcessId 103 -ParentPid 0 -ProcessName 'touchdesigner.exe')
            (New-TestProcessIdentity -ProcessId 104 -ParentPid 200 -ProcessName 'node.exe')
            (New-TestProcessIdentity -ProcessId 200 -ParentPid 0 -ProcessName 'chrome.exe')
            (New-TestProcessIdentity -ProcessId 105 -ParentPid 999 -ProcessName 'node.exe')
            (New-TestProcessIdentity -ProcessId 106 -ParentPid 107 -ProcessName 'node.exe')
            (New-TestProcessIdentity -ProcessId 107 -ParentPid 106 -ProcessName 'pwsh.exe')
            (New-TestProcessIdentity -ProcessId 110 -ParentPid 111 -ProcessName 'node.exe')
            (New-TestProcessIdentity -ProcessId 111 -ParentPid 112 -ProcessName 'helper.exe')
            (New-TestProcessIdentity -ProcessId 112 -ParentPid 113 -ProcessName 'helper.exe')
            (New-TestProcessIdentity -ProcessId 113 -ParentPid 114 -ProcessName 'helper.exe')
            (New-TestProcessIdentity -ProcessId 114 -ParentPid 115 -ProcessName 'helper.exe')
            (New-TestProcessIdentity -ProcessId 115 -ParentPid 116 -ProcessName 'helper.exe')
            (New-TestProcessIdentity -ProcessId 116 -ParentPid 117 -ProcessName 'helper.exe')
            (New-TestProcessIdentity -ProcessId 117 -ParentPid 118 -ProcessName 'helper.exe')
            (New-TestProcessIdentity -ProcessId 118 -ParentPid 0 -ProcessName 'chrome.exe')
            (New-TestProcessIdentity -ProcessId 120 -ParentPid 121 -ProcessName 'node.exe')
            (New-TestProcessIdentity -ProcessId 121 -ParentPid 122 -ProcessName 'helper.exe')
            (New-TestProcessIdentity -ProcessId 122 -ParentPid 123 -ProcessName 'helper.exe')
            (New-TestProcessIdentity -ProcessId 123 -ParentPid 124 -ProcessName 'helper.exe')
            (New-TestProcessIdentity -ProcessId 124 -ParentPid 125 -ProcessName 'helper.exe')
            (New-TestProcessIdentity -ProcessId 125 -ParentPid 126 -ProcessName 'helper.exe')
            (New-TestProcessIdentity -ProcessId 126 -ParentPid 127 -ProcessName 'helper.exe')
            (New-TestProcessIdentity -ProcessId 127 -ParentPid 128 -ProcessName 'helper.exe')
            (New-TestProcessIdentity -ProcessId 128 -ParentPid 129 -ProcessName 'helper.exe')
            (New-TestProcessIdentity -ProcessId 129 -ParentPid 0 -ProcessName 'chrome.exe')
            (New-TestProcessIdentity -ProcessId 140 -ParentPid 0 -ProcessName 'node.exe')
            (New-TestProcessIdentity -ProcessId 141 -ParentPid 0 -ProcessName 'node.exe')
        )
        $calculationFixture = New-DeterministicPressureFixture `
            -FirstSnapshot $firstSnapshot `
            -SecondSnapshot $secondSnapshot `
            -ProcessIdentities $identities `
            -LogicalProcessorCount 4 `
            -CommittedBytes 800000 `
            -CommitLimitBytes 1000000 `
            -PercentCommittedBytesInUse 1.0 `
            -TotalVisibleMemoryKilobytes 1000 `
            -FreePhysicalMemoryKilobytes 250
        $deterministicReport = Invoke-DeterministicPressureFixture `
            -PowerShellPath $fixturePowerShellPath `
            -HarnessPath $fixtureHarnessPath `
            -FixturePath $fixturePath `
            -ErrorPath $fixtureErrorPath `
            -UtilityPath $utilityPath `
            -Fixture $calculationFixture

        Assert-Condition -Condition ([double]$deterministicReport.sample_interval_seconds_requested -eq 0.25) -Name 'deterministic_requested_interval'
        Assert-Condition -Condition ([double]$deterministicReport.sample_elapsed_seconds -ge 0.45) -Name 'deterministic_elapsed_distinct_from_requested'
        Assert-Condition -Condition ([double]$deterministicReport.system.committed_memory_percent -eq 80.0) -Name 'deterministic_committed_formula'
        Assert-Condition -Condition ([double]$deterministicReport.system.physical_memory_used_percent -eq 75.0) -Name 'deterministic_physical_formula'
        Assert-Condition -Condition ([string]$deterministicReport.admission_class -ceq 'green') -Name 'deterministic_admission_exact_80'
        Assert-Condition -Condition (@($deterministicReport.processes | Where-Object { [int]$_.pid -eq 101 }).Count -eq 0) -Name 'deterministic_disappeared_process_absent'

        $sameProcess = @($deterministicReport.processes | Where-Object { [int]$_.pid -eq 100 })
        Assert-Condition -Condition ($sameProcess.Count -eq 1) -Name 'deterministic_same_process_present'
        $expectedCpu = [Math]::Round(
            (0.4 / [double]$deterministicReport.sample_elapsed_seconds / 4.0) * 100.0,
            3
        )
        Assert-Condition -Condition ([Math]::Abs([double]$sameProcess[0].cpu_percent - $expectedCpu) -lt 0.25) -Name 'deterministic_cpu_normalization'
        $requestedIntervalCpu = (0.4 / 0.25 / 4.0) * 100.0
        Assert-Condition -Condition ([Math]::Abs([double]$sameProcess[0].cpu_percent - $requestedIntervalCpu) -gt 5.0) -Name 'deterministic_cpu_rejects_requested_interval'
        Assert-Condition -Condition ([int64]$sameProcess[0].private_memory_growth_bytes -eq 400) -Name 'deterministic_private_growth'

        $reusedProcess = @($deterministicReport.processes | Where-Object { [int]$_.pid -eq 102 })
        Assert-Condition -Condition ([double]$reusedProcess[0].cpu_percent -eq 0.0) -Name 'deterministic_reused_pid_cpu_reset'
        Assert-Condition -Condition ([int64]$reusedProcess[0].private_memory_growth_bytes -eq 0) -Name 'deterministic_reused_pid_growth_reset'
        Assert-Condition -Condition ([string]$reusedProcess[0].owner_family -ceq 'Codex') -Name 'deterministic_direct_owner'

        $appearedProcess = @($deterministicReport.processes | Where-Object { [int]$_.pid -eq 103 })
        Assert-Condition -Condition ([double]$appearedProcess[0].cpu_percent -eq 0.0) -Name 'deterministic_appeared_cpu_zero'
        Assert-Condition -Condition ([int64]$appearedProcess[0].private_memory_growth_bytes -eq 0) -Name 'deterministic_appeared_growth_zero'
        Assert-Condition -Condition ([string]$appearedProcess[0].owner_family -ceq 'TouchDesigner') -Name 'deterministic_appeared_owner'

        $ancestorOwned = @($deterministicReport.processes | Where-Object { [int]$_.pid -eq 104 })
        $missingParent = @($deterministicReport.processes | Where-Object { [int]$_.pid -eq 105 })
        $cycleOwned = @($deterministicReport.processes | Where-Object { [int]$_.pid -eq 106 })
        $depthBoundary = @($deterministicReport.processes | Where-Object { [int]$_.pid -eq 110 })
        $beyondDepth = @($deterministicReport.processes | Where-Object { [int]$_.pid -eq 120 })
        Assert-Condition -Condition ([string]$ancestorOwned[0].owner_family -ceq 'browser') -Name 'deterministic_ancestor_owner'
        Assert-Condition -Condition ([string]$missingParent[0].owner_family -ceq 'development tooling') -Name 'deterministic_missing_parent_fallback'
        Assert-Condition -Condition ([string]$cycleOwned[0].owner_family -ceq 'development tooling') -Name 'deterministic_cycle_fallback'
        Assert-Condition -Condition ([string]$depthBoundary[0].owner_family -ceq 'browser') -Name 'deterministic_depth_boundary_owner'
        Assert-Condition -Condition ([string]$beyondDepth[0].owner_family -ceq 'development tooling') -Name 'deterministic_beyond_depth_fallback'

        $cpuMaximum = @($deterministicReport.processes | Where-Object { [int]$_.pid -eq 140 })
        $cpuMinimum = @($deterministicReport.processes | Where-Object { [int]$_.pid -eq 141 })
        Assert-Condition -Condition ([double]$cpuMaximum[0].cpu_percent -eq 100.0) -Name 'deterministic_cpu_maximum_clamp'
        Assert-Condition -Condition ([double]$cpuMinimum[0].cpu_percent -eq 0.0) -Name 'deterministic_cpu_minimum_clamp'
        Assert-Condition -Condition ([int64]$cpuMinimum[0].private_memory_growth_bytes -eq 0) -Name 'deterministic_growth_minimum_clamp'

        $deterministicProcesses = @($deterministicReport.processes)
        $deterministicGroups = @($deterministicReport.groups)
        foreach ($metricName in @(
            'private_bytes'
            'working_set_bytes'
            'cpu_percent'
            'private_memory_growth_bytes'
        )) {
            foreach ($groupName in @($deterministicReport.group_order)) {
                $groupRow = @($deterministicGroups | Where-Object { [string]$_.group_name -ceq [string]$groupName })
                $members = @($deterministicProcesses | Where-Object { [string]$_.group -ceq [string]$groupName })
                $expectedMetric = [double]0.0
                foreach ($member in $members) {
                    $expectedMetric += [double]$member.$metricName
                }
                Assert-Condition -Condition ([Math]::Abs([double]$groupRow[0].$metricName - $expectedMetric) -lt 0.001) -Name ('deterministic_group_total_{0}' -f $metricName)
            }
        }
        $expectedPrivateTotal = [int64]0
        foreach ($row in $deterministicProcesses) {
            $expectedPrivateTotal += [int64]$row.private_bytes
        }
        Assert-Condition -Condition ([int64]$deterministicReport.system.process_attributable_private_bytes -eq $expectedPrivateTotal) -Name 'deterministic_system_private_total'
        Assert-Condition -Condition ([int64]$deterministicReport.system.non_attributed_committed_gap_bytes -eq (800000L - $expectedPrivateTotal)) -Name 'deterministic_non_attributed_gap'

        $zeroMemberGroup = @($deterministicGroups | Where-Object { [string]$_.group_name -ceq 'ChatGPT' })
        Assert-Condition -Condition ($zeroMemberGroup.Count -eq 1) -Name 'deterministic_zero_member_group_present'
        Assert-Condition -Condition ([int]$zeroMemberGroup[0].process_count -eq 0) -Name 'deterministic_zero_member_group_count'
        Assert-Condition -Condition ([int64]$zeroMemberGroup[0].private_bytes -eq 0) -Name 'deterministic_zero_member_private'
        Assert-Condition -Condition ([double]$zeroMemberGroup[0].cpu_percent -eq 0.0) -Name 'deterministic_zero_member_cpu'

        $stage = 'deterministic_threshold_contract'
        $emptySnapshots = @()
        $thresholdCases = @(
            [pscustomobject]@{ committed = 800; limit = 1000; expected_percent = 80.0; expected_class = 'green' }
            [pscustomobject]@{ committed = 801; limit = 1000; expected_percent = 80.1; expected_class = 'caution' }
            [pscustomobject]@{ committed = 850; limit = 1000; expected_percent = 85.0; expected_class = 'hold' }
        )
        foreach ($thresholdCase in $thresholdCases) {
            $thresholdFixture = New-DeterministicPressureFixture `
                -FirstSnapshot $emptySnapshots `
                -SecondSnapshot $emptySnapshots `
                -ProcessIdentities $emptySnapshots `
                -LogicalProcessorCount 0 `
                -CommittedBytes $thresholdCase.committed `
                -CommitLimitBytes $thresholdCase.limit `
                -PercentCommittedBytesInUse 1.0 `
                -TotalVisibleMemoryKilobytes 1000 `
                -FreePhysicalMemoryKilobytes 500
            $thresholdReport = Invoke-DeterministicPressureFixture `
                -PowerShellPath $fixturePowerShellPath `
                -HarnessPath $fixtureHarnessPath `
                -FixturePath $fixturePath `
                -ErrorPath $fixtureErrorPath `
                -UtilityPath $utilityPath `
                -Fixture $thresholdFixture
            Assert-Condition -Condition ([double]$thresholdReport.system.committed_memory_percent -eq [double]$thresholdCase.expected_percent) -Name 'deterministic_threshold_percent'
            Assert-Condition -Condition ([string]$thresholdReport.admission_class -ceq [string]$thresholdCase.expected_class) -Name 'deterministic_threshold_class'
            Assert-Condition -Condition ([int]$thresholdReport.logical_processor_count -eq 1) -Name 'deterministic_logical_processor_floor'
            Assert-Condition -Condition (@($thresholdReport.processes).Count -eq 0) -Name 'deterministic_empty_processes'
        }

        $fallbackFixture = New-DeterministicPressureFixture `
            -FirstSnapshot $emptySnapshots `
            -SecondSnapshot $emptySnapshots `
            -ProcessIdentities $emptySnapshots `
            -LogicalProcessorCount 2 `
            -CommittedBytes 123 `
            -CommitLimitBytes 0 `
            -PercentCommittedBytesInUse 42.5 `
            -TotalVisibleMemoryKilobytes 0 `
            -FreePhysicalMemoryKilobytes 0
        $fallbackReport = Invoke-DeterministicPressureFixture `
            -PowerShellPath $fixturePowerShellPath `
            -HarnessPath $fixtureHarnessPath `
            -FixturePath $fixturePath `
            -ErrorPath $fixtureErrorPath `
            -UtilityPath $utilityPath `
            -Fixture $fallbackFixture
        Assert-Condition -Condition ([double]$fallbackReport.system.committed_memory_percent -eq 42.5) -Name 'deterministic_commit_limit_zero_fallback'
        Assert-Condition -Condition ([double]$fallbackReport.system.physical_memory_used_percent -eq 0.0) -Name 'deterministic_physical_total_zero_fallback'
        Assert-Condition -Condition ([int64]$fallbackReport.system.non_attributed_committed_gap_bytes -eq 123) -Name 'deterministic_empty_process_gap'
    }
    finally {
        if ($fixtureRootCreated) {
            Remove-OwnedDeterministicFixtureRoot `
                -RootPath $fixtureRoot `
                -ExpectedRunId $fixtureRunId `
                -ExpectedParent $fixtureParent `
                -ExpectedRepositoryRoot $repoRoot `
                -MarkerWasCreated $fixtureMarkerCreated
        }
    }

    $stage = 'json_execution'
    $jsonCapture = @(& $utilityPath -SampleIntervalSeconds 0.25 -Json)
    Assert-Condition -Condition ($jsonCapture.Count -gt 0) -Name 'json_capture'
    $report = ($jsonCapture -join [Environment]::NewLine) | ConvertFrom-Json

    $stage = 'schema'
    $rootProperties = @(Get-PropertyNames -InputObject $report)
    foreach ($requiredRootProperty in @(
        'schema_version'
        'sampled_at_utc'
        'sample_interval_seconds_requested'
        'sample_elapsed_seconds'
        'logical_processor_count'
        'admission_class'
        'system'
        'group_order'
        'groups'
        'processes'
    )) {
        Assert-Condition -Condition ($rootProperties -contains $requiredRootProperty) -Name 'root_schema'
    }

    Assert-Condition -Condition ([int]$report.schema_version -eq 1) -Name 'schema_version'
    Assert-Condition -Condition ([Math]::Abs([double]$report.sample_interval_seconds_requested - 0.25) -lt 0.001) -Name 'sample_interval'
    Assert-Condition -Condition ([double]$report.sample_elapsed_seconds -ge 0.20) -Name 'sample_elapsed'
    Assert-Condition -Condition ([double]$report.logical_processor_count -ge 1.0) -Name 'logical_processor_minimum'
    Assert-Condition -Condition ([double]$report.logical_processor_count -eq [Math]::Floor([double]$report.logical_processor_count)) -Name 'logical_processor_integer'

    $systemProperties = @(Get-PropertyNames -InputObject $report.system)
    foreach ($requiredSystemProperty in @(
        'committed_bytes'
        'commit_limit_bytes'
        'committed_memory_percent'
        'physical_total_bytes'
        'physical_available_bytes'
        'physical_memory_used_percent'
        'process_attributable_private_bytes'
        'non_attributed_committed_gap_bytes'
        'non_attributed_committed_gap_is_approximate'
    )) {
        Assert-Condition -Condition ($systemProperties -contains $requiredSystemProperty) -Name 'system_schema'
    }

    Assert-Condition -Condition ([int64]$report.system.committed_bytes -ge 0) -Name 'committed_bytes'
    Assert-Condition -Condition ([int64]$report.system.commit_limit_bytes -gt 0) -Name 'commit_limit_bytes'
    Assert-Condition -Condition ([int64]$report.system.committed_bytes -le [int64]$report.system.commit_limit_bytes) -Name 'committed_within_limit'
    Assert-Condition -Condition ([double]$report.system.committed_memory_percent -ge 0.0) -Name 'committed_percent_minimum'
    Assert-Condition -Condition ([double]$report.system.committed_memory_percent -le 100.0) -Name 'committed_percent_maximum'
    Assert-Condition -Condition ([int64]$report.system.physical_total_bytes -gt 0) -Name 'physical_total_bytes'
    Assert-Condition -Condition ([int64]$report.system.physical_available_bytes -ge 0) -Name 'physical_available_minimum'
    Assert-Condition -Condition ([int64]$report.system.physical_available_bytes -le [int64]$report.system.physical_total_bytes) -Name 'physical_available_maximum'
    Assert-Condition -Condition ([double]$report.system.physical_memory_used_percent -ge 0.0) -Name 'physical_percent_minimum'
    Assert-Condition -Condition ([double]$report.system.physical_memory_used_percent -le 100.0) -Name 'physical_percent_maximum'
    Assert-Condition -Condition ([int64]$report.system.process_attributable_private_bytes -ge 0) -Name 'process_private_total'
    Assert-Condition -Condition ([int64]$report.system.non_attributed_committed_gap_bytes -ge 0) -Name 'non_attributed_gap'
    Assert-Condition -Condition ([bool]$report.system.non_attributed_committed_gap_is_approximate) -Name 'gap_is_approximate'

    $validAdmissionClasses = @('green', 'caution', 'hold')
    Assert-Condition -Condition ($validAdmissionClasses -ccontains [string]$report.admission_class) -Name 'admission_class'
    $committedPercent = [double]$report.system.committed_memory_percent
    $expectedAdmissionClass = if ($committedPercent -ge 85.0) {
        'hold'
    }
    elseif ($committedPercent -gt 80.0) {
        'caution'
    }
    else {
        'green'
    }
    Assert-Condition -Condition ([string]$report.admission_class -ceq $expectedAdmissionClass) -Name 'admission_threshold'

    $stage = 'groups'
    $expectedGroupOrder = @(
        'Codex'
        'ChatGPT'
        'TouchDesigner'
        'Node/tooling'
        'browser'
        'search/indexing'
        'cloud sync'
        'Defender'
        'other'
    )
    $actualGroupOrder = @($report.group_order)
    Assert-ExactSequence -Actual $actualGroupOrder -Expected $expectedGroupOrder -Name 'group_order'

    $groups = @($report.groups)
    Assert-Condition -Condition ($groups.Count -eq $expectedGroupOrder.Count) -Name 'aggregate_group_count'
    for ($index = 0; $index -lt $expectedGroupOrder.Count; $index++) {
        Assert-Condition -Condition ([string]$groups[$index].group_name -ceq $expectedGroupOrder[$index]) -Name ('aggregate_group_order_{0}' -f $index)
        Assert-Condition -Condition ([int]$groups[$index].process_count -ge 0) -Name ('aggregate_process_count_{0}' -f $index)
        Assert-Condition -Condition ([int64]$groups[$index].private_bytes -ge 0) -Name ('aggregate_private_{0}' -f $index)
        Assert-Condition -Condition ([int64]$groups[$index].working_set_bytes -ge 0) -Name ('aggregate_working_set_{0}' -f $index)
        Assert-Condition -Condition ([double]$groups[$index].cpu_percent -ge 0.0) -Name ('aggregate_cpu_{0}' -f $index)
        Assert-Condition -Condition ([int64]$groups[$index].private_memory_growth_bytes -ge 0) -Name ('aggregate_growth_{0}' -f $index)
    }

    $stage = 'processes'
    $processes = @($report.processes)
    $expectedProcessProperties = @(
        'cpu_percent'
        'group'
        'owner_family'
        'parent_pid'
        'parent_process_name'
        'pid'
        'private_bytes'
        'private_memory_growth_bytes'
        'process_name'
        'working_set_bytes'
    ) | Sort-Object
    $validOwnerFamilies = @(
        'Codex'
        'ChatGPT'
        'TouchDesigner'
        'browser'
        'search/indexing'
        'cloud sync'
        'Defender'
        'development tooling'
        'other'
    )

    foreach ($process in $processes) {
        $actualProcessProperties = @(Get-PropertyNames -InputObject $process) | Sort-Object
        Assert-ExactSequence -Actual $actualProcessProperties -Expected $expectedProcessProperties -Name 'process_safe_properties'
        Assert-Condition -Condition ($expectedGroupOrder -ccontains [string]$process.group) -Name 'process_group_membership'
        Assert-Condition -Condition ([int]$process.pid -ge 0) -Name 'process_pid'
        Assert-Condition -Condition (-not [string]::IsNullOrWhiteSpace([string]$process.process_name)) -Name 'process_name'
        Assert-Condition -Condition ([double]$process.parent_pid -ge 0.0) -Name 'process_parent_pid_minimum'
        Assert-Condition -Condition ([double]$process.parent_pid -eq [Math]::Floor([double]$process.parent_pid)) -Name 'process_parent_pid_integer'
        Assert-Condition -Condition (-not [string]::IsNullOrWhiteSpace([string]$process.parent_process_name)) -Name 'process_parent_name'
        Assert-Condition -Condition ($validOwnerFamilies -ccontains [string]$process.owner_family) -Name 'process_owner_family'
        Assert-Condition -Condition ([int64]$process.private_bytes -ge 0) -Name 'process_private_bytes'
        Assert-Condition -Condition ([int64]$process.working_set_bytes -ge 0) -Name 'process_working_set_bytes'
        Assert-Condition -Condition ([double]$process.cpu_percent -ge 0.0 -and [double]$process.cpu_percent -le 100.0) -Name 'process_cpu_percent'
        Assert-Condition -Condition ([int64]$process.private_memory_growth_bytes -ge 0) -Name 'process_growth'
    }

    $stage = 'totals'
    $processPrivateTotal = [int64]0
    foreach ($process in $processes) {
        $processPrivateTotal += [int64]$process.private_bytes
    }
    $groupPrivateTotal = [int64]0
    foreach ($group in $groups) {
        $groupPrivateTotal += [int64]$group.private_bytes
    }
    Assert-Condition -Condition ($groupPrivateTotal -eq $processPrivateTotal) -Name 'aggregate_private_total'
    Assert-Condition -Condition ([int64]$report.system.process_attributable_private_bytes -eq $processPrivateTotal) -Name 'system_private_total'

    foreach ($groupName in $expectedGroupOrder) {
        $aggregate = @($groups | Where-Object { $_.group_name -ceq $groupName })
        $members = @($processes | Where-Object { $_.group -ceq $groupName })
        Assert-Condition -Condition ($aggregate.Count -eq 1) -Name 'single_aggregate_row'
        $memberPrivateTotal = [int64]0
        foreach ($member in $members) {
            $memberPrivateTotal += [int64]$member.private_bytes
        }
        Assert-Condition -Condition ([int64]$aggregate[0].private_bytes -eq $memberPrivateTotal) -Name 'group_private_total'
        Assert-Condition -Condition ([int]$aggregate[0].process_count -eq $members.Count) -Name 'group_process_count'
    }

    $stage = 'human_execution'
    $humanCapture = @(& $utilityPath -SampleIntervalSeconds 0.25)
    $humanText = $humanCapture -join [Environment]::NewLine
    Assert-Condition -Condition ($humanText -match '(?m)^Admission class:') -Name 'human_admission_section'
    Assert-Condition -Condition ($humanText -match '(?m)^Committed memory:') -Name 'human_committed_section'
    Assert-Condition -Condition ($humanText -match '(?m)^Physical memory used:') -Name 'human_physical_section'
    Assert-Condition -Condition ($humanText -match '(?m)^Groups:') -Name 'human_groups_section'
    Assert-Condition -Condition ($humanText -match '(?m)^Processes:') -Name 'human_processes_section'
    $humanProcessSection = $humanText.Substring($humanText.IndexOf('Processes:', [System.StringComparison]::Ordinal))
    Assert-Condition -Condition ($humanProcessSection -match '(?m)^\s*group\s+pid\s+process_name\s+owner_family\b') -Name 'human_owner_family_column'
    Assert-Condition -Condition ($humanProcessSection -match '(?m)^\s*group\s+pid\s+process_name\s+owner_family\s+parent_pid\b') -Name 'human_parent_pid_column'
    Assert-Condition -Condition ($humanProcessSection -match '(?m)^\s*group\s+pid\s+process_name\s+owner_family\s+parent_pid\s+parent_process_name\b') -Name 'human_parent_name_column'

    $forbiddenPublicationLabelPatterns = @(
        '(?im)^\s*command[ _-]*line(?:\s*:|\s{2,}|$)'
        '(?im)^\s*executable[ _-]*path(?:\s*:|\s{2,}|$)'
        '(?im)^\s*main[ _-]*window[ _-]*title(?:\s*:|\s{2,}|$)'
        '(?im)^\s*environment(?:[ _-]*values?)?(?:\s*:|\s{2,}|$)'
        '(?im)^\s*tokens?(?:\s*:|\s{2,}|$)'
        '(?im)^\s*secrets?(?:\s*:|\s{2,}|$)'
        '(?im)^\s*raw[ _-]*logs?(?:\s*:|\s{2,}|$)'
    )
    foreach ($pattern in $forbiddenPublicationLabelPatterns) {
        Assert-Condition -Condition ($humanText -notmatch $pattern) -Name 'human_forbidden_publication_label'
    }

    Write-Output ('status=ok; assertions={0}' -f $script:assertionCount)
}
catch {
    $failure = [string]$_.Exception.Message
    if ($failure -like 'assertion_failed=*') {
        [Console]::Error.WriteLine(('status=fail; {0}' -f $failure))
    }
    else {
        [Console]::Error.WriteLine(('status=fail; stage={0}' -f $stage))
    }
    exit 1
}
