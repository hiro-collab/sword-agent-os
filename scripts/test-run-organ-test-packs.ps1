$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$RepoRoot = Split-Path -Parent $PSScriptRoot
$RunnerPath = Join-Path $PSScriptRoot "run-organ-test-packs.ps1"
$PwshPath = Join-Path $PSHOME "pwsh.exe"
$assertions = 0
$runId = [guid]::NewGuid().ToString("N")
$testRootName = "organ-pack-path-boundary-test-$runId"
$systemTempBase = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
$systemTempRoot = Join-Path $systemTempBase $testRootName
$repoTempBase = Join-Path $RepoRoot ".cache"
$repoTempRoot = Join-Path $repoTempBase $testRootName
$junctionPath = Join-Path $repoTempRoot "linked"
$privacySentinel = "secret-fixture-value"

function Assert-True {
  param([bool]$Condition, [string]$Message)
  $script:assertions += 1
  if (-not $Condition) { throw $Message }
}

function Assert-Equal {
  param($Actual, $Expected, [string]$Message)
  Assert-True ($Actual -ceq $Expected) "$Message; actual=$Actual expected=$Expected"
}

function Assert-ParserClear {
  param([Parameter(Mandatory = $true)][string]$Path)
  $tokens = $null
  $errors = $null
  [void][Management.Automation.Language.Parser]::ParseFile(
    $Path, [ref]$tokens, [ref]$errors)
  Assert-Equal @($errors).Count 0 "PowerShell parser must remain clear"
}

function Write-JsonFile {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)]$Value
  )
  [System.IO.File]::WriteAllText(
    $Path,
    ($Value | ConvertTo-Json -Depth 10),
    [Text.Encoding]::UTF8)
}

function Write-MinimalCommandPack {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][object[]]$Tests
  )
  Write-JsonFile -Path $Path -Value ([ordered]@{
      schema_version = "organ-test-packs.v0"
      id = "organ-pack-path-boundary-fixture"
      profile_id = "standard"
      service_manifest = "manifests/services/standard.json"
      default_modes = @("auto")
      packs = @(
        [ordered]@{
          organ_id = "agent-os-body-schema"
          tests = @($Tests)
        }
      )
    })
}

function New-CommandTest {
  param(
    [Parameter(Mandatory = $true)][string]$Id,
    [Parameter(Mandatory = $true)][string]$Executable,
    [Parameter(Mandatory = $true)][string[]]$Arguments
  )
  return [ordered]@{
    id = $Id
    mode = "auto"
    type = "command"
    executable = $Executable
    args = @($Arguments)
    expect_exit_code = 0
  }
}

function Invoke-RunnerCase {
  param(
    [Parameter(Mandatory = $true)][string]$ManifestPath,
    [Parameter(Mandatory = $true)][string]$WorkingDirectory
  )
  $statusPath = Join-Path $systemTempRoot "status.json"
  $topologyPath = Join-Path $systemTempRoot "topology-not-created.json"
  Push-Location $WorkingDirectory
  try {
    $rawOutput = @(
      & $PwshPath -NoProfile -File $RunnerPath `
        -TestPackPath $ManifestPath -StatusPath $statusPath `
        -TopologyPath $topologyPath -Modes auto -NoRefreshDiagnostics -Json 2>&1
    )
    $exitCode = $LASTEXITCODE
  }
  finally {
    Pop-Location
  }
  $serialized = ($rawOutput | ForEach-Object { [string]$_ }) -join "`n"
  try {
    $output = $serialized | ConvertFrom-Json
  }
  catch {
    throw "organ pack focused runner output invalid"
  }
  return [pscustomobject]@{
    ExitCode = $exitCode
    Output = $output
    Serialized = $serialized
  }
}

