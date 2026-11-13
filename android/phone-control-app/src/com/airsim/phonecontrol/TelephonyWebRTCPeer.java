package com.airsim.phonecontrol;

import android.content.Context;
import org.json.JSONArray;
import org.json.JSONObject;
import org.webrtc.*;
import org.webrtc.audio.JavaAudioDeviceModule;
import java.io.*;
import java.net.*;
import java.nio.charset.StandardCharsets;
import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.AtomicBoolean;
import org.webrtc.audio.ExternalPlayoutClock;
import org.webrtc.audio.PcmFormat;

/** Native peer and carrier audio share the privileged process. No audio crosses IPC. */
final class TelephonyWebRTCPeer implements Closeable {
    interface Signals { void send(JSONObject value) throws Exception; }
    private static boolean initialized;
    private final Context context;
    private final String callUUID;
    private final long generation;
    private final JSONArray configuration;
    private final Signals signals;
    private final Runnable failed;
    private final ScheduledExecutorService signaling = Executors.newSingleThreadScheduledExecutor();
    private ScheduledFuture<?> statisticsTask;
    private final WebRTCStatistics statistics = new WebRTCStatistics();
    private boolean statisticsPending;
    private boolean disposalFailed;
    // Carrier attachment can race the Telecom/audio-policy transition into the call. Retry only
    // before the verified route first reports ready; the TELEPHONY route check is never relaxed.
    static final int CARRIER_ATTACH_ATTEMPTS = 4;
    static final long CARRIER_ATTACH_RETRY_MILLIS = 300;
    private int carrierAttempts;
    private volatile String failureReason = "webrtc_failed";
    private final AtomicBoolean closed = new AtomicBoolean();
    private final CompletableFuture<Void> disposal = new CompletableFuture<>();
    private final PcmFormat pcmFormat;
    private final WebRTCPcmBuffer capture;
    // Carrier backpressure bounds playback delay; see WebRTCPcmBuffer.NO_AGE_LIMIT.
    private final WebRTCPcmBuffer playback;
    private volatile boolean deviceReady;
    // Each direction follows the carrier's device clock once it is attached.
    private final WebRTCCaptureClock captureClock;
    private final WebRTCPlayoutClock playoutClock;
    private TelephonyAudioDevice device;
    private PeerConnectionFactory factory;
    private JavaAudioDeviceModule adm;
    private AudioSource source;
    private AudioTrack track;
    private PeerConnection peer;
    private String sessionID = "";
    private final Set<String> previousSessions = new HashSet<>();
    private final List<IceCandidate> pendingICE = new ArrayList<>();
    private final WebRTCReadiness readiness = new WebRTCReadiness();
    private final CloudAudioSetupTimeline setup = new CloudAudioSetupTimeline(
            CloudAudioSetupTimeline.Scope.NATIVE, System::nanoTime, BridgeLog::info);
    private boolean remoteSet;
    private List<PeerConnection.IceServer> iceServers;
    private final boolean hostOnly;
    private boolean hostAnswerReady;
    private boolean hostGatheringComplete;
    private PeerConnection hostAnswerOwner;
    private String hostAnswerSession = "";

    TelephonyWebRTCPeer(Context context, String callUUID, long generation, JSONArray ice,
                        Signals signals, Runnable failed, boolean hostOnly) {
        this(context, callUUID, generation, ice, signals, failed, hostOnly, false);
    }

    TelephonyWebRTCPeer(Context context, String callUUID, long generation, JSONArray ice,
                        Signals signals, Runnable failed, boolean hostOnly, boolean forceNarrowband) {
        this.context = context; this.callUUID = callUUID;
        this.generation = generation; this.configuration = ice;
        this.signals = signals; this.failed = failed; this.hostOnly = hostOnly;
        // Local host-only sessions do not yet have automatic whole-peer format recovery.
        pcmFormat = hostOnly || forceNarrowband ? PcmFormat.NARROWBAND : TelephonyAudioDevice.preferredFormat();
        capture = new WebRTCPcmBuffer(pcmFormat);
        playback = new WebRTCPcmBuffer(pcmFormat, WebRTCPcmBuffer.NO_AGE_LIMIT);
        captureClock = new WebRTCCaptureClock(capture);
        playoutClock = new WebRTCPlayoutClock(playback, () -> deviceReady && !closed.get());
    }

    int sampleRate() { return pcmFormat.rate(); }

