package com.airsim.phonecontrol;

import java.io.IOException;
import java.util.Arrays;
import java.util.concurrent.locks.LockSupport;
import java.util.function.BooleanSupplier;
import java.util.function.Consumer;
import java.util.function.LongSupplier;

/**
 * Feeds decoded WebRTC audio to the carrier AudioTrack and guards its route. It has no Android
 * types, so these decisions run on the JVM; {@link TelephonyAudioDevice} puts the AudioTrack
 * behind {@link Sink}.
 *
 * WebRTC produces playout frames only while a negotiated peer is playing. A carrier attached before
 * the offer, or kept across a renegotiation, would otherwise get no data for seconds. Android
 * takes a starved AudioTrack off its output and tells audio policy the client stopped; only another
 * write starts it again. So this loop keeps the track fed with silence, and a route that is
 * reported as absent is given a bounded time to return while writes continue.
 */
final class CarrierUplink {
    /** The carrier AudioTrack, reduced to what the loop needs. */
    interface Sink {
        /** {@code AudioDeviceInfo} type of the routed device, or {@link #ROUTE_NONE}. */
        int routedType();
        /** Writes the whole frame, waiting for the carrier clock. */
        void write(byte[] frame) throws IOException;
        /** Writes what fits without waiting and returns the byte count. Restarts a starved track. */
        int writeNow(byte[] frame) throws IOException;
    }

    static final int ROUTE_NONE = -1;
    static final long FRAME_NANOS = 10_000_000L;
    /**
     * Longest wait for a decoded frame before silence is written. NetEq hands over a frame within
     * a few milliseconds of the queue having room, so with playout running this never expires and
     * no silence is added. It is half the 80 ms AudioTrack floor: when it does expire the track
     * still holds about 40 ms, so the track neither underruns nor goes inactive. A longer gap would
     * have underrun the track anyway, so the silence replaces a platform gap instead of adding one.
     */
    static final long FILL_AFTER_NANOS = 40_000_000L;
    /**
     * How long the platform may report no routed device after the route was verified. Starting a
     * starved track again makes audio policy apply its route once more, which is asynchronous and
     * delayed by a fraction of the output latency. 300 ms is the carrier attach retry interval and
     * three times {@link WebRTCPlayout#CARRIER_STALL_NANOS}. At most that much audio is written to a
     * track with no reported device before the peer ends. No other device is ever accepted.
     */
    static final long ROUTE_GRACE_NANOS = 300_000_000L;
    /** At most one silence gap per second is logged; the rest are counted. */
    static final long LOG_INTERVAL_NANOS = 1_000_000_000L;

    private final WebRTCPcmBuffer playback;
    private final Sink sink;
    private final int carrierType;
    private final BooleanSupplier closed;
    private final LongSupplier clock;
    private final Consumer<String> log;
    private boolean filling;
    private long gapStarted;
    private long gapFrames;
    private boolean gapLogged;
    private boolean everLogged;
    private long lastLogged;
    private long skippedGaps;
    private boolean routeMissing;
    private long routeMissingSince;

    CarrierUplink(WebRTCPcmBuffer playback, Sink sink, int carrierType, BooleanSupplier closed,
                  LongSupplier clock, Consumer<String> log) {
        this.playback = playback; this.sink = sink; this.carrierType = carrierType;
        this.closed = closed; this.clock = clock; this.log = log;
    }

    /** Runs on the uplink thread until the device or its queue closes. Failures are fixed phrases. */
    void run() throws IOException, InterruptedException {
        while (!closed.getAsBoolean()) {
            // While filling, the blocking silence write is the clock; only look for a real frame.
            byte[] frame = playback.take(filling ? 0 : FILL_AFTER_NANOS);
            long now = clock.getAsLong();
            if (frame == null) {
                if (closed.getAsBoolean() || playback.isClosed()) return;
                frame = silence(now);
            } else if (filling) {
                resumed(now);
            }
            try { feed(frame, now); } finally { Arrays.fill(frame, (byte) 0); }
        }
    }

    /** One 10 ms frame for a gap. The queue fades the last speech out and the next frame back in. */
    private byte[] silence(long now) {
        if (!filling) {
            filling = true;
            gapStarted = now - FILL_AFTER_NANOS; // The queue was already empty for the whole wait.
            gapFrames = 0;
            gapLogged = !everLogged || now - lastLogged >= LOG_INTERVAL_NANOS;
            if (gapLogged) {
                log.accept("standalone_carrier_silence_started skipped=" + skippedGaps);
                everLogged = true; lastLogged = now; skippedGaps = 0;
            } else {
                skippedGaps++;
            }
        }
        gapFrames++;
        return playback.conceal();
    }

    private void resumed(long now) {
        filling = false;
        if (gapLogged) {
            log.accept("standalone_carrier_silence_stopped gap_ms=" + (now - gapStarted) / 1_000_000L
                    + " frames=" + gapFrames);
        }
    }

    private void feed(byte[] frame, long now) throws IOException {
        int type = sink.routedType();
        if (type == carrierType) {
            routeMissing = false;
            sink.write(frame);
            return;
        }
        // A reported device that is not the carrier is never written to, not even once.
        if (type != ROUTE_NONE) throw new IOException("carrier route changed type " + type);
        if (!routeMissing) {
            routeMissing = true;
            routeMissingSince = now;
        } else if (now - routeMissingSince >= ROUTE_GRACE_NANOS) {
            throw new IOException("carrier route inactive");
        }
        // The write is what restarts a starved track. Never wait on a track without a route: a
        // track that does not restart would hold this thread and the failure above would not come.
        if (sink.writeNow(frame) < frame.length) LockSupport.parkNanos(FRAME_NANOS);
    }
}
