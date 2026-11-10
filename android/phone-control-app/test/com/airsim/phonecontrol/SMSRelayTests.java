package com.airsim.phonecontrol;

import java.nio.charset.StandardCharsets;
import java.util.Arrays;

/** SMS relay lane, call-event queue and MMS text rules; no network, provider or device access. */
public final class SMSRelayTests {
    private static int checks;

    public static void main(String[] args) {
        relayOutcomesNeverDiscardRetryableMessages();
        retryDelayBacksOffAndCaps();
        failureSummariesCarryNoMessageData();
        terminalEventForAMissingRelayCallIsObsolete();
        permanentCallEventRejectionsLeaveTheQueue();
        mmsRowsWaitForDownloadAndParts();
        cloudEventStaysDeliverable();
        mmsSenderAndTextFollowThePduFields();
        mmsCharsetsDecodeKoreanText();
        System.out.println("SMS relay tests passed (" + checks + " checks)");
    }

    private static void relayOutcomesNeverDiscardRetryableMessages() {
        check(SMSRelayPolicy.outcome(202) == SMSRelayPolicy.Outcome.DELIVERED);
        check(SMSRelayPolicy.outcome(200) == SMSRelayPolicy.Outcome.DELIVERED);
        for (int status : new int[]{400, 413, 422}) {
            check(SMSRelayPolicy.outcome(status) == SMSRelayPolicy.Outcome.REJECTED);
        }
        // Missing alert token, credentials, older Relay, rate limit, APNs/Relay failure, network.
        for (int status : new int[]{0, 401, 403, 404, 408, 409, 429, 500, 502, 503}) {
            check(SMSRelayPolicy.outcome(status) == SMSRelayPolicy.Outcome.RETRY);
        }
    }

    private static void retryDelayBacksOffAndCaps() {
        check(SMSRelayPolicy.retryDelayMillis(1) == 5_000L);
        check(SMSRelayPolicy.retryDelayMillis(2) == 10_000L);
        check(SMSRelayPolicy.retryDelayMillis(4) == 40_000L);
        check(SMSRelayPolicy.retryDelayMillis(7) == 300_000L);
        check(SMSRelayPolicy.retryDelayMillis(1_000) == 300_000L);
        check(SMSRelayPolicy.retryDelayMillis(0) == 5_000L);
    }

    private static void failureSummariesCarryNoMessageData() {
        SMSRelayStatus.failed(409);
        check(SMSRelayStatus.lastError().contains("notification token"));
        check(SMSRelayStatus.summary(true, 3, 0).startsWith("3 SMS waiting for Relay"));
        check(SMSRelayStatus.summary(true, 3, 0).contains("HTTP 409"));
        check(SMSRelayStatus.summary(false, 3, 0).startsWith("Relay delivery off"));
        SMSRelayStatus.delivered(1_000_000L);
        check(SMSRelayStatus.lastError().isEmpty());
        check(SMSRelayStatus.summary(true, 0, 1_000_000L + 5 * 60_000L).endsWith("5 min ago"));
        check(SMSRelayPolicy.describeFailure(0).equals("Relay unreachable"));
        check(SMSRelayPolicy.describeFailure(503).contains("HTTP 503"));
    }

    private static void terminalEventForAMissingRelayCallIsObsolete() {
        String missing = "Relay HTTP 409: {\"accepted\":false,\"reason\":\"call_identity_mismatch\"}";
        check(CallLifecycleConflict.obsoleteTerminal("ended", 409, missing));
        check(CallLifecycleConflict.obsoleteTerminal("failed", 409, missing));
        // A non-terminal event conflicts with a stuck call; that is repaired, not dropped here.
        check(!CallLifecycleConflict.obsoleteTerminal("active", 409, missing));
        check(!CallLifecycleConflict.obsoleteTerminal("ended", 503, missing));
        check(!CallLifecycleConflict.obsoleteTerminal("ended", 409,
                "Relay HTTP 409: {\"accepted\":false,\"reason\":\"identity_mismatch\",\"lifecycle\":{}}"));
        check(!CallLifecycleConflict.obsoleteTerminal("ended", 409, null));
    }

    private static void permanentCallEventRejectionsLeaveTheQueue() {
        for (int status : new int[]{400, 409, 410, 413, 422}) {
            check(CallLifecycleConflict.permanentRejection(status));
        }
        for (int status : new int[]{0, 200, 401, 403, 404, 408, 429, 500, 502, 503}) {
            check(!CallLifecycleConflict.permanentRejection(status));
        }
        // A refused event gets a short grace period (fresh timestamps may cure clock skew), then
        // leaves the queue; transient failures never do.
        long first = 1_000_000L;
        check(!CallLifecycleConflict.dropRejectedEvent(409, first, first));
        check(!CallLifecycleConflict.dropRejectedEvent(409, first, first + 29_999));
        check(CallLifecycleConflict.dropRejectedEvent(409, first, first + 30_000));
        check(CallLifecycleConflict.dropRejectedEvent(400, first, first - 1));
        check(!CallLifecycleConflict.dropRejectedEvent(503, first, first + 3_600_000));
        check(!CallLifecycleConflict.dropRejectedEvent(401, first, first + 3_600_000));
    }

