package com.airsim.phonecontrol;

import java.util.ArrayDeque;
import java.util.Arrays;

/** Bounded 8 kHz mono PCM16 bridge. Native WebRTC pulls exactly 10 ms per callback. */
final class WebRTCPcmBuffer {
    static final int FRAME_BYTES = 160;
    static final int MAX_FRAMES = 6;
    private final ArrayDeque<byte[]> frames = new ArrayDeque<>();
    private final byte[] partial = new byte[FRAME_BYTES];
    private int partialSize;
    private boolean closed;

    synchronized void offer(byte[] bytes, int offset, int length) {
        if (closed) return;
        if (offset < 0 || length < 0 || offset > bytes.length - length) throw new IndexOutOfBoundsException();
        while (length > 0) {
            int count = Math.min(length, FRAME_BYTES - partialSize);
            System.arraycopy(bytes, offset, partial, partialSize, count);
            partialSize += count; offset += count; length -= count;
            if (partialSize == FRAME_BYTES) {
                if (frames.size() == MAX_FRAMES) frames.removeFirst();
                frames.addLast(Arrays.copyOf(partial, FRAME_BYTES));
                partialSize = 0;
                notifyAll();
            }
        }
    }

    synchronized byte[] poll() {
        byte[] value = frames.pollFirst();
        return value == null ? new byte[FRAME_BYTES] : value;
    }

    synchronized byte[] take() throws InterruptedException {
        while (frames.isEmpty() && !closed) wait();
        return frames.pollFirst();
    }

    synchronized int size() { return frames.size(); }

    synchronized void close() {
        closed = true; frames.clear(); partialSize = 0; notifyAll();
    }
}
