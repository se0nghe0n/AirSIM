package com.airsim.phonecontrol;

import java.nio.charset.Charset;
import java.util.List;

/**
 * Pure rules for relaying the text of received MMS (Korean LMS and other long or multimedia
 * messages). Carriers deliver these through WAP push + MMS download, which only the default SMS
 * app performs; AirSIM reads the text the default SMS app has already stored, using READ_SMS.
 */
final class MMSInboxPolicy {
    static final int MESSAGE_TYPE_NOTIFICATION_IND = 0x82;
    static final int MESSAGE_TYPE_RETRIEVE_CONF = 0x84;
    static final int ADDRESS_TYPE_FROM = 0x89;
    /** A notification row waits this long for the default SMS app to download the message. */
    static final long DOWNLOAD_WAIT_MILLIS = 10 * 60_000L;
    /** A downloaded row without text waits this long in case its parts are still being written. */
    static final long PARTS_WAIT_MILLIS = 60_000L;
    static final int MAX_TEXT_BYTES = 64 * 1024;

    enum Step {
        /** Relay this message now. */
        QUEUE,
        /** Nothing to relay (no text, or never downloaded); advance past it. */
        SKIP,
        /** Stop here and look again on the next scan, without advancing the cursor. */
        WAIT
    }

    private MMSInboxPolicy() {}

    /**
     * @param firstSeenMillis when this scanner first saw the row (in memory), not the PDU date: the
     *                        MMSC date can be long before delivery or in the future.
     */
    static Step step(int messageType, boolean hasText, long firstSeenMillis, long nowMillis) {
        long waited = Math.max(0, nowMillis - firstSeenMillis);
        if (messageType == MESSAGE_TYPE_NOTIFICATION_IND) {
            return waited < DOWNLOAD_WAIT_MILLIS ? Step.WAIT : Step.SKIP;
        }
        if (messageType != MESSAGE_TYPE_RETRIEVE_CONF) return Step.SKIP;
        if (hasText) return Step.QUEUE;
        return waited < PARTS_WAIT_MILLIS ? Step.WAIT : Step.SKIP;
    }

    static boolean isSenderAddress(int type, String address) {
        return type == ADDRESS_TYPE_FROM && address != null && !address.isBlank()
                && !"insert-address-token".equals(address);
    }

    static boolean isTextPart(String contentType) {
        return contentType != null && contentType.trim().toLowerCase(java.util.Locale.ROOT).startsWith("text/plain");
    }

    /** Concatenates the text parts of one message in part order. */
    static String joinText(List<String> parts) {
        StringBuilder text = new StringBuilder();
        for (String part : parts) {
            if (part == null || part.isBlank()) continue;
            if (text.length() > 0) text.append('\n');
            text.append(part);
        }
        return text.toString();
    }

    /** MMS part charsets are IANA MIBenum values; unknown or unsupported values decode as UTF-8. */
    static Charset charset(int mib) {
        String name = switch (mib) {
            case 3 -> "US-ASCII";
            case 4 -> "ISO-8859-1";
            case 17 -> "Shift_JIS";
            case 36, 38 -> "EUC-KR";
            case 113 -> "GBK";
            case 114 -> "GB18030";
            case 1000, 1013 -> "UTF-16BE";
            case 1014 -> "UTF-16LE";
            case 1015 -> "UTF-16";
            case 2025 -> "GB2312";
            case 2026 -> "Big5";
            default -> "UTF-8";
        };
        try {
            return Charset.isSupported(name) ? Charset.forName(name) : java.nio.charset.StandardCharsets.UTF_8;
        } catch (RuntimeException unsupported) {
            return java.nio.charset.StandardCharsets.UTF_8;
        }
    }
}
