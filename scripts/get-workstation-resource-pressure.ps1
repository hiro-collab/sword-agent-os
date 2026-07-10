[CmdletBinding()]
param(
    [Parameter()]
    [ValidateRange(0.25, 30.0)]
    [double]$SampleIntervalSeconds = 2.0,

    [Parameter()]
    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$groupOrder = @(
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

function Get-PressureGroup {
    param(
        [Parameter(Mandatory)]
        [string]$ProcessName
    )

    switch -Regex ($ProcessName) {
        '^codex(?:$|-)' { return 'Codex' }
        '^chatgpt$' { return 'ChatGPT' }
        '^(touchdesigner|touchdesigner099|touchplayer|toeexpand)$' { return 'TouchDesigner' }
        '^(node|npm|npx|pnpm|yarn|bun|deno|python|pythonw|py|uv|pwsh|powershell|cmd|conhost|git|rg|fd|jq|yq|just)$' { return 'Node/tooling' }
        '^(chrome|msedge|msedgewebview2|webviewhost|firefox|brave|opera|vivaldi|iexplore)$' { return 'browser' }
        '^(searchapp|searchhost|searchindexer|searchprotocolhost|searchfilterhost|everything|everything64)$' { return 'search/indexing' }
        '^(onedrive|dropbox|googledrivefs|synologydrive|synologydriveclient|iclouddrive|nextcloud|cloud-drive-daemon)$' { return 'cloud sync' }
        '^(msmpeng|mpcmdrun|nissrv|securityhealthservice)$' { return 'Defender' }
        default { return 'other' }
    }
}

function Get-BoundedProcessSnapshot {
    $rows = foreach ($process in @(Get-Process -ErrorAction SilentlyContinue)) {
        try {
            $cpuSeconds = if ($null -eq $process.CPU) { 0.0 } else { [double]$process.CPU }
            [pscustomobject][ordered]@{
                pid             = [int]$process.Id
                process_name    = [string]$process.ProcessName
                cpu_seconds     = $cpuSeconds
                private_bytes   = [int64]$process.PrivateMemorySize64
                working_set_bytes = [int64]$process.WorkingSet64
            }
        }
        catch {
            # A process can exit or become inaccessible while its counters are read.
            continue
        }
    }

    return @($rows)
}

function Get-AdmissionClass {
    param(
        [Parameter(Mandatory)]
        [double]$CommittedMemoryPercent
    )

    if ($CommittedMemoryPercent -ge 85.0) {
        return 'hold'
    }
    if ($CommittedMemoryPercent -gt 80.0) {
        return 'caution'
    }
    return 'green'
}

function Convert-GroupToOwnerFamily {
    param(
        [Parameter(Mandatory)]
        [string]$GroupName
    )

    switch -CaseSensitive ($GroupName) {
        'Codex' { return 'Codex' }
        'ChatGPT' { return 'ChatGPT' }
        'TouchDesigner' { return 'TouchDesigner' }
        'browser' { return 'browser' }
        'search/indexing' { return 'search/indexing' }
        'cloud sync' { return 'cloud sync' }
        'Defender' { return 'Defender' }
        'Node/tooling' { return 'development tooling' }
        default { return 'other' }
    }
}

function Get-RecognizedOwnerFamily {
    param(
        [Parameter(Mandatory)]
        [string]$ProcessName
    )

    $groupName = Get-PressureGroup -ProcessName $ProcessName
    switch -CaseSensitive ($groupName) {
        'Codex' { return 'Codex' }
        'ChatGPT' { return 'ChatGPT' }
        'TouchDesigner' { return 'TouchDesigner' }
        'browser' { return 'browser' }
        'search/indexing' { return 'search/indexing' }
        'cloud sync' { return 'cloud sync' }
        'Defender' { return 'Defender' }
        default { return $null }
    }
}

function Get-OwnerFamily {
    param(
        [Parameter(Mandatory)]
        [int]$ProcessId,

        [Parameter(Mandatory)]
        [string]$ProcessName,

        [Parameter(Mandatory)]
        [string]$CurrentGroup,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [hashtable]$ProcessIdentityByPid
    )

    $currentFamily = Get-RecognizedOwnerFamily -ProcessName $ProcessName
    if ($null -ne $currentFamily) {
        return $currentFamily
    }

    $fallbackFamily = Convert-GroupToOwnerFamily -GroupName $CurrentGroup
    $visitedPids = @{}
    $visitedPids[$ProcessId] = $true
    $parentPid = 0
    if ($ProcessIdentityByPid.ContainsKey($ProcessId)) {
        $parentPid = [int]$ProcessIdentityByPid[$ProcessId].parent_pid
    }

    for ($depth = 0; $depth -lt 8 -and $parentPid -gt 0; $depth++) {
        if ($visitedPids.ContainsKey($parentPid)) {
            break
        }
        $visitedPids[$parentPid] = $true

        if (-not $ProcessIdentityByPid.ContainsKey($parentPid)) {
            break
        }

        $ancestorIdentity = $ProcessIdentityByPid[$parentPid]
        $ancestorFamily = Get-RecognizedOwnerFamily -ProcessName $ancestorIdentity.process_name
        if ($null -ne $ancestorFamily) {
            return $ancestorFamily
        }
        $parentPid = [int]$ancestorIdentity.parent_pid
    }

    return $fallbackFamily
}

$computerSystem = Get-CimInstance -ClassName Win32_ComputerSystem
$logicalProcessorCount = [int]$computerSystem.NumberOfLogicalProcessors
if ($logicalProcessorCount -lt 1) {
    $logicalProcessorCount = 1
}

$firstSnapshot = @(Get-BoundedProcessSnapshot)
$sampleTimer = [System.Diagnostics.Stopwatch]::StartNew()
$sleepMilliseconds = [int][Math]::Round($SampleIntervalSeconds * 1000.0)
Start-Sleep -Milliseconds $sleepMilliseconds
$secondSnapshot = @(Get-BoundedProcessSnapshot)
$sampleTimer.Stop()

$elapsedSeconds = [Math]::Max(0.001, $sampleTimer.Elapsed.TotalSeconds)
$firstByPid = @{}
foreach ($item in $firstSnapshot) {
    $firstByPid[[int]$item.pid] = $item
}

$processIdentityByPid = @{}
try {
    $cimProcesses = @(
        Get-CimInstance -ClassName Win32_Process -Property ProcessId, ParentProcessId, Name -ErrorAction Stop
    )
    foreach ($cimProcess in $cimProcesses) {
        $identityName = [string]$cimProcess.Name
        $identityName = $identityName -replace '(?i)\.exe$', ''
        if ([string]::IsNullOrWhiteSpace($identityName)) {
            $identityName = 'unknown'
        }

        $identityPid = [int]$cimProcess.ProcessId
        $identityParentPid = [Math]::Max(0, [int]$cimProcess.ParentProcessId)
        $processIdentityByPid[$identityPid] = [pscustomobject][ordered]@{
            process_name = $identityName
            parent_pid   = $identityParentPid
        }
    }
}
catch {
    $processIdentityByPid = @{}
}

$processRows = foreach ($current in $secondSnapshot) {
    $cpuDeltaSeconds = 0.0
    $privateGrowthBytes = [int64]0

    if ($firstByPid.ContainsKey([int]$current.pid)) {
        $first = $firstByPid[[int]$current.pid]
        if ($first.process_name -eq $current.process_name) {
            $cpuDeltaSeconds = [Math]::Max(0.0, ([double]$current.cpu_seconds - [double]$first.cpu_seconds))
            $rawGrowthBytes = [Math]::Max([int64]0, ([int64]$current.private_bytes - [int64]$first.private_bytes))
            $privateGrowthBytes = [Math]::Min([int64]$current.private_bytes, [int64]$rawGrowthBytes)
        }
    }

    $cpuPercent = ($cpuDeltaSeconds / $elapsedSeconds / $logicalProcessorCount) * 100.0
    $cpuPercent = [Math]::Min(100.0, [Math]::Max(0.0, $cpuPercent))
    $currentGroup = Get-PressureGroup -ProcessName $current.process_name
    $parentPid = 0
    $parentProcessName = 'unknown'
    if ($processIdentityByPid.ContainsKey([int]$current.pid)) {
        $parentPid = [int]$processIdentityByPid[[int]$current.pid].parent_pid
        if ($parentPid -gt 0 -and $processIdentityByPid.ContainsKey($parentPid)) {
            $parentProcessName = [string]$processIdentityByPid[$parentPid].process_name
        }
    }
    $ownerFamily = Get-OwnerFamily -ProcessId $current.pid -ProcessName $current.process_name -CurrentGroup $currentGroup -ProcessIdentityByPid $processIdentityByPid

    [pscustomobject][ordered]@{
        group                       = $currentGroup
        pid                         = [int]$current.pid
        process_name                = [string]$current.process_name
        parent_pid                  = $parentPid
        parent_process_name         = $parentProcessName
        owner_family                = $ownerFamily
        private_bytes               = [int64]$current.private_bytes
        working_set_bytes           = [int64]$current.working_set_bytes
        cpu_percent                 = [Math]::Round($cpuPercent, 3)
        private_memory_growth_bytes = [int64]$privateGrowthBytes
    }
}

$groupRank = @{}
for ($index = 0; $index -lt $groupOrder.Count; $index++) {
    $groupRank[$groupOrder[$index]] = $index
}

$processRows = @(
    $processRows | Sort-Object @{ Expression = { $groupRank[$_.group] } }, @{ Expression = { $_.process_name } }, @{ Expression = { $_.pid } }
)

$groupRows = foreach ($groupName in $groupOrder) {
    $members = @($processRows | Where-Object { $_.group -eq $groupName })
    $privateBytes = [int64]0
    $workingSetBytes = [int64]0
    $cpuPercent = [double]0.0
    $growthBytes = [int64]0
    foreach ($member in $members) {
        $privateBytes += [int64]$member.private_bytes
        $workingSetBytes += [int64]$member.working_set_bytes
        $cpuPercent += [double]$member.cpu_percent
        $growthBytes += [int64]$member.private_memory_growth_bytes
    }

    [pscustomobject][ordered]@{
        group_name                  = $groupName
        process_count               = $members.Count
        private_bytes               = $privateBytes
        working_set_bytes           = $workingSetBytes
        cpu_percent                 = [Math]::Round($cpuPercent, 3)
        private_memory_growth_bytes = $growthBytes
    }
}

$operatingSystem = Get-CimInstance -ClassName Win32_OperatingSystem
$memoryCounters = Get-CimInstance -ClassName Win32_PerfFormattedData_PerfOS_Memory

$committedBytes = [int64]$memoryCounters.CommittedBytes
$commitLimitBytes = [int64]$memoryCounters.CommitLimit
$committedMemoryPercent = if ($commitLimitBytes -gt 0) {
    ([double]$committedBytes / [double]$commitLimitBytes) * 100.0
}
else {
    [double]$memoryCounters.PercentCommittedBytesInUse
}

$physicalTotalBytes = [int64]$operatingSystem.TotalVisibleMemorySize * 1024L
$physicalAvailableBytes = [int64]$operatingSystem.FreePhysicalMemory * 1024L
$physicalMemoryUsedPercent = if ($physicalTotalBytes -gt 0) {
    (([double]$physicalTotalBytes - [double]$physicalAvailableBytes) / [double]$physicalTotalBytes) * 100.0
}
else {
    0.0
}

$processAttributablePrivateBytes = [int64]0
foreach ($processRow in $processRows) {
    $processAttributablePrivateBytes += [int64]$processRow.private_bytes
}
$nonAttributedCommittedGapBytes = [Math]::Max(
    [int64]0,
    ([int64]$committedBytes - [int64]$processAttributablePrivateBytes)
)

$report = [pscustomobject][ordered]@{
    schema_version                    = 1
    sampled_at_utc                    = [DateTime]::UtcNow.ToString('o')
    sample_interval_seconds_requested = [Math]::Round($SampleIntervalSeconds, 3)
    sample_elapsed_seconds            = [Math]::Round($elapsedSeconds, 3)
    logical_processor_count           = $logicalProcessorCount
    admission_class                   = Get-AdmissionClass -CommittedMemoryPercent $committedMemoryPercent
    system                            = [pscustomobject][ordered]@{
        committed_bytes                            = $committedBytes
        commit_limit_bytes                         = $commitLimitBytes
        committed_memory_percent                   = [Math]::Round($committedMemoryPercent, 3)
        physical_total_bytes                       = $physicalTotalBytes
        physical_available_bytes                   = $physicalAvailableBytes
        physical_memory_used_percent               = [Math]::Round($physicalMemoryUsedPercent, 3)
        process_attributable_private_bytes         = $processAttributablePrivateBytes
        non_attributed_committed_gap_bytes         = [int64]$nonAttributedCommittedGapBytes
        non_attributed_committed_gap_is_approximate = $true
    }
    group_order                       = @($groupOrder)
    groups                            = @($groupRows)
    processes                         = @($processRows)
}

if ($Json) {
    $report | ConvertTo-Json -Depth 6 -Compress
    return
}

Write-Output ('Admission class: {0}' -f $report.admission_class)
Write-Output ('Committed memory: {0:N1}% ({1:N0} / {2:N0} bytes)' -f $report.system.committed_memory_percent, $report.system.committed_bytes, $report.system.commit_limit_bytes)
Write-Output ('Physical memory used: {0:N1}%' -f $report.system.physical_memory_used_percent)
Write-Output ('Sample: {0:N3}s elapsed, {1} logical processors' -f $report.sample_elapsed_seconds, $report.logical_processor_count)
Write-Output ('Process-attributable private memory: {0:N0} bytes' -f $report.system.process_attributable_private_bytes)
Write-Output ('Approximate non-attributed committed gap: {0:N0} bytes' -f $report.system.non_attributed_committed_gap_bytes)
Write-Output ''
Write-Output 'Groups:'
$groupRows |
    Select-Object group_name, process_count, private_bytes, working_set_bytes, cpu_percent, private_memory_growth_bytes |
    Format-Table -AutoSize |
    Out-String -Width 200 |
    Write-Output
Write-Output 'Processes:'
$processRows |
    Select-Object group, pid, process_name, owner_family, parent_pid, parent_process_name, private_bytes, working_set_bytes, cpu_percent, private_memory_growth_bytes |
    Format-Table -AutoSize |
    Out-String -Width 220 |
    Write-Output
