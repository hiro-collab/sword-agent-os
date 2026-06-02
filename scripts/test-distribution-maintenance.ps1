param(
  [string]$Profile = "standard",
  [string]$DistributionManifestPath = "",
  [string]$TempRoot = "",
  [switch]$SkipFreshClone,
  [switch]$KeepTemp,
  [switch]$RequireAssembledCheckouts,
  [switch]$VerifyRemote
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$RepoRoot = Split-Path -Parent $PSScriptRoot

function Write-TestStep {
  param([Parameter(Mandatory = $true)][string]$Message)
  Write-Host ""
  Write-Host "[maintenance-test] $Message" -ForegroundColor Cyan
}

function Get-PowerShellCommand {
  $pwsh = Get-Command pwsh -ErrorAction SilentlyContinue
  if ($null -ne $pwsh) {
    return $pwsh.Source
  }
  $powershell = Get-Command powershell -ErrorAction SilentlyContinue
  if ($null -ne $powershell) {
    return $powershell.Source
  }
  throw "PowerShell command not found"
}

$PowerShellCommand = Get-PowerShellCommand

function Invoke-Checked {
  param(
    [Parameter(Mandatory = $true)][string[]]$Command,
    [string]$WorkingDirectory = $RepoRoot
  )
  Push-Location $WorkingDirectory
  try {
    Write-Host ("> {0}" -f ($Command -join " "))
    $output = & $Command[0] @($Command | Select-Object -Skip 1) 2>&1
    $exitCode = $LASTEXITCODE
    foreach ($line in @($output)) {
      Write-Host $line
    }
    if ($exitCode -ne 0) {
      throw "command failed with exit code ${exitCode}: $($Command -join ' ')"
    }
    return @($output | ForEach-Object { [string]$_ })
  }
  finally {
    Pop-Location
  }
}

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

function Test-PowerShellSyntax {
  Write-TestStep "PowerShell script syntax"
  $scripts = Get-ChildItem -LiteralPath (Join-Path $RepoRoot "scripts") -Filter "*.ps1" -File
  foreach ($script in $scripts) {
    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($script.FullName, [ref]$tokens, [ref]$errors) | Out-Null
    if (@($errors).Count -gt 0) {
      $messages = @($errors | ForEach-Object { "$($_.Extent.StartLineNumber): $($_.Message)" })
      throw "syntax error in $($script.Name): $($messages -join '; ')"
    }
    Write-Host "syntax ok: $($script.Name)"
  }
}

function Test-BatchWrappers {
  Write-TestStep "batch wrapper targets"
  $batches = Get-ChildItem -LiteralPath $RepoRoot -Filter "*.bat" -File
  foreach ($batch in $batches) {
    $content = Get-Content -Raw -LiteralPath $batch.FullName
    if ($content -notmatch 'set\s+"TARGET=%~dp0scripts\\([^"]+\.ps1)"') {
      throw "batch wrapper missing TARGET script: $($batch.Name)"
    }
    $targetScript = Join-Path (Join-Path $RepoRoot "scripts") $Matches[1]
    if (-not (Test-Path -LiteralPath $targetScript -PathType Leaf)) {
      throw "batch wrapper target missing for $($batch.Name): $targetScript"
    }
    if ($content -notmatch "-NoProfile" -or $content -notmatch "ExecutionPolicy Bypass") {
      throw "batch wrapper should use NoProfile and ExecutionPolicy Bypass: $($batch.Name)"
    }
    if ($content -notmatch "(?m)^\s*powershell\s") {
      throw "batch wrapper missing Windows PowerShell fallback: $($batch.Name)"
    }
    Write-Host "batch ok: $($batch.Name) -> $(Split-Path -Leaf $targetScript)"
  }
}

function Test-ManifestAndVersion {
  Write-TestStep "manifest and version commands"
  $validateArgs = @($PowerShellCommand, "-NoProfile", "-File", (Join-Path $PSScriptRoot "validate-manifests.ps1"))
  if ($VerifyRemote) {
    $validateArgs += "-VerifyRemote"
  }
  Invoke-Checked -Command $validateArgs | Out-Null
  Invoke-Checked -Command @($PowerShellCommand, "-NoProfile", "-File", (Join-Path $PSScriptRoot "show-version.ps1"), "-Profile", $Profile) | Out-Null
}

function Get-DistributionManifestPath {
  if ([string]::IsNullOrWhiteSpace($DistributionManifestPath)) {
    return "manifests/distributions/$Profile.json"
  }
  return $DistributionManifestPath
}

function Test-AssembledCheckoutState {
  $manifest = Read-JsonFile -Path (Get-DistributionManifestPath)
  $items = @()
  $controlPlane = Read-JsonFile -Path ([string]$manifest.control_plane_manifest_path)
  $items += [PSCustomObject]@{
    id = [string]$controlPlane.id
    target_path = [string]$controlPlane.target_path
  }
  $organManifest = Read-JsonFile -Path ([string]$manifest.organ_manifest_path)
  foreach ($source in @($organManifest.sources)) {
    if ([string]$source.adoption -eq "deferred_reference") {
      continue
    }
    $items += [PSCustomObject]@{
      id = [string]$source.organ_id
      target_path = [string]$source.target_path
    }
  }

  $missing = @()
  foreach ($item in $items) {
    $target = Resolve-RepoPath ([string]$item.target_path)
    if (-not (Test-Path -LiteralPath (Join-Path $target ".git"))) {
      $missing += [string]$item.id
    }
  }
  return [PSCustomObject]@{
    assembled = ($missing.Count -eq 0)
    missing = $missing
  }
}

function Test-InstalledWorkspaceMaintenance {
  Write-TestStep "installed workspace dry-run maintenance"
  $state = Test-AssembledCheckoutState
  if (-not $state.assembled) {
    $message = "assembled checkouts missing: $($state.missing -join ', ')"
    if ($RequireAssembledCheckouts) {
      throw $message
    }
    Write-Warning "$message; skipping held=0 update assertion"
    return
  }

  $updateOutput = Invoke-Checked -Command @(
    $PowerShellCommand,
    "-NoProfile",
    "-File",
    (Join-Path $PSScriptRoot "update-distribution.ps1"),
    "-Profile",
    $Profile,
    "-DryRun",
    "-NoDeps"
  )
  if (($updateOutput -join "`n") -notmatch "held\s*:\s*0") {
    throw "installed update dry-run did not report held: 0"
  }

  Invoke-Checked -Command @(
    $PowerShellCommand,
    "-NoProfile",
    "-File",
    (Join-Path $PSScriptRoot "render-env-files.ps1"),
    "-Profile",
    $Profile,
    "-DryRun",
    "-NoCreateCentralEnv"
  ) | Out-Null
}

function New-FreshTestRoot {
  if (-not [string]::IsNullOrWhiteSpace($TempRoot)) {
    New-Item -ItemType Directory -Force -Path $TempRoot | Out-Null
    return (Resolve-Path -LiteralPath $TempRoot).Path
  }
  $root = Join-Path ([System.IO.Path]::GetTempPath()) ("sword-agent-os-maintenance-test-" + [guid]::NewGuid().ToString("N"))
  New-Item -ItemType Directory -Force -Path $root | Out-Null
  return $root
}

function Remove-FreshTestRoot {
  param([Parameter(Mandatory = $true)][string]$Path)
  if ($KeepTemp) {
    Write-Host "keeping temp root: $Path"
    return
  }
  $resolved = [System.IO.Path]::GetFullPath($Path)
  $tempBase = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
  $leaf = Split-Path -Leaf $resolved
  if (-not $resolved.StartsWith($tempBase, [System.StringComparison]::OrdinalIgnoreCase) -or
      -not $leaf.StartsWith("sword-agent-os-maintenance-test-", [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "refusing to remove unexpected temp root: $resolved"
  }
  Remove-Item -LiteralPath $resolved -Recurse -Force
}

function Test-FreshCloneDryRun {
  if ($SkipFreshClone) {
    Write-Warning "fresh clone dry-run skipped"
    return
  }

  Write-TestStep "fresh clone install/update dry-run"
  $root = New-FreshTestRoot
  try {
    $clonePath = Join-Path $root "sword-agent-os"
    Invoke-Checked -Command @("git", "clone", "--local", "--no-hardlinks", $RepoRoot, $clonePath) -WorkingDirectory $root | Out-Null

    $bootstrapOutput = Invoke-Checked -Command @(
      $PowerShellCommand,
      "-NoProfile",
      "-File",
      (Join-Path $clonePath "scripts/bootstrap-workspace.ps1")
    ) -WorkingDirectory $clonePath
    if (($bootstrapOutput -join "`n") -notmatch "No workspace-local directories requested") {
      throw "bootstrap-workspace default output did not confirm no extra directories"
    }
    foreach ($unexpected in @("_codex", "coordination", "local", "worktrees")) {
      if (Test-Path -LiteralPath (Join-Path $root $unexpected)) {
        throw "bootstrap-workspace default created unexpected sibling directory: $unexpected"
      }
    }

    Invoke-Checked -Command @(
      $PowerShellCommand,
      "-NoProfile",
      "-File",
      (Join-Path $clonePath "scripts/install-distribution.ps1"),
      "-Profile",
      $Profile,
      "-DryRun",
      "-NoDeps"
    ) -WorkingDirectory $clonePath | Out-Null

    Invoke-Checked -Command @(
      $PowerShellCommand,
      "-NoProfile",
      "-File",
      (Join-Path $clonePath "scripts/render-env-files.ps1"),
      "-Profile",
      $Profile,
      "-DryRun",
      "-NoCreateCentralEnv"
    ) -WorkingDirectory $clonePath | Out-Null

    Invoke-Checked -Command @(
      $PowerShellCommand,
      "-NoProfile",
      "-File",
      (Join-Path $clonePath "scripts/update-distribution.ps1"),
      "-Profile",
      $Profile,
      "-DryRun",
      "-NoDeps",
      "-NoEnv"
    ) -WorkingDirectory $clonePath | Out-Null
  }
  finally {
    Remove-FreshTestRoot -Path $root
  }
}

Test-PowerShellSyntax
Test-BatchWrappers
Test-ManifestAndVersion
Test-InstalledWorkspaceMaintenance
Test-FreshCloneDryRun

Write-Host ""
Write-Host "maintenance smoke tests: ok" -ForegroundColor Green