function Assert-InvalidPowerShellCase {
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][string[]]$Arguments,
    [Parameter(Mandatory = $true)][string]$WorkingDirectory
  )
  $manifestPath = Join-Path $systemTempRoot "$Name.json"
  Write-MinimalCommandPack -Path $manifestPath -Tests @(
    New-CommandTest -Id "fixture.$Name" -Executable "powershell" -Arguments $Arguments
  )
  $case = Invoke-RunnerCase `
    -ManifestPath $manifestPath -WorkingDirectory $WorkingDirectory
  Assert-Equal $case.ExitCode 0 "$Name must return a bounded blocked result"
  Assert-Equal $case.Output.summary.status "blocked" `
    "$Name must fail closed without child execution"
  Assert-Equal ([int]$case.Output.summary.blocked) 1 `
    "$Name must produce exactly one blocked result"
  Assert-Equal ([int]$case.Output.summary.pass) 0 `
    "$Name must not execute the rejected PowerShell command"
  Assert-Equal ([int]$case.Output.summary.fail) 0 `
    "$Name must not reach child-process failure handling"
  Assert-Equal $case.Output.results[0].detail `
    "organ_pack_powershell_file_invalid" `
    "$Name must publish only the fixed invalid-file class"
  Assert-True (-not $case.Serialized.Contains($privacySentinel)) `
    "$Name must not publish the rejected path or private sentinel"
}

function Assert-NonReparsePathChain {
  param([Parameter(Mandatory = $true)][string]$Path)
  $currentPath = [System.IO.Path]::GetFullPath($Path)
  $visited = [Collections.Generic.HashSet[string]]::new(
    [StringComparer]::OrdinalIgnoreCase)
  while (-not [string]::IsNullOrWhiteSpace($currentPath)) {
    if (-not $visited.Add($currentPath)) {
      throw "fixture_path_chain_invalid"
    }
    if (Test-Path -LiteralPath $currentPath) {
      $item = Get-Item -LiteralPath $currentPath -Force
      if (
        -not [bool]$item.PSIsContainer -or
        ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0
      ) {
        throw "fixture_path_chain_invalid"
      }
    }
    $parent = [System.IO.Directory]::GetParent($currentPath)
    if ($null -eq $parent) { break }
    $currentPath = $parent.FullName
  }
}

