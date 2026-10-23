package com.airsim.phonecontrol;

public final class NotificationUpdateGateTests {
    public static void main(String[] args) {
        NotificationUpdateGate gate = new NotificationUpdateGate();
        assertTrue(gate.shouldPublish("Waiting for pairing", 1_000L), "first notification must publish");
        gate.published("Waiting for pairing", 1_000L);
        assertFalse(gate.shouldPublish("Waiting for pairing", 3_000L), "unchanged 2-second update must be skipped");
        assertFalse(gate.shouldPublish("Waiting for pairing", 6_000L), "unchanged 5-second update must be skipped");
        assertTrue(gate.shouldPublish("Relay connected", 6_001L), "changed state must publish immediately");
        // If NotificationManager.notify fails, the caller does not mark it published.
        assertTrue(gate.shouldPublish("Relay connected", 6_002L), "failed publish must retry");
        gate.published("Relay connected", 6_002L);
        assertFalse(gate.shouldPublish("Relay connected", 66_001L), "refresh must not be early");
        assertTrue(gate.shouldPublish("Relay connected", 66_002L), "unchanged foreground state needs periodic refresh");
        gate.published("Relay connected", 66_002L);
        assertTrue(gate.shouldPublish("Relay connected", 500L), "clock rollback must not suppress updates");
        System.out.println("NotificationUpdateGateTests passed");
    }

    private static void assertTrue(boolean value, String message) {
        if (!value) throw new AssertionError(message);
    }

    private static void assertFalse(boolean value, String message) {
        if (value) throw new AssertionError(message);
    }
}
