using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO.Pipes;
using Microsoft.Win32.SafeHandles;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;

namespace SwordAgentOS.AudioAwareness
{
    public sealed class VoiceCaptureDspCapability
    {
        public string CapabilityClass { get; set; }
        public string PlatformClass { get; set; }
        public string ComClass { get; set; }
        public string OwnerClass { get; set; }
    }

    public sealed class VoiceCaptureDspObservation
    {
        public string ResultClass { get; set; }
        public string OwnerClass { get; set; }
        public string SourceClass { get; set; }
        public int WindowMs { get; set; }
        public int PacketCount { get; set; }
        public long ProcessedByteCount { get; set; }
        public int BackendActivateCount { get; set; }
        public int CaptureStartCount { get; set; }
        public int CaptureStopAttemptCount { get; set; }
        public int CaptureStopCount { get; set; }
        public int BackendResourceReleaseCount { get; set; }
        public int SinkConnectCount { get; set; }
        public int SinkWriteCount { get; set; }
        public int SinkReleaseCount { get; set; }
        public int CancelCount { get; set; }
        public bool RenderReferencePublished { get; set; }
        public bool RawAudioPersisted { get; set; }
        public bool TurnInputAuthority { get; set; }
    }

    public sealed class VoiceCaptureDspException : Exception
    {
        public VoiceCaptureDspException(string failureClass)
            : base(failureClass)
        {
            FailureClass = failureClass;
        }

        public string FailureClass { get; private set; }
    }

    public interface IVoiceCaptureDspBackend : IDisposable
    {
        int ActivateCount { get; }
        int CaptureStartCount { get; }
        int CaptureStopAttemptCount { get; }
        int CaptureStopCount { get; }
        int ResourceReleaseCount { get; }
        Task ActivateAsync(CancellationToken cancellationToken);
        void Start();
        bool TryReadProcessedPcm(out byte[] processedPcm);
        void Stop();
    }

    public interface ITransientPcmSink : IDisposable
    {
        int ConnectCount { get; }
        int WriteCount { get; }
        int ReleaseCount { get; }
        Task ConnectAsync(CancellationToken cancellationToken);
        Task WriteAsync(
            byte[] processedPcm,
            CancellationToken cancellationToken);
    }

    public sealed class ProcessedPcmPipeLease
    {
        internal ProcessedPcmPipeLease(
            string pipeName,
            string nonce,
            int serverProcessId,
            long serverCreationUtcTicks,
            long expiresUtcTicks)
        {
            PipeName = pipeName;
            Nonce = nonce;
            ServerProcessId = serverProcessId;
            ServerCreationUtcTicks = serverCreationUtcTicks;
            ExpiresUtcTicks = expiresUtcTicks;
        }

        internal string PipeName { get; private set; }
        internal string Nonce { get; private set; }
        internal int ServerProcessId { get; private set; }
        internal long ServerCreationUtcTicks { get; private set; }
        internal long ExpiresUtcTicks { get; private set; }
    }

    internal interface IServerProcessIdentity
    {
        bool TryGetCreationUtcTicks(int processId, out long creationUtcTicks);
    }

    internal sealed class ServerProcessIdentity : IServerProcessIdentity
    {
        public bool TryGetCreationUtcTicks(
            int processId,
            out long creationUtcTicks)
        {
            creationUtcTicks = 0;
            try
            {
                using (Process process = Process.GetProcessById(processId))
                {
                    if (process.HasExited)
                    {
                        return false;
                    }
                    creationUtcTicks = process.StartTime.ToUniversalTime().Ticks;
                    return true;
                }
            }
            catch
            {
                return false;
            }
        }
    }

    public static class VoiceCaptureDspAec
    {
        public const string WindowsVoiceCaptureDspOwnerClass =
            "windows_voice_capture_dsp";
        public const int SampleRate = 16000;
        public const int ChannelCount = 1;
        public const int BitsPerSample = 16;
        public const int FrameDurationMs = 10;
        public const int FrameBytes =
            SampleRate * ChannelCount * (BitsPerSample / 8) * FrameDurationMs / 1000;
        internal const string VoiceCaptureDspClsid =
            "745057c7-f353-4f2d-a7ee-58434477730e";
        internal const string VoiceCapturePropertySet =
            "6f52c567-0360-4bd2-9617-ccbf1421c939";
        internal const int PidSystemMode = 2;
        internal const int PidSourceMode = 3;
        internal const int PidFeatureMode = 5;
        internal const int PidNoiseSuppression = 8;
        internal const int PidAutomaticGainControl = 9;
        internal const int SingleChannelAec = 0;
        private static readonly Regex PipeNamePattern = new Regex(
            @"^sword-aec-[a-f0-9]{32}$",
            RegexOptions.CultureInvariant);
        private static readonly Regex NoncePattern = new Regex(
            @"^[a-f0-9]{64}$",
            RegexOptions.CultureInvariant);

