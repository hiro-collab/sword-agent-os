using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;

namespace SwordAgentOS.AudioAwareness
{
    public sealed class ProcessLoopbackCapability
    {
        public string CapabilityClass { get; set; }
        public string BuildClass { get; set; }
        public string ApiClass { get; set; }
    }

    public sealed class ProcessLoopbackPacket
    {
        public uint FrameCount { get; set; }
        public bool IsSilent { get; set; }
    }

    public sealed class ProcessLoopbackObservation
    {
        public string SourceClass { get; set; }
        public string ResultClass { get; set; }
        public string AttributionClass { get; set; }
        public int WindowMs { get; set; }
        public int PacketCount { get; set; }
        public long FrameCount { get; set; }
        public long NonSilentFrameCount { get; set; }
        public long SilentFrameCount { get; set; }
        public int CaptureStartCount { get; set; }
        public int CaptureStopAttemptCount { get; set; }
        public int CaptureStopCount { get; set; }
        public int BufferReleaseCount { get; set; }
        public int ResourceReleaseCount { get; set; }
        public int CancelCount { get; set; }
    }

    public sealed class ProcessLoopbackObserverException : Exception
    {
        public ProcessLoopbackObserverException(string failureClass)
            : base(failureClass)
        {
            FailureClass = failureClass;
        }

        public string FailureClass { get; private set; }
    }

    public interface IProcessLoopbackBackend : IDisposable
    {
        int CaptureStartCount { get; }
        int CaptureStopAttemptCount { get; }
        int CaptureStopCount { get; }
        int BufferReleaseCount { get; }
        int ResourceReleaseCount { get; }
        Task ActivateAsync(int targetProcessId, CancellationToken cancellationToken);
        void Start();
        ProcessLoopbackPacket ReadPacket();
        void Stop();
    }

    public sealed class ProcessRenderLease
    {
        internal ProcessRenderLease(
            int targetProcessId,
            long creationUtcTicks,
            long expiresUtcTicks)
        {
            TargetProcessId = targetProcessId;
            CreationUtcTicks = creationUtcTicks;
            ExpiresUtcTicks = expiresUtcTicks;
        }

        internal int TargetProcessId { get; private set; }
        internal long CreationUtcTicks { get; private set; }
        internal long ExpiresUtcTicks { get; private set; }
    }

    internal interface IProcessIdentityProvider
    {
        bool TryGetCreationUtcTicks(int processId, out long creationUtcTicks);
    }

    internal sealed class SystemProcessIdentityProvider : IProcessIdentityProvider
    {
        public bool TryGetCreationUtcTicks(int processId, out long creationUtcTicks)
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

    public static class ProcessLoopbackObserver
    {
        internal const int MinimumProcessLoopbackBuild = 20348;

        public static ProcessLoopbackCapability GetCapability()
        {
            if (!RuntimeInformation.IsOSPlatform(OSPlatform.Windows))
            {
                return new ProcessLoopbackCapability
                {
                    CapabilityClass = "unsupported_platform",
                    BuildClass = "unsupported_platform",
                    ApiClass = "unavailable"
                };
            }

            string buildClass = Environment.OSVersion.Version.Build >= MinimumProcessLoopbackBuild
                ? "process_loopback_build_floor_met"
                : "process_loopback_build_floor_not_met";
            bool apiAvailable = false;
            IntPtr libraryHandle = IntPtr.Zero;
            try
            {
                if (NativeLibrary.TryLoad("Mmdevapi.dll", out libraryHandle))
                {
                    IntPtr exportAddress;
                    apiAvailable = NativeLibrary.TryGetExport(
                        libraryHandle,
                        "ActivateAudioInterfaceAsync",
                        out exportAddress);
                }
            }
            finally
            {
                if (libraryHandle != IntPtr.Zero)
                {
                    NativeLibrary.Free(libraryHandle);
                }
            }

            string apiClass = apiAvailable ? "available" : "unavailable";
            return new ProcessLoopbackCapability
            {
                CapabilityClass = buildClass == "process_loopback_build_floor_met" && apiAvailable
                    ? "process_loopback_capability_available"
                    : "process_loopback_capability_unavailable",
                BuildClass = buildClass,
                ApiClass = apiClass
            };
        }

