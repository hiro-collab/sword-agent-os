param(
  [string]$Profile = "standard",
  [string]$DistributionManifestPath = "",
  [switch]$DryRun,
  [switch]$NoDeps,
  [switch]$NoEnv,
  [switch]$ForceEnv,
  [switch]$VerifyRemote,
  [switch]$IncludeDeferred
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

function Invoke-Step {
  param(
    [Parameter(Mandatory = $true)][string[]]$Command,
    [string]$WorkingDirectory = $RepoRoot
  )
  if ($Command.Count -eq 0) {
    return
  }
  if ($DryRun) {
    Write-Host "cd $WorkingDirectory"
    Write-Host ($Command -join " ")
    return
  }
  Push-Location $WorkingDirectory
  try {
    $exe = $Command[0]
    $stepArgs = @()
    if ($Command.Count -gt 1) {
      $stepArgs = $Command[1..($Command.Count - 1)]
    }
    & $exe @stepArgs
    $exitCode = $LASTEXITCODE
    if ($null -ne $exitCode -and $exitCode -ne 0) {
      throw "command failed with exit code ${exitCode}: $($Command -join ' ')"
    }
  }
  finally {
    Pop-Location
  }
}

function Test-RemotePin {
  param([Parameter(Mandatory = $true)]$Item)
  $line = @(Invoke-GitReadChecked -Arguments @("ls-remote", ([string]$Item.repo_url), "refs/heads/$($Item.branch)"))
  if ([string]::IsNullOrWhiteSpace(($line -join ""))) {
    throw "remote branch not found for $($Item.id): $($Item.branch)"
  }
  $remoteCommit = (($line | Select-Object -First 1) -split "`t")[0]
  if ($remoteCommit -ne [string]$Item.commit) {
    throw "remote commit mismatch for $($Item.id): expected $($Item.commit), got $remoteCommit"
  }
  Write-Host "remote verified: $($Item.id) $($Item.commit.Substring(0, 7))"
}

function Invoke-GitReadChecked {
  param([Parameter(Mandatory = $true)][string[]]$Arguments)
  $output = & git @Arguments 2>&1
  $exitCode = $LASTEXITCODE
  if ($exitCode -ne 0) {
    $details = (@($output) | ForEach-Object { [string]$_ }) -join "`n"
    if (-not [string]::IsNullOrWhiteSpace($details)) {
      throw "git failed: git $($Arguments -join ' ')`n$details"
    }
    throw "git failed: git $($Arguments -join ' ')"
  }
  return @($output | ForEach-Object { [string]$_ })
}

function Invoke-GitChecked {
  param([Parameter(Mandatory = $true)][string[]]$Arguments)
  $output = @(Invoke-GitReadChecked -Arguments $Arguments)
  foreach ($line in @($output)) {
    if (-not [string]::IsNullOrWhiteSpace([string]$line)) {
      Write-Host $line
    }
  }
}

function Format-GitHoldFailure {
  param([Parameter(Mandatory = $true)][string]$Message)
  if ($Message -match "detected dubious ownership") {
    return "Git ownership check blocked this sandbox/user from reading the checkout. Run the same command as the normal workspace user, or use an exact per-command safe.directory override for diagnosis; do not treat this as a source pin mismatch."
  }
  $lines = @($Message -split '\r\n|\n|\r' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
  if ($lines.Count -eq 0) {
    return "Git command failed without details"
  }
  return (($lines | Select-Object -First 3) -join " | ")
}

function Get-GitReadOrHold {
  param(
    [Parameter(Mandatory = $true)][string[]]$Arguments,
    [Parameter(Mandatory = $true)][string]$Label,
    [Parameter(Mandatory = $true)][string]$Operation
  )
  try {
    $output = @(Invoke-GitReadChecked -Arguments $Arguments)
    return [PSCustomObject]@{
      ok = $true
      output = $output
    }
  }
  catch {
    Write-Warning "hold git ${Operation} failed for ${Label}: $(Format-GitHoldFailure -Message ([string]$_.Exception.Message))"
    return [PSCustomObject]@{
      ok = $false
      output = @()
    }
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
      Write-Host "skip deferred organ: $($source.organ_id)"
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

function Update-Checkout {
  param([Parameter(Mandatory = $true)]$Item)

  $target = Resolve-RepoPath ([string]$Item.target_path)
  $expected = [string]$Item.commit
  $branch = [string]$Item.branch
  $label = "$($Item.kind):$($Item.id)"

  if ($VerifyRemote) {
    Test-RemotePin -Item $Item
  }

  if (-not (Test-Path -LiteralPath $target -PathType Container)) {
    Write-Warning "hold missing checkout: $label -> $target"
    return "held"
  }
  if (-not (Test-Path -LiteralPath (Join-Path $target ".git"))) {
    Write-Warning "hold non-git checkout path: $label -> $target"
    return "held"
  }

  $dirtyRead = Get-GitReadOrHold -Arguments @("-C", $target, "status", "--porcelain") -Label $label -Operation "status"
  if (-not $dirtyRead.ok) {
    return "held"
  }
  $dirty = @($dirtyRead.output)
  $dirtySplit = Split-DirtyLines -Lines $dirty
  if ($dirtySplit.blocking.Count -gt 0) {
    Write-Warning "hold dirty checkout: $label"
    foreach ($line in @($dirtySplit.blocking | Select-Object -First 5)) {
      Write-Warning "  $line"
    }
    return "held"
  }
  if ($dirtySplit.generated.Count -gt 0) {
    Write-Warning "generated local files ignored for update: $label"
    foreach ($line in @($dirtySplit.generated | Select-Object -First 5)) {
      Write-Warning "  $line"
    }
  }

  $branchRead = Get-GitReadOrHold -Arguments @("-C", $target, "branch", "--show-current") -Label $label -Operation "branch"
  if (-not $branchRead.ok) {
    return "held"
  }
  $currentBranch = (($branchRead.output | Select-Object -First 1) -join "").Trim()
  if (-not [string]::IsNullOrWhiteSpace($currentBranch) -and $currentBranch -ne $branch) {
    Write-Warning "hold branch mismatch for ${label}: expected $branch, got $currentBranch"
    return "held"
  }
  $headRead = Get-GitReadOrHold -Arguments @("-C", $target, "rev-parse", "HEAD") -Label $label -Operation "rev-parse"
  if (-not $headRead.ok) {
    return "held"
  }
  $head = (($headRead.output | Select-Object -First 1) -join "").Trim()
  if ($head -eq $expected) {
    Write-Host "up-to-date: $label $($expected.Substring(0, 7))"
    return "up_to_date"
  }

  if ($DryRun) {
    Write-Host "update planned: $label $($head.Substring(0, 7)) -> $($expected.Substring(0, 7))"
    Invoke-Step -Command @("git", "-C", $target, "fetch", "origin", $branch)
    Invoke-Step -Command @("git", "-C", $target, "merge", "--ff-only", $expected)
    return "planned"
  }

  Invoke-GitChecked -Arguments @("-C", $target, "fetch", "origin", $branch)
  Invoke-GitChecked -Arguments @("-C", $target, "cat-file", "-e", "$expected^{commit}")
  $mergeBaseOutput = & git -C $target merge-base --is-ancestor $head $expected 2>&1
  $mergeBaseExitCode = $LASTEXITCODE
  if ($mergeBaseExitCode -eq 1) {
    Write-Warning "hold non-fast-forward update: $label $($head.Substring(0, 7)) -> $($expected.Substring(0, 7))"
    return "held"
  }
  if ($mergeBaseExitCode -ne 0) {
    $mergeDetails = (@($mergeBaseOutput) | ForEach-Object { [string]$_ }) -join "`n"
    if (-not [string]::IsNullOrWhiteSpace($mergeDetails)) {
      throw "git failed: git -C $target merge-base --is-ancestor $head $expected`n$mergeDetails"
    }
    throw "git failed: git -C $target merge-base --is-ancestor $head $expected"
  }

  Invoke-GitChecked -Arguments @("-C", $target, "merge", "--ff-only", $expected)
  $newHead = ((Invoke-GitReadChecked -Arguments @("-C", $target, "rev-parse", "HEAD") | Select-Object -First 1) -join "").Trim()
  if ($newHead -ne $expected) {
    throw "update did not reach manifest pin for ${label}: expected $expected, got $newHead"
  }
  Write-Host "updated: $label $($expected.Substring(0, 7))"
  return "updated"
}

function Invoke-EnvRender {
  $renderArgs = @("-NoProfile", "-File", (Join-Path $PSScriptRoot "render-env-files.ps1"), "-Profile", $Profile)
  if (-not [string]::IsNullOrWhiteSpace($DistributionManifestPath)) {
    $renderArgs += @("-DistributionManifestPath", $DistributionManifestPath)
  }
  if ($DryRun) {
    $renderArgs += "-DryRun"
  }
  if ($ForceEnv) {
    $renderArgs += "-Force"
  }
  Invoke-Step -Command (@("pwsh") + $renderArgs)
}

function Invoke-DependencyInstall {
  param(
    [Parameter(Mandatory = $true)]$Manifest,
    [hashtable]$HeldDependencyIds = @{}
  )
  foreach ($dep in @($Manifest.dependencies)) {
    $id = [string]$dep.id
    if ($HeldDependencyIds.ContainsKey($id)) {
      Write-Warning "dependency skip held checkout: $id"
      continue
    }
    $path = Resolve-RepoPath ([string]$dep.path)
    $command = @($dep.command | ForEach-Object { [string]$_ })
    if ($command.Count -eq 0) {
      Write-Host "dependency skip: $id (no command)"
      continue
    }
    if (-not (Test-Path -LiteralPath $path -PathType Container)) {
      Write-Warning "dependency path missing for ${id}: $path"
      continue
    }
    Write-Host "dependency install: $id"
    Invoke-Step -Command $command -WorkingDirectory $path
  }
}

if ([string]::IsNullOrWhiteSpace($DistributionManifestPath)) {
  $DistributionManifestPath = "manifests/distributions/$Profile.json"
}

$manifest = Read-JsonFile -Path $DistributionManifestPath

Write-Host "Sword Agent OS distribution update"
Write-Host "  Repo root: $RepoRoot"
Write-Host "  Profile  : $Profile"
Write-Host "  Manifest : $DistributionManifestPath"
Write-Host ""

$counts = @{
  planned = 0
  updated = 0
  up_to_date = 0
  held = 0
}
$heldDependencyIds = @{}

foreach ($item in @(Get-CheckoutItems -Manifest $manifest)) {
  $result = Update-Checkout -Item $item
  $counts[$result] = [int]$counts[$result] + 1
  if ($result -eq "held") {
    if ([string]$item.kind -eq "control-plane") {
      $heldDependencyIds["control-plane"] = $true
    }
    else {
      $heldDependencyIds[[string]$item.id] = $true
    }
  }
}

if (-not $NoEnv) {
  Write-Host ""
  Write-Host "Render missing local env/config files"
  Invoke-EnvRender
}
else {
  Write-Host "env rendering skipped: -NoEnv"
}

if (-not $NoDeps) {
  Write-Host ""
  Write-Host "Install/update dependencies"
  Invoke-DependencyInstall -Manifest $manifest -HeldDependencyIds $heldDependencyIds
}
else {
  Write-Host "dependency install skipped: -NoDeps"
}

Write-Host ""
Write-Host "Validate manifests"
Invoke-Step -Command @("pwsh", "-NoProfile", "-File", (Join-Path $PSScriptRoot "validate-manifests.ps1"))

Write-Host ""
Write-Host "Update summary:"
Write-Host "  planned   : $($counts.planned)"
Write-Host "  updated   : $($counts.updated)"
Write-Host "  up-to-date: $($counts.up_to_date)"
Write-Host "  held      : $($counts.held)"
if ([int]$counts.held -gt 0) {
  Write-Host ""
  Write-Host "Some checkouts were held. Inspect their git status before updating them manually."
}