        public static VoiceCaptureDspCapability GetCapability()
        {
            if (!RuntimeInformation.IsOSPlatform(OSPlatform.Windows))
            {
                return new VoiceCaptureDspCapability
                {
                    CapabilityClass = "voice_capture_dsp_unsupported_platform",
                    PlatformClass = "unsupported_platform",
                    ComClass = "not_checked",
                    OwnerClass = WindowsVoiceCaptureDspOwnerClass
                };
            }

            object instance = null;
            try
            {
                Type type = Type.GetTypeFromCLSID(
                    new Guid(VoiceCaptureDspClsid),
                    false);
                if (type == null)
                {
                    return Capability("voice_capture_dsp_com_unavailable");
                }
                instance = Activator.CreateInstance(type);
                if (!(instance is IMediaObject) || !(instance is IPropertyStore))
                {
                    return Capability("voice_capture_dsp_interface_unavailable");
                }
                return Capability("voice_capture_dsp_capability_available");
            }
            catch
            {
                return Capability("voice_capture_dsp_com_unavailable");
            }
            finally
            {
                ReleaseComObject(instance);
            }
        }

        public static ProcessedPcmPipeLease AcquirePipeLease(
            string pipeName,
            string nonce,
            int serverProcessId,
            long serverCreationUtcTicks,
            long expiresUtcTicks,
            string selectionClass,
            string selectedOwnerClass)
        {
            return AcquirePipeLease(
                pipeName,
                nonce,
                serverProcessId,
                serverCreationUtcTicks,
                expiresUtcTicks,
                selectionClass,
                selectedOwnerClass,
                new ServerProcessIdentity(),
                DateTime.UtcNow.Ticks);
        }

        internal static ProcessedPcmPipeLease AcquirePipeLease(
            string pipeName,
            string nonce,
            int serverProcessId,
            long serverCreationUtcTicks,
            long expiresUtcTicks,
            string selectionClass,
            string selectedOwnerClass,
            IServerProcessIdentity identity,
            long nowUtcTicks)
        {
            if (string.IsNullOrWhiteSpace(pipeName) ||
                !PipeNamePattern.IsMatch(pipeName) ||
                string.IsNullOrWhiteSpace(nonce) ||
                !NoncePattern.IsMatch(nonce) ||
                serverProcessId <= 0 ||
                serverCreationUtcTicks <= 0 ||
                expiresUtcTicks <= nowUtcTicks ||
                expiresUtcTicks > checked(nowUtcTicks + TimeSpan.FromSeconds(15).Ticks) ||
                selectionClass != "synthetic_aec_owner_selected" ||
                selectedOwnerClass != WindowsVoiceCaptureDspOwnerClass)
            {
                throw new VoiceCaptureDspException(
                    "processed_pcm_pipe_lease_invalid");
            }
            if (identity == null)
            {
                throw new VoiceCaptureDspException(
                    "processed_pcm_pipe_lease_invalid");
            }
            long actualCreationUtcTicks;
            if (!identity.TryGetCreationUtcTicks(
                serverProcessId,
                out actualCreationUtcTicks) ||
                actualCreationUtcTicks != serverCreationUtcTicks)
            {
                throw new VoiceCaptureDspException(
                    "processed_pcm_pipe_server_identity_mismatch");
            }
            return new ProcessedPcmPipeLease(
                pipeName,
                nonce,
                serverProcessId,
                serverCreationUtcTicks,
                expiresUtcTicks);
        }

        public static Task<VoiceCaptureDspObservation> ObserveAsync(
            ProcessedPcmPipeLease pipeLease,
            int windowMs,
            int deadlineMs,
            CancellationToken cancellationToken)
        {
            return ObserveWithBackendAsync(
                new WindowsVoiceCaptureDspBackend(),
                new NamedPipePcmSink(pipeLease, deadlineMs),
                pipeLease,
                new ServerProcessIdentity(),
                () => DateTime.UtcNow.Ticks,
                windowMs,
                deadlineMs,
                cancellationToken);
        }

