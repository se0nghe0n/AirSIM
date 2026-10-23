package com.airsim.phonecontrol;

/** NetEq bounds for a voice call. The SDK owns concealment and time scaling. */
final class WebRTCPlayout {
    /** Fifty 20 ms Opus packets, one second. The SDK default of 200 packets is four seconds. */
    static final int JITTER_BUFFER_MAX_PACKETS = 50;
    static final boolean FAST_ACCELERATE = true;

    private WebRTCPlayout() {}
}
