param(
  [string]$ManifestPath = "",
  [switch]$DryRun,
  [switch]$IncludeDeferred,
  [switch]$VerifyRemote
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$RepoRoot = Split-Path -Parent $PSScriptRoot

if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
  $ManifestPath = Join-Path $RepoRoot "manifests\organs\standard-sources.json"
}
elseif (-not [System.IO.Path]::IsPathRooted($ManifestPath)) {
  $ManifestPath = Join-Path $RepoRoot $ManifestPath
}

$manifest = Get-Content -Raw -LiteralPath $ManifestPath | ConvertFrom-Json

function Invoke-Step {
  param(
    [Parameter(Mandatory = $true)][string[]]$Command,
    [string]$WorkingDirectory = $RepoRoot
  )

  if ($DryRun) {
    Write-Host "cd $WorkingDirectory"
    Write-Host ($Command -join " ")
    return
  }

  Push-Location $WorkingDirectory
  try {
    $exe = $Command[0]
    $args = @()
    if ($Command.Count -gt 1) {
      $args = $Command[1..($Command.Count - 1)]
    }
    & $exe @args
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
      throw "command failed with exit code ${exitCode}: $($Command -join ' ')"
    }
  }
  finally {
    Pop-Location
  }
}

function Invoke-Git {
  param(
    [Parameter(Mandatory = $true)][string[]]$Arguments,
    [string]$WorkingDirectory = $RepoRoot
  )

  Push-Location $WorkingDirectory
  try {
    $output = & git @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
      throw "git failed with exit code ${exitCode}: git $($Arguments -join ' ')"
    }
    return @($output)
  }
  finally {
    Pop-Location
  }
}

function Test-GitCommitExists {
  param(
    [Parameter(Mandatory = $true)][string]$Target,
    [Parameter(Mandatory = $true)][string]$Commit
  )

  try {
    Invoke-Git -WorkingDirectory $Target -Arguments @("cat-file", "-e", "$Commit^{commit}") | Out-Null
    return $true
  }
  catch {
    return $false
  }
}

function Ensure-ManifestPin {
  param(
    [Parameter(Mandatory = $true)][string]$Target,
    [Parameter(Mandatory = $true)][string]$OrganId,
    [Parameter(Mandatory = $true)][string]$Branch,
    [Parameter(Mandatory = $true)][string]$Expected
  )

  $dirty = Invoke-Git -WorkingDirectory $Target -Arguments @("status", "--short")
  $head = (((Invoke-Git -WorkingDirectory $Target -Arguments @("rev-parse", "HEAD")) | Select-Object -First 1) -join "").Trim()
  $currentBranch = (((Invoke-Git -WorkingDirectory $Target -Arguments @("branch", "--show-current")) | Select-Object -First 1) -join "").Trim()

  if ($head -ne $Expected) {
    if (-not [string]::IsNullOrWhiteSpace(($dirty -join ""))) {
      if ($DryRun) {
        Write-Warning "organ checkout is dirty and not at manifest pin: $OrganId expected $Expected, got $head"
        return
      }
      throw "organ checkout is dirty and not at manifest pin: $OrganId expected $Expected, got $head"
    }
    if ($DryRun) {
      if (-not (Test-GitCommitExists -Target $Target -Commit $Expected)) {
        Invoke-Step -WorkingDirectory $Target -Command @("git", "fetch", "origin", $Branch)
      }
      Invoke-Step -WorkingDirectory $Target -Command @("git", "checkout", "--detach", $Expected)
      Write-Host "would verify: $OrganId $($Expected.Substring(0, 7))"
      return
    }
    if (-not (Test-GitCommitExists -Target $Target -Commit $Expected)) {
      Invoke-Step -WorkingDirectory $Target -Command @("git", "fetch", "origin", $Branch)
    }
    Invoke-Step -WorkingDirectory $Target -Command @("git", "checkout", "--detach", $Expected)
    $head = (((Invoke-Git -WorkingDirectory $Target -Arguments @("rev-parse", "HEAD")) | Select-Object -First 1) -join "").Trim()
    $currentBranch = (((Invoke-Git -WorkingDirectory $Target -Arguments @("branch", "--show-current")) | Select-Object -First 1) -join "").Trim()
    if ($head -ne $Expected) {
      throw "organ checkout did not reach manifest pin: $OrganId expected $Expected, got $head"
    }
  }

  if (-not [string]::IsNullOrWhiteSpace(($dirty -join ""))) {
    Write-Warning "dirty organ checkout: $OrganId"
  }
  if (-not [string]::IsNullOrWhiteSpace($currentBranch) -and $currentBranch -ne $Branch) {
    Write-Warning "branch mismatch for ${OrganId}: expected $Branch, got $currentBranch"
  }
  Write-Host "verified: $OrganId $($Expected.Substring(0, 7))"
}

function Get-RelativeTarget {
  param([Parameter(Mandatory = $true)][string]$Path)
  return ($Path -replace "/", [System.IO.Path]::DirectorySeparatorChar)
}

foreach ($source in $manifest.sources) {
  if ($source.adoption -eq "deferred_reference" -and -not $IncludeDeferred) {
    Write-Host "skip deferred organ: $($source.organ_id)"
    continue
  }

  $target = Join-Path $RepoRoot (Get-RelativeTarget -Path $source.target_path)
  $parent = Split-Path -Parent $target

  if ($VerifyRemote) {
    $line = Invoke-Git -Arguments @("ls-remote", ([string]$source.repo_url), "refs/heads/$($source.branch)")
    if ([string]::IsNullOrWhiteSpace(($line -join ""))) {
      throw "remote branch not found for $($source.organ_id): $($source.branch)"
    }
    $remoteCommit = (($line | Select-Object -First 1) -split "`t")[0]
    if ($remoteCommit -ne [string]$source.commit) {
      throw "remote commit mismatch for $($source.organ_id): expected $($source.commit), got $remoteCommit"
    }
    Write-Host "remote verified: $($source.organ_id) $($source.commit.Substring(0, 7))"
  }

  if (-not (Test-Path -LiteralPath $parent)) {
    if ($DryRun) {
      Write-Host "New-Item -ItemType Directory -Force -Path $parent"
    }
    else {
      New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }
  }

  if (-not (Test-Path -LiteralPath $target)) {
    Invoke-Step -Command @(
      "git",
      "clone",
      "--branch",
      [string]$source.branch,
      [string]$source.repo_url,
      $target
    )
  }
  elseif (-not (Test-Path -LiteralPath (Join-Path $target ".git"))) {
    throw "target exists but is not a git checkout: $target"
  }
  else {
    Write-Host "exists: $target"
  }

  if (Test-Path -LiteralPath (Join-Path $target ".git")) {
    Ensure-ManifestPin `
      -Target $target `
      -OrganId ([string]$source.organ_id) `
      -Branch ([string]$source.branch) `
      -Expected ([string]$source.commit)
  }
}