        internal static async Task<VoiceCaptureDspObservation>
            ObserveWithBackendAsync(
                IVoiceCaptureDspBackend backend,
                ITransientPcmSink sink,
                ProcessedPcmPipeLease pipeLease,
                IServerProcessIdentity identity,
                Func<long> utcNowTicks,
                int windowMs,
                int deadlineMs,
                CancellationToken cancellationToken)
        {
            if (backend == null || sink == null)
            {
                DisposeAfterValidationFailure(backend, sink);
                throw new VoiceCaptureDspException("live_aec_backend_or_sink_missing");
            }
            if (pipeLease == null)
            {
                DisposeAfterValidationFailure(backend, sink);
                throw new VoiceCaptureDspException("processed_pcm_pipe_lease_missing");
            }
            if (windowMs < 100 || windowMs > 5000 ||
                deadlineMs < windowMs + 200 || deadlineMs > 10000)
            {
                DisposeAfterValidationFailure(backend, sink);
                throw new VoiceCaptureDspException("live_aec_bounds_invalid");
            }

            int packetCount = 0;
            long processedByteCount = 0;
            int cancelCount = 0;
            bool started = false;
            bool cleanupFailed = false;
            string failureClass = null;

            using (CancellationTokenSource linked =
                CancellationTokenSource.CreateLinkedTokenSource(cancellationToken))
            {
                linked.CancelAfter(deadlineMs);
                try
                {
                    RevalidatePipeLease(pipeLease, identity, utcNowTicks());
                    await sink.ConnectAsync(linked.Token).ConfigureAwait(false);
                    RevalidatePipeLease(pipeLease, identity, utcNowTicks());
                    await backend.ActivateAsync(linked.Token).ConfigureAwait(false);
                    backend.Start();
                    started = true;

                    Stopwatch window = Stopwatch.StartNew();
                    while (window.ElapsedMilliseconds < windowMs)
                    {
                        linked.Token.ThrowIfCancellationRequested();
                        byte[] processedPcm;
                        if (!backend.TryReadProcessedPcm(out processedPcm))
                        {
                            await Task.Delay(10, linked.Token).ConfigureAwait(false);
                            continue;
                        }
                        if (processedPcm == null ||
                            processedPcm.Length != FrameBytes ||
                            processedPcm.Length % (BitsPerSample / 8) != 0)
                        {
                            try
                            {
                                throw new VoiceCaptureDspException(
                                    "live_aec_processed_packet_invalid");
                            }
                            finally
                            {
                                if (processedPcm != null)
                                {
                                    Array.Clear(
                                        processedPcm,
                                        0,
                                        processedPcm.Length);
                                }
                            }
                        }
                        try
                        {
                            linked.Token.ThrowIfCancellationRequested();
                            await sink.WriteAsync(
                                processedPcm,
                                linked.Token).ConfigureAwait(false);
                            packetCount += 1;
                            processedByteCount += processedPcm.Length;
                        }
                        finally
                        {
                            Array.Clear(processedPcm, 0, processedPcm.Length);
                        }
                    }
                }
                catch (OperationCanceledException)
                {
                    cancelCount = 1;
                    failureClass = "live_aec_deadline_exceeded";
                }
                catch (VoiceCaptureDspException exception)
                {
                    failureClass = exception.FailureClass;
                }
                catch
                {
                    failureClass = "live_aec_observer_failed";
                }
                finally
                {
                    if (started)
                    {
                        try
                        {
                            backend.Stop();
                        }
                        catch
                        {
                            cleanupFailed = true;
                        }
                    }
                    try
                    {
                        sink.Dispose();
                    }
                    catch
                    {
                        cleanupFailed = true;
                    }
                    try
                    {
                        backend.Dispose();
                    }
                    catch
                    {
                        cleanupFailed = true;
                    }
                }
            }

            if (cleanupFailed)
            {
                throw new VoiceCaptureDspException("live_aec_cleanup_failed");
            }
            if (failureClass == null &&
                (backend.ActivateCount != 1 ||
                 backend.CaptureStartCount != 1 ||
                 backend.CaptureStopAttemptCount != 1 ||
                 backend.CaptureStopCount != 1 ||
                 backend.ResourceReleaseCount != 1 ||
                 sink.ConnectCount != 1 ||
                 sink.WriteCount != packetCount ||
                 sink.ReleaseCount != 1))
            {
                throw new VoiceCaptureDspException(
                    "live_aec_lifecycle_invariant_failed");
            }
            if (failureClass != null)
            {
                throw new VoiceCaptureDspException(failureClass);
            }

            return new VoiceCaptureDspObservation
            {
                ResultClass = packetCount > 0
                    ? "processed_near_end_pcm_observed"
                    : "processed_near_end_silence_observed",
                OwnerClass = WindowsVoiceCaptureDspOwnerClass,
                SourceClass = "windows_voice_capture_dsp_source_mode",
                WindowMs = windowMs,
                PacketCount = packetCount,
                ProcessedByteCount = processedByteCount,
                BackendActivateCount = backend.ActivateCount,
                CaptureStartCount = backend.CaptureStartCount,
                CaptureStopAttemptCount = backend.CaptureStopAttemptCount,
                CaptureStopCount = backend.CaptureStopCount,
                BackendResourceReleaseCount = backend.ResourceReleaseCount,
                SinkConnectCount = sink.ConnectCount,
                SinkWriteCount = sink.WriteCount,
                SinkReleaseCount = sink.ReleaseCount,
                CancelCount = cancelCount,
                RenderReferencePublished = false,
                RawAudioPersisted = false,
                TurnInputAuthority = false
            };
        }

