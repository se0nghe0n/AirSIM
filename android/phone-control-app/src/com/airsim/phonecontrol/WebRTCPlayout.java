package com.airsim.phonecontrol;

/** NetEq bounds for a voice call. The SDK owns concealment and time scaling. */
final class WebRTCPlayout {
    /** Fifty 20 ms Opus packets, one second. The SDK default of 200 packets is four seconds. */
    static final int JITTER_BUFFER_MAX_PACKETS = 50;
    static final boolean FAST_ACCELERATE = true;
    /** Decoded 10 ms frames queued ahead of the carrier AudioTrack while its clock paces NetEq. */
    static final int CARRIER_QUEUE_FRAMES = 2;
    /** Longest wait for the carrier to take a frame before playout falls back to its own timer. */
    static final long CARRIER_STALL_NANOS = 100_000_000L;

    private WebRTCPlayout() {}
}
