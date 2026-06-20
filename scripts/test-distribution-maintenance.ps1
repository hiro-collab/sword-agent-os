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
    "scripts/check-distribution-pins.ps1",
    "scripts/doctor-distribution.ps1",
    "scripts/render-env-files.ps1",
    "scripts/start-home-control-bridge.ps1",
    "scripts/inspect-home-control-switchbot-surfaces.ps1",
    "scripts/run-home-control-light-proof.ps1",
    "scripts/check-voicevox-readiness.ps1",
    "scripts/evaluate-room-light-sunshine.ps1",
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

function Get-TestLayoutSourceFiles {
  $excludedDirectoryNames = New-Object "System.Collections.Generic.HashSet[string]" ([System.StringComparer]::OrdinalIgnoreCase)
  foreach ($name in @(
      ".git",
      ".venv",
      ".uv-cache",
      ".cache",
      "node_modules",
      "test-runs",
      "dist",
      "build",
      ".next",
      "coverage"
    )) {
    $excludedDirectoryNames.Add($name) | Out-Null
  }

  function Test-GitIgnoredRelativePath {
    param([Parameter(Mandatory = $true)][string]$RelativePath)
    if ([string]::IsNullOrWhiteSpace($RelativePath)) {
      return $false
    }
    $previousErrorActionPreference = $ErrorActionPreference
    try {
      $ErrorActionPreference = "Continue"
      & git -C $RepoRoot check-ignore -q -- $RelativePath *> $null
      return ($LASTEXITCODE -eq 0)
    }
    finally {
      $ErrorActionPreference = $previousErrorActionPreference
    }
  }

  $excludedRelativeRoots = @(
    "control-plane\sword-voice-agent",
    "organs\speech-input\ai-talk-core",
    "organs\reflex\mediapipe-sword-sign",
    "organs\environment\environment-state-server",
    "organs\environment\vision-snapshot-processor",
    "organs\action\home-assistant-server",
    "organs\expression\tts-service",
    "organs\expression\aituber-kit",
    "organs\display\touchdesigner-ai-controller",
    "organs\diagnostics\system-house-renderer"
  )

  $stack = New-Object "System.Collections.Generic.Stack[System.IO.DirectoryInfo]"
  $stack.Push((Get-Item -LiteralPath $RepoRoot))
  while ($stack.Count -gt 0) {
    $directory = $stack.Pop()
    foreach ($childDirectory in $directory.GetDirectories()) {
      $relativeChild = $childDirectory.FullName.Substring($RepoRoot.Length).TrimStart(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar
      )
      if (Test-GitIgnoredRelativePath -RelativePath $relativeChild) {
        continue
      }
      $isNestedCheckout = $false
      foreach ($excludedRoot in $excludedRelativeRoots) {
        if ($relativeChild.Equals($excludedRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
          $isNestedCheckout = $true
          break
        }
      }
      if ($isNestedCheckout) {
        continue
      }
      if (-not $excludedDirectoryNames.Contains($childDirectory.Name)) {
        $stack.Push($childDirectory)
      }
    }
    foreach ($file in $directory.GetFiles()) {
      $relativeFile = $file.FullName.Substring($RepoRoot.Length).TrimStart(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar
      )
      if (-not (Test-GitIgnoredRelativePath -RelativePath $relativeFile)) {
        $file
      }
    }
  }
}

function Test-TestLayoutPolicy {
  Write-TestStep "test layout policy static checks"
  $policyPath = Join-Path $RepoRoot "manifests\tests\README.md"
  $packReadmePath = Join-Path $RepoRoot "manifests\tests\organ-test-packs\README.md"
  $standardPackPath = Join-Path $RepoRoot "manifests\tests\organ-test-packs\standard.json"
  Assert-PathPresent -Path $policyPath
  Assert-PathPresent -Path $packReadmePath
  Assert-PathPresent -Path $standardPackPath

  $policy = Get-Content -Raw -LiteralPath $policyPath
  Assert-TextMatch -Text $policy -Pattern "Module-internal unit and contract tests" -Message "test layout policy should describe module-local tests"
  Assert-TextMatch -Text $policy -Pattern "organ-test-packs" -Message "test layout policy should describe cross-module test packs"
  Assert-TextMatch -Text $policy -Pattern "Generated SQLite databases and evidence" -Message "test layout policy should keep generated memory proof out of source"
  Assert-TextMatch -Text $policy -Pattern "service.*execution/process shape" -Message "test layout policy should clarify service as process shape"
  Assert-TextMatch -Text $policy -Pattern "Memory Core and Event Journal are runtime substrate" -Message "test layout policy should keep Memory Core/Event Journal as runtime substrate"

  $testNamePattern = "^(test_.+\.py|.+_test\.py|smoke_test\.py|.+\.(test|spec)\.(ts|tsx|js|jsx|mjs))$"
  $allowedSegments = @("tests", "__tests__", "test")
  $legacyExceptions = @(
    "organs\speech-input\ai-talk-core\smoke_test.py",
    "organs\voice\ai-talk-core\smoke_test.py"
  )
  $violations = @()
  $warnings = @()
  foreach ($file in Get-TestLayoutSourceFiles) {
    if ($file.Name -notmatch $testNamePattern) {
      continue
    }
    $relativePath = $file.FullName.Substring($RepoRoot.Length).TrimStart(
      [System.IO.Path]::DirectorySeparatorChar,
      [System.IO.Path]::AltDirectorySeparatorChar
    )
    if ($legacyExceptions -contains $relativePath) {
      $warnings += "legacy test-layout exception: $relativePath"
      continue
    }
    $segments = $relativePath -split "[\\/]"
    $inAllowedSegment = $false
    foreach ($segment in $allowedSegments) {
      if ($segments -contains $segment) {
        $inAllowedSegment = $true
        break
      }
    }
    if (-not $inAllowedSegment) {
      $violations += $relativePath
    }
  }

  foreach ($warning in $warnings) {
    Write-Warning $warning
  }
  if ($violations.Count -gt 0) {
    $violationText = $violations -join "; "
    throw "test files outside allowed roots: $violationText"
  }
  Write-Host "test layout policy ok: $($warnings.Count) warning(s), 0 failure(s)"
}

function Test-ReadmeFirstRunGuidance {
  Write-TestStep "README first-run guidance static checks"
  $readme = Get-Content -Raw -LiteralPath (Join-Path $RepoRoot "README.md")
  $verificationCommandsPath = Join-Path $RepoRoot "docs\verification-commands.md"
  Assert-PathPresent -Path $verificationCommandsPath
  $verificationCommands = Get-Content -Raw -LiteralPath $verificationCommandsPath
  $verificationSurface = "$readme`n$verificationCommands"
  $troubleshootingPath = Join-Path $RepoRoot "docs\troubleshooting.md"
  Assert-PathPresent -Path $troubleshootingPath
  $troubleshooting = Get-Content -Raw -LiteralPath $troubleshootingPath
  $troubleshootingSurface = "$readme`n$troubleshooting"
  $frontDoorDocs = @(
    "docs\operate.md",
    "docs\customize.md",
    "docs\proof-layers.md",
    "docs\manifest-ledger-authority.md",
    "docs\local-configuration.md",
    "docs\home-assistant-setup.md",
    "docs\home-control-action-authoring.md",
    "docs\live-home-control-proof.md",
    "runtime\control\README.md"
  )
  $frontDoorSurface = $readme
  foreach ($docPath in $frontDoorDocs) {
    $absoluteDocPath = Join-Path $RepoRoot $docPath
    Assert-PathPresent -Path $absoluteDocPath
    $frontDoorSurface = "$frontDoorSurface`n$(Get-Content -Raw -LiteralPath $absoluteDocPath)"
  }
  Assert-TextMatch -Text $readme -Pattern "prepared local|準備済みローカル" -Message "README should describe prepared local inputs without requiring private folder names"
  Assert-TextMatch -Text $readme -Pattern "_secret_inputs.*product convention|製品として特定のフォルダ名を要求しません" -Message "README should not make _secret_inputs look like a required product convention"
  Assert-TextMatch -Text $readme -Pattern "15分 quick-start" -Message "README should include the 15-minute quick-start path"
  Assert-TextMatch -Text $readme -Pattern "prepare-local-inputs\.ps1" -Message "README should document the optional local input helper without making it a product requirement"
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
  Assert-TextMatch -Text $readme -Pattern "-CheckTracking -ActionId" -Message "README should show helper-based state-tracking metadata check before execute"
  Assert-TextMatch -Text $readme -Pattern "-CheckState -ActionId" -Message "README should show helper-based Home Assistant state check"
  Assert-TextMatch -Text $readme -Pattern "live_test_readiness" -Message "README should document Home Control live-test readiness metadata"
  Assert-TextMatch -Text $readme -Pattern "restore_action_id" -Message "README should document Home Control restore action metadata"
  Assert-TextMatch -Text $readme -Pattern "proof_ceiling" -Message "README should document Home Control proof ceiling metadata"
  Assert-TextMatch -Text $readme -Pattern "実行後または restore 後|post-action" -Message "README should separate CheckState from pre-execution checks"
  Assert-TextMatch -Text $readme -Pattern "live-home-control-cause-trail\.md" -Message "README should link live Home Control cause trail"
  Assert-PathPresent -Path (Join-Path $RepoRoot "docs\live-home-control-cause-trail.md")
  $bridgeHelper = Get-Content -Raw -LiteralPath (Join-Path $RepoRoot "scripts\start-home-control-bridge.ps1")
  Assert-TextMatch -Text $bridgeHelper -Pattern "--env-file" -Message "Home Control bridge helper should pass generated .env through uv"
  Assert-TextMatch -Text $bridgeHelper -Pattern "config_error_kind" -Message "Home Control bridge helper should report redacted config error kind"
  Assert-TextMatch -Text $bridgeHelper -Pattern "cause_code" -Message "Home Control bridge helper should report cause codes"
  Assert-TextMatch -Text $bridgeHelper -Pattern "root_cause_trace" -Message "Home Control bridge helper should emit root-cause trace packet"
  Assert-TextMatch -Text $bridgeHelper -Pattern "HOME_ASSISTANT_TOKEN" -Message "Home Control bridge helper should classify Home Assistant token readiness"
  Assert-TextMatch -Text $bridgeHelper -Pattern "CheckTracking" -Message "Home Control bridge helper should provide a redacted state-tracking metadata mode"
  Assert-TextMatch -Text $bridgeHelper -Pattern "live_test_readiness" -Message "Home Control bridge helper should report live-test readiness"
  Assert-TextMatch -Text $bridgeHelper -Pattern "live_test_blockers" -Message "Home Control bridge helper should report exact live-test blockers"
  Assert-TextMatch -Text $bridgeHelper -Pattern "restore_action" -Message "Home Control bridge helper should report restore action classes"
  Assert-TextMatch -Text $bridgeHelper -Pattern "safety_requirements" -Message "Home Control bridge helper should report safety requirement classes"
  Assert-TextMatch -Text $bridgeHelper -Pattern "CheckState" -Message "Home Control bridge helper should provide a redacted state-check mode"
  Assert-TextMatch -Text $bridgeHelper -Pattern "bridge_start: status=starting" -Message "Home Control bridge helper should print startup status"
  Assert-TextMatch -Text $bridgeHelper -Pattern "UV_CACHE_DIR" -Message "Home Control bridge helper should use a local uv cache without changing persistent environment"
  Assert-TextMatch -Text $bridgeHelper -Pattern "UvCacheDir" -Message "Home Control bridge helper should expose a scoped uv cache override"
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
  Assert-TextMatch -Text $causeTrail -Pattern "state_tracking=tracked" -Message "cause trail should separate tracking metadata from post-state proof"
  Assert-TextMatch -Text $causeTrail -Pattern "live_test_readiness" -Message "cause trail should explain live-test readiness as separate from state tracking"
  Assert-TextMatch -Text $troubleshootingSurface -Pattern "UV_CACHE_DIR" -Message "public troubleshooting docs should include uv cache troubleshooting guidance"
  Assert-TextMatch -Text $troubleshootingSurface -Pattern "uv python find" -Message "public troubleshooting docs should explain uv-based Python interpreter discovery"
  Assert-TextMatch -Text $troubleshootingSurface -Pattern "Git ownership warning" -Message "public troubleshooting docs should frame restricted-environment Git ownership warnings as validation friction"
  Assert-TextMatch -Text $readme -Pattern "doctor-distribution\.ps1" -Message "README should document the distribution doctor"
  Assert-TextMatch -Text $readme -Pattern "check-distribution-pins\.ps1" -Message "README should document the distribution pin checker"
  Assert-TextMatch -Text $readme -Pattern "ahead_of_manifest|正式採用待ち|parent adoption" -Message "README should explain ahead-of-manifest pin state"
  Assert-TextMatch -Text $readme -Pattern "git_unreadable[\s\S]{0,240}pin mismatch" -Message "README should separate git_unreadable from true pin mismatch"
  Assert-TextMatch -Text $troubleshootingSurface -Pattern "port 競合[\s\S]{0,240}isolated_override|isolated_override[\s\S]{0,240}port 競合" -Message "public troubleshooting docs should explain port-conflict handling"
  Assert-TextMatch -Text $troubleshootingSurface -Pattern '既存の `sword-agent-os` directory' -Message "public troubleshooting docs should explain existing clone directory handling"
  Assert-TextMatch -Text $troubleshootingSurface -Pattern "network permission" -Message "public troubleshooting docs should classify restricted environment network reruns"
  Assert-TextMatch -Text $readme -Pattern "foreground の" -Message "README should explain Home Control bridge foreground behavior"
  Assert-TextMatch -Text $readme -Pattern "status=submitted" -Message "README should explain submitted execute status"
  Assert-TextMatch -Text $readme -Pattern "install/readiness pass" -Message "README should separate first-run report proof layers"
  Assert-TextMatch -Text $readme -Pattern "gesture-to-voice-input" -Message "README should separate gesture-to-voice gate proof"
  Assert-TextMatch -Text $troubleshootingSurface -Pattern "npm audit" -Message "public troubleshooting docs should include npm audit interpretation guidance"
  Assert-TextMatch -Text $readme -Pattern "run-local-media-replay\.ps1" -Message "README should document the local media replay preview helper"
  Assert-TextMatch -Text $readme -Pattern "evaluate-room-light-sunshine\.ps1" -Message "README should document the sunshine room-light evaluator"
  Assert-TextMatch -Text $readme -Pattern "check-voicevox-readiness\.ps1" -Message "README should document the VOICEVOX readiness helper"
  Assert-TextMatch -Text $readme -Pattern "Start Stack し直して" -Message "README should explain restart after forced env/config render"
  Assert-TextMatch -Text $readme -Pattern "run-full-install-verification\.ps1" -Message "README should document the full install verification helper"
  Assert-TextMatch -Text $readme -Pattern "run-home-control-light-proof\.ps1" -Message "README should document the physical light proof helper"
  Assert-TextMatch -Text $verificationSurface -Pattern "run-home-control-light-proof\.ps1" -Message "public verification docs should document the physical light proof helper"
  Assert-TextMatch -Text $troubleshootingSurface -Pattern "run-home-control-light-proof\.ps1" -Message "troubleshooting should point light physical proof to the bounded helper"
  Assert-PathPresent -Path (Join-Path $RepoRoot "scripts\run-home-control-light-proof.ps1")
  Assert-TextMatch -Text $verificationSurface -Pattern "inspect-home-control-switchbot-surfaces\.ps1" -Message "public verification docs should document the SwitchBot read-only surface helper"
  Assert-PathPresent -Path (Join-Path $RepoRoot "scripts\inspect-home-control-switchbot-surfaces.ps1")
  Assert-PathPresent -Path (Join-Path $RepoRoot "scripts\measure-camera-brightness.py")
  $lightProofHelper = Get-Content -Raw -LiteralPath (Join-Path $RepoRoot "scripts\run-home-control-light-proof.ps1")
  $switchBotInspectHelper = Get-Content -Raw -LiteralPath (Join-Path $RepoRoot "scripts\inspect-home-control-switchbot-surfaces.ps1")
  $cameraBrightnessHelper = Get-Content -Raw -LiteralPath (Join-Path $RepoRoot "scripts\measure-camera-brightness.py")
  Assert-TextMatch -Text $lightProofHelper -Pattern "ConfirmLiveLightTicket" -Message "physical light proof helper should require explicit live ticket confirmation"
  Assert-TextMatch -Text $lightProofHelper -Pattern "raw_media_saved" -Message "physical light proof helper should report raw media is not saved"
  Assert-TextMatch -Text $lightProofHelper -Pattern "entity_id_shared" -Message "physical light proof helper should report entity ids are not shared"
  Assert-TextMatch -Text $lightProofHelper -Pattern "preview_status" -Message "physical light proof helper should record preview status"
  Assert-TextMatch -Text $lightProofHelper -Pattern "dry_run_status" -Message "physical light proof helper should record dry-run status"
  Assert-TextMatch -Text $lightProofHelper -Pattern "cause_kind" -Message "physical light proof helper should classify bridge startup failures"
  Assert-TextMatch -Text $lightProofHelper -Pattern "ConvertTo-RedactedText" -Message "physical light proof helper should redact diagnostic log tails"
  Assert-TextMatch -Text $lightProofHelper -Pattern "inverted" -Message "physical light proof helper should classify opposite brightness movement without claiming expected on proof"
  Assert-TextMatch -Text $switchBotInspectHelper -Pattern 'ha_service_call = "no"' -Message "SwitchBot read-only helper should not perform HA service calls"
  Assert-TextMatch -Text $switchBotInspectHelper -Pattern "live_test_readiness" -Message "SwitchBot read-only helper should report live-test readiness"
  Assert-TextMatch -Text $switchBotInspectHelper -Pattern "safety_requirement" -Message "SwitchBot read-only helper should report safety requirement blockers"
  Assert-TextMatch -Text $cameraBrightnessHelper -Pattern "raw_media_saved" -Message "camera brightness helper should report raw media is not saved"
  Assert-TextMatch -Text $cameraBrightnessHelper -Pattern "cv2\.VideoCapture" -Message "camera brightness helper should use OpenCV without writing frames"
  Assert-TextMatch -Text $verificationSurface -Pattern "default_safety=no-live/no-device" -Message "public verification docs should state the full verification helper default safety"
  Assert-TextMatch -Text $readme -Pattern "RequestLiveHomeAssistant[\s\S]{0,320}ConfirmHomeAssistantTicket|ConfirmHomeAssistantTicket[\s\S]{0,320}RequestLiveHomeAssistant" -Message "README should require explicit live HA request and ticket confirmation"
  Assert-TextMatch -Text $readme -Pattern "local-media replay" -Message "README should name local-media replay as a separate proof layer"
  Assert-TextMatch -Text $readme -Pattern "gesture\.sword\.20260603" -Message "README should show the sword-sign positive local media asset id"
  Assert-TextMatch -Text $readme -Pattern "vision\.room_light\.on\.20260603" -Message "README should show the room-light local media asset id"
  Assert-TextMatch -Text $frontDoorSurface -Pattern "sword\.ps1" -Message "front-door docs should document the root sword.ps1 wrapper"
  Assert-TextMatch -Text $frontDoorSurface -Pattern "まず安全に見る" -Message "operator docs should be organized by user intent"
  Assert-TextMatch -Text $frontDoorSurface -Pattern "Customize Sword Agent OS" -Message "front-door docs should include a customization map"
  Assert-TextMatch -Text $frontDoorSurface -Pattern "やりたいこと" -Message "customization docs should let users start from their goal"
  Assert-TextMatch -Text $frontDoorSurface -Pattern "使う AI サービスやモデルを変えたい" -Message "customization docs should use user-facing Japanese for LLM changes"
  Assert-TextMatch -Text $frontDoorSurface -Pattern "操作できる家電動作を増やしたい" -Message "customization docs should describe Home Assistant actions as user goals"
  Assert-TextMatch -Text $frontDoorSurface -Pattern "実際の家電が動いた証拠を取りたい" -Message "customization docs should describe live proof as a user goal"
  Assert-TextMatch -Text $frontDoorSurface -Pattern "runtime/control/README\.md|runtime\\control\\README\.md" -Message "front-door docs should link runtime control vocabulary"
  Assert-TextMatch -Text $frontDoorSurface -Pattern "HOLD_LIVE[\s\S]{0,240}STOP[\s\S]{0,240}PAUSE[\s\S]{0,240}REQUIRE_APPROVAL" -Message "runtime control docs should define the core control vocabulary"
  Assert-TextMatch -Text $frontDoorSurface -Pattern "\.cache\\agent-os\\control\\hold-live\.json" -Message "runtime control docs should name the local hold-live marker"
  Assert-TextMatch -Text $frontDoorSurface -Pattern "not yet a universal runtime interlock|universal runtime interlock" -Message "runtime control docs should state hold-live enforcement boundary"
  Assert-TextMatch -Text $frontDoorSurface -Pattern "Action Boundary[\s\S]{0,160}Home Control bridge[\s\S]{0,160}Launch\s+Manager|Launch\s+Manager[\s\S]{0,160}Home Control bridge[\s\S]{0,160}Action Boundary" -Message "runtime control docs should name intended hold-live reader surfaces"
  Assert-TextMatch -Text $frontDoorSurface -Pattern "full-schema private/live config|reviewed clone-local equivalent" -Message "customization docs should explain full-schema Home Assistant config requirements"
  Assert-TextMatch -Text $frontDoorSurface -Pattern "partial, not release-ready" -Message "front-door docs should keep scoped fresh-install evidence separate from release readiness"
  Assert-TextMatch -Text $frontDoorSurface -Pattern "source/static" -Message "proof-layer docs should name source/static proof"
  Assert-TextMatch -Text $frontDoorSurface -Pattern "runtime/status" -Message "proof-layer docs should name runtime/status proof"
  Assert-TextMatch -Text $frontDoorSurface -Pattern "physical/device proof" -Message "proof-layer docs should name physical/device proof"
  Assert-TextMatch -Text $frontDoorSurface -Pattern "manifest-ledger-authority\.md" -Message "README should link the manifest ledger authority page"
  Assert-TextMatch -Text $frontDoorSurface -Pattern "home-control-action-authoring\.md" -Message "README should link Home Control action authoring docs"
  Assert-TextMatch -Text $frontDoorSurface -Pattern "home-assistant-setup\.md" -Message "front-door docs should link Home Assistant setup docs"
  Assert-TextMatch -Text $frontDoorSurface -Pattern "Connection[\s\S]{0,120}Proof-ready config|Proof-ready config[\s\S]{0,120}Connection" -Message "Home Assistant setup docs should separate connection from proof-ready config"
  Assert-TextMatch -Text $frontDoorSurface -Pattern "live-home-control-proof\.md" -Message "README should link live Home Control proof docs"
  Assert-TextMatch -Text $frontDoorSurface -Pattern "Home Assistant Config Context" -Message "front-door docs should name the Home Assistant config context checkpoint"
  Assert-TextMatch -Text $frontDoorSurface -Pattern "HOME_CONTROL_CONFIG" -Message "front-door docs should name selected Home Control config path"
  Assert-TextMatch -Text $frontDoorSurface -Pattern "full-schema|full schema" -Message "front-door docs should require full-schema config for HA-visible CheckState proof"
  Assert-TextMatch -Text $frontDoorSurface -Pattern "short/minimal action-only override" -Message "front-door docs should separate minimal overrides from tracked-state proof"
  Assert-TextMatch -Text $frontDoorSurface -Pattern "demo/default/template" -Message "front-door docs should require rejecting demo/default/template context for live proof"
  Assert-TextMatch -Text $frontDoorSurface -Pattern "reviewed clone-local equivalent|reviewed_clone_local_full_schema_equivalent" -Message "front-door docs should support reviewed clone-local full-schema equivalents for worktree verification"
  Assert-TextMatch -Text $frontDoorSurface -Pattern "dry-run.*token.*consumed|token.*dry-run.*consumed" -Message "front-door docs should explain dry-run confirmation token consumption"
  Assert-TextMatch -Text $frontDoorSurface -Pattern "HA-visible CheckState.*physical proof|physical proof.*HA-visible CheckState" -Message "front-door docs should prevent promoting HA-visible CheckState to physical proof"
  $standardDistributionMap = Get-Content -Raw -LiteralPath (Join-Path $RepoRoot "docs\standard-distribution-map.md")
  Assert-TextMatch -Text $standardDistributionMap -Pattern "\.\\sword\.ps1 status[\s\S]{0,120}\.\\sword\.ps1 verify" -Message "standard distribution map should start first success with sword.ps1 front-door checks"
  Assert-TextMatch -Text $standardDistributionMap -Pattern "sword\.ps1.*入口.*script.*詳細工具|script.*詳細工具.*sword\.ps1.*入口" -Message "standard distribution map should explain front-door vs detailed script roles"
  Assert-TextMatch -Text $standardDistributionMap -Pattern "docs/home-assistant-setup\.md" -Message "standard distribution map should point external HA setup to the setup guide"
  Assert-TextMatch -Text $standardDistributionMap -Pattern "HOME_CONTROL_CONFIG[\s\S]{0,200}private full-schema|private full-schema[\s\S]{0,200}HOME_CONTROL_CONFIG" -Message "standard distribution map should require proof-ready selected config before live HA"
  $centralEnvTemplate = Get-Content -Raw -LiteralPath (Join-Path $RepoRoot "templates\env\sword-agent-os.env.example")
  $homeControlEnvTemplate = Get-Content -Raw -LiteralPath (Join-Path $RepoRoot "organs\action\home-assistant-server\.env.example")
  $homeControlExampleConfigTemplate = Get-Content -Raw -LiteralPath (Join-Path $RepoRoot "organs\action\home-assistant-server\config\home-control.example.yaml")
  $homeAssistantTemplateSurface = "$centralEnvTemplate`n$homeControlEnvTemplate`n$homeControlExampleConfigTemplate"
  Assert-TextMatch -Text $homeAssistantTemplateSurface -Pattern "docs/home-assistant-setup\.md" -Message "Home Assistant env/config examples should point first-time operators to the setup guide"
  Assert-TextMatch -Text $homeAssistantTemplateSurface -Pattern "demo/default/template" -Message "Home Assistant env/config examples should mark public config as demo/default/template"
  Assert-TextMatch -Text $homeAssistantTemplateSurface -Pattern "ignored private full-schema config|private full-schema config" -Message "Home Assistant env/config examples should require private full-schema config for live proof"
  Assert-TextMatch -Text $homeAssistantTemplateSurface -Pattern "reviewed clone-local equivalent" -Message "Home Assistant env/config examples should support reviewed clone-local equivalents"
  Assert-TextMatch -Text $homeAssistantTemplateSurface -Pattern "short/minimal action-only override" -Message "Home Assistant env/config examples should warn that minimal action-only overrides are not proof-ready"
  Assert-TextMatch -Text $homeAssistantTemplateSurface -Pattern "expected-effect target|expected_effect" -Message "Home Assistant env/config examples should require expected-effect target metadata"
  Assert-TextMatch -Text $homeAssistantTemplateSurface -Pattern "CheckTracking.*CheckState|CheckState.*CheckTracking" -Message "Home Assistant env/config examples should keep CheckTracking and CheckState visible"
  Assert-TextMatch -Text $homeAssistantTemplateSurface -Pattern "read-only parity gate" -Message "Home Assistant env/config examples should require read-only parity before live routes"
  Assert-TextMatch -Text $verificationSurface -Pattern "raw_media_shared=false" -Message "public verification docs should show raw media is not shared in local-media results"
  Assert-TextMatch -Text $verificationSurface -Pattern "generated_output_written=false" -Message "public verification docs should show preview helper does not write generated output"
  Assert-TextMatch -Text $verificationSurface -Pattern "SecretInputsRoot" -Message "public verification docs should explain separate secret input roots"
  $localMediaPreparationHelper = Get-Content -Raw -LiteralPath (Join-Path $RepoRoot "scripts\prepare-local-media-index.ps1")
  Assert-TextMatch -Text $localMediaPreparationHelper -Pattern "SecretInputsRoot" -Message "local media preparation helper should support private secret inputs outside the workspace root"
  Assert-TextMatch -Text $localMediaPreparationHelper -Pattern "<secret-inputs>" -Message "local media preparation helper should redact the secret inputs root"
  $localMediaHelper = Get-Content -Raw -LiteralPath (Join-Path $RepoRoot "scripts\run-local-media-replay.ps1")
  Assert-TextMatch -Text $localMediaHelper -Pattern "local/media/media-index\.json" -Message "local media helper should resolve the local media index"
  Assert-TextMatch -Text $localMediaHelper -Pattern "source/static-command-preview" -Message "local media helper should label preview output as source/static-command-preview"
  Assert-TextMatch -Text $localMediaHelper -Pattern "next_proof_layer" -Message "local media helper should separate the next bounded replay proof layer"
  Assert-TextMatch -Text $localMediaHelper -Pattern "raw_media_shared=false" -Message "local media helper should print raw_media_shared=false"
  Assert-TextMatch -Text $localMediaHelper -Pattern "raw_transcript_shared=false" -Message "local media helper should print raw_transcript_shared=false"
  Assert-TextMatch -Text $localMediaHelper -Pattern "generated_output_written=false" -Message "local media helper should print generated_output_written=false"
  Assert-TextMatch -Text $localMediaHelper -Pattern "live_action_executed=false" -Message "local media helper should print live_action_executed=false"
  Assert-TextMatch -Text $localMediaHelper -Pattern "<workspace>" -Message "local media helper should use placeholders instead of private absolute paths"
  Assert-TextMatch -Text $localMediaHelper -Pattern "<workspace-uri>" -Message "room-light preview should use a placeholder file URI"
  Assert-PathPresent -Path (Join-Path $RepoRoot "scripts\evaluate-room-light-sunshine.ps1")
  Assert-PathPresent -Path (Join-Path $RepoRoot "scripts\evaluate-room-light-video.py")
  $sunshineHelper = Get-Content -Raw -LiteralPath (Join-Path $RepoRoot "scripts\evaluate-room-light-sunshine.ps1")
  $sunshinePython = Get-Content -Raw -LiteralPath (Join-Path $RepoRoot "scripts\evaluate-room-light-video.py")
  Assert-TextMatch -Text $sunshineHelper -Pattern "direct_file_helper" -Message "sunshine helper should report the direct-file route"
  Assert-TextMatch -Text $sunshineHelper -Pattern "SamplingMode" -Message "sunshine helper should expose dense sampling mode"
  Assert-TextMatch -Text $sunshineHelper -Pattern 'raw_media_shared.*false|raw_media_shared = \$false' -Message "sunshine helper should not share raw media"
  Assert-TextMatch -Text $sunshineHelper -Pattern 'generated_model_written.*false|generated_model_written = \$false' -Message "sunshine helper should not write generated models"
  Assert-TextMatch -Text $sunshinePython -Pattern "cv2\.VideoCapture" -Message "sunshine evaluator should read video frames through OpenCV"
  Assert-TextMatch -Text $sunshinePython -Pattern "all-frames" -Message "sunshine evaluator should support dense all-frame-pair sampling"
  Assert-TextMatch -Text $sunshinePython -Pattern "generated_frames_written" -Message "sunshine evaluator should report that generated frames were not written"
  Assert-PathPresent -Path (Join-Path $RepoRoot "scripts\run-full-install-verification.ps1")
  $fullInstallHelper = Get-Content -Raw -LiteralPath (Join-Path $RepoRoot "scripts\run-full-install-verification.ps1")
  Assert-TextMatch -Text $fullInstallHelper -Pattern "default_safety=no-live/no-device" -Message "full install helper should report default no-live/no-device safety"
  Assert-TextMatch -Text $fullInstallHelper -Pattern "RequestRealCamera" -Message "full install helper should require explicit real camera request"
  Assert-TextMatch -Text $fullInstallHelper -Pattern "RequestVirtualAudio" -Message "full install helper should require explicit virtual audio request"
  Assert-TextMatch -Text $fullInstallHelper -Pattern "RequestVoicevoxStartup" -Message "full install helper should require explicit VOICEVOX startup request"
  Assert-TextMatch -Text $fullInstallHelper -Pattern "SecretInputsRoot" -Message "full install helper should forward a separate secret inputs root"
  Assert-TextMatch -Text $fullInstallHelper -Pattern "<secret-inputs>" -Message "full install helper should redact separate secret inputs root paths"
  Assert-TextMatch -Text $fullInstallHelper -Pattern "RequestLiveHomeAssistant" -Message "full install helper should require explicit live HA request"
  Assert-TextMatch -Text $fullInstallHelper -Pattern "ConfirmHomeAssistantTicket" -Message "full install helper should require live HA ticket confirmation"
  Assert-TextMatch -Text $fullInstallHelper -Pattern "git_unreadable" -Message "full install helper should separate git_unreadable from true pin mismatch"
  Assert-TextMatch -Text $fullInstallHelper -Pattern 'raw_audio_shared = \$false' -Message "full install helper should keep raw audio unshared"
  Assert-TextMatch -Text $fullInstallHelper -Pattern 'live_action_executed = \$false' -Message "full install helper should not execute live actions"
  Assert-TextMatch -Text $fullInstallHelper -Pattern "<workspace>" -Message "full install helper should redact workspace paths in display commands"
  Assert-TextMatch -Text $fullInstallHelper -Pattern "run-local-media-replay\.ps1" -Message "full install helper should call the local media preview helper"
  Assert-TextMatch -Text $fullInstallHelper -Pattern "check-voicevox-readiness\.ps1" -Message "full install helper should call the VOICEVOX readiness helper"
  Assert-TextMatch -Text $fullInstallHelper -Pattern "test-local-media-voice-gate\.ps1" -Message "full install helper should call the voice-gate preview helper"
  Assert-TextMatch -Text $fullInstallHelper -Pattern "start-home-control-bridge\.ps1" -Message "full install helper should use the Home Control bridge only for preflight/tracking checks"
  Assert-TextMatch -Text $fullInstallHelper -Pattern "CheckTracking" -Message "full install helper should use tracking metadata before live execute instead of post-state checks"
  Assert-PathPresent -Path (Join-Path $RepoRoot "scripts\check-voicevox-readiness.ps1")
  $voicevoxHelper = Get-Content -Raw -LiteralPath (Join-Path $RepoRoot "scripts\check-voicevox-readiness.ps1")
  Assert-TextMatch -Text $voicevoxHelper -Pattern "EndpointUrl" -Message "VOICEVOX helper should check endpoint first"
  Assert-TextMatch -Text $voicevoxHelper -Pattern "StartIfNeeded" -Message "VOICEVOX helper should require explicit startup request"
  Assert-TextMatch -Text $voicevoxHelper -Pattern "installed_or_updated_voicevox" -Message "VOICEVOX helper should report that it did not install or update VOICEVOX"
  Assert-TextMatch -Text $voicevoxHelper -Pattern "global_audio_changed_by_script" -Message "VOICEVOX helper should report that it did not change global audio"
  Assert-PathPresent -Path (Join-Path $RepoRoot "control-plane\sword-voice-agent\src\sword_voice_agent\apps\local_media_voice_gate_proof.py")
  Assert-PathPresent -Path (Join-Path $RepoRoot "scripts\test-local-media-voice-gate.ps1")
  $voiceGateHelper = Get-Content -Raw -LiteralPath (Join-Path $RepoRoot "control-plane\sword-voice-agent\src\sword_voice_agent\apps\local_media_voice_gate_proof.py")
  $voiceGateWrapper = Get-Content -Raw -LiteralPath (Join-Path $RepoRoot "scripts\test-local-media-voice-gate.ps1")
  Assert-TextMatch -Text $voiceGateHelper -Pattern "FORBIDDEN_OUTPUT_KEYS" -Message "voice-gate proof helper should maintain a blocked output key list"
  Assert-TextMatch -Text $voiceGateHelper -Pattern "transcript_bucket" -Message "voice-gate proof helper should bucket transcript length instead of printing text"
  Assert-TextMatch -Text $voiceGateHelper -Pattern "raw_response_shared" -Message "voice-gate proof helper should emit raw response safety status"
  Assert-TextMatch -Text $voiceGateWrapper -Pattern "source/static-command-preview" -Message "voice-gate wrapper should default to source/static preview"
  Assert-TextMatch -Text $voiceGateWrapper -Pattern "collect-local" -Message "voice-gate wrapper should support redacted collection from existing diagnostics"
  Assert-TextMatch -Text $voiceGateWrapper -Pattern "raw_transcript_shared=false" -Message "voice-gate wrapper should print raw_transcript_shared=false"
  Assert-TextMatch -Text $voiceGateWrapper -Pattern "raw_prompt_shared=false" -Message "voice-gate wrapper should print raw_prompt_shared=false"
  Assert-TextMatch -Text $voiceGateWrapper -Pattern "raw_response_shared=false" -Message "voice-gate wrapper should print raw_response_shared=false"
  Assert-TextMatch -Text $voiceGateWrapper -Pattern "no_media_playback=true" -Message "voice-gate wrapper should default to no media playback"
  Assert-TextMatch -Text $voiceGateWrapper -Pattern "no_stt_execution=true" -Message "voice-gate wrapper should default to no STT execution"
  Assert-TextMatch -Text $voiceGateWrapper -Pattern "no_virtual_audio_route_change=true" -Message "voice-gate wrapper should avoid changing audio routes"
  Write-Host "README first-run guidance static ok"
}

function Test-RouteAParentNoLiveUxStatic {
  Write-TestStep "Route A parent no-live UX static checks"

  $swordPath = Join-Path $RepoRoot "sword.ps1"
  Assert-PathPresent -Path $swordPath
  $sword = Get-Content -Raw -LiteralPath $swordPath
  Assert-TextMatch -Text $sword -Pattern 'ValidateSet\("status", "verify", "doctor", "start", "stop", "hold-live"\)' -Message "sword.ps1 should expose the approved front-door commands"
  Assert-TextMatch -Text $sword -Pattern "default_safety=no-live/no-device" -Message "sword.ps1 should advertise no-live/no-device default safety"
  Assert-TextMatch -Text $sword -Pattern "source-static-command-preview" -Message "sword.ps1 start/stop should default to command preview"
  Assert-TextMatch -Text $sword -Pattern 'live_home_assistant_actions_allowed = \$false' -Message "hold-live should not authorize Home Assistant actions"
  Assert-TextMatch -Text $sword -Pattern 'approval_bypass_allowed = \$false' -Message "hold-live should not create an approval bypass"

  $install = Get-Content -Raw -LiteralPath (Join-Path $RepoRoot "scripts\install-distribution.ps1")
  Assert-TextMatch -Text $install -Pattern "Dry run: planning only" -Message "install dry-run should say it is planning only"
  Assert-TextMatch -Text $install -Pattern "SWORD AGENT OS DRY RUN COMPLETE" -Message "install dry-run should not look like real readiness"
  Assert-TextMatch -Text $install -Pattern "no clone, env, dependency, or generated local file changes" -Message "install dry-run should spell out no-write scope"

  $readiness = Get-Content -Raw -LiteralPath (Join-Path $RepoRoot "scripts\check-launch-readiness.ps1")
  Assert-TextMatch -Text $readiness -Pattern "expected_for_no_live=true" -Message "readiness should mark mock adapter as expected no-live evidence"
  Assert-TextMatch -Text $readiness -Pattern "proof_layer=no-live/mock" -Message "readiness should expose the mock proof layer"

  $mediaPrep = Get-Content -Raw -LiteralPath (Join-Path $RepoRoot "scripts\prepare-local-media-index.ps1")
  Assert-TextMatch -Text $mediaPrep -Pattern "consumer_readiness_map" -Message "local media preparation should expose consumer readiness mapping"
  Assert-TextMatch -Text $mediaPrep -Pattern "intentionally_not_copied" -Message "local media preparation should list data it does not copy"
  Assert-TextMatch -Text $mediaPrep -Pattern "run-full-install-verification\.ps1" -Message "local media readiness map should point to full verification consumer"

  $compatSmoke = Get-Content -Raw -LiteralPath (Join-Path $RepoRoot "scripts\run-compat-smoke.ps1")
  Assert-TextMatch -Text $compatSmoke -Pattern "start_exit_code_class" -Message "compat smoke should classify start exit code mixed signals"
  Assert-TextMatch -Text $compatSmoke -Pattern "nonzero_after_route_success_explained" -Message "compat smoke should explain route-success/nonzero-exit mixed signals"

  Write-Host "Route A parent no-live UX static ok"
}

function Test-HomeControlTrackingHelperFixtures {
  Write-TestStep "Home Control tracking helper no-live fixtures"
  $output = Invoke-Checked -Command @(
    $PowerShellCommand,
    "-NoProfile",
    "-File",
    (Join-Path $RepoRoot "scripts\start-home-control-bridge.ps1"),
    "-SelfTestTracking"
  )
  $text = $output -join "`n"
  Assert-TextMatch -Text $text -Pattern "tracking_self_test: legacy_tracked=tracked" -Message "tracking helper should keep legacy /actions payload fallback"
  Assert-TextMatch -Text $text -Pattern "tracking_self_test: new_tracked=tracked" -Message "tracking helper should accept new tracked metadata"
  Assert-TextMatch -Text $text -Pattern "tracking_self_test: external_required=blocked" -Message "tracking helper should block external-required actions from HA state proof"
  Assert-TextMatch -Text $text -Pattern "tracking_self_test: ack_only=blocked" -Message "tracking helper should block ack-only actions from HA state proof"
  Assert-TextMatch -Text $text -Pattern "tracking_self_test: missing_action=blocked" -Message "tracking helper should preserve missing-action hard stop evidence"
  Assert-TextMatch -Text $text -Pattern "tracking self-test: ok" -Message "tracking helper no-live fixtures should complete"
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

function Test-DistributionPinCheckerFixtures {
  Write-TestStep "distribution pin checker fixture behavior"
  $root = New-FreshTestRoot
  try {
    $exactRepo = Join-Path $root "pin-exact-checkout"
    $exactHead = New-LocalGitRepository -Path $exactRepo
    $exactManifest = New-UpdateFixtureManifest -Root $root -TargetPath $exactRepo -Commit $exactHead -Id "pin-exact"
    $exactOutput = Invoke-Checked -Command @(
      $PowerShellCommand,
      "-NoProfile",
      "-File",
      (Join-Path $PSScriptRoot "check-distribution-pins.ps1"),
      "-DistributionManifestPath",
      $exactManifest,
      "-Strict",
      "-Json"
    )
    $exactJson = ($exactOutput -join "`n") | ConvertFrom-Json
    if ([string]$exactJson.status -ne "ok") {
      throw "exact pin fixture should pass strict check; got $($exactJson.status)"
    }

    $aheadRepo = Join-Path $root "pin-ahead-checkout"
    $aheadManifestHead = New-LocalGitRepository -Path $aheadRepo
    Set-Content -LiteralPath (Join-Path $aheadRepo "README.md") -Value "fixture repository ahead" -Encoding utf8
    Invoke-Checked -Command @("git", "-C", $aheadRepo, "add", "README.md") | Out-Null
    Invoke-Checked -Command @(
      "git",
      "-C",
      $aheadRepo,
      "-c",
      "user.name=Sword Agent OS Maintenance Test",
      "-c",
      "user.email=maintenance-test@example.invalid",
      "commit",
      "-q",
      "-m",
      "fixture ahead commit"
    ) | Out-Null
    $aheadCurrentHead = ((Invoke-Checked -Command @("git", "-C", $aheadRepo, "rev-parse", "HEAD") | Select-Object -First 1) -join "").Trim()
    if ($aheadCurrentHead -eq $aheadManifestHead) {
      throw "ahead fixture failed to create a newer checkout head"
    }
    $aheadManifest = New-UpdateFixtureManifest -Root $root -TargetPath $aheadRepo -Commit $aheadManifestHead -Id "pin-ahead"
    $aheadOutput = Invoke-Checked -Command @(
      $PowerShellCommand,
      "-NoProfile",
      "-File",
      (Join-Path $PSScriptRoot "check-distribution-pins.ps1"),
      "-DistributionManifestPath",
      $aheadManifest,
      "-Json"
    )
    $aheadJson = ($aheadOutput -join "`n") | ConvertFrom-Json
    if ([string]$aheadJson.status -ne "warning") {
      throw "ahead fixture should be warning in non-strict mode; got $($aheadJson.status)"
    }
    if ([string]$aheadJson.items[0].status -ne "ahead_of_manifest") {
      throw "ahead fixture did not report ahead_of_manifest"
    }
    $aheadStrictOutput = Invoke-ExpectFailure -Command @(
      $PowerShellCommand,
      "-NoProfile",
      "-File",
      (Join-Path $PSScriptRoot "check-distribution-pins.ps1"),
      "-DistributionManifestPath",
      $aheadManifest,
      "-Strict",
      "-Json"
    )
    Assert-TextMatch -Text ($aheadStrictOutput -join "`n") -Pattern "ahead_of_manifest" -Message "strict pin check should fail on ahead-of-manifest checkout"

    $behindRepo = Join-Path $root "pin-behind-checkout"
    $behindOldHead = New-LocalGitRepository -Path $behindRepo
    Set-Content -LiteralPath (Join-Path $behindRepo "README.md") -Value "fixture repository expected newer" -Encoding utf8
    Invoke-Checked -Command @("git", "-C", $behindRepo, "add", "README.md") | Out-Null
    Invoke-Checked -Command @(
      "git",
      "-C",
      $behindRepo,
      "-c",
      "user.name=Sword Agent OS Maintenance Test",
      "-c",
      "user.email=maintenance-test@example.invalid",
      "commit",
      "-q",
      "-m",
      "fixture expected commit"
    ) | Out-Null
    $behindExpectedHead = ((Invoke-Checked -Command @("git", "-C", $behindRepo, "rev-parse", "HEAD") | Select-Object -First 1) -join "").Trim()
    Invoke-Checked -Command @("git", "-C", $behindRepo, "checkout", "--detach", $behindOldHead) | Out-Null
    $behindManifest = New-UpdateFixtureManifest -Root $root -TargetPath $behindRepo -Commit $behindExpectedHead -Id "pin-behind"
    $behindOutput = Invoke-ExpectFailure -Command @(
      $PowerShellCommand,
      "-NoProfile",
      "-File",
      (Join-Path $PSScriptRoot "check-distribution-pins.ps1"),
      "-DistributionManifestPath",
      $behindManifest,
      "-Strict",
      "-Json"
    )
    Assert-TextMatch -Text ($behindOutput -join "`n") -Pattern "behind_manifest" -Message "strict pin check should fail on behind-manifest checkout"
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
    Assert-TextMatch -Text $installText -Pattern "SWORD AGENT OS DRY RUN COMPLETE" -Message "install dry-run should end with a dry-run completion banner"
    if ($installText -match "SWORD AGENT OS IS READY FOR FIRST LAUNCH") {
      throw "install dry-run should not claim first-launch readiness"
    }
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
Test-TestLayoutPolicy
Test-ReadmeFirstRunGuidance
Test-RouteAParentNoLiveUxStatic
Test-HomeControlTrackingHelperFixtures
Test-ManifestAndVersion
Test-UpdateFixtureHoldBehavior
Test-DistributionPinCheckerFixtures
Test-EnvRenderFixtures
Test-NativeLaunchLayoutFixtures
Test-DeveloperWorkspaceBootstrap
Test-InstalledWorkspaceMaintenance
Test-FreshCloneDryRun

Write-Host ""
Write-Host "maintenance smoke tests: ok" -ForegroundColor Green