        private static VoiceCaptureDspCapability Capability(string capabilityClass)
        {
            return new VoiceCaptureDspCapability
            {
                CapabilityClass = capabilityClass,
                PlatformClass = "windows_desktop",
                ComClass = capabilityClass == "voice_capture_dsp_capability_available"
                    ? "cwmaudioaec_available"
                    : "cwmaudioaec_unavailable",
                OwnerClass = WindowsVoiceCaptureDspOwnerClass
            };
        }

        private static void RevalidatePipeLease(
            ProcessedPcmPipeLease lease,
            IServerProcessIdentity identity,
            long nowUtcTicks)
        {
            if (identity == null || nowUtcTicks >= lease.ExpiresUtcTicks)
            {
                throw new VoiceCaptureDspException(
                    "processed_pcm_pipe_lease_expired");
            }
            long currentCreationUtcTicks;
            if (!identity.TryGetCreationUtcTicks(
                lease.ServerProcessId,
                out currentCreationUtcTicks) ||
                currentCreationUtcTicks != lease.ServerCreationUtcTicks)
            {
                throw new VoiceCaptureDspException(
                    "processed_pcm_pipe_server_identity_mismatch");
            }
        }

        internal static void ValidateConnectedServer(
            ProcessedPcmPipeLease lease,
            int actualServerProcessId,
            IServerProcessIdentity identity,
            long nowUtcTicks)
        {
            RevalidatePipeLease(lease, identity, nowUtcTicks);
            if (actualServerProcessId != lease.ServerProcessId)
            {
                throw new VoiceCaptureDspException(
                    "processed_pcm_pipe_server_identity_mismatch");
            }
        }

        private static void DisposeAfterValidationFailure(
            IVoiceCaptureDspBackend backend,
            ITransientPcmSink sink)
        {
            bool failed = false;
            try
            {
                if (sink != null) sink.Dispose();
            }
            catch
            {
                failed = true;
            }
            try
            {
                if (backend != null) backend.Dispose();
            }
            catch
            {
                failed = true;
            }
            if (failed)
            {
                throw new VoiceCaptureDspException("live_aec_cleanup_failed");
            }
        }

        internal static void ThrowIfFailed(int hresult, string failureClass)
        {
            if (hresult < 0)
            {
                throw new VoiceCaptureDspException(failureClass);
            }
        }

        internal static void ReleaseComObject(object value)
        {
            if (value != null && Marshal.IsComObject(value))
            {
                Marshal.FinalReleaseComObject(value);
            }
        }
    }

    public sealed class NamedPipePcmSink : ITransientPcmSink
    {
        private readonly ProcessedPcmPipeLease _lease;
        private readonly int _connectTimeoutMs;
        private readonly IServerProcessIdentity _identity;
        private readonly Func<long> _utcNowTicks;
        private NamedPipeClientStream _stream;
        private int _disposed;
        private int _streamClosed;

        public NamedPipePcmSink(
            ProcessedPcmPipeLease lease,
            int connectTimeoutMs)
            : this(
                lease,
                connectTimeoutMs,
                new ServerProcessIdentity(),
                () => DateTime.UtcNow.Ticks)
        {
        }

        internal NamedPipePcmSink(
            ProcessedPcmPipeLease lease,
            int connectTimeoutMs,
            IServerProcessIdentity identity,
            Func<long> utcNowTicks)
        {
            _lease = lease;
            _connectTimeoutMs = connectTimeoutMs;
            _identity = identity;
            _utcNowTicks = utcNowTicks;
        }

        public int ConnectCount { get; private set; }
        public int WriteCount { get; private set; }
        public int ReleaseCount { get; private set; }

