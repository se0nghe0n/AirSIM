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
import java.util.concurrent.locks.LockSupport;

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
    private final AtomicBoolean closed = new AtomicBoolean();
    private final CompletableFuture<Void> disposal = new CompletableFuture<>();
    private final WebRTCPcmBuffer capture = new WebRTCPcmBuffer();
    private final WebRTCPcmBuffer playback = new WebRTCPcmBuffer();
    private volatile boolean deviceReady;
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
    private boolean remoteSet;
    private List<PeerConnection.IceServer> iceServers;
    private long captureDeadline;
    private final boolean hostOnly;
    private boolean hostAnswerReady;
    private boolean hostGatheringComplete;
    private PeerConnection hostAnswerOwner;
    private String hostAnswerSession = "";

    TelephonyWebRTCPeer(Context context, String callUUID, long generation, JSONArray ice,
                        Signals signals, Runnable failed, boolean hostOnly) {
        this.context = context; this.callUUID = callUUID;
        this.generation = generation; this.configuration = ice;
        this.signals = signals; this.failed = failed; this.hostOnly = hostOnly;
    }

    void start() {
        submit(() -> {
            initialize(context);
            iceServers = parseICE(configuration, hostOnly);
            if (closed.get()) return;
            adm = JavaAudioDeviceModule.builder(context).setSampleRate(8000)
                    .setUseStereoInput(false).setUseStereoOutput(false)
                    .setUseHardwareAcousticEchoCanceler(false).setUseHardwareNoiseSuppressor(false)
                    .setAudioRecordErrorCallback(new JavaAudioDeviceModule.AudioRecordErrorCallback() {
                        public void onWebRtcAudioRecordInitError(String error) { fail(); }
                        public void onWebRtcAudioRecordStartError(JavaAudioDeviceModule.AudioRecordStartErrorCode code, String error) { fail(); }
                        public void onWebRtcAudioRecordError(String error) { fail(); }
                    })
                    .setAudioTrackErrorCallback(new JavaAudioDeviceModule.AudioTrackErrorCallback() {
                        public void onWebRtcAudioTrackInitError(String error) { fail(); }
                        public void onWebRtcAudioTrackStartError(JavaAudioDeviceModule.AudioTrackStartErrorCode code, String error) { fail(); }
                        public void onWebRtcAudioTrackError(String error) { fail(); }
                    })
                    .setAudioBufferCallback((buffer, format, channels, rate, count, time) -> {
                        // With AudioRecord disabled this callback, not the SDK, owns the clock.
                        long now = System.nanoTime();
                        if (captureDeadline == 0) captureDeadline = now;
                        while (now < captureDeadline) {
                            LockSupport.parkNanos(captureDeadline - now);
                            now = System.nanoTime();
                        }
                        captureDeadline += 10_000_000L;
                        if (captureDeadline < now) captureDeadline = now + 10_000_000L;
                        buffer.clear();
                        byte[] bytes = capture.poll();
                        if (buffer.remaining() == bytes.length && channels == 1 && rate == 8000) {
                            buffer.put(bytes);
                        } else {
                            while (buffer.hasRemaining()) buffer.put((byte) 0);
                        }
                        buffer.position(0);
                        return 0; // External capture has no sample-accurate monotonic timestamp.
                    })
                    .setPlaybackSamplesReadyCallback(samples -> {
                        byte[] bytes = samples.getData();
                        if (deviceReady && !closed.get()) playback.offer(bytes, 0, bytes.length);
                    }).createAudioDeviceModule();
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
            device = new TelephonyAudioDevice(capture, playback, () -> {
                deviceReady = true;
                submit(() -> { readiness.deviceReady(); maybeEmitReady(); });
            }, this::fail);
            if (!closed.get()) device.start();
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
                            long pcmDrops = capture.drops() + playback.drops();
                            long pcmUnderruns = capture.underruns();
                            for (Map<String, Object> fields : statistics.sample(entries)) {
                                if ("inbound".equals(fields.get("direction"))) {
                                    fields.put("pcm_drop_total", pcmDrops);
                                    fields.put("pcm_underrun_total", pcmUnderruns);
                                }
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
        public void onCreateFailure(String error) { submit(() -> { if (id.equals(sessionID)) fail(); }); }
        public void onSetFailure(String error) { submit(() -> { if (id.equals(sessionID)) fail(); }); }
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
            try { work.run(); } catch (Exception | LinkageError error) { fail(); }
        }); } catch (RejectedExecutionException ignored) {}
    }

    private void fail() {
        if (closed.get()) return;
        close();
        // Generic diagnostics only: SDK errors may contain SDP/ICE credentials.
        BridgeLog.info("standalone_webrtc_failed");
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