    void start(boolean activateCarrierAudio) {
        submit(() -> {
            initialize(context);
            iceServers = parseICE(configuration, hostOnly);
            if (closed.get()) return;
            adm = JavaAudioDeviceModule.builder(context).setSampleRate(pcmFormat.rate())
                    .setUseStereoInput(false).setUseStereoOutput(false)
                    .setUseHardwareAcousticEchoCanceler(false).setUseHardwareNoiseSuppressor(false)
                    .setAudioRecordErrorCallback(new JavaAudioDeviceModule.AudioRecordErrorCallback() {
                        public void onWebRtcAudioRecordInitError(String error) { fail("audio_record_init_error"); }
                        public void onWebRtcAudioRecordStartError(JavaAudioDeviceModule.AudioRecordStartErrorCode code, String error) { fail("audio_record_start_error"); }
                        public void onWebRtcAudioRecordError(String error) { fail("audio_record_error"); }
                    })
                    .setAudioTrackErrorCallback(new JavaAudioDeviceModule.AudioTrackErrorCallback() {
                        public void onWebRtcAudioTrackInitError(String error) { fail("audio_playout_init_error"); }
                        public void onWebRtcAudioTrackStartError(JavaAudioDeviceModule.AudioTrackStartErrorCode code, String error) { fail("audio_playout_start_error"); }
                        public void onWebRtcAudioTrackError(String error) { fail("audio_playout_error"); }
                    })
                    .setAudioBufferCallback((buffer, format, channels, rate, count, time) -> {
                        // The pinned SDK passes count=0 for external capture and sends the entire
                        // direct buffer after this callback. Validate its actual contract first.
                        if (!WebRTCPcmContract.acceptsCapture(pcmFormat, buffer, format, channels, rate)) {
                            WebRTCPcmContract.silence(buffer);
                            submit(() -> fail("pcm_capture_format_mismatch"));
                            return 0;
                        }
                        byte[] bytes;
                        try { bytes = captureClock.next(deviceReady && !closed.get()); }
                        catch (InterruptedException ignored) { bytes = new byte[pcmFormat.frameBytes()]; }
                        if (!WebRTCPcmContract.copyCapture(pcmFormat, buffer, format, channels, rate, bytes)) {
                            WebRTCPcmContract.silence(buffer);
                            submit(() -> fail("pcm_capture_format_mismatch"));
                        }
                        return 0; // External capture has no sample-accurate monotonic timestamp.
                    })
                    .setPlaybackSamplesReadyCallback(new CarrierPlayout()).createAudioDeviceModule();
            adm.setAudioRecordEnabled(false);
            PeerConnectionFactory.Options options = new PeerConnectionFactory.Options();
            // UserService is not an Application. Avoid context-dependent Android network callbacks;
            // native sockets still gather host/STUN/TURN candidates and ICE checks remain enabled.
            options.disableNetworkMonitor = true;
            factory = PeerConnectionFactory.builder().setOptions(options)
                    .setAudioDeviceModule(adm).createPeerConnectionFactory();
            MediaConstraints constraints = new MediaConstraints();
            // The telephone loopback is already processed; iPhone retains native voice processing.
            for (String key : new String[]{"googEchoCancellation", "googAutoGainControl", "googNoiseSuppression", "googHighpassFilter"}) {
                constraints.mandatory.add(new MediaConstraints.KeyValuePair(key, "false"));
            }
            source = factory.createAudioSource(constraints);
            track = factory.createAudioTrack("airsim-telephone", source);
            if (activateCarrierAudio) startCarrierAudio();
        });
    }

    /** Keep ICE/DTLS alive during ringback; attach the carrier route only on answer. */
    void activateCarrierAudio() { submit(this::startCarrierAudio); }

    /** The playout adapter pulls NetEq when the carrier AudioTrack has room. */
    private final class CarrierPlayout implements JavaAudioDeviceModule.PlaybackSamplesReadyCallback, ExternalPlayoutClock {
        @Override public boolean awaitPlayoutSlot() throws InterruptedException { return playoutClock.awaitPlayoutSlot(); }
        @Override public void onWebRtcAudioTrackSamplesReady(JavaAudioDeviceModule.AudioSamples samples) {
            byte[] pcm = samples.getData();
            if (!WebRTCPcmContract.acceptsPlayback(pcmFormat, samples.getAudioFormat(),
                    samples.getChannelCount(), samples.getSampleRate(), pcm)) {
                submit(() -> fail("pcm_playback_format_mismatch"));
                return;
            }
            playoutClock.accept(pcm);
        }
    }

