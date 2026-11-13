package com.airsim.phonecontrol;

import android.app.Instrumentation;
import android.os.Bundle;
import org.json.JSONObject;
import org.webrtc.*;
import org.webrtc.audio.ExternalPlayoutClock;
import org.webrtc.audio.JavaAudioDeviceModule;
import org.webrtc.audio.PcmFormat;
import java.io.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.*;
import java.util.concurrent.locks.LockSupport;

/** Runs real JNI/Opus/DTLS-SRTP without physical audio or telephone services. */
public final class WebRTCNativeTests extends Instrumentation {
    private boolean forceRelay;
    private final List<PeerConnection.IceServer> ice = new ArrayList<>();
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
            if (forceRelay) {
                File file = new File(getTargetContext().getFilesDir(), "webrtc-test-ice.json");
                ByteArrayOutputStream data = new ByteArrayOutputStream();
                try (InputStream in = new FileInputStream(file)) { byte[] b = new byte[4096]; int n; while ((n = in.read(b)) > 0) data.write(b, 0, n); }
                JSONObject config = new JSONObject(data.toString("UTF-8"));
                ice.add(PeerConnection.IceServer.builder(config.getString("android_url"))
                        .setUsername(config.getString("username")).setPassword(config.getString("credential")).createIceServer());
            }
            requireDetectorControls();
            StringBuilder report = new StringBuilder();
            runCase("legacy-8k", PcmFormat.NARROWBAND, PcmFormat.NARROWBAND, 400, 1000, report);
            runCase("wideband-48k", PcmFormat.WIDEBAND, PcmFormat.WIDEBAND, 5100, 6000, report);
            runCase("mixed-48k-8k", PcmFormat.WIDEBAND, PcmFormat.NARROWBAND, 400, 1000, report);
            result.putString("stream", "PASS native JNI bidirectional Opus: legacy, wideband, mixed\n"
                    + "detector_controls=PASS (silence, wrong tone, 8k aliases, 8k downsample/upsample)\n"
                    + report + "synthetic_only=true physical_carrier_HD=not_tested\n");
            candidateDelivery.shutdownNow();
            finish(-1, result);
        } catch (Throwable error) {
            result.putString("stream", "FAIL " + error.getClass().getSimpleName() + ": " + error.getMessage() + "\n");
            candidateDelivery.shutdownNow();
            finish(1, result);
        }
    }

    private void runCase(String name, PcmFormat aFormat, PcmFormat bFormat, int aTone, int bTone,
                         StringBuilder report) throws Exception {
        int reportStart = report.length();
        Endpoint a = new Endpoint(aFormat, aTone, bTone, false);
        // B stands in for the carrier side: its capture and playout follow a skewed device clock.
        Endpoint b = new Endpoint(bFormat, bTone, aTone, true);
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
            while ((a.goodFrames.get() < 120 || b.goodFrames.get() < 120)
                    && System.nanoTime() < deadline && failure.get() == null) Thread.sleep(50);
            require(failure.get() == null, name + " native callback failure: " + failure.get());
            require(a.goodFrames.get() >= 120 && b.goodFrames.get() >= 120,
                    name + " bidirectional tone timeout: A=" + a.summary() + " B=" + b.summary());
            // Over three further seconds the skewed carrier clock must not cost a single frame.
            long[] before = b.carrierCounters();
            int goodA = a.goodFrames.get(), goodB = b.goodFrames.get();
            int analyzedA = a.analyzedFrames.get(), analyzedB = b.analyzedFrames.get();
            Thread.sleep(3000);
            long[] after = b.carrierCounters();
            require(failure.get() == null, name + " native callback failure: " + failure.get());
            require(after[0] == before[0] && after[1] == before[1] && after[2] == before[2] && after[3] == before[3],
                    name + " carrier clock lost audio: before=" + Arrays.toString(before) + " after=" + Arrays.toString(after));
            require(Math.abs((after[4] - before[4]) - (after[5] - before[5])) <= WebRTCPcmBuffer.MAX_FRAMES,
                    name + " capture did not follow the carrier clock: before=" + Arrays.toString(before) + " after=" + Arrays.toString(after));
            int framesA = a.analyzedFrames.get() - analyzedA, framesB = b.analyzedFrames.get() - analyzedB;
            int tonesA = a.goodFrames.get() - goodA, tonesB = b.goodFrames.get() - goodB;
            // Liveness is independent of spectral selectivity. NetEq's clock-skew correction can
            // spread a tone's energy across a 10 ms frame; it must not hide missing PCM callbacks.
            require(framesA >= 250 && framesB >= 250,
                    name + " PCM stopped under the carrier clock: A=" + framesA + " B=" + framesB);
            require(tonesA >= 0.75 * framesA && tonesB >= 0.75 * framesB,
                    name + " spectral tone success below 75%: A=" + tonesA + "/" + framesA + " B=" + tonesB + "/" + framesB
                            + " A{" + a.summary() + "} B{" + b.summary() + "}");
            String astats = stats(a.peer), bstats = stats(b.peer);
            a.requireNoPhysicalAudio(); b.requireNoPhysicalAudio();
            require(a.inputFrames.get() < 3000 && b.inputFrames.get() < 3000, name + " capture busy loop");
            try { a.close(); } finally { b.close(); }
            int[] stoppedA = a.callbackCounters(), stoppedB = b.callbackCounters();
            Thread.sleep(150);
            require(Arrays.equals(a.callbackCounters(), stoppedA) && Arrays.equals(b.callbackCounters(), stoppedB),
                    name + " audio callbacks survived disposal");
            report.append("PASS ").append(name).append(" tones=").append(aTone).append('/').append(bTone)
                    .append("Hz A{").append(a.summary()).append("} B{").append(b.summary()).append("}\n")
                    .append("steady_frames=").append(framesA).append('/').append(framesB)
                    .append(" steady_tones=").append(tonesA).append('/').append(tonesB).append("\n")
                    .append("B_carrier_lost=0 B_carrier_skew=+-2% policy=").append(forceRelay ? "relay" : "all")
                    .append("\nA ").append(astats).append("\nB ").append(bstats)
                    .append("\ncallback_metadata=PCM16/mono/rate_derived/count0 physical_audio=absent cleanup=stopped\n");
            Bundle progress = new Bundle(); progress.putString("stream", report.substring(reportStart)); sendStatus(0, progress);
        } finally { try { a.close(); } finally { b.close(); } }
    }

    /** Spectral energy, rather than zero crossings, distinguishes a high tone from an 8 kHz alias. */
    private static final class ToneDetector {
        final int rate, expected;
        final double[] expectedCoefficients, rejectedCoefficients;
        int peakHz, quietFrames, spreadFrames, aliasFrames;
        ToneDetector(int rate, int expected, int wrongTone) {
            this.rate = rate; this.expected = expected;
            require(expected > 150 && expected + 150 < rate / 2, "tone outside usable Nyquist band");
            expectedCoefficients = coefficients(expected, rate);
            int alias = expected > 4000 ? 8000 - expected : wrongTone;
            rejectedCoefficients = coefficients(alias, rate);
        }
        private static double[] coefficients(int center, int rate) {
            double[] result = new double[13];
            for (int i = 0; i < result.length; i++) result[i] = 2 * Math.cos(2 * Math.PI * (center - 150 + 25 * i) / rate);
            return result;
        }
        private static double energy(byte[] pcm, double coefficient) {
            double previous = 0, previous2 = 0;
            for (int i = 0; i < pcm.length / 2; i++) {
                double value = WebRTCPcmBuffer.sample(pcm, i) + coefficient * previous - previous2;
                previous2 = previous; previous = value;
            }
            return Math.max(0, previous * previous + previous2 * previous2 - coefficient * previous * previous2);
        }
        boolean accepts(byte[] pcm) {
            double square = 0;
            for (int i = 0; i < pcm.length / 2; i++) {
                int value = WebRTCPcmBuffer.sample(pcm, i); square += (double) value * value;
            }
            int samples = pcm.length / 2;
            if (samples == 0 || square / samples <= 100000) { quietFrames++; return false; }
            double wanted = 0, rejected = 0;
            for (int i = 0; i < expectedCoefficients.length; i++) {
                double value = energy(pcm, expectedCoefficients[i]);
                if (value > wanted) { wanted = value; peakHz = expected - 150 + i * 25; }
            }
            for (double coefficient : rejectedCoefficients) rejected = Math.max(rejected, energy(pcm, coefficient));
            // A single tone must explain most signal energy and dominate the wrong/aliased band.
            if (2 * wanted / (samples * square) < 0.55) { spreadFrames++; return false; }
            if (wanted < 10 * rejected) { aliasFrames++; return false; }
            return true;
        }
    }

    private static byte[] toneFrame(PcmFormat format, int tone, long startSample) {
        byte[] pcm = new byte[format.frameBytes()];
        for (int i = 0; i < format.frameSamples(); i++) {
            short value = (short) (8000 * Math.sin(2 * Math.PI * tone * (startSample + i) / format.rate()));
            pcm[i * 2] = (byte) value; pcm[i * 2 + 1] = (byte) (value >> 8);
        }
        return pcm;
    }

    private static void requireDetectorControls() {
        for (int tone : new int[]{5100, 6000}) {
            ToneDetector detector = new ToneDetector(48000, tone, 1000);
            byte[] high = toneFrame(PcmFormat.WIDEBAND, tone, 0);
            require(detector.accepts(high), "detector rejected high-band positive control " + tone);
            require(!detector.accepts(new byte[960]), "detector accepted silence");
            require(!detector.accepts(toneFrame(PcmFormat.WIDEBAND, 1000, 0)), "detector accepted a low tone");
            require(!detector.accepts(toneFrame(PcmFormat.WIDEBAND, 8000 - tone, 0)), "detector accepted an 8k alias");
            // Deliberately pass through an 8 kHz bottleneck without an anti-alias filter. Even its
            // reconstructed high-frequency images must not masquerade as true wideband transport.
            byte[] narrow = toneFrame(PcmFormat.NARROWBAND, tone, 0), reconstructed = new byte[960];
            for (int i = 0; i < 480; i++) {
                reconstructed[2 * i] = narrow[2 * (i / 6)]; reconstructed[2 * i + 1] = narrow[2 * (i / 6) + 1];
            }
            require(!detector.accepts(reconstructed), "detector accepted an 8k downsample/upsample control");
        }
    }

    private final class Endpoint implements AutoCloseable {
        final PcmFormat format;
        final int tone, expected;
        final boolean carrier;
        final ToneDetector detector;
        final WebRTCPcmBuffer capture, playback;
        final WebRTCCaptureClock captureClock;
        volatile boolean carrierRunning;
        final WebRTCPlayoutClock playoutClock;
        final AtomicLong carrierProduced = new AtomicLong(), carrierMissed = new AtomicLong(), detectedHzSum = new AtomicLong();
        Thread carrierIn, carrierOut;
        final AtomicInteger inputFrames = new AtomicInteger(), outputFrames = new AtomicInteger(), goodFrames = new AtomicInteger(), analyzedFrames = new AtomicInteger();
        final List<IceCandidate> candidates = new ArrayList<>();
        JavaAudioDeviceModule adm;
        PeerConnectionFactory factory;
        AudioSource source;
        AudioTrack track;
        PeerConnection peer;
        volatile Endpoint other;
        boolean remote;
        long sample, next;
        Endpoint(PcmFormat format, int tone, int expected, boolean carrier) {
            this.format = format; this.tone = tone; this.expected = expected; this.carrier = carrier;
            detector = new ToneDetector(format.rate(), expected, tone);
            capture = new WebRTCPcmBuffer(format);
            playback = new WebRTCPcmBuffer(format, WebRTCPcmBuffer.NO_AGE_LIMIT);
            captureClock = new WebRTCCaptureClock(capture);
            playoutClock = new WebRTCPlayoutClock(playback, () -> carrierRunning);
        }
        byte[] nextToneFrame() {
            byte[] frame = toneFrame(format, tone, sample); sample += format.frameSamples(); return frame;
        }
        void analyze(byte[] data) {
            analyzedFrames.incrementAndGet();
            if (detector.accepts(data)) { goodFrames.incrementAndGet(); detectedHzSum.addAndGet(detector.peakHz); }
        }
        String summary() {
            int good = goodFrames.get();
            return "rate=" + format.rate() + " frame_bytes=" + format.frameBytes() + " good=" + good
                    + " capture=" + inputFrames + " playout=" + outputFrames
                    + " expected_hz=" + expected + " detected_hz=" + (good == 0 ? 0 : detectedHzSum.get() / good)
                    + " quiet=" + detector.quietFrames + " spread=" + detector.spreadFrames + " wrong_band=" + detector.aliasFrames;
        }
        int[] callbackCounters() { return new int[]{inputFrames.get(), outputFrames.get()}; }
        /** Capture drops, capture concealments, playback drops, carrier misses, carrier frames, WebRTC captures. */
        long[] carrierCounters() {
            return new long[]{capture.drops(), capture.underruns(), playback.drops(), carrierMissed.get(),
                    carrierProduced.get(), inputFrames.get()};
        }
        /** Simulated modem: capture 2% slower and playout 2% faster than WebRTC's 10 ms timer, in 20 ms bursts. */
        void startCarrier() {
            carrierRunning = true;
            carrierIn = new Thread(() -> {
                android.os.Process.setThreadPriority(android.os.Process.THREAD_PRIORITY_URGENT_AUDIO);
                long due = System.nanoTime();
                while (carrierRunning) {
                    due += 20_400_000L;
                    for (long now = System.nanoTime(); now < due && carrierRunning; now = System.nanoTime()) LockSupport.parkNanos(due - now);
                    for (int i = 0; i < 2 && carrierRunning; i++) {
                        byte[] frame = nextToneFrame(); capture.offer(frame, 0, frame.length); carrierProduced.incrementAndGet();
                    }
                }
            }, "test-carrier-capture");
            carrierOut = new Thread(() -> {
                android.os.Process.setThreadPriority(android.os.Process.THREAD_PRIORITY_URGENT_AUDIO);
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
            require(carrierIn == null || !carrierIn.isAlive(), "carrier capture survived disposal");
            require(carrierOut == null || !carrierOut.isAlive(), "carrier playout survived disposal");
        }
        boolean validPlayback(JavaAudioDeviceModule.AudioSamples samples) {
            byte[] data = samples.getData();
            if (!format.matches(samples.getAudioFormat(), samples.getChannelCount(), samples.getSampleRate(), data.length)) {
                failure.compareAndSet(null, "playback metadata mismatch: expected " + format.rate()
                        + "Hz/" + format.frameBytes() + " bytes, got " + samples.getSampleRate() + "Hz/" + data.length + " bytes");
                return false;
            }
            outputFrames.incrementAndGet(); return true;
        }
        final class ClockedSink implements JavaAudioDeviceModule.PlaybackSamplesReadyCallback, ExternalPlayoutClock {
            @Override public boolean awaitPlayoutSlot() throws InterruptedException { return playoutClock.awaitPlayoutSlot(); }
            @Override public void onWebRtcAudioTrackSamplesReady(JavaAudioDeviceModule.AudioSamples samples) {
                if (validPlayback(samples)) playoutClock.accept(samples.getData());
            }
        }
        void start() {
            JavaAudioDeviceModule.Builder builder = JavaAudioDeviceModule.builder(getTargetContext()).setSampleRate(format.rate())
                    .setUseHardwareAcousticEchoCanceler(false).setUseHardwareNoiseSuppressor(false);
            builder.setAudioBufferCallback((buffer, encoding, channels, rate, length, timestamp) -> {
                // The pinned external-capture SDK reports length=0; its direct buffer is the frame.
                if (length != 0 || !WebRTCPcmContract.acceptsCapture(format, buffer, encoding, channels, rate)) {
                    failure.compareAndSet(null, "capture metadata mismatch: expected " + format.rate()
                            + "Hz/" + format.frameBytes() + " bytes, got " + rate + "Hz/" + buffer.capacity() + " bytes, count=" + length);
                    return 0;
                }
                byte[] bytes;
                if (carrier) {
                    try { bytes = captureClock.next(carrierRunning); }
                    catch (InterruptedException ignored) { bytes = new byte[format.frameBytes()]; }
                } else {
                    long now = System.nanoTime(); if (next == 0) next = now;
                    while (now < next) { LockSupport.parkNanos(next - now); now = System.nanoTime(); }
                    next += 10_000_000; if (next < now) next = now + 10_000_000;
                    bytes = nextToneFrame();
                }
                if (!WebRTCPcmContract.copyCapture(format, buffer, encoding, channels, rate, bytes)) {
                    failure.compareAndSet(null, "capture PCM copy failed");
                    WebRTCPcmContract.silence(buffer);
                }
                inputFrames.incrementAndGet(); return 0;
            });
            if (carrier) builder.setPlaybackSamplesReadyCallback(new ClockedSink());
            else builder.setPlaybackSamplesReadyCallback(samples -> { if (validPlayback(samples)) analyze(samples.getData()); });
            adm = builder.createAudioDeviceModule();
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
            require(output.getClass().getName().equals("org.webrtc.audio.WebRtcAudioTrack"), "production playout override not loaded");
            for (java.lang.reflect.Field member : output.getClass().getDeclaredFields()) {
                require(member.getType() != android.media.AudioTrack.class, "physical speaker adapter");
            }
        }
        public synchronized void close() {
            Throwable failure = null;
            try { stopCarrier(); }
            catch (InterruptedException interrupted) { Thread.currentThread().interrupt(); failure = interrupted; }
            catch (Throwable error) { failure = error; }
            List<Runnable> cleanup = new ArrayList<>();
            PeerConnection oldPeer = peer; peer = null;
            AudioTrack oldTrack = track; track = null;
            AudioSource oldSource = source; source = null;
            PeerConnectionFactory oldFactory = factory; factory = null;
            JavaAudioDeviceModule oldAdm = adm; adm = null;
            if (oldPeer != null) { cleanup.add(oldPeer::close); cleanup.add(oldPeer::dispose); }
            if (oldTrack != null) cleanup.add(oldTrack::dispose);
            if (oldSource != null) cleanup.add(oldSource::dispose);
            if (oldFactory != null) cleanup.add(oldFactory::dispose);
            if (oldAdm != null) cleanup.add(oldAdm::release);
            for (Runnable action : cleanup) {
                try { action.run(); }
                catch (Throwable error) { if (failure == null) failure = error; else failure.addSuppressed(error); }
            }
            if (failure != null) throw new AssertionError("endpoint cleanup failed", failure);
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