        public static ProcessRenderLease AcquireProcessLease(
            int targetProcessId,
            int ttlMs)
        {
            return AcquireProcessLease(
                new SystemProcessIdentityProvider(),
                targetProcessId,
                ttlMs,
                DateTime.UtcNow.Ticks);
        }

        internal static ProcessRenderLease AcquireProcessLease(
            IProcessIdentityProvider identityProvider,
            int targetProcessId,
            int ttlMs,
            long nowUtcTicks)
        {
            if (targetProcessId <= 0)
            {
                throw new ProcessLoopbackObserverException(
                    "target_process_lease_missing");
            }
            if (identityProvider == null || ttlMs < 250 || ttlMs > 15000)
            {
                throw new ProcessLoopbackObserverException(
                    "target_process_lease_invalid");
            }
            long creationUtcTicks;
            if (!identityProvider.TryGetCreationUtcTicks(
                targetProcessId,
                out creationUtcTicks))
            {
                throw new ProcessLoopbackObserverException(
                    "target_process_lease_exited");
            }
            return new ProcessRenderLease(
                targetProcessId,
                creationUtcTicks,
                checked(nowUtcTicks + TimeSpan.FromMilliseconds(ttlMs).Ticks));
        }

        public static Task<ProcessLoopbackObservation> ObserveAsync(
            ProcessRenderLease lease,
            int windowMs,
            int deadlineMs,
            CancellationToken cancellationToken)
        {
            return ObserveWithBackendAsync(
                new WasapiProcessLoopbackBackend(),
                lease,
                new SystemProcessIdentityProvider(),
                () => DateTime.UtcNow.Ticks,
                windowMs,
                deadlineMs,
                cancellationToken);
        }

        internal static async Task<ProcessLoopbackObservation> ObserveWithBackendAsync(
            IProcessLoopbackBackend backend,
            ProcessRenderLease lease,
            IProcessIdentityProvider identityProvider,
            Func<long> utcNowTicks,
            int windowMs,
            int deadlineMs,
            CancellationToken cancellationToken)
        {
            if (backend == null)
            {
                throw new ProcessLoopbackObserverException("backend_missing");
            }
            if (lease == null)
            {
                DisposeAfterValidationFailure(backend);
                throw new ProcessLoopbackObserverException("target_process_lease_missing");
            }
            if (windowMs < 100 || windowMs > 5000 ||
                deadlineMs < windowMs + 200 || deadlineMs > 10000)
            {
                DisposeAfterValidationFailure(backend);
                throw new ProcessLoopbackObserverException("observation_bounds_invalid");
            }

            int packetCount = 0;
            long frameCount = 0;
            long nonSilentFrameCount = 0;
            long silentFrameCount = 0;
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
                    RevalidateProcessLease(lease, identityProvider, utcNowTicks());
                    await backend.ActivateAsync(lease.TargetProcessId, linked.Token)
                        .ConfigureAwait(false);
                    backend.Start();
                    started = true;

                    Stopwatch window = Stopwatch.StartNew();
                    while (window.ElapsedMilliseconds < windowMs)
                    {
                        linked.Token.ThrowIfCancellationRequested();
                        ProcessLoopbackPacket packet = backend.ReadPacket();
                        if (packet == null)
                        {
                            await Task.Delay(10, linked.Token).ConfigureAwait(false);
                            continue;
                        }

                        packetCount += 1;
                        frameCount += packet.FrameCount;
                        if (packet.IsSilent)
                        {
                            silentFrameCount += packet.FrameCount;
                        }
                        else
                        {
                            nonSilentFrameCount += packet.FrameCount;
                        }
                    }
                }
                catch (OperationCanceledException)
                {
                    cancelCount = 1;
                    failureClass = "observation_deadline_exceeded";
                }
                catch (ProcessLoopbackObserverException exception)
                {
                    failureClass = exception.FailureClass;
                }
                catch
                {
                    failureClass = "process_loopback_observer_failed";
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
                throw new ProcessLoopbackObserverException("process_loopback_cleanup_failed");
            }
            if (failureClass == null &&
                (backend.CaptureStartCount != 1 ||
                 backend.CaptureStopAttemptCount != 1 ||
                 backend.CaptureStopCount != 1 ||
                 backend.BufferReleaseCount != packetCount ||
                 backend.ResourceReleaseCount < 1))
            {
                throw new ProcessLoopbackObserverException(
                    "process_loopback_lifecycle_invariant_failed");
            }
            if (failureClass != null)
            {
                throw new ProcessLoopbackObserverException(failureClass);
            }

