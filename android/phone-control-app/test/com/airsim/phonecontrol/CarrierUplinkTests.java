package com.airsim.phonecontrol;

import java.io.IOException;
import java.io.ByteArrayOutputStream;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicLong;
import java.util.concurrent.atomic.AtomicReference;

/**
 * The carrier uplink loop against a scripted AudioTrack. The clock is the test's own, advanced by
 * the fake track, so nothing here depends on how precisely this machine sleeps.
 */
public final class CarrierUplinkTests {
    private static final int TELEPHONY = 18; // AudioDeviceInfo.TYPE_TELEPHONY
    private static final int SPEAKER = 2;    // AudioDeviceInfo.TYPE_BUILTIN_SPEAKER

    /** A fake carrier track. Each write is 10 ms of carrier time; hooks script the scenario. */
    private static class Track implements CarrierUplink.Sink {
        final AtomicLong nanos = new AtomicLong(1_000_000_000L);
        final List<byte[]> written = new ArrayList<>();
        final List<byte[]> unrouted = new ArrayList<>();
        final AtomicBoolean closed = new AtomicBoolean();
        final List<String> log = new ArrayList<>();
        volatile int route = TELEPHONY;
        int routeQueries;
        Runnable afterWrite = () -> {};

        @Override public int routedType() { routeQueries++; return route; }
        @Override public int write(byte[] frame, int offset, int length) {
            written.add(Arrays.copyOfRange(frame, offset, offset + length));
            nanos.addAndGet(CarrierUplink.FRAME_NANOS);
            afterWrite.run();
            return length;
        }
        @Override public int writeNow(byte[] frame, int offset, int length) {
            unrouted.add(Arrays.copyOfRange(frame, offset, offset + length));
            nanos.addAndGet(CarrierUplink.FRAME_NANOS);
            afterWrite.run();
            return length;
        }
        CarrierUplink uplink(WebRTCPcmBuffer playback) {
            return new CarrierUplink(playback, this, TELEPHONY, closed::get, nanos::get, log::add);
        }
    }

    public static void main(String[] args) throws Exception {
        gapBeforeFirstFrameKeepsTheTrackFed();
        steadyStateInsertsNothing();
        steadyStateFollowsThePlayoutClock();
        silenceAfterSpeechHasNoStep();
        missingRouteIsToleratedBrieflyThenFails();
        missingRouteThatReturnsKeepsTheCall();
        trackThatTakesNoDataStillFailsInTime();
        otherDeviceFailsAtOnce();
        partialWritesPreserveEverySample();
        partialWritesRecheckTheRoute();
        partialWritesRespectClose();
        invalidWritesFailClosed();
        closeDuringGapExitsCleanly();
        silenceLogIsRateLimited();
        System.out.println("Carrier uplink tests passed");
    }

    /** Carrier attached before the offer: no playout frame exists yet, the track still gets data. */
    private static void gapBeforeFirstFrameKeepsTheTrackFed() throws Exception {
        WebRTCPcmBuffer playback = new WebRTCPcmBuffer(WebRTCPcmBuffer.NO_AGE_LIMIT);
        AtomicBoolean attached = new AtomicBoolean(true);
        WebRTCPlayoutClock playout = new WebRTCPlayoutClock(playback, attached::get);
        Track track = new Track();
        long started = System.nanoTime();
        AtomicLong firstWrite = new AtomicLong();
        track.afterWrite = () -> {
            int count = track.written.size();
            if (count == 1) firstWrite.set(System.nanoTime());
            if (count == 5) {
                // Silence is not carrier progress and must not look like a stall to NetEq's clock.
                require(playback.consumed() == 0, "silence does not count as a consumed playout frame");
                try { require(playout.awaitPlayoutSlot(), "playout is carrier clocked the moment it starts"); }
                catch (InterruptedException error) { throw new AssertionError(error); }
                playout.accept(frame(7000));
            }
            if (count == 6) track.closed.set(true);
        };
        track.uplink(playback).run();
        require(firstWrite.get() - started >= CarrierUplink.FILL_AFTER_NANOS, "silence starts only after the fill threshold");
        require(track.written.size() == 6 && track.unrouted.isEmpty(), "every frame goes to the verified route");
        for (int i = 0; i < 5; i++) require(Arrays.equals(track.written.get(i), new byte[160]), "the gap is fed with silence");
        require(sample(track.written.get(5), 79) == 7000, "the first decoded frame follows the silence");
        require(playback.underruns() == 5 && playback.consumed() == 1, "fill frames are counted apart from playout frames");
        require(track.routeQueries == 6, "the route is checked before every write, silence included");
        require(track.log.equals(List.of("standalone_carrier_silence_started skipped=0",
                "standalone_carrier_silence_stopped gap_ms=90 frames=5")), "the gap is logged with its duration: " + track.log);
    }

