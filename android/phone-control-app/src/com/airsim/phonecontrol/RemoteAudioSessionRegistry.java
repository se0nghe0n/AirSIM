package com.airsim.phonecontrol;

public final class RemoteAudioSessionRegistry {
    private static boolean vowlan;

    private RemoteAudioSessionRegistry() {}

    public static synchronized void setVoWLAN(boolean active) {
        vowlan = active;
        AirSIMInCallService.refreshAudioPolicy();
    }

    public static synchronized boolean active() { return vowlan; }
}
