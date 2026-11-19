package com.airsim.phonecontrol;

final class PreparationFailure {
    static String reason(Exception error) {
        String reason = error.getMessage();
        if (reason == null) return "pre_dial_unavailable";
        return switch (reason) {
            case "call_busy", "default_dialer_required", "media_unavailable", "invalid_preparation",
                    "reservation_replayed", "reservation_storage_failed" -> reason;
            default -> "pre_dial_unavailable";
        };
    }
}