    /** With frames always queued, as carrier backpressure keeps them, the loop adds nothing. */
    private static void steadyStateInsertsNothing() throws Exception {
        WebRTCPcmBuffer playback = new WebRTCPcmBuffer(WebRTCPcmBuffer.NO_AGE_LIMIT);
        Track track = new Track();
        int total = 3000; // 30 s of audio
        AtomicInteger next = new AtomicInteger();
        for (int i = 0; i < WebRTCPlayout.CARRIER_QUEUE_FRAMES; i++) playback.offer(frame(next.incrementAndGet()), 0, 160);
        track.afterWrite = () -> {
            if (track.written.size() == total) track.closed.set(true);
            else playback.offer(frame(next.incrementAndGet()), 0, 160);
        };
        track.uplink(playback).run();
        require(track.written.size() == total, "every decoded frame is written");
        for (int i = 0; i < total; i++) require(sample(track.written.get(i), 0) == i + 1, "frames keep their order and content");
        require(playback.underruns() == 0 && playback.drops() == 0 && track.log.isEmpty(), "steady state inserts no silence");
    }

    /** The real playout clock on its own thread: the carrier still paces it and nothing is added. */
    private static void steadyStateFollowsThePlayoutClock() throws Exception {
        WebRTCPcmBuffer playback = new WebRTCPcmBuffer(WebRTCPcmBuffer.NO_AGE_LIMIT);
        WebRTCPlayoutClock playout = new WebRTCPlayoutClock(playback, () -> true);
        Track track = new Track();
        int total = 2000;
        AtomicInteger deepest = new AtomicInteger();
        AtomicReference<Throwable> failure = new AtomicReference<>();
        Thread decoder = new Thread(() -> {
            try {
                for (int i = 1; i <= total; ) {
                    if (!playout.awaitPlayoutSlot()) continue;
                    playout.accept(frame(i++));
                    deepest.accumulateAndGet(playback.size(), Math::max);
                }
            } catch (Throwable error) { failure.set(error); }
        }, "test-playout");
        track.afterWrite = () -> { if (track.written.size() == total) track.closed.set(true); };
        decoder.start();
        track.uplink(playback).run();
        decoder.join(5000);
        require(failure.get() == null && !decoder.isAlive(), "playout finished");
        require(track.written.size() == total, "every decoded frame reaches the carrier");
        for (int i = 0; i < total; i++) require(sample(track.written.get(i), 0) == i + 1, "carrier order follows decode order");
        require(deepest.get() <= WebRTCPlayout.CARRIER_QUEUE_FRAMES && playback.drops() == 0,
                "the carrier clock still paces playout");
        require(playback.underruns() == 0 && track.log.isEmpty(), "running playout gets no silence");
    }

