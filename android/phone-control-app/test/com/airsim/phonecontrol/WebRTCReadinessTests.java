package com.airsim.phonecontrol;

public final class WebRTCReadinessTests {
    public static void main(String[] args) {
        WebRTCReadiness delayedPCM = new WebRTCReadiness();
        delayedPCM.beginSession("first");
        delayedPCM.connectionChanged("first", true);
        for (int retry = 0; retry < 60; retry++) {
            require(delayedPCM.takeReadySession() == null, "missing PCM must not announce native-only readiness");
        }
        delayedPCM.pcmConnected();
        require("first".equals(delayedPCM.takeReadySession()), "late PCM completes readiness");
        delayedPCM.connectionChanged("first", true);
        delayedPCM.pcmConnected();
        require(delayedPCM.takeReadySession() == null, "duplicate completions emit once");

        WebRTCReadiness pcmFirst = new WebRTCReadiness();
        pcmFirst.pcmConnected();
        require(pcmFirst.takeReadySession() == null, "PCM without negotiation is insufficient");
        pcmFirst.beginSession("first");
        require(pcmFirst.takeReadySession() == null, "PCM before native connection is insufficient");
        pcmFirst.connectionChanged("first", true);
        require("first".equals(pcmFirst.takeReadySession()), "native completion after PCM emits");
        pcmFirst.beginSession("second");
        require(pcmFirst.takeReadySession() == null, "renegotiation clears prior native readiness");
        pcmFirst.connectionChanged("first", true);
        require(pcmFirst.takeReadySession() == null, "old connected callback is fenced");
        pcmFirst.connectionChanged("second", true);
        pcmFirst.connectionChanged("first", false);
        require("second".equals(pcmFirst.takeReadySession()), "old disconnected callback cannot clear current readiness");
        pcmFirst.connectionChanged("second", false);
        pcmFirst.connectionChanged("second", true);
        require(pcmFirst.takeReadySession() == null, "same negotiation reconnect emits once");

        WebRTCReadiness disconnected = new WebRTCReadiness();
        disconnected.beginSession("first");
        disconnected.connectionChanged("first", true);
        disconnected.connectionChanged("first", false);
        disconnected.pcmConnected();
        require(disconnected.takeReadySession() == null, "disconnect before PCM prevents premature readiness");
        disconnected.connectionChanged("first", true);
        require("first".equals(disconnected.takeReadySession()), "reconnect completes still-unannounced negotiation");
        System.out.println("WebRTC readiness tests passed: delayed PCM, reversed completion, stale sessions, once-only, disconnect");
    }
    private static void require(boolean value, String message) { if (!value) throw new AssertionError(message); }
}
