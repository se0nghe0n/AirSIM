package com.airsim.phonecontrol;

import java.util.function.BooleanSupplier;
import org.webrtc.audio.ExternalPlayoutClock;

/**
 * Lets the carrier AudioTrack, not a free-running 10 ms timer, decide when NetEq decodes the next
 * frame. A timer drifts against the modem clock, so the carrier would periodically starve or the
 * queue would drop audio, both heard by the far end as a pop.
 */
final class WebRTCPlayoutClock implements ExternalPlayoutClock {
    private final WebRTCPcmBuffer sink;
    private final BooleanSupplier attached;
    private boolean stalled; // Playout thread only.
    private long consumedAtStall;

    WebRTCPlayoutClock(WebRTCPcmBuffer sink, BooleanSupplier attached) {
        this.sink = sink; this.attached = attached;
    }

    @Override public boolean awaitPlayoutSlot() throws InterruptedException {
        if (!attached.getAsBoolean()) {
            stalled = false;
            return false;
        }
        // While the carrier is stuck the timer runs and the full queue drops its oldest frame.
        // Return to the device clock once the carrier takes a frame again.
        if (stalled && sink.consumed() == consumedAtStall) return false;
        stalled = false;
        if (sink.awaitCapacity(WebRTCPlayout.CARRIER_QUEUE_FRAMES, WebRTCPlayout.CARRIER_STALL_NANOS)) return true;
        stalled = true;
        consumedAtStall = sink.consumed();
        return false;
    }

    /** Queues decoded audio only while the carrier is attached. */
    void accept(byte[] pcm) {
        if (attached.getAsBoolean()) sink.offer(pcm, 0, pcm.length);
    }
}