    /** A gap after speech fades out and back in, so the far end hears no click. */
    private static void silenceAfterSpeechHasNoStep() throws Exception {
        WebRTCPcmBuffer playback = new WebRTCPcmBuffer(WebRTCPcmBuffer.NO_AGE_LIMIT);
        Track track = new Track();
        playback.offer(frame(12000), 0, 160);
        track.afterWrite = () -> {
            if (track.written.size() == 4) playback.offer(frame(12000), 0, 160);
            if (track.written.size() == 5) track.closed.set(true);
        };
        track.uplink(playback).run();
        int previous = 12000, step = 0;
        for (byte[] pcm : track.written) {
            for (int i = 0; i < 80; i++) { int value = sample(pcm, i); step = Math.max(step, Math.abs(value - previous)); previous = value; }
        }
        require(step <= 12000 / 40 + 1, "silence joins speech with ramps, largest step " + step);
        require(Arrays.equals(track.written.get(2), new byte[160]) && sample(track.written.get(4), 79) == 12000,
                "the gap is silent and speech returns at its level");
    }

    /** No reported device: writes continue without waiting, and the route must return in time. */
    private static void missingRouteIsToleratedBrieflyThenFails() throws Exception {
        WebRTCPcmBuffer playback = new WebRTCPcmBuffer(WebRTCPcmBuffer.NO_AGE_LIMIT);
        Track track = new Track();
        AtomicInteger next = new AtomicInteger();
        playback.offer(frame(next.incrementAndGet()), 0, 160);
        track.afterWrite = () -> {
            if (track.written.size() == 3) track.route = CarrierUplink.ROUTE_NONE;
            playback.offer(frame(next.incrementAndGet()), 0, 160);
        };
        IOException failure = failure(track.uplink(playback));
        require(failure != null && "carrier route inactive".equals(failure.getMessage()), "a route that stays absent ends the device");
        require("carrier_route_inactive".equals(TelephonyAudioDevice.reason(failure)), "inactive route has its own reason");
        long frames = CarrierUplink.ROUTE_GRACE_NANOS / CarrierUplink.FRAME_NANOS;
        require(track.written.size() == 3 && track.unrouted.size() == frames,
                "exactly the grace period is written without a reported device: " + track.unrouted.size());
        require(sample(track.unrouted.get(0), 0) == 4, "the write that restarts a starved track still happens");
    }

    private static void missingRouteThatReturnsKeepsTheCall() throws Exception {
        WebRTCPcmBuffer playback = new WebRTCPcmBuffer(WebRTCPcmBuffer.NO_AGE_LIMIT);
        Track track = new Track();
        AtomicInteger next = new AtomicInteger();
        track.route = CarrierUplink.ROUTE_NONE; // Starved while nothing was queued, as after a gap.
        playback.offer(frame(next.incrementAndGet()), 0, 160);
        track.afterWrite = () -> {
            int unrouted = track.unrouted.size(), routed = track.written.size();
            // Absent for 290 ms twice with a verified write between: each absence has its own limit.
            if (unrouted == 29 && routed == 0) track.route = TELEPHONY;
            if (routed == 1 && unrouted == 29) track.route = CarrierUplink.ROUTE_NONE;
            if (unrouted == 58) track.route = TELEPHONY;
            if (routed == 10) track.closed.set(true);
            else playback.offer(frame(next.incrementAndGet()), 0, 160);
        };
        require(failure(track.uplink(playback)) == null, "a route that returns within the limit keeps the device");
        require(track.unrouted.size() == 58 && track.written.size() == 10, "audio continues on the returned route");
    }

    /** A track that accepts nothing must not hold the thread past the limit, unlike a blocking write. */
    private static void trackThatTakesNoDataStillFailsInTime() throws Exception {
        WebRTCPcmBuffer playback = new WebRTCPcmBuffer(WebRTCPcmBuffer.NO_AGE_LIMIT);
        AtomicInteger attempts = new AtomicInteger();
        Track track = new Track() {
            @Override public int write(byte[] frame, int offset, int length) { throw new AssertionError("waited on a track without a route"); }
            @Override public int writeNow(byte[] frame, int offset, int length) {
                attempts.incrementAndGet();
                nanos.addAndGet(100_000_000L);
                return 0;
            }
        };
        track.route = CarrierUplink.ROUTE_NONE;
        IOException failure = failure(track.uplink(playback));
        require(failure != null && "carrier route inactive".equals(failure.getMessage()), "a dead track fails closed");
        require(attempts.get() == 3, "the limit is time, not frames accepted: " + attempts.get());
    }

