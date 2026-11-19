package com.airsim.phonecontrol;

public final class PreparationFailureTests {
    public static void main(String[] args) {
        for (String reason : new String[] { "call_busy", "default_dialer_required", "media_unavailable",
                "invalid_preparation", "reservation_replayed", "reservation_storage_failed" }) {
            if (!reason.equals(PreparationFailure.reason(new IllegalStateException(reason))))
                throw new AssertionError(reason);
        }
        for (Exception error : new Exception[] { new Exception(), new Exception("private exception details") }) {
            if (!"pre_dial_unavailable".equals(PreparationFailure.reason(error)))
                throw new AssertionError("untrusted error must not escape");
        }
        System.out.println("PreparationFailureTests passed");
    }
}