        public async Task ConnectAsync(CancellationToken cancellationToken)
        {
            if (_lease == null || _stream != null ||
                Interlocked.CompareExchange(ref _disposed, 0, 0) != 0)
            {
                throw new VoiceCaptureDspException(
                    "processed_pcm_pipe_connect_failed");
            }
            _stream = new NamedPipeClientStream(
                ".",
                _lease.PipeName,
                PipeDirection.InOut,
                PipeOptions.Asynchronous,
                TokenImpersonationLevel.Identification);
            using (CancellationTokenSource bounded =
                CancellationTokenSource.CreateLinkedTokenSource(cancellationToken))
            {
                bounded.CancelAfter(_connectTimeoutMs);
                try
                {
                    await _stream.ConnectAsync(bounded.Token).ConfigureAwait(false);
                }
                catch (OperationCanceledException)
                {
                    throw new VoiceCaptureDspException(
                        "processed_pcm_pipe_connect_timeout");
                }
                catch
                {
                    throw new VoiceCaptureDspException(
                        "processed_pcm_pipe_connect_failed");
                }
                uint actualServerProcessId;
                if (!NativeMethods.GetNamedPipeServerProcessId(
                    _stream.SafePipeHandle,
                    out actualServerProcessId))
                {
                    throw new VoiceCaptureDspException(
                        "processed_pcm_pipe_server_identity_mismatch");
                }
                VoiceCaptureDspAec.ValidateConnectedServer(
                    _lease,
                    checked((int)actualServerProcessId),
                    _identity,
                    _utcNowTicks());
                await PerformHandshakeAsync(bounded.Token).ConfigureAwait(false);
            }
            ConnectCount += 1;
        }

        private async Task PerformHandshakeAsync(
            CancellationToken cancellationToken)
        {
            byte[] nonce = new byte[32];
            byte[] acknowledgement = new byte[1];
            try
            {
                for (int index = 0; index < nonce.Length; index += 1)
                {
                    nonce[index] = Convert.ToByte(
                        _lease.Nonce.Substring(index * 2, 2),
                        16);
                }
                await _stream.WriteAsync(
                    nonce,
                    0,
                    nonce.Length,
                    cancellationToken).ConfigureAwait(false);
                await _stream.FlushAsync(cancellationToken).ConfigureAwait(false);
                int received = await _stream.ReadAsync(
                    acknowledgement,
                    0,
                    1,
                    cancellationToken).ConfigureAwait(false);
                if (received != 1 || acknowledgement[0] != 0xA1)
                {
                    throw new VoiceCaptureDspException(
                        "processed_pcm_pipe_handshake_failed");
                }
            }
            catch (VoiceCaptureDspException)
            {
                throw;
            }
            catch
            {
                throw new VoiceCaptureDspException(
                    "processed_pcm_pipe_handshake_failed");
            }
            finally
            {
                Array.Clear(nonce, 0, nonce.Length);
                Array.Clear(acknowledgement, 0, acknowledgement.Length);
            }
        }

        public async Task WriteAsync(
            byte[] processedPcm,
            CancellationToken cancellationToken)
        {
            NamedPipeClientStream stream = _stream;
            if (stream == null || !stream.IsConnected ||
                Interlocked.CompareExchange(ref _disposed, 0, 0) != 0 ||
                processedPcm == null || processedPcm.Length == 0 ||
                processedPcm.Length != VoiceCaptureDspAec.FrameBytes ||
                processedPcm.Length % (VoiceCaptureDspAec.BitsPerSample / 8) != 0)
            {
                throw new VoiceCaptureDspException(
                    "processed_pcm_pipe_write_failed");
            }
            byte[] lengthPrefix = BitConverter.GetBytes(processedPcm.Length);
            using (cancellationToken.Register(CloseStreamOnce))
            {
                try
                {
                    cancellationToken.ThrowIfCancellationRequested();
                    await stream.WriteAsync(
                        lengthPrefix,
                        0,
                        lengthPrefix.Length,
                        cancellationToken).ConfigureAwait(false);
                    await stream.WriteAsync(
                        processedPcm,
                        0,
                        processedPcm.Length,
                        cancellationToken).ConfigureAwait(false);
                    await stream.FlushAsync(cancellationToken).ConfigureAwait(false);
                    cancellationToken.ThrowIfCancellationRequested();
                    WriteCount += 1;
                }
                catch (OperationCanceledException)
                {
                    CloseStreamOnce();
                    throw;
                }
                catch
                {
                    if (cancellationToken.IsCancellationRequested)
                    {
                        CloseStreamOnce();
                        throw new OperationCanceledException(cancellationToken);
                    }
                    throw new VoiceCaptureDspException(
                        "processed_pcm_pipe_write_failed");
                }
                finally
                {
                    Array.Clear(lengthPrefix, 0, lengthPrefix.Length);
                }
            }
        }

        public void Dispose()
        {
            if (Interlocked.Exchange(ref _disposed, 1) != 0) return;
            try
            {
                CloseStreamOnce();
            }
            finally
            {
                _stream = null;
                ReleaseCount += 1;
            }
        }

        private void CloseStreamOnce()
        {
            if (Interlocked.Exchange(ref _streamClosed, 1) != 0) return;
            NamedPipeClientStream stream = _stream;
            if (stream != null) stream.Dispose();
        }
    }