    /** Any reported device other than the carrier ends the device before a single sample is written. */
    private static void otherDeviceFailsAtOnce() throws Exception {
        WebRTCPcmBuffer playback = new WebRTCPcmBuffer(WebRTCPcmBuffer.NO_AGE_LIMIT);
        Track track = new Track();
        playback.offer(frame(1), 0, 160); playback.offer(frame(2), 0, 160);
        track.afterWrite = () -> track.route = SPEAKER;
        IOException failure = failure(track.uplink(playback));
        require(failure != null && "carrier route changed type 2".equals(failure.getMessage()), "another device ends the device");
        require("carrier_route_changed_type_2".equals(TelephonyAudioDevice.reason(failure)), "changed route reports only its type");
        require(track.written.size() == 1 && track.unrouted.isEmpty(), "nothing is written to another device");

        // Also inside the grace period of an absent route, and for silence.
        WebRTCPcmBuffer idle = new WebRTCPcmBuffer(WebRTCPcmBuffer.NO_AGE_LIMIT);
        Track starved = new Track();
        starved.route = CarrierUplink.ROUTE_NONE;
        starved.afterWrite = () -> { if (starved.unrouted.size() == 2) starved.route = SPEAKER; };
        failure = failure(starved.uplink(idle));
        require(failure != null && "carrier route changed type 2".equals(failure.getMessage()), "grace never covers another device");
        require(starved.unrouted.size() == 2 && starved.written.isEmpty(), "no silence is written to another device either");

        String longest = TelephonyAudioDevice.reason(new IOException("carrier route changed type " + Integer.MAX_VALUE));
        require(longest.equals("carrier_route_changed_type_2147483647") && longest.length() <= 48, "reason fits the 48 character limit");
    }

    /** Partial/zero writes never skip or repeat samples, including after the route returns. */
    private static void partialWritesPreserveEverySample() throws Exception {
        for (boolean beginsRouted : new boolean[]{false, true}) {
            WebRTCPcmBuffer playback = new WebRTCPcmBuffer(WebRTCPcmBuffer.NO_AGE_LIMIT);
            byte[] audio = new byte[320];
            for (int i = 0; i < 160; i++) {
                int tone = (int) (12000 * Math.sin(2 * Math.PI * 400 * i / 8000));
                audio[i * 2] = (byte) tone; audio[i * 2 + 1] = (byte) (tone >> 8);
            }
            playback.offer(audio, 0, audio.length);
            ByteArrayOutputStream accepted = new ByteArrayOutputStream();
            AtomicInteger calls = new AtomicInteger();
            Track track = new Track() {
                private int accept(byte[] frame, int offset, int length, boolean blocking) {
                    int call = calls.incrementAndGet();
                    int count = blocking ? Math.min(24, length) : call == 1 ? 0 : Math.min(42, length);
                    accepted.write(frame, offset, count);
                    nanos.addAndGet(CarrierUplink.FRAME_NANOS);
                    if (call == 3) route = TELEPHONY;
                    if (accepted.size() == audio.length) closed.set(true);
                    return count;
                }
                @Override public int write(byte[] frame, int offset, int length) { return accept(frame, offset, length, true); }
                @Override public int writeNow(byte[] frame, int offset, int length) { return accept(frame, offset, length, false); }
            };
            track.route = beginsRouted ? TELEPHONY : CarrierUplink.ROUTE_NONE;
            track.uplink(playback).run();
            require(Arrays.equals(audio, accepted.toByteArray()), "partial writes preserve the synthetic waveform byte for byte");
            require(track.routeQueries == calls.get(), "every partial write has its own route check");
            require(playback.consumed() == 2 && playback.drops() == 0 && playback.underruns() == 0,
                    "partial writes neither discard decoded frames nor insert silence");
        }
    }

