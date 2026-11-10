package com.airsim.phonecontrol;

import java.util.regex.Pattern;

/** How to publish a call-state event when the Relay still owns a different call. */
final class CallLifecycleConflict {
    private static final Pattern MISSING_CALL_RECORD =
            Pattern.compile("\"reason\"\\s*:\\s*\"call_identity_mismatch\"");

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

    /**
     * The Relay answers a terminal call-state with {@code 409 call_identity_mismatch} when it holds
     * no matching call record: the record expired (5 h), was never created, or belongs to another
     * generation. Nothing remains to end, and resending the event can never succeed.
     */
    static boolean obsoleteTerminal(String phase, int status, String responseDetail) {
        return ("ended".equals(phase) || "failed".equals(phase)) && status == 409
                && responseDetail != null && MISSING_CALL_RECORD.matcher(responseDetail).find();
    }

    /**
     * A Relay 4xx that resending the same call event cannot change. Credentials (401/403), an
     * older Relay (404), timeouts (408) and rate limits (429) stay retryable, as do 5xx and network
     * failures.
     */
    static boolean permanentRejection(int status) {
        return status >= 400 && status < 500
                && status != 401 && status != 403 && status != 404 && status != 408 && status != 429;
    }

    /** How long a queued call event may keep being refused before it stops blocking the queue. */
    static final long REJECTED_EVENT_GRACE_MILLIS = 30_000L;

    /**
     * Whether the head call event should leave the queue. Each retry carries a fresh timestamp, so
     * a refusal caused by clock skew ({@code stale_timestamp}) or a conflict another client clears
     * may still succeed briefly; after the grace period the event is dropped so later events flow.
     */
    static boolean dropRejectedEvent(int status, long firstRejectedAtMillis, long nowMillis) {
        return permanentRejection(status)
                && (nowMillis < firstRejectedAtMillis
                    || nowMillis - firstRejectedAtMillis >= REJECTED_EVENT_GRACE_MILLIS);
    }
}