    public sealed class WindowsVoiceCaptureDspBackend : IVoiceCaptureDspBackend
    {
        private object _dspObject;
        private IMediaObject _mediaObject;
        private ManagedMediaBuffer _outputBuffer;
        private bool _started;
        private bool _stopAttempted;
        private bool _disposed;

        public int ActivateCount { get; private set; }
        public int CaptureStartCount { get; private set; }
        public int CaptureStopAttemptCount { get; private set; }
        public int CaptureStopCount { get; private set; }
        public int ResourceReleaseCount { get; private set; }

        public Task ActivateAsync(CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (_dspObject != null || _disposed)
            {
                throw new VoiceCaptureDspException(
                    "voice_capture_dsp_activation_failed");
            }
            try
            {
                Type type = Type.GetTypeFromCLSID(
                    new Guid(VoiceCaptureDspAec.VoiceCaptureDspClsid),
                    true);
                _dspObject = Activator.CreateInstance(type);
                _mediaObject = (IMediaObject)_dspObject;
                IPropertyStore properties = (IPropertyStore)_dspObject;
                ConfigureProperties(properties);
                ConfigureOutputType(_mediaObject);
                ActivateCount += 1;
                return Task.CompletedTask;
            }
            catch (VoiceCaptureDspException)
            {
                throw;
            }
            catch
            {
                throw new VoiceCaptureDspException(
                    "voice_capture_dsp_activation_failed");
            }
        }

        public void Start()
        {
            if (_mediaObject == null || _started || _disposed)
            {
                throw new VoiceCaptureDspException(
                    "voice_capture_dsp_start_failed");
            }
            VoiceCaptureDspAec.ThrowIfFailed(
                _mediaObject.AllocateStreamingResources(),
                "voice_capture_dsp_start_failed");
            _outputBuffer = new ManagedMediaBuffer(
                VoiceCaptureDspAec.FrameBytes);
            _started = true;
            CaptureStartCount += 1;
        }

        public bool TryReadProcessedPcm(out byte[] processedPcm)
        {
            processedPcm = null;
            if (!_started || _mediaObject == null || _outputBuffer == null)
            {
                throw new VoiceCaptureDspException(
                    "voice_capture_dsp_not_started");
            }
            _outputBuffer.SetLength(0);
            DmoOutputDataBuffer[] output = new DmoOutputDataBuffer[1];
            output[0] = new DmoOutputDataBuffer
            {
                Buffer = _outputBuffer,
                Status = 0,
                Timestamp = 0,
                Timelength = 0
            };
            uint status;
            int result;
            try
            {
                result = _mediaObject.ProcessOutput(0, 1, output, out status);
            }
            catch
            {
                _outputBuffer.ClearCurrent();
                throw new VoiceCaptureDspException(
                    "voice_capture_dsp_process_output_failed");
            }
            if (result < 0)
            {
                _outputBuffer.ClearCurrent();
                throw new VoiceCaptureDspException(
                    "voice_capture_dsp_process_output_failed");
            }
            int length = _outputBuffer.CurrentLength;
            if (length <= 0)
            {
                return false;
            }
            processedPcm = _outputBuffer.CopyCurrentBytes();
            return true;
        }

        public void Stop()
        {
            CaptureStopAttemptCount += 1;
            _stopAttempted = true;
            if (!_started || _mediaObject == null)
            {
                throw new VoiceCaptureDspException(
                    "voice_capture_dsp_stop_failed");
            }
            int flush = _mediaObject.Flush();
            int free = _mediaObject.FreeStreamingResources();
            VoiceCaptureDspAec.ThrowIfFailed(
                flush < 0 ? flush : free,
                "voice_capture_dsp_stop_failed");
            _started = false;
            CaptureStopCount += 1;
        }

        public void Dispose()
        {
            if (_disposed) return;
            _disposed = true;
            try
            {
                if (_started && !_stopAttempted)
                {
                    Stop();
                }
            }
            finally
            {
                if (_outputBuffer != null) _outputBuffer.Dispose();
                _outputBuffer = null;
                _mediaObject = null;
                VoiceCaptureDspAec.ReleaseComObject(_dspObject);
                _dspObject = null;
                ResourceReleaseCount += 1;
            }
        }

        private static void ConfigureProperties(IPropertyStore properties)
        {
            SetIntProperty(
                properties,
                VoiceCaptureDspAec.PidSystemMode,
                VoiceCaptureDspAec.SingleChannelAec);
            SetBoolProperty(properties, VoiceCaptureDspAec.PidSourceMode, true);
            SetBoolProperty(properties, VoiceCaptureDspAec.PidFeatureMode, true);
            SetIntProperty(
                properties,
                VoiceCaptureDspAec.PidNoiseSuppression,
                1);
            SetBoolProperty(
                properties,
                VoiceCaptureDspAec.PidAutomaticGainControl,
                true);
        }

