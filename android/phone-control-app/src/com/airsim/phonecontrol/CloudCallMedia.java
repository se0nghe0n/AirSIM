package com.airsim.phonecontrol;

/** Cloud call media is WebRTC. The retired PCM pump is not a start path. */
final class CloudCallMedia {
    static final String WEBRTC = "webrtc";

    private CloudCallMedia() {}

    static void start(String mediaTransport, Runnable startWebRTC) {
        if (WEBRTC.equals(mediaTransport)) startWebRTC.run();
    }
}
