param(
  [string]$Profile = "standard",
  [string]$DistributionManifestPath = "",
  [switch]$Strict,
  [switch]$Json,
  [switch]$IncludeDeferred,
  [switch]$VerifyRemote
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$RepoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot "lib/common.ps1")

function Invoke-GitRead {
  param([Parameter(Mandatory = $true)][string[]]$Arguments)
  $output = & git @Arguments 2>&1
  $exitCode = $LASTEXITCODE
  return [PSCustomObject]@{
    exit_code = $exitCode
    output = @($output | ForEach-Object { [string]$_ })
  }
}

function Test-GitSuccess {
  param([Parameter(Mandatory = $true)][string[]]$Arguments)
  $result = Invoke-GitRead -Arguments $Arguments
  return ($result.exit_code -eq 0)
}

function Test-GitAncestor {
  param(
    [Parameter(Mandatory = $true)][string]$Target,
    [Parameter(Mandatory = $true)][string]$Ancestor,
    [Parameter(Mandatory = $true)][string]$Descendant
  )
  $result = Invoke-GitRead -Arguments @("-C", $Target, "merge-base", "--is-ancestor", $Ancestor, $Descendant)
  if ($result.exit_code -eq 0) {
    return $true
  }
  if ($result.exit_code -eq 1) {
    return $false
  }
  return $null
}

function Test-GeneratedDirtyLine {
  param([Parameter(Mandatory = $true)][string]$Line)
  if ($Line -notmatch "^\?\? ") {
    return $false
  }
  $path = $Line.Substring(3).Trim() -replace "\\", "/"
  return (
    $path -eq "uv.lock" -or
    $path -match "(^|/)[^/]+\.egg-info(/|$)" -or
    $path -match "^\.venv(/|$)" -or
    $path -match "^node_modules(/|$)"
  )
}

function Split-DirtyLines {
  param([string[]]$Lines)
  $generated = @()
  $blocking = @()
  foreach ($line in @($Lines)) {
    if ([string]::IsNullOrWhiteSpace($line)) {
      continue
    }
    if (Test-GeneratedDirtyLine -Line $line) {
      $generated += $line
    }
    else {
      $blocking += $line
    }
  }
  return [PSCustomObject]@{
    generated = $generated
    blocking = $blocking
  }
}

function Get-CheckoutItems {
  param([Parameter(Mandatory = $true)]$Manifest)

  $items = @()
  $controlPlane = Read-JsonFile -Path ([string]$Manifest.control_plane_manifest_path)
  $items += [PSCustomObject]@{
    id = [string]$controlPlane.id
    kind = "control-plane"
    repo_url = [string]$controlPlane.repo_url
    branch = [string]$controlPlane.branch
    commit = [string]$controlPlane.commit
    target_path = [string]$controlPlane.target_path
    adoption = "standard"
  }

  $organManifest = Read-JsonFile -Path ([string]$Manifest.organ_manifest_path)
  foreach ($source in @($organManifest.sources)) {
    if ([string]$source.adoption -eq "deferred_reference" -and -not $IncludeDeferred) {
      continue
    }
    $items += [PSCustomObject]@{
      id = [string]$source.organ_id
      kind = "organ"
      repo_url = [string]$source.repo_url
      branch = [string]$source.branch
      commit = [string]$source.commit
      target_path = [string]$source.target_path
      adoption = [string]$source.adoption
    }
  }
  return $items
}

function New-PinResult {
  param(
    [Parameter(Mandatory = $true)]$Item,
    [Parameter(Mandatory = $true)][string]$Status,
    [Parameter(Mandatory = $true)][string]$Severity,
    [Parameter(Mandatory = $true)][string]$Detail,
    [string]$CurrentHead = "",
    [string]$CurrentBranch = "",
    [string[]]$DirtyBlocking = @(),
    [string[]]$DirtyGenerated = @(),
    [bool]$StrictViolation = $false
  )

  return [PSCustomObject]@{
    id = [string]$Item.id
    kind = [string]$Item.kind
    target_path = [string]$Item.target_path
    branch = [string]$Item.branch
    expected_commit = [string]$Item.commit
    current_head = $CurrentHead
    current_branch = $CurrentBranch
    status = $Status
    severity = $Severity
    detail = $Detail
    dirty_blocking = @($DirtyBlocking)
    dirty_generated = @($DirtyGenerated)
    strict_violation = $StrictViolation
  }
}

