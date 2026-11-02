/*
 * AirSIM extension for the external playout adapter in WebRtcAudioTrack.java.
 * Not part of the upstream WebRTC SDK.
 */
package org.webrtc.audio;

/**
 * Implemented by a {@link JavaAudioDeviceModule.PlaybackSamplesReadyCallback} whose sink has its
 * own device clock. Pulling decoded audio at that clock, instead of a free-running 10 ms timer,
 * keeps the sink from slowly starving or overflowing.
 */
public interface ExternalPlayoutClock {
    /**
     * Blocks until the sink can take another 10 ms frame. Returns false when no device clock is
     * attached or it stalled; the adapter then paces playout itself.
     */
    boolean awaitPlayoutSlot() throws InterruptedException;
}