    private static void partialWritesRecheckTheRoute() throws Exception {
        for (boolean beginsRouted : new boolean[]{false, true}) {
            WebRTCPcmBuffer playback = new WebRTCPcmBuffer(WebRTCPcmBuffer.NO_AGE_LIMIT);
            playback.offer(frame(1000), 0, 160);
            AtomicInteger accepted = new AtomicInteger();
            Track track = new Track() {
                private int partial() { accepted.addAndGet(20); route = SPEAKER; return 20; }
                @Override public int write(byte[] frame, int offset, int length) { return partial(); }
                @Override public int writeNow(byte[] frame, int offset, int length) { return partial(); }
            };
            track.route = beginsRouted ? TELEPHONY : CarrierUplink.ROUTE_NONE;
            IOException failure = failure(track.uplink(playback));
            require(failure != null && "carrier route changed type 2".equals(failure.getMessage()),
                    "a route change during a partial frame fails closed");
            require(accepted.get() == 20 && track.routeQueries == 2, "no tail is written to a non-carrier device");
        }

        // Progress inside a frame must not restart the absence deadline.
        WebRTCPcmBuffer playback = new WebRTCPcmBuffer(WebRTCPcmBuffer.NO_AGE_LIMIT);
        playback.offer(frame(1000), 0, 160);
        AtomicInteger attempts = new AtomicInteger();
        Track stalled = new Track() {
            @Override public int writeNow(byte[] frame, int offset, int length) {
                attempts.incrementAndGet(); nanos.addAndGet(100_000_000L); return 2;
            }
        };
        stalled.route = CarrierUplink.ROUTE_NONE;
        IOException failure = failure(stalled.uplink(playback));
        require(failure != null && "carrier route inactive".equals(failure.getMessage()) && attempts.get() == 3,
                "partial progress preserves the original 300 ms absence budget");
    }

    private static void partialWritesRespectClose() throws Exception {
        for (boolean deviceFirst : new boolean[]{false, true}) {
            WebRTCPcmBuffer playback = new WebRTCPcmBuffer(WebRTCPcmBuffer.NO_AGE_LIMIT);
            playback.offer(frame(1000), 0, 160);
            AtomicInteger attempts = new AtomicInteger();
            Track track = new Track() {
                @Override public int writeNow(byte[] frame, int offset, int length) {
                    attempts.incrementAndGet();
                    if (deviceFirst) closed.set(true); else playback.close();
                    return 20;
                }
            };
            track.route = CarrierUplink.ROUTE_NONE;
            track.uplink(playback).run();
            require(attempts.get() == 1, "close discards the pending tail without another write");
        }
        WebRTCPcmBuffer playback = new WebRTCPcmBuffer(WebRTCPcmBuffer.NO_AGE_LIMIT);
        playback.offer(frame(1000), 0, 160);
        AtomicInteger attempts = new AtomicInteger();
        Track interrupted = new Track() {
            @Override public int writeNow(byte[] frame, int offset, int length) {
                attempts.incrementAndGet(); Thread.currentThread().interrupt(); return 20;
            }
        };
        interrupted.route = CarrierUplink.ROUTE_NONE;
        try { interrupted.uplink(playback).run(); throw new AssertionError("partial write ignored cancellation"); }
        catch (InterruptedException expected) { require(attempts.get() == 1, "interrupt cancels the pending tail"); }
        finally { Thread.interrupted(); }
    }

    private static void invalidWritesFailClosed() throws Exception {
        for (int count : new int[]{-1, 1, 162}) {
            for (boolean routed : new boolean[]{false, true}) {
                WebRTCPcmBuffer playback = new WebRTCPcmBuffer(WebRTCPcmBuffer.NO_AGE_LIMIT);
                playback.offer(frame(1000), 0, 160);
                Track track = new Track() {
                    @Override public int write(byte[] frame, int offset, int length) { return count; }
                    @Override public int writeNow(byte[] frame, int offset, int length) { return count; }
                };
                track.route = routed ? TELEPHONY : CarrierUplink.ROUTE_NONE;
                IOException failure = failure(track.uplink(playback));
                require(failure != null && "carrier playback stopped".equals(failure.getMessage()),
                        "invalid sample count fails closed: " + count);
            }
        }
    }