            return new ProcessLoopbackObservation
            {
                SourceClass = "live_process_loopback",
                ResultClass = nonSilentFrameCount > 0
                    ? "process_tree_render_observed"
                    : "process_tree_silence_observed",
                AttributionClass = "target_process_tree_included",
                WindowMs = windowMs,
                PacketCount = packetCount,
                FrameCount = frameCount,
                NonSilentFrameCount = nonSilentFrameCount,
                SilentFrameCount = silentFrameCount,
                CaptureStartCount = backend.CaptureStartCount,
                CaptureStopAttemptCount = backend.CaptureStopAttemptCount,
                CaptureStopCount = backend.CaptureStopCount,
                BufferReleaseCount = backend.BufferReleaseCount,
                ResourceReleaseCount = backend.ResourceReleaseCount,
                CancelCount = cancelCount
            };
        }

        public static ProcessLoopbackObservation CreateSyntheticFixture(bool renderObserved)
        {
            return new ProcessLoopbackObservation
            {
                SourceClass = "synthetic_fixture",
                ResultClass = renderObserved
                    ? "synthetic_process_tree_render_fixture"
                    : "synthetic_process_tree_silence_fixture",
                AttributionClass = "synthetic_target_process_tree",
                WindowMs = 250,
                PacketCount = 1,
                FrameCount = 256,
                NonSilentFrameCount = renderObserved ? 256 : 0,
                SilentFrameCount = renderObserved ? 0 : 256,
                CaptureStartCount = 0,
                CaptureStopAttemptCount = 0,
                CaptureStopCount = 0,
                BufferReleaseCount = 0,
                ResourceReleaseCount = 0,
                CancelCount = 0
            };
        }

        private static void DisposeAfterValidationFailure(
            IProcessLoopbackBackend backend)
        {
            try
            {
                backend.Dispose();
            }
            catch
            {
                throw new ProcessLoopbackObserverException(
                    "process_loopback_cleanup_failed");
            }
        }

        private static void RevalidateProcessLease(
            ProcessRenderLease lease,
            IProcessIdentityProvider identityProvider,
            long nowUtcTicks)
        {
            if (identityProvider == null)
            {
                throw new ProcessLoopbackObserverException(
                    "target_process_lease_invalid");
            }
            if (nowUtcTicks > lease.ExpiresUtcTicks)
            {
                throw new ProcessLoopbackObserverException(
                    "target_process_lease_expired");
            }
            long currentCreationUtcTicks;
            if (!identityProvider.TryGetCreationUtcTicks(
                lease.TargetProcessId,
                out currentCreationUtcTicks))
            {
                throw new ProcessLoopbackObserverException(
                    "target_process_lease_exited");
            }
            if (currentCreationUtcTicks != lease.CreationUtcTicks)
            {
                throw new ProcessLoopbackObserverException(
                    "target_process_lease_identity_mismatch");
            }
        }
    }

    internal sealed class WasapiProcessLoopbackBackend : IProcessLoopbackBackend
    {
        internal const string VirtualAudioDeviceProcessLoopback = @"VAD\Process_Loopback";
        internal const ushort VtBlob = 65;
        internal const int ActivationTypeProcessLoopback = 1;
        internal const int IncludeTargetProcessTree = 0;
        private const uint AudclntStreamflagsLoopback = 0x00020000;
        private const uint AudclntStreamflagsAutoconvertPcm = 0x80000000;
        private const uint AudclntStreamflagsSrcDefaultQuality = 0x08000000;
        private const uint AudclntBufferflagsSilent = 0x00000002;

