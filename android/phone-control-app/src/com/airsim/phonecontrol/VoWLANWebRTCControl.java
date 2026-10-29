package com.airsim.phonecontrol;

/** VoWLAN signaling stays on the HMAC control link. Audio is WebRTC, not a PCM preface. */
public final class VoWLANWebRTCControl {
    public static final String PATH = "/api/calls/webrtc";
    public static final String STATUS_PATH = PATH + "/status";
    public static final String STOP_PATH = PATH + "/stop";

    private VoWLANWebRTCControl() {}
}