function Test-CheckoutPin {
  param([Parameter(Mandatory = $true)]$Item)

  $target = Resolve-RepoPath ([string]$Item.target_path)
  $expected = [string]$Item.commit
  $branch = [string]$Item.branch

  if (-not (Test-Path -LiteralPath $target -PathType Container)) {
    return New-PinResult -Item $Item -Status "missing_checkout" -Severity "blocker" -Detail "target checkout directory is missing" -StrictViolation $true
  }
  if (-not (Test-Path -LiteralPath (Join-Path $target ".git"))) {
    return New-PinResult -Item $Item -Status "non_git_checkout" -Severity "blocker" -Detail "target path is not a Git checkout" -StrictViolation $true
  }

  $statusRead = Invoke-GitRead -Arguments @("-C", $target, "status", "--porcelain")
  if ($statusRead.exit_code -ne 0) {
    return New-PinResult -Item $Item -Status "git_unreadable" -Severity "warning" -Detail (($statusRead.output | Select-Object -First 3) -join " | ") -StrictViolation $true
  }
  $dirty = Split-DirtyLines -Lines @($statusRead.output)

  $headRead = Invoke-GitRead -Arguments @("-C", $target, "rev-parse", "HEAD")
  if ($headRead.exit_code -ne 0) {
    return New-PinResult -Item $Item -Status "git_unreadable" -Severity "warning" -Detail (($headRead.output | Select-Object -First 3) -join " | ") -StrictViolation $true
  }
  $head = (($headRead.output | Select-Object -First 1) -join "").Trim()

  $branchRead = Invoke-GitRead -Arguments @("-C", $target, "branch", "--show-current")
  $currentBranch = ""
  if ($branchRead.exit_code -eq 0) {
    $currentBranch = (($branchRead.output | Select-Object -First 1) -join "").Trim()
  }

  $commitExists = Test-GitSuccess -Arguments @("-C", $target, "cat-file", "-e", "$expected^{commit}")
  if (-not $commitExists) {
    return New-PinResult -Item $Item -Status "manifest_commit_missing_locally" -Severity "blocker" -Detail "expected manifest commit is not available in this checkout; run installer/update with network access or check the manifest pin" -CurrentHead $head -CurrentBranch $currentBranch -DirtyBlocking $dirty.blocking -DirtyGenerated $dirty.generated -StrictViolation $true
  }

  $branchMismatch = (-not [string]::IsNullOrWhiteSpace($currentBranch) -and $currentBranch -ne $branch)
  $dirtyViolation = ($dirty.blocking.Count -gt 0)

  if ($head -eq $expected) {
    if ($dirtyViolation) {
      return New-PinResult -Item $Item -Status "dirty_at_manifest_pin" -Severity "warning" -Detail "checkout is at the manifest pin but has local source changes" -CurrentHead $head -CurrentBranch $currentBranch -DirtyBlocking $dirty.blocking -DirtyGenerated $dirty.generated -StrictViolation $true
    }
    if ($branchMismatch) {
      return New-PinResult -Item $Item -Status "branch_mismatch_at_manifest_pin" -Severity "warning" -Detail "checkout is at the manifest pin but on a different named branch" -CurrentHead $head -CurrentBranch $currentBranch -DirtyBlocking $dirty.blocking -DirtyGenerated $dirty.generated -StrictViolation $true
    }
    return New-PinResult -Item $Item -Status "ok" -Severity "ok" -Detail "checkout matches manifest pin" -CurrentHead $head -CurrentBranch $currentBranch -DirtyBlocking $dirty.blocking -DirtyGenerated $dirty.generated
  }

  if ($dirtyViolation) {
    return New-PinResult -Item $Item -Status "dirty_not_at_manifest_pin" -Severity "blocker" -Detail "checkout is dirty and does not match manifest pin" -CurrentHead $head -CurrentBranch $currentBranch -DirtyBlocking $dirty.blocking -DirtyGenerated $dirty.generated -StrictViolation $true
  }

  $expectedAncestorOfHead = Test-GitAncestor -Target $target -Ancestor $expected -Descendant $head
  if ($expectedAncestorOfHead -eq $true) {
    return New-PinResult -Item $Item -Status "ahead_of_manifest" -Severity "warning" -Detail "checkout is ahead of the manifest pin; parent adoption decision required before release" -CurrentHead $head -CurrentBranch $currentBranch -DirtyBlocking $dirty.blocking -DirtyGenerated $dirty.generated -StrictViolation $true
  }

  $headAncestorOfExpected = Test-GitAncestor -Target $target -Ancestor $head -Descendant $expected
  if ($headAncestorOfExpected -eq $true) {
    return New-PinResult -Item $Item -Status "behind_manifest" -Severity "blocker" -Detail "checkout is behind the manifest pin; run update-distribution or reinstall" -CurrentHead $head -CurrentBranch $currentBranch -DirtyBlocking $dirty.blocking -DirtyGenerated $dirty.generated -StrictViolation $true
  }

  return New-PinResult -Item $Item -Status "pin_mismatch" -Severity "blocker" -Detail "checkout head is not related to the manifest pin by a simple ancestry check" -CurrentHead $head -CurrentBranch $currentBranch -DirtyBlocking $dirty.blocking -DirtyGenerated $dirty.generated -StrictViolation $true
}