        private IAudioClient _audioClient;
        private IAudioCaptureClient _captureClient;
        private ICaptureBufferSource _captureBufferSource;
        private bool _started;
        private bool _stopAttempted;
        private bool _disposed;

        public int CaptureStartCount { get; private set; }
        public int CaptureStopAttemptCount { get; private set; }
        public int CaptureStopCount { get; private set; }
        public int BufferReleaseCount { get; private set; }
        public int ResourceReleaseCount { get; private set; }

        public async Task ActivateAsync(
            int targetProcessId,
            CancellationToken cancellationToken)
        {
            IntPtr activationBlob = IntPtr.Zero;
            IActivateAudioInterfaceAsyncOperation operation = null;
            ActivationHandler handler = new ActivationHandler();
            try
            {
                PropVariant variant = BuildActivationVariant(
                    targetProcessId,
                    out activationBlob);
                Guid audioClientGuid = typeof(IAudioClient).GUID;
                int hr = NativeMethods.ActivateAudioInterfaceAsync(
                    VirtualAudioDeviceProcessLoopback,
                    ref audioClientGuid,
                    ref variant,
                    handler,
                    out operation);
                ThrowIfFailed(hr, "process_loopback_activation_start_failed");

                Task cancellationTask = Task.Delay(Timeout.Infinite, cancellationToken);
                Task completed = await Task.WhenAny(handler.WaitTask, cancellationTask)
                    .ConfigureAwait(false);
                if (completed != handler.WaitTask)
                {
                    handler.Abandon();
                    cancellationToken.ThrowIfCancellationRequested();
                }
                await handler.WaitTask.ConfigureAwait(false);
                _audioClient = handler.ClaimClient();
                InitializeCaptureClient();
                GC.KeepAlive(operation);
            }
            finally
            {
                if (activationBlob != IntPtr.Zero)
                {
                    Marshal.FreeHGlobal(activationBlob);
                }
                ReleaseOwnedComObject(operation);
            }
        }

        internal static PropVariant BuildActivationVariant(
            int targetProcessId,
            out IntPtr activationBlob)
        {
            AudioClientActivationParams activation =
                new AudioClientActivationParams
                {
                    ActivationType = ActivationTypeProcessLoopback,
                    ProcessLoopbackParams = new AudioClientProcessLoopbackParams
                    {
                        TargetProcessId = unchecked((uint)targetProcessId),
                        ProcessLoopbackMode = IncludeTargetProcessTree
                    }
                };
            activationBlob = Marshal.AllocHGlobal(
                Marshal.SizeOf(typeof(AudioClientActivationParams)));
            Marshal.StructureToPtr(activation, activationBlob, false);
            return new PropVariant
            {
                VariantType = VtBlob,
                Blob = new Blob
                {
                    Size = Marshal.SizeOf(typeof(AudioClientActivationParams)),
                    Data = activationBlob
                }
            };
        }

        public void Start()
        {
            EnsureNotDisposed();
            ThrowIfFailed(_audioClient.Start(), "process_loopback_start_failed");
            _started = true;
            CaptureStartCount += 1;
        }

        public ProcessLoopbackPacket ReadPacket()
        {
            EnsureNotDisposed();
            return ReadPacketFromSource(
                _captureBufferSource,
                () => BufferReleaseCount += 1);
        }

        internal static ProcessLoopbackPacket ReadPacketFromSource(
            ICaptureBufferSource source,
            Action releaseObserved)
        {
            if (source == null)
            {
                throw new ProcessLoopbackObserverException(
                    "process_loopback_not_initialized");
            }
            uint nextPacketFrames;
            ThrowIfFailed(
                source.GetNextPacketSize(out nextPacketFrames),
                "process_loopback_packet_query_failed");
            if (nextPacketFrames == 0)
            {
                return null;
            }

            IntPtr data;
            uint frameCount;
            uint flags;
            ulong devicePosition;
            ulong qpcPosition;
            ThrowIfFailed(
                source.GetBuffer(
                    out data,
                    out frameCount,
                    out flags,
                    out devicePosition,
                    out qpcPosition),
                "process_loopback_buffer_get_failed");
            try
            {
                return new ProcessLoopbackPacket
                {
                    FrameCount = frameCount,
                    IsSilent = (flags & AudclntBufferflagsSilent) != 0
                };
            }
            finally
            {
                ThrowIfFailed(
                    source.ReleaseBuffer(frameCount),
                    "process_loopback_buffer_release_failed");
                if (releaseObserved != null)
                {
                    releaseObserved();
                }
            }
        }

