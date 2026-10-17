package com.airsim.phonecontrol;

/** Tracks whether a remote PCM owner has actually completed its handshake. */
public final class RemoteAudioSessionRegistry {
    private static boolean vowlan;

    private RemoteAudioSessionRegistry() {}

    public static synchronized void setVoWLAN(boolean active) {
        vowlan = active;
        AirSIMInCallService.refreshAudioPolicy();
    }

    public static synchronized boolean active() { return vowlan; }

    static synchronized void resetForTests() { vowlan = false; }
}
