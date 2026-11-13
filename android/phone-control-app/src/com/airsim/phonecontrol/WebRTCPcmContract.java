package com.airsim.phonecontrol;

import java.nio.ByteBuffer;
import org.webrtc.audio.PcmFormat;

/** Strict native callback boundary; SDK external-capture count is zero before the callback. */
final class WebRTCPcmContract {
    static void silence(ByteBuffer buffer) {
        if (buffer == null || buffer.isReadOnly()) return;
        buffer.clear();
        while (buffer.hasRemaining()) buffer.put((byte) 0);
        buffer.position(0);
    }

    static boolean acceptsCapture(PcmFormat expected, ByteBuffer buffer, int encoding, int channels, int rate) {
        return buffer != null && buffer.isDirect() && !buffer.isReadOnly()
                && expected.matches(encoding, channels, rate, buffer.capacity());
    }

    static boolean copyCapture(PcmFormat expected, ByteBuffer buffer, int encoding, int channels, int rate, byte[] pcm) {
        if (!acceptsCapture(expected, buffer, encoding, channels, rate)
                || pcm == null || pcm.length != expected.frameBytes()) return false;
        buffer.clear();
        buffer.put(pcm);
        buffer.position(0);
        return true;
    }

    static boolean acceptsPlayback(PcmFormat expected, int encoding, int channels, int rate, byte[] pcm) {
        return pcm != null && expected.matches(encoding, channels, rate, pcm.length);
    }
}
