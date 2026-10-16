package com.airsim.phonecontrol;

import java.io.IOException;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.util.Arrays;

public final class CloudPCMTraceFrameTests {
    public static void main(String[] args) throws Exception {
        byte[] pcm = new byte[320];
        for (int i = 0; i < pcm.length; i++) pcm[i] = (byte) i;
        byte[] trace = CloudPCMTraceFrame.encode("airsim-pcm-trace-v2", pcm, 0x89abcdef,
                0x0102030405060700L, 0x0102030405060708L, 0x1112131415161718L);
        byte[] expectedHeader = new byte[] {
                0x41, 0x53, 0x50, 0x4d, 2, 0, 0, 48,
                (byte) 0x89, (byte) 0xab, (byte) 0xcd, (byte) 0xef, 0, 0, 0, 8,
                1, 2, 3, 4, 5, 6, 7, 8, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18,
                0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0};
        check(trace.length == 368, "exact trace length");
        check(Arrays.equals(Arrays.copyOf(trace, 48), expectedHeader), "exact big-endian trace header");
        check(Arrays.equals(Arrays.copyOfRange(trace, 48, trace.length), pcm), "PCM starts at offset 48");
        check(Arrays.equals(CloudPCMTraceFrame.decode(trace), pcm), "trace round trip");
        // Relay timestamps may be filled before Android receives a trace frame.
        ByteBuffer.wrap(trace).order(ByteOrder.BIG_ENDIAN).putLong(32, 321).putLong(40, 456);
        check(Arrays.equals(CloudPCMTraceFrame.decode(trace), pcm), "accept stamped trace round trip");
        byte[] futureCapture = CloudPCMTraceFrame.encode("airsim-pcm-trace-v2", pcm, 0, 101, 100, 1);
        check(ByteBuffer.wrap(futureCapture).getInt(12) == 0, "negative queue age clamps to zero");
        byte[] oldCapture = CloudPCMTraceFrame.encode("airsim-pcm-trace-v2", pcm, 0, 0, 0x1ffffffffL, 1);
        check(ByteBuffer.wrap(oldCapture).getInt(12) == -1, "queue age clamps to unsigned 32-bit max");

        byte[] v1 = CloudPCMTraceFrame.encode("airsim-pcm-v1", pcm, 7, 50, 100, 200);
        check(v1.length == 340 && v1[4] == 1 && v1[7] == 20, "legacy v1 envelope preserved");
        check(ByteBuffer.wrap(v1).getInt(8) == 7 && ByteBuffer.wrap(v1).getLong(12) == 200,
                "legacy v1 sequence and Unix timestamp preserved");
        check(Arrays.equals(CloudPCMTraceFrame.decode(v1), pcm), "legacy v1 round trip");
        for (String protocol : new String[] {"", "unknown", "AIRSIM-PCM-TRACE-V2"}) {
            check(CloudPCMTraceFrame.encode(protocol, pcm, 1, 2, 3, 4) == pcm,
                    "raw fallback unless trace explicitly negotiated");
        }
        check(CloudPCMTraceFrame.decode(pcm) == pcm, "raw PCM remains unchanged");
        byte[] rawMagic = pcm.clone();
        System.arraycopy(new byte[] {'A', 'S', 'P', 'M'}, 0, rawMagic, 0, 4);
        check(CloudPCMTraceFrame.decode(rawMagic) == rawMagic, "raw PCM magic collision remains raw");
        byte[] rawPair = new byte[640];
        System.arraycopy(rawMagic, 0, rawPair, 0, rawMagic.length);
        check(CloudPCMTraceFrame.decode(rawPair) == rawPair, "raw multi-frame magic collision remains raw");
        malformed(Arrays.copyOf(trace, 4), "truncated envelope");
        malformed(Arrays.copyOf(trace, 367), "truncated payload");
        malformed(Arrays.copyOf(trace, 369), "oversized payload");
        byte[] bad = trace.clone(); bad[4] = 3; malformed(bad, "unknown version");
        bad = trace.clone(); bad[5] = 1; malformed(bad, "unsupported flags");
        bad = trace.clone(); bad[7] = 20; malformed(bad, "wrong v2 header length");
        bad = v1.clone(); bad[7] = 48; malformed(bad, "wrong v1 header length");
        malformed(Arrays.copyOf(v1, 339), "truncated v1 payload");
        try {
            CloudPCMTraceFrame.encode("airsim-pcm-trace-v2", new byte[319], 0, 0, 0, 0);
            throw new AssertionError("partial frame accepted");
        } catch (IllegalArgumentException expected) { }
        System.out.println("CloudPCMTraceFrameTests passed (wire layout, round trips, legacy, malformed frames)");
    }
    private static void malformed(byte[] wire, String message) throws Exception {
        try { CloudPCMTraceFrame.decode(wire); throw new AssertionError(message); }
        catch (IOException expected) { }
    }
    private static void check(boolean condition, String message) { if (!condition) throw new AssertionError(message); }
}
