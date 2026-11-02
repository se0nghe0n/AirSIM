package com.airsim.phonecontrol;

import java.io.Closeable;
import java.util.function.Consumer;
import java.util.concurrent.atomic.AtomicInteger;

/** Runtime-only carrier boundary: never acquires a microphone, speaker, or native route. */
final class TelephonyAudioDevice implements Closeable {
    /** Tests opt in explicitly; by default a native route start is a test failure. */
    static volatile Consumer<TelephonyAudioDevice> onStart =
            device -> { throw new AssertionError("This suite must never start a native audio route"); };
    final AtomicInteger closeCalls = new AtomicInteger();
    Runnable duringClose = () -> {};
    final Runnable ready;
    final Runnable failed;
    volatile String failureReason = "carrier_route_unverified";

    TelephonyAudioDevice(WebRTCPcmBuffer capture, WebRTCPcmBuffer playback,
                         Runnable ready, Runnable failed) {
        this.ready = ready;
        this.failed = failed;
    }

    void start() { onStart.accept(this); }

    String failureReason() { return failureReason; }

    int playbackUnderruns() { return -1; }

    @Override public void close() {
        closeCalls.incrementAndGet();
        duringClose.run();
    }
}
