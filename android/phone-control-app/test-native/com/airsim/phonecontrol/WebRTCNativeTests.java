package com.airsim.phonecontrol;

import android.app.Instrumentation;
import android.os.Bundle;
import org.json.JSONObject;
import org.webrtc.*;
import org.webrtc.audio.ExternalPlayoutClock;
import org.webrtc.audio.JavaAudioDeviceModule;
import java.io.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.*;
import java.util.concurrent.locks.LockSupport;

/** Runs real JNI/Opus/DTLS-SRTP without physical audio or telephone services. */
public final class WebRTCNativeTests extends Instrumentation {
    private boolean forceRelay;
    private final ExecutorService candidateDelivery = Executors.newSingleThreadExecutor();
    private final AtomicReference<String> failure = new AtomicReference<>();
    @Override public void onCreate(Bundle args) {
        super.onCreate(args);
        forceRelay = args != null && "true".equals(args.getString("relay"));
        start();
    }
    @Override public void onStart() {
        Bundle result = new Bundle();
        try {
            PeerConnectionFactory.initialize(PeerConnectionFactory.InitializationOptions.builder(getTargetContext()).createInitializationOptions());
            Logging.enableLogToDebugOutput(Logging.Severity.LS_NONE);
            List<PeerConnection.IceServer> ice = new ArrayList<>();
            if (forceRelay) {
                File file = new File(getTargetContext().getFilesDir(), "webrtc-test-ice.json");
                ByteArrayOutputStream data = new ByteArrayOutputStream();
                try (InputStream in = new FileInputStream(file)) { byte[] b = new byte[4096]; int n; while ((n = in.read(b)) > 0) data.write(b, 0, n); }
                JSONObject config = new JSONObject(data.toString("UTF-8"));
                ice.add(PeerConnection.IceServer.builder(config.getString("android_url"))
                        .setUsername(config.getString("username")).setPassword(config.getString("credential")).createIceServer());
            }
            Endpoint a = new Endpoint(400, 1000, ice, false);
            // B stands in for the carrier side: its capture and playout follow a skewed device clock.
            Endpoint b = new Endpoint(1000, 400, ice, true);
            try {
                a.other = b; b.other = a;
                a.start(); b.start();
                SessionDescription offer = create(a.peer, false);
                set(a.peer, offer, true);
                set(b.peer, offer, false); b.remoteReady();
                SessionDescription answer = create(b.peer, true);
                answer = new SessionDescription(answer.type, WebRTCOpusSDP.configure(answer.description));
                set(b.peer, answer, true);
                set(a.peer, answer, false); a.remoteReady();
                long deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(25);
                while ((a.goodFrames.get() < 120 || b.goodFrames.get() < 120) && System.nanoTime() < deadline && failure.get() == null) Thread.sleep(50);
                require(failure.get() == null, "native callback failure");
                require(a.goodFrames.get() >= 120 && b.goodFrames.get() >= 120,
                        "bidirectional tone timeout: A=" + a.goodFrames + " B=" + b.goodFrames);
                // Over three further seconds the skewed carrier clock must not cost a single frame.
                long[] before = b.carrierCounters();
                int goodA = a.goodFrames.get(), goodB = b.goodFrames.get();
                Thread.sleep(3000);
                long[] after = b.carrierCounters();
                require(after[0] == before[0] && after[1] == before[1] && after[2] == before[2] && after[3] == before[3],
                        "carrier clock lost audio: before=" + Arrays.toString(before) + " after=" + Arrays.toString(after));
                require(Math.abs((after[4] - before[4]) - (after[5] - before[5])) <= WebRTCPcmBuffer.MAX_FRAMES,
                        "capture did not follow the carrier clock: before=" + Arrays.toString(before) + " after=" + Arrays.toString(after));
                require(a.goodFrames.get() - goodA >= 250 && b.goodFrames.get() - goodB >= 250,
                        "tone stopped under the carrier clock: A=" + (a.goodFrames.get() - goodA) + " B=" + (b.goodFrames.get() - goodB));
                String astats = stats(a.peer), bstats = stats(b.peer);
                a.requireNoPhysicalAudio(); b.requireNoPhysicalAudio();
                require(a.inputFrames.get() < 3000 && b.inputFrames.get() < 3000, "capture busy loop");
                a.close(); b.close();
                int stoppedA = a.outputFrames.get(), stoppedB = b.outputFrames.get();
                Thread.sleep(150);
                require(a.outputFrames.get() == stoppedA && b.outputFrames.get() == stoppedB, "playout survived disposal");
                result.putString("stream", "PASS native JNI bidirectional Opus 400/1000Hz; A_good=" + a.goodFrames
                        + " B_good=" + b.goodFrames + " A_capture=" + a.inputFrames + " B_capture=" + b.inputFrames
                        + " B_carrier_lost=0 B_carrier_skew=+-2%"
                        + " policy=" + (forceRelay ? "relay" : "all") + "\nA " + astats + "\nB " + bstats + "\nphysical_audio=absent cleanup=stopped\n");
            } finally { a.close(); b.close(); }
            candidateDelivery.shutdownNow();
            finish(-1, result);
        } catch (Throwable error) {
            result.putString("stream", "FAIL " + error.getClass().getSimpleName() + ": " + error.getMessage() + "\n");
            candidateDelivery.shutdownNow();
            finish(1, result);
        }
    }