        private static void SetIntProperty(
            IPropertyStore properties,
            int propertyId,
            int value)
        {
            PropertyKey key = PropertyKey.Create(propertyId);
            PropVariant variant = PropVariant.FromInt(value);
            VoiceCaptureDspAec.ThrowIfFailed(
                properties.SetValue(ref key, ref variant),
                "voice_capture_dsp_configuration_failed");
        }

        private static void SetBoolProperty(
            IPropertyStore properties,
            int propertyId,
            bool value)
        {
            PropertyKey key = PropertyKey.Create(propertyId);
            PropVariant variant = PropVariant.FromBool(value);
            VoiceCaptureDspAec.ThrowIfFailed(
                properties.SetValue(ref key, ref variant),
                "voice_capture_dsp_configuration_failed");
        }

        private static void ConfigureOutputType(IMediaObject mediaObject)
        {
            WaveFormatEx format = new WaveFormatEx
            {
                FormatTag = 1,
                Channels = VoiceCaptureDspAec.ChannelCount,
                SamplesPerSecond = VoiceCaptureDspAec.SampleRate,
                AverageBytesPerSecond = VoiceCaptureDspAec.SampleRate * 2,
                BlockAlign = 2,
                BitsPerSample = VoiceCaptureDspAec.BitsPerSample,
                ExtraSize = 0
            };
            IntPtr formatPointer = Marshal.AllocHGlobal(
                Marshal.SizeOf(typeof(WaveFormatEx)));
            try
            {
                Marshal.StructureToPtr(format, formatPointer, false);
                DmoMediaType mediaType = new DmoMediaType
                {
                    MajorType = new Guid("73647561-0000-0010-8000-00aa00389b71"),
                    SubType = new Guid("00000001-0000-0010-8000-00aa00389b71"),
                    FixedSizeSamples = true,
                    TemporalCompression = false,
                    SampleSize = 0,
                    FormatType = new Guid("05589f81-c356-11ce-bf01-00aa0055595a"),
                    Unknown = IntPtr.Zero,
                    FormatSize = (uint)Marshal.SizeOf(typeof(WaveFormatEx)),
                    Format = formatPointer
                };
                VoiceCaptureDspAec.ThrowIfFailed(
                    mediaObject.SetOutputType(0, ref mediaType, 0),
                    "voice_capture_dsp_output_format_failed");
            }
            finally
            {
                Marshal.FreeHGlobal(formatPointer);
            }
        }
    }

    [ComVisible(true)]
    [ClassInterface(ClassInterfaceType.None)]
    internal sealed class ManagedMediaBuffer : IMediaBuffer, IDisposable
    {
        private readonly byte[] _bytes;
        private GCHandle _handle;
        private bool _disposed;

        internal ManagedMediaBuffer(int capacity)
        {
            _bytes = new byte[capacity];
            _handle = GCHandle.Alloc(_bytes, GCHandleType.Pinned);
        }

        internal int CurrentLength { get; private set; }

        public int SetLength(uint length)
        {
            if (length > _bytes.Length) return unchecked((int)0x80070057);
            CurrentLength = (int)length;
            return 0;
        }

        public int GetMaxLength(out uint maxLength)
        {
            maxLength = (uint)_bytes.Length;
            return 0;
        }

        public int GetBufferAndLength(out IntPtr buffer, out uint length)
        {
            buffer = _handle.AddrOfPinnedObject();
            length = (uint)CurrentLength;
            return 0;
        }

        internal byte[] CopyCurrentBytes()
        {
            int length = CurrentLength;
            byte[] result = null;
            try
            {
                result = new byte[length];
                Buffer.BlockCopy(_bytes, 0, result, 0, length);
                return result;
            }
            finally
            {
                ClearCurrent();
            }
        }

        internal void ClearCurrent()
        {
            int length = CurrentLength;
            if (length > 0) Array.Clear(_bytes, 0, length);
            CurrentLength = 0;
        }

        internal bool IsCleared()
        {
            foreach (byte value in _bytes)
            {
                if (value != 0) return false;
            }
            return true;
        }

        public void Dispose()
        {
            if (_disposed) return;
            _disposed = true;
            Array.Clear(_bytes, 0, _bytes.Length);
            if (_handle.IsAllocated) _handle.Free();
        }
    }

