param(
  [string]$RepoRoot = (Split-Path -Parent $PSScriptRoot),
  [Parameter(Mandatory = $true)][string]$UserStartEventName,
  [ValidateRange(30, 1800)][int]$UserStartHoldSeconds = 900,
  [ValidateRange(30, 300)][int]$InfrastructureDeadlineSeconds = 180,
  [switch]$Json
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

if ($null -eq ("SwordAgentOS.Runtime.OwnedProcessJob" -as [type])) {
  Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

namespace SwordAgentOS.Runtime {
  public sealed class OwnedProcessJob : IDisposable {
    private IntPtr handle;

    [StructLayout(LayoutKind.Sequential)]
    private struct BasicLimitInformation {
      public long PerProcessUserTimeLimit;
      public long PerJobUserTimeLimit;
      public uint LimitFlags;
      public UIntPtr MinimumWorkingSetSize;
      public UIntPtr MaximumWorkingSetSize;
      public uint ActiveProcessLimit;
      public UIntPtr Affinity;
      public uint PriorityClass;
      public uint SchedulingClass;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct IoCounters {
      public ulong ReadOperationCount;
      public ulong WriteOperationCount;
      public ulong OtherOperationCount;
      public ulong ReadTransferCount;
      public ulong WriteTransferCount;
      public ulong OtherTransferCount;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct ExtendedLimitInformation {
      public BasicLimitInformation BasicLimitInformation;
      public IoCounters IoInfo;
      public UIntPtr ProcessMemoryLimit;
      public UIntPtr JobMemoryLimit;
      public UIntPtr PeakProcessMemoryUsed;
      public UIntPtr PeakJobMemoryUsed;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct BasicAccountingInformation {
      public long TotalUserTime;
      public long TotalKernelTime;
      public long ThisPeriodTotalUserTime;
      public long ThisPeriodTotalKernelTime;
      public uint TotalPageFaultCount;
      public uint TotalProcesses;
      public uint ActiveProcesses;
      public uint TotalTerminatedProcesses;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct StartupInformation {
      public uint Size;
      public string Reserved;
      public string Desktop;
      public string Title;
      public uint X;
      public uint Y;
      public uint XSize;
      public uint YSize;
      public uint XCountChars;
      public uint YCountChars;
      public uint FillAttribute;
      public uint Flags;
      public ushort ShowWindow;
      public ushort Reserved2;
      public IntPtr Reserved2Pointer;
      public IntPtr StandardInput;
      public IntPtr StandardOutput;
      public IntPtr StandardError;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct ProcessInformation {
      public IntPtr Process;
      public IntPtr Thread;
      public uint ProcessId;
      public uint ThreadId;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr CreateJobObject(IntPtr attributes, string name);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool SetInformationJobObject(
      IntPtr job, int informationClass, ref ExtendedLimitInformation information, uint length);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CreateProcess(
      string applicationName, StringBuilder commandLine,
      IntPtr processAttributes, IntPtr threadAttributes, bool inheritHandles,
      uint creationFlags, IntPtr environment, string currentDirectory,
      ref StartupInformation startupInformation, out ProcessInformation processInformation);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern uint ResumeThread(IntPtr thread);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool TerminateProcess(IntPtr process, uint exitCode);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool TerminateJobObject(IntPtr job, uint exitCode);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool QueryInformationJobObject(
      IntPtr job, int informationClass, out BasicAccountingInformation information,
      uint length, IntPtr returnLength);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CloseHandle(IntPtr handle);

    public OwnedProcessJob() {
      handle = CreateJobObject(IntPtr.Zero, null);
      if (handle == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
      var information = new ExtendedLimitInformation();
      information.BasicLimitInformation.LimitFlags = 0x00002000;
      if (!SetInformationJobObject(
          handle, 9, ref information, (uint)Marshal.SizeOf<ExtendedLimitInformation>())) {
        int error = Marshal.GetLastWin32Error();
        CloseHandle(handle);
        handle = IntPtr.Zero;
        throw new Win32Exception(error);
      }
    }

    private static string QuoteArgument(string value) {
      if (value == null) return "\"\"";
      if (value.Length != 0 && value.IndexOfAny(new [] { ' ', '\t', '\n', '\v', '"' }) < 0) {
        return value;
      }
      var result = new StringBuilder("\"");
      int backslashes = 0;
      foreach (char character in value) {
        if (character == '\\') {
          backslashes++;
        } else if (character == '"') {
          result.Append('\\', backslashes * 2 + 1);
          result.Append('"');
          backslashes = 0;
        } else {
          result.Append('\\', backslashes);
          result.Append(character);
          backslashes = 0;
        }
      }
      result.Append('\\', backslashes * 2);
      result.Append('"');
      return result.ToString();
    }

    private static bool TerminateCreatedProcess(IntPtr process, int timeoutMs) {
      if (process == IntPtr.Zero) return true;
      uint waitResult = WaitForSingleObject(process, 0);
      if (waitResult == 0) return true;
      if (waitResult == UInt32.MaxValue) return false;
      if (!TerminateProcess(process, 1)) {
        return WaitForSingleObject(process, 0) == 0;
      }
      waitResult = WaitForSingleObject(process, (uint)Math.Max(0, timeoutMs));
      return waitResult == 0;
    }

    public Process StartSuspended(
        string executablePath, string[] arguments, out string failureClass) {
      failureClass = null;
      if (handle == IntPtr.Zero || String.IsNullOrWhiteSpace(executablePath)) {
        failureClass = "owned_process_start_failed";
        return null;
      }
      var commandLine = new StringBuilder(QuoteArgument(executablePath));
      if (arguments != null) {
        foreach (string argument in arguments) {
          commandLine.Append(' ').Append(QuoteArgument(argument));
        }
      }
      var startup = new StartupInformation();
      startup.Size = (uint)Marshal.SizeOf<StartupInformation>();
      ProcessInformation created;
      Process result = null;
      if (!CreateProcess(
          executablePath, commandLine, IntPtr.Zero, IntPtr.Zero, false,
          0x00000004u | 0x08000000u, IntPtr.Zero, null, ref startup, out created)) {
        failureClass = "owned_process_start_failed";
        return null;
      }
      try {
        try {
          result = Process.GetProcessById((int)created.ProcessId);
        } catch {
          failureClass = TerminateCreatedProcess(created.Process, 2000)
            ? "owned_process_start_failed" : "cleanup_incomplete";
          return null;
        }
        if (!AssignProcessToJobObject(handle, created.Process)) {
          failureClass = TerminateCreatedProcess(created.Process, 2000)
            ? "owned_job_assignment_failed" : "cleanup_incomplete";
          result.Dispose();
          return null;
        }
        if (ResumeThread(created.Thread) == UInt32.MaxValue) {
          failureClass = TerminateCreatedProcess(created.Process, 2000)
            ? "owned_process_resume_failed" : "cleanup_incomplete";
          result.Dispose();
          return null;
        }
        return result;
      } finally {
        CloseHandle(created.Thread);
        CloseHandle(created.Process);
      }
    }

    public uint ActiveProcessCount {
      get {
        if (handle == IntPtr.Zero) return 0;
        BasicAccountingInformation information;
        if (!QueryInformationJobObject(
            handle, 1, out information,
            (uint)Marshal.SizeOf<BasicAccountingInformation>(), IntPtr.Zero)) {
          throw new Win32Exception(Marshal.GetLastWin32Error());
        }
        return information.ActiveProcesses;
      }
    }

    public bool TerminateAndWait(int timeoutMs) {
      if (handle == IntPtr.Zero) return true;
      if (!TerminateJobObject(handle, 1)) return false;
      var stopwatch = Stopwatch.StartNew();
      while (ActiveProcessCount != 0 && stopwatch.ElapsedMilliseconds < timeoutMs) {
        Thread.Sleep(25);
      }
      return ActiveProcessCount == 0;
    }

    public void Dispose() {
      if (handle != IntPtr.Zero) {
        CloseHandle(handle);
        handle = IntPtr.Zero;
      }
    }
  }
}
'@
}

$pwshPath = "C:\Program Files\PowerShell\7\pwsh.exe"
$launcherProcess = $null
$coreProcess = $null
$chromeProcess = $null
$controllerProcess = $null
$userStartEvent = $null
$launcherStarted = $false
$stackStarted = $false
$runRoot = $null
$ownedRunId = [guid]::NewGuid().ToString("N")
$ownedJob = $null

function Throw-Fixed {
  param([Parameter(Mandatory = $true)][string]$Class)
  throw [InvalidOperationException]::new($Class)
}

function Write-Class {
  param([Parameter(Mandatory = $true)][Collections.IDictionary]$Value)
  $Value.raw_private_publication_flags = $false
  [Console]::Out.WriteLine(($Value | ConvertTo-Json -Compress -Depth 8))
  [Console]::Out.Flush()
}

function Get-RemainingBudgetMs {
  param(
    [Parameter(Mandatory = $true)]$Stopwatch,
    [Parameter(Mandatory = $true)][int]$DeadlineMs,
    [Parameter(Mandatory = $true)][string]$FailureClass
  )
  $remaining = [long]$DeadlineMs - [long]$Stopwatch.ElapsedMilliseconds
  if ($remaining -le 0) { Throw-Fixed -Class $FailureClass }
  return [int][Math]::Min([int]::MaxValue, $remaining)
}

function Wait-Until {
  param(
    [Parameter(Mandatory = $true)][scriptblock]$Condition,
    [Parameter(Mandatory = $true)]$RouteStopwatch,
    [Parameter(Mandatory = $true)][int]$RouteDeadlineMs,
    [Parameter(Mandatory = $true)][string]$FailureClass,
    [scriptblock]$SleepInvoker = { param([int]$Milliseconds) Start-Sleep -Milliseconds $Milliseconds }
  )
  while ($true) {
    $remainingMs = Get-RemainingBudgetMs -Stopwatch $RouteStopwatch `
      -DeadlineMs $RouteDeadlineMs -FailureClass $FailureClass
    try {
      $value = & $Condition
      if ($null -ne $value) { return $value }
    } catch [InvalidOperationException] {
      throw
    } catch {}
    $remainingMs = Get-RemainingBudgetMs -Stopwatch $RouteStopwatch `
      -DeadlineMs $RouteDeadlineMs -FailureClass $FailureClass
    [void](& $SleepInvoker ([Math]::Min(100, $remainingMs)))
  }
}

function Invoke-LoopbackJson {
  param(
    [Parameter(Mandatory = $true)][string]$Uri,
    [ValidateSet("GET", "POST")][string]$Method = "GET",
    [AllowNull()][object]$Body = $null,
    [hashtable]$Headers = @{},
    [ValidateRange(1, 30000)][int]$TimeoutMs = 5000
  )
  $arguments = @{
    Uri = $Uri
    Method = $Method
    TimeoutSec = [Math]::Max(1, [int][Math]::Ceiling($TimeoutMs / 1000.0))
    Headers = $Headers
  }
  if ($null -ne $Body) {
    $arguments.ContentType = "application/json"
    $arguments.Body = ($Body | ConvertTo-Json -Compress -Depth 20)
  }
  return Invoke-RestMethod @arguments
}

function Get-ProcessCreationIdentity {
  param([Parameter(Mandatory = $true)]$Value)
  if ($Value -is [datetime]) {
    return $Value.ToUniversalTime().Ticks.ToString([Globalization.CultureInfo]::InvariantCulture)
  }
  return [string]$Value
}

function New-OwnedRootIdentity {
  param([Parameter(Mandatory = $true)][Diagnostics.Process]$Process)
  try {
    $Process.Refresh()
    if ($Process.HasExited) { Throw-Fixed -Class "owned_process_identity_unavailable" }
    $rows = @(Get-CimInstance Win32_Process -Filter ("ProcessId = {0}" -f $Process.Id) -ErrorAction Stop)
    if ($rows.Count -ne 1) { Throw-Fixed -Class "owned_process_identity_unavailable" }
    $processTicks = $Process.StartTime.ToUniversalTime().Ticks
    $cimTicks = $rows[0].CreationDate.ToUniversalTime().Ticks
    if ([Math]::Abs($processTicks - $cimTicks) -gt [TimeSpan]::TicksPerMillisecond) {
      Throw-Fixed -Class "owned_process_identity_unavailable"
    }
    return [pscustomobject]@{
      ProcessId = [int]$Process.Id
      CreationIdentity = Get-ProcessCreationIdentity -Value $rows[0].CreationDate
    }
  } catch {
    if ([string]$_.Exception.Message -ceq "owned_process_identity_unavailable") { throw }
    Throw-Fixed -Class "owned_process_identity_unavailable"
  }
}

function Test-RootIdentityConflict {
  param(
    [Parameter(Mandatory = $true)][object[]]$RootIdentities,
    [Parameter(Mandatory = $true)][object[]]$ProcessRows
  )
  foreach ($root in $RootIdentities) {
    $samePidRows = @($ProcessRows | Where-Object { [int]$_.ProcessId -eq [int]$root.ProcessId })
    if (
      $samePidRows.Count -gt 0 -and
      @($samePidRows | Where-Object {
          (Get-ProcessCreationIdentity -Value $_.CreationDate) -ceq [string]$root.CreationIdentity
        }).Count -ne 1
    ) { return $true }
  }
  return $false
}

function Test-RootIdentityAmbiguity {
  param(
    [Parameter(Mandatory = $true)][object[]]$RootIdentities,
    [Parameter(Mandatory = $true)][object[]]$ProcessRows
  )
  foreach ($root in $RootIdentities) {
    $rootPid = [int]$root.ProcessId
    $matchingRoot = @($ProcessRows | Where-Object {
        [int]$_.ProcessId -eq $rootPid -and
        (Get-ProcessCreationIdentity -Value $_.CreationDate) -ceq [string]$root.CreationIdentity
      })
    if (
      $matchingRoot.Count -eq 0 -and
      @($ProcessRows | Where-Object { [int]$_.ParentProcessId -eq $rootPid }).Count -gt 0
    ) { return $true }
  }
  return $false
}

function Resolve-OwnedProcessRows {
  param(
    [Parameter(Mandatory = $true)][object[]]$RootIdentities,
    [Parameter(Mandatory = $true)][object[]]$ProcessRows
  )
  $owned = @{}
  foreach ($root in $RootIdentities) {
    $rootPid = [int]$root.ProcessId
    $samePidRows = @($ProcessRows | Where-Object { [int]$_.ProcessId -eq $rootPid })
    $matchingRootRows = @($samePidRows | Where-Object {
        (Get-ProcessCreationIdentity -Value $_.CreationDate) -ceq [string]$root.CreationIdentity
      })
    if ($matchingRootRows.Count -ne 1) { continue }
    $owned[$rootPid] = [pscustomobject]@{
      Depth = 0
      CreationTicks = [long]$root.CreationIdentity
    }
  }
  $changed = $true
  while ($changed) {
    $changed = $false
    foreach ($process in $ProcessRows) {
      $parentPid = [int]$process.ParentProcessId
      $processId = [int]$process.ProcessId
      $creationTicks = [long](Get-ProcessCreationIdentity -Value $process.CreationDate)
      if (
        $owned.ContainsKey($parentPid) -and
        -not $owned.ContainsKey($processId) -and
        $creationTicks -ge [long]$owned[$parentPid].CreationTicks
      ) {
        $owned[$processId] = [pscustomobject]@{
          Depth = [int]$owned[$parentPid].Depth + 1
          CreationTicks = $creationTicks
        }
        $changed = $true
      }
    }
  }
  return @($ProcessRows | Where-Object {
      $process = $_
      $processId = [int]$process.ProcessId
      $owned.ContainsKey($processId) -and
      [long](Get-ProcessCreationIdentity -Value $process.CreationDate) -eq
        [long]$owned[$processId].CreationTicks
    } | ForEach-Object {
      [pscustomobject]@{
        ProcessId = [int]$_.ProcessId
        ParentProcessId = [int]$_.ParentProcessId
        CreationIdentity = Get-ProcessCreationIdentity -Value $_.CreationDate
        Depth = [int]$owned[[int]$_.ProcessId].Depth
      }
    })
}

function Resolve-OwnedProcessStartFailureClass {
  param([string]$FailureClass)
  if ($FailureClass -cin @(
      "owned_process_start_failed", "owned_job_assignment_failed",
      "owned_process_resume_failed", "cleanup_incomplete")) {
    return $FailureClass
  }
  return "owned_process_start_failed"
}

function Start-OwnedProcessSuspended {
  param(
    [Parameter(Mandatory = $true)][SwordAgentOS.Runtime.OwnedProcessJob]$Job,
    [Parameter(Mandatory = $true)][string]$FilePath,
    [Parameter(Mandatory = $true)][string[]]$ArgumentList,
    [string]$StandardOutputPath,
    [string]$StandardErrorPath
  )
  $payload = [ordered]@{
    file_path = $FilePath
    argument_list = @($ArgumentList)
    standard_output_path = if ([string]::IsNullOrWhiteSpace($StandardOutputPath)) { $null } else { $StandardOutputPath }
    standard_error_path = if ([string]::IsNullOrWhiteSpace($StandardErrorPath)) { $null } else { $StandardErrorPath }
  }
  $payloadBase64 = [Convert]::ToBase64String(
    [Text.Encoding]::UTF8.GetBytes(($payload | ConvertTo-Json -Compress -Depth 4)))
  $wrapper = @"
`$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
try {
  `$payload = [Text.Encoding]::UTF8.GetString(
    [Convert]::FromBase64String("$payloadBase64")) | ConvertFrom-Json
  `$standardOutputPath = [string]`$payload.standard_output_path
  `$standardErrorPath = [string]`$payload.standard_error_path
  `$redirect = (
    -not [string]::IsNullOrWhiteSpace(`$standardOutputPath) -and
    -not [string]::IsNullOrWhiteSpace(`$standardErrorPath)
  )
  `$startInfo = [Diagnostics.ProcessStartInfo]::new()
  `$startInfo.FileName = [string]`$payload.file_path
  `$startInfo.UseShellExecute = `$false
  `$startInfo.RedirectStandardOutput = `$redirect
  `$startInfo.RedirectStandardError = `$redirect
  foreach (`$argument in @(`$payload.argument_list)) {
    [void]`$startInfo.ArgumentList.Add([string]`$argument)
  }
  `$child = [Diagnostics.Process]::new()
  `$child.StartInfo = `$startInfo
  `$standardOutputStream = `$null
  `$standardErrorStream = `$null
  try {
    if (-not `$child.Start()) { exit 1 }
    if (`$redirect) {
      `$standardOutputStream = [IO.File]::Open(
        `$standardOutputPath, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::Read)
      `$standardErrorStream = [IO.File]::Open(
        `$standardErrorPath, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::Read)
      `$standardOutputCopy = `$child.StandardOutput.BaseStream.CopyToAsync(`$standardOutputStream)
      `$standardErrorCopy = `$child.StandardError.BaseStream.CopyToAsync(`$standardErrorStream)
    }
    `$child.WaitForExit()
    if (`$redirect) {
      `$standardOutputCopy.GetAwaiter().GetResult()
      `$standardErrorCopy.GetAwaiter().GetResult()
    }
    exit [int]`$child.ExitCode
  } finally {
    if (`$null -ne `$standardOutputStream) { `$standardOutputStream.Dispose() }
    if (`$null -ne `$standardErrorStream) { `$standardErrorStream.Dispose() }
    `$child.Dispose()
  }
} catch {
  exit 1
}
"@
  $encodedWrapper = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($wrapper))
  [string]$failureClass = $null
  $process = $Job.StartSuspended(
    $pwshPath,
    [string[]]@("-NoLogo", "-NoProfile", "-NonInteractive", "-EncodedCommand", $encodedWrapper),
    [ref]$failureClass)
  if ($null -eq $process) {
    $failureClass = Resolve-OwnedProcessStartFailureClass -FailureClass $failureClass
    Throw-Fixed -Class $failureClass
  }
  return $process
}

function Get-ListeningOwnerPids {
  param([Parameter(Mandatory = $true)][int]$Port)
  return @(
    Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue |
      ForEach-Object { [int]$_.OwningProcess } |
      Sort-Object -Unique
  )
}

function Assert-PortsClear {
  param([Parameter(Mandatory = $true)][int[]]$Ports)
  foreach ($port in $Ports) {
    if (@(Get-ListeningOwnerPids -Port $port).Count -ne 0) {
      Throw-Fixed -Class "route_port_preexisting"
    }
  }
}

function Assert-PortOwnedByRoot {
  param(
    [Parameter(Mandatory = $true)][int]$Port,
    [Parameter(Mandatory = $true)]$RootIdentity
  )
  $owners = @(Get-ListeningOwnerPids -Port $Port)
  $rows = @(Get-CimInstance Win32_Process -ErrorAction Stop)
  if (Test-RootIdentityConflict -RootIdentities @($RootIdentity) -ProcessRows $rows) {
    Throw-Fixed -Class "route_port_owner_mismatch"
  }
  $lineage = @(Resolve-OwnedProcessRows -RootIdentities @($RootIdentity) -ProcessRows $rows)
  $lineageIds = @($lineage | ForEach-Object { [int]$_.ProcessId })
  if ($owners.Count -ne 1 -or $owners[0] -notin $lineageIds) {
    Throw-Fixed -Class "route_port_owner_mismatch"
  }
}

function Invoke-OwnedLauncherMutation {
  param(
    [Parameter(Mandatory = $true)]$RootIdentity,
    [Parameter(Mandatory = $true)][scriptblock]$MutationInvoker,
    [scriptblock]$OwnershipVerifier = {
      param($Identity)
      Assert-PortOwnedByRoot -Port 8799 -RootIdentity $Identity
    }
  )
  [void](& $OwnershipVerifier $RootIdentity)
  return & $MutationInvoker
}

function Assert-NoReparseAncestors {
  param([Parameter(Mandatory = $true)][string]$Path)
  $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
  while ($null -ne $item) {
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
      Throw-Fixed -Class "cleanup_incomplete"
    }
    $parent = $item.Parent
    if ($null -eq $parent -or $parent.FullName -ceq $item.FullName) { break }
    $item = $parent
  }
}

function Remove-OwnedRunRoot {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$OwnedBase,
    [Parameter(Mandatory = $true)][string]$RunId
  )
  $resolvedBase = [IO.Path]::GetFullPath($OwnedBase).TrimEnd("\", "/")
  $resolvedPath = [IO.Path]::GetFullPath($Path).TrimEnd("\", "/")
  Assert-NoReparseAncestors -Path $resolvedBase
  Assert-NoReparseAncestors -Path $resolvedPath
  $prefix = $resolvedBase + [IO.Path]::DirectorySeparatorChar
  if (-not $resolvedPath.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
    Throw-Fixed -Class "cleanup_incomplete"
  }
  if (-not [IO.Path]::GetFileName($resolvedPath).Equals("primary-system-cell-speech-test-$RunId", [StringComparison]::Ordinal)) {
    Throw-Fixed -Class "cleanup_incomplete"
  }
  $markerPath = Join-Path $resolvedPath ".owned-run"
  if (
    -not (Test-Path -LiteralPath $markerPath -PathType Leaf) -or
    (Get-Content -Raw -LiteralPath $markerPath) -cne $RunId
  ) { Throw-Fixed -Class "cleanup_incomplete" }
  $items = @(
    Get-Item -LiteralPath $resolvedPath -Force
    Get-ChildItem -LiteralPath $resolvedPath -Force -Recurse
  )
  if (@($items | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }).Count -gt 0) {
    Throw-Fixed -Class "cleanup_incomplete"
  }
  Remove-Item -LiteralPath $resolvedPath -Recurse -Force
  if (Test-Path -LiteralPath $resolvedPath) { Throw-Fixed -Class "cleanup_incomplete" }
}

function Get-ChromeExecutable {
  $candidates = @(
    (Join-Path $env:ProgramFiles "Google\Chrome\Application\chrome.exe"),
    (Join-Path ${env:ProgramFiles(x86)} "Google\Chrome\Application\chrome.exe"),
    (Join-Path $env:LOCALAPPDATA "Google\Chrome\Application\chrome.exe")
  )
  return @($candidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1)[0]
}

function Get-RequiredLauncherServices {
  return @(
    "home_assistant_bridge", "environment_state_server", "mediapipe",
    "vision_snapshot_processor", "aituber_kit", "touchdesigner_control_gui",
    "thought_core_api", "thought_core_watcher", "voicevox"
  )
}

function Wait-ControllerSignal {
  param(
    [Parameter(Mandatory = $true)][Diagnostics.Process]$Process,
    [Parameter(Mandatory = $true)][string]$ErrorPath,
    [Parameter(Mandatory = $true)][string]$ExpectedSchema,
    [Parameter(Mandatory = $true)][string]$ExpectedClass,
    [Parameter(Mandatory = $true)]$RouteStopwatch,
    [Parameter(Mandatory = $true)][int]$RouteDeadlineMs,
    [string]$FailureClass = "live_controller_signal_unavailable"
  )
  return Wait-Until -RouteStopwatch $RouteStopwatch -RouteDeadlineMs $RouteDeadlineMs `
    -FailureClass $FailureClass -Condition {
    if ($Process.HasExited) { Throw-Fixed -Class "live_controller_exited_before_signal" }
    if (-not (Test-Path -LiteralPath $ErrorPath -PathType Leaf)) { return $null }
    $matches = @()
    foreach ($line in @(Get-Content -LiteralPath $ErrorPath -ErrorAction SilentlyContinue)) {
      if ([string]::IsNullOrWhiteSpace($line)) { continue }
      try { $value = $line | ConvertFrom-Json } catch { continue }
      $keys = @($value.PSObject.Properties.Name | Sort-Object)
      if (
        ($keys -join ",") -ceq "raw_private_publication_flags,result_class,schema_version" -and
        [string]$value.schema_version -ceq $ExpectedSchema -and
        [string]$value.result_class -ceq $ExpectedClass -and
        $value.raw_private_publication_flags -is [bool] -and
        -not [bool]$value.raw_private_publication_flags
      ) { $matches += $value }
    }
    if ($matches.Count -gt 1) { Throw-Fixed -Class "live_controller_signal_duplicated" }
    if ($matches.Count -eq 1) { return $matches[0] }
    return $null
  }
}

function Get-ExpectedControllerResultKeys {
  return @(
    "schema_version", "controller_status", "scenario", "result_class",
    "expectation_class", "accepted_join_class", "capture_packet_count",
    "capture_byte_count", "signal_class", "vad_decision_class",
    "transcription_count", "submission_count", "thought_core_turninput_count",
    "endpoint_elapsed_ms", "last_vad_speech_frame_offset_ms",
    "utterance_end_to_candidate_result_ms", "utterance_end_timing_class",
    "stt_start_offset_ms", "stt_end_offset_ms", "canonical_accept_offset_ms",
    "canonical_accept_latency_class", "inflight_sink_cancellation_class",
    "presentation_class", "thought_core_first_event_elapsed_ms",
    "visible_response_class", "visible_match_count",
    "first_visible_observer_elapsed_ms", "utterance_end_to_first_visible_ms",
    "first_non_silent_audio_observation_class", "utterance_end_to_first_audio_ms",
    "controller_elapsed_ms", "window_ms", "deadline_ms", "deadline_class",
    "endpoint_completion_class", "http_status_class", "pcm_cleanup_count",
    "private_authority_residue_count", "route_owned_process_residue_count",
    "route_owned_temp_residue_count", "route_owned_request_residue_count",
    "cleanup_class", "blocker_class", "raw_audio_shared", "raw_text_shared",
    "private_identifier_shared", "private_environment_shared",
    "raw_private_publication_flags"
  )
}

function Test-IntegerValue {
  param($Value)
  return $Value -is [byte] -or $Value -is [sbyte] -or
    $Value -is [int16] -or $Value -is [uint16] -or
    $Value -is [int32] -or $Value -is [uint32] -or
    $Value -is [int64]
}

function Assert-ControllerSuccessResult {
  param([Parameter(Mandatory = $true)]$Value)
  $expectedKeys = Get-ExpectedControllerResultKeys
  if (
    $null -eq $Value -or
    (@($Value.PSObject.Properties.Name | Sort-Object) -join ",") -cne
      (@($expectedKeys | Sort-Object) -join ",") -or
    [string]$Value.schema_version -cne "self_output_awareness.live_controller.v0" -or
    [string]$Value.controller_status -cne "completed" -or
    [string]$Value.scenario -cne "independent_current_session_user_speech" -or
    [string]$Value.result_class -cne "independent_user_speech_turninput_accepted" -or
    -not (Test-IntegerValue $Value.transcription_count) -or [long]$Value.transcription_count -ne 1 -or
    -not (Test-IntegerValue $Value.submission_count) -or [long]$Value.submission_count -ne 1 -or
    -not (Test-IntegerValue $Value.thought_core_turninput_count) -or [long]$Value.thought_core_turninput_count -ne 1 -or
    -not (Test-IntegerValue $Value.route_owned_process_residue_count) -or [long]$Value.route_owned_process_residue_count -ne 0 -or
    -not (Test-IntegerValue $Value.route_owned_temp_residue_count) -or [long]$Value.route_owned_temp_residue_count -ne 0 -or
    -not (Test-IntegerValue $Value.route_owned_request_residue_count) -or [long]$Value.route_owned_request_residue_count -ne 0 -or
    [string]$Value.cleanup_class -cne "controller_http_resources_disposed_endpoint_pcm_and_authority_clear" -or
    $null -ne $Value.blocker_class -or
    $Value.raw_audio_shared -isnot [bool] -or [bool]$Value.raw_audio_shared -or
    $Value.raw_text_shared -isnot [bool] -or [bool]$Value.raw_text_shared -or
    $Value.private_identifier_shared -isnot [bool] -or [bool]$Value.private_identifier_shared -or
    $Value.private_environment_shared -isnot [bool] -or [bool]$Value.private_environment_shared -or
    $Value.raw_private_publication_flags -isnot [bool] -or [bool]$Value.raw_private_publication_flags
  ) { Throw-Fixed -Class "live_controller_result_invalid" }
  return $Value
}

function Invoke-UserSessionSequence {
  param(
    [Parameter(Mandatory = $true)][scriptblock]$PublishSessionReady,
    [Parameter(Mandatory = $true)][scriptblock]$WaitForUserStart,
    [Parameter(Mandatory = $true)][scriptblock]$StartControllerAndWaitForSystemOutputTriggerReady,
    [Parameter(Mandatory = $true)][scriptblock]$TriggerSystemOutput,
    [Parameter(Mandatory = $true)][scriptblock]$WaitForUserSpeechReady,
    [Parameter(Mandatory = $true)][scriptblock]$PublishUserCue
  )
  [void](& $StartControllerAndWaitForSystemOutputTriggerReady)
  [void](& $PublishSessionReady)
  $userStart = & $WaitForUserStart
  if ($userStart -cne "user_start_received") { Throw-Fixed -Class "user_start_not_received" }
  $dispatch = & $TriggerSystemOutput
  if ($dispatch -cne "system_output_dispatched_once") { Throw-Fixed -Class "test_ui_dispatch_not_ready" }
  [void](& $WaitForUserSpeechReady)
  [void](& $PublishUserCue)
}

function New-ExclusiveUserStartEvent {
  param([Parameter(Mandatory = $true)][string]$Name)
  $createdNew = $false
  $event = [Threading.EventWaitHandle]::new(
    $false, [Threading.EventResetMode]::ManualReset, $Name, [ref]$createdNew)
  if (-not $createdNew) {
    $event.Dispose()
    Throw-Fixed -Class "user_start_event_collision"
  }
  return $event
}

if ($MyInvocation.InvocationName -eq ".") { return }

$terminalClass = "not_started"
$blockerClass = $null
$cleanupClass = "cleanup_not_started"
$routeExitCode = 0
$resolvedRepo = $null
$ownedBase = $null
$previousCoreToken = [Environment]::GetEnvironmentVariable("AI_TALK_CORE_WEB_TOKEN", "Process")
$tokenChanged = $false
$launcherOwnershipProven = $false
$routePorts = @(3000, 8000, 8554, 8765, 8770, 8776, 8787, 8788, 8790, 8799, 8889, 18787, 9222)
try {
  if ($UserStartEventName -cnotmatch "^[A-Za-z0-9][A-Za-z0-9_.-]{7,95}$") {
    Throw-Fixed -Class "user_start_event_invalid"
  }
  if (-not (Test-Path -LiteralPath $pwshPath -PathType Leaf)) {
    Throw-Fixed -Class "pwsh_unavailable"
  }
  $preparationStopwatch = [Diagnostics.Stopwatch]::StartNew()
  $preparationDeadlineMs = $InfrastructureDeadlineSeconds * 1000
  Assert-PortsClear -Ports $routePorts
  $resolvedRepo = (Resolve-Path -LiteralPath $RepoRoot).Path
  Assert-NoReparseAncestors -Path $resolvedRepo
  $ownedBase = Join-Path $resolvedRepo ".cache\codex-owned"
  [void][IO.Directory]::CreateDirectory($ownedBase)
  Assert-NoReparseAncestors -Path $ownedBase
  $runRoot = Join-Path $ownedBase "primary-system-cell-speech-test-$ownedRunId"
  if (Test-Path -LiteralPath $runRoot) { Throw-Fixed -Class "run_root_collision" }
  [void][IO.Directory]::CreateDirectory($runRoot)
  $markerPath = Join-Path $runRoot ".owned-run"
  $markerBytes = [Text.Encoding]::ASCII.GetBytes($ownedRunId)
  $markerStream = [IO.File]::Open($markerPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
  try { $markerStream.Write($markerBytes, 0, $markerBytes.Length) } finally { $markerStream.Dispose() }
  try { $ownedJob = [SwordAgentOS.Runtime.OwnedProcessJob]::new() }
  catch { Throw-Fixed -Class "owned_job_unavailable" }

  . (Join-Path $resolvedRepo "control-plane\core\scripts\common.ps1")
  $env:AI_TALK_CORE_WEB_TOKEN = New-SwordSharedToken
  $tokenChanged = $true

  $launcherScript = Join-Path $resolvedRepo "control-plane\core\ops\scripts\home-control-stack\start-home-control-launcher.ps1"
  $launcherProcess = Start-OwnedProcessSuspended -Job $ownedJob -FilePath $pwshPath -ArgumentList @(
    "-NoLogo", "-NoProfile", "-File", $launcherScript,
    "-WorkspaceRoot", $resolvedRepo, "-HostName", "127.0.0.1", "-Port", "8799"
  ) -StandardOutputPath (Join-Path $runRoot "launcher.out.log") `
    -StandardErrorPath (Join-Path $runRoot "launcher.err.log")
  $launcherIdentity = New-OwnedRootIdentity -Process $launcherProcess
  $launcherStarted = $true

  $launcherState = Wait-Until -RouteStopwatch $preparationStopwatch `
    -RouteDeadlineMs $preparationDeadlineMs -FailureClass "launcher_unreachable" -Condition {
    try {
      Invoke-LoopbackJson -Uri "http://127.0.0.1:8799/api/state" `
        -TimeoutMs (Get-RemainingBudgetMs -Stopwatch $preparationStopwatch `
          -DeadlineMs $preparationDeadlineMs -FailureClass "launcher_unreachable")
    } catch { $null }
  }
  Assert-PortOwnedByRoot -Port 8799 -RootIdentity $launcherIdentity
  $launcherOwnershipProven = $true
  if ([string]$launcherState.config.selectedProfileId -cne "thought-core-v0") {
    Throw-Fixed -Class "launcher_primary_profile_not_selected"
  }
  if ([string]::IsNullOrWhiteSpace([string]$launcherState.config.options.MediapipeCameraName)) {
    Throw-Fixed -Class "saved_camera_selection_missing"
  }
  $cameraSelection = Invoke-LoopbackJson -Uri "http://127.0.0.1:8799/api/video-input-devices" `
    -TimeoutMs (Get-RemainingBudgetMs -Stopwatch $preparationStopwatch `
      -DeadlineMs $preparationDeadlineMs -FailureClass "preparation_deadline_exceeded")
  if (
    [string]$cameraSelection.selection_class -cne "selected_available" -or
    [bool]$cameraSelection.selected_match -ne $true -or
    [int]$cameraSelection.device_start_count -ne 0 -or
    [int]$cameraSelection.capture_count -ne 0
  ) { Throw-Fixed -Class "saved_camera_selection_not_exactly_available" }

  [void](Invoke-OwnedLauncherMutation -RootIdentity $launcherIdentity -MutationInvoker {
      Invoke-LoopbackJson -Uri "http://127.0.0.1:8799/api/start" -Method POST `
        -TimeoutMs (Get-RemainingBudgetMs -Stopwatch $preparationStopwatch `
          -DeadlineMs $preparationDeadlineMs -FailureClass "preparation_deadline_exceeded") -Body ([ordered]@{
        profileId = "thought-core-v0"
        options = $launcherState.config.options
      })
    })
  $stackStarted = $true
  $requiredServices = Get-RequiredLauncherServices
  [void](Wait-Until -RouteStopwatch $preparationStopwatch `
    -RouteDeadlineMs $preparationDeadlineMs -FailureClass "launcher_nine_service_boundary_not_ready" -Condition {
    $status = Invoke-LoopbackJson -Uri "http://127.0.0.1:8799/api/status" `
      -TimeoutMs (Get-RemainingBudgetMs -Stopwatch $preparationStopwatch `
        -DeadlineMs $preparationDeadlineMs -FailureClass "launcher_nine_service_boundary_not_ready")
    $readyCount = 0
    foreach ($serviceId in $requiredServices) {
      $service = $status.services.$serviceId
      $state = [string]$service.state
      $operational = $state -cin @("OK", "OK_EXTERNAL")
      if (
        -not $operational -and $serviceId -ceq "mediapipe" -and
        $state -ceq "DEGRADED" -and [bool]$service.camera_state_operational
      ) { $operational = $true }
      if ($operational) { $readyCount++ }
    }
    if ($readyCount -eq $requiredServices.Count) { return $status }
    return $null
  })

  $coreStatusDir = Join-Path $runRoot "core-status"
  $coreProcess = Start-OwnedProcessSuspended -Job $ownedJob -FilePath $pwshPath -ArgumentList @(
    "-NoLogo", "-NoProfile", "-File", (Join-Path $resolvedRepo "control-plane\core\scripts\start-ai-talk-core.ps1"),
    "-EnvPath", (Join-Path $resolvedRepo "local\env\sword-agent-os.env"),
    "-HostName", "127.0.0.1", "-Port", "8000", "-StatusDir", $coreStatusDir,
    "-RuntimeStatusFile", (Join-Path $coreStatusDir "runtime\ai_talk_core.json"), "-NoSaveHandoff"
  ) -StandardOutputPath (Join-Path $runRoot "core.out.log") `
    -StandardErrorPath (Join-Path $runRoot "core.err.log")
  $coreIdentity = New-OwnedRootIdentity -Process $coreProcess

  [void](Wait-Until -RouteStopwatch $preparationStopwatch `
    -RouteDeadlineMs $preparationDeadlineMs -FailureClass "canonical_input_gate_not_ready" -Condition {
    try {
      $remainingMs = Get-RemainingBudgetMs -Stopwatch $preparationStopwatch `
        -DeadlineMs $preparationDeadlineMs -FailureClass "canonical_input_gate_not_ready"
      [void](Invoke-LoopbackJson -Uri "http://127.0.0.1:8000/health" -TimeoutMs $remainingMs)
      $body = Invoke-LoopbackJson -Uri "http://127.0.0.1:8000/api/input-gate/body-state" `
        -Headers @{ "X-AI-Core-Token" = $env:AI_TALK_CORE_WEB_TOKEN } `
        -TimeoutMs (Get-RemainingBudgetMs -Stopwatch $preparationStopwatch `
          -DeadlineMs $preparationDeadlineMs -FailureClass "canonical_input_gate_not_ready")
      if ([string]$body.input_availability_class -ceq "enabled") { return $body }
    } catch {}
    return $null
  })
  Assert-PortOwnedByRoot -Port 8000 -RootIdentity $coreIdentity

  $chromeExecutable = Get-ChromeExecutable
  if ([string]::IsNullOrWhiteSpace($chromeExecutable)) { Throw-Fixed -Class "controlled_chrome_unavailable" }
  $chromeProcess = Start-OwnedProcessSuspended -Job $ownedJob -FilePath $chromeExecutable -ArgumentList @(
    "--remote-debugging-port=9222", "--remote-debugging-address=127.0.0.1",
    "--user-data-dir=$(Join-Path $runRoot 'chrome-profile')", "--no-first-run",
    "--no-default-browser-check", "--new-window", "http://127.0.0.1:3000/projection-visual/"
  )
  $chromeIdentity = New-OwnedRootIdentity -Process $chromeProcess
  [void](Wait-Until -RouteStopwatch $preparationStopwatch `
    -RouteDeadlineMs $preparationDeadlineMs -FailureClass "controlled_chrome_cdp_unavailable" -Condition {
    try {
      Invoke-LoopbackJson -Uri "http://127.0.0.1:9222/json/version" `
        -TimeoutMs (Get-RemainingBudgetMs -Stopwatch $preparationStopwatch `
          -DeadlineMs $preparationDeadlineMs -FailureClass "controlled_chrome_cdp_unavailable")
    } catch { $null }
  })
  Assert-PortOwnedByRoot -Port 9222 -RootIdentity $chromeIdentity
  $ownerTimeoutMs = [Math]::Min(10000, (Get-RemainingBudgetMs `
      -Stopwatch $preparationStopwatch -DeadlineMs $preparationDeadlineMs `
      -FailureClass "projection_owner_not_ready"))
  $ownerPrepare = (& node (Join-Path $resolvedRepo "scripts\drive-primary-system-cell-test-ui.mjs") `
    --prepare-owner --cdp-endpoint http://127.0.0.1:9222 --timeout-ms $ownerTimeoutMs) | ConvertFrom-Json
  if ([string]$ownerPrepare.result_class -cnotin @("projection_owner_ready", "projection_owner_created")) {
    Throw-Fixed -Class "projection_owner_not_ready"
  }

  $controllerOut = Join-Path $runRoot "controller.out.json"
  $controllerErr = Join-Path $runRoot "controller.err.log"
  $userStartEvent = New-ExclusiveUserStartEvent -Name $UserStartEventName

  Invoke-UserSessionSequence `
    -PublishSessionReady {
      Write-Class ([ordered]@{
        schema_version = "primary_system_cell_speech_test_prepare.v1"
        result_class = "ready_for_user_session_start"
        saved_camera_selection_class = "selected_available"
        launcher_service_count = 9
        input_availability_class = "enabled"
        projection_owner_class = [string]$ownerPrepare.result_class
        user_clock_started = $false
        test_dispatch_count = 0
      })
    } `
    -WaitForUserStart {
      $holdStopwatch = [Diagnostics.Stopwatch]::StartNew()
      [void](Wait-ControllerSignal -Process $controllerProcess -ErrorPath $controllerErr `
        -ExpectedSchema "self_output_awareness.user_start_received.v0" `
        -ExpectedClass "user_start_received" -RouteStopwatch $holdStopwatch `
        -RouteDeadlineMs ($UserStartHoldSeconds * 1000) -FailureClass "prepared_hold_expired")
      $script:postStartStopwatch = [Diagnostics.Stopwatch]::StartNew()
      $script:postStartDeadlineMs = 10000
      return "user_start_received"
    } `
    -StartControllerAndWaitForSystemOutputTriggerReady {
      $script:controllerProcess = Start-OwnedProcessSuspended -Job $ownedJob -FilePath $pwshPath -ArgumentList @(
        "-NoLogo", "-NoProfile", "-File", (Join-Path $resolvedRepo "scripts\run-self-output-awareness-live-controller.ps1"),
        "-BaseUrl", "http://127.0.0.1:8000", "-AitBaseUrl", "http://127.0.0.1:3000",
        "-Scenario", "independent_current_session_user_speech", "-WindowMs", "3000",
        "-DeadlineMs", "10000", "-ControlledChromeRootPid", [string]$chromeProcess.Id,
        "-CdpEndpoint", "http://127.0.0.1:9222", "-AudioObserverWindowMs", "3000",
        "-PreparationDeadlineMs", "10000", "-UserStartEventName", $UserStartEventName,
        "-UserStartHoldMs", [string]($UserStartHoldSeconds * 1000), "-EmitUserSpeechReadySignal"
      ) -StandardOutputPath $controllerOut -StandardErrorPath $controllerErr
      $script:controllerIdentity = New-OwnedRootIdentity -Process $controllerProcess
      Wait-ControllerSignal -Process $controllerProcess -ErrorPath $controllerErr `
        -ExpectedSchema "self_output_awareness.system_output_trigger_ready.v0" `
        -ExpectedClass "ready_for_system_output_trigger" `
        -RouteStopwatch $preparationStopwatch -RouteDeadlineMs $preparationDeadlineMs
    } `
    -TriggerSystemOutput {
      $dispatchTimeoutMs = [Math]::Min(5000, (Get-RemainingBudgetMs `
          -Stopwatch $postStartStopwatch -DeadlineMs $postStartDeadlineMs `
          -FailureClass "post_start_deadline_exceeded"))
      $uiResult = (& node (Join-Path $resolvedRepo "scripts\drive-primary-system-cell-test-ui.mjs") `
        --cdp-endpoint http://127.0.0.1:9222 --timeout-ms $dispatchTimeoutMs) | ConvertFrom-Json
      if (
        [string]$uiResult.result_class -cne "test_ui_seed_dispatched" -or
        [int]$uiResult.ui_dispatch_count -ne 1
      ) { Throw-Fixed -Class "test_ui_dispatch_not_ready" }
      return "system_output_dispatched_once"
    } `
    -WaitForUserSpeechReady {
      Wait-ControllerSignal -Process $controllerProcess -ErrorPath $controllerErr `
        -ExpectedSchema "self_output_awareness.live_controller_ready.v0" `
        -ExpectedClass "ready_for_user_speech" `
        -RouteStopwatch $postStartStopwatch -RouteDeadlineMs $postStartDeadlineMs
    } `
    -PublishUserCue {
      Write-Class ([ordered]@{
        schema_version = "primary_system_cell_speech_test_cue.v1"
        result_class = "issue_user_cue_now"
        user_clock_started = $true
        test_dispatch_count = 1
      })
    }

  if (-not $controllerProcess.WaitForExit(12000)) { Throw-Fixed -Class "live_controller_did_not_finish" }
  if ($controllerProcess.ExitCode -ne 0) { Throw-Fixed -Class "live_controller_failed" }
  $resultText = $(if (Test-Path -LiteralPath $controllerOut -PathType Leaf) {
      (Get-Content -Raw -LiteralPath $controllerOut).Trim()
    } else { "" })
  if ([string]::IsNullOrWhiteSpace($resultText)) { Throw-Fixed -Class "live_controller_result_missing" }
  try { $controllerResult = $resultText | ConvertFrom-Json }
  catch { Throw-Fixed -Class "live_controller_result_invalid" }
  $controllerResult = Assert-ControllerSuccessResult -Value $controllerResult
  $terminalClass = [string]$controllerResult.result_class
  Write-Class ([ordered]@{
    schema_version = "primary_system_cell_speech_test_terminal.v1"
    result_class = $terminalClass
    blocker_class = [string]$controllerResult.blocker_class
    transcription_count = [int]$controllerResult.transcription_count
    submission_count = [int]$controllerResult.submission_count
    thought_core_turninput_count = [int]$controllerResult.thought_core_turninput_count
    cleanup_class = [string]$controllerResult.cleanup_class
  })
} catch {
  $routeExitCode = 1
  $terminalClass = "preparation_or_live_blocked"
  $allowedBlockers = @(
    "user_start_event_invalid", "pwsh_unavailable", "cleanup_incomplete",
    "route_port_preexisting", "route_port_owner_mismatch", "run_root_collision",
    "user_start_event_collision", "owned_process_identity_unavailable",
    "owned_job_unavailable", "owned_process_start_failed",
    "owned_job_assignment_failed", "owned_process_resume_failed", "launcher_unreachable",
    "launcher_primary_profile_not_selected", "saved_camera_selection_missing",
    "saved_camera_selection_not_exactly_available",
    "launcher_nine_service_boundary_not_ready", "canonical_input_gate_not_ready",
    "controlled_chrome_unavailable", "controlled_chrome_cdp_unavailable",
    "projection_owner_not_ready", "live_controller_signal_unavailable",
    "live_controller_exited_before_signal", "live_controller_signal_duplicated",
    "user_start_not_received", "prepared_hold_expired", "test_ui_dispatch_not_ready",
    "live_controller_did_not_finish", "live_controller_failed",
    "live_controller_result_missing", "live_controller_result_invalid",
    "preparation_deadline_exceeded", "post_start_deadline_exceeded"
  )
  $candidateBlocker = [string]$_.Exception.Message
  $blockerClass = $(if ($candidateBlocker -cin $allowedBlockers) {
      $candidateBlocker
    } else {
      "preparation_internal_failure"
    })
  Write-Class ([ordered]@{
    schema_version = "primary_system_cell_speech_test_error.v1"
    result_class = $terminalClass
    blocker_class = $blockerClass
    test_dispatch_count = 0
  })
} finally {
  $launcherMutationOwnershipClear = $true
  if ($stackStarted -and $launcherOwnershipProven) {
    try {
      [void](Invoke-OwnedLauncherMutation -RootIdentity $launcherIdentity -MutationInvoker {
          Invoke-LoopbackJson -Uri "http://127.0.0.1:8799/api/stop" -Method POST -Body @{}
        })
    } catch { $launcherMutationOwnershipClear = $false }
  }
  if ($launcherStarted -and $launcherOwnershipProven) {
    try {
      [void](Invoke-OwnedLauncherMutation -RootIdentity $launcherIdentity -MutationInvoker {
          Invoke-LoopbackJson -Uri "http://127.0.0.1:8799/api/shutdown" -Method POST -Body @{}
        })
    } catch { $launcherMutationOwnershipClear = $false }
  }
  if ($null -ne $userStartEvent) { $userStartEvent.Dispose() }
  try {
    if ($null -ne $ownedJob) {
      if (-not $ownedJob.TerminateAndWait(5000)) { Throw-Fixed -Class "cleanup_incomplete" }
      if ($ownedJob.ActiveProcessCount -ne 0) { Throw-Fixed -Class "cleanup_incomplete" }
      $ownedJob.Dispose()
      $ownedJob = $null
    }
    Assert-PortsClear -Ports $routePorts
    if (-not $launcherMutationOwnershipClear) { Throw-Fixed -Class "cleanup_incomplete" }
    if ($tokenChanged) {
      [Environment]::SetEnvironmentVariable("AI_TALK_CORE_WEB_TOKEN", $previousCoreToken, "Process")
      $tokenChanged = $false
      $previousCoreToken = $null
    }
    if ($null -ne $runRoot -and $null -ne $ownedBase) {
      Remove-OwnedRunRoot -Path $runRoot -OwnedBase $ownedBase -RunId $ownedRunId
    }
    $cleanupClass = "route_owned_processes_and_temp_cleared"
  } catch {
    $cleanupClass = "cleanup_incomplete"
    if ($terminalClass -cne "preparation_or_live_blocked") {
      $terminalClass = "preparation_or_live_blocked"
      $blockerClass = "cleanup_incomplete"
    }
    $routeExitCode = 1
  }
  if ($tokenChanged) {
    [Environment]::SetEnvironmentVariable("AI_TALK_CORE_WEB_TOKEN", $previousCoreToken, "Process")
    $tokenChanged = $false
    $previousCoreToken = $null
  }
  if ($null -ne $ownedJob) {
    try { [void]$ownedJob.TerminateAndWait(1000) } catch {}
    try { $ownedJob.Dispose() } catch {}
    $ownedJob = $null
  }
  Write-Class ([ordered]@{
    schema_version = "primary_system_cell_speech_test_cleanup.v1"
    result_class = "preparation_route_cleanup_completed"
    cleanup_class = $cleanupClass
    terminal_class = $terminalClass
    blocker_class = $blockerClass
  })
}
exit $routeExitCode
