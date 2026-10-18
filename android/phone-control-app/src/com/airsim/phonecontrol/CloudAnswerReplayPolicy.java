package com.airsim.phonecontrol;

/** Only pending answer confirmation is retryable; completed actions stay idempotent. */
final class CloudAnswerReplayPolicy {
    private CloudAnswerReplayPolicy() {}

    static boolean isFinal(String action, boolean success, String error) {
        if (success || !"answer".equals(action)) return true;
        // A dialing outgoing call and a media session that has not yet learned
        // its Telecom id must be checked again. A mismatched call id stays final.
        return !"Telecom state confirmation timeout".equals(error)
                && !"cloud call not bound".equals(error)
                && !"active call id mismatch".equals(error);
    }
}
