package com.airsim.phonecontrol;

/** How to publish a call-state event when the Relay still owns a different call. */
final class CallLifecycleConflict {
    enum Action {
        /** Not an identity conflict the agent can repair. */
        RETHROW,
        /** Discard this event. The Relay call is already terminal. */
        DROP,
        /** End the Relay call, then discard this event. */
        END_THEN_DROP,
        /** End the Relay call, then publish this ringing or connecting event. */
        END_THEN_RETRY,
        /** End the Relay call, publish connecting, then publish this active event. */
        END_OPEN_THEN_RETRY
    }

    private CallLifecycleConflict() {}

    static Action decide(boolean identityMismatch, String candidatePhase,
                         String candidateCallId, String candidateUuid,
                         String stuckCallId, String stuckUuid, String stuckPhase) {
        if (!identityMismatch || stuckCallId == null || stuckCallId.isBlank()
                || stuckUuid == null || stuckUuid.isBlank()) return Action.RETHROW;
        if (stuckCallId.equals(candidateCallId)
                && stuckUuid.equalsIgnoreCase(candidateUuid == null ? "" : candidateUuid)) {
            return Action.RETHROW;
        }
        boolean stuckOpen = !"ended".equals(stuckPhase) && !"failed".equals(stuckPhase);
        if ("ringing".equals(candidatePhase) || "connecting".equals(candidatePhase)) {
            return Action.END_THEN_RETRY;
        }
        if ("active".equals(candidatePhase)) return Action.END_OPEN_THEN_RETRY;
        return stuckOpen ? Action.END_THEN_DROP : Action.DROP;
    }
}
