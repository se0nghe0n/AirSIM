package com.airsim.phonecontrol;

import java.io.IOException;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.util.Arrays;

/** Versioned 8 kHz mono PCM envelope. All wire integers are big-endian. */
final class CloudPCMTraceFrame {
    static final String TRACE_PROTOCOL = "airsim-pcm-trace-v2";
    static final int PCM_BYTES = 320;
    static final int TRACE_HEADER_BYTES = 48;

    private CloudPCMTraceFrame() {}

    static byte[] encode(String protocol, byte[] pcm, int sequence, long capturedAtMillis,
                         long sendMonotonicMillis, long sendUnixMillis) {
        if (pcm.length != PCM_BYTES) throw new IllegalArgumentException("Expected one PCM frame");
        boolean trace = TRACE_PROTOCOL.equals(protocol);
        if (!trace && !"airsim-pcm-v1".equalsIgnoreCase(protocol)) return pcm;
        int headerBytes = trace ? TRACE_HEADER_BYTES : 20;
        ByteBuffer wire = ByteBuffer.allocate(headerBytes + pcm.length).order(ByteOrder.BIG_ENDIAN);
        wire.put(new byte[] {'A', 'S', 'P', 'M'}).put((byte) (trace ? 2 : 1)).put((byte) 0)
                .putShort((short) headerBytes).putInt(sequence);
        if (trace) {
            // Difference first avoids wall-clock changes and never exposes a negative/u32 overflow age.
            long age = sendMonotonicMillis <= capturedAtMillis ? 0
                    : Math.min(0xffff_ffffL, sendMonotonicMillis - capturedAtMillis);
            wire.putInt((int) age).putLong(sendMonotonicMillis).putLong(sendUnixMillis)
                    .putLong(0).putLong(0);
        } else {
            wire.putLong(sendUnixMillis);
        }
        wire.put(pcm);
        return wire.array();
    }

    static byte[] decode(byte[] wire) throws IOException {
        if (wire.length < 4 || wire[0] != 'A' || wire[1] != 'S' || wire[2] != 'P' || wire[3] != 'M') {
            return wire;
        }
        if (wire.length < 8 || wire[5] != 0) throw invalid();
        int version = wire[4] & 0xff;
        int header = ByteBuffer.wrap(wire, 6, 2).order(ByteOrder.BIG_ENDIAN).getShort() & 0xffff;
        if ((version != 1 || header != 20) && (version != 2 || header != TRACE_HEADER_BYTES)) throw invalid();
        if (wire.length != header + PCM_BYTES) throw invalid();
        return Arrays.copyOfRange(wire, header, wire.length);
    }

    private static IOException invalid() { return new IOException("AirSIM PCM frame invalid"); }
}
