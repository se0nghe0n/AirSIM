package com.airsim.phonecontrol;

import java.util.function.BooleanSupplier;
import java.util.function.LongSupplier;

/** Drain a ready signaling burst without changing idle polling or unbounding one worker turn. */
final class WebRTCSignalDrain {
    static final int MAX_EVENTS = 8;
    static final long TURN_NANOS = 8_000_000L;
    static final long POLL_INTERVAL_MILLIS = 40;

    interface Poll { boolean forwardOne() throws Exception; }

    static int run(Poll poll, BooleanSupplier closed, LongSupplier clock) throws Exception {
        long started = clock.getAsLong();
        int forwarded = 0;
        while (!closed.getAsBoolean() && forwarded < MAX_EVENTS) {
            if (!poll.forwardOne()) break;
            forwarded++;
            // Check between operations: a single IPC/network operation can itself take longer.
            if (clock.getAsLong() - started >= TURN_NANOS) break;
        }
        return forwarded;
    }

    private WebRTCSignalDrain() {}
}