function Remove-OwnedTestRoot {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$Base,
    [Parameter(Mandatory = $true)][string]$ExpectedRunId,
    [Parameter(Mandatory = $true)][bool]$Created,
    [Parameter(Mandatory = $true)][bool]$MarkerWritten
  )
  Assert-NonReparsePathChain -Path $Base
  if (-not $Created) {
    if (Test-Path -LiteralPath $Path) {
      throw "owned_test_cleanup_untracked_root"
    }
    return
  }
  $trimCharacters = [char[]]@(
    [System.IO.Path]::DirectorySeparatorChar,
    [System.IO.Path]::AltDirectorySeparatorChar
  )
  $baseFull = [System.IO.Path]::GetFullPath($Base).TrimEnd($trimCharacters)
  $pathFull = [System.IO.Path]::GetFullPath($Path)
  $basePrefix = $baseFull + [System.IO.Path]::DirectorySeparatorChar
  if (
    -not $pathFull.StartsWith($basePrefix, [StringComparison]::OrdinalIgnoreCase) -or
    [System.IO.Path]::GetFileName($pathFull) -cne
      "organ-pack-path-boundary-test-$ExpectedRunId"
  ) {
    throw "owned test cleanup path invalid"
  }
  if (-not (Test-Path -LiteralPath $pathFull)) { return }
  $rootItem = Get-Item -LiteralPath $pathFull -Force
  if (
    -not [bool]$rootItem.PSIsContainer -or
    ($rootItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0
  ) {
    throw "owned test cleanup root invalid"
  }
  $markerPath = Join-Path $pathFull ".owned-test"
  if ($MarkerWritten) {
    if (
      -not (Test-Path -LiteralPath $markerPath -PathType Leaf) -or
      (Get-Content -Raw -LiteralPath $markerPath).Trim() -cne $ExpectedRunId
    ) {
      throw "owned test cleanup marker invalid"
    }
    $reparseChildren = @(
      Get-ChildItem -LiteralPath $pathFull -Recurse -Force |
        Where-Object {
          ($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0
        }
    )
    if ($reparseChildren.Count -ne 0) {
      throw "owned test cleanup reparse residue"
    }
    [System.IO.Directory]::Delete($pathFull, $true)
  }
  else {
    if (
      (Test-Path -LiteralPath $markerPath) -or
      [System.IO.Directory]::GetFileSystemEntries($pathFull).Count -ne 0
    ) {
      throw "owned test markerless cleanup refused"
    }
    [System.IO.Directory]::Delete($pathFull, $false)
  }
  if (Test-Path -LiteralPath $pathFull) {
    throw "owned test cleanup incomplete"
  }
}

function Invoke-OwnedFixtureCleanup {
  param(
    [Parameter(Mandatory = $true)][string]$SystemRoot,
    [Parameter(Mandatory = $true)][string]$SystemBase,
    [Parameter(Mandatory = $true)][string]$RepoRoot,
    [Parameter(Mandatory = $true)][string]$RepoBase,
    [Parameter(Mandatory = $true)][string]$Junction,
    [Parameter(Mandatory = $true)][string]$ExpectedRunId,
    [Parameter(Mandatory = $true)][bool]$SystemRootCreated,
    [Parameter(Mandatory = $true)][bool]$SystemMarkerWritten,
    [Parameter(Mandatory = $true)][bool]$RepoRootCreated,
    [Parameter(Mandatory = $true)][bool]$RepoMarkerWritten,
    [Parameter(Mandatory = $true)][bool]$JunctionCreated,
    [switch]$InjectFirstCleanupFailure
  )
  $failureCount = 0
  $junctionAttempted = $true
  $repoRootAttempted = $false
  $systemRootAttempted = $false

  try {
    Assert-NonReparsePathChain -Path $RepoBase
    if ($JunctionCreated) {
      $repoRootFull = [System.IO.Path]::GetFullPath($RepoRoot)
      $junctionFull = [System.IO.Path]::GetFullPath($Junction)
      if (
        [System.IO.Path]::GetDirectoryName($junctionFull) -cne $repoRootFull -or
        [System.IO.Path]::GetFileName($junctionFull) -cne "linked"
      ) {
        throw "owned test junction cleanup path invalid"
      }
      if (Test-Path -LiteralPath $junctionFull) {
        Assert-NonReparsePathChain -Path $repoRootFull
        $junctionItem = Get-Item -LiteralPath $junctionFull -Force
        if (
          -not [bool]$junctionItem.PSIsContainer -or
          ($junctionItem.Attributes -band
            [System.IO.FileAttributes]::ReparsePoint) -eq 0
        ) {
          throw "owned test junction cleanup refused"
        }
        [System.IO.Directory]::Delete($junctionFull, $false)
        if (Test-Path -LiteralPath $junctionFull) {
          throw "owned test junction cleanup incomplete"
        }
      }
    }
    elseif (Test-Path -LiteralPath $Junction) {
      throw "owned test junction cleanup untracked"
    }
  }
  catch {
    $failureCount += 1
  }
  if ($InjectFirstCleanupFailure) {
    $failureCount += 1
  }

  $repoRootAttempted = $true
  try {
    Remove-OwnedTestRoot `
      -Path $RepoRoot -Base $RepoBase -ExpectedRunId $ExpectedRunId `
      -Created $RepoRootCreated -MarkerWritten $RepoMarkerWritten
  }
  catch {
    $failureCount += 1
  }

  $systemRootAttempted = $true
  try {
    Remove-OwnedTestRoot `
      -Path $SystemRoot -Base $SystemBase -ExpectedRunId $ExpectedRunId `
      -Created $SystemRootCreated -MarkerWritten $SystemMarkerWritten
  }
  catch {
    $failureCount += 1
  }

  return [pscustomobject]@{
    FailureClass = if ($failureCount -eq 0) {
      $null
    }
    else {
      "fixture_cleanup_incomplete"
    }
    JunctionAttempted = $junctionAttempted
    RepoRootAttempted = $repoRootAttempted
    SystemRootAttempted = $systemRootAttempted
  }
}

function Invoke-FixtureLifecycleMutation {
  param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("setup_failure", "first_cleanup_failure")]
    [string]$Mode
  )
  $mutationRunId = [guid]::NewGuid().ToString("N")
  $mutationRootName = "organ-pack-path-boundary-test-$mutationRunId"
  $mutationSystemRoot = Join-Path $systemTempBase $mutationRootName
  $mutationRepoRoot = Join-Path $repoTempBase $mutationRootName
  $mutationJunction = Join-Path $mutationRepoRoot "linked"
  $mutationSystemCreated = $false
  $mutationSystemMarker = $false
  $mutationRepoCreated = $false
  $mutationRepoMarker = $false
  $mutationJunctionCreated = $false
  $setupFailureObserved = $false
  $injectedCleanupResult = $null
  $finalCleanupResult = $null

  try {
    Assert-NonReparsePathChain -Path $systemTempBase
    Assert-NonReparsePathChain -Path $repoTempBase
    if (
      (Test-Path -LiteralPath $mutationSystemRoot) -or
      (Test-Path -LiteralPath $mutationRepoRoot)
    ) {
      throw "fixture_mutation_root_not_absent"
    }
    [void][System.IO.Directory]::CreateDirectory($mutationSystemRoot)
    $mutationSystemCreated = $true
    [void][System.IO.Directory]::CreateDirectory($mutationRepoRoot)
    $mutationRepoCreated = $true

    if ($Mode -ceq "setup_failure") {
      throw "fixture_setup_injected"
    }

    [System.IO.File]::WriteAllText(
      (Join-Path $mutationSystemRoot ".owned-test"),
      $mutationRunId,
      [Text.Encoding]::ASCII)
    $mutationSystemMarker = $true
    [System.IO.File]::WriteAllText(
      (Join-Path $mutationRepoRoot ".owned-test"),
      $mutationRunId,
      [Text.Encoding]::ASCII)
    $mutationRepoMarker = $true
    $mutationTarget = Join-Path $mutationSystemRoot "junction-target"
    [void][System.IO.Directory]::CreateDirectory($mutationTarget)
    [void](New-Item -ItemType Junction -Path $mutationJunction `
        -Target $mutationTarget -ErrorAction Stop)
    $mutationJunctionCreated = $true

    $injectedCleanupResult = Invoke-OwnedFixtureCleanup `
      -SystemRoot $mutationSystemRoot -SystemBase $systemTempBase `
      -RepoRoot $mutationRepoRoot -RepoBase $repoTempBase `
      -Junction $mutationJunction -ExpectedRunId $mutationRunId `
      -SystemRootCreated $mutationSystemCreated `
      -SystemMarkerWritten $mutationSystemMarker `
      -RepoRootCreated $mutationRepoCreated `
      -RepoMarkerWritten $mutationRepoMarker `
      -JunctionCreated $mutationJunctionCreated `
      -InjectFirstCleanupFailure
  }
  catch {
    if (
      $Mode -ceq "setup_failure" -and
      $_.Exception.Message -ceq "fixture_setup_injected"
    ) {
      $setupFailureObserved = $true
    }
    else {
      throw
    }
  }
  finally {
    $finalCleanupResult = Invoke-OwnedFixtureCleanup `
      -SystemRoot $mutationSystemRoot -SystemBase $systemTempBase `
      -RepoRoot $mutationRepoRoot -RepoBase $repoTempBase `
      -Junction $mutationJunction -ExpectedRunId $mutationRunId `
      -SystemRootCreated $mutationSystemCreated `
      -SystemMarkerWritten $mutationSystemMarker `
      -RepoRootCreated $mutationRepoCreated `
      -RepoMarkerWritten $mutationRepoMarker `
      -JunctionCreated $mutationJunctionCreated
    if ($null -ne $finalCleanupResult.FailureClass) {
      throw "fixture_cleanup_incomplete"
    }
  }

  Assert-True $finalCleanupResult.JunctionAttempted `
    "$Mode cleanup must attempt the junction independently"
  Assert-True $finalCleanupResult.RepoRootAttempted `
    "$Mode cleanup must attempt the repository root independently"
  Assert-True $finalCleanupResult.SystemRootAttempted `
    "$Mode cleanup must attempt the system root independently"
  if ($Mode -ceq "setup_failure") {
    Assert-True $setupFailureObserved `
      "setup failure mutation must reach the cleanup-protected region"
  }
  else {
    Assert-Equal $injectedCleanupResult.FailureClass `
      "fixture_cleanup_incomplete" `
      "first cleanup failure must aggregate to one fixed class"
    Assert-True $injectedCleanupResult.JunctionAttempted `
      "first cleanup failure must attempt the junction"
    Assert-True $injectedCleanupResult.RepoRootAttempted `
      "first cleanup failure must not skip repository cleanup"
    Assert-True $injectedCleanupResult.SystemRootAttempted `
      "first cleanup failure must not skip system cleanup"
  }
  Assert-True (-not (Test-Path -LiteralPath $mutationRepoRoot)) `
    "$Mode repository mutation residue must be zero"
  Assert-True (-not (Test-Path -LiteralPath $mutationSystemRoot)) `
    "$Mode system mutation residue must be zero"
}

$systemRootCreated = $false
$systemMarkerWritten = $false
$repoRootCreated = $false
$repoMarkerWritten = $false
$junctionCreated = $false

Assert-ParserClear -Path $RunnerPath
Assert-ParserClear -Path $MyInvocation.MyCommand.Path
Assert-True (Test-Path -LiteralPath $PwshPath -PathType Leaf) `
  "PowerShell 7 must be available for the focused runner"
Assert-True (-not (Test-Path -LiteralPath $systemTempRoot)) `
  "system temp test root must start absent"
Assert-True (-not (Test-Path -LiteralPath $repoTempRoot)) `
  "repository temp test root must start absent"

Invoke-FixtureLifecycleMutation -Mode "setup_failure"
Invoke-FixtureLifecycleMutation -Mode "first_cleanup_failure"

try {
  Assert-NonReparsePathChain -Path $systemTempBase
  Assert-NonReparsePathChain -Path $repoTempBase
  [void][System.IO.Directory]::CreateDirectory($systemTempRoot)
  $systemRootCreated = $true
  [void][System.IO.Directory]::CreateDirectory($repoTempRoot)
  $repoRootCreated = $true
  Assert-NonReparsePathChain -Path $systemTempBase
  Assert-NonReparsePathChain -Path $repoTempBase
  [System.IO.File]::WriteAllText(
    (Join-Path $systemTempRoot ".owned-test"),
    $runId,
    [Text.Encoding]::ASCII)
  $systemMarkerWritten = $true
  [System.IO.File]::WriteAllText(
    (Join-Path $repoTempRoot ".owned-test"),
    $runId,
    [Text.Encoding]::ASCII)
  $repoMarkerWritten = $true
  [System.IO.File]::WriteAllText(
    (Join-Path $systemTempRoot "status.json"),
    '{"services":[],"capabilities":[]}',
    [Text.Encoding]::ASCII)

  $unrelatedWorkingDirectory = Join-Path $systemTempRoot "unrelated"
  $decoyDirectory = Join-Path $unrelatedWorkingDirectory "scripts\tests"
  $decoyMarkerDirectory = Join-Path $systemTempRoot "decoy-markers"
  [void][System.IO.Directory]::CreateDirectory($decoyDirectory)
  [void][System.IO.Directory]::CreateDirectory($decoyMarkerDirectory)
  $bodySchemaScripts = @(
    "test-state-event-ingest.ps1",
    "test-diagnostics-body-state-projection.ps1",
    "test-body-schema-current-state.ps1"
  )
  $decoyMarkers = @()
  foreach ($scriptName in $bodySchemaScripts) {
    $marker = Join-Path $decoyMarkerDirectory "$scriptName.marker"
    $decoyMarkers += $marker
    $escapedMarker = $marker.Replace("'", "''")
    [System.IO.File]::WriteAllText(
      (Join-Path $decoyDirectory $scriptName),
      "[System.IO.File]::WriteAllText('$escapedMarker','decoy')`r`nexit 0`r`n",
      [Text.Encoding]::UTF8)
  }

  $threeCommandManifest = Join-Path $systemTempRoot "body-schema-three.json"
  Write-MinimalCommandPack -Path $threeCommandManifest -Tests @(
    (New-CommandTest -Id "body_schema.state_event_ingest" `
      -Executable "powershell" `
      -Arguments @(
        "-NoProfile", "-ExecutionPolicy", "Bypass", "-File",
        "scripts/tests/test-state-event-ingest.ps1"))
    (New-CommandTest -Id "body_schema.diagnostics_body_state_projection" `
      -Executable "powershell" `
      -Arguments @(
        "-NoProfile", "-ExecutionPolicy", "Bypass", "-File",
        "scripts/tests/test-diagnostics-body-state-projection.ps1"))
    (New-CommandTest -Id "body_schema.current_state" `
      -Executable "powershell" `
      -Arguments @(
        "-NoProfile", "-ExecutionPolicy", "Bypass", "-File",
        "scripts/tests/test-body-schema-current-state.ps1"))
  )
  $threeCommandResult = Invoke-RunnerCase `
    -ManifestPath $threeCommandManifest `
    -WorkingDirectory $unrelatedWorkingDirectory
  Assert-Equal $threeCommandResult.ExitCode 0 `
    "bounded Body Schema command route must exit successfully"
  Assert-Equal $threeCommandResult.Output.summary.status "ok" `
    "bounded Body Schema command route must pass"
  Assert-Equal ([int]$threeCommandResult.Output.summary.tests_selected) 3 `
    "bounded Body Schema command route must select exactly three tests"
  Assert-Equal ([int]$threeCommandResult.Output.summary.pass) 3 `
    "bounded Body Schema command route must run all three tracked scripts"
  foreach ($marker in $decoyMarkers) {
    Assert-True (-not (Test-Path -LiteralPath $marker)) `
      "unrelated-cwd decoy must never execute"
  }

  Assert-InvalidPowerShellCase -Name "missing" `
    -Arguments @(
      "-NoProfile", "-File",
      "scripts/tests/$privacySentinel-missing.ps1") `
    -WorkingDirectory $unrelatedWorkingDirectory
  Assert-InvalidPowerShellCase -Name "outside" `
    -Arguments @("-NoProfile", "-File", "../$privacySentinel-outside.ps1") `
    -WorkingDirectory $unrelatedWorkingDirectory

  $absoluteTarget = Join-Path $systemTempRoot "$privacySentinel-absolute.ps1"
  [System.IO.File]::WriteAllText($absoluteTarget, "exit 0", [Text.Encoding]::ASCII)
  Assert-InvalidPowerShellCase -Name "absolute" `
    -Arguments @("-NoProfile", "-File", $absoluteTarget) `
    -WorkingDirectory $unrelatedWorkingDirectory

  $outsideDirectory = Join-Path $systemTempRoot "outside-junction-target"
  [void][System.IO.Directory]::CreateDirectory($outsideDirectory)
  [System.IO.File]::WriteAllText(
    (Join-Path $outsideDirectory "$privacySentinel-reparse.ps1"),
    "exit 0",
    [Text.Encoding]::ASCII)
  [void](New-Item -ItemType Junction -Path $junctionPath `
      -Target $outsideDirectory -ErrorAction Stop)
  $junctionCreated = $true
  $reparseRelativePath = ".cache/$testRootName/linked/$privacySentinel-reparse.ps1"
  Assert-InvalidPowerShellCase -Name "reparse" `
    -Arguments @("-NoProfile", "-File", $reparseRelativePath) `
    -WorkingDirectory $unrelatedWorkingDirectory

  Assert-InvalidPowerShellCase -Name "duplicate-file" `
    -Arguments @(
      "-NoProfile", "-File", "scripts/tests/test-state-event-ingest.ps1",
      "-File", "scripts/tests/$privacySentinel-duplicate.ps1") `
    -WorkingDirectory $unrelatedWorkingDirectory

  Assert-InvalidPowerShellCase -Name "zero-file" `
    -Arguments @("-NoProfile", "-Command", "exit 0") `
    -WorkingDirectory $unrelatedWorkingDirectory

  Assert-InvalidPowerShellCase -Name "dangling-file" `
    -Arguments @("-NoProfile", "-File") `
    -WorkingDirectory $unrelatedWorkingDirectory

  $nodeManifest = Join-Path $systemTempRoot "non-powershell.json"
  Write-MinimalCommandPack -Path $nodeManifest -Tests @(
    New-CommandTest -Id "fixture.non_powershell" -Executable "node" `
      -Arguments @(
        "-e",
        "process.exit(process.argv[1] === '-File' && process.argv[2] === 'relative-fixture-value' ? 0 : 9)",
        "--",
        "-File",
        "relative-fixture-value")
  )
  $nodeResult = Invoke-RunnerCase `
    -ManifestPath $nodeManifest -WorkingDirectory $unrelatedWorkingDirectory
  Assert-Equal $nodeResult.ExitCode 0 `
    "non-PowerShell command must retain normal runner exit behavior"
  Assert-Equal $nodeResult.Output.summary.status "ok" `
    "non-PowerShell command arguments and order must remain unchanged"
  Assert-Equal ([int]$nodeResult.Output.summary.pass) 1 `
    "non-PowerShell command must execute exactly once"
}
finally {
  $cleanupResult = Invoke-OwnedFixtureCleanup `
    -SystemRoot $systemTempRoot -SystemBase $systemTempBase `
    -RepoRoot $repoTempRoot -RepoBase $repoTempBase `
    -Junction $junctionPath -ExpectedRunId $runId `
    -SystemRootCreated $systemRootCreated `
    -SystemMarkerWritten $systemMarkerWritten `
    -RepoRootCreated $repoRootCreated `
    -RepoMarkerWritten $repoMarkerWritten `
    -JunctionCreated $junctionCreated
  if ($null -ne $cleanupResult.FailureClass) {
    throw "fixture_cleanup_incomplete"
  }
}

$systemResidue = @(
  Get-ChildItem -LiteralPath $systemTempBase -Directory `
    -Filter "organ-pack-path-boundary-test-*" -ErrorAction SilentlyContinue
).Count
$repoResidue = @(
  Get-ChildItem -LiteralPath $repoTempBase -Directory `
    -Filter "organ-pack-path-boundary-test-*" -ErrorAction SilentlyContinue
).Count
$managedListeners = @(
  Get-NetTCPConnection -State Listen -ErrorAction Stop |
    Where-Object {
      $_.LocalPort -in @(3000, 8000, 8554, 8765, 8770, 8776, 8787, 8788, 8790, 8799, 8889, 18787, 9222)
    }
).Count
$focusedTestProcess = @(
    Get-CimInstance Win32_Process -Filter "ProcessId = $PID" -ErrorAction Stop
)
Assert-Equal $focusedTestProcess.Count 1 "focused test process identity must resolve exactly once"
$harnessParentPid = [long]$focusedTestProcess[0].ParentProcessId
Assert-True ($harnessParentPid -gt 0 -and $harnessParentPid -ne [long]$PID) "focused test harness parent identity must be deterministic"
$harnessParentProcess = @(
    Get-CimInstance Win32_Process -Filter "ProcessId = $harnessParentPid" -ErrorAction Stop
)
Assert-Equal $harnessParentProcess.Count 1 "focused test harness parent process identity must resolve exactly once"
$focusedHarnessProcessIds = @([long]$PID, $harnessParentPid)

$matchingProcesses = @(
  Get-CimInstance Win32_Process -ErrorAction Stop |
    Where-Object {
      [long]$_.ProcessId -notin $focusedHarnessProcessIds -and
      [string]$_.CommandLine -match
        "run-organ-test-packs|test-state-event-ingest|test-diagnostics-body-state-projection|test-body-schema-current-state"
    }
).Count
Assert-Equal $systemResidue 0 "system owned test temp residue must be zero"
Assert-Equal $repoResidue 0 "repository owned test temp residue must be zero"
Assert-Equal $managedListeners 0 "focused test managed listener residue must be zero"
Assert-Equal $matchingProcesses 0 "focused test matching process residue must be zero"

Write-Output "status=ok"
Write-Output ("assertions={0}" -f $assertions)
Write-Output "bounded_body_schema_command_count=3"
Write-Output "full_standard_pack_traversal_count=0"
Write-Output "live_runtime_invocation_count=0"
Write-Output "owned_temp_residue_count=0"
Write-Output "raw_private_publication_flags=false"
