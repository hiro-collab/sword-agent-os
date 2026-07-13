[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$script:Assertions = 0

function Assert-True {
  param([bool]$Value, [string]$Message)
  $script:Assertions += 1
  if (-not $Value) { throw "assertion failed: $Message" }
}

function Assert-False {
  param([bool]$Value, [string]$Message)
  Assert-True (-not $Value) $Message
}

function Assert-Equal {
  param($Actual, $Expected, [string]$Message)
  $script:Assertions += 1
  if ($Actual -ne $Expected) {
    throw "assertion failed: $Message; expected=$Expected actual=$Actual"
  }
}

function Assert-Match {
  param([string]$Value, [string]$Pattern, [string]$Message)
  $script:Assertions += 1
  if ($Value -notmatch $Pattern) { throw "assertion failed: $Message" }
}

function Assert-NotMatch {
  param([string]$Value, [string]$Pattern, [string]$Message)
  $script:Assertions += 1
  if ($Value -match $Pattern) { throw "assertion failed: $Message" }
}

function Get-FixedFailureClass {
  param([scriptblock]$Action)
  try {
    & $Action
    throw "expected fixed failure"
  } catch {
    $exception = $_.Exception
    while ($null -ne $exception) {
      if ($exception.GetType().FullName -eq
        "SwordAgentOS.AudioAwareness.VoiceCaptureDspException") {
        return [string]$exception.FailureClass
      }
      $exception = $exception.InnerException
    }
    throw
  }
}

$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$sourcePath = Join-Path $root "audio-awareness\windows\VoiceCaptureDspAec.cs"
$wrapperPath = Join-Path $root "audio-awareness\windows\invoke-voice-capture-dsp-aec.ps1"

Assert-True (Test-Path -LiteralPath $sourcePath -PathType Leaf) "C# source exists"
Assert-True (Test-Path -LiteralPath $wrapperPath -PathType Leaf) "wrapper exists"

$tokens = $null
$parseErrors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile(
  $wrapperPath,
  [ref]$tokens,
  [ref]$parseErrors)
Assert-Equal @($parseErrors).Count 0 "wrapper parser errors"

$sourceText = Get-Content -LiteralPath $sourcePath -Raw
$fakeTypes = @'
namespace SwordAgentOS.AudioAwareness.Tests
{
    public sealed class FakeServerProcessIdentity :
        SwordAgentOS.AudioAwareness.IServerProcessIdentity
    {
        public bool Available { get; set; } = true;
        public long CreationUtcTicks { get; set; } = 100;

        public bool TryGetCreationUtcTicks(out long creationUtcTicks)
        {
            return TryGetCreationUtcTicks(1, out creationUtcTicks);
        }

        public bool TryGetCreationUtcTicks(
            int processId,
            out long creationUtcTicks)
        {
            creationUtcTicks = CreationUtcTicks;
            return Available;
        }
    }

    public sealed class FakeVoiceCaptureDspBackend :
        SwordAgentOS.AudioAwareness.IVoiceCaptureDspBackend
    {
        private readonly System.Collections.Generic.Queue<byte[]> _packets =
            new System.Collections.Generic.Queue<byte[]>();
        private readonly bool _throwOnStop;
        private byte[] _lastPacket;

        public FakeVoiceCaptureDspBackend(int packetLength, bool throwOnStop)
        {
            _throwOnStop = throwOnStop;
            if (packetLength > 0)
            {
                byte[] packet = new byte[packetLength];
                for (int index = 0; index < packet.Length; index += 1)
                {
                    packet[index] = (byte)((index % 251) + 1);
                }
                _lastPacket = packet;
                _packets.Enqueue(packet);
            }
        }

        public int ActivateCount { get; private set; }
        public int CaptureStartCount { get; private set; }
        public int CaptureStopAttemptCount { get; private set; }
        public int CaptureStopCount { get; private set; }
        public int ResourceReleaseCount { get; private set; }
        public int DisposeCount { get; private set; }

        public System.Threading.Tasks.Task ActivateAsync(
            System.Threading.CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            ActivateCount += 1;
            return System.Threading.Tasks.Task.CompletedTask;
        }

        public void Start()
        {
            CaptureStartCount += 1;
        }

        public bool TryReadProcessedPcm(out byte[] processedPcm)
        {
            if (_packets.Count == 0)
            {
                processedPcm = null;
                return false;
            }
            processedPcm = _packets.Dequeue();
            return true;
        }

        public bool LastPacketWasCleared()
        {
            if (_lastPacket == null) return false;
            foreach (byte value in _lastPacket)
            {
                if (value != 0) return false;
            }
            return true;
        }

        public void Stop()
        {
            CaptureStopAttemptCount += 1;
            if (_throwOnStop)
            {
                throw new System.InvalidOperationException("private-stop-marker");
            }
            CaptureStopCount += 1;
        }

        public void Dispose()
        {
            DisposeCount += 1;
            ResourceReleaseCount += 1;
        }
    }

    public sealed class FakeTransientPcmSink :
        SwordAgentOS.AudioAwareness.ITransientPcmSink
    {
        private readonly bool _throwOnDispose;
        private byte[] _lastBuffer;

        public FakeTransientPcmSink(bool throwOnDispose)
        {
            _throwOnDispose = throwOnDispose;
        }

        public int ConnectCount { get; private set; }
        public int WriteCount { get; private set; }
        public int ReleaseCount { get; private set; }
        public bool ThrowOnWrite { get; set; }
        public int ConnectDelayMs { get; set; }
        public int WriteDelayMs { get; set; }
        public bool WriteCompletedAfterCancellation { get; private set; }

        public async System.Threading.Tasks.Task ConnectAsync(
            System.Threading.CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (ConnectDelayMs > 0)
            {
                await System.Threading.Tasks.Task.Delay(
                    ConnectDelayMs,
                    cancellationToken).ConfigureAwait(false);
            }
            ConnectCount += 1;
        }

        public async System.Threading.Tasks.Task WriteAsync(
            byte[] processedPcm,
            System.Threading.CancellationToken cancellationToken)
        {
            _lastBuffer = processedPcm;
            cancellationToken.ThrowIfCancellationRequested();
            if (WriteDelayMs > 0)
            {
                try
                {
                    await System.Threading.Tasks.Task.Delay(
                        WriteDelayMs,
                        cancellationToken).ConfigureAwait(false);
                }
                catch (System.OperationCanceledException)
                {
                    throw;
                }
            }
            if (ThrowOnWrite)
            {
                throw new SwordAgentOS.AudioAwareness.VoiceCaptureDspException(
                    "processed_pcm_pipe_write_failed");
            }
            if (cancellationToken.IsCancellationRequested)
            {
                WriteCompletedAfterCancellation = true;
                cancellationToken.ThrowIfCancellationRequested();
            }
            WriteCount += 1;
        }

        public bool LastBufferWasCleared()
        {
            if (_lastBuffer == null) return false;
            foreach (byte value in _lastBuffer)
            {
                if (value != 0) return false;
            }
            return true;
        }

        public void Dispose()
        {
            ReleaseCount += 1;
            if (_throwOnDispose)
            {
                throw new System.InvalidOperationException("private-sink-marker");
            }
        }
    }

    public sealed class NamedPipeBehaviorResult
    {
        public string ResultClass { get; set; }
        public int BackendActivateCount { get; set; }
        public int SinkWriteCount { get; set; }
        public int BackendReleaseCount { get; set; }
        public int SinkReleaseCount { get; set; }
        public bool NonceMatched { get; set; }
        public bool NonceCleared { get; set; }
        public bool ServerConverged { get; set; }
        public int ServerFrameCount { get; set; }
    }

    internal sealed class NamedPipeServerFixtureResult
    {
        public bool NonceMatched { get; set; }
        public bool NonceCleared { get; set; }
        public bool Converged { get; set; }
        public int FrameCount { get; set; }
    }

    public static class NamedPipeBehaviorHarness
    {
        public static async System.Threading.Tasks.Task<NamedPipeBehaviorResult>
            RunAsync(string mode)
        {
            string pipeName = "sword-aec-" + System.Guid.NewGuid().ToString("N");
            string nonceHex =
                "0123456789abcdef0123456789abcdef" +
                "0123456789abcdef0123456789abcdef";
            byte[] expectedNonce = new byte[32];
            for (int index = 0; index < expectedNonce.Length; index += 1)
            {
                expectedNonce[index] = System.Convert.ToByte(
                    nonceHex.Substring(index * 2, 2),
                    16);
            }

            var serverTask = RunServerAsync(
                pipeName,
                mode,
                expectedNonce);
            long nowTicks = System.DateTime.UtcNow.Ticks;
            SwordAgentOS.AudioAwareness.ProcessedPcmPipeLease lease;
            SwordAgentOS.AudioAwareness.NamedPipePcmSink sink;
            if (mode == "identity_mismatch")
            {
                var fakeIdentity = new FakeServerProcessIdentity();
                lease = SwordAgentOS.AudioAwareness.VoiceCaptureDspAec
                    .AcquirePipeLease(
                        pipeName,
                        nonceHex,
                        1,
                        fakeIdentity.CreationUtcTicks,
                        nowTicks + System.TimeSpan.FromSeconds(5).Ticks,
                        "synthetic_aec_owner_selected",
                        "windows_voice_capture_dsp",
                        fakeIdentity,
                        nowTicks);
                sink = new SwordAgentOS.AudioAwareness.NamedPipePcmSink(
                    lease,
                    1000,
                    fakeIdentity,
                    () => System.DateTime.UtcNow.Ticks);
            }
            else
            {
                using (System.Diagnostics.Process process =
                    System.Diagnostics.Process.GetCurrentProcess())
                {
                    lease = SwordAgentOS.AudioAwareness.VoiceCaptureDspAec
                        .AcquirePipeLease(
                            pipeName,
                            nonceHex,
                            process.Id,
                            process.StartTime.ToUniversalTime().Ticks,
                            nowTicks + System.TimeSpan.FromSeconds(5).Ticks,
                            "synthetic_aec_owner_selected",
                            "windows_voice_capture_dsp");
                }
                sink = new SwordAgentOS.AudioAwareness.NamedPipePcmSink(
                    lease,
                    mode == "delayed_ack" || mode == "missing_ack"
                        ? 300
                        : 1000);
            }

            var backend = new FakeVoiceCaptureDspBackend(320, false);
            string resultClass = "success";
            try
            {
                await SwordAgentOS.AudioAwareness.VoiceCaptureDspAec
                    .ObserveWithBackendAsync(
                        backend,
                        sink,
                        lease,
                        mode == "identity_mismatch"
                            ? (SwordAgentOS.AudioAwareness.IServerProcessIdentity)
                                new FakeServerProcessIdentity()
                            : new SwordAgentOS.AudioAwareness.ServerProcessIdentity(),
                        () => System.DateTime.UtcNow.Ticks,
                        100,
                        mode == "delayed_ack" || mode == "missing_ack"
                            ? 300
                            : 1000,
                        System.Threading.CancellationToken.None)
                    .ConfigureAwait(false);
            }
            catch (SwordAgentOS.AudioAwareness.VoiceCaptureDspException error)
            {
                resultClass = error.FailureClass;
            }

            NamedPipeServerFixtureResult server = await serverTask
                .ConfigureAwait(false);
            bool expectedCleared = true;
            foreach (byte value in expectedNonce)
            {
                if (value != 0) expectedCleared = false;
            }
            return new NamedPipeBehaviorResult
            {
                ResultClass = resultClass,
                BackendActivateCount = backend.ActivateCount,
                SinkWriteCount = sink.WriteCount,
                BackendReleaseCount = backend.ResourceReleaseCount,
                SinkReleaseCount = sink.ReleaseCount,
                NonceMatched = server.NonceMatched,
                NonceCleared = server.NonceCleared && expectedCleared,
                ServerConverged = server.Converged,
                ServerFrameCount = server.FrameCount
            };
        }

        private static async System.Threading.Tasks.Task<
            NamedPipeServerFixtureResult> RunServerAsync(
                string pipeName,
                string mode,
                byte[] expectedNonce)
        {
            byte[] receivedNonce = new byte[32];
            byte[] prefix = new byte[4];
            byte[] frame = null;
            bool nonceMatched = false;
            int frameCount = 0;
            try
            {
                using (var server = new System.IO.Pipes.NamedPipeServerStream(
                    pipeName,
                    System.IO.Pipes.PipeDirection.InOut,
                    1,
                    System.IO.Pipes.PipeTransmissionMode.Byte,
                    System.IO.Pipes.PipeOptions.Asynchronous))
                {
                    await server.WaitForConnectionAsync().ConfigureAwait(false);
                    int nonceRead = await ReadExactAsync(
                        server,
                        receivedNonce,
                        receivedNonce.Length).ConfigureAwait(false);
                    nonceMatched = nonceRead == receivedNonce.Length &&
                        FixedEquals(receivedNonce, expectedNonce);
                    if (mode == "delayed_ack" || mode == "missing_ack")
                    {
                        await System.Threading.Tasks.Task.Delay(500)
                            .ConfigureAwait(false);
                    }
                    if (mode != "missing_ack" && mode != "identity_mismatch")
                    {
                        byte acknowledgement = mode == "wrong_ack"
                            ? (byte)0xA2
                            : (byte)0xA1;
                        await server.WriteAsync(
                            new byte[] { acknowledgement },
                            0,
                            1).ConfigureAwait(false);
                        await server.FlushAsync().ConfigureAwait(false);
                    }
                    if (mode == "correct")
                    {
                        int prefixRead = await ReadExactAsync(
                            server,
                            prefix,
                            prefix.Length).ConfigureAwait(false);
                        int frameLength = prefixRead == prefix.Length
                            ? System.BitConverter.ToInt32(prefix, 0)
                            : 0;
                        if (frameLength == 320)
                        {
                            frame = new byte[frameLength];
                            if (await ReadExactAsync(
                                server,
                                frame,
                                frame.Length).ConfigureAwait(false) == frame.Length)
                            {
                                frameCount = 1;
                            }
                        }
                    }
                }
            }
            catch
            {
            }
            finally
            {
                System.Array.Clear(receivedNonce, 0, receivedNonce.Length);
                System.Array.Clear(expectedNonce, 0, expectedNonce.Length);
                System.Array.Clear(prefix, 0, prefix.Length);
                if (frame != null) System.Array.Clear(frame, 0, frame.Length);
            }
            bool nonceCleared = true;
            foreach (byte value in receivedNonce)
            {
                if (value != 0) nonceCleared = false;
            }
            return new NamedPipeServerFixtureResult
            {
                NonceMatched = nonceMatched,
                NonceCleared = nonceCleared,
                Converged = true,
                FrameCount = frameCount
            };
        }

        private static async System.Threading.Tasks.Task<int> ReadExactAsync(
            System.IO.Stream stream,
            byte[] buffer,
            int expected)
        {
            int total = 0;
            while (total < expected)
            {
                int read = await stream.ReadAsync(
                    buffer,
                    total,
                    expected - total).ConfigureAwait(false);
                if (read == 0) break;
                total += read;
            }
            return total;
        }

        private static bool FixedEquals(byte[] left, byte[] right)
        {
            int difference = left.Length ^ right.Length;
            int count = System.Math.Min(left.Length, right.Length);
            for (int index = 0; index < count; index += 1)
            {
                difference |= left[index] ^ right[index];
            }
            return difference == 0;
        }
    }

    public static class VoiceCaptureDspHarness
    {
        public static SwordAgentOS.AudioAwareness.ProcessedPcmPipeLease Lease(
            FakeServerProcessIdentity identity,
            int ttlMs,
            long nowTicks)
        {
            return SwordAgentOS.AudioAwareness.VoiceCaptureDspAec.AcquirePipeLease(
                "sword-aec-0123456789abcdef0123456789abcdef",
                "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
                123,
                identity.CreationUtcTicks,
                nowTicks + System.TimeSpan.FromMilliseconds(ttlMs).Ticks,
                "synthetic_aec_owner_selected",
                "windows_voice_capture_dsp",
                identity,
                nowTicks);
        }

        public static System.Threading.Tasks.Task<
            SwordAgentOS.AudioAwareness.VoiceCaptureDspObservation> Observe(
                FakeVoiceCaptureDspBackend backend,
                FakeTransientPcmSink sink,
                FakeServerProcessIdentity identity,
                SwordAgentOS.AudioAwareness.ProcessedPcmPipeLease lease,
                long nowTicks,
                int windowMs,
                int deadlineMs,
                System.Threading.CancellationToken cancellationToken)
        {
            return SwordAgentOS.AudioAwareness.VoiceCaptureDspAec
                .ObserveWithBackendAsync(
                    backend,
                    sink,
                    lease,
                    identity,
                    () => nowTicks,
                    windowMs,
                    deadlineMs,
                    cancellationToken);
        }

        public static System.Threading.Tasks.Task<
            SwordAgentOS.AudioAwareness.VoiceCaptureDspObservation> ObserveTimes(
                FakeVoiceCaptureDspBackend backend,
                FakeTransientPcmSink sink,
                FakeServerProcessIdentity identity,
                SwordAgentOS.AudioAwareness.ProcessedPcmPipeLease lease,
                long firstTicks,
                long secondTicks)
        {
            var times = new System.Collections.Generic.Queue<long>();
            times.Enqueue(firstTicks);
            times.Enqueue(secondTicks);
            return SwordAgentOS.AudioAwareness.VoiceCaptureDspAec
                .ObserveWithBackendAsync(
                    backend,
                    sink,
                    lease,
                    identity,
                    () => times.Count > 0 ? times.Dequeue() : secondTicks,
                    100,
                    1000,
                    System.Threading.CancellationToken.None);
        }

        public static object[] NativeShape()
        {
            return new object[]
            {
                SwordAgentOS.AudioAwareness.VoiceCaptureDspAec.VoiceCaptureDspClsid,
                SwordAgentOS.AudioAwareness.VoiceCaptureDspAec.VoiceCapturePropertySet,
                SwordAgentOS.AudioAwareness.VoiceCaptureDspAec.PidSystemMode,
                SwordAgentOS.AudioAwareness.VoiceCaptureDspAec.PidSourceMode,
                SwordAgentOS.AudioAwareness.VoiceCaptureDspAec.PidFeatureMode,
                SwordAgentOS.AudioAwareness.VoiceCaptureDspAec.PidNoiseSuppression,
                SwordAgentOS.AudioAwareness.VoiceCaptureDspAec.PidAutomaticGainControl,
                SwordAgentOS.AudioAwareness.VoiceCaptureDspAec.SingleChannelAec,
                SwordAgentOS.AudioAwareness.VoiceCaptureDspAec.SampleRate,
                SwordAgentOS.AudioAwareness.VoiceCaptureDspAec.ChannelCount,
                SwordAgentOS.AudioAwareness.VoiceCaptureDspAec.BitsPerSample,
                SwordAgentOS.AudioAwareness.VoiceCaptureDspAec.FrameDurationMs
                ,SwordAgentOS.AudioAwareness.VoiceCaptureDspAec.FrameBytes
            };
        }

        public static string ValidateConnectedServer(
            SwordAgentOS.AudioAwareness.ProcessedPcmPipeLease lease,
            int actualServerProcessId,
            FakeServerProcessIdentity identity,
            long nowTicks)
        {
            try
            {
                SwordAgentOS.AudioAwareness.VoiceCaptureDspAec
                    .ValidateConnectedServer(
                        lease,
                        actualServerProcessId,
                        identity,
                        nowTicks);
                return "server_identity_matched";
            }
            catch (SwordAgentOS.AudioAwareness.VoiceCaptureDspException error)
            {
                return error.FailureClass;
            }
        }

        public static object[] InternalBufferClearShape()
        {
            var buffer = new SwordAgentOS.AudioAwareness.ManagedMediaBuffer(320);
            try
            {
                System.IntPtr pointer;
                uint length;
                buffer.GetBufferAndLength(out pointer, out length);
                byte[] fixture = new byte[320];
                for (int index = 0; index < fixture.Length; index += 1)
                {
                    fixture[index] = (byte)((index % 251) + 1);
                }
                System.Runtime.InteropServices.Marshal.Copy(
                    fixture,
                    0,
                    pointer,
                    fixture.Length);
                buffer.SetLength((uint)fixture.Length);
                byte[] copy = buffer.CopyCurrentBytes();
                bool copied = copy.Length == 320 && copy[0] == 1;
                bool cleared = buffer.IsCleared();
                System.Array.Clear(fixture, 0, fixture.Length);
                System.Array.Clear(copy, 0, copy.Length);
                return new object[] { copied, cleared, buffer.CurrentLength };
            }
            finally
            {
                buffer.Dispose();
            }
        }
    }
}
'@

Add-Type -TypeDefinition ($sourceText + "`n" + $fakeTypes)

function Invoke-Wrapper {
  param([hashtable]$Parameters)
  $json = (& $wrapperPath @Parameters | Out-String).Trim()
  return [pscustomobject]@{
    Json = $json
    Value = $json | ConvertFrom-Json -Depth 20
  }
}

$capability = Invoke-Wrapper -Parameters @{ Compact = $true }
Assert-Match $capability.Value.result_class '^voice_capture_dsp_' "fixed capability class"
Assert-Equal $capability.Value.owner_class "windows_voice_capture_dsp" "one owner class"
Assert-False $capability.Value.observation.live_capture_used "capability is no-live"
Assert-Equal $capability.Value.lifecycle.cleanup_class "no_runtime_started" "capability cleanup"
Assert-False $capability.Value.privacy.raw_audio_persisted "capability persists no audio"
Assert-False $capability.Value.authority.exactly_one_aec_owner "capability does not claim verified AEC owner"
Assert-False $capability.Value.authority.render_reference_turn_input_authority "render has no TurnInput authority"
Assert-NotMatch $capability.Json '(?i)sword-aec-[a-f0-9]+|[A-Z]:\\' "capability omits private identities"
Assert-False $capability.Value.privacy.process_or_device_identity_published "capability publishes no process/device identity"

$missingPipe = Invoke-Wrapper -Parameters @{
  Mode = "live_source"
  Compact = $true
}
Assert-Equal $missingPipe.Value.result_class "processed_pcm_pipe_lease_missing" "missing pipe fixed class"
Assert-Equal $missingPipe.Value.lifecycle.cleanup_class "no_runtime_started" "missing pipe no runtime"
Assert-False $missingPipe.Value.observation.live_capture_used "missing pipe no live capture"

Assert-NotMatch (Get-Content -LiteralPath $wrapperPath -Raw) 'param\([\s\S]{0,320}\$PipeName' "pipe name absent from command-line parameters"
Assert-Match (Get-Content -LiteralPath $wrapperPath -Raw) 'Console\]::In\.ReadLineAsync' "private lease arrives over stdin"

$pipeCases = [ordered]@{
  correct = "success"
  wrong_ack = "processed_pcm_pipe_handshake_failed"
  delayed_ack = "processed_pcm_pipe_handshake_failed"
  missing_ack = "processed_pcm_pipe_handshake_failed"
  identity_mismatch = "processed_pcm_pipe_server_identity_mismatch"
}
foreach ($entry in $pipeCases.GetEnumerator()) {
  $behavior = [SwordAgentOS.AudioAwareness.Tests.NamedPipeBehaviorHarness]::RunAsync(
    $entry.Key).GetAwaiter().GetResult()
  Assert-Equal $behavior.ResultClass $entry.Value "$($entry.Key) real pipe result class"
  Assert-True $behavior.ServerConverged "$($entry.Key) server task converged"
  Assert-True $behavior.NonceCleared "$($entry.Key) nonce buffers cleared"
  Assert-Equal $behavior.BackendReleaseCount 1 "$($entry.Key) backend release once"
  Assert-Equal $behavior.SinkReleaseCount 1 "$($entry.Key) sink release once"
  if ($entry.Key -eq "correct") {
    Assert-True $behavior.NonceMatched "correct pipe nonce matched"
    Assert-Equal $behavior.BackendActivateCount 1 "correct pipe activates once"
    Assert-Equal $behavior.SinkWriteCount 1 "correct pipe writes once"
    Assert-Equal $behavior.ServerFrameCount 1 "correct pipe receives one exact frame"
  } else {
    Assert-Equal $behavior.BackendActivateCount 0 "$($entry.Key) fails before activation"
    Assert-Equal $behavior.SinkWriteCount 0 "$($entry.Key) has no completed or late write"
    Assert-Equal $behavior.ServerFrameCount 0 "$($entry.Key) receives no frame"
  }
}

$identity = [SwordAgentOS.AudioAwareness.Tests.FakeServerProcessIdentity]::new()
$lease = [SwordAgentOS.AudioAwareness.Tests.VoiceCaptureDspHarness]::Lease(
  $identity,
  1000,
  0)
$backend = [SwordAgentOS.AudioAwareness.Tests.FakeVoiceCaptureDspBackend]::new(320, $false)
$sink = [SwordAgentOS.AudioAwareness.Tests.FakeTransientPcmSink]::new($false)
$result = [SwordAgentOS.AudioAwareness.Tests.VoiceCaptureDspHarness]::Observe(
  $backend,
  $sink,
  $identity,
  $lease,
  0,
  100,
  1000,
  [System.Threading.CancellationToken]::None).GetAwaiter().GetResult()
Assert-Equal $result.ResultClass "processed_near_end_pcm_observed" "processed fixture observed"
Assert-Equal $result.OwnerClass "windows_voice_capture_dsp" "result owner"
Assert-Equal $result.PacketCount 1 "one processed packet"
Assert-Equal $result.ProcessedByteCount 320 "processed byte count only"
Assert-Equal $result.BackendActivateCount 1 "backend activates once"
Assert-Equal $result.CaptureStartCount 1 "capture starts once"
Assert-Equal $result.CaptureStopAttemptCount 1 "capture stop attempted once"
Assert-Equal $result.CaptureStopCount 1 "capture stops once"
Assert-Equal $result.BackendResourceReleaseCount 1 "backend releases once"
Assert-Equal $result.SinkConnectCount 1 "sink connects once"
Assert-Equal $result.SinkWriteCount 1 "sink writes once"
Assert-Equal $result.SinkReleaseCount 1 "sink releases once"
Assert-False $result.RenderReferencePublished "render reference not published"
Assert-False $result.RawAudioPersisted "raw audio not persisted"
Assert-False $result.TurnInputAuthority "result has no TurnInput authority"
Assert-True $sink.LastBufferWasCleared() "processed buffer cleared after sink write"
Assert-Equal $backend.DisposeCount 1 "backend disposed once"

$invalidPackets = [ordered]@{
  oversize = 322
  odd = 319
}
foreach ($entry in $invalidPackets.GetEnumerator()) {
  $invalidBackend = [SwordAgentOS.AudioAwareness.Tests.FakeVoiceCaptureDspBackend]::new(
    $entry.Value,
    $false)
  $invalidSink = [SwordAgentOS.AudioAwareness.Tests.FakeTransientPcmSink]::new($false)
  $invalidClass = Get-FixedFailureClass {
    [SwordAgentOS.AudioAwareness.Tests.VoiceCaptureDspHarness]::Observe(
      $invalidBackend,
      $invalidSink,
      $identity,
      $lease,
      0,
      100,
      1000,
      [System.Threading.CancellationToken]::None).GetAwaiter().GetResult()
  }
  Assert-Equal $invalidClass "live_aec_processed_packet_invalid" "$($entry.Key) packet fixed class"
  Assert-Equal $invalidSink.WriteCount 0 "$($entry.Key) packet not written"
  Assert-True $invalidBackend.LastPacketWasCleared() "$($entry.Key) packet cleared"
  Assert-Equal $invalidBackend.ResourceReleaseCount 1 "$($entry.Key) backend released once"
  Assert-Equal $invalidSink.ReleaseCount 1 "$($entry.Key) sink released once"
}

$writeBackend = [SwordAgentOS.AudioAwareness.Tests.FakeVoiceCaptureDspBackend]::new(320, $false)
$writeSink = [SwordAgentOS.AudioAwareness.Tests.FakeTransientPcmSink]::new($false)
$writeSink.ThrowOnWrite = $true
$writeClass = Get-FixedFailureClass {
  [SwordAgentOS.AudioAwareness.Tests.VoiceCaptureDspHarness]::Observe(
    $writeBackend,
    $writeSink,
    $identity,
    $lease,
    0,
    100,
    1000,
    [System.Threading.CancellationToken]::None).GetAwaiter().GetResult()
}
Assert-Equal $writeClass "processed_pcm_pipe_write_failed" "write failure fixed non-echo class"
Assert-True $writeSink.LastBufferWasCleared() "write failure clears processed packet"
Assert-True $writeBackend.LastPacketWasCleared() "write failure leaves no backend packet bytes"
Assert-Equal $writeBackend.ResourceReleaseCount 1 "write failure backend release exactly once"
Assert-Equal $writeSink.ReleaseCount 1 "write failure sink release exactly once"

$silenceBackend = [SwordAgentOS.AudioAwareness.Tests.FakeVoiceCaptureDspBackend]::new(0, $false)
$silenceSink = [SwordAgentOS.AudioAwareness.Tests.FakeTransientPcmSink]::new($false)
$silence = [SwordAgentOS.AudioAwareness.Tests.VoiceCaptureDspHarness]::Observe(
  $silenceBackend,
  $silenceSink,
  $identity,
  $lease,
  0,
  100,
  1000,
  [System.Threading.CancellationToken]::None).GetAwaiter().GetResult()
Assert-Equal $silence.ResultClass "processed_near_end_silence_observed" "silence class"
Assert-Equal $silence.PacketCount 0 "silence has no packet"
Assert-Equal $silenceSink.WriteCount 0 "silence writes no PCM"

$stopBackend = [SwordAgentOS.AudioAwareness.Tests.FakeVoiceCaptureDspBackend]::new(320, $true)
$stopSink = [SwordAgentOS.AudioAwareness.Tests.FakeTransientPcmSink]::new($false)
$stopClass = Get-FixedFailureClass {
  [SwordAgentOS.AudioAwareness.Tests.VoiceCaptureDspHarness]::Observe(
    $stopBackend,
    $stopSink,
    $identity,
    $lease,
    0,
    100,
    1000,
    [System.Threading.CancellationToken]::None).GetAwaiter().GetResult()
}
Assert-Equal $stopClass "live_aec_cleanup_failed" "stop failure fixed cleanup class"
Assert-Equal $stopBackend.CaptureStopAttemptCount 1 "failed stop attempted once"
Assert-Equal $stopBackend.CaptureStopCount 0 "failed stop not success"
Assert-Equal $stopBackend.DisposeCount 1 "failed stop disposes once without retry"
Assert-Equal $stopSink.ReleaseCount 1 "failed stop releases sink"

$cancelBackend = [SwordAgentOS.AudioAwareness.Tests.FakeVoiceCaptureDspBackend]::new(0, $false)
$cancelSink = [SwordAgentOS.AudioAwareness.Tests.FakeTransientPcmSink]::new($false)
$cancelSource = [System.Threading.CancellationTokenSource]::new()
$cancelSource.CancelAfter(25)
$cancelClass = Get-FixedFailureClass {
  [SwordAgentOS.AudioAwareness.Tests.VoiceCaptureDspHarness]::Observe(
    $cancelBackend,
    $cancelSink,
    $identity,
    $lease,
    0,
    500,
    1000,
    $cancelSource.Token).GetAwaiter().GetResult()
}
$cancelSource.Dispose()
Assert-Equal $cancelClass "live_aec_deadline_exceeded" "cancel fixed class"
Assert-Equal $cancelBackend.CaptureStopAttemptCount 1 "cancel stop attempted"
Assert-Equal $cancelBackend.CaptureStopCount 1 "cancel stopped"
Assert-Equal $cancelBackend.DisposeCount 1 "cancel disposed"
Assert-Equal $cancelSink.ReleaseCount 1 "cancel sink released"

$midWriteBackend = [SwordAgentOS.AudioAwareness.Tests.FakeVoiceCaptureDspBackend]::new(320, $false)
$midWriteSink = [SwordAgentOS.AudioAwareness.Tests.FakeTransientPcmSink]::new($false)
$midWriteSink.WriteDelayMs = 500
$midWriteSource = [System.Threading.CancellationTokenSource]::new()
$midWriteSource.CancelAfter(25)
$midWriteClass = Get-FixedFailureClass {
  [SwordAgentOS.AudioAwareness.Tests.VoiceCaptureDspHarness]::Observe(
    $midWriteBackend,
    $midWriteSink,
    $identity,
    $lease,
    0,
    500,
    1000,
    $midWriteSource.Token).GetAwaiter().GetResult()
}
$midWriteSource.Dispose()
Assert-Equal $midWriteClass "live_aec_deadline_exceeded" "mid-write cancellation fixed class"
Assert-Equal $midWriteSink.WriteCount 0 "mid-write cancellation has no completed write"
Assert-False $midWriteSink.WriteCompletedAfterCancellation "mid-write cancellation has no late write"
Assert-True $midWriteSink.LastBufferWasCleared() "mid-write cancellation clears processed packet"
Assert-True $midWriteBackend.LastPacketWasCleared() "mid-write backend packet clears"
Assert-Equal $midWriteBackend.ResourceReleaseCount 1 "mid-write backend release once"
Assert-Equal $midWriteSink.ReleaseCount 1 "mid-write sink release once"

$preCancelledBackend = [SwordAgentOS.AudioAwareness.Tests.FakeVoiceCaptureDspBackend]::new(320, $false)
$preCancelledSink = [SwordAgentOS.AudioAwareness.Tests.FakeTransientPcmSink]::new($false)
$preCancelledSource = [System.Threading.CancellationTokenSource]::new()
$preCancelledSource.Cancel()
$preCancelledClass = Get-FixedFailureClass {
  [SwordAgentOS.AudioAwareness.Tests.VoiceCaptureDspHarness]::Observe(
    $preCancelledBackend,
    $preCancelledSink,
    $identity,
    $lease,
    0,
    100,
    1000,
    $preCancelledSource.Token).GetAwaiter().GetResult()
}
$preCancelledSource.Dispose()
Assert-Equal $preCancelledClass "live_aec_deadline_exceeded" "pre-cancel fixed class"
Assert-Equal $preCancelledBackend.ActivateCount 0 "pre-cancel has no activation"
Assert-Equal $preCancelledSink.WriteCount 0 "pre-cancel has no write"
Assert-Equal $preCancelledBackend.ResourceReleaseCount 1 "pre-cancel backend release once"
Assert-Equal $preCancelledSink.ReleaseCount 1 "pre-cancel sink release once"

$delayedBackend = [SwordAgentOS.AudioAwareness.Tests.FakeVoiceCaptureDspBackend]::new(320, $false)
$delayedSink = [SwordAgentOS.AudioAwareness.Tests.FakeTransientPcmSink]::new($false)
$delayedSink.ConnectDelayMs = 500
$delayedClass = Get-FixedFailureClass {
  [SwordAgentOS.AudioAwareness.Tests.VoiceCaptureDspHarness]::Observe(
    $delayedBackend,
    $delayedSink,
    $identity,
    $lease,
    0,
    100,
    300,
    [System.Threading.CancellationToken]::None).GetAwaiter().GetResult()
}
Assert-Equal $delayedClass "live_aec_deadline_exceeded" "delayed reader timeout fixed class"
Assert-Equal $delayedBackend.ActivateCount 0 "delayed reader has no late activation"
Assert-Equal $delayedSink.WriteCount 0 "delayed reader has no late write"
Assert-Equal $delayedBackend.ResourceReleaseCount 1 "delayed backend release once"
Assert-Equal $delayedSink.ReleaseCount 1 "delayed sink release once"

$expiryBackend = [SwordAgentOS.AudioAwareness.Tests.FakeVoiceCaptureDspBackend]::new(320, $false)
$expirySink = [SwordAgentOS.AudioAwareness.Tests.FakeTransientPcmSink]::new($false)
$expiryClass = Get-FixedFailureClass {
  [SwordAgentOS.AudioAwareness.Tests.VoiceCaptureDspHarness]::ObserveTimes(
    $expiryBackend,
    $expirySink,
    $identity,
    $lease,
    0,
    1001 * 10000L).GetAwaiter().GetResult()
}
Assert-Equal $expiryClass "processed_pcm_pipe_lease_expired" "post-connect expiry fixed class"
Assert-Equal $expiryBackend.ActivateCount 0 "expired after connect has no activation"
Assert-Equal $expirySink.ConnectCount 1 "expired route connected once"
Assert-Equal $expirySink.WriteCount 0 "expired route has no write"
Assert-Equal $expiryBackend.ResourceReleaseCount 1 "expired backend release once"
Assert-Equal $expirySink.ReleaseCount 1 "expired sink release once"

$leaseFailures = [ordered]@{
  expired = "processed_pcm_pipe_lease_expired"
  mismatch = "processed_pcm_pipe_server_identity_mismatch"
}

$serverIdentity = [SwordAgentOS.AudioAwareness.Tests.FakeServerProcessIdentity]::new()
$serverLease = [SwordAgentOS.AudioAwareness.Tests.VoiceCaptureDspHarness]::Lease(
  $serverIdentity,
  1000,
  0)
Assert-Equal ([SwordAgentOS.AudioAwareness.Tests.VoiceCaptureDspHarness]::ValidateConnectedServer(
    $serverLease,
    123,
    $serverIdentity,
    0)) "server_identity_matched" "expected server identity matches"
Assert-Equal ([SwordAgentOS.AudioAwareness.Tests.VoiceCaptureDspHarness]::ValidateConnectedServer(
    $serverLease,
    124,
    $serverIdentity,
    0)) "processed_pcm_pipe_server_identity_mismatch" "same-name attacker PID rejected"
$serverIdentity.CreationUtcTicks = 200
Assert-Equal ([SwordAgentOS.AudioAwareness.Tests.VoiceCaptureDspHarness]::ValidateConnectedServer(
    $serverLease,
    123,
    $serverIdentity,
    0)) "processed_pcm_pipe_server_identity_mismatch" "reused PID start identity rejected"
$serverIdentity.CreationUtcTicks = 100
Assert-Equal ([SwordAgentOS.AudioAwareness.Tests.VoiceCaptureDspHarness]::ValidateConnectedServer(
    $serverLease,
    123,
    $serverIdentity,
    1001 * 10000L)) "processed_pcm_pipe_lease_expired" "expired connected server rejected"
foreach ($entry in $leaseFailures.GetEnumerator()) {
  $failureIdentity = [SwordAgentOS.AudioAwareness.Tests.FakeServerProcessIdentity]::new()
  $failureLease = [SwordAgentOS.AudioAwareness.Tests.VoiceCaptureDspHarness]::Lease(
    $failureIdentity,
    1000,
    0)
  $now = 0
  if ($entry.Key -eq "expired") { $now = 1001 * 10000L }
  if ($entry.Key -eq "mismatch") { $failureIdentity.CreationUtcTicks = 200 }
  $failureBackend = [SwordAgentOS.AudioAwareness.Tests.FakeVoiceCaptureDspBackend]::new(0, $false)
  $failureSink = [SwordAgentOS.AudioAwareness.Tests.FakeTransientPcmSink]::new($false)
  $failureClass = Get-FixedFailureClass {
    [SwordAgentOS.AudioAwareness.Tests.VoiceCaptureDspHarness]::Observe(
      $failureBackend,
      $failureSink,
      $failureIdentity,
      $failureLease,
      $now,
      100,
      1000,
      [System.Threading.CancellationToken]::None).GetAwaiter().GetResult()
  }
  Assert-Equal $failureClass $entry.Value "lease $($entry.Key) fixed class"
  Assert-Equal $failureBackend.ActivateCount 0 "lease $($entry.Key) fails before activation"
  Assert-Equal $failureSink.ConnectCount 0 "lease $($entry.Key) fails before connect"
  Assert-Equal $failureBackend.DisposeCount 1 "lease $($entry.Key) disposes backend"
  Assert-Equal $failureSink.ReleaseCount 1 "lease $($entry.Key) disposes sink"
}

$shape = [SwordAgentOS.AudioAwareness.Tests.VoiceCaptureDspHarness]::NativeShape()
Assert-Equal $shape[0] "745057c7-f353-4f2d-a7ee-58434477730e" "SDK Voice Capture DSP CLSID"
Assert-Equal $shape[1] "6f52c567-0360-4bd2-9617-ccbf1421c939" "SDK property set"
Assert-Equal $shape[2] 2 "system mode property id"
Assert-Equal $shape[3] 3 "source mode property id"
Assert-Equal $shape[4] 5 "feature mode property id"
Assert-Equal $shape[5] 8 "noise suppression property id"
Assert-Equal $shape[6] 9 "automatic gain control property id"
Assert-Equal $shape[7] 0 "single-channel AEC system mode"
Assert-Equal $shape[8] 16000 "output sample rate"
Assert-Equal $shape[9] 1 "output channel count"
Assert-Equal $shape[10] 16 "output bit depth"
Assert-Equal $shape[11] 10 "bounded frame duration"
Assert-Equal $shape[12] 320 "exact ten-millisecond frame bytes"

$bufferShape = [SwordAgentOS.AudioAwareness.Tests.VoiceCaptureDspHarness]::InternalBufferClearShape()
Assert-True $bufferShape[0] "internal DMO buffer copy succeeds"
Assert-True $bufferShape[1] "internal DMO buffer clears after copy"
Assert-Equal $bufferShape[2] 0 "internal DMO buffer length resets"

Assert-Match $sourceText 'NamedPipeClientStream' "in-memory pipe transport present"
Assert-Match $sourceText 'Array\.Clear\(processedPcm' "processed buffer cleared"
Assert-Match $sourceText 'GetNamedPipeServerProcessId' "actual pipe server PID is read"
Assert-Match $sourceText 'PipeDirection\.InOut' "nonce handshake uses duplex pipe"
Assert-Match $sourceText 'processed_pcm_pipe_handshake_failed' "nonce handshake fails closed"
Assert-Match $sourceText 'SINGLE_CHANNEL_AEC|SingleChannelAec' "one AEC owner mode"
Assert-Match $sourceText 'SetIntProperty\(\s*properties,\s*VoiceCaptureDspAec\.PidNoiseSuppression,\s*1\)' "noise suppression uses the required VT_I4 value"
Assert-NotMatch $sourceText 'SetBoolProperty\(\s*properties,\s*VoiceCaptureDspAec\.PidNoiseSuppression' "noise suppression is never encoded as VT_BOOL"
Assert-Match $sourceText 'SetBoolProperty\(\s*properties,\s*VoiceCaptureDspAec\.PidAutomaticGainControl,\s*true\)' "automatic gain control retains the required VT_BOOL value"
Assert-NotMatch $sourceText 'properties\.Commit\(' "transient Voice Capture DSP properties are applied without an unsupported commit"
Assert-NotMatch $sourceText 'WriteAllBytes|FileStream|\.wav|transcript' "source persists no audio or transcript"
Assert-NotMatch $sourceText 'Console\.(Write|Error)|Trace\.|Debug\.' "source logs no raw data"

[ordered]@{
  status = "ok"
  assertions = $script:Assertions
  parser_errors = @($parseErrors).Count
  live_audio_invocation_count = 0
  dependency_install_count = 0
  product_process_start_count = 0
  proof_ceiling = "source_static_live_aec_adapter_contract"
} | ConvertTo-Json -Compress