        public void Stop()
        {
            if (_disposed || !_started || _stopAttempted)
            {
                return;
            }
            _stopAttempted = true;
            CaptureStopAttemptCount += 1;
            ThrowIfFailed(_audioClient.Stop(), "process_loopback_stop_failed");
            _started = false;
            CaptureStopCount += 1;
        }

        public void Dispose()
        {
            if (_disposed)
            {
                return;
            }
            try
            {
                if (_started && !_stopAttempted)
                {
                    try
                    {
                        Stop();
                    }
                    catch
                    {
                        // The owning observer reports cleanup failure. COM
                        // release must still converge in this finalizer path.
                    }
                }
            }
            finally
            {
                ReleaseOwnedComObject(_captureClient);
                ReleaseOwnedComObject(_audioClient);
                _captureClient = null;
                _captureBufferSource = null;
                _audioClient = null;
                _started = false;
                _disposed = true;
            }
        }

        private void InitializeCaptureClient()
        {
            WaveFormatEx format = new WaveFormatEx
            {
                FormatTag = 1,
                Channels = 2,
                SamplesPerSecond = 44100,
                AverageBytesPerSecond = 176400,
                BlockAlign = 4,
                BitsPerSample = 16,
                ExtraSize = 0
            };
            IntPtr formatPointer = IntPtr.Zero;
            try
            {
                formatPointer = Marshal.AllocHGlobal(Marshal.SizeOf(typeof(WaveFormatEx)));
                Marshal.StructureToPtr(format, formatPointer, false);
                uint streamFlags = AudclntStreamflagsLoopback |
                    AudclntStreamflagsAutoconvertPcm |
                    AudclntStreamflagsSrcDefaultQuality;
                ThrowIfFailed(
                    _audioClient.Initialize(0, streamFlags, 0, 0, formatPointer, IntPtr.Zero),
                    "process_loopback_initialize_failed");
            }
            finally
            {
                if (formatPointer != IntPtr.Zero)
                {
                    Marshal.FreeHGlobal(formatPointer);
                }
            }

            object captureObject;
            Guid captureGuid = typeof(IAudioCaptureClient).GUID;
            ThrowIfFailed(
                _audioClient.GetService(ref captureGuid, out captureObject),
                "process_loopback_capture_service_failed");
            _captureClient = captureObject as IAudioCaptureClient;
            if (_captureClient == null)
            {
                ReleaseOwnedComObject(captureObject);
                throw new ProcessLoopbackObserverException(
                    "process_loopback_capture_service_failed");
            }
            _captureBufferSource = new ComCaptureBufferSource(_captureClient);
        }

        private void EnsureNotDisposed()
        {
            if (_disposed || _audioClient == null ||
                _captureClient == null || _captureBufferSource == null)
            {
                throw new ProcessLoopbackObserverException("process_loopback_not_initialized");
            }
        }

        private static void ThrowIfFailed(int hr, string failureClass)
        {
            if (hr < 0)
            {
                throw new ProcessLoopbackObserverException(failureClass);
            }
        }

        private void ReleaseOwnedComObject(object value)
        {
            if (value != null && Marshal.IsComObject(value))
            {
                Marshal.FinalReleaseComObject(value);
                ResourceReleaseCount += 1;
            }
        }
    }

    [ComVisible(true)]
    [ClassInterface(ClassInterfaceType.None)]
    internal sealed class ActivationHandler : IActivateAudioInterfaceCompletionHandler
    {
        private const int Pending = 0;
        private const int Available = 1;
        private const int Claimed = 2;
        private const int Abandoned = 3;
        private const int Failed = 4;

