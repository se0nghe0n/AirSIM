package com.airsim.phonecontrol;

import java.util.concurrent.locks.LockSupport;

/**
 * Clocks WebRTC's capture thread from the carrier AudioRecord. A 10 ms timer of our own would
 * drift against the modem clock and periodically add or drop 10 ms, which the iPhone hears as a
 * pop. The timer is kept only before the carrier is attached and while it stalls.
 */
final class WebRTCCaptureClock {
    static final long FRAME_NANOS = 10_000_000L;
    /**
     * Carrier capture normally arrives every 20 to 40 ms. Only a much longer gap is a stall: a false
     * stall would itself conceal 10 ms. During a real one the iPhone's NetEq conceals the gap.
     */
    static final long STALL_NANOS = 100_000_000L;
    private final WebRTCPcmBuffer source;
    private boolean deviceClocked;
    private long deadline;

    WebRTCCaptureClock(WebRTCPcmBuffer source) { this.source = source; }

    /** Next 10 ms frame. Called only from WebRTC's capture thread. */
    byte[] next(boolean carrierReady) throws InterruptedException {
        if (carrierReady) {
            long wait = deviceClocked ? STALL_NANOS : Math.max(0, deadline - System.nanoTime());
            byte[] frame = source.take(wait);
            if (frame != null) {
                deviceClocked = true;
                return frame;
            }
            if (deviceClocked) {
                // Conceal the stall now, then keep a 10 ms cadence until carrier frames return.
                deviceClocked = false;
                deadline = System.nanoTime();
            }
        } else {
            deviceClocked = false;
        }
        pace();
        return carrierReady ? source.conceal() : new byte[WebRTCPcmBuffer.FRAME_BYTES];
    }

    boolean deviceClocked() { return deviceClocked; }

    private void pace() {
        long now = System.nanoTime();
        // Never replay a backlog of timer ticks after the thread was suspended.
        if (deadline == 0 || now - deadline > FRAME_NANOS) deadline = now;
        while (now < deadline) {
            LockSupport.parkNanos(deadline - now);
            now = System.nanoTime();
        }
        deadline += FRAME_NANOS;
    }
}
