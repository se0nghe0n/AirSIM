package com.airsim.phonecontrol;

import java.io.IOException;
import java.util.function.BooleanSupplier;
import java.util.function.LongSupplier;

/** Bounded startup only. Running audio retains its carrier-clocked blocking I/O. */
final class CarrierStartup {
    static final long ROUTE_TIMEOUT_NANOS = 2_000_000_000L;
    // Initial capture must not hold a verified but stalled device forever; normal reads stay clocked.
    static final long FIRST_CAPTURE_TIMEOUT_NANOS = 2_000_000_000L;
    static final long POLL_NANOS = 10_000_000L;
    interface Transfer { int transfer(byte[] frame, int offset, int length) throws IOException; }
    interface Pause { void pause(long nanos) throws InterruptedException; }

    private final BooleanSupplier closed;
    private final LongSupplier clock;
    private final Pause pause;

    CarrierStartup(BooleanSupplier closed, LongSupplier clock, Pause pause) {
        this.closed = closed; this.clock = clock; this.pause = pause;
    }

    /** The transfer MUST be nonblocking. Only silence is supplied before route verification. */
    boolean verifyRoute(byte[] silence, Transfer write, BooleanSupplier verified)
            throws IOException, InterruptedException {
        long started = clock.getAsLong();
        int offset = 0;
        while (!closed.getAsBoolean()) {
            checkDeadline(started, ROUTE_TIMEOUT_NANOS, "carrier route unverified");
            int count = write.transfer(silence, offset, silence.length - offset);
            validate(count, silence.length - offset, "carrier playback stopped");
            offset = (offset + count) % silence.length;
            if (closed.getAsBoolean()) return false;
            checkDeadline(started, ROUTE_TIMEOUT_NANOS, "carrier route unverified");
            if (verified.getAsBoolean()) return true;
            pause.pause(POLL_NANOS);
        }
        return false;
    }

    /** Assemble one fresh frame without waiting indefinitely for a stalled input. */
    boolean firstCapture(byte[] frame, Transfer read) throws IOException, InterruptedException {
        long started = clock.getAsLong();
        int offset = 0;
        while (!closed.getAsBoolean()) {
            checkDeadline(started, FIRST_CAPTURE_TIMEOUT_NANOS, "carrier capture timeout");
            int count = read.transfer(frame, offset, frame.length - offset);
            validate(count, frame.length - offset, "carrier capture failed");
            offset += count;
            if (closed.getAsBoolean()) return false;
            checkDeadline(started, FIRST_CAPTURE_TIMEOUT_NANOS, "carrier capture timeout");
            if (offset == frame.length) return true;
            pause.pause(POLL_NANOS);
        }
        return false;
    }

    private void checkDeadline(long started, long budget, String reason) throws IOException {
        if (clock.getAsLong() - started >= budget) throw new IOException(reason);
    }

    private static void validate(int count, int remaining, String reason) throws IOException {
        if (count < 0 || count > remaining || (count & 1) != 0) throw new IOException(reason);
    }
}