    private void startCarrierAudio() {
        if (closed.get() || device != null) return;
        setup.mark(CloudAudioSetupTimeline.Phase.CARRIER_ACTIVATION);
        carrierAttempts++;
        TelephonyAudioDevice[] attempt = new TelephonyAudioDevice[1];
        attempt[0] = new TelephonyAudioDevice(capture, playback, () -> {
            deviceReady = true;
            setup.mark(CloudAudioSetupTimeline.Phase.CARRIER_READY);
            submit(() -> { readiness.deviceReady(); maybeEmitReady(); });
        }, () -> carrierFailed(attempt[0]));
        device = attempt[0];
        if (!closed.get()) device.start();
    }

    /** Retry a carrier device that failed before its route was verified, keeping ICE/DTLS alive. */
    private void carrierFailed(TelephonyAudioDevice failed) {
        submit(() -> {
            if (device != failed) return;
            String reason = failed.failureReason();
            // A format rejection requires a new ADM/factory and a fresh negotiation. Never
            // reopen 8 kHz carrier queues underneath a still-running 48 kHz native peer.
            if (CarrierFormatFallback.FORMAT_INIT_FAILED.equals(reason)
                    || deviceReady || carrierAttempts >= CARRIER_ATTACH_ATTEMPTS) {
                failureReason = reason;
                throw new IOException(reason);
            }
            device = null;
            try { failed.close(); }
            catch (RuntimeException | LinkageError error) {
                // A worker may still hold native handles. Never reuse its buffers or claim disposal.
                disposalFailed = true;
                throw new IOException("carrier_cleanup_failed");
            }
            capture.reopen(); playback.reopen();
            if (closed.get()) { capture.close(); playback.close(); return; }
            BridgeLog.info("standalone_carrier_attach_retry attempt=" + carrierAttempts + " reason=" + reason);
            try {
                signaling.schedule(() -> submit(this::startCarrierAudio),
                        CARRIER_ATTACH_RETRY_MILLIS, TimeUnit.MILLISECONDS);
            } catch (RejectedExecutionException closing) { /* Peer is closing. */ }
        });
    }

    static synchronized void initialize(Context context) {
        if (initialized) return;
        PeerConnectionFactory.initialize(PeerConnectionFactory.InitializationOptions.builder(context)
                .setEnableInternalTracer(false)
                .setNativeLibraryLoader(name -> {
                    try {
                        // app_process does not inherit the APK ClassLoader's native search path.
                        // Load only the installed, signed APK's platform-selected library directory.
                        java.io.File library = new java.io.File(context.getApplicationInfo().nativeLibraryDir,
                                System.mapLibraryName(name));
                        System.load(library.getAbsolutePath());
                        return true;
                    } catch (UnsatisfiedLinkError | SecurityException error) { return false; }
                }).createInitializationOptions());
        // Native SDP and ICE credentials must not be copied into app diagnostics.
        Logging.enableLogToDebugOutput(Logging.Severity.LS_NONE);
        initialized = true;
    }

