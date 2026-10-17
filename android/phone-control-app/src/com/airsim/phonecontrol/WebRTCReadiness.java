package com.airsim.phonecontrol;

/** Signaling-executor confined gate: a negotiation is usable only after both paths are ready. */
final class WebRTCReadiness {
    private String sessionID = "";
    private String connectedSessionID = "";
    private boolean pcmReady;
    private boolean emitted;

    void beginSession(String id) {
        sessionID = id;
        connectedSessionID = "";
        emitted = false;
        // The same PCM connection survives renegotiation of this owning call socket.
    }

    void connectionChanged(String id, boolean connected) {
        if (sessionID.equals(id)) connectedSessionID = connected ? id : "";
    }

    void pcmConnected() { pcmReady = true; }

    String takeReadySession() {
        if (emitted || !pcmReady || sessionID.isEmpty() || !sessionID.equals(connectedSessionID)) return null;
        emitted = true;
        return sessionID;
    }
}
