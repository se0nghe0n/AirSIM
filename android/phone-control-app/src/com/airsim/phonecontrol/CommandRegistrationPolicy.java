package com.airsim.phonecontrol;

/** Fences command work by cloud ownership, without coupling it to push/telemetry changes. */
final class CommandRegistrationPolicy {
    private boolean enabled;
    private String relay = "";
    private String device = "";
    private String secret = "";
    private long generation;

    synchronized boolean update(boolean nextEnabled, String nextRelay, String nextDevice, String nextSecret) {
        if (!nextEnabled) {
            nextRelay = "";
            nextDevice = "";
            nextSecret = "";
        }
        if (enabled == nextEnabled && relay.equals(nextRelay) && device.equals(nextDevice)
                && secret.equals(nextSecret)) return false;
        enabled = nextEnabled;
        relay = nextRelay;
        device = nextDevice;
        secret = nextSecret;
        generation++;
        return true;
    }

    synchronized long generation() { return generation; }

    synchronized boolean isCurrent(long candidate) { return enabled && candidate == generation; }
}
