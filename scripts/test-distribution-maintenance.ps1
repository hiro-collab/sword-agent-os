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
  $previousErrorActionPreference = $ErrorActionPreference
  $stdoutPath = [System.IO.Path]::GetTempFileName()
  $stderrPath = [System.IO.Path]::GetTempFileName()
  try {
    Write-Host ("> {0}" -f ($Command -join " "))
    $ErrorActionPreference = "Continue"
    & $Command[0] @($Command | Select-Object -Skip 1) > $stdoutPath 2> $stderrPath
    $exitCode = $LASTEXITCODE
    $output = @()
    if (Test-Path -LiteralPath $stdoutPath -PathType Leaf) {
      $output += @(Get-Content -LiteralPath $stdoutPath)
    }
    if ($exitCode -ne 0 -and (Test-Path -LiteralPath $stderrPath -PathType Leaf)) {
      $output += @(Get-Content -LiteralPath $stderrPath)
    }
    foreach ($line in @($output)) {
      Write-Host $line
    }
    if ($exitCode -ne 0) {
      throw "command failed with exit code ${exitCode}: $($Command -join ' ')"
    }
    return @($output | ForEach-Object { [string]$_ })
  }
  finally {
    $ErrorActionPreference = $previousErrorActionPreference
    Remove-Item -LiteralPath $stdoutPath, $stderrPath -Force -ErrorAction SilentlyContinue
    Pop-Location
  }
}

function Invoke-ExpectFailure {
  param(
    [Parameter(Mandatory = $true)][string[]]$Command,
    [string]$WorkingDirectory = $RepoRoot
  )
  Push-Location $WorkingDirectory
  $previousErrorActionPreference = $ErrorActionPreference
  $stdoutPath = [System.IO.Path]::GetTempFileName()
  $stderrPath = [System.IO.Path]::GetTempFileName()
  try {
    Write-Host ("> {0}" -f ($Command -join " "))
    $ErrorActionPreference = "Continue"
    & $Command[0] @($Command | Select-Object -Skip 1) > $stdoutPath 2> $stderrPath
    $exitCode = $LASTEXITCODE
    $output = @()
    if (Test-Path -LiteralPath $stdoutPath -PathType Leaf) {
      $output += @(Get-Content -LiteralPath $stdoutPath)
    }
    if (Test-Path -LiteralPath $stderrPath -PathType Leaf) {
      $output += @(Get-Content -LiteralPath $stderrPath)
    }
    foreach ($line in @($output)) {
      Write-Host $line
    }
    if ($exitCode -eq 0) {
      throw "command was expected to fail but exited 0: $($Command -join ' ')"
    }
    return @($output | ForEach-Object { [string]$_ })
  }
  finally {
    $ErrorActionPreference = $previousErrorActionPreference
    Remove-Item -LiteralPath $stdoutPath, $stderrPath -Force -ErrorAction SilentlyContinue
    Pop-Location
  }
}

function Assert-TextMatch {
  param(
    [Parameter(Mandatory = $true)][string]$Text,
    [Parameter(Mandatory = $true)][string]$Pattern,
    [Parameter(Mandatory = $true)][string]$Message
  )
  if ($Text -notmatch $Pattern) {
    throw $Message
  }
}

function Assert-PathPresent {
  param([Parameter(Mandatory = $true)][string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) {
    throw "expected path missing: $Path"
  }
}

function Assert-PathAbsent {
  param([Parameter(Mandatory = $true)][string]$Path)
  if (Test-Path -LiteralPath $Path) {
    throw "unexpected path present: $Path"
  }
}

function Write-JsonFixture {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)]$Value
  )
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path) | Out-Null
  $Value | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $Path -Encoding utf8
}