    [ComImport]
    [Guid("d8ad0f58-5494-4102-97c5-ec798e59bcf4")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IMediaObject
    {
        [PreserveSig] int GetStreamCount(out uint inputs, out uint outputs);
        [PreserveSig] int GetInputStreamInfo(uint index, out uint flags);
        [PreserveSig] int GetOutputStreamInfo(uint index, out uint flags);
        [PreserveSig] int GetInputType(uint index, uint typeIndex, IntPtr mediaType);
        [PreserveSig] int GetOutputType(uint index, uint typeIndex, IntPtr mediaType);
        [PreserveSig] int SetInputType(uint index, IntPtr mediaType, uint flags);
        [PreserveSig] int SetOutputType(uint index, ref DmoMediaType mediaType, uint flags);
        [PreserveSig] int GetInputCurrentType(uint index, IntPtr mediaType);
        [PreserveSig] int GetOutputCurrentType(uint index, IntPtr mediaType);
        [PreserveSig] int GetInputSizeInfo(uint index, out uint size, out uint ahead, out uint alignment);
        [PreserveSig] int GetOutputSizeInfo(uint index, out uint size, out uint alignment);
        [PreserveSig] int GetInputMaxLatency(uint index, out long latency);
        [PreserveSig] int SetInputMaxLatency(uint index, long latency);
        [PreserveSig] int Flush();
        [PreserveSig] int Discontinuity(uint index);
        [PreserveSig] int AllocateStreamingResources();
        [PreserveSig] int FreeStreamingResources();
        [PreserveSig] int GetInputStatus(uint index, out uint flags);
        [PreserveSig] int ProcessInput(uint index, IMediaBuffer buffer, uint flags, long timestamp, long timelength);
        [PreserveSig] int ProcessOutput(uint flags, uint outputCount, [In, Out] DmoOutputDataBuffer[] output, out uint status);
        [PreserveSig] int Lock(int value);
    }

    [ComImport]
    [Guid("59eff8b9-938c-4a26-82f2-95cb84cdc837")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IMediaBuffer
    {
        [PreserveSig] int SetLength(uint length);
        [PreserveSig] int GetMaxLength(out uint maxLength);
        [PreserveSig] int GetBufferAndLength(out IntPtr buffer, out uint length);
    }

    [ComImport]
    [Guid("886d8eeb-8cf2-4446-8d02-cdba1dbdcf99")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IPropertyStore
    {
        [PreserveSig] int GetCount(out uint propertyCount);
        [PreserveSig] int GetAt(uint propertyIndex, out PropertyKey key);
        [PreserveSig] int GetValue(ref PropertyKey key, out PropVariant value);
        [PreserveSig] int SetValue(ref PropertyKey key, ref PropVariant value);
        [PreserveSig] int Commit();
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct DmoMediaType
    {
        internal Guid MajorType;
        internal Guid SubType;
        [MarshalAs(UnmanagedType.Bool)] internal bool FixedSizeSamples;
        [MarshalAs(UnmanagedType.Bool)] internal bool TemporalCompression;
        internal uint SampleSize;
        internal Guid FormatType;
        internal IntPtr Unknown;
        internal uint FormatSize;
        internal IntPtr Format;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct DmoOutputDataBuffer
    {
        [MarshalAs(UnmanagedType.Interface)] internal IMediaBuffer Buffer;
        internal uint Status;
        internal long Timestamp;
        internal long Timelength;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct PropertyKey
    {
        internal Guid FormatId;
        internal int PropertyId;

        internal static PropertyKey Create(int propertyId)
        {
            return new PropertyKey
            {
                FormatId = new Guid(VoiceCaptureDspAec.VoiceCapturePropertySet),
                PropertyId = propertyId
            };
        }
    }

    [StructLayout(LayoutKind.Explicit)]
    internal struct PropVariant
    {
        [FieldOffset(0)] internal ushort VariantType;
        [FieldOffset(8)] internal int IntValue;
        [FieldOffset(8)] internal short BoolValue;

        internal static PropVariant FromInt(int value)
        {
            return new PropVariant { VariantType = 3, IntValue = value };
        }

        internal static PropVariant FromBool(bool value)
        {
            return new PropVariant
            {
                VariantType = 11,
                BoolValue = value ? (short)-1 : (short)0
            };
        }
    }

    [StructLayout(LayoutKind.Sequential, Pack = 2)]
    internal struct WaveFormatEx
    {
        internal ushort FormatTag;
        internal ushort Channels;
        internal uint SamplesPerSecond;
        internal uint AverageBytesPerSecond;
        internal ushort BlockAlign;
        internal ushort BitsPerSample;
        internal ushort ExtraSize;
    }

    internal static class NativeMethods
    {
        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool GetNamedPipeServerProcessId(
            SafePipeHandle pipe,
            out uint serverProcessId);
    }
}
