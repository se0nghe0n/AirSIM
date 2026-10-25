package com.airsim.phonecontrol;

import java.io.BufferedReader;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.util.UUID;

/** Control-only IPC v2. The bound includes escaped SDP; audio/binary messages are not supported. */
final class PrivilegedMediaProtocol {
    static final int VERSION = 2;
    static final int MAX_BYTES = 98_304;
    static final int MAX_SDP_CHARS = 49_152;
    static final int MAX_EVENTS = 64;
    static final long OWNER_LEASE_MILLIS = 30_000;

    static String bounded(String value) {
        if (value == null || value.getBytes(StandardCharsets.UTF_8).length > MAX_BYTES)
            throw new IllegalArgumentException("media_message_too_large");
        return value;
    }

    static void requireIdentity(String callUUID, long generation) {
        try { UUID.fromString(callUUID); }
        catch (RuntimeException error) { throw new IllegalArgumentException("invalid_call_identity"); }
        if (generation <= 0) throw new IllegalArgumentException("invalid_generation");
    }

    static String readLine(BufferedReader input) throws IOException {
        StringBuilder value = new StringBuilder();
        for (int ch; (ch = input.read()) != -1;) {
            if (ch == '\n') return bounded(value.toString());
            if (value.length() >= MAX_BYTES) throw new IOException("media_frame_too_large");
            value.append((char) ch);
        }
        if (value.length() == 0) return null;
        throw new IOException("incomplete_media_frame");
    }
}
