package com.airsim.phonecontrol;

final class PrivilegedBridgeCoordinator {
    interface Transport {
        String startBridge() throws Exception;
        String status() throws Exception;
        String setLocalOutputMuted(boolean muted) throws Exception;
    }

    private Transport transport;
    private boolean desiredMuted;
    private boolean hasMuteIntent;
    private String lastResult = "disconnected";
    private String lastBridgeStatus = "disconnected";

    synchronized void connect(Transport value) throws Exception {
        transport = value;
        lastBridgeStatus = value.startBridge();
        lastResult = lastBridgeStatus;
        if (hasMuteIntent) lastResult = value.setLocalOutputMuted(desiredMuted);
    }

    synchronized void disconnect() {
        transport = null;
        lastResult = "disconnected";
        lastBridgeStatus = "disconnected";
    }

    synchronized void setLocalOutputMuted(boolean muted) throws Exception {
        desiredMuted = muted;
        hasMuteIntent = hasMuteIntent || muted;
        if (transport != null && hasMuteIntent) {
            lastResult = transport.setLocalOutputMuted(muted);
        }
    }

    synchronized boolean desiredMuted() {
        return desiredMuted;
    }

    synchronized String lastResult() {
        return lastResult;
    }

    synchronized String refreshStatus() throws Exception {
        if (transport != null) {
            lastBridgeStatus = transport.status();
            lastResult = lastBridgeStatus;
        }
        return lastResult;
    }

    /** Fresh admission readiness; a cached UI status must not authorize another call. */
    synchronized boolean mediaAvailable() {
        if (transport == null) return false;
        try { return PCMBridgeStatus.isRunning(refreshStatus()); }
        catch (Exception error) {
            // Fail closed for admission, but retain the transport for owner poll/stop and recovery.
            lastBridgeStatus = "media=unavailable";
            lastResult = lastBridgeStatus;
            return false;
        }
    }

    synchronized boolean bridgeRunning() {
        return PCMBridgeStatus.isRunning(lastBridgeStatus);
    }
}