    private final class Endpoint implements AutoCloseable {
        final int tone, expected;
        final boolean carrier;
        final List<PeerConnection.IceServer> ice;
        final WebRTCPcmBuffer capture = new WebRTCPcmBuffer(), playback = new WebRTCPcmBuffer(WebRTCPcmBuffer.NO_AGE_LIMIT);
        final WebRTCCaptureClock captureClock = new WebRTCCaptureClock(capture);
        volatile boolean carrierRunning;
        final WebRTCPlayoutClock playoutClock = new WebRTCPlayoutClock(playback, () -> carrierRunning);
        final AtomicLong carrierProduced = new AtomicLong(), carrierMissed = new AtomicLong();
        Thread carrierIn, carrierOut;
        final AtomicInteger inputFrames = new AtomicInteger(), outputFrames = new AtomicInteger(), goodFrames = new AtomicInteger();
        final List<IceCandidate> candidates = new ArrayList<>();
        JavaAudioDeviceModule adm;
        PeerConnectionFactory factory;
        AudioSource source;
        AudioTrack track;
        PeerConnection peer;
        volatile Endpoint other;
        boolean remote;
        long sample, next;
        Endpoint(int tone, int expected, List<PeerConnection.IceServer> ice, boolean carrier) {
            this.tone = tone; this.expected = expected; this.ice = ice; this.carrier = carrier;
        }
        byte[] toneFrame() {
            byte[] frame = new byte[160];
            for (int i = 0; i < 80; i++) {
                short value = (short) (8000 * Math.sin(2 * Math.PI * tone * sample++ / 8000));
                frame[i * 2] = (byte) value; frame[i * 2 + 1] = (byte) (value >> 8);
            }
            return frame;
        }
        void analyze(byte[] data) {
            int crossings = 0, previous = 0; long square = 0;
            for (int i = 0; i + 1 < data.length; i += 2) {
                int value = (short) ((data[i] & 255) | (data[i + 1] << 8));
                if (previous < 0 && value >= 0) crossings++;
                square += (long)value * value; previous = value;
            }
            double hz = crossings * 8000.0 / (data.length / 2);
            if (square / (data.length / 2) > 100000 && Math.abs(hz - expected) <= 150) goodFrames.incrementAndGet();
        }
        /** Capture drops, capture concealments, playback drops, carrier misses, carrier frames, WebRTC captures. */
        long[] carrierCounters() {
            return new long[]{capture.drops(), capture.underruns(), playback.drops(), carrierMissed.get(),
                    carrierProduced.get(), inputFrames.get()};
        }
        /** Simulated modem: capture 2% slower and playout 2% faster than WebRTC's 10 ms timer, in 20 ms bursts. */
        void startCarrier() {
            carrierRunning = true;
            carrierIn = new Thread(() -> {
                long due = System.nanoTime();
                while (carrierRunning) {
                    due += 20_400_000L;
                    for (long now = System.nanoTime(); now < due && carrierRunning; now = System.nanoTime()) LockSupport.parkNanos(due - now);
                    for (int i = 0; i < 2; i++) { capture.offer(toneFrame(), 0, 160); carrierProduced.incrementAndGet(); }
                }
            }, "test-carrier-capture");
            carrierOut = new Thread(() -> {
                long due = System.nanoTime();
                try {
                    while (carrierRunning) {
                        due += 19_600_000L;
                        for (long now = System.nanoTime(); now < due && carrierRunning; now = System.nanoTime()) LockSupport.parkNanos(due - now);
                        for (int i = 0; i < 2 && carrierRunning; i++) {
                            byte[] frame = playback.take(19_600_000L);
                            if (frame == null) { if (carrierRunning) carrierMissed.incrementAndGet(); } else analyze(frame);
                        }
                    }
                } catch (InterruptedException ignored) {}
            }, "test-carrier-playout");
            carrierIn.start(); carrierOut.start();
        }
        void stopCarrier() throws InterruptedException {
            carrierRunning = false; capture.close(); playback.close();
            if (carrierIn != null) carrierIn.join(1000);
            if (carrierOut != null) carrierOut.join(1000);
        }
        final class ClockedSink implements JavaAudioDeviceModule.PlaybackSamplesReadyCallback, ExternalPlayoutClock {
            @Override public boolean awaitPlayoutSlot() throws InterruptedException { return playoutClock.awaitPlayoutSlot(); }
            @Override public void onWebRtcAudioTrackSamplesReady(JavaAudioDeviceModule.AudioSamples samples) {
                outputFrames.incrementAndGet(); playoutClock.accept(samples.getData());
            }
        }
        void start() {
            JavaAudioDeviceModule.Builder builder = JavaAudioDeviceModule.builder(getTargetContext()).setSampleRate(8000)
                    .setUseHardwareAcousticEchoCanceler(false).setUseHardwareNoiseSuppressor(false);
            if (carrier) {
                builder.setAudioBufferCallback((buffer, format, channels, rate, length, timestamp) -> {
                    byte[] bytes;
                    try { bytes = captureClock.next(carrierRunning); } catch (InterruptedException ignored) { bytes = new byte[160]; }
                    buffer.clear(); buffer.put(bytes); buffer.position(0);
                    inputFrames.incrementAndGet(); return 0;
                }).setPlaybackSamplesReadyCallback(new ClockedSink());
            }
            adm = (carrier ? builder : builder
                    .setAudioBufferCallback((buffer, format, channels, rate, length, timestamp) -> {
                        long now = System.nanoTime(); if (next == 0) next = now;
                        while (now < next) { LockSupport.parkNanos(next - now); now = System.nanoTime(); }
                        next += 10_000_000; if (next < now) next = now + 10_000_000;
                        buffer.clear();
                        while (buffer.remaining() >= 2) {
                            short value = (short) (8000 * Math.sin(2 * Math.PI * tone * sample++ / 8000));
                            buffer.put((byte) value); buffer.put((byte) (value >> 8));
                        }
                        inputFrames.incrementAndGet(); return 0;
                    }).setPlaybackSamplesReadyCallback(samples -> {
                        outputFrames.incrementAndGet(); byte[] data = samples.getData();
                        int crossings = 0, previous = 0; long square = 0;
                        for (int i = 0; i + 1 < data.length; i += 2) {
                            int value = (short) ((data[i] & 255) | (data[i + 1] << 8));
                            if (previous < 0 && value >= 0) crossings++;
                            square += (long)value * value; previous = value;
                        }
                        double hz = crossings * 8000.0 / (data.length / 2);
                        if (square / (data.length / 2) > 100000 && Math.abs(hz - expected) <= 150) goodFrames.incrementAndGet();
                    })).createAudioDeviceModule();
            adm.setAudioRecordEnabled(false);
            if (carrier) startCarrier();
            factory = PeerConnectionFactory.builder().setAudioDeviceModule(adm).createPeerConnectionFactory();
            MediaConstraints c = new MediaConstraints();
            for (String key : new String[]{"googEchoCancellation", "googAutoGainControl", "googNoiseSuppression", "googHighpassFilter"}) c.mandatory.add(new MediaConstraints.KeyValuePair(key,"false"));
            source = factory.createAudioSource(c); track = factory.createAudioTrack("tone-" + tone, source);
            PeerConnection.RTCConfiguration configuration = new PeerConnection.RTCConfiguration(ice);
            configuration.sdpSemantics = PeerConnection.SdpSemantics.UNIFIED_PLAN;
            if (forceRelay) configuration.iceTransportsType = PeerConnection.IceTransportsType.RELAY;
            peer = factory.createPeerConnection(configuration, new PeerConnection.Observer() {
                public void onSignalingChange(PeerConnection.SignalingState state) {}
                public void onIceConnectionChange(PeerConnection.IceConnectionState state) {}
                public void onIceConnectionReceivingChange(boolean receiving) {}
                public void onIceGatheringChange(PeerConnection.IceGatheringState state) {}
                public void onIceCandidate(IceCandidate candidate) {
                    candidateDelivery.execute(() -> other.candidate(candidate));
                }
                public void onIceCandidatesRemoved(IceCandidate[] candidates) {}
                public void onAddStream(MediaStream stream) {}
                public void onRemoveStream(MediaStream stream) {}
                public void onDataChannel(DataChannel channel) {}
                public void onRenegotiationNeeded() {}
            });
            require(peer != null, "peer creation"); peer.addTrack(track, Collections.singletonList("test"));
            List<RtpCapabilities.CodecCapability> codecs = new ArrayList<>();
            for (RtpCapabilities.CodecCapability codec : factory.getRtpSenderCapabilities(MediaStreamTrack.MediaType.MEDIA_TYPE_AUDIO).codecs) if ("opus".equalsIgnoreCase(codec.name)) codecs.add(codec);
            for (RtpTransceiver transceiver : peer.getTransceivers()) transceiver.setCodecPreferences(codecs);
        }
        synchronized void candidate(IceCandidate value) { if (peer == null) return; if (remote) peer.addIceCandidate(value); else candidates.add(value); }
        synchronized void remoteReady() { remote = true; for (IceCandidate value : candidates) peer.addIceCandidate(value); candidates.clear(); }
        void requireNoPhysicalAudio() throws Exception {
            Object input = adm.getClass().getField("audioInput").get(adm);
            java.lang.reflect.Field field = input.getClass().getDeclaredField("audioRecord");
            field.setAccessible(true);
            require(field.get(input) == null, "physical microphone was opened");
            Object output = adm.getClass().getField("audioOutput").get(adm);
            for (java.lang.reflect.Field member : output.getClass().getDeclaredFields()) {
                require(member.getType() != android.media.AudioTrack.class, "physical speaker adapter");
            }
        }
        public synchronized void close() {
            try { stopCarrier(); } catch (InterruptedException interrupted) { Thread.currentThread().interrupt(); }
            if (peer != null) { peer.close(); peer.dispose(); peer = null; }
            if (track != null) { track.dispose(); track = null; }
            if (source != null) { source.dispose(); source = null; }
            if (factory != null) { factory.dispose(); factory = null; }
            if (adm != null) { adm.release(); adm = null; }
        }
    }
    private SessionDescription create(PeerConnection peer, boolean answer) throws Exception {
        CountDownLatch done = new CountDownLatch(1); AtomicReference<SessionDescription> result = new AtomicReference<>();
        SdpObserver observer = new Observer(done) { public void onCreateSuccess(SessionDescription sdp) { result.set(sdp); done.countDown(); } };
        if (answer) peer.createAnswer(observer, new MediaConstraints()); else peer.createOffer(observer, new MediaConstraints());
        require(done.await(10, TimeUnit.SECONDS) && result.get() != null, "create SDP"); return result.get();
    }
    private void set(PeerConnection peer, SessionDescription description, boolean local) throws Exception {
        CountDownLatch done = new CountDownLatch(1); Observer observer = new Observer(done);
        if (local) peer.setLocalDescription(observer, description); else peer.setRemoteDescription(observer, description);
        require(done.await(10, TimeUnit.SECONDS) && failure.get() == null, "set SDP");
    }
    private class Observer implements SdpObserver {
        final CountDownLatch done; Observer(CountDownLatch done) { this.done = done; }
        public void onCreateSuccess(SessionDescription sdp) { done.countDown(); }
        public void onSetSuccess() { done.countDown(); }
        public void onCreateFailure(String error) { failure.set("create SDP"); done.countDown(); }
        public void onSetFailure(String error) { failure.set("set SDP"); done.countDown(); }
    }
    private String stats(PeerConnection peer) throws Exception {
        CountDownLatch done = new CountDownLatch(1); AtomicReference<RTCStatsReport> result = new AtomicReference<>();
        peer.getStats(report -> { result.set(report); done.countDown(); }); require(done.await(5, TimeUnit.SECONDS), "stats timeout");
        Map<String, RTCStats> all = result.get().getStatsMap();
        boolean opus = false, dtls = false, relay = false; long sent = 0, received = 0;
        for (RTCStats stat : all.values()) {
            Map<String, Object> m = stat.getMembers();
            if ("codec".equals(stat.getType()) && "audio/opus".equals(m.get("mimeType"))) opus = true;
            if ("transport".equals(stat.getType()) && "connected".equals(m.get("dtlsState"))) dtls = true;
            if ("outbound-rtp".equals(stat.getType()) && m.get("bytesSent") instanceof Number) sent += ((Number)m.get("bytesSent")).longValue();
            if ("inbound-rtp".equals(stat.getType()) && m.get("bytesReceived") instanceof Number) received += ((Number)m.get("bytesReceived")).longValue();
            if ("candidate-pair".equals(stat.getType()) && "succeeded".equals(m.get("state")) && Boolean.TRUE.equals(m.get("nominated"))) {
                RTCStats local = all.get(m.get("localCandidateId"));
                if (local != null && "relay".equals(local.getMembers().get("candidateType"))) relay = true;
            }
        }
        require(opus && dtls && sent > 0 && received > 0, "Opus/DTLS/RTP stats"); require(!forceRelay || relay, "selected relay candidate");
        return "opus=" + opus + " dtls=" + dtls + " sent=" + sent + " received=" + received + " relay=" + relay;
    }
    private static void require(boolean value, String message) { if (!value) throw new AssertionError(message); }
}