        private readonly TaskCompletionSource<bool> _completion =
            new TaskCompletionSource<bool>(
                TaskCreationOptions.RunContinuationsAsynchronously);
        private readonly Action<object> _releaseAction;
        private object _completedInterface;
        private string _failureClass;
        private int _state = Pending;

        internal ActivationHandler()
            : this(ReleaseComInterface)
        {
        }

        internal ActivationHandler(Action<object> releaseAction)
        {
            _releaseAction = releaseAction ?? ReleaseComInterface;
        }

        internal Task<bool> WaitTask { get { return _completion.Task; } }

        internal string FailureClass { get { return _failureClass; } }

        internal void Abandon()
        {
            while (true)
            {
                int state = Volatile.Read(ref _state);
                if (state == Pending)
                {
                    if (Interlocked.CompareExchange(
                        ref _state,
                        Abandoned,
                        Pending) == Pending)
                    {
                        _completion.TrySetResult(false);
                        return;
                    }
                    continue;
                }
                if (state == Available)
                {
                    if (Interlocked.CompareExchange(
                        ref _state,
                        Abandoned,
                        Available) == Available)
                    {
                        object value = Interlocked.Exchange(
                            ref _completedInterface,
                            null);
                        ReleaseValue(value);
                        _completion.TrySetResult(false);
                        return;
                    }
                    continue;
                }
                return;
            }
        }

        internal IAudioClient ClaimClient()
        {
            if (Interlocked.CompareExchange(
                ref _state,
                Claimed,
                Available) != Available)
            {
                throw new ProcessLoopbackObserverException(
                    _failureClass ?? "process_loopback_activation_abandoned");
            }
            object value = Interlocked.Exchange(ref _completedInterface, null);
            IAudioClient audioClient = value as IAudioClient;
            if (audioClient == null)
            {
                ReleaseValue(value);
                throw new ProcessLoopbackObserverException(
                    "process_loopback_activation_failed");
            }
            return audioClient;
        }

        internal void CompleteForTest(object activatedInterface, bool succeeded)
        {
            Complete(activatedInterface, succeeded);
        }

        public int ActivateCompleted(IActivateAudioInterfaceAsyncOperation operation)
        {
            try
            {
                int activationResult;
                object activatedInterface = null;
                int operationResult = operation.GetActivateResult(
                    out activationResult,
                    out activatedInterface);
                Complete(
                    activatedInterface,
                    operationResult >= 0 && activationResult >= 0);
            }
            catch
            {
                Complete(null, false);
            }
            return 0;
        }

        private void Complete(object activatedInterface, bool succeeded)
        {
            if (!succeeded || activatedInterface == null)
            {
                ReleaseValue(activatedInterface);
                _failureClass = "process_loopback_activation_failed";
                Interlocked.CompareExchange(ref _state, Failed, Pending);
                _completion.TrySetResult(false);
                return;
            }

            _completedInterface = activatedInterface;
            Thread.MemoryBarrier();
            if (Interlocked.CompareExchange(
                ref _state,
                Available,
                Pending) == Pending)
            {
                _completion.TrySetResult(true);
                return;
            }

            object value = Interlocked.Exchange(ref _completedInterface, null);
            ReleaseValue(value);
            _completion.TrySetResult(false);
        }

        private void ReleaseValue(object value)
        {
            if (value == null)
            {
                return;
            }
            try
            {
                _releaseAction(value);
            }
            catch
            {
                // Completion callbacks must remain non-throwing. The owning
                // observer still fails closed if no client can be claimed.
            }
        }

        private static void ReleaseComInterface(object value)
        {
            if (value != null && Marshal.IsComObject(value))
            {
                Marshal.FinalReleaseComObject(value);
            }
        }
    }

