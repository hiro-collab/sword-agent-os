param(
  [ValidateSet("manifest_default", "isolated_override")]
  [string]$PortMode = "manifest_default",
  [ValidateSet("strict", "process")]
  [string]$WebSocketProbeMode = "process",
  [int]$IntervalSeconds = 5,
  [int]$DurationSeconds = 0,
  [int]$TimeoutMs = 1200,
  [string]$WorkspaceRoot = "",
  [string]$StackStateDir = "",
  [string]$LogPath = ".cache/agent-os/diagnostics-watch/watch.log",
  [switch]$ManifestOnly,
  [switch]$NoJournal
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

function Ensure-DirectoryForFile {
  param([Parameter(Mandatory = $true)][string]$Path)
  $directory = Split-Path -Parent $Path
  if (-not [string]::IsNullOrWhiteSpace($directory) -and -not (Test-Path -LiteralPath $directory -PathType Container)) {
    [void](New-Item -ItemType Directory -Force -Path $directory)
  }
}

if ($IntervalSeconds -lt 1) {
  throw "IntervalSeconds must be 1 or greater."
}

$resolvedLogPath = Resolve-RepoPath $LogPath
Ensure-DirectoryForFile -Path $resolvedLogPath

$startedAt = [DateTimeOffset]::Now
$deadline = if ($DurationSeconds -gt 0) { $startedAt.AddSeconds($DurationSeconds) } else { $null }
$updateScript = Join-Path $PSScriptRoot "update-diagnostics-status.ps1"
$iteration = 0

while ($true) {
  $iteration += 1
  $now = [DateTimeOffset]::Now
  try {
    $arguments = @{
      PortMode = $PortMode
      WebSocketProbeMode = $WebSocketProbeMode
      TimeoutMs = $TimeoutMs
    }
    if (-not [string]::IsNullOrWhiteSpace($WorkspaceRoot)) {
      $arguments.WorkspaceRoot = $WorkspaceRoot
    }
    if (-not [string]::IsNullOrWhiteSpace($StackStateDir)) {
      $arguments.StackStateDir = $StackStateDir
    }
    if ($ManifestOnly) {
      $arguments.ManifestOnly = $true
    }
    if ($NoJournal) {
      $arguments.NoJournal = $true
    }

    $result = & $updateScript @arguments
    $summary = ($result | Out-String).Trim()
    Add-Content -LiteralPath $resolvedLogPath -Encoding UTF8 -Value "$($now.ToString("o")) iteration=$iteration status=ok $summary"
  }
  catch {
    Add-Content -LiteralPath $resolvedLogPath -Encoding UTF8 -Value "$($now.ToString("o")) iteration=$iteration status=error $($_.Exception.Message)"
  }

  if ($null -ne $deadline -and [DateTimeOffset]::Now -ge $deadline) {
    break
  }
  Start-Sleep -Seconds $IntervalSeconds
}
