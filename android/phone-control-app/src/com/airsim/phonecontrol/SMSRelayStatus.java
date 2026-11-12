package com.airsim.phonecontrol;

/**
 * In-memory diagnostics for the SMS lane, shown in the Android app and {@code /api/sms/status}.
 * Holds only a status code summary and a time; never a sender, number or message text.
 */
final class SMSRelayStatus {
    private static volatile long lastDeliveredAt;
    private static volatile String lastError = "";

    private SMSRelayStatus() {}

    static void delivered(long now) {
        lastDeliveredAt = now;
        lastError = "";
    }

    static void rejected(int status) {
        lastError = "Relay refused one message (HTTP " + status + ")";
    }

    static void failed(int status) {
        lastError = SMSRelayPolicy.describeFailure(status);
    }

    static String lastError() { return lastError; }

    static long lastDeliveredAt() { return lastDeliveredAt; }

    /** One line for the Android status screen. */
    static String summary(boolean cloudEnabled, int cloudPending, long now) {
        if (!cloudEnabled) return "Relay delivery off · SMS reach the iPhone over local VoWLAN only";
        String error = lastError;
        if (cloudPending > 0) {
            return cloudPending + " SMS waiting for Relay" + (error.isEmpty() ? "" : " · " + error);
        }
        long delivered = lastDeliveredAt;
        if (delivered == 0) return "Relay delivery ready · No SMS sent since the Agent started";
        long minutes = Math.max(0, (now - delivered) / 60_000L);
        return "Relay delivery ready · Last SMS sent " + (minutes == 0 ? "just now" : minutes + " min ago");
    }
}