function New-LocalGitRepository {
  param([Parameter(Mandatory = $true)][string]$Path)
  New-Item -ItemType Directory -Force -Path $Path | Out-Null
  Invoke-Checked -Command @("git", "init", "-q", $Path) | Out-Null
  $emptyExcludePath = Join-Path $Path ".git\info\empty-excludes"
  Set-Content -LiteralPath $emptyExcludePath -Value "" -Encoding utf8
  Invoke-Checked -Command @("git", "-C", $Path, "config", "core.excludesFile", $emptyExcludePath) | Out-Null
  Invoke-Checked -Command @("git", "-C", $Path, "checkout", "-q", "-B", "main") | Out-Null
  Set-Content -LiteralPath (Join-Path $Path "README.md") -Value "fixture repository" -Encoding utf8
  Invoke-Checked -Command @("git", "-C", $Path, "add", "README.md") | Out-Null
  Invoke-Checked -Command @(
    "git",
    "-C",
    $Path,
    "-c",
    "user.name=Sword Agent OS Maintenance Test",
    "-c",
    "user.email=maintenance-test@example.invalid",
    "commit",
    "-q",
    "-m",
    "fixture initial commit"
  ) | Out-Null
  return ((Invoke-Checked -Command @("git", "-C", $Path, "rev-parse", "HEAD") | Select-Object -First 1) -join "").Trim()
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

function Test-MaintenanceSafetyStatic {
  Write-TestStep "maintenance safety static checks"
  $productionScripts = @(
    "scripts/bootstrap-workspace.ps1",
    "scripts/install-distribution.ps1",
    "scripts/update-distribution.ps1",
    "scripts/render-env-files.ps1",
    "scripts/start-home-control-bridge.ps1",
    "scripts/prepare-aituberkit-sword-adapter.ps1",
    "start-home-control-launcher.bat",
    "stop-home-control-launcher.bat"
  )
  $bannedPatterns = @(
    "git\s+add\s+\.",
    "git\s+reset\s+--hard",
    "git\s+push\s+--force",
    "git\s+clean\b",
    "Remove-Item\s+-Recurse"
  )
  foreach ($relativePath in $productionScripts) {
    $path = Join-Path $RepoRoot ($relativePath -replace "/", [System.IO.Path]::DirectorySeparatorChar)
    $content = Get-Content -Raw -LiteralPath $path
    foreach ($pattern in $bannedPatterns) {
      if ($content -match $pattern) {
        throw "potentially broad maintenance operation found in ${relativePath}: $pattern"
      }
    }
    Write-Host "safety static ok: $relativePath"
  }

  $selfContent = Get-Content -Raw -LiteralPath $PSCommandPath
  foreach ($pattern in @("git\s+add\s+\.", "git\s+reset\s+--hard", "git\s+push\s+--force", "git\s+clean\b")) {
    if ($selfContent -match $pattern) {
      throw "potentially broad test operation found in maintenance test: $pattern"
    }
  }
  if ($selfContent -match 'Remove-Item\s+-LiteralPath\s+\$resolved\s+-Recurse\s+-Force' -and
      $selfContent -notmatch "refusing to remove unexpected temp root") {
    throw "maintenance test temp cleanup is missing the expected safety guard"
  }
  Write-Host "safety static ok: scripts/test-distribution-maintenance.ps1"
}

function Test-PublicPathLeakStatic {
  Write-TestStep "public docs/scripts path leak static checks"
  $scanTargets = @(
    "README.md",
    "docs",
    "scripts",
    "manifests"
  )
  $checks = @(
    [PSCustomObject]@{
      name = "concrete Windows user-home path"
      pattern = '(?i)\b[A-Z]:\\Users\\(?!<)[^\\\r\n<>]+\\'
    },
    [PSCustomObject]@{
      name = "concrete macOS user-home path"
      pattern = '(?i)/Users/(?!<)[^/\r\n<>|]+/'
    },
    [PSCustomObject]@{
      name = "file URL"
      pattern = [regex]::Escape(("file:" + "//"))
    }
  )

  $files = @()
  foreach ($target in $scanTargets) {
    $path = Join-Path $RepoRoot ($target -replace "/", [System.IO.Path]::DirectorySeparatorChar)
    if (Test-Path -LiteralPath $path -PathType Leaf) {
      $files += Get-Item -LiteralPath $path
    } elseif (Test-Path -LiteralPath $path -PathType Container) {
      $files += Get-ChildItem -LiteralPath $path -Recurse -File
    }
  }

  $findings = @()
  foreach ($file in $files) {
    $relativePath = $file.FullName.Substring($RepoRoot.Length).TrimStart(
      [System.IO.Path]::DirectorySeparatorChar,
      [System.IO.Path]::AltDirectorySeparatorChar
    )
    if ($relativePath -eq "scripts\test-distribution-maintenance.ps1") {
      continue
    }
    $content = Get-Content -Raw -LiteralPath $file.FullName
    foreach ($check in $checks) {
      if ($content -match $check.pattern) {
        $findings += "$relativePath matches $($check.name)"
      }
    }
  }

  if ($findings.Count -gt 0) {
    throw "public path leak patterns found: $($findings -join '; ')"
  }
  Write-Host "path leak static ok: README/docs/scripts/manifests"
}

function Test-ReadmeFirstRunGuidance {
  Write-TestStep "README first-run guidance static checks"
  $readme = Get-Content -Raw -LiteralPath (Join-Path $RepoRoot "README.md")
  Assert-TextMatch -Text $readme -Pattern "prepared local|準備済みローカル" -Message "README should describe prepared local inputs without requiring private folder names"
  Assert-TextMatch -Text $readme -Pattern "_secret_inputs.*product convention|製品として特定のフォルダ名を要求しません" -Message "README should not make _secret_inputs look like a required product convention"
  Assert-TextMatch -Text $readme -Pattern "render-env-files\.ps1 -Profile standard -Force" -Message "README should show central env re-render after editing local env"
  Assert-TextMatch -Text $readme -Pattern "MediapipeVideoSource testsrc" -Message "README should show device-free/no-camera compat smoke with testsrc"
  Assert-TextMatch -Text $readme -Pattern "runtime/browser|実マイク|実カメラ|live Home Assistant|物理家電" -Message "README should separate no-live install/readiness from runtime/browser/live proof"
  Assert-TextMatch -Text $readme -Pattern "標準ディストリビューションの流れ" -Message "README should explain the standard distribution flow"
  Assert-TextMatch -Text $readme -Pattern "刀印.*wake word|OK Google|入力ゲート" -Message "README should explain the sword-sign input gate"
  Assert-TextMatch -Text $readme -Pattern "docs/assets/readme/sword-sign-gesture\.png" -Message "README should reference the sword-sign gesture image"
  Assert-PathPresent -Path (Join-Path $RepoRoot "docs\assets\readme\sword-sign-gesture.png")
  Assert-TextMatch -Text $readme -Pattern "start-home-control-bridge\.ps1" -Message "README should document the Home Control bridge live helper"
  Assert-TextMatch -Text $readme -Pattern "/health.*config_error|/actions.*preview / execute" -Message "README should define live Home Control safe-stop behavior"
  Assert-TextMatch -Text $readme -Pattern "preview、dry-run、execute" -Message "README should require preview before live execute"
  Assert-TextMatch -Text $readme -Pattern "live pilot|live 確認.*ladder|OpenAPI" -Message "README should provide a live pilot command ladder without requiring OpenAPI discovery"
  Assert-TextMatch -Text $readme -Pattern "home-control\.yaml[\s\S]{0,200}再生成|再生成[\s\S]{0,200}home-control\.yaml" -Message "README should warn that render-env-files -Force regenerates home-control.yaml"
  Assert-TextMatch -Text $readme -Pattern "/actions/<allowed-action-id>/preview" -Message "README should show a concrete preview route shape"
  Assert-TextMatch -Text $readme -Pattern '"dry_run":true' -Message "README should show a dry-run execute body"
  Assert-TextMatch -Text $readme -Pattern "-CheckState -ActionId" -Message "README should show helper-based Home Assistant state check"
  Assert-TextMatch -Text $readme -Pattern "live-home-control-cause-trail\.md" -Message "README should link live Home Control cause trail"
  Assert-PathPresent -Path (Join-Path $RepoRoot "docs\live-home-control-cause-trail.md")
  $bridgeHelper = Get-Content -Raw -LiteralPath (Join-Path $RepoRoot "scripts\start-home-control-bridge.ps1")
  Assert-TextMatch -Text $bridgeHelper -Pattern "--env-file" -Message "Home Control bridge helper should pass generated .env through uv"
  Assert-TextMatch -Text $bridgeHelper -Pattern "config_error_kind" -Message "Home Control bridge helper should report redacted config error kind"
  Assert-TextMatch -Text $bridgeHelper -Pattern "cause_code" -Message "Home Control bridge helper should report cause codes"
  Assert-TextMatch -Text $bridgeHelper -Pattern "root_cause_trace" -Message "Home Control bridge helper should emit root-cause trace packet"
  Assert-TextMatch -Text $bridgeHelper -Pattern "HOME_ASSISTANT_TOKEN" -Message "Home Control bridge helper should classify Home Assistant token readiness"
  Assert-TextMatch -Text $bridgeHelper -Pattern "CheckState" -Message "Home Control bridge helper should provide a redacted state-check mode"
  Assert-TextMatch -Text $bridgeHelper -Pattern "bridge_start: status=starting" -Message "Home Control bridge helper should print startup status"
  Assert-TextMatch -Text $bridgeHelper -Pattern 'displayEnvPath = ConvertTo-DisplayLocalPath -Path \$EnvPath' -Message "Home Control bridge helper should redact env paths in live-ready errors"
  Assert-TextMatch -Text $bridgeHelper -Pattern 'ConvertTo-DisplayLocalPath -Path \$envFilePath' -Message "Home Control bridge helper should not print raw local env paths"
  Assert-TextMatch -Text $bridgeHelper -Pattern 'ConvertTo-DisplayLocalPath -Path \$configFilePath' -Message "Home Control bridge helper should not print raw local config paths"
  Assert-TextMatch -Text $bridgeHelper -Pattern 'uvDisplayArguments\[2\] = ConvertTo-DisplayLocalPath -Path \$envFilePath' -Message "Home Control bridge helper dry-run should not print raw env-file paths"
  $causeTrail = Get-Content -Raw -LiteralPath (Join-Path $RepoRoot "docs\live-home-control-cause-trail.md")
  Assert-TextMatch -Text $causeTrail -Pattern "proof_layer:" -Message "cause trail should define proof_layer field"
  Assert-TextMatch -Text $causeTrail -Pattern "entrypoint:" -Message "cause trail should define entrypoint field"
  Assert-TextMatch -Text $causeTrail -Pattern "blocked_at:" -Message "cause trail should define blocked_at field"
  Assert-TextMatch -Text $causeTrail -Pattern "missing-process-env" -Message "cause trail should cover missing process env failures"
  Assert-TextMatch -Text $causeTrail -Pattern "live-ha-state" -Message "cause trail should separate Home Assistant state proof"
  Assert-TextMatch -Text $readme -Pattern "UV_CACHE_DIR" -Message "README should include uv cache troubleshooting guidance"
  Assert-TextMatch -Text $readme -Pattern "Git ownership warning" -Message "README should frame restricted-environment Git ownership warnings as validation friction"
  Assert-TextMatch -Text $readme -Pattern '既存の `sword-agent-os` directory' -Message "README should explain existing clone directory handling"
  Assert-TextMatch -Text $readme -Pattern "network permission" -Message "README should classify restricted environment network reruns"
  Assert-TextMatch -Text $readme -Pattern "foreground の" -Message "README should explain Home Control bridge foreground behavior"
  Assert-TextMatch -Text $readme -Pattern "status=submitted" -Message "README should explain submitted execute status"
  Assert-TextMatch -Text $readme -Pattern "install/readiness pass" -Message "README should separate first-run report proof layers"
  Assert-TextMatch -Text $readme -Pattern "gesture-to-voice-input" -Message "README should separate gesture-to-voice gate proof"
  Assert-TextMatch -Text $readme -Pattern "npm audit" -Message "README should include npm audit interpretation guidance"
  Assert-TextMatch -Text $readme -Pattern "run-local-media-replay\.ps1" -Message "README should document the local media replay preview helper"
  Assert-TextMatch -Text $readme -Pattern "local-media replay" -Message "README should name local-media replay as a separate proof layer"
  Assert-TextMatch -Text $readme -Pattern "gesture\.sword\.20260603" -Message "README should show the sword-sign positive local media asset id"
  Assert-TextMatch -Text $readme -Pattern "vision\.room_light\.on\.20260603" -Message "README should show the room-light local media asset id"
  Assert-TextMatch -Text $readme -Pattern "raw_media_shared=false" -Message "README should show raw media is not shared in local-media results"
  Assert-TextMatch -Text $readme -Pattern "generated_output_written=false" -Message "README should show preview helper does not write generated output"
  $localMediaHelper = Get-Content -Raw -LiteralPath (Join-Path $RepoRoot "scripts\run-local-media-replay.ps1")
  Assert-TextMatch -Text $localMediaHelper -Pattern "local/media/media-index\.json" -Message "local media helper should resolve the local media index"
  Assert-TextMatch -Text $localMediaHelper -Pattern "raw_media_shared=false" -Message "local media helper should print raw_media_shared=false"
  Assert-TextMatch -Text $localMediaHelper -Pattern "raw_transcript_shared=false" -Message "local media helper should print raw_transcript_shared=false"
  Assert-TextMatch -Text $localMediaHelper -Pattern "generated_output_written=false" -Message "local media helper should print generated_output_written=false"
  Assert-TextMatch -Text $localMediaHelper -Pattern "live_action_executed=false" -Message "local media helper should print live_action_executed=false"
  Assert-TextMatch -Text $localMediaHelper -Pattern "<workspace>" -Message "local media helper should use placeholders instead of private absolute paths"
  Assert-TextMatch -Text $localMediaHelper -Pattern "<workspace-uri>" -Message "room-light preview should use a placeholder file URI"
  Write-Host "README first-run guidance static ok"
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
  $updateText = $updateOutput -join "`n"
  if ($updateText -notmatch "held\s*:\s*0") {
    $message = "installed update dry-run did not report held: 0"
    if ($RequireAssembledCheckouts) {
      throw $message
    }
    Write-Warning "$message; continuing because current checkout may contain active local WIP"
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

function New-UpdateFixtureManifest {
  param(
    [Parameter(Mandatory = $true)][string]$Root,
    [Parameter(Mandatory = $true)][string]$TargetPath,
    [Parameter(Mandatory = $true)][string]$Commit,
    [string]$Branch = "main",
    [string]$Id = "fixture-control"
  )

  $controlManifestPath = Join-Path $Root "$Id-control.json"
  $organManifestPath = Join-Path $Root "$Id-organs.json"
  $distributionManifestPath = Join-Path $Root "$Id-distribution.json"
  Write-JsonFixture -Path $controlManifestPath -Value ([ordered]@{
    id = $Id
    repo_url = $TargetPath
    branch = $Branch
    commit = $Commit
    target_path = $TargetPath
  })
  Write-JsonFixture -Path $organManifestPath -Value ([ordered]@{
    sources = @()
  })
  Write-JsonFixture -Path $distributionManifestPath -Value ([ordered]@{
    control_plane_manifest_path = $controlManifestPath
    organ_manifest_path = $organManifestPath
    dependencies = @()
  })
  return $distributionManifestPath
}

function Test-UpdateFixtureHoldBehavior {
  Write-TestStep "update fixture dirty/hold behavior"
  $root = New-FreshTestRoot
  try {
    $generatedRepo = Join-Path $root "generated-only-checkout"
    $generatedHead = New-LocalGitRepository -Path $generatedRepo
    Set-Content -LiteralPath (Join-Path $generatedRepo "uv.lock") -Value "generated lock" -Encoding utf8
    New-Item -ItemType Directory -Force -Path (Join-Path $generatedRepo "demo.egg-info") | Out-Null
    Set-Content -LiteralPath (Join-Path $generatedRepo "demo.egg-info\PKG-INFO") -Value "generated metadata" -Encoding utf8
    New-Item -ItemType Directory -Force -Path (Join-Path $generatedRepo ".venv") | Out-Null
    Set-Content -LiteralPath (Join-Path $generatedRepo ".venv\pyvenv.cfg") -Value "home = fixture" -Encoding utf8
    New-Item -ItemType Directory -Force -Path (Join-Path $generatedRepo "node_modules\demo") | Out-Null
    Set-Content -LiteralPath (Join-Path $generatedRepo "node_modules\demo\index.js") -Value "module.exports = {};" -Encoding utf8
    $generatedManifest = New-UpdateFixtureManifest -Root $root -TargetPath $generatedRepo -Commit $generatedHead -Id "generated-only"
    $generatedOutput = Invoke-Checked -Command @(
      $PowerShellCommand,
      "-NoProfile",
      "-File",
      (Join-Path $PSScriptRoot "update-distribution.ps1"),
      "-DistributionManifestPath",
      $generatedManifest,
      "-DryRun",
      "-NoDeps",
      "-NoEnv"
    )
    $generatedText = $generatedOutput -join "`n"
    Assert-TextMatch -Text $generatedText -Pattern "generated local files ignored" -Message "generated dependency artifacts were not reported as ignored"
    Assert-TextMatch -Text $generatedText -Pattern "\?\? \.venv/" -Message ".venv generated artifact was not reported"
    Assert-TextMatch -Text $generatedText -Pattern "\?\? demo\.egg-info/" -Message "*.egg-info generated artifact was not reported"
    Assert-TextMatch -Text $generatedText -Pattern "\?\? node_modules/" -Message "node_modules generated artifact was not reported"
    Assert-TextMatch -Text $generatedText -Pattern "\?\? uv\.lock" -Message "untracked uv.lock generated artifact was not reported"
    Assert-TextMatch -Text $generatedText -Pattern "held\s*:\s*0" -Message "generated-only fixture should not be held"

    $cleanUpdateRemote = Join-Path $root "clean-update-remote"
    New-LocalGitRepository -Path $cleanUpdateRemote | Out-Null
    $cleanUpdateCheckout = Join-Path $root "clean-update-checkout"
    Invoke-Checked -Command @("git", "clone", $cleanUpdateRemote, $cleanUpdateCheckout) -WorkingDirectory $root | Out-Null
    $cleanUpdateOldHead = ((Invoke-Checked -Command @("git", "-C", $cleanUpdateCheckout, "rev-parse", "HEAD") | Select-Object -First 1) -join "").Trim()
    Set-Content -LiteralPath (Join-Path $cleanUpdateRemote "README.md") -Value "fixture repository updated" -Encoding utf8
    Invoke-Checked -Command @("git", "-C", $cleanUpdateRemote, "add", "README.md") | Out-Null
    Invoke-Checked -Command @(
      "git",
      "-C",
      $cleanUpdateRemote,
      "-c",
      "user.name=Sword Agent OS Maintenance Test",
      "-c",
      "user.email=maintenance-test@example.invalid",
      "commit",
      "-q",
      "-m",
      "fixture update commit"
    ) | Out-Null
    $cleanUpdateExpected = ((Invoke-Checked -Command @("git", "-C", $cleanUpdateRemote, "rev-parse", "HEAD") | Select-Object -First 1) -join "").Trim()
    if ($cleanUpdateOldHead -eq $cleanUpdateExpected) {
      throw "clean update fixture failed to create a newer manifest pin"
    }
    $cleanUpdateManifest = New-UpdateFixtureManifest -Root $root -TargetPath $cleanUpdateCheckout -Commit $cleanUpdateExpected -Id "clean-update"
    $cleanDryRunOutput = Invoke-Checked -Command @(
      $PowerShellCommand,
      "-NoProfile",
      "-File",
      (Join-Path $PSScriptRoot "update-distribution.ps1"),
      "-DistributionManifestPath",
      $cleanUpdateManifest,
      "-DryRun",
      "-NoDeps",
      "-NoEnv"
    )
    $cleanDryRunText = $cleanDryRunOutput -join "`n"
    Assert-TextMatch -Text $cleanDryRunText -Pattern "update planned: control-plane:clean-update" -Message "clean wrong-commit checkout should plan an update"
    Assert-TextMatch -Text $cleanDryRunText -Pattern "planned\s*:\s*1" -Message "clean wrong-commit dry run should report planned: 1"
    Assert-TextMatch -Text $cleanDryRunText -Pattern "held\s*:\s*0" -Message "clean wrong-commit dry run should not be held"
    $cleanRealUpdateOutput = Invoke-Checked -Command @(
      $PowerShellCommand,
      "-NoProfile",
      "-File",
      (Join-Path $PSScriptRoot "update-distribution.ps1"),
      "-DistributionManifestPath",
      $cleanUpdateManifest,
      "-NoDeps",
      "-NoEnv"
    )
    $cleanRealUpdateText = $cleanRealUpdateOutput -join "`n"
    Assert-TextMatch -Text $cleanRealUpdateText -Pattern "updated: control-plane:clean-update" -Message "clean wrong-commit checkout should fast-forward to the manifest pin"
    Assert-TextMatch -Text $cleanRealUpdateText -Pattern "updated\s*:\s*1" -Message "clean wrong-commit real update should report updated: 1"
    Assert-TextMatch -Text $cleanRealUpdateText -Pattern "held\s*:\s*0" -Message "clean wrong-commit real update should not be held"
    $cleanUpdateNewHead = ((Invoke-Checked -Command @("git", "-C", $cleanUpdateCheckout, "rev-parse", "HEAD") | Select-Object -First 1) -join "").Trim()
    if ($cleanUpdateNewHead -ne $cleanUpdateExpected) {
      throw "clean update fixture did not reach manifest pin: expected $cleanUpdateExpected, got $cleanUpdateNewHead"
    }

    $dirtyRepo = Join-Path $root "dirty-checkout"
    $dirtyHead = New-LocalGitRepository -Path $dirtyRepo
    Set-Content -LiteralPath (Join-Path $dirtyRepo "README.md") -Value "tracked dirty change" -Encoding utf8
    $dirtyManifest = New-UpdateFixtureManifest -Root $root -TargetPath $dirtyRepo -Commit $dirtyHead -Id "dirty"
    $dirtyOutput = Invoke-Checked -Command @(
      $PowerShellCommand,
      "-NoProfile",
      "-File",
      (Join-Path $PSScriptRoot "update-distribution.ps1"),
      "-DistributionManifestPath",
      $dirtyManifest,
      "-DryRun",
      "-NoDeps",
      "-NoEnv"
    )
    $dirtyText = $dirtyOutput -join "`n"
    Assert-TextMatch -Text $dirtyText -Pattern "hold dirty checkout" -Message "tracked dirty checkout was not held"
    Assert-TextMatch -Text $dirtyText -Pattern "held\s*:\s*1" -Message "tracked dirty fixture should report held: 1"

    $trackedUvRepo = Join-Path $root "tracked-uv-lock-checkout"
    New-LocalGitRepository -Path $trackedUvRepo | Out-Null
    Set-Content -LiteralPath (Join-Path $trackedUvRepo "uv.lock") -Value "tracked lock base" -Encoding utf8
    Invoke-Checked -Command @("git", "-C", $trackedUvRepo, "add", "uv.lock") | Out-Null
    $installOutput = Invoke-Checked -Command @(
      "git",
      "-C",
      $trackedUvRepo,
      "-c",
      "user.name=Sword Agent OS Maintenance Test",
      "-c",
      "user.email=maintenance-test@example.invalid",
      "commit",
      "-q",
      "-m",
      "add tracked uv lock"
    ) | Out-Null
    $trackedUvHead = ((Invoke-Checked -Command @("git", "-C", $trackedUvRepo, "rev-parse", "HEAD") | Select-Object -First 1) -join "").Trim()
    Set-Content -LiteralPath (Join-Path $trackedUvRepo "uv.lock") -Value "tracked lock dirty" -Encoding utf8
    $trackedUvManifest = New-UpdateFixtureManifest -Root $root -TargetPath $trackedUvRepo -Commit $trackedUvHead -Id "tracked-uv-lock"
    $trackedUvOutput = Invoke-Checked -Command @(
      $PowerShellCommand,
      "-NoProfile",
      "-File",
      (Join-Path $PSScriptRoot "update-distribution.ps1"),
      "-DistributionManifestPath",
      $trackedUvManifest,
      "-DryRun",
      "-NoDeps",
      "-NoEnv"
    )
    $trackedUvText = $trackedUvOutput -join "`n"
    Assert-TextMatch -Text $trackedUvText -Pattern "hold dirty checkout" -Message "tracked uv.lock change was not held"
    Assert-TextMatch -Text $trackedUvText -Pattern "M uv\.lock" -Message "tracked uv.lock dirty line was not reported"

    $untrackedSourceRepo = Join-Path $root "untracked-source-checkout"
    $untrackedSourceHead = New-LocalGitRepository -Path $untrackedSourceRepo
    New-Item -ItemType Directory -Force -Path (Join-Path $untrackedSourceRepo "src") | Out-Null
    Set-Content -LiteralPath (Join-Path $untrackedSourceRepo "src\new.py") -Value "print('untracked source')" -Encoding utf8
    $untrackedSourceManifest = New-UpdateFixtureManifest -Root $root -TargetPath $untrackedSourceRepo -Commit $untrackedSourceHead -Id "untracked-source"
    $untrackedSourceOutput = Invoke-Checked -Command @(
      $PowerShellCommand,
      "-NoProfile",
      "-File",
      (Join-Path $PSScriptRoot "update-distribution.ps1"),
      "-DistributionManifestPath",
      $untrackedSourceManifest,
      "-DryRun",
      "-NoDeps",
      "-NoEnv"
    )
    $untrackedSourceText = $untrackedSourceOutput -join "`n"
    Assert-TextMatch -Text $untrackedSourceText -Pattern "hold dirty checkout" -Message "ordinary untracked source was not held"
    Assert-TextMatch -Text $untrackedSourceText -Pattern "\?\? src/" -Message "ordinary untracked source dirty line was not reported"

    $missingPath = Join-Path $root "missing-checkout"
    $missingManifest = New-UpdateFixtureManifest -Root $root -TargetPath $missingPath -Commit $generatedHead -Id "missing"
    $missingOutput = Invoke-Checked -Command @(
      $PowerShellCommand,
      "-NoProfile",
      "-File",
      (Join-Path $PSScriptRoot "update-distribution.ps1"),
      "-DistributionManifestPath",
      $missingManifest,
      "-DryRun",
      "-NoDeps",
      "-NoEnv"
    )
    Assert-TextMatch -Text ($missingOutput -join "`n") -Pattern "hold missing checkout" -Message "missing checkout was not held"

    $nonGitPath = Join-Path $root "non-git-checkout"
    New-Item -ItemType Directory -Force -Path $nonGitPath | Out-Null
    $nonGitManifest = New-UpdateFixtureManifest -Root $root -TargetPath $nonGitPath -Commit $generatedHead -Id "non-git"
    $nonGitOutput = Invoke-Checked -Command @(
      $PowerShellCommand,
      "-NoProfile",
      "-File",
      (Join-Path $PSScriptRoot "update-distribution.ps1"),
      "-DistributionManifestPath",
      $nonGitManifest,
      "-DryRun",
      "-NoDeps",
      "-NoEnv"
    )
    Assert-TextMatch -Text ($nonGitOutput -join "`n") -Pattern "hold non-git checkout path" -Message "non-git checkout path was not held"

    $branchRepo = Join-Path $root "branch-mismatch-checkout"
    $branchHead = New-LocalGitRepository -Path $branchRepo
    $branchManifest = New-UpdateFixtureManifest -Root $root -TargetPath $branchRepo -Commit $branchHead -Branch "not-main" -Id "branch-mismatch"
    $branchOutput = Invoke-Checked -Command @(
      $PowerShellCommand,
      "-NoProfile",
      "-File",
      (Join-Path $PSScriptRoot "update-distribution.ps1"),
      "-DistributionManifestPath",
      $branchManifest,
      "-DryRun",
      "-NoDeps",
      "-NoEnv"
    )
    Assert-TextMatch -Text ($branchOutput -join "`n") -Pattern "hold branch mismatch" -Message "branch mismatch checkout was not held"

    $nonFastForwardRemote = Join-Path $root "non-ff-remote"
    New-LocalGitRepository -Path $nonFastForwardRemote | Out-Null
    $nonFastForwardCheckout = Join-Path $root "non-ff-checkout"
    Invoke-Checked -Command @("git", "clone", $nonFastForwardRemote, $nonFastForwardCheckout) -WorkingDirectory $root | Out-Null
    Set-Content -LiteralPath (Join-Path $nonFastForwardRemote "README.md") -Value "remote update" -Encoding utf8
    Invoke-Checked -Command @("git", "-C", $nonFastForwardRemote, "add", "README.md") | Out-Null
    Invoke-Checked -Command @(
      "git",
      "-C",
      $nonFastForwardRemote,
      "-c",
      "user.name=Sword Agent OS Maintenance Test",
      "-c",
      "user.email=maintenance-test@example.invalid",
      "commit",
      "-q",
      "-m",
      "remote update"
    ) | Out-Null
    $nonFastForwardExpected = ((Invoke-Checked -Command @("git", "-C", $nonFastForwardRemote, "rev-parse", "HEAD") | Select-Object -First 1) -join "").Trim()
    Set-Content -LiteralPath (Join-Path $nonFastForwardCheckout "README.md") -Value "local divergent update" -Encoding utf8
    Invoke-Checked -Command @("git", "-C", $nonFastForwardCheckout, "add", "README.md") | Out-Null
    Invoke-Checked -Command @(
      "git",
      "-C",
      $nonFastForwardCheckout,
      "-c",
      "user.name=Sword Agent OS Maintenance Test",
      "-c",
      "user.email=maintenance-test@example.invalid",
      "commit",
      "-q",
      "-m",
      "local divergent update"
    ) | Out-Null
    $nonFastForwardManifest = New-UpdateFixtureManifest -Root $root -TargetPath $nonFastForwardCheckout -Commit $nonFastForwardExpected -Id "non-fast-forward"
    $nonFastForwardOutput = Invoke-Checked -Command @(
      $PowerShellCommand,
      "-NoProfile",
      "-File",
      (Join-Path $PSScriptRoot "update-distribution.ps1"),
      "-DistributionManifestPath",
      $nonFastForwardManifest,
      "-NoDeps",
      "-NoEnv"
    )
    $nonFastForwardText = $nonFastForwardOutput -join "`n"
    Assert-TextMatch -Text $nonFastForwardText -Pattern "hold non-fast-forward update" -Message "non-fast-forward update was not held"
    Assert-TextMatch -Text $nonFastForwardText -Pattern "held\s*:\s*1" -Message "non-fast-forward fixture should report held: 1"
  }
  finally {
    Remove-FreshTestRoot -Path $root
  }
}

function Test-EnvRenderFixtures {
  Write-TestStep "env renderer fixture behavior"
  $root = New-FreshTestRoot
  try {
    $templateDir = Join-Path $root "templates"
    $targetDir = Join-Path $root "target"
    New-Item -ItemType Directory -Force -Path $templateDir | Out-Null
    $centralTemplate = Join-Path $templateDir "central.env.example"
    $centralEnv = Join-Path $root "local\env\sword-agent-os.env"
    $targetTemplate = Join-Path $templateDir "organ.env.example"
    $targetEnv = Join-Path $targetDir ".env"
    $configTemplate = Join-Path $templateDir "home-control.example.yaml"
    $targetConfig = Join-Path $targetDir "home-control.yaml"
    $missingTargetTemplate = Join-Path $templateDir "missing.env.example"
    $missingConfigTemplate = Join-Path $templateDir "missing-config.yaml"
    $manifestPath = Join-Path $root "env-fixture.json"

    Set-Content -LiteralPath $centralTemplate -Value @(
      "TOKEN=central-token",
      "FIXTURE_TARGET__TOKEN=scoped-token",
      "KEEP=central-keep"
    ) -Encoding utf8

    Write-JsonFixture -Path $manifestPath -Value ([ordered]@{
      env = [ordered]@{
        central_template_path = $centralTemplate
        central_env_path = $centralEnv
        local_config_templates = @(
          [ordered]@{
            id = "missing-config"
            template_path = $missingConfigTemplate
            target_path = $targetConfig
          }
        )
        targets = @(
          [ordered]@{
            id = "missing-target"
            template_path = $missingTargetTemplate
            target_path = $targetEnv
          }
        )
      }
    })

    $dryRunOutput = Invoke-Checked -Command @(
      $PowerShellCommand,
      "-NoProfile",
      "-File",
      (Join-Path $PSScriptRoot "render-env-files.ps1"),
      "-DistributionManifestPath",
      $manifestPath,
      "-DryRun",
      "-NoCreateCentralEnv"
    )
    $dryRunText = $dryRunOutput -join "`n"
    Assert-TextMatch -Text $dryRunText -Pattern "central env missing" -Message "dry-run did not warn about missing central env"
    Assert-TextMatch -Text $dryRunText -Pattern "template not present yet" -Message "dry-run did not tolerate missing config template"
    Assert-TextMatch -Text $dryRunText -Pattern "env template not present yet" -Message "dry-run did not tolerate missing env template"
    Assert-PathAbsent -Path $centralEnv
    Assert-PathAbsent -Path $targetEnv

    $failureOutput = Invoke-ExpectFailure -Command @(
      $PowerShellCommand,
      "-NoProfile",
      "-File",
      (Join-Path $PSScriptRoot "render-env-files.ps1"),
      "-DistributionManifestPath",
      $manifestPath,
      "-NoCreateCentralEnv"
    )
    Assert-TextMatch -Text ($failureOutput -join "`n") -Pattern "template missing|env template missing" -Message "non-dry-run missing template did not fail clearly"

    Set-Content -LiteralPath $targetTemplate -Value @(
      "TOKEN=template-token",
      "KEEP=template-keep",
      "LOCAL_ONLY=template-local"
    ) -Encoding utf8
    Set-Content -LiteralPath $configTemplate -Value "enabled: true" -Encoding utf8
    Write-JsonFixture -Path $manifestPath -Value ([ordered]@{
      env = [ordered]@{
        central_template_path = $centralTemplate
        central_env_path = $centralEnv
        local_config_templates = @(
          [ordered]@{
            id = "home-control-config"
            template_path = $configTemplate
            target_path = $targetConfig
          }
        )
        targets = @(
          [ordered]@{
            id = "fixture-target"
            template_path = $targetTemplate
            target_path = $targetEnv
          }
        )
      }
    })

    $installOutput = Invoke-Checked -Command @(
      $PowerShellCommand,
      "-NoProfile",
      "-File",
      (Join-Path $PSScriptRoot "render-env-files.ps1"),
      "-DistributionManifestPath",
      $manifestPath
    ) | Out-Null
    Assert-PathPresent -Path $centralEnv
    Assert-PathPresent -Path $targetEnv
    Assert-PathPresent -Path $targetConfig
    Assert-TextMatch -Text (Get-Content -Raw -LiteralPath $targetEnv) -Pattern "TOKEN=scoped-token" -Message "target env did not inherit scoped central value"

    Set-Content -LiteralPath $targetEnv -Value "TOKEN=operator-override" -Encoding utf8
    Invoke-Checked -Command @(
      $PowerShellCommand,
      "-NoProfile",
      "-File",
      (Join-Path $PSScriptRoot "render-env-files.ps1"),
      "-DistributionManifestPath",
      $manifestPath
    ) | Out-Null
    Assert-TextMatch -Text (Get-Content -Raw -LiteralPath $targetEnv) -Pattern "TOKEN=operator-override" -Message "target env was overwritten without -Force"

    Invoke-Checked -Command @(
      $PowerShellCommand,
      "-NoProfile",
      "-File",
      (Join-Path $PSScriptRoot "render-env-files.ps1"),
      "-DistributionManifestPath",
      $manifestPath,
      "-Force"
    ) | Out-Null
    Assert-TextMatch -Text (Get-Content -Raw -LiteralPath $targetEnv) -Pattern "TOKEN=scoped-token" -Message "target env was not refreshed with scoped value under -Force"
  }
  finally {
    Remove-FreshTestRoot -Path $root
  }
}

function New-NativeLaunchWorkspaceFixture {
  param([Parameter(Mandatory = $true)][string]$Root)

  New-Item -ItemType Directory -Force -Path $Root | Out-Null

  $paths = @(
    "organs\action\home-assistant-server\config",
    "organs\environment\environment-state-server",
    "organs\environment\vision-snapshot-processor\src\vision_snapshot_processor",
    "organs\expression\aituber-kit\public\vrm",
    "organs\reflex\mediapipe-sword-sign\scripts",
    "organs\display\touchdesigner-ai-controller\tools",
    "organs\speech-input\ai-talk-core",
    "control-plane\sword-voice-agent\scripts",
    "control-plane\sword-voice-agent\src\sword_voice_agent\apps",
    "control-plane\sword-voice-agent\services\thought-core"
  )
  foreach ($relativePath in $paths) {
    New-Item -ItemType Directory -Force -Path (Join-Path $Root $relativePath) | Out-Null
  }

  Set-Content -LiteralPath (Join-Path $Root "organs\action\home-assistant-server\config\home-control.yaml") -Value "actions: []" -Encoding utf8
  Set-Content -LiteralPath (Join-Path $Root "organs\action\home-assistant-server\.env") -Value @(
    "HOME_CONTROL_API_TOKEN=",
    "ENVIRONMENT_API_TOKEN="
  ) -Encoding utf8
  Set-Content -LiteralPath (Join-Path $Root "control-plane\sword-voice-agent\.env") -Value @(
    "THOUGHT_CORE_LLM_MODE=off",
    "THOUGHT_CORE_TOOLS_ADAPTER=mock # no-live fixture"
  ) -Encoding utf8
  Set-Content -LiteralPath (Join-Path $Root "organs\expression\aituber-kit\.env") -Value @(
    "VOICEVOX_SERVER_URL=http://127.0.0.1:50021",
    "NEXT_PUBLIC_SELECTED_VRM_PATH=/vrm/fixture.vrm"
  ) -Encoding utf8
  Set-Content -LiteralPath (Join-Path $Root "organs\reflex\mediapipe-sword-sign\gesture_model.pkl") -Value "fixture" -Encoding utf8
  Set-Content -LiteralPath (Join-Path $Root "organs\reflex\mediapipe-sword-sign\scripts\camera_hub_stack.py") -Value "" -Encoding utf8
  Set-Content -LiteralPath (Join-Path $Root "organs\reflex\mediapipe-sword-sign\scripts\start_camera_hub_stack.bat") -Value "" -Encoding utf8
  Set-Content -LiteralPath (Join-Path $Root "organs\environment\vision-snapshot-processor\src\vision_snapshot_processor\main.py") -Value "" -Encoding utf8
  Set-Content -LiteralPath (Join-Path $Root "organs\display\touchdesigner-ai-controller\tools\server.js") -Value "" -Encoding utf8
  Set-Content -LiteralPath (Join-Path $Root "organs\expression\aituber-kit\public\vrm\fixture.vrm") -Value "fixture" -Encoding utf8
  Set-Content -LiteralPath (Join-Path $Root "control-plane\sword-voice-agent\scripts\start-thought-core.ps1") -Value "" -Encoding utf8
  Set-Content -LiteralPath (Join-Path $Root "control-plane\sword-voice-agent\scripts\start-thought-core-watch.ps1") -Value "" -Encoding utf8
  Set-Content -LiteralPath (Join-Path $Root "control-plane\sword-voice-agent\src\sword_voice_agent\apps\watch_handoff_to_thought_core.py") -Value "" -Encoding utf8
}

function New-LegacyLaunchAliasFixture {
  param([Parameter(Mandatory = $true)][string]$Root)

  $paths = @(
    "sword-control-plane\scripts",
    "sword-control-plane\services\thought-core",
    "organs\voice\ai-talk-core"
  )
  foreach ($relativePath in $paths) {
    New-Item -ItemType Directory -Force -Path (Join-Path $Root $relativePath) | Out-Null
  }

  Set-Content -LiteralPath (Join-Path $Root "sword-control-plane\.env") -Value "THOUGHT_CORE_LLM_MODE=off" -Encoding utf8
  Set-Content -LiteralPath (Join-Path $Root "sword-control-plane\scripts\start-thought-core.ps1") -Value "" -Encoding utf8
  Set-Content -LiteralPath (Join-Path $Root "sword-control-plane\scripts\start-thought-core-watch.ps1") -Value "" -Encoding utf8
}

function Remove-FixtureSubtree {
  param(
    [Parameter(Mandatory = $true)][string]$Workspace,
    [Parameter(Mandatory = $true)][string]$RelativePath
  )

  $target = Join-Path $Workspace $RelativePath
  $resolvedTarget = [System.IO.Path]::GetFullPath($target)
  $resolvedWorkspace = [System.IO.Path]::GetFullPath($Workspace)
  if (-not $resolvedTarget.StartsWith($resolvedWorkspace, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "refusing to remove fixture path outside workspace: $resolvedTarget"
  }
  if (Test-Path -LiteralPath $resolvedTarget) {
    Remove-Item -LiteralPath $resolvedTarget -Recurse -Force
  }
}

function Test-NativeLaunchLayoutFixtures {
  Write-TestStep "native launch layout dry-run fixtures"
  $root = New-FreshTestRoot
  try {
    $workspace = Join-Path $root "sword-agent-os"
    New-NativeLaunchWorkspaceFixture -Root $workspace
    Assert-PathAbsent -Path (Join-Path $workspace "sword-control-plane")
    Assert-PathAbsent -Path (Join-Path $workspace "organs\voice\ai-talk-core")

    $readinessOutput = Invoke-Checked -Command @(
      $PowerShellCommand,
      "-NoProfile",
      "-File",
      (Join-Path $PSScriptRoot "check-launch-readiness.ps1"),
      "-WorkspaceRoot",
      $workspace,
      "-SkipPortChecks"
    )
    $readiness = $readinessOutput -join "`n" | ConvertFrom-Json
    if ([string]$readiness.status -ne "ok") {
      throw "native launch readiness should be ok; got $($readiness.status)"
    }
    if ([string]$readiness.workspace_root -ne $workspace) {
      throw "native launch readiness used wrong workspace root: $($readiness.workspace_root)"
    }
    $readinessIds = @($readiness.checks | ForEach-Object { [string]$_.id })
    if ("legacy_delegate_layout.sword_control_plane_alias" -in $readinessIds) {
      throw "native launch readiness should not require sword-control-plane alias"
    }
    if ("legacy_delegate_layout.ai_talk_core_voice_alias" -in $readinessIds) {
      throw "native launch readiness should not require organs/voice/ai-talk-core alias"
    }
    if (@($readinessIds | Where-Object { $_ -match "avatar" }).Count -gt 0) {
      throw "native launch readiness should not require deferred avatar-service"
    }
    Assert-TextMatch -Text ($readinessOutput -join "`n") -Pattern "native_delegate_layout\.control_plane" -Message "native control-plane readiness check missing"
    Assert-TextMatch -Text ($readinessOutput -join "`n") -Pattern "native_delegate_layout\.ai_talk_core" -Message "native AI Talk Core readiness check missing"

    $centralEnvDir = Join-Path $workspace "local\env"
    New-Item -ItemType Directory -Force -Path $centralEnvDir | Out-Null
    Set-Content -LiteralPath (Join-Path $centralEnvDir "sword-agent-os.env") -Value @(
      "THOUGHT_CORE_TOOLS_ADAPTER=home_control",
      "HOME_CONTROL_API_TOKEN=central-home-control-token-12345678901234567890",
      "ENVIRONMENT_API_TOKEN=central-environment-token-12345678901234567890",
      "HOME_ASSISTANT_TOKEN=central-home-assistant-token-12345678901234567890"
    ) -Encoding utf8
    Copy-Item `
      -LiteralPath (Join-Path $workspace "organs\action\home-assistant-server\config\home-control.yaml") `
      -Destination (Join-Path $workspace "organs\action\home-assistant-server\config\home-control.example.yaml")
    $homeControlWarningOutput = Invoke-Checked -Command @(
      $PowerShellCommand,
      "-NoProfile",
      "-File",
      (Join-Path $PSScriptRoot "check-launch-readiness.ps1"),
      "-WorkspaceRoot",
      $workspace,
      "-SkipPortChecks"
    )
    $homeControlWarning = $homeControlWarningOutput -join "`n" | ConvertFrom-Json
    if ([string]$homeControlWarning.status -ne "warning") {
      throw "home_control example config and stale env should warn; got $($homeControlWarning.status)"
    }
    $homeControlConfigCheck = @($homeControlWarning.checks | Where-Object { [string]$_.id -eq "local.home_control_config_customized" } | Select-Object -First 1)
    if ($homeControlConfigCheck.Count -eq 0 -or [string]$homeControlConfigCheck[0].status -ne "example") {
      throw "home_control example config warning missing"
    }
    $homeControlSyncCheck = @($homeControlWarning.checks | Where-Object { [string]$_.id -eq "local.home_control_api_token_sync" } | Select-Object -First 1)
    if ($homeControlSyncCheck.Count -eq 0 -or [string]$homeControlSyncCheck[0].status -ne "missing") {
      throw "home_control token sync warning missing"
    }
    Remove-FixtureSubtree -Workspace $workspace -RelativePath "local"
    Remove-Item -LiteralPath (Join-Path $workspace "organs\action\home-assistant-server\config\home-control.example.yaml") -Force

    $gestureModelPath = Join-Path $workspace "organs\reflex\mediapipe-sword-sign\gesture_model.pkl"
    Remove-Item -LiteralPath $gestureModelPath -Force
    $missingGestureOutput = Invoke-Checked -Command @(
      $PowerShellCommand,
      "-NoProfile",
      "-File",
      (Join-Path $PSScriptRoot "check-launch-readiness.ps1"),
      "-WorkspaceRoot",
      $workspace,
      "-SkipPortChecks"
    )
    $missingGesture = $missingGestureOutput -join "`n" | ConvertFrom-Json
    if ([string]$missingGesture.status -ne "blocked") {
      throw "missing gesture model should block launch readiness; got $($missingGesture.status)"
    }
    $missingGestureCheck = @($missingGesture.checks | Where-Object { [string]$_.id -eq "local.mediapipe_gesture_model" } | Select-Object -First 1)
    if ($missingGestureCheck.Count -eq 0 -or [string]$missingGestureCheck[0].status -ne "missing") {
      throw "missing gesture model check did not report missing"
    }
    if ([string]$missingGestureCheck[0].severity -ne "blocker") {
      throw "missing gesture model should be a blocker"
    }
    Assert-TextMatch -Text ([string]$missingGestureCheck[0].detail) -Pattern "model_not_found|Camera Hub topics timeout" -Message "missing gesture model detail should explain the startup symptom"
    Assert-TextMatch -Text ([string]$missingGestureCheck[0].detail) -Pattern "already have|do not have" -Message "missing gesture model detail should explain both prepared-model and no-model first-run paths"
    Set-Content -LiteralPath $gestureModelPath -Value "fixture" -Encoding utf8

    $launchOutput = Invoke-Checked -Command @(
      $PowerShellCommand,
      "-NoProfile",
      "-ExecutionPolicy",
      "Bypass",
      "-File",
      (Join-Path $RepoRoot "control-plane\sword-voice-agent\ops\scripts\system.ps1"),
      "-WorkspaceRoot",
      $workspace,
      "start",
      "-Profile",
      "thought-core-v0",
      "-ThoughtCorePort",
      "39787",
      "-StackStateDir",
      (Join-Path $workspace ".cache\home-control-stack"),
      "-SkipDify",
      "-SkipDifyWatch",
      "-SkipVoicevoxCheck",
      "-MediapipeNoBrowser",
      "-DryRun"
    )
    $launchText = $launchOutput -join "`n"
    Assert-TextMatch -Text $launchText -Pattern "control-plane\\sword-voice-agent\\scripts\\start-thought-core\.ps1" -Message "dry-run did not use native Thought Core script path"
    Assert-TextMatch -Text $launchText -Pattern "organs\\speech-input\\ai-talk-core" -Message "dry-run did not use native AI Talk Core path"
    if ($launchText -match "directory not found") {
      throw "native launch dry-run reported missing directory: $launchText"
    }
    if ($launchText -match "sword-control-plane\\scripts") {
      throw "native launch dry-run still used legacy sword-control-plane scripts"
    }
    if ($launchText -match "organs\\voice\\ai-talk-core") {
      throw "native launch dry-run still used legacy AI Talk Core voice alias"
    }

    New-LegacyLaunchAliasFixture -Root $workspace
    $preferredLaunchOutput = Invoke-Checked -Command @(
      $PowerShellCommand,
      "-NoProfile",
      "-ExecutionPolicy",
      "Bypass",
      "-File",
      (Join-Path $RepoRoot "control-plane\sword-voice-agent\ops\scripts\system.ps1"),
      "-WorkspaceRoot",
      $workspace,
      "start",
      "-Profile",
      "thought-core-v0",
      "-ThoughtCorePort",
      "39788",
      "-StackStateDir",
      (Join-Path $workspace ".cache\home-control-stack-preferred"),
      "-SkipDify",
      "-SkipDifyWatch",
      "-SkipVoicevoxCheck",
      "-MediapipeNoBrowser",
      "-DryRun"
    )
    $preferredLaunchText = $preferredLaunchOutput -join "`n"
    Assert-TextMatch -Text $preferredLaunchText -Pattern "control-plane\\sword-voice-agent\\scripts\\start-thought-core\.ps1" -Message "native-preferred dry-run did not use native Thought Core script path"
    Assert-TextMatch -Text $preferredLaunchText -Pattern "organs\\speech-input\\ai-talk-core" -Message "native-preferred dry-run did not use native AI Talk Core path"
    if ($preferredLaunchText -match "sword-control-plane\\scripts") {
      throw "native-preferred launch dry-run used legacy sword-control-plane scripts"
    }
    if ($preferredLaunchText -match "organs\\voice\\ai-talk-core") {
      throw "native-preferred launch dry-run used legacy AI Talk Core voice alias"
    }

    $partialAiTalkWorkspace = Join-Path $root "partial-ai-talk"
    New-NativeLaunchWorkspaceFixture -Root $partialAiTalkWorkspace
    New-LegacyLaunchAliasFixture -Root $partialAiTalkWorkspace
    Remove-FixtureSubtree -Workspace $partialAiTalkWorkspace -RelativePath "organs\speech-input"
    $partialAiTalkOutput = Invoke-Checked -Command @(
      $PowerShellCommand,
      "-NoProfile",
      "-File",
      (Join-Path $PSScriptRoot "check-launch-readiness.ps1"),
      "-WorkspaceRoot",
      $partialAiTalkWorkspace,
      "-SkipPortChecks"
    )
    $partialAiTalk = $partialAiTalkOutput -join "`n" | ConvertFrom-Json
    $partialAiTalkCheck = @($partialAiTalk.checks | Where-Object { [string]$_.id -eq "legacy_delegate_layout.ai_talk_core_voice_alias" } | Select-Object -First 1)
    if ($partialAiTalkCheck.Count -eq 0 -or [string]$partialAiTalkCheck[0].status -ne "ok") {
      throw "partial AI Talk Core layout should report available legacy voice alias fallback"
    }
    if ([string]$partialAiTalkCheck[0].detail -notmatch "fallback available") {
      throw "partial AI Talk Core layout did not explain legacy fallback: $($partialAiTalkCheck[0].detail)"
    }

    $partialAiTalkLaunchOutput = Invoke-Checked -Command @(
      $PowerShellCommand,
      "-NoProfile",
      "-ExecutionPolicy",
      "Bypass",
      "-File",
      (Join-Path $RepoRoot "control-plane\sword-voice-agent\ops\scripts\system.ps1"),
      "-WorkspaceRoot",
      $partialAiTalkWorkspace,
      "start",
      "-Profile",
      "thought-core-v0",
      "-StackStateDir",
      (Join-Path $partialAiTalkWorkspace ".cache\home-control-stack"),
      "-SkipDify",
      "-SkipDifyWatch",
      "-SkipVoicevoxCheck",
      "-MediapipeNoBrowser",
      "-DryRun"
    )
    $partialAiTalkLaunchText = $partialAiTalkLaunchOutput -join "`n"
    Assert-TextMatch -Text $partialAiTalkLaunchText -Pattern "organs\\voice\\ai-talk-core" -Message "partial AI Talk Core dry-run did not use legacy voice alias fallback"
    if ($partialAiTalkLaunchText -match "ai-talk-core directory not found") {
      throw "partial AI Talk Core fallback still reported missing ai-talk-core"
    }

    $partialControlWorkspace = Join-Path $root "partial-control-plane"
    New-NativeLaunchWorkspaceFixture -Root $partialControlWorkspace
    New-LegacyLaunchAliasFixture -Root $partialControlWorkspace
    Remove-FixtureSubtree -Workspace $partialControlWorkspace -RelativePath "control-plane\sword-voice-agent"
    $partialControlOutput = Invoke-Checked -Command @(
      $PowerShellCommand,
      "-NoProfile",
      "-File",
      (Join-Path $PSScriptRoot "check-launch-readiness.ps1"),
      "-WorkspaceRoot",
      $partialControlWorkspace,
      "-SkipPortChecks"
    )
    $partialControl = $partialControlOutput -join "`n" | ConvertFrom-Json
    if ([string]$partialControl.status -ne "blocked") {
      throw "partial control-plane layout should stay blocked for the native service target; got $($partialControl.status)"
    }
    $partialControlCheck = @($partialControl.checks | Where-Object { [string]$_.id -eq "legacy_delegate_layout.sword_control_plane_alias" } | Select-Object -First 1)
    if ($partialControlCheck.Count -eq 0 -or [string]$partialControlCheck[0].status -ne "ok") {
      throw "partial control-plane layout should report available legacy alias fallback"
    }
    if ([string]$partialControlCheck[0].detail -notmatch "fallback available") {
      throw "partial control-plane layout did not explain legacy fallback: $($partialControlCheck[0].detail)"
    }
  }
  finally {
    Remove-FreshTestRoot -Path $root
  }
}

function Test-DeveloperWorkspaceBootstrap {
  if ($SkipFreshClone) {
    Write-Warning "developer workspace bootstrap fixture skipped"
    return
  }

  Write-TestStep "developer workspace bootstrap opt-in"
  $root = New-FreshTestRoot
  try {
    $clonePath = Join-Path $root "sword-agent-os"
    Invoke-Checked -Command @("git", "clone", "--local", "--no-hardlinks", $RepoRoot, $clonePath) -WorkingDirectory $root | Out-Null

    Invoke-Checked -Command @(
      $PowerShellCommand,
      "-NoProfile",
      "-File",
      (Join-Path $clonePath "scripts/bootstrap-workspace.ps1"),
      "-DeveloperWorkspace"
    ) -WorkingDirectory $clonePath | Out-Null
    foreach ($expected in @(
      "worktrees",
      "_codex",
      "local",
      "local\organ-cache",
      "local\artifact-cache",
      "local\backups",
      "local\scratch"
    )) {
      Assert-PathPresent -Path (Join-Path $root $expected)
    }
    Assert-PathAbsent -Path (Join-Path $root "coordination")

    $coordinationSource = Join-Path $root "coordination-source"
    New-LocalGitRepository -Path $coordinationSource | Out-Null
    Invoke-Checked -Command @(
      $PowerShellCommand,
      "-NoProfile",
      "-File",
      (Join-Path $clonePath "scripts/bootstrap-workspace.ps1"),
      "-CloneCoordination",
      "-CoordinationRepoUrl",
      $coordinationSource
    ) -WorkingDirectory $clonePath | Out-Null
    Assert-PathPresent -Path (Join-Path $root "coordination")
    Assert-PathPresent -Path (Join-Path $root "coordination\local")
    Assert-PathPresent -Path (Join-Path $root "coordination\shared\.git")
  }
  finally {
    Remove-FreshTestRoot -Path $root
  }
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

    $installOutput = Invoke-Checked -Command @(
      $PowerShellCommand,
      "-NoProfile",
      "-File",
      (Join-Path $clonePath "scripts/install-distribution.ps1"),
      "-Profile",
      $Profile,
      "-DryRun",
      "-NoDeps"
    ) -WorkingDirectory $clonePath
    $installText = $installOutput -join "`n"
    Assert-TextMatch -Text $installText -Pattern "bootstrap-control-plane\.ps1" -Message "install dry-run did not report control-plane bootstrap"
    Assert-TextMatch -Text $installText -Pattern "bootstrap-organs\.ps1" -Message "install dry-run did not report organ bootstrap"
    Assert-TextMatch -Text $installText -Pattern "-DryRun" -Message "install dry-run did not propagate dry-run to bootstrap commands"
    Assert-TextMatch -Text $installText -Pattern "dependency install skipped: -NoDeps" -Message "install dry-run did not skip dependencies with -NoDeps"
    Assert-PathAbsent -Path (Join-Path $clonePath "local\env\sword-agent-os.env")

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
Test-MaintenanceSafetyStatic
Test-PublicPathLeakStatic
Test-ReadmeFirstRunGuidance
Test-ManifestAndVersion
Test-UpdateFixtureHoldBehavior
Test-EnvRenderFixtures
Test-NativeLaunchLayoutFixtures
Test-DeveloperWorkspaceBootstrap
Test-InstalledWorkspaceMaintenance
Test-FreshCloneDryRun

Write-Host ""
Write-Host "maintenance smoke tests: ok" -ForegroundColor Green