    void receive(JSONObject message) {
        if (!callUUID.equalsIgnoreCase(message.optString("call_uuid"))
                || generation != message.optLong("generation", -1)) return;
        String action = message.optString("action");
        String id = message.optString("session_id");
        try { UUID.fromString(id); } catch (IllegalArgumentException invalid) { return; }
        submit(() -> {
            if ("webrtc_offer".equals(action)) {
                String sdp = message.optString("sdp");
                if (sdp.isEmpty() || sdp.length() > 49152 || id.equals(sessionID) || previousSessions.contains(id)) return;
                if (previousSessions.size() >= 64) throw new IOException("Too many WebRTC negotiations");
                previousSessions.add(id);
                disposePeer();
                sessionID = id; readiness.beginSession(id); remoteSet = false; pendingICE.clear();
                hostAnswerReady = false; hostGatheringComplete = false; hostAnswerOwner = null; hostAnswerSession = "";
                if (hostOnly && iceServers == null) iceServers = List.of();
                PeerConnection.RTCConfiguration config = new PeerConnection.RTCConfiguration(iceServers);
                config.audioJitterBufferMaxPackets = WebRTCPlayout.JITTER_BUFFER_MAX_PACKETS;
                config.audioJitterBufferFastAccelerate = WebRTCPlayout.FAST_ACCELERATE;
                config.sdpSemantics = PeerConnection.SdpSemantics.UNIFIED_PLAN;
                config.continualGatheringPolicy = hostOnly
                        ? PeerConnection.ContinualGatheringPolicy.GATHER_ONCE
                        : PeerConnection.ContinualGatheringPolicy.GATHER_CONTINUALLY;
                peer = factory.createPeerConnection(config, observer(id));
                if (peer == null) throw new IOException("Peer creation failed");
                peer.addTrack(track, Collections.singletonList("airsim"));
                PeerConnection owner = peer;
                startStatistics(owner, id);
                owner.setRemoteDescription(new DescriptionObserver(id) {
                    @Override public void onSetSuccess() { submit(() -> {
                        if (!owns(owner, id)) return;
                        remoteSet = true;
                        for (IceCandidate candidate : pendingICE) owner.addIceCandidate(candidate);
                        pendingICE.clear();
                        List<RtpCapabilities.CodecCapability> codecs = new ArrayList<>();
                        for (RtpCapabilities.CodecCapability codec : factory.getRtpSenderCapabilities(MediaStreamTrack.MediaType.MEDIA_TYPE_AUDIO).codecs) {
                            if ("opus".equalsIgnoreCase(codec.name)) codecs.add(codec);
                        }
                        if (codecs.isEmpty()) throw new IOException("Opus unavailable");
                        for (RtpTransceiver transceiver : owner.getTransceivers()) {
                            if (transceiver.getMediaType() == MediaStreamTrack.MediaType.MEDIA_TYPE_AUDIO) transceiver.setCodecPreferences(codecs);
                        }
                        owner.createAnswer(new DescriptionObserver(id) {
                            @Override public void onCreateSuccess(SessionDescription answer) { submit(() -> {
                                if (!owns(owner, id)) return;
                                SessionDescription tuned = new SessionDescription(answer.type, WebRTCOpusSDP.configure(answer.description));
                                owner.setLocalDescription(new DescriptionObserver(id) {
                                    @Override public void onSetSuccess() { submit(() -> {
                                        if (!owns(owner, id)) return;
                                        if (!hostOnly) {
                                            signals.send(identity("webrtc_answer", id).put("sdp", tuned.description));
                                            return;
                                        }
                                        hostAnswerOwner = owner;
                                        hostAnswerSession = id;
                                        hostAnswerReady = true;
                                        maybeSendHostAnswer();
                                    }); }
                                }, tuned);
                            }); }
                        }, new MediaConstraints());
                    }); }
                }, new SessionDescription(SessionDescription.Type.OFFER, sdp));
            } else if ("webrtc_ice".equals(action) && id.equals(sessionID) && peer != null) {
                JSONObject value = message.optJSONObject("candidate");
                if (value == null) return;
                String candidate = value.optString("candidate");
                int index = value.optInt("sdp_mline_index", -1);
                if (candidate.isEmpty() || candidate.length() > 4096 || index < 0 || index > 64) return;
                IceCandidate ice = new IceCandidate(value.isNull("sdp_mid") ? null : value.optString("sdp_mid"), index, candidate);
                if (remoteSet) peer.addIceCandidate(ice);
                else if (pendingICE.size() < 128) pendingICE.add(ice);
                else throw new IOException("Too many ICE candidates");
            }
        });
    }

    // Add fields before handing a complete signaling message to the owning socket.
    private JSONObject identity(String action, String id) throws Exception {
        return new JSONObject().put("action", action).put("call_uuid", callUUID)
                .put("generation", generation).put("session_id", id);
    }

    private boolean owns(PeerConnection owner, String id) { return !closed.get() && peer == owner && sessionID.equals(id); }

    private void maybeSendHostAnswer() throws Exception {
        if (!hostOnly || !hostAnswerReady || !hostGatheringComplete || hostAnswerOwner == null) return;
        if (!owns(hostAnswerOwner, hostAnswerSession)) return;
        SessionDescription local = hostAnswerOwner.getLocalDescription();
        if (local == null || local.description == null || local.description.isEmpty()) return;
        hostAnswerReady = false;
        signals.send(identity("webrtc_answer", hostAnswerSession).put("sdp", local.description));
    }

