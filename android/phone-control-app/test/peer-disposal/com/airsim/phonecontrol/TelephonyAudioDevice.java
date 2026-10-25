package com.airsim.phonecontrol;

import java.io.Closeable;
import java.util.concurrent.atomic.AtomicInteger;

/** Runtime-only carrier boundary: never acquires a microphone, speaker, or native route. */
final class TelephonyAudioDevice implements Closeable {
    final AtomicInteger closeCalls = new AtomicInteger();
    Runnable duringClose = () -> {};

    TelephonyAudioDevice(WebRTCPcmBuffer capture, WebRTCPcmBuffer playback,
                         Runnable ready, Runnable failed) {}

    void start() { throw new AssertionError("This suite must never start a native audio route"); }

    @Override public void close() {
        closeCalls.incrementAndGet();
        duringClose.run();
    }
}
