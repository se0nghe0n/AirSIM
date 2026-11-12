package com.airsim.phonecontrol;

/**
 * Incoming SMS delivery to the Relay ({@code POST /v1/events/sms}).
 *
 * <p>SMS runs in its own lane, independent of call events, heartbeats and command polling, so a
 * call event the Relay keeps refusing can never hold received messages back again. Each message
 * is classified by the Relay response alone; message text never reaches this policy.
 */
final class SMSRelayPolicy {
    enum Outcome {
        /** 2xx, including a Relay duplicate: the iPhone push was accepted or already sent. */
        DELIVERED,
        /** The Relay validated and refused this message; resending the same event cannot succeed. */
        REJECTED,
        /** Network, credentials, missing iPhone alert token, rate limit or Relay/APNs failure. */
        RETRY
    }

    static final long BASE_DELAY_MILLIS = 5_000L;
    static final long MAX_DELAY_MILLIS = 300_000L;
    /** Upper bound on how long the lane sleeps without a wake request (inbox fallback cadence). */
    static final long IDLE_WAIT_MILLIS = 30_000L;
    /**
     * UTF-8 budget for the text sent to the Relay. The Relay repeats it in the APNs alert and the
     * payload, and APNs allows 4 KB, so this keeps long Hangul text deliverable even through a
     * Relay that predates payload fitting. The full text stays in the local store for VoWLAN.
     */
    static final int MAX_CLOUD_CONTENT_BYTES = 1_700;
    /** A pass stops after this many consecutive per-message (5xx) failures; the Relay is likely down. */
    static final int MAX_MESSAGE_FAILURES_PER_PASS = 3;

    private SMSRelayPolicy() {}

    /** @param status Relay HTTP status, or 0 when the request did not complete. */
    static Outcome outcome(int status) {
        if (status >= 200 && status < 300) return Outcome.DELIVERED;
        if (status == 400 || status == 413 || status == 422) return Outcome.REJECTED;
        // 401/403 and 404 are configuration (credentials, an older Relay) and must not discard
        // messages; 409 means the iPhone has no alert token yet; 408/429/5xx are transient.
        return Outcome.RETRY;
    }

    /**
     * Whether a RETRY affects every message of this device (network, credentials, missing iPhone
     * token, rate limit), so the pass stops. A 5xx may be specific to one message (for example an
     * APNs refusal), so the pass moves on and that message is retried on the next pass.
     */
    static boolean stopsPass(int status) {
        return status < 500;
    }

    /** Text for the Relay event: at most {@link #MAX_CLOUD_CONTENT_BYTES}, cut on a code point and marked with "…". */
    static String cloudContent(String content) {
        if (content == null) return "";
        if (utf8Length(content) <= MAX_CLOUD_CONTENT_BYTES) return content;
        int budget = MAX_CLOUD_CONTENT_BYTES - 3;
        int bytes = 0;
        int index = 0;
        while (index < content.length()) {
            int codePoint = content.codePointAt(index);
            bytes += utf8Size(codePoint);
            if (bytes > budget) break;
            index += Character.charCount(codePoint);
        }
        return content.substring(0, index) + "…";
    }

    static int utf8Length(String value) {
        int bytes = 0;
        for (int index = 0; index < value.length(); ) {
            int codePoint = value.codePointAt(index);
            bytes += utf8Size(codePoint);
            index += Character.charCount(codePoint);
        }
        return bytes;
    }

    private static int utf8Size(int codePoint) {
        return codePoint < 0x80 ? 1 : codePoint < 0x800 ? 2 : codePoint < 0x10000 ? 3 : 4;
    }

    /**
     * The carrier (SMSC) time can run ahead of the phone when the carrier's zone is wrong; the
     * Relay refuses timestamps more than 5 minutes in the future. Send at most "now". The delivery
     * ID, derived from the original time, is unchanged.
     */
    static String cloudTimestamp(String stored, long nowMillis) {
        try {
            java.time.Instant parsed = java.time.Instant.parse(stored);
            return parsed.toEpochMilli() > nowMillis
                    ? java.time.Instant.ofEpochMilli(nowMillis).toString() : stored;
        } catch (RuntimeException invalid) {
            return java.time.Instant.ofEpochMilli(nowMillis).toString();
        }
    }

    /** 5 s, 10 s, 20 s ... capped at 5 minutes. A newly received SMS still triggers one attempt. */
    static long retryDelayMillis(int consecutiveFailures) {
        int exponent = Math.max(0, Math.min(consecutiveFailures - 1, 6));
        return Math.min(MAX_DELAY_MILLIS, BASE_DELAY_MILLIS << exponent);
    }

    /** Short, user-facing reason without Relay bodies, numbers or message text. */
    static String describeFailure(int status) {
        return switch (status) {
            case 0 -> "Relay unreachable";
            case 401, 403 -> "Relay rejected this device (HTTP " + status + "); pair the iPhone again";
            case 404 -> "Relay does not accept SMS events (HTTP 404)";
            case 409 -> "iPhone notification token is not registered (HTTP 409); "
                    + "open AirSIM on the iPhone with cloud mode and notifications enabled";
            case 429 -> "Relay rate limited (HTTP 429)";
            default -> status >= 500 ? "Relay or APNs failure (HTTP " + status + ")"
                    : "Relay HTTP " + status;
        };
    }
}