    // Telemetry has a separate failure boundary: SDK/report failures must never end audio.
    private void startStatistics(PeerConnection owner, String id) {
        statisticsTask = signaling.scheduleWithFixedDelay(() -> {
            if (!owns(owner, id) || statisticsPending) return;
            statisticsPending = true;
            try {
                owner.getStats(report -> {
                    try { signaling.execute(() -> {
                        if (!owns(owner, id)) return;
                        statisticsPending = false;
                        try {
                            Map<String, WebRTCStatistics.Entry> entries = new HashMap<>();
                            for (RTCStats stat : report.getStatsMap().values()) {
                                entries.put(stat.getId(), new WebRTCStatistics.Entry(stat.getId(), stat.getType(), stat.getMembers()));
                            }
                            Map<String, Object> pcm = new LinkedHashMap<>();
                            // Frames the carrier loopback discarded or concealed, outside the RTP loss count.
                            pcm.put("pcm_sample_rate_hz", pcmFormat.rate());
                            pcm.put("pcm_capture_drop_total", capture.drops());
                            pcm.put("pcm_capture_conceal_total", capture.underruns());
                            pcm.put("pcm_playback_drop_total", playback.drops());
                            // 10 ms silence frames that kept the carrier track fed without playout.
                            pcm.put("pcm_playback_fill_total", playback.underruns());
                            int carrierUnderruns = device == null ? -1 : device.playbackUnderruns();
                            if (carrierUnderruns >= 0) pcm.put("carrier_underrun_total", carrierUnderruns);
                            for (Map<String, Object> fields : statistics.sample(entries)) {
                                if ("inbound".equals(fields.get("direction"))) fields.putAll(pcm);
                                BridgeLog.info("standalone_webrtc_stats session_id=" + id + " " + fields);
                            }
                        } catch (Exception | LinkageError ignored) { /* Optional telemetry only. */ }
                    }); } catch (RejectedExecutionException ignored) { /* Peer is closing. */ }
                });
            } catch (Exception | LinkageError ignored) { statisticsPending = false; }
        }, 5, 5, TimeUnit.SECONDS);
    }

    private PeerConnection.Observer observer(String id) {
        return new PeerConnection.Observer() {
            public void onSignalingChange(PeerConnection.SignalingState state) {}
            public void onIceConnectionChange(PeerConnection.IceConnectionState state) {
                if (state == PeerConnection.IceConnectionState.FAILED) submit(() -> {
                    if (sessionID.equals(id)) throw new IOException("ICE failed");
                });
            }
            public void onConnectionChange(PeerConnection.PeerConnectionState state) {
                submit(() -> {
                    if (id.equals(sessionID) && state == PeerConnection.PeerConnectionState.CONNECTED) {
                        setup.mark(CloudAudioSetupTimeline.Phase.NATIVE_CONNECTED);
                    }
                    readiness.connectionChanged(id, state == PeerConnection.PeerConnectionState.CONNECTED);
                    maybeEmitReady();
                });
            }
            public void onIceConnectionReceivingChange(boolean receiving) {}
            public void onIceGatheringChange(PeerConnection.IceGatheringState state) {
                if (!hostOnly || state != PeerConnection.IceGatheringState.COMPLETE) return;
                submit(() -> {
                    if (!id.equals(sessionID)) return;
                    hostGatheringComplete = true;
                    maybeSendHostAnswer();
                });
            }
            public void onIceCandidate(IceCandidate candidate) { submit(() -> {
                if (hostOnly || !id.equals(sessionID)) return;
                signals.send(identity("webrtc_ice", id).put("candidate", new JSONObject()
                        .put("candidate", candidate.sdp).put("sdp_mid", candidate.sdpMid)
                        .put("sdp_mline_index", candidate.sdpMLineIndex)));
            }); }
            public void onIceCandidatesRemoved(IceCandidate[] candidates) {}
            public void onAddStream(MediaStream stream) {}
            public void onRemoveStream(MediaStream stream) {}
            public void onDataChannel(DataChannel channel) { channel.close(); channel.dispose(); }
            public void onRenegotiationNeeded() {}
        };
    }

    private void maybeEmitReady() throws Exception {
        String readySession = readiness.takeReadySession();
        if (readySession != null) signals.send(new JSONObject().put("status", "webrtc_ready")
                .put("call_uuid", callUUID).put("generation", generation).put("session_id", readySession));
    }

    private abstract class DescriptionObserver implements SdpObserver {
        private final String id;
        DescriptionObserver(String id) { this.id = id; }
        public void onCreateSuccess(SessionDescription description) {}
        public void onSetSuccess() {}
        public void onCreateFailure(String error) { submit(() -> { if (id.equals(sessionID)) fail("sdp_create_failed"); }); }
        public void onSetFailure(String error) { submit(() -> { if (id.equals(sessionID)) fail("sdp_set_failed"); }); }
    }