    private static void mmsRowsWaitForDownloadAndParts() {
        long now = 10_000_000L;
        int notification = MMSInboxPolicy.MESSAGE_TYPE_NOTIFICATION_IND;
        int retrieved = MMSInboxPolicy.MESSAGE_TYPE_RETRIEVE_CONF;
        // Waits count from when the scanner first saw the row, never from the MMSC date.
        check(MMSInboxPolicy.step(retrieved, true, now, now) == MMSInboxPolicy.Step.QUEUE);
        // Undownloaded rows hold the cursor briefly, then are skipped so later MMS still flow.
        check(MMSInboxPolicy.step(notification, false, now - 60_000, now) == MMSInboxPolicy.Step.WAIT);
        check(MMSInboxPolicy.step(notification, false, now - 11 * 60_000, now) == MMSInboxPolicy.Step.SKIP);
        // Parts may be written just after the message row; image-only messages are skipped later.
        check(MMSInboxPolicy.step(retrieved, false, now, now) == MMSInboxPolicy.Step.WAIT);
        check(MMSInboxPolicy.step(retrieved, false, now - 5_000, now) == MMSInboxPolicy.Step.WAIT);
        check(MMSInboxPolicy.step(retrieved, false, now - 2 * 60_000, now) == MMSInboxPolicy.Step.SKIP);
        // A first-seen time ahead of the clock (clock stepped back) waits, but never forever.
        check(MMSInboxPolicy.step(retrieved, false, now + 3_600_000, now) == MMSInboxPolicy.Step.WAIT);
        check(MMSInboxPolicy.step(0x80, true, now, now) == MMSInboxPolicy.Step.SKIP);
    }

    private static void cloudEventStaysDeliverable() {
        check(SMSRelayPolicy.cloudContent("Code 123456").equals("Code 123456"));
        check(SMSRelayPolicy.cloudContent(null).isEmpty());
        String ascii = "x".repeat(SMSRelayPolicy.MAX_CLOUD_CONTENT_BYTES);
        check(SMSRelayPolicy.cloudContent(ascii).equals(ascii));
        // 1,000 Hangul syllables (3 bytes each) as in a long LMS: cut on a character, marked.
        String hangul = "\uAC00".repeat(1_000);
        String cut = SMSRelayPolicy.cloudContent(hangul);
        check(cut.endsWith("\u2026"));
        check(SMSRelayPolicy.utf8Length(cut) <= SMSRelayPolicy.MAX_CLOUD_CONTENT_BYTES);
        check(hangul.startsWith(cut.substring(0, cut.length() - 1)));
        // Surrogate pairs are never split.
        String emoji = "\uD83D\uDE00".repeat(600);
        String emojiCut = SMSRelayPolicy.cloudContent(emoji);
        check(!Character.isHighSurrogate(emojiCut.charAt(emojiCut.length() - 2)));
        check(SMSRelayPolicy.utf8Length(emojiCut) <= SMSRelayPolicy.MAX_CLOUD_CONTENT_BYTES);

        long now = java.time.Instant.parse("2026-11-10T05:00:00Z").toEpochMilli();
        check(SMSRelayPolicy.cloudTimestamp("2026-11-10T04:59:00Z", now).equals("2026-11-10T04:59:00Z"));
        check(SMSRelayPolicy.cloudTimestamp("2026-11-10T09:00:00Z", now).equals("2026-11-10T05:00:00Z"));
        check(SMSRelayPolicy.cloudTimestamp("not a time", now).equals("2026-11-10T05:00:00Z"));

        // Device-wide failures end a pass; a 5xx may be one message, so the pass moves on.
        for (int status : new int[]{0, 401, 403, 404, 408, 409, 429}) check(SMSRelayPolicy.stopsPass(status));
        for (int status : new int[]{500, 502, 503}) check(!SMSRelayPolicy.stopsPass(status));
    }

    private static void mmsSenderAndTextFollowThePduFields() {
        check(MMSInboxPolicy.isSenderAddress(MMSInboxPolicy.ADDRESS_TYPE_FROM, "15880000"));
        check(!MMSInboxPolicy.isSenderAddress(0x97, "15880000"));
        check(!MMSInboxPolicy.isSenderAddress(MMSInboxPolicy.ADDRESS_TYPE_FROM, "insert-address-token"));
        check(!MMSInboxPolicy.isSenderAddress(MMSInboxPolicy.ADDRESS_TYPE_FROM, " "));
        check(MMSInboxPolicy.isTextPart("text/plain"));
        check(MMSInboxPolicy.isTextPart("Text/Plain; charset=utf-8"));
        check(!MMSInboxPolicy.isTextPart("application/smil"));
        check(!MMSInboxPolicy.isTextPart(null));
        check(MMSInboxPolicy.joinText(Arrays.asList("first", null, " ", "second")).equals("first\nsecond"));
        check(MMSInboxPolicy.joinText(java.util.List.of()).isEmpty());
    }

    private static void mmsCharsetsDecodeKoreanText() {
        String korean = "\uC548\uB155\uD558\uC138\uC694";
        check(MMSInboxPolicy.charset(106).equals(StandardCharsets.UTF_8));
        check(MMSInboxPolicy.charset(999_999).equals(StandardCharsets.UTF_8));
        check(new String(korean.getBytes(StandardCharsets.UTF_8), MMSInboxPolicy.charset(106)).equals(korean));
        byte[] eucKR = korean.getBytes(java.nio.charset.Charset.forName("EUC-KR"));
        check(new String(eucKR, MMSInboxPolicy.charset(38)).equals(korean));
        check(new String(korean.getBytes(StandardCharsets.UTF_16BE), MMSInboxPolicy.charset(1000)).equals(korean));
    }

    private static void check(boolean value) {
        if (!value) throw new AssertionError("SMS relay check " + checks);
        checks++;
    }
}
