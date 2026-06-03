param(
  [string]$EndpointUrl = "http://127.0.0.1:50021/version",
  [string]$ExecutablePath = "",
  [switch]$StartIfNeeded,
  [int]$TimeoutSeconds = 60,
  [int]$PollSeconds = 2,
  [switch]$Json
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Test-VoicevoxEndpoint {
  param([Parameter(Mandatory = $true)][string]$Url)

  try {
    $response = Invoke-WebRequest -Uri $Url -Method Get -TimeoutSec 3 -UseBasicParsing
    return [PSCustomObject]@{
      ready = ($response.StatusCode -ge 200 -and $response.StatusCode -lt 500)
      detail = "http $($response.StatusCode)"
    }
  }
  catch {
    return [PSCustomObject]@{
      ready = $false
      detail = "endpoint unavailable"
    }
  }
}

function Resolve-ShortcutTarget {
  param([Parameter(Mandatory = $true)][string]$ShortcutPath)

  try {
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($ShortcutPath)
    if (-not [string]::IsNullOrWhiteSpace($shortcut.TargetPath) -and
        (Test-Path -LiteralPath $shortcut.TargetPath -PathType Leaf)) {
      return [PSCustomObject]@{
        path = $shortcut.TargetPath
        source = "start_menu_shortcut"
      }
    }

    if (-not [string]::IsNullOrWhiteSpace($shortcut.WorkingDirectory)) {
      $candidate = Join-Path $shortcut.WorkingDirectory "VOICEVOX.exe"
      if (Test-Path -LiteralPath $candidate -PathType Leaf) {
        return [PSCustomObject]@{
          path = $candidate
          source = "shortcut_workdir"
        }
      }
    }
  }
  catch {
  }

  return $null
}

function Find-VoicevoxExecutable {
  param([string]$ExplicitPath = "")

  if (-not [string]::IsNullOrWhiteSpace($ExplicitPath)) {
    $resolved = [System.IO.Path]::GetFullPath($ExplicitPath)
    if (Test-Path -LiteralPath $resolved -PathType Leaf) {
      return [PSCustomObject]@{
        path = $resolved
        source = "explicit_input"
      }
    }
    return [PSCustomObject]@{
      path = ""
      source = "explicit_input"
      missing = $true
    }
  }

  $knownCandidates = @()
  if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
    $knownCandidates += (Join-Path $env:LOCALAPPDATA "Programs\VOICEVOX\VOICEVOX.exe")
  }
  if (-not [string]::IsNullOrWhiteSpace($env:ProgramFiles)) {
    $knownCandidates += (Join-Path $env:ProgramFiles "VOICEVOX\VOICEVOX.exe")
  }
  $programFilesX86 = [Environment]::GetEnvironmentVariable("ProgramFiles(x86)")
  if (-not [string]::IsNullOrWhiteSpace($programFilesX86)) {
    $knownCandidates += (Join-Path $programFilesX86 "VOICEVOX\VOICEVOX.exe")
  }

  foreach ($candidate in $knownCandidates) {
    if (Test-Path -LiteralPath $candidate -PathType Leaf) {
      return [PSCustomObject]@{
        path = $candidate
        source = "known_pc_path"
      }
    }
  }

  $shortcutRoots = @()
  if (-not [string]::IsNullOrWhiteSpace($env:APPDATA)) {
    $shortcutRoots += (Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs")
  }
  if (-not [string]::IsNullOrWhiteSpace($env:ProgramData)) {
    $shortcutRoots += (Join-Path $env:ProgramData "Microsoft\Windows\Start Menu\Programs")
  }

  foreach ($root in $shortcutRoots) {
    if (-not (Test-Path -LiteralPath $root -PathType Container)) {
      continue
    }
    $shortcuts = @(Get-ChildItem -LiteralPath $root -Recurse -Filter "*VOICEVOX*.lnk" -ErrorAction SilentlyContinue)
    foreach ($shortcut in $shortcuts) {
      $resolvedShortcut = Resolve-ShortcutTarget -ShortcutPath $shortcut.FullName
      if ($null -ne $resolvedShortcut) {
        return $resolvedShortcut
      }
    }
  }

  return [PSCustomObject]@{
    path = ""
    source = "none"
    missing = $true
  }
}

function New-VoicevoxResult {
  param(
    [string]$EndpointInitial,
    [string]$ExecutableDiscovery,
    [string]$ExecutableSource,
    [string]$EndpointAfterStart,
    [string]$Classification,
    [string]$Note,
    [bool]$StartAttempted,
    [string]$GuiLaunchContext
  )

  return [PSCustomObject]@{
    voicevox_endpoint_checked = $true
    endpoint_url = $EndpointUrl
    endpoint_initial = $EndpointInitial
    executable_discovery = $ExecutableDiscovery
    executable_source = $ExecutableSource
    start_attempted = $StartAttempted
    gui_launch_context = $GuiLaunchContext
    endpoint_after_start = $EndpointAfterStart
    classification = $Classification
    note = $Note
    raw_audio_shared = $false
    raw_transcript_shared = $false
    raw_screenshot_shared = $false
    full_local_logs_shared = $false
    global_audio_changed_by_script = $false
    installed_or_updated_voicevox = $false
    persistent_environment_changed = $false
  }
}

$initial = Test-VoicevoxEndpoint -Url $EndpointUrl
if ($initial.ready) {
  $result = New-VoicevoxResult `
    -EndpointInitial "ready" `
    -ExecutableDiscovery "skipped_endpoint_ready" `
    -ExecutableSource "none" `
    -EndpointAfterStart "not_attempted" `
    -Classification "pass" `
    -Note "VOICEVOX endpoint responded before startup" `
    -StartAttempted $false `
    -GuiLaunchContext "not-needed"
}
elseif (-not $StartIfNeeded) {
  $result = New-VoicevoxResult `
    -EndpointInitial "not_ready" `
    -ExecutableDiscovery "not_attempted" `
    -ExecutableSource "none" `
    -EndpointAfterStart "not_attempted" `
    -Classification "skipped" `
    -Note "endpoint not ready; startup was not requested" `
    -StartAttempted $false `
    -GuiLaunchContext "not-approved"
}
else {
  $executable = Find-VoicevoxExecutable -ExplicitPath $ExecutablePath
  $hasExecutable = (-not [string]::IsNullOrWhiteSpace([string]$executable.path)) -and
    (Test-Path -LiteralPath ([string]$executable.path) -PathType Leaf)

  if (-not $hasExecutable) {
    $result = New-VoicevoxResult `
      -EndpointInitial "not_ready" `
      -ExecutableDiscovery "not_found" `
      -ExecutableSource ([string]$executable.source) `
      -EndpointAfterStart "not_attempted" `
      -Classification "blocked" `
      -Note "existing local VOICEVOX executable was not found" `
      -StartAttempted $false `
      -GuiLaunchContext "not-approved"
  }
  else {
    $launchContext = "normal-user-approved"
    $startError = ""
    try {
      Start-Process -FilePath ([string]$executable.path) | Out-Null
    }
    catch {
      $launchContext = "sandbox-blocked"
      $startError = $_.Exception.Message
    }

    if (-not [string]::IsNullOrWhiteSpace($startError)) {
      $result = New-VoicevoxResult `
        -EndpointInitial "not_ready" `
        -ExecutableDiscovery "found" `
        -ExecutableSource ([string]$executable.source) `
        -EndpointAfterStart "not_ready" `
        -Classification "blocked" `
        -Note "VOICEVOX launch failed or was blocked by the execution context" `
        -StartAttempted $true `
        -GuiLaunchContext $launchContext
    }
    else {
      $deadline = (Get-Date).AddSeconds([Math]::Max(1, $TimeoutSeconds))
      $ready = $false
      while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds ([Math]::Max(1, $PollSeconds))
        $poll = Test-VoicevoxEndpoint -Url $EndpointUrl
        if ($poll.ready) {
          $ready = $true
          break
        }
      }

      if ($ready) {
        $result = New-VoicevoxResult `
          -EndpointInitial "not_ready" `
          -ExecutableDiscovery "found" `
          -ExecutableSource ([string]$executable.source) `
          -EndpointAfterStart "ready" `
          -Classification "pass" `
          -Note "VOICEVOX endpoint responded after bounded startup" `
          -StartAttempted $true `
          -GuiLaunchContext $launchContext
      }
      else {
        $result = New-VoicevoxResult `
          -EndpointInitial "not_ready" `
          -ExecutableDiscovery "found" `
          -ExecutableSource ([string]$executable.source) `
          -EndpointAfterStart "not_ready" `
          -Classification "blocked" `
          -Note "VOICEVOX endpoint did not respond before timeout" `
          -StartAttempted $true `
          -GuiLaunchContext $launchContext
      }
    }
  }
}

if ($Json) {
  $result | ConvertTo-Json -Depth 5
  return
}

Write-Host "VOICEVOX readiness"
Write-Host ("classification={0}" -f $result.classification)
Write-Host ("endpoint_initial={0}" -f $result.endpoint_initial)
Write-Host ("executable_discovery={0}" -f $result.executable_discovery)
Write-Host ("executable_source={0}" -f $result.executable_source)
Write-Host ("start_attempted={0}" -f $result.start_attempted)
Write-Host ("gui_launch_context={0}" -f $result.gui_launch_context)
Write-Host ("endpoint_after_start={0}" -f $result.endpoint_after_start)
Write-Host ("note={0}" -f $result.note)
Write-Host "raw_audio_shared=false"
Write-Host "raw_transcript_shared=false"
Write-Host "global_audio_changed_by_script=false"