    private static List<PeerConnection.IceServer> parseICE(JSONArray servers, boolean hostOnly) throws Exception {
        if (hostOnly) {
            if (servers.length() != 0) throw new IOException("host-only ICE required");
            return List.of();
        }
        if (servers.length() > 16) throw new IOException("too many ICE servers");
        List<PeerConnection.IceServer> result = new ArrayList<>();
        boolean hasTurn = false;
        for (int i = 0; i < servers.length(); i++) {
            JSONObject server = servers.getJSONObject(i);
            JSONArray urls = server.getJSONArray("urls");
            if (urls.length() > 16) throw new IOException("too many ICE URLs");
            List<String> values = new ArrayList<>();
            for (int j = 0; j < urls.length(); j++) {
                String url = urls.getString(j);
                if (url.length() > 2048 || !(url.startsWith("turn:") || url.startsWith("turns:")
                        || url.startsWith("stun:") || url.startsWith("stuns:"))) throw new IOException("invalid ICE URL");
                hasTurn |= url.startsWith("turn:") || url.startsWith("turns:");
                values.add(url);
            }
            if (!values.isEmpty()) result.add(PeerConnection.IceServer.builder(values)
                    .setUsername(server.optString("username")).setPassword(server.optString("credential")).createIceServer());
        }
        if (!hasTurn) throw new IOException("TURN configuration unavailable");
        return result;
    }

    private interface Work { void run() throws Exception; }
    private void submit(Work work) {
        if (closed.get()) return;
        try { signaling.execute(() -> {
            if (closed.get()) return;
            try { work.run(); } catch (Exception | LinkageError error) { fail(reason(error)); }
        }); } catch (RejectedExecutionException ignored) {}
    }

    /** Stable, non-sensitive failure code. SDK messages may contain SDP/ICE and are never used. */
    String failureReason() { return failureReason; }

    private static String reason(Throwable error) {
        String value = error instanceof IOException && error.getMessage() != null ? error.getMessage()
                : "media_cleanup_failed".equals(error.getMessage()) ? "media_cleanup_failed"
                : "webrtc " + error.getClass().getSimpleName();
        value = value.toLowerCase(Locale.ROOT).replaceAll("[^a-z0-9]+", "_");
        return value.length() > 48 ? value.substring(0, 48) : value;
    }

    private void fail(String reason) {
        if (closed.get()) return;
        failureReason = reason;
        close();
        // Generic diagnostics only: SDK errors may contain SDP/ICE credentials.
        BridgeLog.info("standalone_webrtc_failed reason=" + reason);
        failed.run();
    }

    private void disposePeer() {
        if (statisticsTask != null) statisticsTask.cancel(false);
        statisticsTask = null; statisticsPending = false; statistics.reset();
        PeerConnection retiring = peer;
        peer = null; // Never retry a native handle after an uncertain close/dispose.
        if (retiring != null) {
            boolean released = release(retiring::close);
            released &= release(retiring::dispose);
            if (!released) {
                disposalFailed = true;
                throw new IllegalStateException("media_cleanup_failed");
            }
        }
    }

    /** Completes only after serialized native and carrier teardown, never merely after queuing it. */
    CompletableFuture<Void> closeAsync() {
        if (!closed.compareAndSet(false, true)) return disposal;
        deviceReady = false; capture.close(); playback.close();
        try {
            signaling.execute(() -> {
                // Try every release even if an earlier one fails. Keep ownership on any uncertainty.
                boolean released = !disposalFailed;
                released &= release(() -> { if (device != null) device.close(); });
                released &= release(this::disposePeer);
                released &= release(() -> { if (track != null) track.dispose(); });
                released &= release(() -> { if (source != null) source.dispose(); });
                released &= release(() -> { if (factory != null) factory.dispose(); });
                released &= release(() -> { if (adm != null) adm.release(); });
                if (released) disposal.complete(null);
                else disposal.completeExceptionally(new IllegalStateException("media_cleanup_failed"));
            });
        } catch (RejectedExecutionException error) {
            disposal.completeExceptionally(new IllegalStateException("media_cleanup_failed"));
        } finally {
            signaling.shutdown();
        }
        return disposal;
    }

    private static boolean release(Runnable action) {
        try { action.run(); return true; }
        catch (RuntimeException | LinkageError error) { return false; }
    }

    @Override public void close() { closeAsync(); }
}
