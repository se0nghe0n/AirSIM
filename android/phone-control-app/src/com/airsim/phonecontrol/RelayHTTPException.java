package com.airsim.phonecontrol;

import java.io.IOException;

/** Preserves the Relay response status so retry behavior does not depend on message text. */
final class RelayHTTPException extends IOException {
    private final int statusCode;

    RelayHTTPException(int statusCode, String detail) {
        super("Relay HTTP " + statusCode + (detail == null || detail.isBlank() ? "" : ": " + detail));
        this.statusCode = statusCode;
    }

    int statusCode() { return statusCode; }

    static RelayHTTPException fromHandshakeStatusLine(String line) throws IOException {
        if (line == null) throw new IOException("WebSocket handshake failed: empty");
        String[] parts = line.split(" ", 3);
        if (parts.length < 2 || !parts[0].startsWith("HTTP/")) {
            throw new IOException("Invalid WebSocket handshake response: " + line);
        }
        try {
            return new RelayHTTPException(Integer.parseInt(parts[1]), "WebSocket handshake failed: " + line);
        } catch (NumberFormatException error) {
            throw new IOException("Invalid WebSocket handshake response: " + line, error);
        }
    }
}