    /** Closing while only silence flows: the loop returns, reports nothing and writes nothing more. */
    private static void closeDuringGapExitsCleanly() throws Exception {
        // The peer closes the queue before it closes the device.
        for (boolean deviceFirst : new boolean[]{false, true}) {
            WebRTCPcmBuffer playback = new WebRTCPcmBuffer(WebRTCPcmBuffer.NO_AGE_LIMIT);
            Track track = new Track();
            AtomicReference<Throwable> failure = new AtomicReference<>();
            AtomicBoolean filling = new AtomicBoolean();
            track.afterWrite = () -> {
                if (track.written.size() >= 3) filling.set(true);
                try { Thread.sleep(1); } catch (InterruptedException error) { Thread.currentThread().interrupt(); }
            };
            Thread uplink = new Thread(() -> {
                try { track.uplink(playback).run(); } catch (Throwable error) { failure.set(error); }
            }, "test-uplink");
            uplink.start();
            long deadline = System.nanoTime() + 5_000_000_000L;
            while (!filling.get() && System.nanoTime() < deadline) Thread.sleep(1);
            require(filling.get(), "the gap is being filled");
            if (deviceFirst) track.closed.set(true); else playback.close();
            uplink.join(2000);
            require(!uplink.isAlive() && failure.get() == null, "close during a gap ends the loop without a failure");
            int written = track.written.size();
            Thread.sleep(30);
            require(track.written.size() == written, "nothing is written after close");
        }

        // Closed while still waiting for the first frame, before any silence.
        WebRTCPcmBuffer waiting = new WebRTCPcmBuffer(WebRTCPcmBuffer.NO_AGE_LIMIT);
        Track untouched = new Track();
        waiting.close();
        untouched.uplink(waiting).run();
        require(untouched.written.isEmpty() && untouched.log.isEmpty() && waiting.underruns() == 0, "a closed queue is not a gap");
    }

    private static void silenceLogIsRateLimited() throws Exception {
        WebRTCPcmBuffer playback = new WebRTCPcmBuffer(WebRTCPcmBuffer.NO_AGE_LIMIT);
        Track track = new Track();
        // Speech frames at these positions end a gap; the frames between are silence.
        track.afterWrite = () -> {
            int count = track.written.size();
            if (count == 2 || count == 5 || count == 8) playback.offer(frame(100), 0, 160);
            if (count == 9) track.nanos.addAndGet(CarrierUplink.LOG_INTERVAL_NANOS);
            if (count == 11) playback.offer(frame(100), 0, 160);
            if (count == 12) track.closed.set(true);
        };
        track.uplink(playback).run();
        require(track.log.equals(List.of(
                "standalone_carrier_silence_started skipped=0",
                "standalone_carrier_silence_stopped gap_ms=60 frames=2",
                "standalone_carrier_silence_started skipped=2",
                "standalone_carrier_silence_stopped gap_ms=60 frames=2")), "gaps inside one second are counted, not logged: " + track.log);
    }

    private static IOException failure(CarrierUplink uplink) throws InterruptedException {
        try { uplink.run(); return null; } catch (IOException error) { return error; }
    }

    private static byte[] frame(int value) {
        byte[] pcm = new byte[160];
        for (int i = 0; i < 80; i++) { pcm[i * 2] = (byte) value; pcm[i * 2 + 1] = (byte) (value >> 8); }
        return pcm;
    }

    private static int sample(byte[] pcm, int index) { return WebRTCPcmBuffer.sample(pcm, index); }

    private static void require(boolean value, String message) { if (!value) throw new AssertionError(message); }
}