    internal static class NativeMethods
    {
        [DllImport("Mmdevapi.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
        internal static extern int ActivateAudioInterfaceAsync(
            [MarshalAs(UnmanagedType.LPWStr)] string deviceInterfacePath,
            ref Guid interfaceId,
            ref PropVariant activationParams,
            [MarshalAs(UnmanagedType.Interface)]
            IActivateAudioInterfaceCompletionHandler completionHandler,
            [MarshalAs(UnmanagedType.Interface)]
            out IActivateAudioInterfaceAsyncOperation activationOperation);
    }

    internal interface ICaptureBufferSource
    {
        int GetBuffer(
            out IntPtr data,
            out uint frameCount,
            out uint flags,
            out ulong devicePosition,
            out ulong qpcPosition);
        int ReleaseBuffer(uint frameCount);
        int GetNextPacketSize(out uint nextPacketFrames);
    }

    internal sealed class ComCaptureBufferSource : ICaptureBufferSource
    {
        private readonly IAudioCaptureClient _client;

        internal ComCaptureBufferSource(IAudioCaptureClient client)
        {
            _client = client;
        }

        public int GetBuffer(
            out IntPtr data,
            out uint frameCount,
            out uint flags,
            out ulong devicePosition,
            out ulong qpcPosition)
        {
            return _client.GetBuffer(
                out data,
                out frameCount,
                out flags,
                out devicePosition,
                out qpcPosition);
        }

        public int ReleaseBuffer(uint frameCount)
        {
            return _client.ReleaseBuffer(frameCount);
        }

        public int GetNextPacketSize(out uint nextPacketFrames)
        {
            return _client.GetNextPacketSize(out nextPacketFrames);
        }
    }

    [ComImport]
    [Guid("72A22D78-CDE4-431D-B8CC-843A71199B6D")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IActivateAudioInterfaceAsyncOperation
    {
        [PreserveSig]
        int GetActivateResult(
            out int activateResult,
            [MarshalAs(UnmanagedType.IUnknown)] out object activatedInterface);
    }

    [ComImport]
    [Guid("41D949AB-9862-444A-80F6-C261334DA5EB")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IActivateAudioInterfaceCompletionHandler
    {
        [PreserveSig]
        int ActivateCompleted(IActivateAudioInterfaceAsyncOperation operation);
    }

    [ComImport]
    [Guid("1CB9AD4C-DBFA-4C32-B178-C2F568A703B2")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IAudioClient
    {
        [PreserveSig]
        int Initialize(
            int shareMode,
            uint streamFlags,
            long bufferDuration,
            long periodicity,
            IntPtr format,
            IntPtr sessionGuid);
        [PreserveSig] int GetBufferSize(out uint bufferFrames);
        [PreserveSig] int GetStreamLatency(out long latency);
        [PreserveSig] int GetCurrentPadding(out uint paddingFrames);
        [PreserveSig] int IsFormatSupported(int shareMode, IntPtr format, out IntPtr closestMatch);
        [PreserveSig] int GetMixFormat(out IntPtr format);
        [PreserveSig] int GetDevicePeriod(out long defaultPeriod, out long minimumPeriod);
        [PreserveSig] int Start();
        [PreserveSig] int Stop();
        [PreserveSig] int Reset();
        [PreserveSig] int SetEventHandle(IntPtr eventHandle);
        [PreserveSig]
        int GetService(
            ref Guid serviceGuid,
            [MarshalAs(UnmanagedType.IUnknown)] out object service);
    }

    [ComImport]
    [Guid("C8ADBD64-E71E-48A0-A4DE-185C395CD317")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IAudioCaptureClient
    {
        [PreserveSig]
        int GetBuffer(
            out IntPtr data,
            out uint frameCount,
            out uint flags,
            out ulong devicePosition,
            out ulong qpcPosition);
        [PreserveSig] int ReleaseBuffer(uint frameCount);
        [PreserveSig] int GetNextPacketSize(out uint nextPacketFrames);
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct AudioClientProcessLoopbackParams
    {
        internal uint TargetProcessId;
        internal int ProcessLoopbackMode;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct AudioClientActivationParams
    {
        internal int ActivationType;
        internal AudioClientProcessLoopbackParams ProcessLoopbackParams;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct Blob
    {
        internal int Size;
        internal IntPtr Data;
    }

    [StructLayout(LayoutKind.Explicit)]
    internal struct PropVariant
    {
        [FieldOffset(0)] internal ushort VariantType;
        [FieldOffset(8)] internal Blob Blob;
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
}
