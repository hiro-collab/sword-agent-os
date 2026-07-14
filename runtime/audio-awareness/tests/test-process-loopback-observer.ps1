[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$sourcePath = [System.IO.Path]::GetFullPath(
  (Join-Path $PSScriptRoot "..\windows\ProcessLoopbackObserver.cs"))
$wrapperPath = [System.IO.Path]::GetFullPath(
  (Join-Path $PSScriptRoot "..\windows\invoke-process-loopback-observer.ps1"))
$script:AssertionCount = 0

function Assert-Equal {
  param($Actual, $Expected, [Parameter(Mandatory)][string]$Message)
  $script:AssertionCount += 1
  if ($Actual -ne $Expected) { throw "assertion_failed:$Message" }
}

function Assert-True {
  param($Actual, [Parameter(Mandatory)][string]$Message)
  Assert-Equal ([bool]$Actual) $true $Message
}

function Assert-False {
  param($Actual, [Parameter(Mandatory)][string]$Message)
  Assert-Equal ([bool]$Actual) $false $Message
}

function Assert-Match {
  param([string]$Actual, [string]$Pattern, [Parameter(Mandatory)][string]$Message)
  $script:AssertionCount += 1
  if ($Actual -notmatch $Pattern) { throw "assertion_failed:$Message" }
}

function Assert-NotMatch {
  param([string]$Actual, [string]$Pattern, [Parameter(Mandatory)][string]$Message)
  $script:AssertionCount += 1
  if ($Actual -match $Pattern) { throw "assertion_failed:$Message" }
}

function Assert-PropertyNames {
  param($Actual, [string[]]$Expected, [Parameter(Mandatory)][string]$Message)
  $actualNames = @($Actual.PSObject.Properties.Name | Sort-Object)
  $expectedNames = @($Expected | Sort-Object)
  Assert-Equal ($actualNames -join '|') ($expectedNames -join '|') $Message
}

function Invoke-Wrapper {
  param([hashtable]$Parameters = @{})
  $json = (& $wrapperPath @Parameters | Out-String).Trim()
  if (-not $json) { throw "wrapper_returned_empty_output" }
  return [pscustomobject]@{
    Json = $json
    Value = $json | ConvertFrom-Json -Depth 10
  }
}

function Get-FixedFailureClass {
  param([Parameter(Mandatory)][scriptblock]$Action)
  try {
    & $Action
    return "no_failure"
  } catch {
    $exception = $_.Exception
    while ($null -ne $exception) {
      if ($exception.GetType().FullName -eq
        "SwordAgentOS.AudioAwareness.ProcessLoopbackObserverException") {
        return [string]$exception.FailureClass
      }
      $exception = $exception.InnerException
    }
    return "unexpected_failure_type"
  }
}

$tokens = $null
$parseErrors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile(
  $wrapperPath,
  [ref]$tokens,
  [ref]$parseErrors)
Assert-Equal @($parseErrors).Count 0 "wrapper parser errors"

. $wrapperPath

Assert-Equal (ConvertTo-CaptureStartedAtUtcMs `
    -CaptureStartedAtUtcTicks 621355969230000000) 123000 `
  "fixed UTC ticks convert to Unix milliseconds"
Assert-Equal (ConvertTo-CaptureStartedAtUtcMs `
    -CaptureStartedAtUtcTicks 0) $null `
  "missing capture start remains absent"

$sourceText = Get-Content -LiteralPath $sourcePath -Raw
$fakeTypeDefinition = @'
namespace SwordAgentOS.AudioAwareness.Tests
{
    public sealed class FakeProcessLoopbackBackend :
        SwordAgentOS.AudioAwareness.IProcessLoopbackBackend
    {
        private readonly System.Collections.Generic.Queue<
            SwordAgentOS.AudioAwareness.ProcessLoopbackPacket> _packets;
        private readonly bool _throwOnStop;
        public System.Action ActivateAction;

        public FakeProcessLoopbackBackend(bool renderObserved, bool throwOnStop)
        {
            _throwOnStop = throwOnStop;
            _packets = new System.Collections.Generic.Queue<
                SwordAgentOS.AudioAwareness.ProcessLoopbackPacket>();
            _packets.Enqueue(new SwordAgentOS.AudioAwareness.ProcessLoopbackPacket
            {
                FrameCount = 128,
                IsSilent = true,
                QpcPosition100Ns = 1050000UL
            });
            _packets.Enqueue(new SwordAgentOS.AudioAwareness.ProcessLoopbackPacket
            {
                FrameCount = 64,
                IsSilent = !renderObserved,
                QpcPosition100Ns = 1250000UL
            });
        }

        public int CaptureStartCount { get; private set; }
        public int ActivateCount { get; private set; }
        public int CaptureStopAttemptCount { get; private set; }
        public int CaptureStopCount { get; private set; }
        public int BufferReleaseCount { get; private set; }
        public int ResourceReleaseCount { get; private set; }
        public int DisposeCount { get; private set; }

        public System.Threading.Tasks.Task ActivateAsync(
            int targetProcessId,
            System.Threading.CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            ActivateCount += 1;
            if (ActivateAction != null) ActivateAction();
            return System.Threading.Tasks.Task.CompletedTask;
        }

        public void Start()
        {
            CaptureStartCount += 1;
        }

        public SwordAgentOS.AudioAwareness.ProcessLoopbackPacket ReadPacket()
        {
            if (_packets.Count == 0) return null;
            BufferReleaseCount += 1;
            return _packets.Dequeue();
        }

        public void Stop()
        {
            CaptureStopAttemptCount += 1;
            if (_throwOnStop)
            {
                throw new System.InvalidOperationException("fixed-test-stop");
            }
            CaptureStopCount += 1;
        }

        public void Dispose()
        {
            DisposeCount += 1;
            ResourceReleaseCount += 1;
        }
    }

    internal sealed class FakeProcessIdentityProvider :
        SwordAgentOS.AudioAwareness.IProcessIdentityProvider
    {
        internal bool Exists = true;
        internal long CreationUtcTicks = 100;

        public bool TryGetCreationUtcTicks(
            int processId,
            out long creationUtcTicks)
        {
            creationUtcTicks = CreationUtcTicks;
            return Exists;
        }
    }

    public static class ObserverHarness
    {
        public static System.Threading.Tasks.Task<
            SwordAgentOS.AudioAwareness.ProcessLoopbackObservation> Observe(
                FakeProcessLoopbackBackend backend,
                int windowMs,
                int deadlineMs,
                System.Threading.CancellationToken cancellationToken)
        {
            var provider = new FakeProcessIdentityProvider();
            var lease = SwordAgentOS.AudioAwareness.ProcessLoopbackObserver
                .AcquireProcessLease(provider, 1, 1000, 0);
            int utcCallCount = 0;
            long captureStartedAtUtcTicks = 621355969230000000L;
            return SwordAgentOS.AudioAwareness.ProcessLoopbackObserver
                .ObserveWithBackendAsync(
                    backend,
                    lease,
                    provider,
                    () => ++utcCallCount == 3
                        ? captureStartedAtUtcTicks
                        : 0,
                    windowMs,
                    deadlineMs,
                    cancellationToken,
                    () => 1000000UL);
        }

        public static System.Threading.Tasks.Task<
            SwordAgentOS.AudioAwareness.ProcessLoopbackObservation> ObserveMissingLease(
                FakeProcessLoopbackBackend backend)
        {
            return SwordAgentOS.AudioAwareness.ProcessLoopbackObserver
                .ObserveWithBackendAsync(
                    backend,
                    null,
                    new FakeProcessIdentityProvider(),
                    () => 0,
                    100,
                    1000,
                    System.Threading.CancellationToken.None,
                    () => 1000000UL);
        }

        public static System.Threading.Tasks.Task<
            SwordAgentOS.AudioAwareness.ProcessLoopbackObservation> ObserveLeaseFailure(
                FakeProcessLoopbackBackend backend,
                string failureMode)
        {
            var provider = new FakeProcessIdentityProvider();
            var lease = SwordAgentOS.AudioAwareness.ProcessLoopbackObserver
                .AcquireProcessLease(provider, 1, 1000, 0);
            long nowTicks = 0;
            if (failureMode == "mismatch") provider.CreationUtcTicks = 200;
            if (failureMode == "exited") provider.Exists = false;
            if (failureMode == "expired") nowTicks = 1001 * 10000L;
            return SwordAgentOS.AudioAwareness.ProcessLoopbackObserver
                .ObserveWithBackendAsync(
                    backend,
                    lease,
                    provider,
                    () => nowTicks,
                    100,
                    1000,
                    System.Threading.CancellationToken.None,
                    () => 1000000UL);
        }

        public static System.Threading.Tasks.Task<
            SwordAgentOS.AudioAwareness.ProcessLoopbackObservation> ObserveActivationLeaseFailure(
                FakeProcessLoopbackBackend backend,
                string failureMode)
        {
            var provider = new FakeProcessIdentityProvider();
            var lease = SwordAgentOS.AudioAwareness.ProcessLoopbackObserver
                .AcquireProcessLease(provider, 1, 1000, 0);
            backend.ActivateAction = () =>
            {
                if (failureMode == "mismatch") provider.CreationUtcTicks = 200;
                if (failureMode == "exited") provider.Exists = false;
            };
            return SwordAgentOS.AudioAwareness.ProcessLoopbackObserver
                .ObserveWithBackendAsync(
                    backend,
                    lease,
                    provider,
                    () => 0,
                    100,
                    1000,
                    System.Threading.CancellationToken.None,
                    () => 1000000UL);
        }
    }

    public static class ActivationHandlerHarness
    {
        public static int LateSuccessReleaseCount()
        {
            int releases = 0;
            var handler = new SwordAgentOS.AudioAwareness.ActivationHandler(
                value => releases += 1);
            handler.Abandon();
            handler.CompleteForTest(new object(), true);
            return releases;
        }

        public static int FailedResultReleaseCount()
        {
            int releases = 0;
            var handler = new SwordAgentOS.AudioAwareness.ActivationHandler(
                value => releases += 1);
            handler.CompleteForTest(new object(), false);
            return releases;
        }

        public static int CompletedThenAbandonReleaseCount()
        {
            int releases = 0;
            var handler = new SwordAgentOS.AudioAwareness.ActivationHandler(
                value => releases += 1);
            handler.CompleteForTest(new object(), true);
            handler.Abandon();
            return releases;
        }
    }

    internal sealed class FakeCaptureBufferSource :
        SwordAgentOS.AudioAwareness.ICaptureBufferSource
    {
        internal int GetBufferCount;
        internal int ReleaseBufferCount;
        internal uint Flags;
        private bool _hasPacket = true;

        public int GetNextPacketSize(out uint nextPacketFrames)
        {
            nextPacketFrames = _hasPacket ? 128U : 0U;
            return 0;
        }

        public int GetBuffer(
            out System.IntPtr data,
            out uint frameCount,
            out uint flags,
            out ulong devicePosition,
            out ulong qpcPosition)
        {
            GetBufferCount += 1;
            data = System.IntPtr.Zero;
            frameCount = 128;
            flags = Flags;
            devicePosition = 0;
            qpcPosition = 1234UL;
            _hasPacket = false;
            return 0;
        }

        public int ReleaseBuffer(uint frameCount)
        {
            ReleaseBufferCount += 1;
            return 0;
        }
    }

    public static class NativeShapeHarness
    {
        public static int[] ActivationShape()
        {
            System.IntPtr blob;
            var variant = SwordAgentOS.AudioAwareness.WasapiProcessLoopbackBackend
                .BuildActivationVariant(7, out blob);
            try
            {
                var activation = System.Runtime.InteropServices.Marshal
                    .PtrToStructure<SwordAgentOS.AudioAwareness.AudioClientActivationParams>(
                        variant.Blob.Data);
                return new int[]
                {
                    SwordAgentOS.AudioAwareness.ProcessLoopbackObserver
                        .MinimumProcessLoopbackBuild,
                    SwordAgentOS.AudioAwareness.WasapiProcessLoopbackBackend
                        .ActivationTypeProcessLoopback,
                    SwordAgentOS.AudioAwareness.WasapiProcessLoopbackBackend
                        .IncludeTargetProcessTree,
                    SwordAgentOS.AudioAwareness.WasapiProcessLoopbackBackend.VtBlob,
                    variant.VariantType,
                    variant.Blob.Size,
                    activation.ActivationType,
                    activation.ProcessLoopbackParams.ProcessLoopbackMode,
                    (int)activation.ProcessLoopbackParams.TargetProcessId
                };
            }
            finally
            {
                System.Runtime.InteropServices.Marshal.FreeHGlobal(blob);
            }
        }

        public static string VirtualDeviceClass()
        {
            return SwordAgentOS.AudioAwareness.WasapiProcessLoopbackBackend
                .VirtualAudioDeviceProcessLoopback;
        }

        public static int[] BufferReleaseShape()
        {
            var source = new FakeCaptureBufferSource();
            int observedReleases = 0;
            var packet = SwordAgentOS.AudioAwareness.WasapiProcessLoopbackBackend
                .ReadPacketFromSource(source, () => observedReleases += 1);
            return new int[]
            {
                source.GetBufferCount,
                source.ReleaseBufferCount,
                observedReleases,
                (int)packet.FrameCount,
                (int)packet.QpcPosition100Ns
            };
        }

        public static object[] TimestampErrorReleaseShape()
        {
            var source = new FakeCaptureBufferSource();
            source.Flags = 0x4U;
            int observedReleases = 0;
            string failureClass = "no_failure";
            try
            {
                SwordAgentOS.AudioAwareness.WasapiProcessLoopbackBackend
                    .ReadPacketFromSource(source, () => observedReleases += 1);
            }
            catch (SwordAgentOS.AudioAwareness.ProcessLoopbackObserverException exception)
            {
                failureClass = exception.FailureClass;
            }
            return new object[]
            {
                failureClass,
                source.GetBufferCount,
                source.ReleaseBufferCount,
                observedReleases
            };
        }
    }
}
'@
if (-not ("SwordAgentOS.AudioAwareness.ProcessLoopbackObserver" -as [type])) {
  Add-Type -TypeDefinition ($sourceText + "`n" + $fakeTypeDefinition)
}

$capability = Invoke-Wrapper -Parameters @{ Mode = " CAPABILITY_ONLY "; Compact = $true }
Assert-Equal $capability.Value.schema_version "process_loopback_observation.v0" "schema version"
Assert-Match $capability.Value.result_class '^process_loopback_capability_(available|unavailable)$' "bounded capability class"
Assert-Equal $capability.Value.source_class "capability_probe" "capability source class"
Assert-Equal $capability.Value.proof_ceiling "class_only_process_loopback_capability" "capability proof ceiling"
Assert-Equal $capability.Value.attribution_class "not_attempted" "capability does not claim attribution"
Assert-Equal $capability.Value.lifecycle.cleanup_class "no_runtime_started" "capability starts no runtime"

$renderFixture = Invoke-Wrapper -Parameters @{ Mode = "synthetic_render"; Compact = $true }
Assert-Equal $renderFixture.Value.result_class "synthetic_process_tree_render_fixture" "render fixture result"
Assert-Equal $renderFixture.Value.source_class "synthetic_fixture" "render fixture source"
Assert-Equal $renderFixture.Value.observation.non_silent_frame_count 256 "render fixture non-silent frames"
Assert-Equal $renderFixture.Value.observation.silent_frame_count 0 "render fixture silent frames"
Assert-Equal $renderFixture.Value.observation.first_non_silent_frame_offset_ms 0 "render fixture first-frame offset"
Assert-False $renderFixture.Value.observation.live_capture_used "render fixture is not live"
Assert-PropertyNames $renderFixture.Value.observation @(
  "window_ms", "packet_count", "frame_count", "non_silent_frame_count",
  "silent_frame_count", "first_non_silent_frame_offset_ms", "live_capture_used"
) "default observation schema remains backward compatible"

$timedRenderFixture = Invoke-Wrapper -Parameters @{
  Mode = "synthetic_render"
  IncludeCaptureStartTimestamp = $true
  Compact = $true
}
Assert-PropertyNames $timedRenderFixture.Value.observation @(
  "window_ms", "packet_count", "frame_count", "non_silent_frame_count",
  "silent_frame_count", "first_non_silent_frame_offset_ms", "live_capture_used",
  "capture_started_at_utc_ms"
) "timed observation schema adds only capture start"
Assert-Equal $timedRenderFixture.Value.observation.capture_started_at_utc_ms $null "synthetic fixture has no live capture start"

$silenceFixture = Invoke-Wrapper -Parameters @{ Mode = "synthetic_silence"; Compact = $true }
Assert-Equal $silenceFixture.Value.result_class "synthetic_process_tree_silence_fixture" "silence fixture result"
Assert-Equal $silenceFixture.Value.observation.non_silent_frame_count 0 "silence fixture non-silent frames"
Assert-Equal $silenceFixture.Value.observation.silent_frame_count 256 "silence fixture silent frames"
Assert-Equal $silenceFixture.Value.observation.first_non_silent_frame_offset_ms $null "silence fixture has no first-frame offset"

$privateMarker = "private-marker-should-never-echo"
$invalidMode = Invoke-Wrapper -Parameters @{ Mode = $privateMarker; Compact = $true }
Assert-Equal $invalidMode.Value.result_class "invalid_mode" "invalid mode fails closed"
Assert-NotMatch $invalidMode.Json ([regex]::Escape($privateMarker)) "invalid mode does not echo"

$missingLease = Invoke-Wrapper -Parameters @{ Mode = "live_process_tree"; Compact = $true }
Assert-Equal $missingLease.Value.result_class "target_process_lease_missing" "live mode requires process lease"
Assert-Equal $missingLease.Value.lifecycle.cleanup_class "no_runtime_started" "missing lease starts no runtime"
Assert-False $missingLease.Value.observation.live_capture_used "missing lease is not live"

$invalidLiveBounds = Invoke-Wrapper -Parameters @{
  Mode = "live_process_tree"
  TargetProcessId = $PID
  WindowMs = 99
  DeadlineMs = 1000
  Compact = $true
}
Assert-Equal $invalidLiveBounds.Value.result_class "observation_bounds_invalid" "invalid live bounds fail before activation"
Assert-Equal $invalidLiveBounds.Value.lifecycle.cleanup_class "cleanup_not_proven" "failed live result does not upgrade cleanup"
Assert-Equal $invalidLiveBounds.Value.lifecycle.owned_process_residue_count $null "unproven process residue stays null"
Assert-Equal $invalidLiveBounds.Value.lifecycle.temporary_residue_count $null "unproven temporary residue stays null"
Assert-False $invalidLiveBounds.Value.observation.live_capture_used "invalid bounds do not capture"

foreach ($output in @(
    $capability.Value,
    $renderFixture.Value,
    $silenceFixture.Value,
    $invalidMode.Value,
    $missingLease.Value
  )) {
  Assert-False $output.privacy.raw_pcm_published "raw PCM is never published"
  Assert-False $output.privacy.raw_audio_persisted "raw audio is never persisted"
  Assert-False $output.privacy.transcript_observed "transcript is never observed"
  Assert-False $output.privacy.target_process_identity_published "target identity is never published"
  Assert-False $output.privacy.device_or_endpoint_identity_published "device identity is never published"
  Assert-False $output.privacy.private_path_published "private path is never published"
  Assert-False $output.authority.microphone_capture_authority "no microphone authority"
  Assert-False $output.authority.turn_input_authority "no TurnInput authority"
  Assert-False $output.authority.aec_selection_authority "no AEC selection authority"
  Assert-False $output.authority.readiness_authority "no readiness authority"
  Assert-Equal $output.lifecycle.owned_process_residue_count 0 "no owned process residue"
  Assert-Equal $output.lifecycle.temporary_residue_count 0 "no temporary residue"
}

$fake = [SwordAgentOS.AudioAwareness.Tests.FakeProcessLoopbackBackend]::new($true, $false)
$fakeResult = [SwordAgentOS.AudioAwareness.Tests.ObserverHarness]::Observe(
  $fake,
  100,
  1000,
  [System.Threading.CancellationToken]::None).GetAwaiter().GetResult()
Assert-Equal $fakeResult.ResultClass "process_tree_render_observed" "fake render observed"
Assert-Equal $fakeResult.PacketCount 2 "all fake packets drained"
Assert-Equal $fakeResult.FrameCount 192 "fake frames counted"
Assert-Equal $fakeResult.NonSilentFrameCount 64 "fake non-silent frames counted"
Assert-Equal $fakeResult.SilentFrameCount 128 "fake silent frames counted"
Assert-Equal $fakeResult.FirstNonSilentFrameOffsetMs 25 "fake first non-silent frame uses packet QPC offset"
Assert-Equal $fakeResult.CaptureStartedAtUtcTicks 621355969230000000 "fake capture start is recorded after lease validation and before start"
Assert-Equal $fakeResult.CaptureStartCount 1 "fake capture starts once"
Assert-Equal $fakeResult.CaptureStopAttemptCount 1 "fake capture stop attempted once"
Assert-Equal $fakeResult.CaptureStopCount 1 "fake capture stops once"
Assert-Equal $fakeResult.BufferReleaseCount 2 "each fake packet released once"
Assert-Equal $fakeResult.ResourceReleaseCount 1 "fake backend resources released once"
Assert-Equal $fake.ActivateCount 1 "normal observation activates once"
Assert-Equal $fake.DisposeCount 1 "fake backend disposed once"

$silentFake = [SwordAgentOS.AudioAwareness.Tests.FakeProcessLoopbackBackend]::new($false, $false)
$silentFakeResult = [SwordAgentOS.AudioAwareness.Tests.ObserverHarness]::Observe(
  $silentFake,
  100,
  1000,
  [System.Threading.CancellationToken]::None).GetAwaiter().GetResult()
Assert-Equal $silentFakeResult.ResultClass "process_tree_silence_observed" "silent capture remains a distinct result"
Assert-Equal $silentFakeResult.FirstNonSilentFrameOffsetMs $null "silent capture has no first non-silent offset"
Assert-Equal $silentFakeResult.CaptureStartedAtUtcTicks 621355969230000000 "silent capture still records its capture start"

$missingTargetFake = [SwordAgentOS.AudioAwareness.Tests.FakeProcessLoopbackBackend]::new($false, $false)
$missingTargetClass = Get-FixedFailureClass {
  [SwordAgentOS.AudioAwareness.Tests.ObserverHarness]::ObserveMissingLease(
    $missingTargetFake).GetAwaiter().GetResult()
}
Assert-Equal $missingTargetClass "target_process_lease_missing" "missing target fixed failure"
Assert-Equal $missingTargetFake.DisposeCount 1 "missing target backend disposed"
Assert-Equal $missingTargetFake.CaptureStartCount 0 "missing target never starts"
Assert-Equal $missingTargetFake.ActivateCount 0 "missing target fails before activation"

$invalidBoundsFake = [SwordAgentOS.AudioAwareness.Tests.FakeProcessLoopbackBackend]::new($false, $false)
$invalidBoundsClass = Get-FixedFailureClass {
  [SwordAgentOS.AudioAwareness.Tests.ObserverHarness]::Observe(
    $invalidBoundsFake,
    99,
    1000,
    [System.Threading.CancellationToken]::None).GetAwaiter().GetResult()
}
Assert-Equal $invalidBoundsClass "observation_bounds_invalid" "invalid bounds fixed failure"
Assert-Equal $invalidBoundsFake.DisposeCount 1 "invalid bounds backend disposed"
Assert-Equal $invalidBoundsFake.ActivateCount 0 "invalid bounds fail before activation"

$cleanupFailureFake = [SwordAgentOS.AudioAwareness.Tests.FakeProcessLoopbackBackend]::new($true, $true)
$cleanupFailureClass = Get-FixedFailureClass {
  [SwordAgentOS.AudioAwareness.Tests.ObserverHarness]::Observe(
    $cleanupFailureFake,
    100,
    1000,
    [System.Threading.CancellationToken]::None).GetAwaiter().GetResult()
}
Assert-Equal $cleanupFailureClass "process_loopback_cleanup_failed" "cleanup failure is fixed class"
Assert-Equal $cleanupFailureFake.CaptureStartCount 1 "cleanup failure starts once"
Assert-Equal $cleanupFailureFake.CaptureStopAttemptCount 1 "cleanup failure stop attempted once"
Assert-Equal $cleanupFailureFake.CaptureStopCount 0 "failed stop is not counted as success"
Assert-Equal $cleanupFailureFake.DisposeCount 1 "cleanup failure still disposes once"
Assert-Equal $cleanupFailureFake.ResourceReleaseCount 1 "cleanup failure releases resources once"
Assert-Equal $cleanupFailureFake.ActivateCount 1 "cleanup failure has one activation"

$cancelFake = [SwordAgentOS.AudioAwareness.Tests.FakeProcessLoopbackBackend]::new($false, $false)
$cancelSource = [System.Threading.CancellationTokenSource]::new()
$cancelSource.CancelAfter(25)
$cancelClass = Get-FixedFailureClass {
  [SwordAgentOS.AudioAwareness.Tests.ObserverHarness]::Observe(
    $cancelFake,
    500,
    1000,
    $cancelSource.Token).GetAwaiter().GetResult()
}
$cancelSource.Dispose()
Assert-Equal $cancelClass "observation_deadline_exceeded" "cancellation returns fixed bounded class"
Assert-Equal $cancelFake.CaptureStartCount 1 "cancelled capture starts once"
Assert-Equal $cancelFake.CaptureStopAttemptCount 1 "cancelled capture stop attempted once"
Assert-Equal $cancelFake.CaptureStopCount 1 "cancelled capture stops once"
Assert-Equal $cancelFake.DisposeCount 1 "cancelled capture disposes once"
Assert-Equal $cancelFake.ActivateCount 1 "cancelled observation has one activation"

$leaseFailures = [ordered]@{
  mismatch = "target_process_lease_identity_mismatch"
  expired = "target_process_lease_expired"
  exited = "target_process_lease_exited"
}
foreach ($entry in $leaseFailures.GetEnumerator()) {
  $leaseFake = [SwordAgentOS.AudioAwareness.Tests.FakeProcessLoopbackBackend]::new($false, $false)
  $leaseClass = Get-FixedFailureClass {
    [SwordAgentOS.AudioAwareness.Tests.ObserverHarness]::ObserveLeaseFailure(
      $leaseFake,
      $entry.Key).GetAwaiter().GetResult()
  }
  Assert-Equal $leaseClass $entry.Value "lease failure $($entry.Key) fixed class"
  Assert-Equal $leaseFake.CaptureStartCount 0 "lease failure $($entry.Key) starts no capture"
  Assert-Equal $leaseFake.ActivateCount 0 "lease failure $($entry.Key) fails before activation"
  Assert-Equal $leaseFake.DisposeCount 1 "lease failure $($entry.Key) disposes backend"
}

foreach ($entry in ([ordered]@{
      mismatch = "target_process_lease_post_activation_identity_mismatch"
      exited = "target_process_lease_post_activation_exited"
    }).GetEnumerator()) {
  $activationLeaseFake = [SwordAgentOS.AudioAwareness.Tests.FakeProcessLoopbackBackend]::new($false, $false)
  $activationLeaseClass = Get-FixedFailureClass {
    [SwordAgentOS.AudioAwareness.Tests.ObserverHarness]::ObserveActivationLeaseFailure(
      $activationLeaseFake,
      $entry.Key).GetAwaiter().GetResult()
  }
  Assert-Equal $activationLeaseClass $entry.Value "post-activation lease failure $($entry.Key) fixed class"
  Assert-Equal $activationLeaseFake.ActivateCount 1 "post-activation lease failure activates once"
  Assert-Equal $activationLeaseFake.CaptureStartCount 0 "post-activation lease failure starts no capture"
  Assert-Equal $activationLeaseFake.DisposeCount 1 "post-activation lease failure disposes once"
}

Assert-Equal ([SwordAgentOS.AudioAwareness.Tests.ActivationHandlerHarness]::LateSuccessReleaseCount()) 1 "late activation success releases abandoned interface once"
Assert-Equal ([SwordAgentOS.AudioAwareness.Tests.ActivationHandlerHarness]::FailedResultReleaseCount()) 1 "failed activation releases returned interface once"
Assert-Equal ([SwordAgentOS.AudioAwareness.Tests.ActivationHandlerHarness]::CompletedThenAbandonReleaseCount()) 1 "completed activation releases once when abandonment wins before claim"

$activationShape = [SwordAgentOS.AudioAwareness.Tests.NativeShapeHarness]::ActivationShape()
Assert-Equal $activationShape[0] 20348 "minimum process-loopback build"
Assert-Equal $activationShape[1] 1 "process-loopback activation type"
Assert-Equal $activationShape[2] 0 "include target process tree mode"
Assert-Equal $activationShape[3] 65 "VT_BLOB constant"
Assert-Equal $activationShape[4] 65 "activation variant uses VT_BLOB"
Assert-Equal $activationShape[5] 12 "activation blob size"
Assert-Equal $activationShape[6] 1 "blob carries process-loopback activation type"
Assert-Equal $activationShape[7] 0 "blob carries include-tree mode"
Assert-Equal $activationShape[8] 7 "blob carries bounded target only internally"
Assert-Equal ([SwordAgentOS.AudioAwareness.Tests.NativeShapeHarness]::VirtualDeviceClass()) 'VAD\Process_Loopback' "virtual process-loopback device class"

$bufferReleaseShape = [SwordAgentOS.AudioAwareness.Tests.NativeShapeHarness]::BufferReleaseShape()
Assert-Equal $bufferReleaseShape[0] 1 "successful GetBuffer called once"
Assert-Equal $bufferReleaseShape[1] 1 "successful GetBuffer releases once"
Assert-Equal $bufferReleaseShape[2] 1 "release observer records once"
Assert-Equal $bufferReleaseShape[3] 128 "released packet frame count preserved"
Assert-Equal $bufferReleaseShape[4] 1234 "captured packet QPC position preserved"

$timestampErrorShape = [SwordAgentOS.AudioAwareness.Tests.NativeShapeHarness]::TimestampErrorReleaseShape()
Assert-Equal $timestampErrorShape[0] "process_loopback_packet_timestamp_invalid" "uncertain timestamp fails closed"
Assert-Equal $timestampErrorShape[1] 1 "uncertain timestamp gets one buffer"
Assert-Equal $timestampErrorShape[2] 1 "uncertain timestamp releases buffer once"
Assert-Equal $timestampErrorShape[3] 1 "uncertain timestamp release observer runs once"

$preActivationPhase = Resolve-FailurePhase -FailureClass "target_process_lease_identity_mismatch"
Assert-Equal $preActivationPhase.attribution_class "not_attempted" "pre-activation lease failure is not attributed"
Assert-Equal $preActivationPhase.cleanup_class "no_runtime_started" "pre-activation lease failure starts no runtime"
$postActivationPhase = Resolve-FailurePhase -FailureClass "target_process_lease_post_activation_identity_mismatch"
Assert-Equal $postActivationPhase.attribution_class "target_process_tree_activation_completed_not_started" "post-activation lease failure phase is explicit"
Assert-Equal $postActivationPhase.cleanup_class "route_owned_cleanup_clear" "post-activation lease cleanup is explicit"

Assert-Match $sourceText 'VAD\\Process_Loopback' "virtual process loopback surface present"
Assert-Match $sourceText 'IncludeTargetProcessTree' "target process tree inclusion present"
Assert-Match $sourceText 'ActivateAudioInterfaceAsync' "official activation API present"
Assert-Match $sourceText 'ReleaseBuffer' "buffer release present"
Assert-Match $sourceText 'finally' "bounded cleanup present"
Assert-Match $sourceText 'BuildActivationVariant[\s\S]+ActivateAudioInterfaceAsync[\s\S]+ref variant' "built activation blob is passed to activation API"
Assert-Match (Get-Content -LiteralPath $wrapperPath -Raw) 'ConvertTo-CaptureStartedAtUtcMs[\s\S]+-CaptureStartedAtUtcTicks \$result\.CaptureStartedAtUtcTicks' "live wrapper converts the observer capture start"
Assert-NotMatch $sourceText 'System\.IO\.File|FileStream|WriteAll|\.wav|Process\.Start\s*\(|\[System\.Diagnostics\.Process\]::Start|GetDefaultAudioEndpoint|IMMDeviceEnumerator' "no file output, process start, or endpoint enumeration"

foreach ($json in @(
    $capability.Json,
    $renderFixture.Json,
    $silenceFixture.Json,
    $invalidMode.Json,
    $missingLease.Json,
    $invalidLiveBounds.Json
  )) {
  Assert-NotMatch $json '([A-Za-z]:\\|file:|https?://)' "shared output has no path or URL"
  Assert-NotMatch $json '"(device_name|device_id|endpoint_id|pid|process_id|command_line|payload|transcript)"' "shared output has no private identity or payload fields"
}

[pscustomobject]@{
  status = "ok"
  assertions = $script:AssertionCount
  parser_errors = 0
  live_audio_invocation_count = 0
  dependency_install_count = 0
  process_start_count = 0
  proof_ceiling = "source_static_process_loopback_observer"
} | ConvertTo-Json -Compress
