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
$FreshTestInvocationId = [guid]::NewGuid().ToString("N")
$OwnedFreshTestRoots = @{}
$FreshTestOwnerMarkerName = ".sword-agent-os-maintenance-owner.json"

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

function Assert-TextNotMatch {
  param(
    [Parameter(Mandatory = $true)][string]$Text,
    [Parameter(Mandatory = $true)][string]$Pattern,
    [Parameter(Mandatory = $true)][string]$Message
  )
  if ($Text -match $Pattern) {
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
    "scripts/bootstrap-control-plane.ps1",
    "scripts/bootstrap-organs.ps1",
    "scripts/bootstrap-workspace.ps1",
    "scripts/install-distribution.ps1",
    "scripts/update-distribution.ps1",
    "scripts/check-distribution-pins.ps1",
    "scripts/doctor-distribution.ps1",
    "scripts/render-env-files.ps1",
    "scripts/start-home-control-bridge.ps1",
    "scripts/inspect-home-control-switchbot-surfaces.ps1",
    "scripts/check-voicevox-readiness.ps1",
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

  foreach ($bootstrapPath in @(
      "scripts/bootstrap-control-plane.ps1",
      "scripts/bootstrap-organs.ps1"
    )) {
    $bootstrapContent = Get-Content -Raw -LiteralPath (Join-Path $RepoRoot $bootstrapPath)
    Assert-TextMatch `
      -Text $bootstrapContent `
      -Pattern '(?s)"clone",\s*"--config",\s*"core\.longpaths=true",\s*"--branch"' `
      -Message "$bootstrapPath must keep long-path support repo-local during clone"
  }

  $serviceManifest = Get-Content -Raw -LiteralPath (Join-Path $RepoRoot "manifests\services\standard.json") | ConvertFrom-Json
  $defaultLauncherPort = [int]$serviceManifest.port_modes.manifest_default.auxiliary_ports.home_control_launcher
  $isolatedLauncherPort = [int]$serviceManifest.port_modes.isolated_override.auxiliary_ports.home_control_launcher
  if ($defaultLauncherPort -lt 1 -or $defaultLauncherPort -gt 65535) {
    throw "default launcher port should be manifest-owned"
  }
  if ($isolatedLauncherPort -lt 1 -or $isolatedLauncherPort -gt 65535) {
    throw "isolated launcher port should be manifest-owned"
  }
  if ($defaultLauncherPort -eq $isolatedLauncherPort) {
    throw "isolated launcher port should differ from the default launcher port"
  }

  $swordFrontDoor = Get-Content -Raw -LiteralPath (Join-Path $RepoRoot "sword.ps1")
  Assert-TextMatch -Text $swordFrontDoor -Pattern "Resolve-LauncherPort" -Message "sword front door should resolve launcher ports from the service manifest"
  Assert-TextMatch -Text $swordFrontDoor -Pattern 'start-launcher\.ps1" -Arguments @\("-Port"' -Message "sword start should pass the selected launcher port"
  Assert-TextMatch -Text $swordFrontDoor -Pattern '\$stopArgs = @\("-Port"' -Message "sword stop should pass the same selected launcher port"

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
    "control-plane\core",
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
  $layoutExceptions = @(
    "organs\speech-input\ai-talk-core\smoke_test.py"
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
    if ($layoutExceptions -contains $relativePath) {
      $warnings += "test-layout exception: $relativePath"
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
    "docs\capability-packs.md",
    "docs\architecture.md",
    "docs\standard-distribution-map.md",
    "docs\verification-commands.md",
    "docs\troubleshooting.md",
    "docs\reference-surfaces.md",
    "docs\add-home-device.md",
    "docs\proof-layers.md",
    "manifests\README.md",
    "docs\local-configuration.md",
    "docs\home-assistant-setup.md",
    "docs\home-control-action-authoring.md",
    "docs\live-home-control-proof.md",
    "docs\live-home-control-cause-trail.md",
    "runtime\control\README.md"
  )
  $frontDoorSurface = $readme
  foreach ($docPath in $frontDoorDocs) {
    $absoluteDocPath = Join-Path $RepoRoot $docPath
    Assert-PathPresent -Path $absoluteDocPath
    $frontDoorSurface = "$frontDoorSurface`n$(Get-Content -Raw -LiteralPath $absoluteDocPath)"
  }
  Assert-TextMatch -Text $frontDoorSurface -Pattern "prepared local|準備済みローカル" -Message "front-door docs should describe prepared local inputs without requiring private folder names"
  Assert-TextMatch -Text $frontDoorSurface -Pattern "_secret_inputs.*product convention|製品として特定のフォルダ名を要求しません" -Message "front-door docs should not make _secret_inputs look like a required product convention"
  Assert-TextMatch -Text $frontDoorSurface -Pattern "First Success" -Message "front-door docs should include the first-success path"
  Assert-TextMatch -Text $frontDoorSurface -Pattern "render-env-files\.ps1 -Profile standard -Force" -Message "front-door docs should show central env re-render after editing local env"
  Assert-TextMatch -Text $frontDoorSurface -Pattern "runtime/browser|実マイク|実カメラ|live Home Assistant|物理家電" -Message "front-door docs should separate no-live install/readiness from runtime/browser/live proof"
  Assert-TextMatch -Text $frontDoorSurface -Pattern "Representative Standard Loop|標準構成.*流れ" -Message "front-door docs should explain the standard distribution flow"
  Assert-TextMatch -Text $frontDoorSurface -Pattern "Sword sign|gesture-to-voice gate" -Message "front-door docs should explain the sword-sign input gate"
  Assert-TextMatch -Text $frontDoorSurface -Pattern "start-home-control-bridge\.ps1" -Message "front-door docs should document the Home Control bridge live helper"
  Assert-TextMatch -Text $frontDoorSurface -Pattern "health_config_error" -Message "front-door docs should define live Home Control health config-error behavior"
  Assert-TextMatch -Text $frontDoorSurface -Pattern "actions_unavailable" -Message "front-door docs should define live Home Control action-unavailable safe stop behavior"
  Assert-TextMatch -Text $frontDoorSurface -Pattern "preview\s*/\s*dry-run\s*/\s*execute|preview, dry-run, execute" -Message "front-door docs should require preview before live execute"
  Assert-TextMatch -Text $frontDoorSurface -Pattern "Use this ladder|exact live route|Live Home Control proof" -Message "front-door docs should provide a canonical live proof ladder without requiring OpenAPI discovery"
  Assert-TextMatch -Text $frontDoorSurface -Pattern "-Force[\s\S]{0,260}home-control\.yaml|home-control\.yaml[\s\S]{0,260}-Force" -Message "front-door docs should warn that render-env-files -Force regenerates home-control.yaml"
  Assert-TextMatch -Text $frontDoorSurface -Pattern "/actions/<allowed-action-id>/preview" -Message "front-door docs should show a concrete preview route shape"
  Assert-TextMatch -Text $frontDoorSurface -Pattern "dry-run execute only when the route shape explicitly includes it" -Message "front-door docs should constrain dry-run execute behavior"
  Assert-TextMatch -Text $frontDoorSurface -Pattern "-CheckTracking -ActionId" -Message "front-door docs should show helper-based state-tracking metadata check before execute"
  Assert-TextMatch -Text $frontDoorSurface -Pattern "-CheckState -ActionId" -Message "front-door docs should show helper-based Home Assistant state check"
  Assert-TextMatch -Text $frontDoorSurface -Pattern "live_test_readiness" -Message "front-door docs should document Home Control live-test readiness metadata"
  Assert-TextMatch -Text $frontDoorSurface -Pattern "restore_action_id" -Message "front-door docs should document Home Control restore action metadata"
  Assert-TextMatch -Text $frontDoorSurface -Pattern "proof_ceiling" -Message "front-door docs should document Home Control proof ceiling metadata"
  Assert-TextMatch -Text $frontDoorSurface -Pattern "post-action" -Message "front-door docs should separate CheckState from pre-execution checks"
  Assert-TextMatch -Text $frontDoorSurface -Pattern "live-home-control-cause-trail\.md" -Message "front-door docs should link live Home Control cause trail"
  Assert-PathPresent -Path (Join-Path $RepoRoot "docs\live-home-control-cause-trail.md")
  $bridgeHelper = Get-Content -Raw -LiteralPath (Join-Path $RepoRoot "scripts\start-home-control-bridge.ps1")
  Assert-TextMatch -Text $bridgeHelper -Pattern "--env-file" -Message "Home Control bridge helper should pass generated .env through uv"
  Assert-TextMatch -Text $bridgeHelper -Pattern "config_error_kind" -Message "Home Control bridge helper should report redacted config error kind"
  Assert-TextMatch -Text $bridgeHelper -Pattern "cause_code" -Message "Home Control bridge helper should report cause codes"
  Assert-TextMatch -Text $bridgeHelper -Pattern "root_cause_trace" -Message "Home Control bridge helper should emit root-cause trace packet"
  Assert-TextMatch -Text $bridgeHelper -Pattern "HOME_ASSISTANT_TOKEN" -Message "Home Control bridge helper should classify Home Assistant token readiness"
  Assert-TextMatch -Text $bridgeHelper -Pattern "CheckTracking" -Message "Home Control bridge helper should provide a redacted state-tracking metadata mode"
  Assert-TextMatch -Text $bridgeHelper -Pattern "live_test_readiness" -Message "Home Control bridge helper should report live-test readiness"
  Assert-TextMatch -Text $bridgeHelper -Pattern "live_test_blockers" -Message "Home Control bridge helper should report live-test blocker classes"
  Assert-TextMatch -Text $bridgeHelper -Pattern "restore_action" -Message "Home Control bridge helper should report restore action classes"
  Assert-TextNotMatch -Text $bridgeHelper -Pattern "safety_requirement:" -Message "Home Control bridge helper should not turn legacy appliance requirements into blockers"
  Assert-TextMatch -Text $bridgeHelper -Pattern "CheckState" -Message "Home Control bridge helper should provide a redacted state-check mode"
  Assert-TextMatch -Text $bridgeHelper -Pattern "bridge_start: status=starting" -Message "Home Control bridge helper should print startup status"
  Assert-TextMatch -Text $bridgeHelper -Pattern "UV_CACHE_DIR" -Message "Home Control bridge helper should use a local uv cache without changing persistent environment"
  Assert-TextMatch -Text $bridgeHelper -Pattern "UvCacheDir" -Message "Home Control bridge helper should expose a scoped uv cache override"
  Assert-TextMatch -Text $bridgeHelper -Pattern "Test-HoldLiveMarker" -Message "Home Control bridge helper should read the HOLD_LIVE marker"
  Assert-TextMatch -Text $bridgeHelper -Pattern "runtime_control\.hold_live_active" -Message "Home Control bridge helper should classify active HOLD_LIVE as a runtime-control blocker"
  Assert-TextMatch -Text $bridgeHelper -Pattern "Assert-HoldLiveAllowsBridgeStart" -Message "Home Control bridge helper should gate bridge start on HOLD_LIVE"
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
  Assert-TextMatch -Text $frontDoorSurface -Pattern "doctor-distribution\.ps1" -Message "front-door docs should document the distribution doctor"
  Assert-TextMatch -Text $frontDoorSurface -Pattern "check-distribution-pins\.ps1" -Message "front-door docs should document the distribution pin checker"
  Assert-TextMatch -Text $frontDoorSurface -Pattern "ahead_of_manifest|正式採用待ち|parent adoption" -Message "front-door docs should explain ahead-of-manifest pin state"
  Assert-TextMatch -Text $frontDoorSurface -Pattern "local_artifact_hold_at_manifest_pin" -Message "front-door docs should explain local artifact hold pin state"
  Assert-TextMatch -Text $frontDoorSurface -Pattern "git_unreadable[\s\S]{0,240}pin mismatch" -Message "front-door docs should separate git_unreadable from true pin mismatch"
  Assert-TextMatch -Text $frontDoorSurface -Pattern "port-conflict|isolated_override" -Message "public troubleshooting docs should explain port-conflict handling"
  Assert-TextMatch -Text $troubleshootingSurface -Pattern 'existing `sword-agent-os` directory' -Message "public troubleshooting docs should explain existing clone directory handling"
  Assert-TextMatch -Text $troubleshootingSurface -Pattern "network permission" -Message "public troubleshooting docs should classify restricted environment network reruns"
  Assert-TextMatch -Text $frontDoorSurface -Pattern "foreground" -Message "front-door docs should explain Home Control bridge foreground behavior"
  Assert-TextMatch -Text $frontDoorSurface -Pattern "accepted/submitted|command submitted|submitted_only" -Message "front-door docs should explain submitted execute status"
  Assert-TextMatch -Text $frontDoorSurface -Pattern "install/readiness pass" -Message "front-door docs should separate first-run report proof layers"
  Assert-TextMatch -Text $frontDoorSurface -Pattern "gesture-to-voice gate" -Message "front-door docs should separate gesture-to-voice gate proof"
  Assert-TextMatch -Text $troubleshootingSurface -Pattern "npm audit" -Message "public troubleshooting docs should include npm audit interpretation guidance"
  Assert-TextMatch -Text $frontDoorSurface -Pattern "run-local-media-replay\.ps1" -Message "front-door docs should document the local media replay preview helper"
  Assert-TextMatch -Text $frontDoorSurface -Pattern "room-light evidence|room-light lanes|room-light on/off" -Message "front-door docs should document room-light evidence"
  Assert-TextMatch -Text $frontDoorSurface -Pattern "check-voicevox-readiness\.ps1" -Message "front-door docs should document the VOICEVOX readiness helper"
  Assert-TextMatch -Text $frontDoorSurface -Pattern "forced render[\s\S]{0,180}restart|restart[\s\S]{0,180}env/config" -Message "front-door docs should explain restart after forced env/config render"
  Assert-TextMatch -Text $frontDoorSurface -Pattern "run-full-install-verification\.ps1" -Message "front-door docs should document the full install verification helper"
  Assert-TextMatch -Text $frontDoorSurface -Pattern "demo-safe light command stimulus[\s\S]{0,220}light_on|light_on[\s\S]{0,220}command submission" -Message "front-door docs should describe light_on as command-submission-only demo-safe stimulus"
  Assert-TextMatch -Text $readme -Pattern "front-door:system-at-a-glance" -Message "README should anchor the system-at-a-glance overview"
  Assert-TextMatch -Text $readme -Pattern "## 何のシステムか" -Message "README should explain what the system is before setup steps"
  $readmeProjectionVisualImagePath = Join-Path $RepoRoot "docs\assets\readme\projection-visual-example-1.png"
  Assert-PathPresent -Path $readmeProjectionVisualImagePath
  Assert-TextMatch -Text $readme -Pattern "docs/assets/readme/projection-visual-example-1\.png" -Message "README overview should show the Projection Visual screenshot before setup steps"
  Assert-TextMatch -Text $readme -Pattern "中央のアバター[\s\S]{0,120}状態HUD[\s\S]{0,120}入力欄" -Message "README overview should explain the visible avatar, HUD, and input surface"
  Assert-TextMatch -Text $readme -Pattern "声、身振り、UI入力[\s\S]{0,240}Thought Core / control-plane[\s\S]{0,240}Home Control / Home Assistant" -Message "README overview should show input, thought, and Home Control flow"
  Assert-TextMatch -Text $readme -Pattern "Expression organ[\s\S]{0,160}アバター[\s\S]{0,120}Projection Visual[\s\S]{0,120}TTS[\s\S]{0,220}proof layer" -Message "README overview should show expression and proof layers"
  Assert-TextMatch -Text $readme -Pattern "front-door:thin-entry-rule" -Message "README should anchor the front-door thinning rule"
  Assert-TextMatch -Text $readme -Pattern "入口を薄く保つ基準" -Message "README should define the front-door thinning criteria"
  Assert-TextMatch -Text $readme -Pattern "残すもの[\s\S]{0,220}専門文書へ移すもの[\s\S]{0,220}削除、または履歴へ送るもの" -Message "README should distinguish keep, move, and archive/delete criteria"
  Assert-TextMatch -Text $frontDoorSurface -Pattern "architecture:front-door-thinning-rule" -Message "architecture docs should anchor the front-door thinning rule"
  Assert-TextMatch -Text $frontDoorSurface -Pattern "Delete or archive only after the ownership is clear" -Message "architecture docs should prevent arbitrary entrypoint deletion"
  Assert-TextMatch -Text $verificationSurface -Pattern "docs/live-home-control-proof\.md" -Message "public verification docs should point live proof recipes to the canonical Home Control proof doc"
  Assert-TextMatch -Text $troubleshootingSurface -Pattern "demo-safe light command stimulus[\s\S]{0,260}light_on[\s\S]{0,260}command submission|light_on[\s\S]{0,260}HA state proof" -Message "troubleshooting should keep light_on as command-submission-only, not HA-state proof"
  $demoSafeSettings = Get-Content -Raw -LiteralPath (Join-Path $RepoRoot "manifests\demo-safe-settings\defaults.json")
  $driverManifest = Get-Content -Raw -LiteralPath (Join-Path $RepoRoot "manifests\drivers\standard.json")
  $diagnosticTestPlan = Get-Content -Raw -LiteralPath (Join-Path $RepoRoot "runtime\diagnostic-scheduler\neural-monitoring-test-plan.v0.md")
  Assert-TextMatch -Text $demoSafeSettings -Pattern '"id"\s*:\s*"appliance\.light_command_stimulus"[\s\S]{0,700}"light_on"' -Message "demo-safe light stimulus should use the canonical explicit light_on action id"
  Assert-TextNotMatch -Text $demoSafeSettings -Pattern '"id"\s*:\s*"appliance\.light_command_stimulus"[\s\S]{0,700}"light_toggle"' -Message "demo-safe light stimulus should not keep the legacy light_toggle action id"
  Assert-TextMatch -Text $driverManifest -Pattern "toggle-only light stays external-observation-required" -Message "driver manifest should keep toggle-only light out of reversible-action examples"
  Assert-TextNotMatch -Text $driverManifest -Pattern "light_on then light_off" -Message "driver manifest should not promote light_on/light_off as reversible proof"
  Assert-TextMatch -Text $diagnosticTestPlan -Pattern "toggle-only light requires separate external observation" -Message "diagnostic plan should keep toggle-only light as external-observation-required"
  Assert-TextNotMatch -Text $diagnosticTestPlan -Pattern "Real light on/off" -Message "diagnostic plan should not claim real light on/off as the default deep check"
  Assert-PathAbsent -Path (Join-Path $RepoRoot "scripts\run-home-control-light-proof.ps1")
  Assert-TextMatch -Text $verificationSurface -Pattern "inspect-home-control-switchbot-surfaces\.ps1" -Message "public verification docs should document the SwitchBot read-only surface helper"
  Assert-PathPresent -Path (Join-Path $RepoRoot "scripts\inspect-home-control-switchbot-surfaces.ps1")
  Assert-PathPresent -Path (Join-Path $RepoRoot "scripts\measure-camera-brightness.py")
  $switchBotInspectHelper = Get-Content -Raw -LiteralPath (Join-Path $RepoRoot "scripts\inspect-home-control-switchbot-surfaces.ps1")
  $cameraBrightnessHelper = Get-Content -Raw -LiteralPath (Join-Path $RepoRoot "scripts\measure-camera-brightness.py")
  Assert-TextMatch -Text $switchBotInspectHelper -Pattern 'ha_service_call = "no"' -Message "SwitchBot read-only helper should not perform HA service calls"
  Assert-TextMatch -Text $switchBotInspectHelper -Pattern "live_test_readiness" -Message "SwitchBot read-only helper should report live-test readiness"
  Assert-TextNotMatch -Text $switchBotInspectHelper -Pattern "safety_requirement:" -Message "SwitchBot read-only helper should not report legacy appliance requirement blockers"
  Assert-TextMatch -Text $cameraBrightnessHelper -Pattern "raw_media_saved" -Message "camera brightness helper should report raw media is not saved"
  Assert-TextMatch -Text $cameraBrightnessHelper -Pattern "cv2\.VideoCapture" -Message "camera brightness helper should use OpenCV without writing frames"
  Assert-TextMatch -Text $verificationSurface -Pattern "default_safety=no-live/no-device" -Message "public verification docs should state the full verification helper default safety"
  Assert-TextMatch -Text $frontDoorSurface -Pattern "RequestLiveHomeAssistant[\s\S]{0,320}AllowedActionId|AllowedActionId[\s\S]{0,320}RequestLiveHomeAssistant" -Message "front-door docs should require explicit live HA request and action id"
  Assert-TextMatch -Text $frontDoorSurface -Pattern "local-media replay" -Message "front-door docs should name local-media replay as a separate proof layer"
  Assert-TextMatch -Text $frontDoorSurface -Pattern "gesture\.sword\.20260603" -Message "front-door docs should show the sword-sign positive local media asset id"
  Assert-TextMatch -Text $frontDoorSurface -Pattern "vision\.room_light\.on\.20260603" -Message "front-door docs should show the room-light local media asset id"
  Assert-TextMatch -Text $readme -Pattern "Safety Default" -Message "README should anchor the no-live front-door default"
  Assert-TextMatch -Text $readme -Pattern "\.\\sword\.ps1 status\s+\.\\sword\.ps1 verify\s+\.\\sword\.ps1 doctor" -Message "README front-door commands should use short default no-live forms"
  Assert-TextMatch -Text $frontDoorSurface -Pattern "sword\.ps1" -Message "front-door docs should document the root sword.ps1 wrapper"
  Assert-TextMatch -Text $frontDoorSurface -Pattern "まず安全に見る" -Message "operator docs should be organized by user intent"
  Assert-TextMatch -Text $frontDoorSurface -Pattern "operate:no-live-default" -Message "operator docs should anchor status/verify/doctor no-live defaults"
  Assert-TextMatch -Text $frontDoorSurface -Pattern "Customize Sword Agent OS" -Message "front-door docs should include a customization map"
  Assert-TextMatch -Text $frontDoorSurface -Pattern "やりたいこと" -Message "customization docs should let users start from their goal"
  Assert-TextMatch -Text $frontDoorSurface -Pattern "architecture:structure-spine" -Message "front-door docs should include the architecture structure spine"
  Assert-TextMatch -Text $frontDoorSurface -Pattern "Front Door[\s\S]{0,180}Configuration[\s\S]{0,180}Runtime Control[\s\S]{0,180}Proof" -Message "architecture docs should separate the major structure planes"
  Assert-TextMatch -Text $frontDoorSurface -Pattern "architecture:definition-table" -Message "architecture docs should anchor the definition table"
  Assert-TextMatch -Text $frontDoorSurface -Pattern "first[\s\S]{0,40}operator needs it before choosing a specialist document" -Message "architecture docs should define what remains in the front door"
  Assert-TextMatch -Text $frontDoorSurface -Pattern "architecture:review-thread-use" -Message "architecture docs should tell review threads how to use the structure spine"
  Assert-TextMatch -Text $frontDoorSurface -Pattern "front-door:intent-customize-llm" -Message "customization docs should anchor the LLM customization intent"
  Assert-TextMatch -Text $frontDoorSurface -Pattern "front-door:intent-home-action" -Message "customization docs should anchor the Home Assistant action intent"
  Assert-TextMatch -Text $frontDoorSurface -Pattern "front-door:intent-live-proof" -Message "customization docs should anchor the live proof intent"
  Assert-TextMatch -Text $frontDoorSurface -Pattern "front-door:intent-proof-layer" -Message "customization docs should anchor the proof-layer intent"
  Assert-TextMatch -Text $frontDoorSurface -Pattern "capability-packs:overview" -Message "front-door docs should include the capability pack overview"
  Assert-TextMatch -Text $frontDoorSurface -Pattern "capability-packs:choose-your-path" -Message "capability pack docs should anchor the choose-your-path table"
  Assert-TextMatch -Text $frontDoorSurface -Pattern "capability-packs:starter-profile-plan" -Message "capability pack docs should anchor starter profile planning"
  Assert-TextMatch -Text $frontDoorSurface -Pattern "examples/starter-profiles/_template\.md" -Message "capability/architecture docs should point starter profiles to the template"
  Assert-TextMatch -Text $frontDoorSurface -Pattern "Goal,\s+Safe\s+Route,\s+Report Shape,\s+Stop\s+Conditions,\s+and Next Paths" -Message "front-door docs should preserve the compact starter profile section set"
  Assert-TextMatch -Text $frontDoorSurface -Pattern "read-only/helper readiness[\s\S]{0,140}Home Assistant preview endpoint proof|Home Assistant preview endpoint proof[\s\S]{0,140}read-only/helper readiness" -Message "front-door docs should separate readiness preview wording from HA preview endpoint proof"
  Assert-TextMatch -Text $frontDoorSurface -Pattern "reference-surfaces:overview" -Message "front-door docs should include reference surface guidance"
  Assert-TextMatch -Text $frontDoorSurface -Pattern "reference-surfaces:add-new-reference" -Message "reference surface docs should anchor the add-new-reference procedure"
  Assert-TextMatch -Text $frontDoorSurface -Pattern "contract_ref" -Message "reference surface docs should require contract_ref for reader surfaces"
  Assert-TextMatch -Text $frontDoorSurface -Pattern "Thought Core[\s\S]{0,180}contracted reference surfaces" -Message "reference surface docs should explain Thought Core consumption"
  Assert-TextMatch -Text $frontDoorSurface -Pattern "新しい参照値|reference surface" -Message "front-door docs should expose reference surfaces as a developer route"
  Assert-TextMatch -Text $frontDoorSurface -Pattern "Core Body Pack" -Message "capability pack docs should name the core body pack"
  Assert-TextMatch -Text $frontDoorSurface -Pattern "Home Control Pack" -Message "capability pack docs should name the Home Control pack"
  Assert-TextMatch -Text $frontDoorSurface -Pattern "Agent Worker Pack" -Message "capability pack docs should keep future agent worker work separate"
  Assert-TextMatch -Text $frontDoorSurface -Pattern "add-home-device:overview" -Message "Home device guide should anchor its overview"
  Assert-TextMatch -Text $frontDoorSurface -Pattern "add-home-device:safe-order" -Message "Home device guide should define a safe order"
  Assert-TextMatch -Text $frontDoorSurface -Pattern "add-home-device:full-schema-checklist" -Message "Home device guide should include a full-schema checklist"
  Assert-TextMatch -Text $frontDoorSurface -Pattern "add-home-device:proof-ladder" -Message "Home device guide should keep proof layers separate"
  Assert-TextMatch -Text $frontDoorSurface -Pattern "no-live-display" -Message "capability pack docs should plan a no-live starter profile"
  Assert-TextMatch -Text $frontDoorSurface -Pattern "examples/starter-profiles/voice-avatar/README\.md" -Message "front-door docs should link the voice/avatar starter profile"
  Assert-TextMatch -Text $frontDoorSurface -Pattern "examples/starter-profiles/projection-visual/README\.md" -Message "front-door docs should link the Projection Visual starter profile"
  Assert-TextMatch -Text $frontDoorSurface -Pattern "self-mirror-consumer-routes\.json" -Message "front-door docs should link the Self Mirror consumer route map"
  Assert-TextMatch -Text $frontDoorSurface -Pattern "home-control-preview" -Message "capability pack docs should plan a Home Control preview starter profile"
  Assert-TextMatch -Text $frontDoorSurface -Pattern "examples/starter-profiles/home-control-preview/README\.md" -Message "front-door docs should link the Home Control preview starter profile"
  Assert-TextMatch -Text $frontDoorSurface -Pattern "architecture:capability-pack-layer" -Message "architecture docs should anchor the capability-pack layer"
  Assert-TextMatch -Text $frontDoorSurface -Pattern "starter profiles answer" -Message "architecture docs should distinguish starter profiles from planes and proof layers"
  Assert-TextMatch -Text $frontDoorSurface -Pattern "runtime/control/README\.md|runtime\\control\\README\.md" -Message "front-door docs should link runtime control vocabulary"
  Assert-TextMatch -Text $frontDoorSurface -Pattern "HOLD_LIVE[\s\S]{0,240}STOP[\s\S]{0,240}PAUSE[\s\S]{0,240}REQUIRE_APPROVAL" -Message "runtime control docs should define the core control vocabulary"
  Assert-TextMatch -Text $frontDoorSurface -Pattern "\.cache\\agent-os\\control\\hold-live\.json" -Message "runtime control docs should name the local hold-live marker"
  Assert-TextMatch -Text $frontDoorSurface -Pattern "runtime-control:hold-live-enforcement-boundary" -Message "runtime control docs should anchor hold-live enforcement boundary"
  Assert-TextMatch -Text $frontDoorSurface -Pattern "runtime-control:hold-live-clear-policy" -Message "runtime control docs should anchor hold-live clearing policy"
  Assert-TextMatch -Text $frontDoorSurface -Pattern "start-home-control-bridge\.ps1[\s\S]{0,180}blocks bridge start|blocks bridge start[\s\S]{0,180}start-home-control-bridge\.ps1" -Message "runtime control docs should name the first hold-live reader"
  Assert-TextMatch -Text $frontDoorSurface -Pattern "Action Boundary[\s\S]{0,160}Home Control bridge[\s\S]{0,160}Launch\s+Manager|Launch\s+Manager[\s\S]{0,160}Home Control bridge[\s\S]{0,160}Action Boundary" -Message "runtime control docs should name intended hold-live reader surfaces"
  Assert-TextMatch -Text $frontDoorSurface -Pattern "full-schema private/live config|reviewed clone-local equivalent" -Message "customization docs should explain full-schema Home Assistant config requirements"
  Assert-TextMatch -Text $frontDoorSurface -Pattern "release-ready|release readiness" -Message "front-door docs should keep scoped fresh-install evidence separate from release readiness"
  Assert-TextMatch -Text $frontDoorSurface -Pattern "source/static" -Message "proof-layer docs should name source/static proof"
  Assert-TextMatch -Text $frontDoorSurface -Pattern "runtime/status" -Message "proof-layer docs should name runtime/status proof"
  Assert-TextMatch -Text $frontDoorSurface -Pattern "physical/device proof" -Message "proof-layer docs should name physical/device proof"
  Assert-TextMatch -Text $frontDoorSurface -Pattern "manifests/README\.md|manifests\\README\.md" -Message "front-door docs should link the manifest authority page"
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
  Assert-TextMatch -Text $frontDoorSurface -Pattern "Home Assistant state match into physical proof|CheckState[\s\S]{0,160}not physical proof|HA-visible proof is not physical proof" -Message "front-door docs should prevent promoting HA-visible CheckState to physical proof"
  $standardDistributionMap = Get-Content -Raw -LiteralPath (Join-Path $RepoRoot "docs\standard-distribution-map.md")
  Assert-TextMatch -Text $standardDistributionMap -Pattern "\.\\sword\.ps1 status[\s\S]{0,120}\.\\sword\.ps1 verify" -Message "standard distribution map should start first success with sword.ps1 front-door checks"
  Assert-TextMatch -Text $standardDistributionMap -Pattern "sword\.ps1.*front-door.*scripts.*detailed tools|scripts.*detailed tools.*sword\.ps1.*front-door" -Message "standard distribution map should explain front-door vs detailed script roles"
  Assert-TextMatch -Text $standardDistributionMap -Pattern "standard-map:verify-overlap" -Message "standard distribution map should anchor why verify overlaps detailed scripts"
  Assert-TextMatch -Text $standardDistributionMap -Pattern "manifest validation[\s\S]{0,160}strict pin check[\s\S]{0,160}launch" -Message "standard distribution map should explain what sword.ps1 verify already covers"
  Assert-TextMatch -Text $standardDistributionMap -Pattern "docs/home-assistant-setup\.md" -Message "standard distribution map should point external HA setup to the setup guide"
  Assert-TextMatch -Text $standardDistributionMap -Pattern "docs/capability-packs\.md" -Message "standard distribution map should point feature selection to capability packs"
  Assert-TextMatch -Text $standardDistributionMap -Pattern "docs/reference-surfaces\.md" -Message "standard distribution map should point system-readable values to reference surfaces"
  Assert-TextMatch -Text $standardDistributionMap -Pattern "docs/add-home-device\.md" -Message "standard distribution map should point home-device additions to the beginner guide"
  Assert-TextMatch -Text $standardDistributionMap -Pattern "examples/starter-profiles/voice-avatar/README\.md" -Message "standard distribution map should point voice/avatar no-live setup to the voice/avatar starter"
  Assert-TextMatch -Text $standardDistributionMap -Pattern "examples/starter-profiles/projection-visual/README\.md" -Message "standard distribution map should point avatar visible-motion setup to the Projection Visual starter"
  Assert-TextMatch -Text $standardDistributionMap -Pattern "examples/starter-profiles/home-control-preview/README\.md" -Message "standard distribution map should point HA no-live setup to the Home Control preview starter"
  Assert-TextMatch -Text $standardDistributionMap -Pattern "HOME_CONTROL_CONFIG[\s\S]{0,200}private full-schema|private full-schema[\s\S]{0,200}HOME_CONTROL_CONFIG" -Message "standard distribution map should require proof-ready selected config before live HA"
  $starterTemplate = Get-Content -Raw -LiteralPath (Join-Path $RepoRoot "examples\starter-profiles\_template.md")
  Assert-TextMatch -Text $starterTemplate -Pattern "starter-profile:template" -Message "starter profile template should have a stable anchor"
  Assert-TextMatch -Text $starterTemplate -Pattern "starter-profile:template-goal[\s\S]+starter-profile:template-safe-route[\s\S]+starter-profile:template-report-shape[\s\S]+starter-profile:template-stop-conditions[\s\S]+starter-profile:template-next-paths" -Message "starter profile template should preserve compact section anchors and order"
  Assert-TextMatch -Text $starterTemplate -Pattern "not a proof claim[\s\S]{0,120}not live authorization[\s\S]{0,160}not automatically a new.*front-door" -Message "starter profile template should prevent proof/live/front-door upgrades"
  Assert-TextMatch -Text $starterTemplate -Pattern "read-only readiness[\s\S]{0,180}not Home Assistant preview endpoint proof" -Message "starter profile template should guard preview terminology"
  $noLiveStarter = Get-Content -Raw -LiteralPath (Join-Path $RepoRoot "examples\starter-profiles\no-live-display\README.md")
  Assert-TextMatch -Text $noLiveStarter -Pattern "starter-profile:no-live-display" -Message "no-live starter profile should have a stable anchor"
  Assert-TextMatch -Text $noLiveStarter -Pattern "\.\\sword\.ps1 status[\s\S]{0,120}\.\\sword\.ps1 verify[\s\S]{0,120}\.\\sword\.ps1 start" -Message "no-live starter profile should use the safe front-door route"
  $voiceAvatarStarter = Get-Content -Raw -LiteralPath (Join-Path $RepoRoot "examples\starter-profiles\voice-avatar\README.md")
  Assert-TextMatch -Text $voiceAvatarStarter -Pattern "starter-profile:voice-avatar" -Message "voice/avatar starter profile should have a stable anchor"
  Assert-TextMatch -Text $voiceAvatarStarter -Pattern "starter-profile:voice-avatar-goal[\s\S]+starter-profile:voice-avatar-route[\s\S]+starter-profile:voice-avatar-result-fields[\s\S]+starter-profile:voice-avatar-stop-conditions[\s\S]+starter-profile:voice-avatar-does-not-prove" -Message "voice/avatar starter should follow the template section anchors"
  Assert-TextMatch -Text $voiceAvatarStarter -Pattern "source/docs/no-live readiness" -Message "voice/avatar starter should name its source/docs/no-live proof ceiling"
  Assert-TextMatch -Text $voiceAvatarStarter -Pattern "provider/TTS readiness[\s\S]{0,120}audio playback[\s\S]{0,160}avatar\s+rendering|audio playback[\s\S]{0,160}avatar\s+rendering[\s\S]{0,160}provider/TTS readiness" -Message "voice/avatar starter should separate provider/TTS, audio playback, and avatar rendering"
  Assert-TextMatch -Text $voiceAvatarStarter -Pattern "check-voicevox-readiness\.ps1[\s\S]{0,220}does\s+not play audio[\s\S]{0,140}install or update VOICEVOX" -Message "voice/avatar starter should keep VOICEVOX readiness separate from playback/install"
  Assert-TextMatch -Text $voiceAvatarStarter -Pattern "start-prepared-sample-browser-stt-operator\.ps1[\s\S]{0,180}source-static operator preflight" -Message "voice/avatar starter should keep prepared-sample operator preflight at the source-static layer"
  Assert-TextMatch -Text $voiceAvatarStarter -Pattern "raw prompts[\s\S]{0,160}provider payloads[\s\S]{0,160}audio/media[\s\S]{0,160}screenshots[\s\S]{0,160}transcripts" -Message "voice/avatar starter should preserve raw/private/media boundaries"
  Assert-TextMatch -Text $voiceAvatarStarter -Pattern "real microphone or camera input[\s\S]{0,160}browser runtime reachability[\s\S]{0,160}rendered avatar visibility[\s\S]{0,160}avatar motion dispatch" -Message "voice/avatar starter should avoid overclaiming runtime/input/avatar proof"
  $projectionVisualStarter = Get-Content -Raw -LiteralPath (Join-Path $RepoRoot "examples\starter-profiles\projection-visual\README.md")
  Assert-TextMatch -Text $projectionVisualStarter -Pattern "starter-profile:projection-visual" -Message "Projection Visual starter profile should have a stable anchor"
  Assert-TextMatch -Text $projectionVisualStarter -Pattern "starter-profile:projection-visual-goal[\s\S]+starter-profile:projection-visual-route[\s\S]+starter-profile:projection-visual-report-shape[\s\S]+starter-profile:projection-visual-stop-conditions[\s\S]+starter-profile:projection-visual-next-paths" -Message "Projection Visual starter should follow compact section anchors"
  Assert-TextMatch -Text $projectionVisualStarter -Pattern "Self Mirror[\s\S]{0,120}dance_visible_motion" -Message "Projection Visual starter should name Self Mirror dance visible motion"
  Assert-TextMatch -Text $projectionVisualStarter -Pattern "expression_visible_change[\s\S]{0,160}context_nod|context_nod[\s\S]{0,160}expression_visible_change" -Message "Projection Visual starter should cover expression and nod visible-motion scenarios"
  Assert-TextMatch -Text $projectionVisualStarter -Pattern "self_mirror_metric_summary\.json[\s\S]{0,220}visual_motion_summary\.json" -Message "Projection Visual starter should name reader-safe Self Mirror result files"
  Assert-TextMatch -Text $projectionVisualStarter -Pattern "runtime/visual-motion-analyzer/self-mirror-consumer-routes\.json" -Message "Projection Visual starter should point system readers to the consumer route map"
  Assert-TextMatch -Text $projectionVisualStarter -Pattern "semantic quality[\s\S]{0,180}physical display proof|physical projector output[\s\S]{0,120}physical-device proof" -Message "Projection Visual starter should avoid overclaiming semantic quality or physical display proof"
  Assert-TextMatch -Text $projectionVisualStarter -Pattern "raw screenshots[\s\S]{0,160}raw browser frames[\s\S]{0,160}provider payloads[\s\S]{0,160}transcripts" -Message "Projection Visual starter should preserve raw/private/media boundaries"
  $selfMirrorConsumerRoutes = Get-Content -Raw -LiteralPath (Join-Path $RepoRoot "runtime\visual-motion-analyzer\self-mirror-consumer-routes.json")
  $selfMirrorConsumerRoutesSchemaPath = Join-Path $RepoRoot "contracts\self_mirror_consumer_routes\self_mirror_consumer_routes.v0.schema.json"
  Assert-PathPresent -Path $selfMirrorConsumerRoutesSchemaPath
  $selfMirrorConsumerRoutesSchema = Get-Content -Raw -LiteralPath $selfMirrorConsumerRoutesSchemaPath
  $contractsReadme = Get-Content -Raw -LiteralPath (Join-Path $RepoRoot "contracts\README.md")
  Assert-TextMatch -Text $selfMirrorConsumerRoutes -Pattern '"schema_version"\s*:\s*"self_mirror_consumer_routes\.v0"' -Message "Self Mirror consumer route map should have a schema version"
  Assert-TextMatch -Text $selfMirrorConsumerRoutes -Pattern '"contract_ref"\s*:\s*"contracts/self_mirror_consumer_routes/self_mirror_consumer_routes\.v0\.schema\.json"' -Message "Self Mirror consumer route map should point to its contract"
  Assert-TextMatch -Text $selfMirrorConsumerRoutes -Pattern '"thought_core"' -Message "Self Mirror consumer route map should be discoverable by Thought Core"
  Assert-TextMatch -Text $selfMirrorConsumerRoutes -Pattern '"self_mirror\.browser\.dance_visible_motion"' -Message "Self Mirror consumer route map should include browser dance visible motion"
  Assert-TextMatch -Text $selfMirrorConsumerRoutes -Pattern '"result_authority_file"\s*:\s*"self_mirror_metric_summary\.json"' -Message "Self Mirror consumer route map should name the authority result file"
  Assert-TextMatch -Text $selfMirrorConsumerRoutes -Pattern '"observation_only"\s*:\s*true' -Message "Self Mirror consumer route map should keep observation-only boundary"
  Assert-TextMatch -Text $selfMirrorConsumerRoutes -Pattern '"direct_correction_dispatch"\s*:\s*false' -Message "Self Mirror consumer route map should not dispatch correction"
  Assert-TextMatch -Text $selfMirrorConsumerRoutes -Pattern '"home_assistant_action"\s*:\s*false' -Message "Self Mirror consumer route map should not become a Home Assistant action surface"
  Assert-TextMatch -Text $selfMirrorConsumerRoutes -Pattern '"provider_call"\s*:\s*false' -Message "Self Mirror consumer route map should not become a provider-call surface"
  Assert-TextMatch -Text $selfMirrorConsumerRoutes -Pattern '"microphone_or_camera_input"\s*:\s*false' -Message "Self Mirror consumer route map should not imply mic/camera input"
  Assert-TextMatch -Text $selfMirrorConsumerRoutes -Pattern '"physical_display_proof"\s*:\s*false' -Message "Self Mirror consumer route map should avoid physical display proof upgrade"
  Assert-TextMatch -Text $selfMirrorConsumerRoutes -Pattern '"thought_core"\s*:\s*"[^"]*discovery and interpretation map only[^"]*must not dispatch correction[^"]*claim release readiness[^"]*run another route by itself' -Message "Self Mirror consumer route map should keep Thought Core guidance discovery-only"
  Assert-TextMatch -Text $selfMirrorConsumerRoutesSchema -Pattern '"schema_version"\s*:\s*\{[\s\S]{0,80}"const"\s*:\s*"self_mirror_consumer_routes\.v0"' -Message "Self Mirror consumer route schema should define schema version"
  Assert-TextMatch -Text $selfMirrorConsumerRoutesSchema -Pattern '"contract_ref"\s*:\s*\{[\s\S]{0,140}"const"\s*:\s*"contracts/self_mirror_consumer_routes/self_mirror_consumer_routes\.v0\.schema\.json"' -Message "Self Mirror consumer route schema should lock contract_ref"
  Assert-TextMatch -Text $selfMirrorConsumerRoutesSchema -Pattern '"intended_readers"[\s\S]{0,800}"const"\s*:\s*"thought_core"' -Message "Self Mirror consumer route schema should require Thought Core discoverability"
  Assert-TextMatch -Text $selfMirrorConsumerRoutesSchema -Pattern '"home_assistant_action"\s*:\s*\{[\s\S]{0,80}"const"\s*:\s*false' -Message "Self Mirror consumer route schema should reject Home Assistant action authority"
  Assert-TextMatch -Text $selfMirrorConsumerRoutesSchema -Pattern '"provider_call"\s*:\s*\{[\s\S]{0,80}"const"\s*:\s*false' -Message "Self Mirror consumer route schema should reject provider-call authority"
  Assert-TextMatch -Text $contractsReadme -Pattern "self_mirror_consumer_routes/self_mirror_consumer_routes\.v0\.schema\.json" -Message "Contracts README should list Self Mirror consumer routes"
  Assert-TextMatch -Text $contractsReadme -Pattern "docs/reference-surfaces\.md" -Message "Contracts README should point developers to reference-surface procedure"
  $homeControlPreviewStarter = Get-Content -Raw -LiteralPath (Join-Path $RepoRoot "examples\starter-profiles\home-control-preview\README.md")
  Assert-TextMatch -Text $homeControlPreviewStarter -Pattern "starter-profile:home-control-preview" -Message "Home Control preview starter should have a stable anchor"
  Assert-TextMatch -Text $homeControlPreviewStarter -Pattern "read-only readiness route[\s\S]{0,180}not Home Assistant preview[\s\S]{0,40}proof" -Message "Home Control preview starter should distinguish readiness from HA preview proof"
  Assert-TextMatch -Text $homeControlPreviewStarter -Pattern "\.\\sword\.ps1 status[\s\S]{0,160}\.\\sword\.ps1 verify[\s\S]{0,160}\.\\sword\.ps1 hold-live" -Message "Home Control preview starter should start with safe front-door checks"
  Assert-TextMatch -Text $homeControlPreviewStarter -Pattern "CheckOnly[\s\S]{0,240}CheckTracking[\s\S]{0,240}CheckState" -Message "Home Control preview starter should keep read-only helper modes visible"
  Assert-TextMatch -Text $homeControlPreviewStarter -Pattern "not be reported as proof that a command changed[\s\S]{0,40}device" -Message "Home Control preview starter should prevent read-only CheckState proof upgrades"
  Assert-TextMatch -Text $homeControlPreviewStarter -Pattern "already-running selected-workspace bridge[\s\S]{0,220}exact route-owned read-only[\s\S]{0,220}bridge[\s\S]{0,80}unavailable" -Message "Home Control preview starter should explain HOLD_LIVE read-only bridge availability"
  Assert-TextMatch -Text $homeControlPreviewStarter -Pattern "preview/dry-run/live[\s\S]{0,120}Not part of this starter profile" -Message "Home Control preview starter should keep preview/dry-run/live out of scope"
  Assert-TextMatch -Text $homeControlPreviewStarter -Pattern "raw HA entity IDs[\s\S]{0,160}tokens[\s\S]{0,160}screenshots" -Message "Home Control preview starter should preserve raw/private boundaries"
  $adrDocs = Get-Content -Raw -LiteralPath (Join-Path $RepoRoot "governance\architecture-decisions\README.md")
  Assert-TextMatch -Text $adrDocs -Pattern "architecture-decisions:overview" -Message "architecture decision docs should anchor durable decision records"
  Assert-TextMatch -Text $adrDocs -Pattern "architecture-decisions:template" -Message "architecture decision docs should include a minimal record template"
  $noLiveSkill = Get-Content -Raw -LiteralPath (Join-Path $RepoRoot "skills\repair-no-live-readiness\SKILL.md")
  Assert-TextMatch -Text $noLiveSkill -Pattern "Repair No-Live Readiness" -Message "no-live readiness repair skill should exist"
  Assert-TextMatch -Text $noLiveSkill -Pattern "Do not submit Home Assistant preview, dry-run, or execute" -Message "no-live readiness repair skill should preserve live boundaries"
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
  Assert-PathPresent -Path (Join-Path $RepoRoot "scripts\run-full-install-verification.ps1")
  $fullInstallHelper = Get-Content -Raw -LiteralPath (Join-Path $RepoRoot "scripts\run-full-install-verification.ps1")
  Assert-TextMatch -Text $fullInstallHelper -Pattern "default_safety=no-live/no-device" -Message "full install helper should report default no-live/no-device safety"
  Assert-TextMatch -Text $fullInstallHelper -Pattern "RequestRealCamera" -Message "full install helper should require explicit real camera request"
  Assert-TextMatch -Text $fullInstallHelper -Pattern "RequestVirtualAudio" -Message "full install helper should require explicit virtual audio request"
  Assert-TextMatch -Text $fullInstallHelper -Pattern "RequestVoicevoxStartup" -Message "full install helper should require explicit VOICEVOX startup request"
  Assert-TextMatch -Text $fullInstallHelper -Pattern "SecretInputsRoot" -Message "full install helper should forward a separate secret inputs root"
  Assert-TextMatch -Text $fullInstallHelper -Pattern "<secret-inputs>" -Message "full install helper should redact separate secret inputs root paths"
  Assert-TextMatch -Text $fullInstallHelper -Pattern "RequestLiveHomeAssistant" -Message "full install helper should require explicit live HA request"
  Assert-TextMatch -Text $fullInstallHelper -Pattern "AllowedActionId" -Message "full install helper should require live HA action id"
  Assert-TextMatch -Text $fullInstallHelper -Pattern "git_unreadable" -Message "full install helper should separate git_unreadable from true pin mismatch"
  Assert-TextMatch -Text $fullInstallHelper -Pattern 'raw_audio_shared = \$false' -Message "full install helper should keep raw audio unshared"
  Assert-TextMatch -Text $fullInstallHelper -Pattern 'live_action_executed = \$false' -Message "full install helper should not execute live actions"
  Assert-TextMatch -Text $fullInstallHelper -Pattern "<workspace>" -Message "full install helper should redact workspace paths in display commands"
  Assert-TextMatch -Text $fullInstallHelper -Pattern "run-local-media-replay\.ps1" -Message "full install helper should call the local media preview helper"
  Assert-TextMatch -Text $fullInstallHelper -Pattern "check-voicevox-readiness\.ps1" -Message "full install helper should call the VOICEVOX readiness helper"
  Assert-TextNotMatch -Text $fullInstallHelper -Pattern "FIV-11a|SkipVoiceGatePreview" -Message "full install helper should not retain the retired voice preview row or flag"
  Assert-TextMatch -Text $fullInstallHelper -Pattern "start-home-control-bridge\.ps1" -Message "full install helper should use the Home Control bridge only for preflight/tracking checks"
  Assert-TextMatch -Text $fullInstallHelper -Pattern "CheckTracking" -Message "full install helper should use tracking metadata before live execute instead of post-state checks"
  Assert-PathPresent -Path (Join-Path $RepoRoot "scripts\check-voicevox-readiness.ps1")
  $voicevoxHelper = Get-Content -Raw -LiteralPath (Join-Path $RepoRoot "scripts\check-voicevox-readiness.ps1")
  Assert-TextMatch -Text $voicevoxHelper -Pattern "EndpointUrl" -Message "VOICEVOX helper should check endpoint first"
  Assert-TextMatch -Text $voicevoxHelper -Pattern "StartIfNeeded" -Message "VOICEVOX helper should require explicit startup request"
  Assert-TextMatch -Text $voicevoxHelper -Pattern "installed_or_updated_voicevox" -Message "VOICEVOX helper should report that it did not install or update VOICEVOX"
  Assert-TextMatch -Text $voicevoxHelper -Pattern "global_audio_changed_by_script" -Message "VOICEVOX helper should report that it did not change global audio"
  $preparedSampleRunnerPath = Join-Path $RepoRoot "scripts\start-prepared-sample-browser-stt-operator.ps1"
  Assert-PathPresent -Path $preparedSampleRunnerPath
  $preparedSampleRunner = Get-Content -Raw -LiteralPath $preparedSampleRunnerPath
  Assert-TextMatch -Text $preparedSampleRunner -Pattern "schema_version.*-ne 1" -Message "prepared-sample runner should require media index schema version 1"
  Assert-TextMatch -Text $preparedSampleRunner -Pattern "prepared_sample_index_verified" -Message "prepared-sample runner should fix the verified preflight class"
  Assert-TextMatch -Text $preparedSampleRunner -Pattern '\[int\]\$AttemptCount = 5[\s\S]{0,320}\[ValidateSet\("system_default", "installed_virtual_cable_pair_v1"\)\][\s\S]{0,900}\$AttemptCount -lt 1 -or \$AttemptCount -gt 5' -Message "prepared-sample runner should default to five and admit only the fixed bounded route options"
  Assert-TextMatch -Text $preparedSampleRunner -Pattern 'bounded_attempt_count = \$AttemptCount[\s\S]{0,160}attempt_timeout_ms = 10000[\s\S]{0,160}audio_route_class = \$AudioRouteClass' -Message "prepared-sample runner should carry the selected bounded attempt count and fixed route class"
  Assert-TextMatch -Text $preparedSampleRunner -Pattern '\$IntegratedPresentation[\s\S]{0,260}integrated_presentation=1[\s\S]{0,900}integrated_presentation = \[bool\]\$IntegratedPresentation' -Message "prepared-sample runner should expose only the inert fixed integrated-presentation query marker"
  Assert-TextMatch -Text $preparedSampleRunner -Pattern 'PreparedSampleIdPattern\s*=\s*"\^\[a-z\]\[a-z0-9_\.\-\]\{2,127\}\$"' -Message "prepared-sample runner should use the exact lowercase prepared-sample ID pattern"
  Assert-TextMatch -Text $preparedSampleRunner -Pattern 'ConversationAttemptRefPattern\s*=\s*"\^m4\\\.prepared_sample_attempt:\[a-f0-9\]\{32\}\$"' -Message "prepared-sample runner should lock conversation_attempt_ref to the canonical M4 format"
  Assert-TextMatch -Text $preparedSampleRunner -Pattern 'function New-ConversationAttemptRef\s*\{[\s\S]{0,120}m4\.prepared_sample_attempt:\$\(\[guid\]::NewGuid\(\)\.ToString\(''N''\)\)' -Message "prepared-sample runner should generate canonical colon-delimited conversation_attempt_ref values"
  Assert-TextMatch -Text $preparedSampleRunner -Pattern 'ConversationAttemptRef = New-ConversationAttemptRef[\s\S]{0,120}Assert-ConversationAttemptRef -Value \$ConversationAttemptRef' -Message "prepared-sample runner should validate generated or supplied conversation_attempt_ref values"
  Assert-TextMatch -Text $preparedSampleRunner -Pattern 'browser_open_requested = \[bool\]\$OpenBrowser[\s\S]{0,100}browser_launch_executed = \$false' -Message "prepared-sample runner should distinguish requested browser opening from executed launch"
  Assert-TextMatch -Text $preparedSampleRunner -Pattern 'Start-Process \$operatorUrl[\s\S]{0,100}browser_launch_executed = \$true[\s\S]{0,160}source_static_preflight_plus_browser_launch_only' -Message "prepared-sample runner should only report launch after Start-Process returns and retain the launch-only ceiling"
  Assert-TextMatch -Text $preparedSampleRunner -Pattern 'raw_path_shared = \$false[\s\S]{0,460}browser_page_reachability_proven = \$false[\s\S]{0,120}browser_stt_runtime_executed = \$false[\s\S]{0,120}turn_input_materialized = \$false' -Message "prepared-sample runner should preserve source-static and no-reachability/no-STT boundaries"
  $sourceStaticJoinRowNames = @(
    "recognition",
    "input_gate",
    "thought_core_turninput",
    "canonical_assistant_response",
    "bubble",
    "tts",
    "bubble_tts_parity",
    "self_mirror_observation",
    "self_output_session_correlation",
    "user_heard"
  )
  foreach ($rowName in $sourceStaticJoinRowNames) {
    Assert-TextMatch -Text $preparedSampleRunner -Pattern ('"' + [regex]::Escape($rowName) + '"') -Message "prepared-sample runner should define fixed source-static join row: $rowName"
  }
  Assert-TextMatch -Text $preparedSampleRunner -Pattern 'observation_status = "not_observed_source_static"[\s\S]{0,140}observation_count = \$null[\s\S]{0,140}observed_conversation_attempt_ref = \$null' -Message "prepared-sample runner source-static join rows should not claim runtime observations"
  Assert-TextMatch -Text $preparedSampleRunner -Pattern 'whole_loop_pass_rule = "exact_same_valid_conversation_attempt_ref_across_every_required_row"[\s\S]{0,180}correlation_basis = "conversation_attempt_ref_only"[\s\S]{0,180}correlation_inference_prohibited_from = @\("text", "message_id", "turn_id", "session_id"\)[\s\S]{0,180}missing_or_mismatched_required_row_result = "fails_or_not_observed"' -Message "prepared-sample runner should require exact same attempt correlation without text or identifier inference"
  Assert-TextMatch -Text $preparedSampleRunner -Pattern 'required_conversation_attempt_ref = \$ConversationAttemptRef[\s\S]{0,800}"conversation_attempt_ref=\$\(\[uri\]::EscapeDataString\(\$ConversationAttemptRef\)\)"[\s\S]{0,800}conversation_attempt_ref = \$ConversationAttemptRef' -Message "prepared-sample runner should carry the exact validated conversation_attempt_ref through join envelope, operator query, and result"
  Assert-TextMatch -Text $preparedSampleRunner -Pattern 'new_service_or_schema_or_compatibility_route = \$false' -Message "prepared-sample runner should not add a service schema or compatibility route"
  Assert-TextMatch -Text $preparedSampleRunner -Pattern 'raw_private_text_shared = \$false[\s\S]{0,600}tokens_or_secrets_shared = \$false' -Message "prepared-sample runner source-static join envelope should preserve publication boundaries"
  Assert-TextMatch -Text $preparedSampleRunner -Pattern 'source_static_join_envelope = \$sourceStaticJoinEnvelope' -Message "prepared-sample runner should add the source-static join envelope to result and JSON output"
  $retiredRuntimeFieldPattern = "(?m)^\s*(browser_runtime_" + "executed|stt_runtime_" + "executed)\s*="
  Assert-TextNotMatch -Text $preparedSampleRunner -Pattern $retiredRuntimeFieldPattern -Message "prepared-sample runner should not retain ambiguous retired runtime fields"
  $preparedSamplePlaybackControllerPath = Join-Path $RepoRoot "scripts\run-prepared-sample-browser-stt-playback-controller.ps1"
  $preparedSamplePlaybackControllerTestPath = Join-Path $RepoRoot "scripts\test-prepared-sample-browser-stt-playback-controller.ps1"
  $preparedSamplePlaybackCollectorPath = Join-Path $RepoRoot "organs\expression\aituber-kit\scripts\collect-prepared-sample-browser-stt-playback.mjs"
  $preparedSamplePlaybackCollectorTestPath = Join-Path $RepoRoot "organs\expression\aituber-kit\scripts\collect-prepared-sample-browser-stt-playback.test.mjs"
  foreach ($path in @(
    $preparedSamplePlaybackControllerPath,
    $preparedSamplePlaybackControllerTestPath,
    $preparedSamplePlaybackCollectorPath,
    $preparedSamplePlaybackCollectorTestPath
  )) {
    Assert-PathPresent -Path $path
  }
  $preparedSamplePlaybackController = Get-Content -Raw -LiteralPath $preparedSamplePlaybackControllerPath
  $preparedSamplePlaybackCollector = Get-Content -Raw -LiteralPath $preparedSamplePlaybackCollectorPath
  Assert-TextMatch -Text $preparedSamplePlaybackController -Pattern 'prepared_sample_expected_text\.v1[\s\S]{0,240}prepared_sample_expected_text_authority_missing_or_invalid' -Message "prepared-sample playback controller should keep the local expected-text authority fixed and fail closed"
  Assert-TextMatch -Text $preparedSamplePlaybackController -Pattern 'SWORD_PREPARED_SAMPLE_AUDIO_PATH[\s\S]{0,300}SWORD_PREPARED_SAMPLE_EXPECTED_TEXT[\s\S]{0,300}SWORD_PREPARED_SAMPLE_LOCALE' -Message "prepared-sample playback controller should pass private runtime inputs only through the child environment"
  Assert-TextMatch -Text $preparedSamplePlaybackController -Pattern 'SWORD_PREPARED_SAMPLE_ATTEMPT_COUNT[\s\S]{0,240}SWORD_PREPARED_SAMPLE_AUDIO_ROUTE_CLASS' -Message "prepared-sample playback controller should pass only fixed count/class route options to the collector"
  Assert-TextMatch -Text $preparedSamplePlaybackController -Pattern 'installed_virtual_cable_pair_v1[\s\S]{0,240}\[bool\]\$IntegratedPresentation -ne \$integratedRouteSelected[\s\S]{0,160}\(\$AttemptCount -eq 1\) -ne \$integratedRouteSelected[\s\S]{0,200}prepared_sample_playback_controller_configuration_invalid' -Message "prepared-sample playback controller should fail closed on invalid integrated option combinations"
  Assert-TextMatch -Text $preparedSamplePlaybackController -Pattern 'WaitForExit\(95000\)[\s\S]{0,220}whole_route_timeout' -Message "prepared-sample playback controller should retain the bounded 90-second route with cleanup margin"
  Assert-TextMatch -Text $preparedSamplePlaybackController -Pattern 'private_environment_shared = \$false' -Message "prepared-sample playback controller should keep private child environment values out of shared output"
  Assert-TextMatch -Text $preparedSamplePlaybackController -Pattern 'SWORD_PREPARED_SAMPLE_EXPECTED_TEXT[\s\S]{0,8000}Environment\.Remove\(\$key\)' -Message "prepared-sample playback controller should clear the private child environment in finally"
  Assert-TextMatch -Text $preparedSamplePlaybackController -Pattern '\$validatedAssetId = \$null[\s\S]{0,12000}selected_asset_id = \$validatedAssetId' -Message "prepared-sample playback controller should never reflect an unvalidated asset id"
  Assert-TextMatch -Text $preparedSamplePlaybackController -Pattern 'function Assert-CollectorResult[\s\S]{0,4200}raw_text_shared[\s\S]{0,4200}controller_status -ceq "completed"' -Message "prepared-sample playback controller should strictly validate collector keys, safety flags, and completed-result consistency"
  Assert-TextMatch -Text $preparedSamplePlaybackController -Pattern '\$collectorCompleted = [\s\S]{0,240}\$child\.ExitCode -ne 0[\s\S]{0,240}\$child\.ExitCode -eq 0' -Message "prepared-sample playback controller should couple completed/error JSON to the owned child exit status"
  Assert-TextMatch -Text $preparedSamplePlaybackController -Pattern 'function Stop-OwnedChild[\s\S]{0,900}WaitForExit\(5000\)[\s\S]{0,900}return \$child\.HasExited' -Message "prepared-sample playback controller should confirm owned child exit within a bound"
  Assert-TextMatch -Text $preparedSamplePlaybackController -Pattern 'SWORD_PREPARED_SAMPLE_TEST_LOCK_CLEANUP_FAILURE[\s\S]{0,900}Test-Path -LiteralPath \$lockPath[\s\S]{0,900}\$cleanupIncomplete' -Message "prepared-sample playback controller should verify owned lock absence"
  Assert-TextMatch -Text $preparedSamplePlaybackController -Pattern 'if \(\$cleanupIncomplete\)[\s\S]{0,180}New-FixedFailureResult -BlockerClass "cleanup_incomplete"' -Message "prepared-sample playback controller should override any prior result when cleanup convergence is unproven"
  Assert-TextMatch -Text $preparedSamplePlaybackCollector -Pattern 'ATTEMPT_COUNT = 5[\s\S]{0,100}ATTEMPT_TIMEOUT_MS = 10_000[\s\S]{0,100}ROUTE_TIMEOUT_MS = 90_000' -Message "prepared-sample playback collector should retain five attempts, 10-second attempts, and a 90-second route bound"
  Assert-TextMatch -Text $preparedSamplePlaybackCollector -Pattern 'ROUTE_CANCEL_SETTLE_MS = 2_000[\s\S]{0,30000}new AbortController\(\)[\s\S]{0,2500}waitForRouteSettlement' -Message "prepared-sample playback collector should abort at the route bound and await bounded operation settlement before cleanup"
  Assert-TextMatch -Text $preparedSamplePlaybackCollector -Pattern "waitForStatus\('attempt_listening'[\s\S]{0,650}startPlayback\(\{ signal \}\)" -Message "prepared-sample playback collector should start tracked playback only after the page enters the listening state"
  Assert-TextMatch -Text $preparedSamplePlaybackCollector -Pattern "waitForStatus\('attempt_listening'[\s\S]{0,180}requireRecognitionLocale\(\)[\s\S]{0,650}startPlayback\(\{ signal \}\)" -Message "prepared-sample playback collector should verify the browser recognition locale before playback"
  Assert-TextMatch -Text $preparedSamplePlaybackCollector -Pattern "enumerateDevices\(\)" -Message "prepared-sample playback collector should inspect normal-browser audio input and output devices"
  Assert-TextMatch -Text $preparedSamplePlaybackCollector -Pattern 'CABLE Output \(VB-Audio Virtual Cable\)[\s\S]{0,160}CABLE Input \(VB-Audio Virtual Cable\)[\s\S]{0,3000}captureMatches\.length === 1 && renderMatches\.length === 1' -Message "prepared-sample playback collector should select exactly one fixed virtual capture/render pair internally"
  Assert-TextMatch -Text $preparedSamplePlaybackCollector -Pattern 'deviceId: \{ exact: captureMatches\[0\]\.deviceId \}[\s\S]{0,1000}selectedTrack\?\.readyState === ''live''[\s\S]{0,300}selectedInputId === captureMatches\[0\]\.deviceId' -Message "prepared-sample playback collector should acquire and verify the exact selected virtual capture track"
  Assert-TextMatch -Text $preparedSamplePlaybackCollector -Pattern 'context\.setSinkId\(outputDeviceId\)[\s\S]{0,2400}BROWSER_PLAYBACK_GAIN_DB = 12|BROWSER_PLAYBACK_GAIN_DB = 12[\s\S]{0,16000}context\.setSinkId\(outputDeviceId\)' -Message "prepared-sample playback collector should select the browser sink and retain the fixed +12 dB gain"
  Assert-TextMatch -Text $preparedSamplePlaybackCollector -Pattern 'context\.setSinkId\(outputDeviceId\)[\s\S]{0,2600}audio\.play\(\)' -Message "prepared-sample playback collector should select the fixed sink before browser playback"
  Assert-TextMatch -Text $preparedSamplePlaybackCollector -Pattern 'accepted_candidate_request_completed[\s\S]{0,4500}waitForAcceptedCandidateCompletion[\s\S]{0,4200}assertIntegratedCardinality' -Message "prepared-sample playback collector should await exactly one accepted submission before integrated cleanup"
  Assert-TextMatch -Text $preparedSamplePlaybackCollector -Pattern 'URL\.revokeObjectURL[\s\S]{0,1800}context\.close\(\)' -Message "prepared-sample playback collector should release browser audio graph and blob URL handles"
  Assert-TextMatch -Text $preparedSamplePlaybackCollector -Pattern 'delete privateWindow\.__preparedSampleSttAudioOutputDeviceId' -Message "prepared-sample playback collector should clear the private selected sink handle"
  Assert-TextNotMatch -Text $preparedSamplePlaybackCollector -Pattern 'Set-AudioDevice|SetDefaultEndpoint|SoundVolumeView' -Message "prepared-sample playback collector should not mutate Windows default audio roles"
  Assert-TextMatch -Text $preparedSamplePlaybackCollector -Pattern "browser_microphone_permission_or_device_unavailable[\s\S]{0,600}browser_audio_input_track_not_live[\s\S]{0,600}browser_audio_output_device_unavailable" -Message "prepared-sample playback collector should fail closed on missing input, non-live track, or missing output"
  Assert-TextMatch -Text $preparedSamplePlaybackCollector -Pattern "clearPrivateProcessEnvironment\(\)[\s\S]{0,800}privateValues\[key\] = ''" -Message "prepared-sample playback collector should clear inherited private environment and retained values before exit"
  Assert-TextMatch -Text $preparedSamplePlaybackCollector -Pattern "--use-fake-ui-for-media-stream" -Message "prepared-sample playback collector may suppress only the microphone permission prompt"
  Assert-TextNotMatch -Text $preparedSamplePlaybackCollector -Pattern "--use-fake-device-for-media-stream" -Message "prepared-sample playback collector should not replace the real browser microphone input"
  Assert-TextMatch -Text $preparedSamplePlaybackCollector -Pattern "parent_preflight_mount_pending[\s\S]{0,2200}attach_external" -Message "prepared-sample playback collector should attach only after the bounded operator surface probe succeeds"
  Assert-TextMatch -Text $preparedSamplePlaybackCollector -Pattern "Get-NetTCPConnection[\s\S]{0,1600}CreationDate\.ToUniversalTime\(\)\.Ticks" -Message "prepared-sample playback collector should inspect one loopback listener PID and start identity"
  Assert-TextMatch -Text $preparedSamplePlaybackCollector -Pattern "parseOperatorServerIdentity[\s\S]{0,500}owned:\(\\d\{1,10\}\):\(\\d\{1,19\}\)" -Message "prepared-sample playback collector should parse only a bounded PID/start identity"
  Assert-TextMatch -Text $preparedSamplePlaybackCollector -Pattern 'ParentProcessId[\s\S]{0,2600}node_modules\\\\next\\\\dist\\\\server\\\\lib\\\\start-server[\s\S]{0,800}\$owned=\$directOwned -or \$sealedChild' -Message "prepared-sample playback collector should accept only the direct Next dev owner or its sealed listener child"
  Assert-TextMatch -Text $preparedSamplePlaybackCollector -Pattern "initialIdentity = await inspectOwner\(\)[\s\S]{0,900}confirmedIdentity = await inspectOwner\(\)[\s\S]{0,500}sameOperatorServerIdentity" -Message "prepared-sample playback collector should reject an owner swap during external surface probing"
  Assert-TextMatch -Text $preparedSamplePlaybackCollector -Pattern "adapter\.revalidateExternalServer\(\)[\s\S]{0,240}adapter\.fillExpectedText" -Message "prepared-sample playback collector should revalidate external owner identity before private expected-text use"
  Assert-TextMatch -Text $preparedSamplePlaybackCollector -Pattern "async revalidateExternalServer\(\)[\s\S]{0,420}sameOperatorServerIdentity" -Message "prepared-sample playback collector should compare the current external owner with the retained PID/start identity"
  Assert-TextMatch -Text $preparedSamplePlaybackCollector -Pattern "serverMode = resolution\.serverMode[\s\S]{0,200}externalServerIdentity = resolution\.externalServerIdentity[\s\S]{0,200}serverMode === 'attach_external'" -Message "prepared-sample playback collector should retain external owner identity while preserving an attached Next server"
  Assert-TextMatch -Text $preparedSamplePlaybackCollector -Pattern "stopTrackedServer\(\{ serverMode, serverChild \}\)[\s\S]{0,200}externalServerIdentity = null" -Message "prepared-sample playback collector should clear external identity only through tracked server cleanup"
  Assert-TextMatch -Text $preparedSamplePlaybackCollector -Pattern "stopOwnedProcess[\s\S]{0,600}serverChild\.kill\(\)[\s\S]{0,220}serverChild\.kill\('SIGKILL'\)" -Message "prepared-sample playback collector should clear owned Next tracking only after bounded exit confirmation"
  Assert-TextMatch -Text $preparedSamplePlaybackCollector -Pattern "pipe:0" -Message "prepared-sample playback collector should stream private audio to ffplay without a file path argument"
  Assert-TextNotMatch -Text $preparedSamplePlaybackCollector -Pattern 'spawn\([\s\S]{0,300}audioPath' -Message "prepared-sample playback collector should not place the private audio path on the ffplay command line"
  $preparedSamplePagePath = Join-Path $RepoRoot "organs\expression\aituber-kit\src\pages\operator\prepared-sample-stt.tsx"
  Assert-PathPresent -Path $preparedSamplePagePath
  $preparedSamplePage = Get-Content -Raw -LiteralPath $preparedSamplePagePath
  Assert-TextMatch -Text $preparedSamplePage -Pattern "parent_preflight_query_required[\s\S]{0,500}parent_preflight_query_invalid" -Message "prepared-sample page should fail closed without valid parent query parameters"
  Assert-TextMatch -Text $preparedSamplePage -Pattern "latestTranscriptRef\.current" -Message "prepared-sample page should use the latest active browser STT diagnostic transcript"
  Assert-TextNotMatch -Text $preparedSamplePage -Pattern "Selected sample selector|Sample-index preflight class|Sample-index preflight ref" -Message "prepared-sample page should not expose parent-owned preflight selectors"
  $retiredWrapperPath = Join-Path $RepoRoot ("scripts\test-local-media-" + "voice-gate.ps1")
  $retiredCorePath = Join-Path $RepoRoot ("control-plane\core\src\sword_voice_agent\apps\local_media_" + "voice_gate_proof.py")
  Assert-PathAbsent -Path $retiredWrapperPath
  Assert-PathAbsent -Path $retiredCorePath
  $overallTestLadder = Get-Content -Raw -LiteralPath (Join-Path $RepoRoot "scripts\run-overall-test-ladder-v2.ps1")
  $migrationSurface = @(
    $overallTestLadder,
    $localMediaPreparationHelper,
    $fullInstallHelper,
    $voiceAvatarStarter
  ) -join "`n"
  Assert-TextMatch -Text $migrationSurface -Pattern "start-prepared-sample-browser-stt-operator\.ps1" -Message "parent consumers should point to the prepared-sample runner"
  Assert-TextNotMatch -Text $migrationSurface -Pattern ("test-local-media-" + "voice-gate|local_media_" + "voice_gate_proof") -Message "parent consumers should not retain retired voice-gate references"
  Assert-TextNotMatch -Text $localMediaPreparationHelper -Pattern "voice-gate replay" -Message "local media preparation output should not retain the retired voice-gate replay wording"
  Assert-TextMatch -Text $localMediaPreparationHelper -Pattern "prepared-sample browser-STT operator preflight / exact conversation_attempt_ref correlation" -Message "local media preparation output should name prepared-sample browser-STT exact attempt correlation"
  Assert-TextNotMatch -Text $fullInstallHelper -Pattern "voice-gate collector" -Message "FIV-11 output should not retain the retired voice-gate collector wording"
  Assert-TextMatch -Text $fullInstallHelper -Pattern 'FIV-11[\s\S]{0,360}Prepared-sample browser-STT / exact conversation_attempt_ref correlation[\s\S]{0,360}exact conversation_attempt_ref' -Message "FIV-11 should name prepared-sample browser-STT exact attempt correlation"
  $motionStimulusSchemaPath = Join-Path $RepoRoot "contracts\motion_stimulus\motion_stimulus.v0.schema.json"
  $motionFullRelaxedExamplePath = Join-Path $RepoRoot "contracts\motion_stimulus\examples\rr003-expression-full-relaxed-stimulus.example.json"
  Assert-PathPresent -Path $motionStimulusSchemaPath
  Assert-PathPresent -Path $motionFullRelaxedExamplePath
  $motionStimulusSchema = Get-Content -Raw -LiteralPath $motionStimulusSchemaPath
  $motionFullRelaxedExample = Get-Content -Raw -LiteralPath $motionFullRelaxedExamplePath
  $motionRuntimeReadme = Get-Content -Raw -LiteralPath (Join-Path $RepoRoot "runtime\motion-runtime\README.md")
  $moduleUsageIndex = Get-Content -Raw -LiteralPath (Join-Path $RepoRoot "docs\module-usage-index.md")
  Assert-TextMatch -Text $moduleUsageIndex -Pattern '<!-- module-usage:decision-authority-map -->' -Message "module usage index should retain the decision-authority map anchor"
  $expectedAuthorityIds = @(
    "AUTH-CONFIG-SELECTION",
    "AUTH-RUNTIME-CONTROL",
    "AUTH-SPEECH-ACCEPT",
    "AUTH-CONVERSATION-INTENT",
    "AUTH-REFLEX-REQUEST",
    "AUTH-ACTION-GUARD",
    "AUTH-DEVICE-EXECUTION",
    "AUTH-EXPRESSION-LIFECYCLE",
    "AUTH-MOTION-EXECUTION",
    "AUTH-ENVIRONMENT-OBSERVATION",
    "AUTH-CURRENT-STATE",
    "AUTH-BODY-SCHEMA",
    "AUTH-MEMORY-COMMIT",
    "AUTH-RUNTIME-CORRELATION"
  )
  $actualAuthorityIds = @([regex]::Matches($moduleUsageIndex, '(?m)^\| `(?<id>AUTH-[A-Z-]+)` \|') | ForEach-Object { $_.Groups["id"].Value })
  if (($actualAuthorityIds -join "`n") -cne ($expectedAuthorityIds -join "`n") -or @($actualAuthorityIds | Select-Object -Unique).Count -ne $actualAuthorityIds.Count) {
    throw "module usage index authority ids must match the exact ordered unique set"
  }
  Assert-TextMatch -Text $moduleUsageIndex -Pattern '`AUTH-RUNTIME-CONTROL`[\s\S]{0,700}current operator marker intent[\s\S]{0,700}enforcement remains partial[\s\S]{0,700}not user intent[\s\S]{0,200}action admission' -Message "runtime control should own marker intent without becoming action or user-intent authority"
  Assert-TextMatch -Text $moduleUsageIndex -Pattern '`AUTH-SPEECH-ACCEPT`[\s\S]{0,520}InputGate[\s\S]{0,520}must not grant TurnInput authority' -Message "speech authority should stay with the canonical InputGate rather than signal processing or transport"
  Assert-TextMatch -Text $moduleUsageIndex -Pattern '`AUTH-EXPRESSION-LIFECYCLE`[\s\S]{0,360}selected player owns executed/playback state[\s\S]{0,360}process observer owns externally observed evidence[\s\S]{0,700}Queue acceptance must not be renamed playback' -Message "expression authority should keep queue acceptance, selected-player execution, and process observation separate"
  Assert-TextMatch -Text $moduleUsageIndex -Pattern '`AUTH-ACTION-GUARD`[\s\S]{0,700}organ-local fallback must not bypass the guard' -Message "organ-local fallbacks should not bypass the canonical Action Boundary"
  Assert-TextMatch -Text $moduleUsageIndex -Pattern '`AUTH-RUNTIME-CORRELATION`[\s\S]{0,700}must not classify user intent' -Message "runtime correlation should not become semantic authority"
  Assert-TextMatch -Text $moduleUsageIndex -Pattern '<!-- module-usage:authority-audit-record -->' -Message "module usage index should retain the duplicate-authority audit anchor"
  Assert-TextMatch -Text $moduleUsageIndex -Pattern 'an observation can[\s\S]{0,80}authorize an action[\s\S]{0,180}fallback bypasses the selected owner[\s\S]{0,420}Do not solve those cases by[\s\S]{0,80}third arbitrator' -Message "duplicate-authority audits should fail closed without adding a central arbitrator"
  $motionProfileSurface = "$motionStimulusSchema`n$motionFullRelaxedExample`n$motionRuntimeReadme`n$moduleUsageIndex"
  Assert-TextMatch -Text $motionStimulusSchema -Pattern '"motion\.runtime\.vrm_expression_weights\.v0"[\s\S]{0,140}"motion\.runtime\.vrm_expression_weights\.full_relaxed\.v0"' -Message "motion stimulus schema should expose default and full-relaxed expression profile refs"
  Assert-TextMatch -Text $motionStimulusSchema -Pattern "full_relaxed profile is a bounded diagnostic option" -Message "motion stimulus schema should prevent treating full-relaxed as default proof"
  Assert-TextMatch -Text $motionFullRelaxedExample -Pattern '"expression_profile_ref"\s*:\s*"motion\.runtime\.vrm_expression_weights\.full_relaxed\.v0"' -Message "motion stimulus examples should include a full-relaxed contract fixture"
  Assert-TextMatch -Text $motionFullRelaxedExample -Pattern '"proof_layer"\s*:\s*"source_static"' -Message "full-relaxed motion stimulus example should stay source/static"
  Assert-TextMatch -Text $motionFullRelaxedExample -Pattern '"raw_media_shared"\s*:\s*false[\s\S]{0,240}"provider_payload_shared"\s*:\s*false[\s\S]{0,120}"home_assistant_route"\s*:\s*false' -Message "full-relaxed motion stimulus example should preserve raw/private/provider/HA boundaries"
  Assert-TextMatch -Text $motionRuntimeReadme -Pattern "Expression Profile Refs" -Message "motion runtime docs should document expression profile refs"
  Assert-TextMatch -Text $motionProfileSurface -Pattern "private page[\s\S]{0,80}module[\s\S]{0,80}store[\s\S]{0,80}browser internals|private page/module/store" -Message "motion profile docs should forbid private runtime internals as the selection path"
  Assert-TextMatch -Text $motionProfileSurface -Pattern "does not change the default|standard default expression profile" -Message "motion profile docs should preserve default expression-visible behavior"
  Assert-TextMatch -Text $motionProfileSurface -Pattern "does not prove visible motion|do not prove runtime[\s\S]{0,180}Self Mirror" -Message "motion profile docs should prevent proof upgrades from contract refs"
  $vrmTelemetrySchemaPath = Join-Path $RepoRoot "contracts\vrm_model_telemetry\vrm_model_telemetry.v0.schema.json"
  $vrmTelemetryExamplePath = Join-Path $RepoRoot "contracts\vrm_model_telemetry\examples\rr003-expression-full-relaxed.telemetry.example.json"
  $vrmTelemetryBoneExamplePath = Join-Path $RepoRoot "contracts\vrm_model_telemetry\examples\rr003-bone-baseline.telemetry.example.json"
  $vrmTelemetryRoutesSchemaPath = Join-Path $RepoRoot "contracts\vrm_model_telemetry_consumer_routes\vrm_model_telemetry_consumer_routes.v0.schema.json"
  $vrmTelemetryRoutesPath = Join-Path $RepoRoot "runtime\vrm-model-telemetry\vrm-model-telemetry-consumer-routes.json"
  $vrmTelemetryRuntimeReadmePath = Join-Path $RepoRoot "runtime\vrm-model-telemetry\README.md"
  $vrmTelemetryOrganReadmePath = Join-Path $RepoRoot "organs\expression\vrm-model-telemetry\README.md"
  Assert-PathPresent -Path $vrmTelemetrySchemaPath
  Assert-PathPresent -Path $vrmTelemetryExamplePath
  Assert-PathPresent -Path $vrmTelemetryBoneExamplePath
  Assert-PathPresent -Path $vrmTelemetryRoutesSchemaPath
  Assert-PathPresent -Path $vrmTelemetryRoutesPath
  Assert-PathPresent -Path $vrmTelemetryRuntimeReadmePath
  Assert-PathPresent -Path $vrmTelemetryOrganReadmePath
  $vrmTelemetrySchema = Get-Content -Raw -LiteralPath $vrmTelemetrySchemaPath
  $vrmTelemetryExample = Get-Content -Raw -LiteralPath $vrmTelemetryExamplePath
  $vrmTelemetryBoneExample = Get-Content -Raw -LiteralPath $vrmTelemetryBoneExamplePath
  $vrmTelemetryRoutesSchema = Get-Content -Raw -LiteralPath $vrmTelemetryRoutesSchemaPath
  $vrmTelemetryRoutes = Get-Content -Raw -LiteralPath $vrmTelemetryRoutesPath
  $vrmTelemetryRuntimeReadme = Get-Content -Raw -LiteralPath $vrmTelemetryRuntimeReadmePath
  $vrmTelemetryOrganReadme = Get-Content -Raw -LiteralPath $vrmTelemetryOrganReadmePath
  $contractsReadme = Get-Content -Raw -LiteralPath (Join-Path $RepoRoot "contracts\README.md")
  $proofLayers = Get-Content -Raw -LiteralPath (Join-Path $RepoRoot "docs\proof-layers.md")
  $referenceSurfaces = Get-Content -Raw -LiteralPath (Join-Path $RepoRoot "docs\reference-surfaces.md")
  $vrmTelemetrySurface = "$vrmTelemetrySchema`n$vrmTelemetryExample`n$vrmTelemetryBoneExample`n$vrmTelemetryRoutesSchema`n$vrmTelemetryRoutes`n$vrmTelemetryRuntimeReadme`n$vrmTelemetryOrganReadme`n$contractsReadme`n$proofLayers`n$referenceSurfaces`n$motionRuntimeReadme`n$moduleUsageIndex"
  Assert-TextMatch -Text $vrmTelemetrySchema -Pattern '"proof_ceiling"[\s\S]{0,120}"runtime_model_state_telemetry_summary_only"' -Message "VRM telemetry schema should lock the model-state proof ceiling"
  Assert-TextMatch -Text $vrmTelemetrySchema -Pattern '"command_authority"[\s\S]{0,80}"const"\s*:\s*false' -Message "VRM telemetry schema should not create command authority"
  Assert-TextMatch -Text $vrmTelemetrySchema -Pattern '"self_mirror_authority"[\s\S]{0,80}"const"\s*:\s*false' -Message "VRM telemetry schema should not become Self Mirror authority"
  Assert-TextMatch -Text $vrmTelemetrySchema -Pattern '"semantic_expression_authority"[\s\S]{0,80}"const"\s*:\s*false' -Message "VRM telemetry schema should not become semantic expression authority"
  Assert-TextMatch -Text $vrmTelemetrySchema -Pattern '"raw_media_shared"[\s\S]{0,80}"const"\s*:\s*false[\s\S]{0,180}"raw_path_shared"[\s\S]{0,80}"const"\s*:\s*false' -Message "VRM telemetry schema should preserve raw media/path redaction"
  Assert-TextMatch -Text $vrmTelemetrySchema -Pattern '"clock_kind"[\s\S]{0,80}"relative_monotonic_elapsed"' -Message "VRM telemetry schema should expose relative monotonic timebase fields"
  Assert-TextMatch -Text $vrmTelemetrySchema -Pattern '"t0_event"[\s\S]{0,180}"first_accepted_sample_after_runtime_vrm_scene_ready_and_sampler_armed"' -Message "VRM telemetry schema should define the sampler t0 event"
  Assert-TextMatch -Text $vrmTelemetrySchema -Pattern '"window_map"' -Message "VRM telemetry schema should support Self Mirror-comparable window maps"
  Assert-TextMatch -Text $vrmTelemetrySchema -Pattern '"pretrigger"[\s\S]{0,120}"active"' -Message "VRM telemetry schema should support pretrigger/active window labels"
  Assert-TextMatch -Text $vrmTelemetrySchema -Pattern '"stop_reason"[\s\S]{0,260}"duration_elapsed"[\s\S]{0,260}"sample_cap_reached"' -Message "VRM telemetry schema should constrain stop reasons"
  Assert-TextMatch -Text $vrmTelemetrySchema -Pattern '"basis_point_id"[\s\S]{0,180}"head"[\s\S]{0,180}"body_root"' -Message "VRM telemetry schema should support canonical bone/basis ids"
  Assert-TextMatch -Text $vrmTelemetrySchema -Pattern '"pose_source_kind"[\s\S]{0,160}"normalized_pose"[\s\S]{0,180}"raw_pose_local_only"' -Message "VRM telemetry schema should distinguish normalized shared pose from raw local-only pose"
  Assert-TextMatch -Text $vrmTelemetrySchema -Pattern '"sample_after_update_class"[\s\S]{0,140}"post_update_required"' -Message "VRM telemetry schema should encode sample-after-update semantics"
  Assert-TextMatch -Text $vrmTelemetrySchema -Pattern '"capture_enabled"' -Message "VRM telemetry schema should make capture explicit"
  Assert-TextMatch -Text $vrmTelemetrySchema -Pattern '"detail_export_enabled"' -Message "VRM telemetry schema should make detail export explicit"
  Assert-TextMatch -Text $vrmTelemetrySchema -Pattern '"local_only_diagnostic_artifact"' -Message "VRM telemetry schema should classify local-only diagnostic artifacts"
  Assert-TextMatch -Text $vrmTelemetrySchema -Pattern '"raw_bvh_shared"[\s\S]{0,80}"const"\s*:\s*false[\s\S]{0,220}"full_skeleton_shared"[\s\S]{0,80}"const"\s*:\s*false' -Message "VRM telemetry schema should reject raw BVH/full skeleton sharing"
  Assert-TextMatch -Text $vrmTelemetryExample -Pattern '"expression_profile_ref"\s*:\s*"motion\.runtime\.vrm_expression_weights\.full_relaxed\.v0"' -Message "VRM telemetry example should include the full-relaxed profile ref"
  Assert-TextMatch -Text $vrmTelemetryExample -Pattern '"metric_kind"\s*:\s*"expression_weight"' -Message "VRM telemetry example should include graph-ready expression weights"
  Assert-TextMatch -Text $vrmTelemetryExample -Pattern '"not_self_mirror_pass"[\s\S]{0,220}"not_expression_visible_pass"[\s\S]{0,220}"not_semantic_expression_correctness"' -Message "VRM telemetry example should preserve proof non-claims"
  Assert-TextMatch -Text $vrmTelemetryBoneExample -Pattern '"clock_kind"\s*:\s*"relative_monotonic_elapsed"' -Message "bone/basis fixture should use relative monotonic elapsed timing"
  Assert-TextMatch -Text $vrmTelemetryBoneExample -Pattern '"t0_event"\s*:\s*"first_accepted_sample_after_runtime_vrm_scene_ready_and_sampler_armed"' -Message "bone/basis fixture should define t0"
  Assert-TextMatch -Text $vrmTelemetryBoneExample -Pattern '"baseline_kind"\s*:\s*"pretrigger_window_mean"' -Message "bone/basis fixture should use bounded pretrigger baseline"
  Assert-TextMatch -Text $vrmTelemetryBoneExample -Pattern '"label"\s*:\s*"pretrigger"[\s\S]{0,260}"label"\s*:\s*"active"' -Message "bone/basis fixture should include comparable window labels"
  Assert-TextMatch -Text $vrmTelemetryBoneExample -Pattern '"capture_enabled"\s*:\s*true[\s\S]{0,180}"detail_export_enabled"\s*:\s*false' -Message "bone/basis fixture should be explicit capture but summary-only"
  Assert-TextMatch -Text $vrmTelemetryBoneExample -Pattern '"target_fps"\s*:\s*15' -Message "bone/basis fixture should carry target cadence"
  Assert-TextMatch -Text $vrmTelemetryBoneExample -Pattern '"max_shared_sample_count"\s*:\s*240' -Message "bone/basis fixture should carry shared sample cap"
  Assert-TextMatch -Text $vrmTelemetryBoneExample -Pattern '"basis_point_id"\s*:\s*"head"[\s\S]{0,260}"coordinate_space"\s*:\s*"normalized_humanoid"' -Message "bone/basis fixture should use normalized canonical basis tracks"
  Assert-TextMatch -Text $vrmTelemetryBoneExample -Pattern '"sample_after_update_class"\s*:\s*"post_update_required"' -Message "bone/basis fixture should encode post-update sampling"
  Assert-TextMatch -Text $vrmTelemetryBoneExample -Pattern '"track_allowlist"\s*:\s*\[[\s\S]{0,180}"head"[\s\S]{0,180}"body_root"' -Message "bone/basis fixture should keep a bounded track allowlist"
  Assert-TextMatch -Text $vrmTelemetryBoneExample -Pattern '"raw_bvh_shared"\s*:\s*false[\s\S]{0,220}"full_skeleton_shared"\s*:\s*false' -Message "bone/basis fixture should preserve raw export boundaries"
  Assert-TextMatch -Text $vrmTelemetrySurface -Pattern "runtime/model telemetry|VRM Model Telemetry" -Message "VRM telemetry should be documented as a separate proof/reference layer"
  Assert-TextMatch -Text $vrmTelemetrySurface -Pattern "runtime/vrm-model-telemetry/vrm-model-telemetry-consumer-routes\.json" -Message "VRM telemetry should expose a system-readable module route map"
  Assert-TextMatch -Text $vrmTelemetrySurface -Pattern "organs/expression/vrm-model-telemetry" -Message "VRM telemetry should have a separate expression organ scaffold"
  Assert-TextMatch -Text $vrmTelemetrySurface -Pattern "off by default|default off" -Message "VRM bone/basis telemetry should be documented as off by default"
  Assert-TextMatch -Text $vrmTelemetrySurface -Pattern "summary-first|summary-only" -Message "VRM bone/basis telemetry should be summary-first"
  Assert-TextMatch -Text $vrmTelemetrySurface -Pattern "diagnostic mode|diagnostic-mode-only" -Message "VRM bone/basis telemetry detailed output should require diagnostic mode"
  Assert-TextMatch -Text $vrmTelemetrySurface -Pattern "relative monotonic" -Message "VRM bone/basis telemetry should document relative monotonic timing"
  Assert-TextMatch -Text $vrmTelemetrySurface -Pattern "raw BVH|full skeleton|raw per-frame" -Message "VRM bone/basis telemetry docs should forbid raw export/public traces"
  Assert-TextMatch -Text $vrmTelemetryRoutes -Pattern '"schema_version"\s*:\s*"vrm_model_telemetry_consumer_routes\.v0"' -Message "VRM telemetry route map should have a schema version"
  Assert-TextMatch -Text $vrmTelemetryRoutes -Pattern '"contract_ref"\s*:\s*"contracts/vrm_model_telemetry_consumer_routes/vrm_model_telemetry_consumer_routes\.v0\.schema\.json"' -Message "VRM telemetry route map should point to its contract"
  Assert-TextMatch -Text $vrmTelemetryRoutes -Pattern '"result_contract_ref"\s*:\s*"contracts/vrm_model_telemetry/vrm_model_telemetry\.v0\.schema\.json"' -Message "VRM telemetry route map should point to the result contract"
  Assert-TextMatch -Text $vrmTelemetryRoutes -Pattern '"thought_core"' -Message "VRM telemetry route map should be discoverable by Thought Core"
  Assert-TextMatch -Text $vrmTelemetryRoutes -Pattern '"model_state_readback_only"\s*:\s*true' -Message "VRM telemetry route map should stay model-state readback only"
  Assert-TextMatch -Text $vrmTelemetryRoutes -Pattern '"runtime_execution_authority"\s*:\s*false' -Message "VRM telemetry route map should not authorize runtime execution"
  Assert-TextMatch -Text $vrmTelemetryRoutes -Pattern '"expression_visible_pass_authority"\s*:\s*false' -Message "VRM telemetry route map should not become expression-visible pass authority"
  Assert-TextMatch -Text $vrmTelemetryRoutes -Pattern '"roi_or_threshold_authority"\s*:\s*false' -Message "VRM telemetry route map should not mutate ROI or thresholds"
  Assert-TextMatch -Text $vrmTelemetryRoutes -Pattern '"telemetry_focus"\s*:\s*"bone_basis_tracks"' -Message "VRM telemetry route map should expose bone/basis telemetry focus"
  Assert-TextMatch -Text $vrmTelemetryRoutes -Pattern 'bone_basis_readback' -Message "VRM telemetry route map should reserve future bone/basis runtime route without implementing it"
  Assert-TextMatch -Text $vrmTelemetryRoutes -Pattern '"raw_bvh_shared"\s*:\s*false[\s\S]{0,180}"raw_transform_trace_shared"\s*:\s*false[\s\S]{0,180}"full_skeleton_shared"\s*:\s*false' -Message "VRM telemetry route map should preserve raw export boundaries"
  Assert-TextMatch -Text $vrmTelemetryRoutesSchema -Pattern '"schema_version"\s*:\s*\{[\s\S]{0,80}"const"\s*:\s*"vrm_model_telemetry_consumer_routes\.v0"' -Message "VRM telemetry route schema should define schema version"
  Assert-TextMatch -Text $vrmTelemetryRoutesSchema -Pattern '"result_contract_ref"\s*:\s*\{[\s\S]{0,140}"const"\s*:\s*"contracts/vrm_model_telemetry/vrm_model_telemetry\.v0\.schema\.json"' -Message "VRM telemetry route schema should lock result contract"
  Assert-TextMatch -Text $vrmTelemetryRoutesSchema -Pattern '"runtime_execution_authority"\s*:\s*\{[\s\S]{0,80}"const"\s*:\s*false' -Message "VRM telemetry route schema should reject runtime execution authority"
  Assert-TextMatch -Text $vrmTelemetryRoutesSchema -Pattern '"self_mirror_authority"\s*:\s*\{[\s\S]{0,80}"const"\s*:\s*false' -Message "VRM telemetry route schema should reject Self Mirror authority"
  Assert-TextMatch -Text $vrmTelemetryRoutesSchema -Pattern '"bone_basis_tracks"' -Message "VRM telemetry route schema should allow bone/basis focus"
  Assert-TextMatch -Text $vrmTelemetrySurface -Pattern "does not prove|cannot say[\s\S]{0,220}Self Mirror|not_self_mirror_pass" -Message "VRM telemetry docs should not upgrade model state into visual proof"
  Write-Host "README first-run guidance static ok"
}

function Test-AudioSelfOutputObservationContractStatic {
  Write-TestStep "Audio self-output observation contract static checks"

  $schemaPath = Join-Path $RepoRoot "contracts\audio_self_output_observation\audio_self_output_observation.v0.schema.json"
  $examplePath = Join-Path $RepoRoot "contracts\audio_self_output_observation\examples\source_static_self_output_blocked.example.json"
  $negativeExamplePath = Join-Path $RepoRoot "contracts\audio_self_output_observation\examples\local_sample_recognition_ambiguous_negative.example.json"
  $lowConfidenceExamplePath = Join-Path $RepoRoot "contracts\audio_self_output_observation\examples\local_sample_recognition_low_confidence_negative.example.json"
  Assert-PathPresent -Path $schemaPath
  Assert-PathPresent -Path $examplePath
  Assert-PathPresent -Path $negativeExamplePath
  Assert-PathPresent -Path $lowConfidenceExamplePath

  $schema = Get-Content -Raw -LiteralPath $schemaPath
  $exampleText = Get-Content -Raw -LiteralPath $examplePath
  $negativeExampleText = Get-Content -Raw -LiteralPath $negativeExamplePath
  $lowConfidenceExampleText = Get-Content -Raw -LiteralPath $lowConfidenceExamplePath
  $contractsReadme = Get-Content -Raw -LiteralPath (Join-Path $RepoRoot "contracts\README.md")
  $schemaJson = $schema | ConvertFrom-Json
  $example = $exampleText | ConvertFrom-Json
  $negativeExample = $negativeExampleText | ConvertFrom-Json
  $lowConfidenceExample = $lowConfidenceExampleText | ConvertFrom-Json

  if ([string]$schemaJson.properties.schema_version.const -ne "audio_self_output_observation.v0") {
    throw "audio self-output schema should lock schema_version"
  }
  if ([string]$example.schema_version -ne "audio_self_output_observation.v0") {
    throw "audio self-output example should use the v0 schema"
  }
  if ([string]$example.speaker_role -ne "system_self_output") {
    throw "audio self-output example should classify speaker_role as system_self_output"
  }
  if ([string]$example.route -ne "self_output_observation") {
    throw "audio self-output example should use the self_output_observation route"
  }
  if ($example.may_start_user_turn -ne $false -or $example.turn_adoption_authority -ne $false) {
    throw "audio self-output example should not start or authorize a user turn"
  }
  if ([string]$example.adoption_decision_owner -ne "ai_talk_core" -or [string]$example.pre_turn_result.decision_owner -ne "ai_talk_core") {
    throw "audio self-output adoption decision should belong to AI Talk Core"
  }
  if ($example.pre_turn_result.turn_input_materialized -ne $false -or $example.pre_turn_result.normal_turn_adoption_blocked -ne $true) {
    throw "audio self-output pre-turn result should block normal turn materialization"
  }
  if ($null -ne $example.pre_turn_result.thought_core_turn_input_ref) {
    throw "audio self-output example should not contain a Thought Core turn input ref"
  }
  if ($null -ne $example.refs.heard_text_observation_ref) {
    throw "audio self-output v0 example should keep heard_text_observation_ref null"
  }
  if ($example.transcript_ref_policy.transcript_ref_allowed -ne $false -or
      [string]$example.transcript_ref_policy.transcript_ref_policy -ne "no_shared_transcript_ref" -or
      [string]$example.transcript_ref_policy.retention_class -ne "none_shared") {
    throw "audio self-output transcript ref policy should keep v0 transcript refs unshared"
  }
  foreach ($recognitionExample in @($example, $negativeExample, $lowConfidenceExample)) {
    if (-not ([string]$recognitionExample.local_sample_recognition_summary.source_label).StartsWith("voice.")) {
      throw "local sample recognition summary source_label should be a redacted voice asset label"
    }
    if ([string]$recognitionExample.local_sample_recognition_summary.source_label_policy -ne "stable_local_media_asset_id_only") {
      throw "local sample recognition summary should use stable local media asset labels only"
    }
    if ($recognitionExample.local_sample_recognition_summary.turn_materialization_allowed -ne $false -or
        $recognitionExample.local_sample_recognition_summary.thought_core_adoption_allowed -ne $false) {
      throw "local sample recognition summary should not materialize or adopt a Thought Core turn"
    }
    foreach ($field in @(
      "raw_audio_shared",
      "raw_audio_persisted",
      "raw_transcript_shared",
      "literal_text_shared",
      "private_path_shared",
      "provider_payload_shared",
      "provider_or_network_stt_used",
      "filename_or_extension_shared",
      "browser_storage_key_shared",
      "home_control_or_action_authority"
    )) {
      if ($recognitionExample.local_sample_recognition_summary.redaction_guards.$field -ne $false) {
        throw "local sample recognition summary redaction guard should keep $field false"
      }
    }
  }
  if ([string]$negativeExample.local_sample_recognition_summary.recognized_text_class -ne "ambiguous" -or
      [string]$negativeExample.local_sample_recognition_summary.confidence_bucket -ne "low" -or
      [string]$negativeExample.local_sample_recognition_summary.stt_window_class -ne "overlaps_system_playback_or_cooldown") {
    throw "local sample negative fixture should keep ambiguous low-confidence overlap as a held diagnostic"
  }
  if ([string]$lowConfidenceExample.local_sample_recognition_summary.recognized_text_class -ne "low_confidence" -or
      [string]$lowConfidenceExample.local_sample_recognition_summary.confidence_bucket -ne "low" -or
      [string]$lowConfidenceExample.local_sample_recognition_summary.stt_window_class -ne "outside_system_playback_window") {
    throw "local sample negative fixture should keep low-confidence recognition as a held diagnostic"
  }

  foreach ($guardExample in @($example, $negativeExample, $lowConfidenceExample)) {
    foreach ($field in @(
      "build_handoff_payload_reached",
      "save_handoff_bundle_reached",
      "runner_handoff_payload_created",
      "redacted_turn_input_created",
      "thought_core_turn_input_created",
      "older_session_releases_newer_latch",
      "newer_session_releases_older_cooling_latch",
      "transcript_like_ref_materialized",
      "recognizer_raw_transcript_materialized",
      "recognizer_private_path_materialized",
      "recognizer_provider_payload_materialized",
      "recognizer_browser_storage_key_materialized"
    )) {
      if ($guardExample.no_live_fixture_guards.$field -ne $false) {
        throw "audio self-output no-live fixture guard should keep $field false"
      }
    }
  }

  Assert-TextMatch -Text $schema -Pattern '"may_start_user_turn"[\s\S]{0,80}"const"\s*:\s*false' -Message "audio self-output schema should reject may_start_user_turn=true"
  Assert-TextMatch -Text $schema -Pattern '"turn_adoption_authority"[\s\S]{0,80}"const"\s*:\s*false' -Message "audio self-output schema should reject turn adoption authority"
  Assert-TextNotMatch -Text $schema -Pattern "adoptable_user_turn" -Message "audio self-output schema should not expose adoptable_user_turn"
  Assert-TextMatch -Text $schema -Pattern '"turn_input_materialized"[\s\S]{0,80}"const"\s*:\s*false' -Message "audio self-output schema should prevent turn input materialization"
  Assert-TextMatch -Text $schema -Pattern '"thought_core_turn_input_ref"[\s\S]{0,80}"type"\s*:\s*"null"' -Message "audio self-output schema should force Thought Core turn refs to null"
  Assert-TextMatch -Text $schema -Pattern '"missing_speaker_role"[\s\S]{0,160}"missing_route"|missing_route[\s\S]{0,160}missing_speaker_role' -Message "audio self-output schema should represent missing speaker and route hold reasons separately"
  Assert-TextMatch -Text $schema -Pattern '"build_handoff_payload_reached"[\s\S]{0,80}"const"\s*:\s*false' -Message "audio self-output schema should guard build_handoff_payload leakage"
  Assert-TextMatch -Text $schema -Pattern '"save_handoff_bundle_reached"[\s\S]{0,80}"const"\s*:\s*false' -Message "audio self-output schema should guard save_handoff_bundle leakage"
  Assert-TextMatch -Text $schema -Pattern '"runner_handoff_payload_created"[\s\S]{0,80}"const"\s*:\s*false' -Message "audio self-output schema should guard runner handoff leakage"
  Assert-TextMatch -Text $schema -Pattern '"redacted_turn_input_created"[\s\S]{0,80}"const"\s*:\s*false' -Message "audio self-output schema should guard redacted_turn_input leakage"
  Assert-TextMatch -Text $schema -Pattern '"thought_core_turn_input_created"[\s\S]{0,80}"const"\s*:\s*false' -Message "audio self-output schema should guard Thought Core TurnInput leakage"
  Assert-TextMatch -Text $schema -Pattern '"older_session_releases_newer_latch"[\s\S]{0,80}"const"\s*:\s*false' -Message "audio self-output schema should guard old-session/new-latch release"
  Assert-TextMatch -Text $schema -Pattern '"newer_session_releases_older_cooling_latch"[\s\S]{0,80}"const"\s*:\s*false' -Message "audio self-output schema should guard new-session/old-cooling release"
  Assert-TextMatch -Text $schema -Pattern '"local_sample_recognition_summary"' -Message "audio self-output schema should define local sample recognition summaries"
  Assert-TextMatch -Text $schema -Pattern '"recognized_text_class"[\s\S]{0,260}"present_redacted"' -Message "local sample summary should use recognized text classes, not transcript bodies"
  Assert-TextMatch -Text $schema -Pattern '"language_bucket"[\s\S]{0,240}"ja"[\s\S]{0,80}"en"' -Message "local sample summary should carry language buckets"
  Assert-TextMatch -Text $schema -Pattern '"confidence_bucket"[\s\S]{0,260}"low"[\s\S]{0,80}"medium"[\s\S]{0,80}"high"' -Message "local sample summary should carry confidence buckets"
  Assert-TextMatch -Text $schema -Pattern '"turn_materialization_allowed"[\s\S]{0,80}"const"\s*:\s*false' -Message "local sample summary should not materialize turns"
  Assert-TextMatch -Text $schema -Pattern '"thought_core_adoption_allowed"[\s\S]{0,80}"const"\s*:\s*false' -Message "local sample summary should not authorize Thought Core adoption"
  Assert-TextMatch -Text $schema -Pattern '"literal_text_shared"[\s\S]{0,80}"const"\s*:\s*false' -Message "local sample summary should reject literal text sharing"
  Assert-TextMatch -Text $schema -Pattern '"provider_or_network_stt_used"[\s\S]{0,80}"const"\s*:\s*false' -Message "local sample summary should reject provider/network STT"
  Assert-TextMatch -Text $schema -Pattern '"filename_or_extension_shared"[\s\S]{0,80}"const"\s*:\s*false' -Message "local sample summary should reject filenames and extensions"
  Assert-TextMatch -Text $schema -Pattern '"heard_text_observation_ref"[\s\S]{0,80}"type"\s*:\s*"null"' -Message "audio self-output schema should force heard text refs to null"
  Assert-TextMatch -Text $schema -Pattern '"transcript_ref_allowed"[\s\S]{0,80}"const"\s*:\s*false' -Message "audio self-output schema should reject shared transcript refs"
  Assert-TextMatch -Text $schema -Pattern '"transcript_ref_policy"[\s\S]{0,80}"const"\s*:\s*"no_shared_transcript_ref"' -Message "audio self-output schema should name no_shared_transcript_ref"
  Assert-TextMatch -Text $schema -Pattern '"retention_class"[\s\S]{0,80}"const"\s*:\s*"none_shared"' -Message "audio self-output schema should use none_shared retention"
  Assert-TextMatch -Text $schema -Pattern '"system_refs_are_opaque_non_dereferenceable"[\s\S]{0,80}"const"\s*:\s*true' -Message "audio self-output schema should require opaque system refs"
  Assert-TextMatch -Text $schema -Pattern '"system_refs_may_contain_text"[\s\S]{0,80}"const"\s*:\s*false' -Message "audio self-output schema should forbid text in system refs"
  Assert-TextMatch -Text $schema -Pattern '"system_refs_may_contain_provider_ids"[\s\S]{0,80}"const"\s*:\s*false' -Message "audio self-output schema should forbid provider ids in refs"
  Assert-TextMatch -Text $schema -Pattern '"system_refs_may_contain_paths"[\s\S]{0,80}"const"\s*:\s*false' -Message "audio self-output schema should forbid paths in refs"
  Assert-TextMatch -Text $schema -Pattern '"system_refs_may_contain_browser_storage_keys"[\s\S]{0,80}"const"\s*:\s*false' -Message "audio self-output schema should forbid browser storage keys in refs"
  Assert-TextMatch -Text $schema -Pattern '"system_refs_may_contain_audio_or_media_paths"[\s\S]{0,80}"const"\s*:\s*false' -Message "audio self-output schema should forbid audio/media paths in refs"
  Assert-TextNotMatch -Text ($exampleText + $negativeExampleText + $lowConfidenceExampleText) -Pattern 'C:\\|\\\\|/Users/|localStorage|sessionStorage|provider:[A-Za-z0-9_-]+|provider_payload_(id|ref|body)|"provider_id"\s*:|\.wav|\.mp3|\.mp4|"transcript_body"\s*:|"recognized_text_body"\s*:|"raw_transcript_text"\s*:|"audio_file_path"\s*:' -Message "audio self-output examples should not contain private paths, browser keys, media filenames, provider ids, provider payloads, transcript bodies, recognized text bodies, or audio file paths"
  Assert-TextMatch -Text $contractsReadme -Pattern "audio_self_output_observation/audio_self_output_observation\.v0\.schema\.json" -Message "Contracts README should list audio self-output observation"
  Assert-TextMatch -Text $contractsReadme -Pattern 'cannot\s+materialize\s+a\s+normal\s+Thought Core `TurnInput`|cannot[\s\S]{0,120}Thought Core `TurnInput`' -Message "Contracts README should state self-output cannot materialize a Thought Core turn"
  Assert-TextMatch -Text $contractsReadme -Pattern "local-sample recognition summaries|local sample recognition summaries" -Message "Contracts README should mention local-sample recognition summary boundaries"

  Write-Host "Audio self-output observation contract static ok"
}

function Test-AcceptedUserSpeechCandidateRuntimeSessionJoinContractStatic {
  Write-TestStep "Accepted user speech candidate post-decision audit contract checks"

  $contractDir = Join-Path $RepoRoot "contracts\accepted_user_speech_candidate_input_gate"
  $schemaPath = Join-Path $contractDir "accepted_user_speech_candidate_input_gate.v0.schema.json"
  $vectorsPath = Join-Path $contractDir "examples\runtime_session_join_vectors.v0.json"
  Assert-PathPresent -Path $schemaPath
  Assert-PathPresent -Path $vectorsPath
  $schemaText = Get-Content -Raw -LiteralPath $schemaPath
  $vectorsText = Get-Content -Raw -LiteralPath $vectorsPath
  $schema = $schemaText | ConvertFrom-Json -Depth 100
  $vectors = $vectorsText | ConvertFrom-Json -Depth 100

  $schemaComment = [string]$schema.PSObject.Properties['$comment'].Value
  if ($schemaComment -notmatch 'post-decision audit record only' -or
      $schemaComment -notmatch 'cannot mint, grant, contain, or transport' -or
      $schemaComment -notmatch 'process-local nonserializable one-use capability') {
    throw "serialized gate contract should be explicitly audit-only and non-capability-bearing"
  }
  if ([string]$vectors.serialized_contract_role -ne "post_decision_audit_only" -or
      [string]$vectors.process_local_capability_rule -ne "nonserializable_one_use_capability_owned_by_ai_talk_core_input_gate" -or
      [string]$vectors.proof_ceiling -ne "source_static_post_decision_audit_contract_only" -or
      $vectors.raw_private_publication_flags -ne $false) {
    throw "runtime vectors should preserve the audit-only process-local capability boundary"
  }

  $sourceStaticPaths = @(
    Join-Path $contractDir "examples\source_static_accepted_prepared_sample_candidate.example.json"
    Join-Path $contractDir "examples\source_static_accepted_private_user_speech_candidate.example.json"
    Join-Path $contractDir "examples\source_static_blocked_low_confidence_candidate.example.json"
    Join-Path $contractDir "examples\source_static_blocked_redaction_only_summary.example.json"
    Join-Path $contractDir "examples\source_static_blocked_self_output_candidate.example.json"
  )
  foreach ($examplePath in $sourceStaticPaths) {
    Assert-PathPresent -Path $examplePath
    $exampleText = Get-Content -Raw -LiteralPath $examplePath
    if (-not (Test-Json -Json $exampleText -SchemaFile $schemaPath -ErrorAction SilentlyContinue)) {
      throw "existing source-static example should remain schema valid: $examplePath"
    }
    $example = $exampleText | ConvertFrom-Json -Depth 100
    if ([string]$example.proof_layer -ne "source_static_contract_test_only" -or
        "not_runtime_turn" -notin @($example.non_claims) -or
        $example.acceptance_decision.thought_core_turninput_materialized -ne $false -or
        [int]$example.acceptance_decision.thought_core_turninput_count -ne 0 -or
        $null -ne (Get-OptionalProperty -Object $example -Name "runtime_session_join") -or
        $null -ne (Get-OptionalProperty -Object $example -Name "post_decision_audit")) {
      throw "source-static examples should stay non-runtime, non-materializing, and compatible without live audit fields"
    }
  }

  $requiredCaseIds = @(
    "canonical_positive",
    "missing_session_join",
    "session_id_mismatch",
    "generation_mismatch",
    "stale_session",
    "active_system_speech_session",
    "self_output_cooldown",
    "duplicate_replay",
    "compare_and_release_failure",
    "forged_current_match",
    "forged_owner",
    "forged_cas_success",
    "stale_after_check_toctou",
    "aec_vad_only",
    "contradictory_top_level_vs_one_use",
    "near_end_byte_count_inconsistent",
    "near_end_window_bound_exceeded",
    "forged_ref_namespace",
    "forged_private_candidate_id_namespace",
    "forged_private_recognition_summary_ref_namespace"
  )
  $caseIds = @($vectors.cases | ForEach-Object { [string]$_.case_id })
  if ($caseIds.Count -ne $requiredCaseIds.Count -or @($caseIds | Select-Object -Unique).Count -ne $caseIds.Count) {
    throw "runtime session join vectors should contain one unique full instance per canonical case"
  }
  foreach ($requiredCaseId in $requiredCaseIds) {
    if ($requiredCaseId -notin $caseIds) {
      throw "runtime session join vectors should include full instance $requiredCaseId"
    }
  }

  $defs = $schema.PSObject.Properties['$defs'].Value
  if ([string]$defs.candidate_id.pattern -ne '^ausc_[A-Za-z0-9_.:-]+$' -or
      [string]$defs.opaque_ref.pattern -ne '^[a-z][a-z0-9_.:-]*:[A-Za-z0-9_.:-]+$') {
    throw "generic source-static candidate_id and opaque_ref definitions should remain unchanged"
  }
  $systemSessionPattern = [string]$defs.system_speech_session_ref.pattern
  $playbackPattern = [string]$defs.playback_event_ref.pattern
  $selfOutputPattern = [string]$defs.self_output_observation_ref.pattern
  $privateCandidatePattern = [string]$defs.private_live_candidate_id.pattern
  $privateRecognitionSummaryPattern = [string]$defs.private_live_recognition_summary_ref.pattern
  if ($systemSessionPattern -ne '^system-speech-session:sss_[a-f0-9]{32}$' -or
      $playbackPattern -ne '^playback-event:pe_[a-f0-9]{32}$' -or
      $selfOutputPattern -ne '^self-output-observation:aso_[a-f0-9]{32}$' -or
      $privateCandidatePattern -ne '^ausc_live:cid_[a-f0-9]{32}$' -or
      $privateRecognitionSummaryPattern -ne '^user-speech-candidate-summary:rsc_[a-f0-9]{32}$') {
    throw "private live identifiers and runtime join refs should use fixed bounded system-minted namespaces"
  }

  function Get-RuntimeSessionJoinSemanticResult {
    param([Parameter(Mandatory = $true)]$Instance)

    $valid = $true
    $join = $Instance.runtime_session_join.system_speech_session_join
    $nearEnd = $Instance.runtime_session_join.near_end_evidence
    $oneUse = $Instance.runtime_session_join.one_use_gate
    $audit = $Instance.post_decision_audit
    $inputStatus = [string]$Instance.input_gate.input_gate_decision_class
    $acceptanceStatus = [string]$Instance.acceptance_decision.acceptance_status

    if ([string]$Instance.source_kind -ne "user_speech_candidate" -or
        [string]$Instance.candidate_route -ne "private_user_speech_input_gate" -or
        [string]$Instance.speaker_role -ne "user_candidate" -or
        [string]$Instance.input_gate.input_gate_decision_owner -ne "ai_talk_core_input_gate" -or
        [string]$oneUse.decision_owner -ne "ai_talk_core_input_gate" -or
        [string]$audit.process_local_capability_owner -ne "ai_talk_core_input_gate" -or
        [string]$audit.serialized_contract_role -ne "post_decision_audit_only" -or
        [string]$audit.materialization_executor -ne "later_ai_talk_core_process_local_code" -or
        $audit.process_local_one_use_capability_serialized -ne $false -or
        $audit.capability_mint_authority -ne $false -or
        $audit.capability_grant_authority -ne $false -or
        $audit.capability_transport_authority -ne $false -or
        $audit.thought_core_turninput_materialized -ne $false -or
        [int]$audit.thought_core_turninput_count -ne 0 -or
        $Instance.acceptance_decision.thought_core_turninput_materialized -ne $false -or
        [int]$Instance.acceptance_decision.thought_core_turninput_count -ne 0 -or
        $null -ne $Instance.acceptance_decision.thought_core_turninput_ref -or
        $Instance.raw_private_publication_flags -ne $false) {
      $valid = $false
    }
    if ([string]$nearEnd.evidence_class -ne "bounded_processed_near_end_candidate" -or
        [int]$nearEnd.window_ms -lt 100 -or [int]$nearEnd.window_ms -gt 5000 -or
        [int]$nearEnd.frame_bytes -ne 320 -or
        [int]$nearEnd.packet_count -lt 1 -or
        [int]$nearEnd.packet_count -gt [math]::Floor([int]$nearEnd.window_ms / 10) -or
        [int]$nearEnd.processed_byte_count -ne ([int]$nearEnd.packet_count * [int]$nearEnd.frame_bytes) -or
        [int]$nearEnd.processed_byte_count -gt 160000 -or
        [string]$nearEnd.storage_class -ne "in_memory_ephemeral" -or
        $nearEnd.aec_or_vad_turn_input_authority -ne $false) {
      $valid = $false
    }
    foreach ($refCheck in @(
      @($join.observed_system_speech_session_id, $systemSessionPattern),
      @($join.active_system_speech_session_id, $systemSessionPattern),
      @($join.playback_event_ref, $playbackPattern),
      @($join.self_output_observation_ref, $selfOutputPattern)
    )) {
      if ($null -ne $refCheck[0] -and [string]$refCheck[0] -notmatch [string]$refCheck[1]) {
        $valid = $false
      }
    }
    if ([string]$join.self_output_observation_schema_version -ne "audio_self_output_observation.v0" -or
        $join.opaque_refs_non_dereferenceable -ne $true -or
        [string]$Instance.candidate_id -notmatch $privateCandidatePattern -or
        [string]$Instance.recognition_summary.recognition_summary_ref -notmatch $privateRecognitionSummaryPattern -or
        [string]$oneUse.compared_candidate_id -notmatch $privateCandidatePattern -or
        [string]$oneUse.compared_candidate_id -ne [string]$Instance.candidate_id -or
        $inputStatus -ne $acceptanceStatus) {
      $valid = $false
    }

    if ($acceptanceStatus -eq "accepted_user_speech_candidate") {
      if ([string]$oneUse.acceptance_status -ne $acceptanceStatus -or
          [string]$audit.output_status -ne "eligible_for_later_process_local_materialization" -or
          $Instance.acceptance_decision.may_materialize_thought_core_turninput -ne $true -or
          $oneUse.may_materialize_thought_core_turninput -ne $true -or
          $audit.may_materialize_thought_core_turninput -ne $true -or
          $audit.internal_atomic_compare_completed -ne $true -or
          [string]$Instance.self_output_context.self_output_correlation_class -ne "not_self_output" -or
          [string]$Instance.self_output_context.session_join_class -ne "current_active_session_explicitly_excluded" -or
          [string]$join.observed_system_speech_session_id -ne [string]$join.active_system_speech_session_id -or
          [int]$join.observed_generation -ne [int]$join.active_generation -or
          [string]$join.session_join_status -ne "current_match" -or
          [string]$join.post_compare_session_status -ne "current_unchanged" -or
          [string]$join.self_output_correlation_class -ne "not_self_output" -or
          [string]$join.active_session_exclusion_status -ne "explicitly_excluded_from_candidate" -or
          [string]$join.cooldown_status -ne "clear" -or
          [string]$oneUse.candidate_identity_compare_status -ne "matched" -or
          [string]$oneUse.session_identity_compare_status -ne "matched" -or
          [string]$oneUse.generation_compare_status -ne "matched" -or
          [string]$oneUse.candidate_use_state -ne "unused" -or
          [string]$oneUse.compare_and_release_status -ne "succeeded" -or
          [string]$oneUse.one_use_consume_status -ne "consumed") {
        $valid = $false
      }
      return [pscustomobject]@{
        semantic_result = $(if ($valid) { "accepted_post_decision_audit" } else { "validation_rejected" })
        materialization_eligibility_audit = [bool]$valid
      }
    }

    if (-not $acceptanceStatus.StartsWith("blocked_") -or
        [string]$oneUse.acceptance_status -ne $acceptanceStatus -or
        [string]$audit.output_status -ne $acceptanceStatus -or
        $Instance.acceptance_decision.may_materialize_thought_core_turninput -ne $false -or
        $oneUse.may_materialize_thought_core_turninput -ne $false -or
        $audit.may_materialize_thought_core_turninput -ne $false) {
      $valid = $false
    }
    switch ($acceptanceStatus) {
      "blocked_session_join_missing" {
        if ([string]$join.session_join_status -ne "missing" -or
            $null -ne $join.observed_system_speech_session_id -or
            $null -ne $join.observed_generation) { $valid = $false }
      }
      "blocked_session_join_mismatch" {
        $idMismatch = [string]$join.observed_system_speech_session_id -ne [string]$join.active_system_speech_session_id
        $generationMismatch = [int]$join.observed_generation -ne [int]$join.active_generation
        if ([string]$join.session_join_status -ne "mismatch" -or (-not $idMismatch -and -not $generationMismatch)) { $valid = $false }
      }
      "blocked_session_join_stale" {
        if ([string]$join.session_join_status -ne "stale" -or [string]$oneUse.generation_compare_status -ne "stale") { $valid = $false }
      }
      "blocked_active_system_speech_session" {
        if ([string]$join.self_output_correlation_class -ne "self_output" -or
            [string]$join.active_session_exclusion_status -ne "active_system_speech_session") { $valid = $false }
      }
      "blocked_self_output_cooldown" {
        if ([string]$join.cooldown_status -ne "active") { $valid = $false }
      }
      "blocked_duplicate_candidate" {
        if ([string]$oneUse.candidate_use_state -ne "duplicate" -or [string]$oneUse.one_use_consume_status -ne "duplicate") { $valid = $false }
      }
      "blocked_compare_and_release_failed" {
        if ([string]$oneUse.compare_and_release_status -ne "failed" -or [string]$oneUse.one_use_consume_status -ne "failed") { $valid = $false }
      }
      "blocked_session_join_toctou" {
        if ([string]$join.post_compare_session_status -ne "stale_after_check" -or [string]$oneUse.compare_and_release_status -ne "failed") { $valid = $false }
      }
      default { $valid = $false }
    }
    return [pscustomobject]@{
      semantic_result = $(if ($valid) { $acceptanceStatus } else { "validation_rejected" })
      materialization_eligibility_audit = $false
    }
  }

  foreach ($case in @($vectors.cases)) {
    $instanceText = $case.instance | ConvertTo-Json -Depth 100 -Compress
    $schemaValid = [bool](Test-Json -Json $instanceText -SchemaFile $schemaPath -ErrorAction SilentlyContinue)
    $semantic = Get-RuntimeSessionJoinSemanticResult -Instance $case.instance
    if ($schemaValid -ne [bool]$case.expected_schema_valid) {
      throw "runtime case $($case.case_id) schema validity should be $($case.expected_schema_valid)"
    }
    $actualSemanticResult = $(if ($schemaValid) { [string]$semantic.semantic_result } else { "validation_rejected" })
    $actualEligibility = $schemaValid -and [bool]$semantic.materialization_eligibility_audit
    if ($actualSemanticResult -ne [string]$case.expected_semantic_result -or
        $actualEligibility -ne [bool]$case.expected_materialization_eligibility_audit) {
      throw "runtime case $($case.case_id) should produce $($case.expected_semantic_result) with eligibility audit $($case.expected_materialization_eligibility_audit)"
    }
    if (-not $actualEligibility -and
        ($case.instance.acceptance_decision.thought_core_turninput_materialized -ne $false -or
         [int]$case.instance.acceptance_decision.thought_core_turninput_count -ne 0 -or
         $case.instance.post_decision_audit.thought_core_turninput_materialized -ne $false -or
         [int]$case.instance.post_decision_audit.thought_core_turninput_count -ne 0)) {
      throw "non-eligible runtime case $($case.case_id) should keep TurnInput materialization at zero"
    }
  }

  Assert-TextNotMatch -Text $vectorsText -Pattern 'C:\\|/Users/|localStorage|sessionStorage|\.wav|\.mp3|\.pcm|"capability_token"\s*:|"provider_id"\s*:|"device_(name|id)"\s*:' -Message "runtime audit vectors should not contain paths, storage keys, media filenames, capability tokens, provider ids, or device identity"
  Assert-TextMatch -Text $schemaText -Pattern '"process_local_one_use_capability_serialized"[\s\S]{0,80}"const"\s*:\s*false' -Message "schema should forbid serializing the process-local one-use capability"
  Assert-TextMatch -Text $schemaText -Pattern '"capability_mint_authority"[\s\S]{0,80}"const"\s*:\s*false' -Message "serialized audit should not mint authority"
  Assert-TextMatch -Text $schemaText -Pattern '"capability_grant_authority"[\s\S]{0,80}"const"\s*:\s*false' -Message "serialized audit should not grant authority"
  Assert-TextMatch -Text $schemaText -Pattern '"capability_transport_authority"[\s\S]{0,80}"const"\s*:\s*false' -Message "serialized audit should not transport authority"

  Write-Host "Accepted user speech candidate post-decision audit contract ok"
}

function Test-LocalOfflineRecognizerRedactedAdapterContractStatic {
  Write-TestStep "Local offline recognizer redacted adapter contract static checks"

  $contractDir = Join-Path $RepoRoot "contracts\local_offline_recognizer_redacted_adapter"
  $schemaPath = Join-Path $contractDir "local_offline_recognizer_redacted_adapter.v0.schema.json"
  $examplesDir = Join-Path $contractDir "examples"
  $examplePaths = @(
    Join-Path $examplesDir "source_static_pass_candidate.example.json"
    Join-Path $examplesDir "source_static_missing_model_blocked.example.json"
    Join-Path $examplesDir "source_static_download_needed_blocked.example.json"
    Join-Path $examplesDir "source_static_transcript_oriented_cli_blocked.example.json"
    Join-Path $examplesDir "source_static_raw_transcript_or_text_exposure_blocked.example.json"
    Join-Path $examplesDir "source_static_path_exposure_blocked.example.json"
    Join-Path $examplesDir "source_static_private_metadata_exposure_blocked.example.json"
    Join-Path $examplesDir "source_static_provider_or_browser_required_blocked.example.json"
    Join-Path $examplesDir "source_static_playback_or_capture_required_blocked.example.json"
    Join-Path $examplesDir "source_static_adapter_direct_turn_attempt_blocked.example.json"
  )

  Assert-PathPresent -Path $schemaPath
  foreach ($examplePath in $examplePaths) {
    Assert-PathPresent -Path $examplePath
  }

  $schemaText = Get-Content -Raw -LiteralPath $schemaPath
  $schema = $schemaText | ConvertFrom-Json
  $contractsReadme = Get-Content -Raw -LiteralPath (Join-Path $RepoRoot "contracts\README.md")
  $examples = @()
  $combinedExampleText = ""
  foreach ($examplePath in $examplePaths) {
    $exampleText = Get-Content -Raw -LiteralPath $examplePath
    $combinedExampleText += "`n$exampleText"
    $examples += @($exampleText | ConvertFrom-Json)
  }

  if ([string]$schema.properties.schema_version.const -ne "local_offline_recognizer_redacted_adapter.v0") {
    throw "local offline recognizer adapter schema should lock schema_version"
  }
  Assert-TextMatch -Text $schemaText -Pattern '"redaction_before_artifact_required"[\s\S]{0,80}"const"\s*:\s*true' -Message "local offline recognizer adapter should require redaction before artifacts"
  Assert-TextMatch -Text $schemaText -Pattern '"shared_output_policy"[\s\S]{0,80}"const"\s*:\s*"class_bucket_opaque_ref_only"' -Message "local offline recognizer adapter should limit shared output to classes, buckets, and opaque refs"
  Assert-TextMatch -Text $schemaText -Pattern '"fail_closed_on_unredactable_output"[\s\S]{0,80}"const"\s*:\s*true' -Message "local offline recognizer adapter should fail closed on unredactable output"
  Assert-TextMatch -Text $schemaText -Pattern '"transcript_oriented_output_allowed"[\s\S]{0,80}"const"\s*:\s*false' -Message "local offline recognizer adapter should reject transcript-oriented output"
  Assert-TextMatch -Text $schemaText -Pattern '"provider_or_network_stt_allowed"[\s\S]{0,80}"const"\s*:\s*false' -Message "local offline recognizer adapter should reject provider/network STT"
  Assert-TextMatch -Text $schemaText -Pattern '"browser_stt_allowed"[\s\S]{0,80}"const"\s*:\s*false' -Message "local offline recognizer adapter should reject browser STT"
  Assert-TextMatch -Text $schemaText -Pattern '"playback_or_capture_allowed"[\s\S]{0,80}"const"\s*:\s*false' -Message "local offline recognizer adapter should reject playback/capture"
  Assert-TextMatch -Text $schemaText -Pattern '"model_download_allowed"[\s\S]{0,80}"const"\s*:\s*false' -Message "local offline recognizer adapter should reject model download"
  Assert-TextMatch -Text $schemaText -Pattern '"source_label_policy"[\s\S]{0,80}"const"\s*:\s*"stable_local_media_asset_id_only"' -Message "local offline recognizer adapter should accept stable source labels only"
  Assert-TextMatch -Text $schemaText -Pattern '"source_label"[\s\S]{0,260}Opaque stable local media id only[\s\S]{0,260}must not encode transcript text' -Message "local offline recognizer adapter should document source_label as an opaque non-transcript id"
  if ([string]$schema.'$defs'.source_label.pattern -ne '^voice\.(sample|local_sample|synthetic_sample|fixture)_[a-z0-9_:-]+$') {
    throw "local offline recognizer adapter source_label should be constrained to opaque sample-style ids"
  }
  Assert-TextNotMatch -Text $schemaText -Pattern '"turn_boundary"|"turn_materialization_allowed"|"thought_core_adoption_allowed"|"may_start_user_turn"|"turn_materialization_attempted"' -Message "local offline recognizer adapter should not use broad Thought Core adoption or turn materialization fields"
  Assert-TextNotMatch -Text $combinedExampleText -Pattern '"turn_boundary"|"turn_materialization_allowed"|"thought_core_adoption_allowed"|"may_start_user_turn"|"turn_materialization_attempted"|"not_thought_core_turn_input"|"not_home_control_action"' -Message "local offline recognizer examples should not use broad Thought Core adoption, turn materialization, or action non-claim names"
  Assert-TextMatch -Text $schemaText -Pattern '"adapter_boundary"[\s\S]{0,260}Adapter-local boundary only' -Message "local offline recognizer adapter should describe an adapter-local boundary"
  Assert-TextMatch -Text $schemaText -Pattern '"adapter_direct_turn_materialization_allowed"[\s\S]{0,80}"const"\s*:\s*false' -Message "local offline recognizer adapter should not directly materialize turns"
  Assert-TextMatch -Text $schemaText -Pattern '"adapter_direct_thought_core_turn_input_allowed"[\s\S]{0,80}"const"\s*:\s*false' -Message "local offline recognizer adapter should not directly create Thought Core TurnInput"
  Assert-TextMatch -Text $schemaText -Pattern '"adapter_direct_user_turn_start_allowed"[\s\S]{0,80}"const"\s*:\s*false' -Message "local offline recognizer adapter should not directly start user turns"
  Assert-TextMatch -Text $schemaText -Pattern '"adapter_direct_thought_core_turn_input_ref"[\s\S]{0,80}"type"\s*:\s*"null"' -Message "local offline recognizer adapter should force direct Thought Core turn refs to null"
  Assert-TextMatch -Text $schemaText -Pattern '"adapter_direct_redacted_turn_input_created"[\s\S]{0,80}"const"\s*:\s*false' -Message "local offline recognizer adapter should not directly create redacted_turn_input"
  Assert-TextMatch -Text $schemaText -Pattern '"semantic_user_intent_judgment"[\s\S]{0,80}"const"\s*:\s*"not_performed_by_adapter"' -Message "local offline recognizer adapter should not judge user intent"
  Assert-TextMatch -Text $schemaText -Pattern '"command_or_action_judgment"[\s\S]{0,80}"const"\s*:\s*"not_performed_by_adapter"' -Message "local offline recognizer adapter should not judge commands or actions"
  Assert-TextMatch -Text $schemaText -Pattern '"speech_observation_delivery_boundary"[\s\S]{0,80}"const"\s*:\s*"separate_input_gate_or_thought_core_route_only"' -Message "local offline recognizer adapter should leave speech observation delivery to a separate route"
  Assert-TextMatch -Text $schemaText -Pattern '"recognized_text_hash_ref"[\s\S]{0,220}opaque_ref' -Message "local offline recognizer adapter should allow only opaque recognized-text refs"

  $requiredNegativeCases = @(
    "missing_model",
    "model_download_needed",
    "transcript_oriented_output_only",
    "raw_transcript_or_text_exposure",
    "path_or_filename_exposure",
    "private_metadata_exposure",
    "provider_or_browser_stt_required",
    "playback_or_capture_required",
    "adapter_direct_turn_materialization_attempted"
  )
  $seenNegativeCases = @{}
  $opaqueSourceLabelPattern = '^voice\.(sample|local_sample|synthetic_sample|fixture)_[a-z0-9_:-]+$'
  $transcriptLikeSourceLabelPattern = '(?i)(dance|please|smile|clean|cleaner|cleaning|aircon|cool|heat|dry|stop|return|set|back|hello|phrase|command|transcript|utterance|recognized|text)'
  foreach ($example in $examples) {
    if ([string]$example.schema_version -ne "local_offline_recognizer_redacted_adapter.v0") {
      throw "local offline recognizer adapter example should use v0 schema"
    }
    foreach ($sourceLabel in @(
      [string]$example.source_label,
      [string]$example.input.source_label,
      [string]$example.recognition_summary.source_label
    )) {
      if ($sourceLabel -notmatch $opaqueSourceLabelPattern) {
        throw "local offline recognizer adapter examples should use opaque non-semantic sample source labels"
      }
      if ($sourceLabel -match $transcriptLikeSourceLabelPattern) {
        throw "local offline recognizer adapter source labels should not encode transcript-like or command-like text"
      }
    }
    if ([string]$example.input.source_label_policy -ne "stable_local_media_asset_id_only") {
      throw "local offline recognizer adapter examples should accept stable local media asset ids only"
    }
    if ($example.input.raw_audio_allowed -ne $false -or
        $example.input.private_path_allowed -ne $false -or
        $example.input.filename_or_extension_allowed -ne $false) {
      throw "local offline recognizer adapter input should not allow raw audio, private paths, or filenames"
    }
    if ($example.adapter_policy.redaction_before_artifact_required -ne $true -or
        [string]$example.adapter_policy.shared_output_policy -ne "class_bucket_opaque_ref_only" -or
        $example.adapter_policy.fail_closed_on_unredactable_output -ne $true) {
      throw "local offline recognizer adapter should require redaction-first fail-closed policy"
    }
    if ($example.adapter_policy.raw_output_may_be_logged -ne $false -or
        $example.adapter_policy.transcript_oriented_output_allowed -ne $false -or
        $example.adapter_policy.provider_or_network_stt_allowed -ne $false -or
        $example.adapter_policy.browser_stt_allowed -ne $false -or
        $example.adapter_policy.playback_or_capture_allowed -ne $false -or
        $example.adapter_policy.model_download_allowed -ne $false) {
      throw "local offline recognizer adapter examples should keep execution/leakage policy flags false"
    }
    if ($example.recognizer_runtime.model_download_attempted -ne $false -or
        $example.recognizer_runtime.provider_or_network_stt_used -ne $false -or
        $example.recognizer_runtime.browser_stt_used -ne $false -or
        $example.recognizer_runtime.audio_playback_used -ne $false -or
        $example.recognizer_runtime.audio_capture_used -ne $false -or
        $example.recognizer_runtime.raw_transcript_emitted_to_shared_artifact -ne $false) {
      throw "local offline recognizer adapter examples should not execute download, provider/browser STT, playback/capture, or raw transcript sharing"
    }
    if ($example.recognition_summary.adapter_direct_turn_materialization_allowed -ne $false -or
        $example.recognition_summary.adapter_direct_thought_core_turn_input_allowed -ne $false) {
      throw "local offline recognizer recognition summaries should not directly materialize or create Thought Core turns"
    }
    if ($example.adapter_boundary.adapter_direct_user_turn_start_allowed -ne $false -or
        $example.adapter_boundary.adapter_direct_turn_materialization_allowed -ne $false -or
        $example.adapter_boundary.adapter_direct_thought_core_turn_input_allowed -ne $false -or
        $null -ne $example.adapter_boundary.adapter_direct_thought_core_turn_input_ref -or
        $example.adapter_boundary.adapter_direct_redacted_turn_input_created -ne $false -or
        [string]$example.adapter_boundary.semantic_user_intent_judgment -ne "not_performed_by_adapter" -or
        [string]$example.adapter_boundary.command_or_action_judgment -ne "not_performed_by_adapter" -or
        [string]$example.adapter_boundary.speech_observation_delivery_boundary -ne "separate_input_gate_or_thought_core_route_only" -or
        $example.adapter_boundary.home_control_or_action_authority -ne $false) {
      throw "local offline recognizer adapter examples should keep adapter-direct turn/action boundaries closed without semantic judgment"
    }
    foreach ($field in @(
      "raw_audio_shared",
      "raw_audio_persisted",
      "raw_transcript_shared",
      "literal_text_shared",
      "recognized_text_body_shared",
      "private_path_shared",
      "filename_or_extension_shared",
      "provider_payload_shared",
      "provider_or_network_stt_used",
      "browser_storage_key_shared",
      "device_id_shared",
      "token_or_secret_shared",
      "home_control_or_action_authority"
    )) {
      if ($example.redaction_guards.$field -ne $false) {
        throw "local offline recognizer adapter redaction guard should keep $field false"
      }
    }
    if ([bool]$example.negative_fixture.is_negative_fixture) {
      $seenNegativeCases[[string]$example.negative_fixture.negative_case] = $true
      if ([string]$example.negative_fixture.expected_adapter_decision -ne "blocked") {
        throw "local offline recognizer negative fixtures should be blocked"
      }
      if ($null -eq $example.negative_fixture.blocked_reason) {
        throw "local offline recognizer negative fixtures should carry a class-coded blocked reason"
      }
    }
  }
  foreach ($requiredCase in $requiredNegativeCases) {
    if (-not $seenNegativeCases.ContainsKey($requiredCase)) {
      throw "local offline recognizer adapter should include negative fixture case: $requiredCase"
    }
  }

  Assert-TextNotMatch -Text $combinedExampleText -Pattern 'C:\\|\\\\|/Users/|localStorage|sessionStorage|provider:[A-Za-z0-9_-]+|provider_payload_(id|ref|body)|"provider_id"\s*:|\.wav|\.mp3|\.m4a|\.mp4|"transcript_body"\s*:|"recognized_text_body"\s*:|"raw_transcript_text"\s*:|"recognized_text"\s*:|"audio_file_path"\s*:|"filename"\s*:|"private_path"\s*:|"device_id"\s*:|"token"\s*:|"secret"\s*:' -Message "local offline recognizer examples should not contain private paths, browser keys, media filenames, provider ids, provider payloads, transcript bodies, recognized text bodies, raw text, device ids, tokens, or secrets"
  Assert-TextMatch -Text $contractsReadme -Pattern "local_offline_recognizer_redacted_adapter/local_offline_recognizer_redacted_adapter\.v0\.schema\.json" -Message "Contracts README should list local offline recognizer redacted adapter"
  Assert-TextMatch -Text $contractsReadme -Pattern "redaction[\s\S]{0,80}before shared artifacts|redaction[\s\S]{0,120}shared artifacts" -Message "Contracts README should state redaction-before-artifact boundary"
  Assert-TextMatch -Text $contractsReadme -Pattern "performs no[\s\S]{0,80}recognition|does not run[\s\S]{0,80}recognition|no recognition" -Message "Contracts README should not claim recognition execution"
  Assert-TextMatch -Text $contractsReadme -Pattern "mechanical filter/redaction contract" -Message "Contracts README should narrow the adapter to mechanical filtering and redaction"
  Assert-TextMatch -Text $contractsReadme -Pattern "not a user[\s\S]{0,80}intent[\s\S]{0,80}Thought Core adoption[\s\S]{0,80}Home Control authority" -Message "Contracts README should state the adapter is not a semantic or action authority layer"
  Assert-TextMatch -Text $contractsReadme -Pattern 'creates no normal Thought Core `TurnInput` by\s+itself' -Message "Contracts README should state only adapter-direct TurnInput creation is forbidden"
  Assert-TextMatch -Text $contractsReadme -Pattern "redacted speech observation[\s\S]{0,120}separate input-gate / Thought Core route" -Message "Contracts README should preserve later speech observation delivery to Thought Core as a separate route"

  Write-Host "Local offline recognizer redacted adapter contract static ok"
}

function Test-LocalOfflineRecognizerExecutionWrapperContractStatic {
  Write-TestStep "Local offline recognizer execution wrapper contract static checks"

  $contractDir = Join-Path $RepoRoot "contracts\local_offline_recognizer_execution_wrapper"
  $schemaPath = Join-Path $contractDir "local_offline_recognizer_execution_wrapper.v0.schema.json"
  $examplePath = Join-Path $contractDir "examples\source_static_cases.example.json"
  $contractsReadmePath = Join-Path $RepoRoot "contracts\README.md"

  Assert-PathPresent -Path $schemaPath
  Assert-PathPresent -Path $examplePath

  $schemaText = Get-Content -Raw -LiteralPath $schemaPath
  $schema = $schemaText | ConvertFrom-Json
  $exampleText = Get-Content -Raw -LiteralPath $examplePath
  $example = $exampleText | ConvertFrom-Json
  $contractsReadme = Get-Content -Raw -LiteralPath $contractsReadmePath

  if ([string]$schema.properties.schema_version.const -ne "local_offline_recognizer_execution_wrapper.v0") {
    throw "local offline recognizer execution wrapper schema should lock schema_version"
  }
  if ([string]$schema.properties.route_id.const -ne "OVERALL-TEST-LADDER-AUDIO-REDACTED-RECOGNIZER-EXECUTION-WRAPPER-SOURCE-STATIC-01") {
    throw "local offline recognizer execution wrapper schema should lock the owner route id"
  }
  if ([string]$example.schema_version -ne "local_offline_recognizer_execution_wrapper.v0") {
    throw "local offline recognizer execution wrapper example should use v0 schema"
  }

  Assert-TextMatch -Text $schemaText -Pattern '"redaction_before_artifact_required"[\s\S]{0,80}"const"\s*:\s*true' -Message "local offline recognizer execution wrapper should require redaction before artifact"
  Assert-TextMatch -Text $schemaText -Pattern '"fail_closed_on_unredactable_output"[\s\S]{0,80}"const"\s*:\s*true' -Message "local offline recognizer execution wrapper should fail closed on unredactable output"
  Assert-TextMatch -Text $schemaText -Pattern '"shared_output_policy"[\s\S]{0,80}"const"\s*:\s*"class_bucket_opaque_ref_only"' -Message "local offline recognizer execution wrapper should only share class/bucket/opaque refs"
  Assert-TextMatch -Text $schemaText -Pattern '"raw_output_may_be_logged"[\s\S]{0,80}"const"\s*:\s*false' -Message "local offline recognizer execution wrapper should not log raw runner output"
  Assert-TextMatch -Text $schemaText -Pattern '"transcript_oriented_runner_output_allowed"[\s\S]{0,80}"const"\s*:\s*false' -Message "local offline recognizer execution wrapper should reject transcript-oriented output"
  Assert-TextMatch -Text $schemaText -Pattern '"direct_thought_core_turninput_allowed"[\s\S]{0,80}"const"\s*:\s*false' -Message "local offline recognizer execution wrapper should not create Thought Core TurnInput"

  foreach ($guard in @(
    "stdout_raw_text_allowed",
    "stderr_raw_text_allowed",
    "file_raw_text_allowed",
    "log_raw_text_allowed",
    "shared_artifact_raw_text_allowed",
    "handoff_file_raw_text_allowed",
    "audio_awareness_raw_text_ref_allowed",
    "thought_core_turninput_materialization_allowed",
    "provider_payload_allowed",
    "path_or_filename_allowed"
  )) {
    Assert-TextMatch -Text $schemaText -Pattern ('"{0}"[\s\S]{{0,80}}"const"\s*:\s*false' -f [regex]::Escape($guard)) -Message "local offline recognizer execution wrapper should force $guard false"
  }

  $requiredNegativeCases = @(
    "transcript_like_output",
    "literal_handoff_text",
    "path_or_filename_leakage",
    "provider_cloud_browser_stt_required",
    "model_download_required",
    "microphone_or_pc_output_capture_required",
    "playback_required",
    "adapter_direct_turn_materialization_attempted"
  )
  $seenNegativeCases = @{}
  $opaqueSourceLabelPattern = '^voice\.(sample|local_sample|synthetic_sample|fixture)_[a-z0-9_:-]+$'
  $transcriptLikeSourceLabelPattern = '(?i)(dance|please|smile|clean|cleaner|cleaning|aircon|cool|heat|dry|stop|return|set|back|hello|phrase|command|transcript|utterance|recognized|text)'

  if (@($example.cases).Count -lt 9) {
    throw "local offline recognizer execution wrapper should include pass plus required negative cases"
  }

  foreach ($case in @($example.cases)) {
    $sourceLabel = [string]$case.source_label
    if ($sourceLabel -notmatch $opaqueSourceLabelPattern) {
      throw "local offline recognizer execution wrapper cases should use opaque non-semantic sample labels"
    }
    if ($sourceLabel -match $transcriptLikeSourceLabelPattern) {
      throw "local offline recognizer execution wrapper source labels should not encode transcript-like or command-like text"
    }
    if ($case.runner_candidate.runner_invoked -ne $false -or
        $case.runner_candidate.audio_decoded -ne $false -or
        $case.runner_candidate.recognition_performed -ne $false -or
        $case.runner_candidate.model_download_attempted -ne $false) {
      throw "local offline recognizer execution wrapper examples should not run recognition, decode audio, or download models"
    }
    if ($case.wrapper_policy.redaction_before_artifact_required -ne $true -or
        $case.wrapper_policy.fail_closed_on_unredactable_output -ne $true -or
        [string]$case.wrapper_policy.shared_output_policy -ne "class_bucket_opaque_ref_only" -or
        $case.wrapper_policy.raw_output_may_be_logged -ne $false -or
        $case.wrapper_policy.transcript_oriented_runner_output_allowed -ne $false -or
        $case.wrapper_policy.direct_thought_core_turninput_allowed -ne $false) {
      throw "local offline recognizer execution wrapper policy should stay redaction-first and fail-closed"
    }
    foreach ($field in @(
      "stdout_raw_text_allowed",
      "stderr_raw_text_allowed",
      "file_raw_text_allowed",
      "log_raw_text_allowed",
      "shared_artifact_raw_text_allowed",
      "handoff_file_raw_text_allowed",
      "audio_awareness_raw_text_ref_allowed",
      "thought_core_turninput_materialization_allowed",
      "provider_payload_allowed",
      "path_or_filename_allowed"
    )) {
      if ($case.output_channel_guards.$field -ne $false) {
        throw "local offline recognizer execution wrapper output channel guard should keep $field false"
      }
    }
    if ([string]$case.wrapper_decision.redacted_adapter_contract_ref -ne "contracts/local_offline_recognizer_redacted_adapter/local_offline_recognizer_redacted_adapter.v0.schema.json" -or
        [string]$case.wrapper_decision.audio_awareness_summary_ref_class -ne "classed_summary_only_no_raw_text" -or
        $null -ne $case.wrapper_decision.thought_core_turninput_ref) {
      throw "local offline recognizer execution wrapper decisions should only point to redacted adapter summaries and null Thought Core refs"
    }
    if ([bool]$case.negative_fixture.is_negative_fixture) {
      $seenNegativeCases[[string]$case.negative_fixture.negative_case] = $true
      if ([string]$case.negative_fixture.expected_wrapper_decision -ne "blocked" -or
          [string]$case.wrapper_decision.status_class -ne "blocked_source_static") {
        throw "local offline recognizer execution wrapper negative fixtures should be blocked"
      }
      if ([string]$case.wrapper_decision.blocker_class -ne [string]$case.negative_fixture.negative_case) {
        throw "local offline recognizer execution wrapper negative fixture blocker should match negative case"
      }
    }
    if ($case.raw_private_publication_flags -ne $false) {
      throw "local offline recognizer execution wrapper examples should keep raw private publication false"
    }
    foreach ($claim in @("not_audio_decoding_or_recognition", "not_raw_transcript_publication", "not_thought_core_turninput")) {
      if (@($case.non_claims) -notcontains $claim) {
        throw "local offline recognizer execution wrapper examples should preserve non-claim: $claim"
      }
    }
  }
  foreach ($requiredCase in $requiredNegativeCases) {
    if (-not $seenNegativeCases.ContainsKey($requiredCase)) {
      throw "local offline recognizer execution wrapper should include negative fixture case: $requiredCase"
    }
  }

  Assert-TextNotMatch -Text $exampleText -Pattern 'C:\\|\\\\|/Users/|localStorage|sessionStorage|provider:[A-Za-z0-9_-]+|provider_payload_(id|ref|body)|"provider_id"\s*:|\.wav|\.mp3|\.m4a|\.mp4|"transcript_body"\s*:|"recognized_text_body"\s*:|"raw_transcript_text"\s*:|"recognized_text"\s*:|"audio_file_path"\s*:|"filename"\s*:|"private_path"\s*:|"device_id"\s*:|"token"\s*:|"secret"\s*:' -Message "local offline recognizer execution wrapper examples should not contain private paths, media filenames, provider ids, transcript bodies, raw text, device ids, tokens, or secrets"
  Assert-TextMatch -Text $contractsReadme -Pattern "local_offline_recognizer_execution_wrapper/local_offline_recognizer_execution_wrapper\.v0\.schema\.json" -Message "Contracts README should list local offline recognizer execution wrapper"
  Assert-TextMatch -Text $contractsReadme -Pattern "one layer before any recognition dry-run" -Message "Contracts README should keep wrapper before recognition dry-run"
  Assert-TextMatch -Text $contractsReadme -Pattern "stdout|stderr|files|logs|shared artifacts|Audio Awareness summary refs|Thought Core TurnInput" -Message "Contracts README should name protected output channels"

  Write-Host "Local offline recognizer execution wrapper contract static ok"
}

function Test-OverallTestLadderReportContractStatic {
  Write-TestStep "Overall test ladder report v2 contract static checks"

  $contractDir = Join-Path $RepoRoot "contracts\overall_test_ladder_report"
  $schemaPath = Join-Path $contractDir "overall_test_ladder_report.v2.schema.json"
  $exampleDir = Join-Path $contractDir "examples"
  $contractsReadmePath = Join-Path $RepoRoot "contracts\README.md"
  $verificationCommandsPath = Join-Path $RepoRoot "docs\verification-commands.md"

  Assert-PathPresent -Path $schemaPath
  Assert-PathPresent -Path (Join-Path $exampleDir "daily_confidence_smoke.held.example.json")
  Assert-PathPresent -Path (Join-Path $exampleDir "local_operator_readiness.blocked.example.json")
  Assert-PathPresent -Path (Join-Path $exampleDir "rr003_readiness_candidate.not_claimed.example.json")

  $schemaText = Get-Content -Raw -LiteralPath $schemaPath
  $schema = $schemaText | ConvertFrom-Json
  $contractsReadme = Get-Content -Raw -LiteralPath $contractsReadmePath
  $verificationCommands = Get-Content -Raw -LiteralPath $verificationCommandsPath
  $exampleFiles = @(Get-ChildItem -LiteralPath $exampleDir -Filter "*.json" | Sort-Object Name)
  $exampleTexts = @()
  $examples = @()
  foreach ($exampleFile in $exampleFiles) {
    $text = Get-Content -Raw -LiteralPath $exampleFile.FullName
    $exampleTexts += $text
    $examples += @($text | ConvertFrom-Json)
  }
  $combinedExampleText = $exampleTexts -join "`n"

  if ([string]$schema.properties.schema_version.const -ne "overall_test_ladder_report.v2") {
    throw "overall test ladder report schema should lock schema_version"
  }
  if ([string]$schema.properties.report_schema_version.const -ne "overall_test_ladder_report.v2") {
    throw "overall test ladder report schema should lock report_schema_version"
  }
  if ([string]$schema.properties.route_id.const -ne "OVERALL-TEST-LADDER-REPORT-SCHEMA-V2-SOURCE-STATIC-01") {
    throw "overall test ladder report schema should lock the owner route id"
  }

  Assert-TextMatch -Text $schemaText -Pattern '"shared_output_policy"[\s\S]{0,80}"const"\s*:\s*"class_count_bucket_only"' -Message "overall test ladder report should force class/count/bucket shared output"
  Assert-TextMatch -Text $schemaText -Pattern '"evidence_summary_policy"[\s\S]{0,80}"const"\s*:\s*"class_count_bucket_only_no_raw_material"' -Message "overall test ladder report should keep evidence summaries raw-free"
  Assert-TextMatch -Text $schemaText -Pattern '"pass_candidate_readiness_policy"[\s\S]{0,80}"const"\s*:\s*"pass_candidate_is_not_rr003_final_or_release_ready"' -Message "overall test ladder report should keep pass_candidate below readiness"
  Assert-TextMatch -Text $schemaText -Pattern '"raw_private_publication_policy"[\s\S]{0,80}"const"\s*:\s*"block_shared_report_if_raw_private_required"' -Message "overall test ladder report should block raw/private-only proof"
  Assert-TextMatch -Text $schemaText -Pattern '"proof_ceiling"' -Message "overall test ladder report rows should carry proof_ceiling"
  Assert-TextMatch -Text $schemaText -Pattern '"non_claims"' -Message "overall test ladder report rows should carry non_claims"
  Assert-TextMatch -Text $schemaText -Pattern '"raw_private_publication_flags"[\s\S]{0,80}"const"\s*:\s*false' -Message "overall test ladder report should keep raw_private_publication_flags false"

  foreach ($guard in @(
    "raw_transcript_allowed",
    "raw_audio_allowed",
    "raw_media_allowed",
    "raw_screenshot_allowed",
    "raw_browser_frame_allowed",
    "touchdesigner_content_allowed",
    "provider_payload_allowed",
    "home_assistant_raw_payload_allowed",
    "entity_or_device_id_allowed",
    "private_path_or_filename_allowed",
    "private_url_allowed",
    "exact_env_value_allowed",
    "stdout_stderr_or_stack_trace_allowed",
    "token_or_secret_allowed",
    "raw_private_publication_required"
  )) {
    Assert-TextMatch -Text $schemaText -Pattern ('"{0}"[\s\S]{{0,80}}"const"\s*:\s*false' -f [regex]::Escape($guard)) -Message "overall test ladder report should force $guard false"
  }

  $seenReportClasses = @{}
  foreach ($example in $examples) {
    if ([string]$example.schema_version -ne "overall_test_ladder_report.v2") {
      throw "overall test ladder report examples should use v2 schema"
    }
    if ([string]$example.report_schema_version -ne "overall_test_ladder_report.v2") {
      throw "overall test ladder report examples should use report_schema_version"
    }
    if ([string]$example.route_id -ne "OVERALL-TEST-LADDER-REPORT-SCHEMA-V2-SOURCE-STATIC-01") {
      throw "overall test ladder report examples should use the schema route"
    }
    $seenReportClasses[[string]$example.report_class] = $true
    if ($example.raw_private_publication_flags -ne $false) {
      throw "overall test ladder report examples should keep raw_private_publication_flags false"
    }
    if (@($example.non_claims) -notcontains "not_rr003_or_final_readiness") {
      throw "overall test ladder report examples should preserve readiness non-claim"
    }
    if ([string]$example.report_policy.shared_output_policy -ne "class_count_bucket_only" -or
        [string]$example.report_policy.evidence_summary_policy -ne "class_count_bucket_only_no_raw_material" -or
        [string]$example.report_policy.pass_candidate_readiness_policy -ne "pass_candidate_is_not_rr003_final_or_release_ready" -or
        [string]$example.report_policy.raw_private_publication_policy -ne "block_shared_report_if_raw_private_required") {
      throw "overall test ladder report examples should keep report policy redacted and below readiness"
    }
    foreach ($claimGuard in @(
      "rr003_pass_claimed",
      "final_readiness_claimed",
      "release_readiness_claimed",
      "proof_upgrade_claimed",
      "physical_device_proof_claimed"
    )) {
      if ($example.claim_guards.$claimGuard -ne $false) {
        throw "overall test ladder report examples should keep top-level claim guard $claimGuard false"
      }
    }
    if ([int]$example.summary_counts.rows_total -ne @($example.rows).Count) {
      throw "overall test ladder report rows_total should match row count"
    }
    foreach ($row in @($example.rows)) {
      if (-not [string]$row.proof_ceiling) {
        throw "overall test ladder report rows should carry a proof_ceiling"
      }
      if (-not [string]$row.purpose -or -not [string]$row.user_value_question) {
        throw "overall test ladder report rows should carry purpose and user_value_question"
      }
      if ($row.raw_private_publication_flags -ne $false) {
        throw "overall test ladder report rows should keep raw_private_publication_flags false"
      }
      if (@($row.non_claims) -notcontains "not_rr003_or_final_readiness") {
        throw "overall test ladder report rows should preserve readiness non-claim"
      }
      if ($row.status_class -eq "pass_candidate" -and (
          $row.claim_guards.rr003_pass_claimed -ne $false -or
          $row.claim_guards.final_readiness_claimed -ne $false -or
          $row.claim_guards.release_readiness_claimed -ne $false -or
          $row.claim_guards.proof_upgrade_claimed -ne $false)) {
        throw "overall test ladder pass_candidate rows should not claim readiness or proof upgrade"
      }
      if (-not [string]$row.evidence_summary.summary_class -or
          -not [string]$row.evidence_summary.count_bucket -or
          -not [string]$row.evidence_summary.evidence_bucket) {
        throw "overall test ladder evidence_summary should be class/count/bucket only"
      }
      foreach ($ref in @($row.safe_refs)) {
        if ([string]$ref -notmatch '^safe_ref_[a-z0-9_:-]+$') {
          throw "overall test ladder safe_refs should be opaque safe refs"
        }
      }
      foreach ($guard in @(
        "raw_transcript_allowed",
        "raw_audio_allowed",
        "raw_media_allowed",
        "raw_screenshot_allowed",
        "raw_browser_frame_allowed",
        "touchdesigner_content_allowed",
        "provider_payload_allowed",
        "home_assistant_raw_payload_allowed",
        "entity_or_device_id_allowed",
        "private_path_or_filename_allowed",
        "private_url_allowed",
        "exact_env_value_allowed",
        "stdout_stderr_or_stack_trace_allowed",
        "token_or_secret_allowed",
        "raw_private_publication_required"
      )) {
        if ($row.publication_boundary.$guard -ne $false) {
          throw "overall test ladder publication boundary should keep $guard false"
        }
      }
    }
  }

  foreach ($requiredClass in @("daily_confidence_smoke", "local_operator_readiness", "rr003_readiness_candidate")) {
    if (-not $seenReportClasses.ContainsKey($requiredClass)) {
      throw "overall test ladder report examples should include report_class: $requiredClass"
    }
  }

  Assert-TextNotMatch -Text $combinedExampleText -Pattern 'C:\\|\\\\|/Users/|localStorage|sessionStorage|provider:[A-Za-z0-9_-]+|provider_payload_(id|ref|body)|"provider_id"\s*:|\.wav|\.mp3|\.m4a|\.mp4|\.png|\.jpg|\.jpeg|"transcript_body"\s*:|"recognized_text_body"\s*:|"raw_transcript_text"\s*:|"recognized_text"\s*:|"audio_file_path"\s*:|"filename"\s*:|"private_path"\s*:|"device_id"\s*:|"entity_id"\s*:|"token"\s*:|"secret"\s*:' -Message "overall test ladder report examples should not contain private paths, media filenames, provider ids, transcript bodies, raw text, entity/device ids, tokens, or secrets"
  Assert-TextMatch -Text $contractsReadme -Pattern "overall_test_ladder_report/overall_test_ladder_report\.v2\.schema\.json" -Message "Contracts README should list overall test ladder report v2"
  Assert-TextMatch -Text $contractsReadme -Pattern "pass_candidate[\s\S]{0,120}not[\s\S]{0,120}RR003 pass" -Message "Contracts README should keep pass_candidate below RR003 pass"
  Assert-TextMatch -Text $verificationCommands -Pattern "overall_test_ladder_report/overall_test_ladder_report\.v2\.schema\.json" -Message "verification commands should point to overall test ladder report v2"
  Assert-TextMatch -Text $verificationCommands -Pattern "pass_candidate.*must not mean RR003 pass" -Message "verification commands should preserve pass_candidate non-readiness wording"

  Write-Host "Overall test ladder report v2 contract static ok"
}

function Test-OverallTestLadderFrontDoorV2Static {
  Write-TestStep "Overall test ladder front door v2 static checks"

  $frontDoorPath = Join-Path $RepoRoot "sword.ps1"
  $coordinatorPath = Join-Path $RepoRoot "scripts\run-overall-test-ladder-v2.ps1"
  $verificationCommandsPath = Join-Path $RepoRoot "docs\verification-commands.md"

  Assert-PathPresent -Path $frontDoorPath
  Assert-PathPresent -Path $coordinatorPath
  Assert-PathPresent -Path $verificationCommandsPath

  $frontDoor = Get-Content -Raw -LiteralPath $frontDoorPath
  $coordinator = Get-Content -Raw -LiteralPath $coordinatorPath
  $verificationCommands = Get-Content -Raw -LiteralPath $verificationCommandsPath

  Assert-TextMatch -Text $frontDoor -Pattern '"ladder"' -Message "sword.ps1 should expose the ladder front-door command"
  Assert-TextMatch -Text $frontDoor -Pattern "run-overall-test-ladder-v2\.ps1" -Message "sword.ps1 ladder should delegate to the v2 coordinator"
  Assert-TextMatch -Text $frontDoor -Pattern "Write-LadderRunBlockedOutput" -Message "sword.ps1 ladder -Run should use classed block output"
  Assert-TextMatch -Text $frontDoor -Pattern "runtime_or_device_layers_require_exact_route" -Message "sword.ps1 ladder -Run should emit a result class"
  Assert-TextMatch -Text $frontDoor -Pattern "separate_exact_route_required" -Message "sword.ps1 ladder -Run should emit a blocker class"
  Assert-TextMatch -Text $frontDoor -Pattern "no-live/no-device" -Message "sword.ps1 ladder should keep no-live/no-device wording"
  Assert-TextMatch -Text $coordinator -Pattern "default_safety=no-live/no-device" -Message "v2 coordinator should print the default safety"
  Assert-TextMatch -Text $coordinator -Pattern "local_artifact_hold" -Message "v2 coordinator should preserve local artifact hold handling"
  Assert-TextMatch -Text $coordinator -Pattern "not_broad_runner_implementation" -Message "v2 coordinator should avoid broad runner claims"
  Assert-TextMatch -Text $coordinator -Pattern "not_runtime_or_device_operation" -Message "v2 coordinator should avoid runtime/device operation claims"
  Assert-TextMatch -Text $coordinator -Pattern "raw_private_publication_flags" -Message "v2 coordinator should emit raw-private publication flags"
  Assert-TextNotMatch -Text $coordinator -Pattern 'Invoke-VerificationCommand|Invoke-WebRequest|Start-Process|&\s*\$PowerShellCommand|&\s*\$powerShellExe' -Message "v2 coordinator should not call live/browser/runtime helpers by default"
  Assert-TextMatch -Text $verificationCommands -Pattern "\.\\sword\.ps1 ladder" -Message "verification docs should document the ladder front door"
  Assert-TextMatch -Text $verificationCommands -Pattern "\.\\sword\.ps1 ladder -Run[\s\S]{0,120}fails closed" -Message "verification docs should document classed -Run blocking"
  Assert-TextMatch -Text $verificationCommands -Pattern "local_artifact_hold[\s\S]{0,160}held row" -Message "verification docs should keep local artifact holds as held rows"

  $runBlockOutput = Invoke-ExpectFailure -Command @($PowerShellCommand, "-NoProfile", "-File", $frontDoorPath, "ladder", "-Run")
  $runBlockText = $runBlockOutput -join "`n"
  Assert-TextMatch -Text $runBlockText -Pattern "status_class=blocked" -Message "ladder -Run should emit blocked status"
  Assert-TextMatch -Text $runBlockText -Pattern "result_class=runtime_or_device_layers_require_exact_route" -Message "ladder -Run should emit result class"
  Assert-TextMatch -Text $runBlockText -Pattern "blocker_class=separate_exact_route_required" -Message "ladder -Run should emit blocker class"
  Assert-TextMatch -Text $runBlockText -Pattern "raw_private_publication_flags=false" -Message "ladder -Run should emit raw-private guard"
  Assert-TextNotMatch -Text $runBlockText -Pattern 'C:\\|\\\\|/Users/|\.ps1:\d+|Line\s*\||at\s+.*\.ps1|Exception:|InvalidOperation|throw|CategoryInfo|FullyQualifiedErrorId|StackTrace' -Message "ladder -Run block output should be path-free and stack-free"

  $jsonOutput = Invoke-Checked -Command @($PowerShellCommand, "-NoProfile", "-File", $coordinatorPath, "-Json")
  $report = ($jsonOutput -join "`n") | ConvertFrom-Json
  if ([string]$report.schema_version -ne "overall_test_ladder_report.v2") {
    throw "v2 front-door JSON should use the report schema"
  }
  if ([string]$report.report_class -ne "daily_confidence_smoke") {
    throw "v2 front-door default should be daily_confidence_smoke"
  }
  if ([string]$report.overall_status_class -ne "completed_with_holds") {
    throw "v2 front-door default should complete with held rows"
  }
  if ($report.raw_private_publication_flags -ne $false) {
    throw "v2 front-door report should keep raw_private_publication_flags false"
  }
  if (@($report.non_claims) -notcontains "not_rr003_or_final_readiness") {
    throw "v2 front-door report should preserve readiness non-claim"
  }
  if ([int]$report.summary_counts.rows_total -ne @($report.rows).Count) {
    throw "v2 front-door rows_total should match row count"
  }
  if ([int]$report.summary_counts.held_rows -lt 1) {
    throw "v2 front-door default should hold gated runtime/device layers"
  }

  foreach ($row in @($report.rows)) {
    if (-not [string]$row.proof_ceiling) {
      throw "v2 front-door rows should carry proof_ceiling"
    }
    if (-not [string]$row.evidence_summary.summary_class -or
        -not [string]$row.evidence_summary.count_bucket -or
        -not [string]$row.evidence_summary.evidence_bucket) {
      throw "v2 front-door rows should carry class/count/bucket evidence summaries"
    }
    if ($row.raw_private_publication_flags -ne $false) {
      throw "v2 front-door rows should keep raw_private_publication_flags false"
    }
    if (@($row.non_claims) -notcontains "not_rr003_or_final_readiness") {
      throw "v2 front-door rows should preserve readiness non-claim"
    }
    if ($row.claim_guards.rr003_pass_claimed -ne $false -or
        $row.claim_guards.final_readiness_claimed -ne $false -or
        $row.claim_guards.release_readiness_claimed -ne $false -or
        $row.claim_guards.proof_upgrade_claimed -ne $false -or
        $row.claim_guards.physical_device_proof_claimed -ne $false) {
      throw "v2 front-door rows should not claim readiness or proof upgrade"
    }
    if ($row.publication_boundary.raw_private_publication_required -ne $false) {
      throw "v2 front-door rows should block raw-private publication needs"
    }
  }

  Write-Host "Overall test ladder front door v2 static ok"
}

function Test-AudioAwarenessRefPolicyStatic {
  Write-TestStep "Audio Awareness self-output ref policy static checks"

  $schemaPath = Join-Path $RepoRoot "contracts\audio_awareness_summary\audio_awareness_summary.v0.schema.json"
  $examplePath = Join-Path $RepoRoot "contracts\audio_awareness_summary\examples\pc-output-voicevox-correlated.example.json"
  $runtimePath = Join-Path $RepoRoot "runtime\audio-awareness\audio-awareness.mjs"
  $routesPath = Join-Path $RepoRoot "runtime\audio-awareness\audio-awareness-consumer-routes.json"
  $docsPath = Join-Path $RepoRoot "docs\audio-awareness.md"

  Assert-PathPresent -Path $schemaPath
  Assert-PathPresent -Path $examplePath
  Assert-PathPresent -Path $runtimePath
  Assert-PathPresent -Path $routesPath

  $schemaText = Get-Content -Raw -LiteralPath $schemaPath
  $exampleText = Get-Content -Raw -LiteralPath $examplePath
  $runtimeText = Get-Content -Raw -LiteralPath $runtimePath
  $routesText = Get-Content -Raw -LiteralPath $routesPath
  $docsText = Get-Content -Raw -LiteralPath $docsPath
  $schema = $schemaText | ConvertFrom-Json
  $example = $exampleText | ConvertFrom-Json

  if ($null -ne $example.correlation.self_output_event_ref -or
      $null -ne $example.correlation.playback_event_ref -or
      $null -ne $example.transcript.transcript_summary_ref) {
    throw "Audio Awareness source/static fixture should keep self-output, playback, and transcript refs null"
  }

  if ([string]$schema.properties.transcript.properties.transcript_summary_ref.type -ne "null") {
    throw "Audio Awareness summary schema should force transcript_summary_ref to null in v0"
  }
  Assert-TextNotMatch -Text $schema.'$defs'.safe_ref.pattern -Pattern "\btts\b|\bplayback\b" -Message "Audio Awareness safe refs should not allow legacy tts/playback prefixes"
  Assert-TextNotMatch -Text $exampleText -Pattern '"(self_output_event_ref|playback_event_ref)"\s*:\s*"(tts|playback):|transcript_summary_ref"\s*:\s*"[^"]+"' -Message "Audio Awareness fixture should not contain legacy self-output or transcript-like refs"
  Assert-TextNotMatch -Text $runtimeText -Pattern '"(tts|playback):synthetic_source_static"|transcript_summary_ref:\s*safeRef' -Message "Audio Awareness runtime defaults should normalize legacy refs away"
  Assert-TextMatch -Text $routesText -Pattern "audio_self_output_observation\.v0" -Message "Audio Awareness routes should send self-output STT/adoption-block observations to audio_self_output_observation.v0"
  Assert-TextMatch -Text $docsText -Pattern "audio_self_output_observation\.v0" -Message "Audio Awareness docs should document the self-output observation split"

  Write-Host "Audio Awareness self-output ref policy static ok"
}

function Test-RouteAParentNoLiveUxStatic {
  Write-TestStep "Route A parent no-live UX static checks"

  $swordPath = Join-Path $RepoRoot "sword.ps1"
  Assert-PathPresent -Path $swordPath
  $sword = Get-Content -Raw -LiteralPath $swordPath
  Assert-TextMatch -Text $sword -Pattern 'ValidateSet\("status", "verify", "doctor", "start", "stop", "hold-live", "ladder"\)' -Message "sword.ps1 should expose the supported front-door commands"
  Assert-TextMatch -Text $sword -Pattern "default_safety=no-live/no-device" -Message "sword.ps1 should advertise no-live/no-device default safety"
  Assert-TextMatch -Text $sword -Pattern "source-static-command-preview" -Message "sword.ps1 start/stop should default to command preview"
  Assert-TextMatch -Text $sword -Pattern 'live_home_assistant_actions_allowed = \$false' -Message "hold-live should not authorize Home Assistant actions"
  Assert-TextMatch -Text $sword -Pattern 'approval_bypass_allowed = \$false' -Message "hold-live should not create a live-authority bypass"

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
  Assert-TextMatch -Text $text -Pattern "tracking_self_test: effect_only=blocked" -Message "tracking helper should block expected_effect-only rows from HA state proof"
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

function Assert-NoFreshTestPathReparsePoint {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$Boundary,
    [Parameter(Mandatory = $true)][string]$Label
  )
  $boundaryFull = [System.IO.Path]::GetFullPath($Boundary).TrimEnd(
    [System.IO.Path]::DirectorySeparatorChar,
    [System.IO.Path]::AltDirectorySeparatorChar
  )
  $candidateFull = [System.IO.Path]::GetFullPath($Path).TrimEnd(
    [System.IO.Path]::DirectorySeparatorChar,
    [System.IO.Path]::AltDirectorySeparatorChar
  )
  $boundaryPrefix = $boundaryFull + [System.IO.Path]::DirectorySeparatorChar
  if (-not $candidateFull.Equals($boundaryFull, [System.StringComparison]::OrdinalIgnoreCase) -and
      -not $candidateFull.StartsWith($boundaryPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "$Label must remain inside its canonical boundary: $candidateFull"
  }

  $current = $boundaryFull
  $pathsToCheck = @($current)
  if (-not $candidateFull.Equals($boundaryFull, [System.StringComparison]::OrdinalIgnoreCase)) {
    $relative = [System.IO.Path]::GetRelativePath($boundaryFull, $candidateFull)
    foreach ($component in @($relative -split '[\\/]')) {
      if ([string]::IsNullOrWhiteSpace($component) -or $component -eq ".") {
        continue
      }
      $current = Join-Path $current $component
      $pathsToCheck += $current
    }
  }
  foreach ($candidate in $pathsToCheck) {
    if (-not (Test-Path -LiteralPath $candidate)) {
      continue
    }
    $item = Get-Item -LiteralPath $candidate -Force
    if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
      throw "$Label crosses a reparse point: $candidate"
    }
  }
  return $candidateFull
}

function New-FreshTestRoot {
  $tempBase = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd(
    [System.IO.Path]::DirectorySeparatorChar,
    [System.IO.Path]::AltDirectorySeparatorChar
  )
  $base = if ([string]::IsNullOrWhiteSpace($TempRoot)) {
    $tempBase
  }
  else {
    [System.IO.Path]::GetFullPath($TempRoot).TrimEnd(
      [System.IO.Path]::DirectorySeparatorChar,
      [System.IO.Path]::AltDirectorySeparatorChar
    )
  }
  $tempPrefix = $tempBase.TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
  if (-not $base.Equals($tempBase, [System.StringComparison]::OrdinalIgnoreCase) -and
      -not $base.StartsWith($tempPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "TempRoot base must remain inside the system temp directory: $base"
  }
  [void](Assert-NoFreshTestPathReparsePoint -Path $base -Boundary $tempBase -Label "TempRoot base")
  if (-not (Test-Path -LiteralPath $base)) {
    New-Item -ItemType Directory -Path $base | Out-Null
  }
  if (-not (Test-Path -LiteralPath $base -PathType Container)) {
    throw "TempRoot base must be a directory: $base"
  }
  $baseItem = Get-Item -LiteralPath $base -Force
  if (($baseItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw "TempRoot base must not be a reparse point: $base"
  }
  [void](Assert-NoFreshTestPathReparsePoint -Path $base -Boundary $tempBase -Label "TempRoot base")
  $root = Join-Path $base ("sword-agent-os-maintenance-test-" + [guid]::NewGuid().ToString("N"))
  if (Test-Path -LiteralPath $root) {
    throw "fresh test root unexpectedly exists: $root"
  }
  $rootItem = New-Item -ItemType Directory -Path $root
  if (($rootItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw "fresh test root must not be a reparse point: $root"
  }
  $resolved = [System.IO.Path]::GetFullPath($rootItem.FullName)
  [void](Assert-NoFreshTestPathReparsePoint -Path $resolved -Boundary $tempBase -Label "fresh test root")
  $markerPath = Join-Path $resolved $FreshTestOwnerMarkerName
  $record = [ordered]@{
    schema_version = 1
    owner = "scripts/test-distribution-maintenance.ps1"
    invocation_id = $FreshTestInvocationId
    root = $resolved
    base = [System.IO.Path]::GetFullPath($base)
    creation_time_utc_ticks = $rootItem.CreationTimeUtc.Ticks
  }
  Set-Content -LiteralPath $markerPath -Value ($record | ConvertTo-Json -Compress) -Encoding utf8
  $OwnedFreshTestRoots[$resolved.ToUpperInvariant()] = $record
  return $resolved
}

function Remove-FreshTestRoot {
  param([Parameter(Mandatory = $true)][string]$Path)
  if ($KeepTemp) {
    Write-Host "keeping temp root: $Path"
    return
  }
  $resolved = [System.IO.Path]::GetFullPath($Path)
  $key = $resolved.ToUpperInvariant()
  if (-not $OwnedFreshTestRoots.ContainsKey($key)) {
    throw "refusing to remove test root not created by this invocation: $resolved"
  }
  $record = $OwnedFreshTestRoots[$key]
  $tempBase = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd(
    [System.IO.Path]::DirectorySeparatorChar,
    [System.IO.Path]::AltDirectorySeparatorChar
  )
  $tempPrefix = $tempBase.TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
  $base = [System.IO.Path]::GetFullPath([string]$record.base).TrimEnd(
    [System.IO.Path]::DirectorySeparatorChar,
    [System.IO.Path]::AltDirectorySeparatorChar
  )
  $basePrefix = $base.TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
  $leaf = Split-Path -Leaf $resolved
  if (-not $resolved.StartsWith($tempPrefix, [System.StringComparison]::OrdinalIgnoreCase) -or
      -not $resolved.StartsWith($basePrefix, [System.StringComparison]::OrdinalIgnoreCase) -or
      -not $leaf.StartsWith("sword-agent-os-maintenance-test-", [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "refusing to remove unexpected temp root: $resolved"
  }
  if (-not ([System.IO.Path]::GetDirectoryName($resolved)).Equals($base, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "owned temp root is not a direct child of its recorded base: $resolved"
  }
  [void](Assert-NoFreshTestPathReparsePoint -Path $base -Boundary $tempBase -Label "recorded TempRoot base")
  [void](Assert-NoFreshTestPathReparsePoint -Path $resolved -Boundary $tempBase -Label "owned temp root")
  if (-not (Test-Path -LiteralPath $resolved -PathType Container)) {
    throw "owned temp root is missing or no longer a directory: $resolved"
  }
  $rootItem = Get-Item -LiteralPath $resolved -Force
  if (($rootItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 -or
      $rootItem.CreationTimeUtc.Ticks -ne [long]$record.creation_time_utc_ticks) {
    throw "owned temp root identity changed: $resolved"
  }
  $markerPath = Join-Path $resolved $FreshTestOwnerMarkerName
  if (-not (Test-Path -LiteralPath $markerPath -PathType Leaf)) {
    throw "owned temp root marker is missing: $resolved"
  }
  $markerItem = Get-Item -LiteralPath $markerPath -Force
  if (($markerItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw "owned temp root marker became a reparse point: $resolved"
  }
  $marker = Get-Content -Raw -LiteralPath $markerPath | ConvertFrom-Json
  if ([string]$marker.invocation_id -ne $FreshTestInvocationId -or
      -not ([string]$marker.root).Equals($resolved, [System.StringComparison]::OrdinalIgnoreCase) -or
      [long]$marker.creation_time_utc_ticks -ne [long]$record.creation_time_utc_ticks) {
    throw "owned temp root marker does not match this invocation: $resolved"
  }
  $reparseDescendant = Get-ChildItem -LiteralPath $resolved -Force -Recurse -ErrorAction Stop |
    Where-Object { ($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 } |
    Select-Object -First 1
  if ($null -ne $reparseDescendant) {
    throw "owned temp root contains a reparse point and cannot be recursively cleaned: $($reparseDescendant.FullName)"
  }
  Remove-Item -LiteralPath $resolved -Recurse -Force
  if (Test-Path -LiteralPath $resolved) {
    throw "owned temp root cleanup incomplete: $resolved"
  }
  [void]$OwnedFreshTestRoots.Remove($key)
}

function Test-FreshTestRootOwnershipSafety {
  Write-TestStep "fresh test root ownership and cleanup safety"
  $originalTempRoot = $TempRoot
  $base = Join-Path ([System.IO.Path]::GetTempPath()) ("sword-agent-os-maintenance-parent-" + [guid]::NewGuid().ToString("N"))
  $sentinel = Join-Path $base "caller-owned-sentinel.txt"
  $unowned = Join-Path $base ("sword-agent-os-maintenance-test-" + [guid]::NewGuid().ToString("N"))
  $junctionParent = Join-Path ([System.IO.Path]::GetTempPath()) ("sword-agent-os-maintenance-junction-parent-" + [guid]::NewGuid().ToString("N"))
  $junction = Join-Path $junctionParent "nested-link"
  $externalBase = Join-Path ([System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::LocalApplicationData)) ("sword-agent-os-maintenance-external-" + [guid]::NewGuid().ToString("N"))
  $externalSentinel = Join-Path $externalBase "outside-sentinel.txt"
  $first = $null
  $second = $null
  $descendantLink = $null
  $markerPath = $null
  $markerContent = $null
  try {
    New-Item -ItemType Directory -Path $base | Out-Null
    Set-Content -LiteralPath $sentinel -Value "preserve" -Encoding utf8
    New-Item -ItemType Directory -Path $externalBase | Out-Null
    Set-Content -LiteralPath $externalSentinel -Value "outside-preserve" -Encoding utf8

    $TempRoot = $base
    $first = New-FreshTestRoot
    $second = New-FreshTestRoot
    if ($first -eq $second -or
        [System.IO.Path]::GetDirectoryName($first) -ne [System.IO.Path]::GetFullPath($base)) {
      throw "caller TempRoot was not treated as a base for unique owned children"
    }
    New-Item -ItemType Directory -Path $unowned | Out-Null
    try {
      Remove-FreshTestRoot -Path $unowned
      throw "cleanup accepted an unowned prefix-matching directory"
    }
    catch {
      if ($_.Exception.Message -notmatch "not created by this invocation") {
        throw
      }
    }
    $markerPath = Join-Path $second $FreshTestOwnerMarkerName
    $markerContent = Get-Content -Raw -LiteralPath $markerPath
    Set-Content -LiteralPath $markerPath -Value '{"invocation_id":"tampered"}' -Encoding utf8
    try {
      Remove-FreshTestRoot -Path $second
      throw "cleanup accepted a tampered ownership marker"
    }
    catch {
      if ($_.Exception.Message -notmatch "marker does not match") {
        throw
      }
    }
    Set-Content -LiteralPath $markerPath -Value $markerContent -Encoding utf8
    $markerContent = $null

    $descendantLink = Join-Path $first "redirected-child"
    New-Item -ItemType Junction -Path $descendantLink -Target $externalBase | Out-Null
    try {
      Remove-FreshTestRoot -Path $first
      throw "cleanup accepted a reparse-point descendant"
    }
    catch {
      if ($_.Exception.Message -notmatch "contains a reparse point") {
        throw
      }
    }
    Assert-PathPresent -Path $externalSentinel
    Remove-Item -LiteralPath $descendantLink -Force
    $descendantLink = $null

    Remove-FreshTestRoot -Path $first
    $first = $null
    Remove-FreshTestRoot -Path $second
    $second = $null
    Assert-PathPresent -Path $sentinel

    New-Item -ItemType Directory -Path $junctionParent | Out-Null
    New-Item -ItemType Junction -Path $junction -Target $externalBase | Out-Null
    $TempRoot = Join-Path $junction "caller-base"
    try {
      New-FreshTestRoot | Out-Null
      throw "fresh test root creation accepted an intermediate TempRoot junction"
    }
    catch {
      if ($_.Exception.Message -notmatch "crosses a reparse point") {
        throw
      }
    }
    Assert-PathPresent -Path $externalSentinel
  }
  finally {
    $TempRoot = $originalTempRoot
    if ($null -ne $descendantLink -and (Test-Path -LiteralPath $descendantLink)) {
      Remove-Item -LiteralPath $descendantLink -Force
    }
    if ($null -ne $markerContent -and $null -ne $markerPath -and (Test-Path -LiteralPath $markerPath -PathType Leaf)) {
      Set-Content -LiteralPath $markerPath -Value $markerContent -Encoding utf8
    }
    foreach ($ownedRoot in @($first, $second)) {
      if ($null -ne $ownedRoot -and (Test-Path -LiteralPath $ownedRoot -PathType Container)) {
        Remove-FreshTestRoot -Path $ownedRoot
      }
    }
    if (Test-Path -LiteralPath $junction) {
      Remove-Item -LiteralPath $junction -Force
    }
    if (Test-Path -LiteralPath $junctionParent -PathType Container) {
      Remove-Item -LiteralPath $junctionParent
    }
    if (Test-Path -LiteralPath $unowned -PathType Container) {
      Remove-Item -LiteralPath $unowned
    }
    if (Test-Path -LiteralPath $sentinel -PathType Leaf) {
      Remove-Item -LiteralPath $sentinel
    }
    if (Test-Path -LiteralPath $base -PathType Container) {
      Remove-Item -LiteralPath $base
    }
    if (Test-Path -LiteralPath $externalSentinel -PathType Leaf) {
      Remove-Item -LiteralPath $externalSentinel
    }
    if (Test-Path -LiteralPath $externalBase -PathType Container) {
      Remove-Item -LiteralPath $externalBase
    }
  }
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

    $toeRepo = Join-Path $root "pin-touchdesigner-local-artifact-checkout"
    New-LocalGitRepository -Path $toeRepo | Out-Null
    $toeDir = Join-Path $toeRepo "touchdesigner"
    New-Item -ItemType Directory -Force -Path $toeDir | Out-Null
    $toeFile = Join-Path $toeDir "20260501AITuber.toe"
    Set-Content -LiteralPath $toeFile -Value "tracked local runtime artifact fixture" -Encoding utf8
    Invoke-Checked -Command @("git", "-C", $toeRepo, "add", "touchdesigner/20260501AITuber.toe") | Out-Null
    Invoke-Checked -Command @(
      "git",
      "-C",
      $toeRepo,
      "-c",
      "user.name=Sword Agent OS Maintenance Test",
      "-c",
      "user.email=maintenance-test@example.invalid",
      "commit",
      "-q",
      "-m",
      "add touchdesigner project fixture"
    ) | Out-Null
    $toeHead = ((Invoke-Checked -Command @("git", "-C", $toeRepo, "rev-parse", "HEAD") | Select-Object -First 1) -join "").Trim()
    Set-Content -LiteralPath $toeFile -Value "dirty local runtime artifact fixture" -Encoding utf8
    $toeManifest = New-UpdateFixtureManifest -Root $root -TargetPath $toeRepo -Commit $toeHead -Id "touchdesigner-ai-controller"
    $toeOutput = Invoke-Checked -Command @(
      $PowerShellCommand,
      "-NoProfile",
      "-File",
      (Join-Path $PSScriptRoot "check-distribution-pins.ps1"),
      "-DistributionManifestPath",
      $toeManifest,
      "-Json"
    )
    $toeJson = ($toeOutput -join "`n") | ConvertFrom-Json
    if ([string]$toeJson.status -ne "warning") {
      throw "local artifact hold fixture should be warning in non-strict mode; got $($toeJson.status)"
    }
    if ([string]$toeJson.items[0].status -ne "local_artifact_hold_at_manifest_pin") {
      throw "local artifact hold fixture did not report local_artifact_hold_at_manifest_pin"
    }
    if ([int]$toeJson.local_artifact_holds -ne 1) {
      throw "local artifact hold fixture did not report local_artifact_holds=1"
    }
    if (-not [bool]$toeJson.items[0].local_artifact_hold) {
      throw "local artifact hold fixture did not set local_artifact_hold=true"
    }
    if (@($toeJson.items[0].dirty_blocking).Count -ne 0) {
      throw "local artifact hold fixture should not report dirty_blocking source changes"
    }
    Assert-TextMatch -Text ((@($toeJson.items[0].dirty_local_artifacts) -join "`n")) -Pattern "touchdesigner/20260501AITuber\.toe" -Message "local artifact hold fixture did not report the relative TouchDesigner artifact path"
    $toeStrictOutput = Invoke-ExpectFailure -Command @(
      $PowerShellCommand,
      "-NoProfile",
      "-File",
      (Join-Path $PSScriptRoot "check-distribution-pins.ps1"),
      "-DistributionManifestPath",
      $toeManifest,
      "-Strict",
      "-Json"
    )
    Assert-TextMatch -Text ($toeStrictOutput -join "`n") -Pattern "local_artifact_hold_at_manifest_pin" -Message "strict pin check should fail on local artifact hold"

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
    $workspace = Join-Path $root "renderer-workspace"
    $rendererScriptDir = Join-Path $workspace "scripts"
    $rendererLibDir = Join-Path $rendererScriptDir "lib"
    New-Item -ItemType Directory -Path $rendererLibDir -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot "render-env-files.ps1") -Destination (Join-Path $rendererScriptDir "render-env-files.ps1")
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot "lib\common.ps1") -Destination (Join-Path $rendererLibDir "common.ps1")
    $rendererScript = Join-Path $rendererScriptDir "render-env-files.ps1"
    $templateDir = Join-Path $workspace "templates"
    $targetDir = Join-Path $workspace "target"
    New-Item -ItemType Directory -Force -Path $templateDir | Out-Null
    $centralTemplate = Join-Path $templateDir "central.env.example"
    $centralEnv = Join-Path $workspace "local\env\sword-agent-os.env"
    $targetTemplate = Join-Path $templateDir "organ.env.example"
    $targetEnv = Join-Path $targetDir ".env"
    $localTargetTemplate = Join-Path $templateDir "local-organ.env.example"
    $localTargetEnv = Join-Path $targetDir "local.env"
    $configTemplate = Join-Path $templateDir "home-control.example.yaml"
    $targetConfig = Join-Path $targetDir "home-control.yaml"
    $missingTargetTemplate = Join-Path $templateDir "missing.env.example"
    $missingConfigTemplate = Join-Path $templateDir "missing-config.yaml"
    $manifestPath = Join-Path $workspace "env-fixture.json"

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
      $rendererScript,
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
      $rendererScript,
      "-DistributionManifestPath",
      $manifestPath,
      "-NoCreateCentralEnv"
    )
    Assert-TextMatch -Text ($failureOutput -join "`n") -Pattern "central env missing for non-dry-run" -Message "non-dry-run missing central env did not fail closed"

    Set-Content -LiteralPath $targetTemplate -Value @(
      "TOKEN=template-token",
      "KEEP=template-keep",
      "LOCAL_ONLY=template-local"
    ) -Encoding utf8
    Set-Content -LiteralPath $localTargetTemplate -Value @(
      "TOKEN=local-template-token",
      "KEEP=local-template-keep"
    ) -Encoding utf8
    Set-Content -LiteralPath $configTemplate -Value "enabled: true" -Encoding utf8
    New-Item -ItemType Directory -Path (Split-Path -Parent $centralEnv) -Force | Out-Null
    Copy-Item -LiteralPath $centralTemplate -Destination $centralEnv
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
          },
          [ordered]@{
            id = "local-authoritative-target"
            template_path = $localTargetTemplate
            target_path = $localTargetEnv
            preserve_local = $true
          }
        )
      }
    })

    $installOutput = Invoke-Checked -Command @(
      $PowerShellCommand,
      "-NoProfile",
      "-File",
      $rendererScript,
      "-DistributionManifestPath",
      $manifestPath
    ) | Out-Null
    Assert-PathPresent -Path $centralEnv
    Assert-PathPresent -Path $targetEnv
    Assert-PathPresent -Path $localTargetEnv
    Assert-PathPresent -Path $targetConfig
    Assert-TextMatch -Text (Get-Content -Raw -LiteralPath $targetEnv) -Pattern "TOKEN=scoped-token" -Message "target env did not inherit scoped central value"
    Assert-TextMatch -Text (Get-Content -Raw -LiteralPath $localTargetEnv) -Pattern "TOKEN=local-template-token" -Message "local-authoritative env should be copied from its own template"

    Set-Content -LiteralPath $targetEnv -Value "TOKEN=operator-override" -Encoding utf8
    Set-Content -LiteralPath $localTargetEnv -Value "TOKEN=local-operator-value" -Encoding utf8
    Invoke-Checked -Command @(
      $PowerShellCommand,
      "-NoProfile",
      "-File",
      $rendererScript,
      "-DistributionManifestPath",
      $manifestPath
    ) | Out-Null
    Assert-TextMatch -Text (Get-Content -Raw -LiteralPath $targetEnv) -Pattern "TOKEN=operator-override" -Message "target env was overwritten without -Force"

    Invoke-Checked -Command @(
      $PowerShellCommand,
      "-NoProfile",
      "-File",
      $rendererScript,
      "-DistributionManifestPath",
      $manifestPath,
      "-Force"
    ) | Out-Null
    Assert-TextMatch -Text (Get-Content -Raw -LiteralPath $targetEnv) -Pattern "TOKEN=scoped-token" -Message "target env was not refreshed with scoped value under -Force"
    Assert-TextMatch -Text (Get-Content -Raw -LiteralPath $localTargetEnv) -Pattern "TOKEN=local-operator-value" -Message "local-authoritative env was overwritten under -Force"

    $outsideManifest = Join-Path $root "outside-manifest.json"
    Copy-Item -LiteralPath $manifestPath -Destination $outsideManifest
    $outsideFailure = Invoke-ExpectFailure -Command @(
      $PowerShellCommand, "-NoProfile", "-File", $rendererScript,
      "-DistributionManifestPath", $outsideManifest, "-DryRun"
    )
    Assert-TextMatch -Text ($outsideFailure -join "`n") -Pattern "outside repository root" -Message "outside manifest was not rejected"

    $prefixCollisionDir = $workspace + "-sibling"
    New-Item -ItemType Directory -Path $prefixCollisionDir | Out-Null
    $prefixCollisionManifest = Join-Path $prefixCollisionDir "env-fixture.json"
    Copy-Item -LiteralPath $manifestPath -Destination $prefixCollisionManifest
    $prefixCollisionFailure = Invoke-ExpectFailure -Command @(
      $PowerShellCommand, "-NoProfile", "-File", $rendererScript,
      "-DistributionManifestPath", $prefixCollisionManifest, "-DryRun"
    )
    Assert-TextMatch -Text ($prefixCollisionFailure -join "`n") -Pattern "outside repository root" -Message "repository prefix-collision path was not rejected"

    $traversalFailure = Invoke-ExpectFailure -Command @(
      $PowerShellCommand, "-NoProfile", "-File", $rendererScript,
      "-DistributionManifestPath", "manifests\..\..\outside-manifest.json", "-DryRun"
    ) -WorkingDirectory $workspace
    Assert-TextMatch -Text ($traversalFailure -join "`n") -Pattern "parent traversal" -Message "parent traversal manifest was not rejected"

    $directoryTargetManifest = Join-Path $workspace "directory-target-fixture.json"
    Write-JsonFixture -Path $directoryTargetManifest -Value ([ordered]@{
      env = [ordered]@{
        central_template_path = $centralTemplate
        central_env_path = $centralEnv
        local_config_templates = @()
        targets = @([ordered]@{ id = "directory-target"; template_path = $targetTemplate; target_path = $targetDir })
      }
    })
    $directoryFailure = Invoke-ExpectFailure -Command @(
      $PowerShellCommand, "-NoProfile", "-File", $rendererScript,
      "-DistributionManifestPath", $directoryTargetManifest, "-Force"
    )
    Assert-TextMatch -Text ($directoryFailure -join "`n") -Pattern "regular file destination" -Message "directory target substitution was not rejected"

    $outsideCentralEnv = Join-Path $root "outside-central.env"
    Set-Content -LiteralPath $outsideCentralEnv -Value "TOKEN=outside" -Encoding utf8
    $outsideCentralManifest = Join-Path $workspace "outside-central-fixture.json"
    Write-JsonFixture -Path $outsideCentralManifest -Value ([ordered]@{
      env = [ordered]@{
        central_template_path = $centralTemplate
        central_env_path = $outsideCentralEnv
        local_config_templates = @()
        targets = @()
      }
    })
    $outsideCentralFailure = Invoke-ExpectFailure -Command @(
      $PowerShellCommand, "-NoProfile", "-File", $rendererScript,
      "-DistributionManifestPath", $outsideCentralManifest, "-DryRun"
    )
    Assert-TextMatch -Text ($outsideCentralFailure -join "`n") -Pattern "outside repository root" -Message "outside central env write path was not rejected"

    $reparseOutside = Join-Path $root "reparse-outside"
    $reparseLink = Join-Path $workspace "reparse-link"
    New-Item -ItemType Directory -Path $reparseOutside | Out-Null
    Set-Content -LiteralPath (Join-Path $reparseOutside "sentinel.txt") -Value "preserve" -Encoding utf8
    New-Item -ItemType Junction -Path $reparseLink -Target $reparseOutside | Out-Null
    try {
      $reparseManifest = Join-Path $workspace "reparse-target-fixture.json"
      Write-JsonFixture -Path $reparseManifest -Value ([ordered]@{
        env = [ordered]@{
          central_template_path = $centralTemplate
          central_env_path = $centralEnv
          local_config_templates = @()
          targets = @([ordered]@{ id = "reparse-target"; template_path = $targetTemplate; target_path = (Join-Path $reparseLink "generated.env") })
        }
      })
      $reparseFailure = Invoke-ExpectFailure -Command @(
        $PowerShellCommand, "-NoProfile", "-File", $rendererScript,
        "-DistributionManifestPath", $reparseManifest, "-Force"
      )
      Assert-TextMatch -Text ($reparseFailure -join "`n") -Pattern "reparse point" -Message "reparse target path was not rejected"
      Assert-PathPresent -Path (Join-Path $reparseOutside "sentinel.txt")
    }
    finally {
      if (Test-Path -LiteralPath $reparseLink) {
        Remove-Item -LiteralPath $reparseLink -Force
      }
    }
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
    "control-plane\core\scripts",
    "control-plane\core\src\sword_voice_agent\apps",
    "control-plane\core\services\thought-core"
  )
  foreach ($relativePath in $paths) {
    New-Item -ItemType Directory -Force -Path (Join-Path $Root $relativePath) | Out-Null
  }

  Set-Content -LiteralPath (Join-Path $Root "organs\action\home-assistant-server\config\home-control.yaml") -Value "actions: []" -Encoding utf8
  Set-Content -LiteralPath (Join-Path $Root "organs\action\home-assistant-server\.env") -Value @(
    "HOME_CONTROL_API_TOKEN=",
    "ENVIRONMENT_API_TOKEN="
  ) -Encoding utf8
  Set-Content -LiteralPath (Join-Path $Root "control-plane\core\.env") -Value @(
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
  Set-Content -LiteralPath (Join-Path $Root "control-plane\core\scripts\start-thought-core.ps1") -Value "" -Encoding utf8
  Set-Content -LiteralPath (Join-Path $Root "control-plane\core\scripts\start-thought-core-watch.ps1") -Value "" -Encoding utf8
  Set-Content -LiteralPath (Join-Path $Root "control-plane\core\src\sword_voice_agent\apps\watch_handoff_to_thought_core.py") -Value "" -Encoding utf8
}

function Remove-FixtureSubtree {
  param(
    [Parameter(Mandatory = $true)][string]$Workspace,
    [Parameter(Mandatory = $true)][string]$RelativePath
  )

  if ([System.IO.Path]::IsPathRooted($RelativePath) -or
      @($RelativePath -split '[\\/]' | Where-Object { $_ -eq ".." }).Count -gt 0) {
    throw "fixture subtree path must be a bounded relative path: $RelativePath"
  }

  $resolvedWorkspace = [System.IO.Path]::GetFullPath($Workspace).TrimEnd(
    [System.IO.Path]::DirectorySeparatorChar,
    [System.IO.Path]::AltDirectorySeparatorChar
  )
  $owningRecords = @(
    foreach ($entry in $OwnedFreshTestRoots.GetEnumerator()) {
      $ownedRoot = [System.IO.Path]::GetFullPath([string]$entry.Value.root).TrimEnd(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar
      )
      $ownedPrefix = $ownedRoot + [System.IO.Path]::DirectorySeparatorChar
      if ($resolvedWorkspace.StartsWith($ownedPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        [PSCustomObject]@{
          root = $ownedRoot
          record = $entry.Value
        }
      }
    }
  )
  if ($owningRecords.Count -ne 1) {
    throw "fixture workspace must belong to exactly one root created by this invocation: $resolvedWorkspace"
  }

  $ownedRoot = [string]$owningRecords[0].root
  $record = $owningRecords[0].record
  $key = $ownedRoot.ToUpperInvariant()
  if (-not $OwnedFreshTestRoots.ContainsKey($key) -or
      [string]$record.invocation_id -ne $FreshTestInvocationId) {
    throw "fixture workspace ownership record is invalid: $resolvedWorkspace"
  }
  if (-not (Test-Path -LiteralPath $ownedRoot -PathType Container)) {
    throw "owned fixture root is missing: $ownedRoot"
  }
  $rootItem = Get-Item -LiteralPath $ownedRoot -Force
  if (($rootItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 -or
      $rootItem.CreationTimeUtc.Ticks -ne [long]$record.creation_time_utc_ticks) {
    throw "owned fixture root identity changed: $ownedRoot"
  }
  $markerPath = Join-Path $ownedRoot $FreshTestOwnerMarkerName
  if (-not (Test-Path -LiteralPath $markerPath -PathType Leaf)) {
    throw "owned fixture root marker is missing: $ownedRoot"
  }
  $markerItem = Get-Item -LiteralPath $markerPath -Force
  if (($markerItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw "owned fixture root marker became a reparse point: $ownedRoot"
  }
  $marker = Get-Content -Raw -LiteralPath $markerPath | ConvertFrom-Json
  if ([string]$marker.invocation_id -ne $FreshTestInvocationId -or
      -not ([string]$marker.root).Equals($ownedRoot, [System.StringComparison]::OrdinalIgnoreCase) -or
      [long]$marker.creation_time_utc_ticks -ne [long]$record.creation_time_utc_ticks) {
    throw "owned fixture root marker does not match this invocation: $ownedRoot"
  }

  [void](Assert-NoFreshTestPathReparsePoint -Path $resolvedWorkspace -Boundary $ownedRoot -Label "fixture workspace")
  if (-not (Test-Path -LiteralPath $resolvedWorkspace -PathType Container)) {
    throw "fixture workspace is missing or no longer a directory: $resolvedWorkspace"
  }
  $workspaceItem = Get-Item -LiteralPath $resolvedWorkspace -Force
  if (($workspaceItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw "fixture workspace became a reparse point: $resolvedWorkspace"
  }

  $resolvedTarget = [System.IO.Path]::GetFullPath((Join-Path $resolvedWorkspace $RelativePath)).TrimEnd(
    [System.IO.Path]::DirectorySeparatorChar,
    [System.IO.Path]::AltDirectorySeparatorChar
  )
  $workspacePrefix = $resolvedWorkspace + [System.IO.Path]::DirectorySeparatorChar
  if (-not $resolvedTarget.StartsWith($workspacePrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "refusing to remove fixture path outside workspace: $resolvedTarget"
  }
  [void](Assert-NoFreshTestPathReparsePoint -Path $resolvedTarget -Boundary $ownedRoot -Label "fixture subtree")
  if (-not (Test-Path -LiteralPath $resolvedTarget -PathType Container)) {
    throw "fixture subtree is missing or no longer a directory: $resolvedTarget"
  }
  $targetItem = Get-Item -LiteralPath $resolvedTarget -Force
  if (($targetItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw "fixture subtree became a reparse point: $resolvedTarget"
  }
  $reparseDescendant = Get-ChildItem -LiteralPath $resolvedTarget -Force -Recurse -ErrorAction Stop |
    Where-Object { ($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 } |
    Select-Object -First 1
  if ($null -ne $reparseDescendant) {
    throw "owned fixture subtree contains a reparse point and cannot be recursively cleaned: $($reparseDescendant.FullName)"
  }

  Remove-Item -LiteralPath $resolvedTarget -Recurse -Force
  if (Test-Path -LiteralPath $resolvedTarget) {
    throw "owned fixture subtree cleanup incomplete: $resolvedTarget"
  }
}

function Test-FixtureSubtreeCleanupSafety {
  Write-TestStep "owned fixture subtree cleanup safety"
  $root = New-FreshTestRoot
  try {
    $workspace = Join-Path $root "workspace"
    $validTarget = Join-Path $workspace "valid-target"
    New-Item -ItemType Directory -Path $validTarget -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $validTarget "fixture.txt") -Value "fixture" -Encoding utf8
    Remove-FixtureSubtree -Workspace $workspace -RelativePath "valid-target"
    Assert-PathAbsent -Path $validTarget

    $sibling = Join-Path $root "workspace-sibling"
    $siblingSentinel = Join-Path $sibling "caller-owned-sentinel.txt"
    New-Item -ItemType Directory -Path $sibling -Force | Out-Null
    Set-Content -LiteralPath $siblingSentinel -Value "keep" -Encoding utf8
    $traversalRejected = $false
    try {
      Remove-FixtureSubtree -Workspace $workspace -RelativePath "..\workspace-sibling"
    }
    catch {
      $traversalRejected = $true
    }
    if (-not $traversalRejected -or -not (Test-Path -LiteralPath $siblingSentinel -PathType Leaf)) {
      throw "fixture subtree cleanup did not reject parent traversal without touching the sibling"
    }

    $missingRejected = $false
    try {
      Remove-FixtureSubtree -Workspace $workspace -RelativePath "missing-target"
    }
    catch {
      $missingRejected = $true
    }
    if (-not $missingRejected) {
      throw "fixture subtree cleanup accepted a missing target"
    }

    $markerGuardTarget = Join-Path $workspace "marker-guard-target"
    New-Item -ItemType Directory -Path $markerGuardTarget -Force | Out-Null
    $markerPath = Join-Path $root $FreshTestOwnerMarkerName
    $markerContent = Get-Content -Raw -LiteralPath $markerPath
    $tamperedMarker = $markerContent | ConvertFrom-Json
    $tamperedMarker.invocation_id = "different-invocation"
    Set-Content -LiteralPath $markerPath -Value ($tamperedMarker | ConvertTo-Json -Compress) -Encoding utf8
    $markerRejected = $false
    try {
      Remove-FixtureSubtree -Workspace $workspace -RelativePath "marker-guard-target"
    }
    catch {
      $markerRejected = $true
    }
    finally {
      Set-Content -LiteralPath $markerPath -Value $markerContent -Encoding utf8
    }
    if (-not $markerRejected -or -not (Test-Path -LiteralPath $markerGuardTarget -PathType Container)) {
      throw "fixture subtree cleanup did not reject a mismatched owner marker"
    }
    Remove-FixtureSubtree -Workspace $workspace -RelativePath "marker-guard-target"

    $externalTarget = Join-Path $root "junction-target"
    $reparseTarget = Join-Path $workspace "reparse-target"
    $junction = Join-Path $reparseTarget "linked-content"
    $externalSentinel = Join-Path $externalTarget "external-sentinel.txt"
    New-Item -ItemType Directory -Path $externalTarget -Force | Out-Null
    New-Item -ItemType Directory -Path $reparseTarget -Force | Out-Null
    Set-Content -LiteralPath $externalSentinel -Value "keep" -Encoding utf8
    New-Item -ItemType Junction -Path $junction -Target $externalTarget | Out-Null
    $reparseRejected = $false
    try {
      Remove-FixtureSubtree -Workspace $workspace -RelativePath "reparse-target"
    }
    catch {
      $reparseRejected = $true
    }
    if (-not $reparseRejected -or -not (Test-Path -LiteralPath $externalSentinel -PathType Leaf)) {
      throw "fixture subtree cleanup did not reject a reparse descendant without touching its target"
    }
    Remove-Item -LiteralPath $junction -Force
    Remove-FixtureSubtree -Workspace $workspace -RelativePath "reparse-target"
  }
  finally {
    Remove-FreshTestRoot -Path $root
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
    $compatibilityAliasReadinessIds = @($readinessIds | Where-Object { $_ -match "(^|[._-])(legacy|alias)([._-]|$)" })
    if ($compatibilityAliasReadinessIds.Count -gt 0) {
      throw "native launch readiness should not expose compatibility alias checks"
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

    $partialAiTalkWorkspace = Join-Path $root "partial-ai-talk"
    New-NativeLaunchWorkspaceFixture -Root $partialAiTalkWorkspace
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
    if ([string]$partialAiTalk.status -ne "blocked") {
      throw "partial AI Talk Core layout should block without the required speech-input service target; got $($partialAiTalk.status)"
    }
    $partialAiTalkServiceCheck = @($partialAiTalk.checks | Where-Object { [string]$_.id -eq "service_target.ai_talk_core_web" } | Select-Object -First 1)
    if (
      $partialAiTalkServiceCheck.Count -eq 0 -or
      [string]$partialAiTalkServiceCheck[0].status -ne "missing" -or
      [string]$partialAiTalkServiceCheck[0].severity -ne "blocker"
    ) {
      throw "partial AI Talk Core layout should report the required speech-input service target as a blocker"
    }
    $partialAiTalkCheck = @($partialAiTalk.checks | Where-Object { [string]$_.id -eq "native_delegate_layout.ai_talk_core" } | Select-Object -First 1)
    if ($partialAiTalkCheck.Count -eq 0 -or [string]$partialAiTalkCheck[0].status -ne "missing") {
      throw "partial AI Talk Core layout should report missing native speech-input path"
    }

    $partialControlWorkspace = Join-Path $root "partial-control-plane"
    New-NativeLaunchWorkspaceFixture -Root $partialControlWorkspace
    Remove-FixtureSubtree -Workspace $partialControlWorkspace -RelativePath "control-plane\core"
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
    $partialControlCheck = @($partialControl.checks | Where-Object { [string]$_.id -eq "native_delegate_layout.control_plane" } | Select-Object -First 1)
    if ($partialControlCheck.Count -eq 0 -or [string]$partialControlCheck[0].status -ne "missing") {
      throw "partial control-plane layout should report missing native control-plane path"
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
Test-AudioSelfOutputObservationContractStatic
Test-AcceptedUserSpeechCandidateRuntimeSessionJoinContractStatic
Test-LocalOfflineRecognizerRedactedAdapterContractStatic
Test-LocalOfflineRecognizerExecutionWrapperContractStatic
Test-OverallTestLadderReportContractStatic
Test-OverallTestLadderFrontDoorV2Static
Test-AudioAwarenessRefPolicyStatic
Test-RouteAParentNoLiveUxStatic
Test-FreshTestRootOwnershipSafety
Test-FixtureSubtreeCleanupSafety
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