function Test-RemoteHead {
  param([Parameter(Mandatory = $true)]$Item)
  $line = Invoke-GitRead -Arguments @("ls-remote", ([string]$Item.repo_url), "refs/heads/$($Item.branch)")
  if ($line.exit_code -ne 0 -or [string]::IsNullOrWhiteSpace(($line.output -join ""))) {
    return [PSCustomObject]@{
      id = [string]$Item.id
      status = "remote_unreadable"
      detail = (($line.output | Select-Object -First 3) -join " | ")
    }
  }
  $remoteCommit = ((($line.output | Select-Object -First 1) -split "`t")[0]).Trim()
  return [PSCustomObject]@{
    id = [string]$Item.id
    status = $(if ($remoteCommit -eq [string]$Item.commit) { "ok" } else { "remote_head_differs_from_manifest" })
    remote_head = $remoteCommit
    expected_commit = [string]$Item.commit
  }
}

if ([string]::IsNullOrWhiteSpace($DistributionManifestPath)) {
  $DistributionManifestPath = "manifests/distributions/$Profile.json"
}

$manifest = Read-JsonFile -Path $DistributionManifestPath
$items = @(Get-CheckoutItems -Manifest $manifest)
$pinResults = @()
$remoteResults = @()
foreach ($item in $items) {
  $pinResults += Test-CheckoutPin -Item $item
  if ($VerifyRemote) {
    $remoteResults += Test-RemoteHead -Item $item
  }
}

$counts = [ordered]@{}
foreach ($result in $pinResults) {
  if (-not $counts.Contains($result.status)) {
    $counts[$result.status] = 0
  }
  $counts[$result.status] = [int]$counts[$result.status] + 1
}

$strictViolations = @($pinResults | Where-Object { [bool]$_.strict_violation })
$blocking = @($pinResults | Where-Object { [string]$_.severity -eq "blocker" })
$warnings = @($pinResults | Where-Object { [string]$_.severity -eq "warning" })
$remoteProblems = @($remoteResults | Where-Object { [string]$_.status -ne "ok" })

$status = "ok"
if ($blocking.Count -gt 0 -or ($Strict -and $strictViolations.Count -gt 0) -or ($VerifyRemote -and $remoteProblems.Count -gt 0)) {
  $status = "blocked"
}
elseif ($warnings.Count -gt 0) {
  $status = "warning"
}

$summary = [PSCustomObject]@{
  status = $status
  profile = $Profile
  strict = [bool]$Strict
  verify_remote = [bool]$VerifyRemote
  total = $pinResults.Count
  counts = $counts
  strict_violations = $strictViolations.Count
  items = $pinResults
  remote = $remoteResults
}

if ($Json) {
  $summary | ConvertTo-Json -Depth 10
}
else {
  Write-Host "Sword Agent OS distribution pin check"
  Write-Host "  Profile : $Profile"
  Write-Host "  Status  : $status"
  Write-Host "  Strict  : $([bool]$Strict)"
  Write-Host ""
  foreach ($result in $pinResults) {
    $shortExpected = $result.expected_commit
    if ($shortExpected.Length -gt 7) { $shortExpected = $shortExpected.Substring(0, 7) }
    $shortHead = $result.current_head
    if ($shortHead.Length -gt 7) { $shortHead = $shortHead.Substring(0, 7) }
    if ([string]::IsNullOrWhiteSpace($shortHead)) { $shortHead = "-" }
    Write-Host ("{0,-10} {1,-32} {2,-30} expected={3} head={4}" -f $result.severity, $result.id, $result.status, $shortExpected, $shortHead)
    if ([string]$result.status -ne "ok") {
      Write-Host "  $($result.detail)"
    }
  }
  if ($VerifyRemote -and $remoteResults.Count -gt 0) {
    Write-Host ""
    Write-Host "Remote branch head checks:"
    foreach ($remote in $remoteResults) {
      Write-Host ("{0,-32} {1}" -f $remote.id, $remote.status)
    }
  }
  Write-Host ""
  Write-Host "Summary:"
  foreach ($key in $counts.Keys) {
    Write-Host "  ${key}: $($counts[$key])"
  }
}

if ($Strict -and ($status -ne "ok")) {
  exit 1
}
if ($VerifyRemote -and $remoteProblems.Count -gt 0) {
  exit 1
}
exit 0
