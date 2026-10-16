package com.airsim.phonecontrol;

/** Only pending answer confirmation is retryable; completed actions stay idempotent. */
final class CloudAnswerReplayPolicy {
    private CloudAnswerReplayPolicy() {}

    static boolean isFinal(String action, boolean success, String error) {
        return success || !"answer".equals(action)
                || !"Telecom state confirmation timeout".equals(error);
    }
}
