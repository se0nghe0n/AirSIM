package com.airsim.phonecontrol;

import java.util.ArrayDeque;
import java.util.Arrays;

/** Bounded in-process 8 kHz device-clock adapter. Never serialized or sent across IPC. */
final class WebRTCPcmBuffer {
    static final int FRAME_BYTES = 160;
    static final int MAX_FRAMES = 6;
    /** Four 20 ms Opus packets. Older telephony audio is not encoded or played. */
    static final long MAX_AGE_NANOS = 80_000_000L;
    private final ArrayDeque<Frame> frames = new ArrayDeque<>();
    private final byte[] partial = new byte[FRAME_BYTES];
    private int partialSize;
    private boolean closed;
    private long drops;
    private long underruns;

    synchronized void offer(byte[] bytes, int offset, int length) {
        offer(bytes, offset, length, System.nanoTime());
    }

    synchronized void offer(byte[] bytes, int offset, int length, long nowNanos) {
        if (closed) return;
        if (offset < 0 || length < 0 || offset > bytes.length - length) throw new IndexOutOfBoundsException();
        while (length > 0) {
            int count = Math.min(length, FRAME_BYTES - partialSize);
            System.arraycopy(bytes, offset, partial, partialSize, count);
            partialSize += count; offset += count; length -= count;
            if (partialSize == FRAME_BYTES) {
                if (frames.size() == MAX_FRAMES) {
                    frames.removeFirst();
                    drops++;
                }
                frames.addLast(new Frame(Arrays.copyOf(partial, FRAME_BYTES), nowNanos));
                partialSize = 0;
                notifyAll();
            }
        }
    }

    synchronized byte[] poll() { return poll(System.nanoTime()); }

    synchronized byte[] poll(long nowNanos) {
        dropExpired(nowNanos);
        Frame value = frames.pollFirst();
        if (value == null) {
            underruns++;
            return new byte[FRAME_BYTES];
        }
        return value.pcm;
    }

    synchronized byte[] take() throws InterruptedException {
        while (!closed) {
            dropExpired(System.nanoTime());
            Frame value = frames.pollFirst();
            if (value != null) return value.pcm;
            wait();
        }
        return null;
    }

    synchronized int size() { return frames.size(); }
    synchronized long drops() { return drops; }
    synchronized long underruns() { return underruns; }

    synchronized void close() {
        closed = true; frames.clear(); partialSize = 0; notifyAll();
    }

    private void dropExpired(long nowNanos) {
        while (!frames.isEmpty() && nowNanos - frames.peekFirst().enqueuedAt > MAX_AGE_NANOS) {
            frames.removeFirst();
            drops++;
        }
    }

    private static final class Frame {
        final byte[] pcm;
        final long enqueuedAt;
        Frame(byte[] pcm, long enqueuedAt) { this.pcm = pcm; this.enqueuedAt = enqueuedAt; }
    }
}
