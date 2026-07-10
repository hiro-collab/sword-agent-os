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
