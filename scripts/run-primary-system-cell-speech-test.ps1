param(
  [string]$RepoRoot = (Split-Path -Parent $PSScriptRoot),
  [string]$TestMode = "genuine_user_speech",
  [string]$UserStartEventName = "",
  [ValidateRange(30, 1800)][int]$UserStartHoldSeconds = 900,
  [ValidateRange(30, 300)][int]$InfrastructureDeadlineSeconds = 180,
  [ValidateRange(30, 120)][int]$CleanupStopTimeoutSeconds = 70,
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
$ownedRunId = $null
$ownedJob = $null
$testDispatchCount = 0

function Throw-Fixed {
  param([Parameter(Mandatory = $true)][string]$Class)
  throw [InvalidOperationException]::new($Class)
}

function Resolve-ProjectionOwnerPrepareClass {
  param([AllowNull()]$Value)
  $allowed = @(
    "projection_owner_ready", "projection_owner_created",
    "test_ui_configuration_invalid", "test_ui_cdp_session_invalid",
    "cdp_endpoint_unavailable", "cdp_target_list_invalid",
    "projection_owner_page_missing", "projection_owner_page_multiple",
    "projection_owner_target_invalid", "projection_owner_target_create_failed",
    "projection_owner_prepare_timeout", "projection_owner_input_hydration_timeout",
    "projection_owner_reload_command_timeout", "projection_owner_reload_observation_timeout",
    "projection_owner_observer_arm_timeout", "projection_owner_prepare_failed",
    "projection_owner_target_discovery_failed", "projection_owner_target_readiness_failed",
    "projection_owner_target_selection_failed", "projection_owner_cdp_connect_failed",
    "projection_owner_input_hydration_failed", "projection_owner_reload_command_failed",
    "projection_owner_reload_observation_failed", "projection_owner_observer_arm_failed",
    "test_ui_cleanup_incomplete", "test_ui_page_cleanup_command_failed",
    "test_ui_page_cleanup_state_invalid", "test_ui_socket_cleanup_incomplete"
  )
  if ($null -eq $Value) { return "projection_owner_prepare_failed" }
  $resultClassProperty = $Value.PSObject.Properties["result_class"]
  if ($null -eq $resultClassProperty) { return "projection_owner_prepare_failed" }
  $candidate = [string]$resultClassProperty.Value
  if ($candidate -cin $allowed) { return $candidate }
  return "projection_owner_prepare_failed"
}

function Resolve-ProjectionOwnerErrorDetailClass {
  param(
    [AllowNull()][string]$BlockerClass,
    [AllowNull()][string]$PrepareClass
  )
  if ($BlockerClass -cne "projection_owner_not_ready") { return $null }
  return Resolve-ProjectionOwnerPrepareClass -Value ([pscustomobject]@{
      result_class = $PrepareClass
    })
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
    [ValidateRange(1, 120000)][int]$TimeoutMs = 5000
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
      `$streamOptions = [IO.FileOptions]::Asynchronous -bor [IO.FileOptions]::WriteThrough
      `$standardOutputStream = [IO.FileStream]::new(
        `$standardOutputPath, [IO.FileMode]::Create, [IO.FileAccess]::Write,
        [IO.FileShare]::Read, 1, `$streamOptions)
      `$standardErrorStream = [IO.FileStream]::new(
        `$standardErrorPath, [IO.FileMode]::Create, [IO.FileAccess]::Write,
        [IO.FileShare]::Read, 1, `$streamOptions)
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
  param(
    [Parameter(Mandatory = $true)][int[]]$Ports,
    [scriptblock]$ListenerReader = {
      @(Get-NetTCPConnection -State Listen -ErrorAction Stop)
    }
  )
  try { $listeners = @(& $ListenerReader) }
  catch { Throw-Fixed -Class "cleanup_incomplete" }
  foreach ($port in $Ports) {
    if (@($listeners | Where-Object { [int]$_.LocalPort -eq $port }).Count -ne 0) {
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

function Complete-OwnedRouteCleanup {
  param(
    [AllowNull()]$OwnedJob,
    [Parameter(Mandatory = $true)][int[]]$Ports,
    [AllowNull()][string]$RunRoot,
    [AllowNull()][string]$OwnedBase,
    [AllowNull()][string]$RunId,
    [AllowNull()][string]$LauncherCleanupFailureClass,
    [scriptblock]$PortsClearVerifier = {
      param($ExpectedPorts)
      Assert-PortsClear -Ports $ExpectedPorts
    },
    [ValidateRange(1, 5000)][int]$JobCleanupBudgetMs = 5000,
    [scriptblock]$PortSettlementWaiter = {
      param($DelayMs)
      Start-Sleep -Milliseconds $DelayMs
    },
    [scriptblock]$RunRootRemover = {
      param($Path, $Base, $Id)
      Remove-OwnedRunRoot -Path $Path -OwnedBase $Base -RunId $Id
    }
  )
  $fixedLauncherFailure = $null
  if (-not [string]::IsNullOrWhiteSpace($LauncherCleanupFailureClass)) {
    if ($LauncherCleanupFailureClass -cnotin @(
        "launcher_standard_stop_failed",
        "launcher_shutdown_failed"
      )) {
      return [pscustomobject]@{
        cleanup_class = "cleanup_incomplete"
        cleanup_failure_class = "cleanup_unclassified"
        job_disposed = $false
      }
    }
    $fixedLauncherFailure = $LauncherCleanupFailureClass
  }
  $requiresStandardStopRecoveryProof =
    $fixedLauncherFailure -ceq "launcher_standard_stop_failed"
  $hasOwnedJobRecoveryProof = $null -ne $OwnedJob
  $hasRunRoot = -not [string]::IsNullOrWhiteSpace($RunRoot)
  $hasOwnedBase = -not [string]::IsNullOrWhiteSpace($OwnedBase)
  $hasRunId = -not [string]::IsNullOrWhiteSpace($RunId)
  $hasAnyRootTupleValue = $hasRunRoot -or $hasOwnedBase -or $hasRunId
  $hasCompleteRootRecoveryProof = $hasRunRoot -and $hasOwnedBase -and $hasRunId

  $jobDisposed = $false
  $jobCleanupStopwatch = [Diagnostics.Stopwatch]::StartNew()
  try {
    if ($null -ne $OwnedJob) {
      if (-not $OwnedJob.TerminateAndWait($JobCleanupBudgetMs)) {
        Throw-Fixed -Class "cleanup_incomplete"
      }
      if ($OwnedJob.ActiveProcessCount -ne 0) {
        Throw-Fixed -Class "cleanup_incomplete"
      }
      $OwnedJob.Dispose()
      $jobDisposed = $true
    }
  } catch {
    $jobCleanupStopwatch.Stop()
    return [pscustomobject]@{
      cleanup_class = "cleanup_incomplete"
      cleanup_failure_class = "owned_job_cleanup_failed"
      job_disposed = $jobDisposed
    }
  }

  $portFailureClass = $null
  do {
    try {
      [void](& $PortsClearVerifier $Ports)
      $portFailureClass = $null
      break
    } catch {
      $fixedPortFailure = [string]$_.Exception.Message
      $portFailureClass = $(switch ($fixedPortFailure) {
          "route_port_preexisting" { "route_port_cleanup_failed" }
          "cleanup_incomplete" { "route_port_inspection_failed" }
          default { "cleanup_unclassified" }
        })
    }
    if (-not $jobDisposed) { break }
    $remainingSettlementMs = $JobCleanupBudgetMs -
      [int]$jobCleanupStopwatch.ElapsedMilliseconds
    if ($remainingSettlementMs -le 0) { break }
    try {
      [void](& $PortSettlementWaiter ([Math]::Min(50, $remainingSettlementMs)))
    } catch {
      $portFailureClass = "cleanup_unclassified"
      break
    }
    if ([int]$jobCleanupStopwatch.ElapsedMilliseconds -ge $JobCleanupBudgetMs) {
      break
    }
  } while ($true)
  $jobCleanupStopwatch.Stop()
  if ($null -ne $portFailureClass) {
    return [pscustomobject]@{
      cleanup_class = "cleanup_incomplete"
      cleanup_failure_class = $portFailureClass
      job_disposed = $jobDisposed
    }
  }
  if ($requiresStandardStopRecoveryProof -and -not $hasOwnedJobRecoveryProof) {
    return [pscustomobject]@{
      cleanup_class = "cleanup_incomplete"
      cleanup_failure_class = "owned_job_cleanup_failed"
      job_disposed = $jobDisposed
    }
  }
  if ($requiresStandardStopRecoveryProof -and -not $hasCompleteRootRecoveryProof) {
    return [pscustomobject]@{
      cleanup_class = "cleanup_incomplete"
      cleanup_failure_class = "run_root_cleanup_failed"
      job_disposed = $jobDisposed
    }
  }

  if ($hasAnyRootTupleValue -and -not $hasCompleteRootRecoveryProof) {
    return [pscustomobject]@{
      cleanup_class = "cleanup_incomplete"
      cleanup_failure_class = "run_root_cleanup_failed"
      job_disposed = $jobDisposed
    }
  }
  if ($hasCompleteRootRecoveryProof) {
    try { [void](& $RunRootRemover $RunRoot $OwnedBase $RunId) }
    catch {
      return [pscustomobject]@{
        cleanup_class = "cleanup_incomplete"
        cleanup_failure_class = "run_root_cleanup_failed"
        job_disposed = $jobDisposed
      }
    }
  }

  return [pscustomobject]@{
    cleanup_class = $(if ($null -ne $fixedLauncherFailure) {
        "route_owned_processes_and_temp_cleared_by_owned_job_recovery"
      } else {
        "route_owned_processes_and_temp_cleared"
      })
    cleanup_failure_class = $fixedLauncherFailure
    job_disposed = $jobDisposed
  }
}

function Get-ChromeExecutable {
  $candidates = @(
    (Join-Path $env:ProgramFiles "Google\Chrome\Application\chrome.exe"),
    (Join-Path ${env:ProgramFiles(x86)} "Google\Chrome\Application\chrome.exe"),
    (Join-Path $env:LOCALAPPDATA "Google\Chrome\Application\chrome.exe")
  )
  return @($candidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1)[0]
}

function Get-LauncherRouteContract {
  param([Parameter(Mandatory = $true)][string]$Mode)

  if ($Mode -ceq "genuine_user_speech") {
    return [pscustomobject]@{
      profile_id = "thought-core-v0"
      requires_saved_camera = $true
      camera_selection_class = "selected_available"
      readiness_failure_class = "launcher_nine_service_boundary_not_ready"
      required_services = @(
        "home_assistant_bridge", "environment_state_server", "mediapipe",
        "vision_snapshot_processor", "aituber_kit", "touchdesigner_control_gui",
        "thought_core_api", "thought_core_watcher", "voicevox"
      )
    }
  }
  if ($Mode -ceq "unattended_self_output_suppression") {
    return [pscustomobject]@{
      profile_id = "demo-fast"
      requires_saved_camera = $false
      camera_selection_class = "camera_disabled"
      readiness_failure_class = "launcher_demo_service_boundary_not_ready"
      required_services = @("aituber_kit", "thought_core_api", "voicevox")
    }
  }
  Throw-Fixed -Class "launcher_route_contract_invalid"
}

function Assert-LauncherCameraReadiness {
  param(
    [Parameter(Mandatory = $true)][psobject]$Contract,
    [AllowNull()]$LauncherOptions,
    [Parameter(Mandatory = $true)][scriptblock]$CameraSelectionInvoker
  )

  if ($null -eq $LauncherOptions) {
    Throw-Fixed -Class "launcher_route_contract_invalid"
  }
  if (-not [bool]$Contract.requires_saved_camera) {
    if (
      [string]$Contract.camera_selection_class -cne "camera_disabled" -or
      -not [bool]$LauncherOptions.SkipMediapipe
    ) { Throw-Fixed -Class "launcher_route_contract_invalid" }
    return "camera_disabled"
  }
  if (
    [string]$Contract.camera_selection_class -cne "selected_available" -or
    [bool]$LauncherOptions.SkipMediapipe
  ) { Throw-Fixed -Class "launcher_route_contract_invalid" }
  if ([string]::IsNullOrWhiteSpace([string]$LauncherOptions.MediapipeCameraName)) {
    Throw-Fixed -Class "saved_camera_selection_missing"
  }
  $cameraSelection = & $CameraSelectionInvoker
  if (
    [string]$cameraSelection.selection_class -cne "selected_available" -or
    [bool]$cameraSelection.selected_match -ne $true -or
    [int]$cameraSelection.device_start_count -ne 0 -or
    [int]$cameraSelection.capture_count -ne 0
  ) { Throw-Fixed -Class "saved_camera_selection_not_exactly_available" }
  return "selected_available"
}

function Test-AitLifecyclePreflightResponse {
  param([AllowNull()]$Value)
  if ($null -eq $Value -or $Value -isnot [psobject]) { return $false }
  $expectedKeys = @(
    "ok", "result_class", "transport", "raw_private_publication_flags")
  if (
    (@($Value.PSObject.Properties.Name | Sort-Object) -join ",") -cne
      (@($expectedKeys | Sort-Object) -join ",") -or
    $Value.ok -isnot [bool] -or -not [bool]$Value.ok -or
    $Value.raw_private_publication_flags -isnot [bool] -or
    [bool]$Value.raw_private_publication_flags
  ) { return $false }
  return (
    $null -eq $Value.transport -and
    [string]$Value.result_class -ceq "lifecycle_transport_empty")
}

function Get-AllowedControllerBlockedResultClasses {
  return @(
    "scenario_expectation_not_met",
    "live_candidate_request_invalid",
    "live_candidate_window_busy",
    "input_source_epoch_unavailable",
    "input_gate_capability_unavailable",
    "speech_timing_observation_missing",
    "voice_response_latency_over_10s",
    "private_transcription_not_accepted",
    "private_turn_sink_unavailable",
    "private_turn_sink_failed",
    "live_candidate_environment_unavailable",
    "live_candidate_processing_failed",
    "live_candidate_window_failed",
    "processed_pcm_pipe_lease_invalid",
    "processed_pcm_pipe_owner_unavailable",
    "processed_pcm_pipe_lease_missing",
    "processed_pcm_pipe_lease_expired",
    "processed_pcm_pipe_server_identity_mismatch",
    "processed_pcm_pipe_private_input_timeout",
    "processed_pcm_pipe_connect_failed",
    "processed_pcm_pipe_connect_timeout",
    "processed_pcm_pipe_handshake_failed",
    "processed_pcm_pipe_write_failed",
    "live_aec_backend_or_sink_missing",
    "live_aec_bounds_invalid",
    "live_aec_processing_mode_invalid",
    "live_aec_processed_packet_invalid",
    "live_aec_deadline_exceeded",
    "live_aec_cleanup_failed",
    "live_aec_quality_metrics_cleanup_failed",
    "live_aec_quality_metrics_invariant_failed",
    "live_aec_lifecycle_invariant_failed",
    "voice_capture_dsp_activation_failed",
    "voice_capture_dsp_configuration_failed",
    "voice_capture_dsp_output_format_failed",
    "voice_capture_dsp_start_failed",
    "voice_capture_dsp_not_started",
    "voice_capture_dsp_process_output_failed",
    "voice_capture_dsp_stop_failed",
    "live_aec_observer_failed"
  )
}

function Get-EarlyControllerBlockerClass {
  param([Parameter(Mandatory = $true)][string]$OutputPath)
  if (-not (Test-Path -LiteralPath $OutputPath -PathType Leaf)) { return $null }
  try { $file = Get-Item -LiteralPath $OutputPath -Force -ErrorAction Stop }
  catch { return $null }
  if ($file.Length -gt 16384) { return "live_controller_result_invalid" }
  $rawText = Get-Content -Raw -LiteralPath $OutputPath -ErrorAction SilentlyContinue
  if ($null -eq $rawText) { return $null }
  $text = $rawText.Trim()
  if ([string]::IsNullOrWhiteSpace($text)) { return $null }
  if ([Text.Encoding]::UTF8.GetByteCount($text) -gt 16384) {
    return "live_controller_result_invalid"
  }
  try { $value = $text | ConvertFrom-Json -NoEnumerate }
  catch { return "live_controller_result_invalid" }
  if ($null -eq $value -or $value.GetType() -ne [System.Management.Automation.PSCustomObject]) {
    return "live_controller_result_invalid"
  }
  $expectedKeys = Get-ExpectedControllerResultKeys
  $actualKeys = @(
    $value.PSObject.Properties |
      ForEach-Object { [string]$_.Name }
  )
  $actualKeySet = [Collections.Generic.HashSet[string]]::new(
    [StringComparer]::Ordinal)
  foreach ($actualKey in $actualKeys) {
    [void]$actualKeySet.Add($actualKey)
  }
  if (
    $actualKeys.Count -ne $expectedKeys.Count -or
    @($expectedKeys | Where-Object {
        -not $actualKeySet.Contains([string]$_)
      }).Count -ne 0
  ) {
    return "live_controller_result_invalid"
  }
  $allowedErrors = @(
    "live_controller_configuration_invalid", "live_controller_token_unavailable",
    "live_controller_endpoint_unreachable", "live_controller_endpoint_access_denied",
    "live_controller_endpoint_not_found", "live_controller_endpoint_response_invalid",
    "live_controller_endpoint_cleanup_incomplete", "visible_response_observer_unavailable",
    "visible_response_not_observed", "production_transport_unavailable",
    "production_transport_not_completed", "user_start_event_unavailable",
    "prepared_hold_expired", "live_controller_failed",
    "candidate_window_http_timeout", "production_transport_completion_timeout",
    "post_completion_total_timeout", "whole_route_timeout",
    "cleanup_incomplete")
  $allowedBlockedResults = @(Get-AllowedControllerBlockedResultClasses)
  $blockerClass = [string]$value.blocker_class
  $resultClass = [string]$value.result_class
  $controllerStatus = [string]$value.controller_status
  $statusAndBlockerValid = (
    ($controllerStatus -ceq "error" -and
      $allowedErrors -ccontains $blockerClass) -or
    ($controllerStatus -ceq "blocked" -and
      $resultClass -ceq $blockerClass -and
      $allowedBlockedResults -ccontains $blockerClass)
  )
  $scenarioClass = [string]$value.scenario
  $timeoutPhaseValid = $(switch ($blockerClass) {
      "candidate_window_http_timeout" {
        [string]$value.deadline_class -ceq "exceeded" -and
        [string]$value.endpoint_completion_class -ceq "unverified_after_transport_end" -and
        [string]$value.http_status_class -ceq "not_observed" -and
        [string]$value.first_non_silent_audio_observation_class -ceq "not_observed" -and
        [string]$value.cleanup_class -ceq
          "controller_http_resources_disposed_endpoint_completion_unverified"
      }
      "production_transport_completion_timeout" {
        [string]$value.deadline_class -ceq "exceeded" -and
        [string]$value.endpoint_completion_class -ceq "completed_response_observed" -and
        [string]$value.http_status_class -ceq "success" -and
        [string]$value.first_non_silent_audio_observation_class -ceq "not_observed" -and
        [string]$value.cleanup_class -ceq
          "controller_http_resources_disposed_endpoint_pcm_and_authority_clear"
      }
      "post_completion_total_timeout" {
        [string]$value.deadline_class -ceq "exceeded" -and
        [string]$value.endpoint_completion_class -ceq "completed_response_observed" -and
        [string]$value.http_status_class -ceq "success" -and
        [string]$value.first_non_silent_audio_observation_class -ceq
          "process_tree_render_observed" -and
        [string]$value.cleanup_class -ceq
          "controller_http_resources_disposed_endpoint_pcm_and_authority_clear"
      }
      "whole_route_timeout" {
        [string]$value.deadline_class -ceq "exceeded" -and
        [string]$value.endpoint_completion_class -ceq "not_started" -and
        [string]$value.http_status_class -ceq "not_observed" -and
        [string]$value.first_non_silent_audio_observation_class -ceq
          "not_observed" -and
        [string]$value.cleanup_class -ceq
          "controller_http_resources_disposed_no_request_started"
      }
      default { $true }
    })
  $scenarioValid = (
    $scenarioClass -ceq "independent_current_session_user_speech" -or
    $scenarioClass -ceq "self_output_or_ambiguous" -or
    ($blockerClass -ceq "live_controller_configuration_invalid" -and
      $scenarioClass -ceq "invalid"))
  if (
    [string]$value.schema_version -cne "self_output_awareness.live_controller.v0" -or
    -not $statusAndBlockerValid -or
    -not $scenarioValid -or
    -not $timeoutPhaseValid -or
    $value.raw_audio_shared -isnot [bool] -or [bool]$value.raw_audio_shared -or
    $value.raw_text_shared -isnot [bool] -or [bool]$value.raw_text_shared -or
    $value.private_identifier_shared -isnot [bool] -or [bool]$value.private_identifier_shared -or
    $value.private_environment_shared -isnot [bool] -or [bool]$value.private_environment_shared -or
    $value.raw_private_publication_flags -isnot [bool] -or
    [bool]$value.raw_private_publication_flags
  ) { return "live_controller_result_invalid" }
  return $blockerClass
}

function Resolve-ControllerNonzeroExitClass {
  param([Parameter(Mandatory = $true)][string]$OutputPath)
  $terminalClass = Get-EarlyControllerBlockerClass -OutputPath $OutputPath
  if (-not [string]::IsNullOrWhiteSpace($terminalClass)) {
    return $terminalClass
  }
  return "live_controller_failed"
}

function Wait-ControllerSignal {
  param(
    [Parameter(Mandatory = $true)][Diagnostics.Process]$Process,
    [Parameter(Mandatory = $true)][string]$OutputPath,
    [Parameter(Mandatory = $true)][string]$ErrorPath,
    [Parameter(Mandatory = $true)][string]$ExpectedSchema,
    [Parameter(Mandatory = $true)][string]$ExpectedClass,
    [Parameter(Mandatory = $true)]$RouteStopwatch,
    [Parameter(Mandatory = $true)][int]$RouteDeadlineMs,
    [string]$FailureClass = "live_controller_signal_unavailable"
  )
  return Wait-Until -RouteStopwatch $RouteStopwatch -RouteDeadlineMs $RouteDeadlineMs `
    -FailureClass $FailureClass -Condition {
    if ($Process.HasExited) {
      $earlyBlocker = Get-EarlyControllerBlockerClass -OutputPath $OutputPath
      if (-not [string]::IsNullOrWhiteSpace($earlyBlocker)) {
        Throw-Fixed -Class $earlyBlocker
      }
      Throw-Fixed -Class "live_controller_exited_before_signal"
    }
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
  param(
    [Parameter(Mandatory = $true)]$Value,
    [Parameter(Mandatory = $true)]
    [ValidateSet("genuine_user_speech", "unattended_self_output_suppression")]
    [string]$ExpectedMode
  )
  $expectedKeys = Get-ExpectedControllerResultKeys
  $commonInvalid = (
    $null -eq $Value -or
    (@($Value.PSObject.Properties.Name | Sort-Object) -join ",") -cne
      (@($expectedKeys | Sort-Object) -join ",") -or
    [string]$Value.schema_version -cne "self_output_awareness.live_controller.v0" -or
    [string]$Value.controller_status -cne "completed" -or
    -not (Test-IntegerValue $Value.transcription_count) -or
    -not (Test-IntegerValue $Value.submission_count) -or
    -not (Test-IntegerValue $Value.thought_core_turninput_count) -or
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
  )
  if ($commonInvalid) { Throw-Fixed -Class "live_controller_result_invalid" }

  $modeValid = if ($ExpectedMode -ceq "genuine_user_speech") {
    [string]$Value.scenario -ceq "independent_current_session_user_speech" -and
    [string]$Value.result_class -ceq "independent_user_speech_turninput_accepted" -and
    [long]$Value.transcription_count -eq 1 -and
    [long]$Value.submission_count -eq 1 -and
    [long]$Value.thought_core_turninput_count -eq 1
  } else {
    [string]$Value.scenario -ceq "self_output_or_ambiguous" -and
    [string]$Value.result_class -ceq "self_output_or_ambiguous_confirmed" -and
    [string]$Value.accepted_join_class -ceq "not_accepted" -and
    [long]$Value.transcription_count -eq 0 -and
    [long]$Value.submission_count -eq 0 -and
    [long]$Value.thought_core_turninput_count -eq 0 -and
    [string]$Value.first_non_silent_audio_observation_class -ceq
      "process_tree_render_observed" -and
    $null -eq $Value.utterance_end_to_first_visible_ms -and
    $null -eq $Value.utterance_end_to_first_audio_ms
  }
  if (-not $modeValid) { Throw-Fixed -Class "live_controller_result_invalid" }
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

function Invoke-UnattendedSelfOutputSequence {
  param(
    [Parameter(Mandatory = $true)][scriptblock]$StartControllerAndWaitForSystemOutputTriggerReady,
    [Parameter(Mandatory = $true)][scriptblock]$StartPostStartDeadline,
    [Parameter(Mandatory = $true)][scriptblock]$TriggerSystemOutput,
    [Parameter(Mandatory = $true)][scriptblock]$WaitForSuppressionWindowReady
  )
  [void](& $StartControllerAndWaitForSystemOutputTriggerReady)
  [void](& $StartPostStartDeadline)
  $dispatch = & $TriggerSystemOutput
  if ($dispatch -cne "system_output_dispatched_once") {
    Throw-Fixed -Class "test_ui_dispatch_not_ready"
  }
  [void](& $WaitForSuppressionWindowReady)
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
$projectionOwnerPrepareClass = $null
$cleanupClass = "cleanup_not_started"
$cleanupFailureClass = $null
$routeExitCode = 0
$resolvedRepo = $null
$ownedBase = $null
$previousCoreToken = [Environment]::GetEnvironmentVariable("AI_TALK_CORE_WEB_TOKEN", "Process")
$tokenChanged = $false
$launcherOwnershipProven = $false
$routePorts = @(3000, 8000, 8554, 8765, 8770, 8776, 8787, 8788, 8790, 8799, 8889, 18787, 9222)
try {
  $launcherRouteContract = Get-LauncherRouteContract -Mode $TestMode
  if (
    ($TestMode -ceq "genuine_user_speech" -and
      $UserStartEventName -cnotmatch "^[A-Za-z0-9][A-Za-z0-9_.-]{7,95}$") -or
    ($TestMode -ceq "unattended_self_output_suppression" -and
      -not [string]::IsNullOrWhiteSpace($UserStartEventName))
  ) {
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
  $ownedRunId = [guid]::NewGuid().ToString("N")
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
  $launcherStackStateDir = Join-Path $runRoot "launcher-stack-state"
  $launcherProcess = Start-OwnedProcessSuspended -Job $ownedJob -FilePath $pwshPath -ArgumentList @(
    "-NoLogo", "-NoProfile", "-File", $launcherScript,
    "-WorkspaceRoot", $resolvedRepo, "-HostName", "127.0.0.1", "-Port", "8799",
    "-StackStateDir", $launcherStackStateDir
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
  $launcherProfileMatches = @($launcherState.profiles | Where-Object {
      $null -ne $_ -and
      [string]$_.id -ceq [string]$launcherRouteContract.profile_id
    })
  if ($launcherProfileMatches.Count -ne 1) {
    Throw-Fixed -Class "launcher_route_profile_unavailable"
  }
  if (
    [bool]$launcherRouteContract.requires_saved_camera -and
    [string]$launcherState.config.selectedProfileId -cne [string]$launcherRouteContract.profile_id
  ) {
    Throw-Fixed -Class "launcher_primary_profile_not_selected"
  }
  $launcherOptions = $(if ([bool]$launcherRouteContract.requires_saved_camera) {
      $launcherState.config.options
    } else {
      $launcherProfileMatches[0].options
    })
  $savedCameraSelectionClass = Assert-LauncherCameraReadiness `
    -Contract $launcherRouteContract -LauncherOptions $launcherOptions `
    -CameraSelectionInvoker {
      Invoke-LoopbackJson -Uri "http://127.0.0.1:8799/api/video-input-devices" `
        -TimeoutMs (Get-RemainingBudgetMs -Stopwatch $preparationStopwatch `
          -DeadlineMs $preparationDeadlineMs -FailureClass "preparation_deadline_exceeded")
    }

  [void](Invoke-OwnedLauncherMutation -RootIdentity $launcherIdentity -MutationInvoker {
      Invoke-LoopbackJson -Uri "http://127.0.0.1:8799/api/start" -Method POST `
        -TimeoutMs (Get-RemainingBudgetMs -Stopwatch $preparationStopwatch `
          -DeadlineMs $preparationDeadlineMs -FailureClass "preparation_deadline_exceeded") -Body ([ordered]@{
        profileId = [string]$launcherRouteContract.profile_id
        options = $launcherOptions
      })
    })
  $stackStarted = $true
  $requiredServices = @($launcherRouteContract.required_services)
  [void](Wait-Until -RouteStopwatch $preparationStopwatch `
    -RouteDeadlineMs $preparationDeadlineMs `
    -FailureClass ([string]$launcherRouteContract.readiness_failure_class) -Condition {
    $status = Invoke-LoopbackJson -Uri "http://127.0.0.1:8799/api/status" `
      -TimeoutMs (Get-RemainingBudgetMs -Stopwatch $preparationStopwatch `
        -DeadlineMs $preparationDeadlineMs `
        -FailureClass ([string]$launcherRouteContract.readiness_failure_class))
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
      [void](Invoke-LoopbackJson -Uri "http://127.0.0.1:8000/health" `
        -Headers @{ "X-AI-Core-Token" = $env:AI_TALK_CORE_WEB_TOKEN } `
        -TimeoutMs $remainingMs)
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
    "--no-default-browser-check", "--new-window", "about:blank"
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
  $ownerTimeoutMs = [Math]::Min(20000, (Get-RemainingBudgetMs `
      -Stopwatch $preparationStopwatch -DeadlineMs $preparationDeadlineMs `
      -FailureClass "projection_owner_not_ready"))
  $ownerPrepare = (& node (Join-Path $resolvedRepo "scripts\drive-primary-system-cell-test-ui.mjs") `
    --prepare-owner --cdp-endpoint http://127.0.0.1:9222 --timeout-ms $ownerTimeoutMs) | ConvertFrom-Json
  $projectionOwnerPrepareClass = Resolve-ProjectionOwnerPrepareClass -Value $ownerPrepare
  if ($projectionOwnerPrepareClass -cnotin @("projection_owner_ready", "projection_owner_created")) {
    Throw-Fixed -Class "projection_owner_not_ready"
  }

  [void](Wait-Until -RouteStopwatch $preparationStopwatch `
    -RouteDeadlineMs $preparationDeadlineMs -FailureClass "ait_lifecycle_transport_not_ready" -Condition {
    try {
      $remainingMs = Get-RemainingBudgetMs -Stopwatch $preparationStopwatch `
        -DeadlineMs $preparationDeadlineMs -FailureClass "ait_lifecycle_transport_not_ready"
      $preflight = Invoke-LoopbackJson `
        -Uri "http://127.0.0.1:3000/api/self-output-awareness-transport/" `
        -TimeoutMs $remainingMs
      if (Test-AitLifecyclePreflightResponse -Value $preflight) { return "ready" }
    } catch [InvalidOperationException] { throw } catch {}
    return $null
  })

  $controllerOut = Join-Path $runRoot "controller.out.json"
  $controllerErr = Join-Path $runRoot "controller.err.log"
  if ($TestMode -ceq "genuine_user_speech") {
    $userStartEvent = New-ExclusiveUserStartEvent -Name $UserStartEventName
  }
  $controllerArguments = @(
    "-NoLogo", "-NoProfile", "-File",
    (Join-Path $resolvedRepo "scripts\run-self-output-awareness-live-controller.ps1"),
    "-BaseUrl", "http://127.0.0.1:8000", "-AitBaseUrl", "http://127.0.0.1:3000",
    "-WindowMs", "3000", "-DeadlineMs", "10000",
    "-ControlledChromeRootPid", [string]$chromeProcess.Id,
    "-AudioObserverWindowMs", "3000", "-PreparationDeadlineMs", "10000", "-Json"
  )
  if ($TestMode -ceq "genuine_user_speech") {
    $controllerArguments += @(
      "-Scenario", "independent_current_session_user_speech",
      "-CdpEndpoint", "http://127.0.0.1:9222",
      "-UserStartEventName", $UserStartEventName,
      "-UserStartHoldMs", [string]($UserStartHoldSeconds * 1000),
      "-EmitUserSpeechReadySignal"
    )
  } else {
    $controllerArguments += @(
      "-Scenario", "self_output_or_ambiguous",
      "-EmitSelfOutputSuppressionReadySignal"
    )
  }
  $startControllerAndWait = {
    $script:controllerProcess = Start-OwnedProcessSuspended -Job $ownedJob `
      -FilePath $pwshPath -ArgumentList $controllerArguments `
      -StandardOutputPath $controllerOut -StandardErrorPath $controllerErr
    $script:controllerIdentity = New-OwnedRootIdentity -Process $controllerProcess
    Wait-ControllerSignal -Process $controllerProcess -OutputPath $controllerOut `
      -ErrorPath $controllerErr `
      -ExpectedSchema "self_output_awareness.system_output_trigger_ready.v0" `
      -ExpectedClass "ready_for_system_output_trigger" `
      -RouteStopwatch $preparationStopwatch -RouteDeadlineMs $preparationDeadlineMs `
      -FailureClass "system_output_trigger_signal_unavailable"
  }
  $triggerSystemOutput = {
    $dispatchTimeoutMs = [Math]::Min(5000, (Get-RemainingBudgetMs `
        -Stopwatch $postStartStopwatch -DeadlineMs $postStartDeadlineMs `
        -FailureClass "post_start_deadline_exceeded"))
    $uiResult = (& node (Join-Path $resolvedRepo "scripts\drive-primary-system-cell-test-ui.mjs") `
      --cdp-endpoint http://127.0.0.1:9222 --timeout-ms $dispatchTimeoutMs) | ConvertFrom-Json
    if (
      [string]$uiResult.result_class -cne "test_ui_seed_dispatched" -or
      [int]$uiResult.ui_dispatch_count -ne 1
    ) { Throw-Fixed -Class "test_ui_dispatch_not_ready" }
    $script:testDispatchCount = 1
    return "system_output_dispatched_once"
  }

  if ($TestMode -ceq "genuine_user_speech") {
    Invoke-UserSessionSequence `
      -PublishSessionReady {
        Write-Class ([ordered]@{
          schema_version = "primary_system_cell_speech_test_prepare.v1"
          result_class = "ready_for_user_session_start"
          saved_camera_selection_class = $savedCameraSelectionClass
          launcher_service_count = $requiredServices.Count
          input_availability_class = "enabled"
          projection_owner_class = [string]$ownerPrepare.result_class
          user_clock_started = $false
          test_dispatch_count = 0
        })
      } `
      -WaitForUserStart {
        $holdStopwatch = [Diagnostics.Stopwatch]::StartNew()
        [void](Wait-ControllerSignal -Process $controllerProcess -OutputPath $controllerOut `
          -ErrorPath $controllerErr `
          -ExpectedSchema "self_output_awareness.user_start_received.v0" `
          -ExpectedClass "user_start_received" -RouteStopwatch $holdStopwatch `
          -RouteDeadlineMs ($UserStartHoldSeconds * 1000) -FailureClass "prepared_hold_expired")
        $script:postStartStopwatch = [Diagnostics.Stopwatch]::StartNew()
        $script:postStartDeadlineMs = 10000
        return "user_start_received"
      } `
      -StartControllerAndWaitForSystemOutputTriggerReady $startControllerAndWait `
      -TriggerSystemOutput $triggerSystemOutput `
      -WaitForUserSpeechReady {
        Wait-ControllerSignal -Process $controllerProcess -OutputPath $controllerOut `
          -ErrorPath $controllerErr `
          -ExpectedSchema "self_output_awareness.live_controller_ready.v0" `
          -ExpectedClass "ready_for_user_speech" `
          -RouteStopwatch $postStartStopwatch -RouteDeadlineMs $postStartDeadlineMs `
          -FailureClass "user_speech_signal_unavailable"
      } `
      -PublishUserCue {
        Write-Class ([ordered]@{
          schema_version = "primary_system_cell_speech_test_cue.v1"
          result_class = "issue_user_cue_now"
          user_clock_started = $true
          test_dispatch_count = 1
        })
      }
  } else {
    Invoke-UnattendedSelfOutputSequence `
      -StartControllerAndWaitForSystemOutputTriggerReady $startControllerAndWait `
      -StartPostStartDeadline {
        $script:postStartStopwatch = [Diagnostics.Stopwatch]::StartNew()
        $script:postStartDeadlineMs = 10000
      } `
      -TriggerSystemOutput $triggerSystemOutput `
      -WaitForSuppressionWindowReady {
        Wait-ControllerSignal -Process $controllerProcess -OutputPath $controllerOut `
          -ErrorPath $controllerErr `
          -ExpectedSchema "self_output_awareness.live_controller_ready.v0" `
          -ExpectedClass "ready_for_self_output_suppression_window" `
          -RouteStopwatch $postStartStopwatch -RouteDeadlineMs $postStartDeadlineMs `
          -FailureClass "self_output_suppression_signal_unavailable"
      }
  }

  if (-not $controllerProcess.WaitForExit(12000)) { Throw-Fixed -Class "live_controller_did_not_finish" }
  if ($controllerProcess.ExitCode -ne 0) {
    Throw-Fixed -Class (
      Resolve-ControllerNonzeroExitClass -OutputPath $controllerOut)
  }
  $resultText = $(if (Test-Path -LiteralPath $controllerOut -PathType Leaf) {
      (Get-Content -Raw -LiteralPath $controllerOut).Trim()
    } else { "" })
  if ([string]::IsNullOrWhiteSpace($resultText)) { Throw-Fixed -Class "live_controller_result_missing" }
  try { $controllerResult = $resultText | ConvertFrom-Json }
  catch { Throw-Fixed -Class "live_controller_result_invalid" }
  $controllerResult = Assert-ControllerSuccessResult -Value $controllerResult `
    -ExpectedMode $TestMode
  $terminalClass = [string]$controllerResult.result_class
  Write-Class ([ordered]@{
    schema_version = "primary_system_cell_speech_test_terminal.v1"
    result_class = $terminalClass
    blocker_class = [string]$controllerResult.blocker_class
    transcription_count = [int]$controllerResult.transcription_count
    submission_count = [int]$controllerResult.submission_count
    thought_core_turninput_count = [int]$controllerResult.thought_core_turninput_count
    first_non_silent_audio_observation_class =
      [string]$controllerResult.first_non_silent_audio_observation_class
    utterance_end_to_first_audio_ms = $controllerResult.utterance_end_to_first_audio_ms
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
    "launcher_route_contract_invalid", "launcher_route_profile_unavailable",
    "launcher_nine_service_boundary_not_ready", "launcher_demo_service_boundary_not_ready",
    "canonical_input_gate_not_ready",
    "ait_lifecycle_transport_not_ready",
    "controlled_chrome_unavailable", "controlled_chrome_cdp_unavailable",
    "projection_owner_not_ready", "live_controller_signal_unavailable",
    "system_output_trigger_signal_unavailable", "user_speech_signal_unavailable",
    "self_output_suppression_signal_unavailable",
    "live_controller_exited_before_signal", "live_controller_signal_duplicated",
    "user_start_not_received", "prepared_hold_expired", "test_ui_dispatch_not_ready",
    "live_controller_did_not_finish", "live_controller_failed",
    "live_controller_result_missing", "live_controller_result_invalid",
    "preparation_deadline_exceeded", "post_start_deadline_exceeded",
    "live_controller_configuration_invalid", "live_controller_token_unavailable",
    "live_controller_endpoint_unreachable", "live_controller_endpoint_access_denied",
    "live_controller_endpoint_not_found", "live_controller_endpoint_response_invalid",
    "live_controller_endpoint_cleanup_incomplete", "visible_response_observer_unavailable",
    "visible_response_not_observed", "production_transport_unavailable",
    "production_transport_not_completed", "user_start_event_unavailable",
    "candidate_window_http_timeout", "production_transport_completion_timeout",
    "post_completion_total_timeout", "whole_route_timeout"
  ) + @(Get-AllowedControllerBlockedResultClasses)
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
    projection_owner_prepare_class = Resolve-ProjectionOwnerErrorDetailClass `
      -BlockerClass $blockerClass -PrepareClass $projectionOwnerPrepareClass
    test_dispatch_count = $testDispatchCount
  })
} finally {
  if ($stackStarted -and $launcherOwnershipProven) {
    try {
      $stopResult = Invoke-OwnedLauncherMutation -RootIdentity $launcherIdentity -MutationInvoker {
        Invoke-LoopbackJson -Uri "http://127.0.0.1:8799/api/stop" -Method POST -Body @{} `
          -TimeoutMs ($CleanupStopTimeoutSeconds * 1000)
      }
      if ($stopResult.ok -isnot [bool] -or -not [bool]$stopResult.ok) {
        Throw-Fixed -Class "cleanup_incomplete"
      }
    } catch {
      $cleanupFailureClass = "launcher_standard_stop_failed"
    }
  }
  if ($launcherStarted -and $launcherOwnershipProven) {
    try {
      $shutdownResult = Invoke-OwnedLauncherMutation -RootIdentity $launcherIdentity -MutationInvoker {
        Invoke-LoopbackJson -Uri "http://127.0.0.1:8799/api/shutdown" -Method POST -Body @{} `
          -TimeoutMs 5000
      }
      if ($shutdownResult.ok -isnot [bool] -or -not [bool]$shutdownResult.ok) {
        Throw-Fixed -Class "cleanup_incomplete"
      }
    } catch {
      if ($null -eq $cleanupFailureClass) {
        $cleanupFailureClass = "launcher_shutdown_failed"
      }
    }
  }
  if ($null -ne $userStartEvent) { $userStartEvent.Dispose() }
  $finalCleanup = Complete-OwnedRouteCleanup `
    -OwnedJob $ownedJob -Ports $routePorts -RunRoot $runRoot `
    -OwnedBase $ownedBase -RunId $ownedRunId `
    -LauncherCleanupFailureClass $cleanupFailureClass
  if ([bool]$finalCleanup.job_disposed) { $ownedJob = $null }
  $cleanupClass = [string]$finalCleanup.cleanup_class
  $cleanupFailureClass = $finalCleanup.cleanup_failure_class
  if ($cleanupClass -ceq "cleanup_incomplete") {
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
    cleanup_failure_class = $cleanupFailureClass
    terminal_class = $terminalClass
    blocker_class = $blockerClass
  })
}
exit $routeExitCode
