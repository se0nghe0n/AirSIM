package com.airsim.phonecontrol;

import java.util.ArrayDeque;
import java.util.Arrays;
import org.webrtc.audio.PcmFormat;

/**
 * Bounded in-process PCM16 mono queue between the carrier device clock and WebRTC. Never serialized or
 * sent across IPC. Frames the queue has to discard or invent are joined with short ramps, so a lost
 * 10 ms frame is not a step in the waveform the caller hears as a pop.
 */
final class WebRTCPcmBuffer {
    // Legacy 8 kHz fixture constants. Production framing is always derived from the instance format.
    static final int FRAME_BYTES = 160;
    static final int FRAME_SAMPLES = FRAME_BYTES / 2;
    static final int MAX_FRAMES = 6;
    /** Four 20 ms Opus packets. Older telephony audio is not encoded or played. */
    static final long MAX_AGE_NANOS = 80_000_000L;
    /**
     * For a queue whose consumer paces its producer. Backpressure and the frame cap already bound its
     * delay, and an age limit would drop audio every period on a device that consumes in large chunks.
     */
    static final long NO_AGE_LIMIT = Long.MAX_VALUE;
    /** 5 ms at 8 kHz: removes a waveform step without audibly fading speech. */
    static final int RAMP_SAMPLES = 40;
    private final PcmFormat format;
    private final int frameBytes, frameSamples, rampSamples;
    private final long maxAgeNanos;
    private final ArrayDeque<Frame> frames = new ArrayDeque<>();
    private final byte[] partial;
    private int partialSize;
    private boolean closed;
    private long drops;
    private long underruns;
    private long consumed;
    // Consumer-side continuity. Only the most recent emitted 10 ms frame is retained.
    private final byte[] tail;
    private boolean tailValid;
    private int lastSample;
    private boolean discontinuity;
    private boolean concealing;

    WebRTCPcmBuffer() { this(PcmFormat.NARROWBAND, MAX_AGE_NANOS); }

    WebRTCPcmBuffer(long maxAgeNanos) { this(PcmFormat.NARROWBAND, maxAgeNanos); }

    WebRTCPcmBuffer(PcmFormat format) { this(format, MAX_AGE_NANOS); }

    WebRTCPcmBuffer(PcmFormat format, long maxAgeNanos) {
        this.format = java.util.Objects.requireNonNull(format);
        this.frameBytes = format.frameBytes(); this.frameSamples = format.frameSamples();
        this.rampSamples = format.rampSamples(); this.maxAgeNanos = maxAgeNanos;
        partial = new byte[frameBytes]; tail = new byte[frameBytes];
    }

    PcmFormat format() { return format; }
    int frameBytes() { return frameBytes; }
    int frameSamples() { return frameSamples; }
    int rampSamples() { return rampSamples; }

    synchronized void offer(byte[] bytes, int offset, int length) {
        offer(bytes, offset, length, System.nanoTime());
    }

    synchronized void offer(byte[] bytes, int offset, int length, long nowNanos) {
        if (closed) return;
        if (offset < 0 || length < 0 || offset > bytes.length - length) throw new IndexOutOfBoundsException();
        while (length > 0) {
            int count = Math.min(length, frameBytes - partialSize);
            System.arraycopy(bytes, offset, partial, partialSize, count);
            partialSize += count; offset += count; length -= count;
            if (partialSize == frameBytes) {
                if (frames.size() == MAX_FRAMES) drop();
                frames.addLast(new Frame(Arrays.copyOf(partial, frameBytes), nowNanos));
                partialSize = 0;
                notifyAll();
            }
        }
    }

    /** Next frame, or a concealment frame when none is queued. Never blocks. */
    synchronized byte[] poll() { return poll(System.nanoTime()); }

    synchronized byte[] poll(long nowNanos) {
        dropExpired(nowNanos);
        Frame value = frames.pollFirst();
        if (value == null) return conceal();
        notifyAll();
        return emit(value.pcm);
    }

    /** Blocks until a frame arrives; null after close. */
    synchronized byte[] take() throws InterruptedException {
        while (!closed) {
            dropExpired(System.nanoTime());
            Frame value = frames.pollFirst();
            if (value != null) {
                notifyAll();
                return emit(value.pcm);
            }
            wait();
        }
        return null;
    }

    /** Waits at most {@code timeoutNanos} for a frame. Returns null on timeout or close. */
    synchronized byte[] take(long timeoutNanos) throws InterruptedException {
        long deadline = System.nanoTime() + Math.max(0, timeoutNanos);
        while (!closed) {
            long now = System.nanoTime();
            dropExpired(now);
            Frame value = frames.pollFirst();
            if (value != null) {
                notifyAll();
                return emit(value.pcm);
            }
            long remaining = deadline - now;
            if (remaining <= 0) return null;
            wait(remaining / 1_000_000L, (int) (remaining % 1_000_000L));
        }
        return null;
    }

    /**
     * Producer backpressure. Waits until fewer than {@code depth} frames are queued so the consumer's
     * device clock paces the producer. Returns false on close or timeout.
     */
    synchronized boolean awaitCapacity(int depth, long timeoutNanos) throws InterruptedException {
        long deadline = System.nanoTime() + Math.max(0, timeoutNanos);
        while (!closed) {
            if (frames.size() < depth) return true;
            long remaining = deadline - System.nanoTime();
            if (remaining <= 0) return false;
            wait(remaining / 1_000_000L, (int) (remaining % 1_000_000L));
        }
        return false;
    }

    /**
     * Fills a gap in the consumer's stream. The first frame continues the previous frame backwards
     * and fades it out, so the waveform neither steps to zero nor repeats a pitch period.
     */
    synchronized byte[] conceal() {
        underruns++;
        byte[] output = new byte[frameBytes];
        if (!concealing && tailValid) {
            for (int i = 0; i < frameSamples; i++) {
                int fade = frameSamples - 1 - i;
                write(output, i, sample(tail, frameSamples - 1 - i) * fade / frameSamples);
            }
        }
        concealing = true;
        remember(output);
        discontinuity = true;
        return output;
    }

    synchronized int size() { return frames.size(); }
    synchronized long drops() { return drops; }
    synchronized long underruns() { return underruns; }
    /** Frames the consumer has taken; lets a producer see that a stalled consumer resumed. */
    synchronized long consumed() { return consumed; }
    /** Tells a timed take that gave up from one that ended because the queue closed. */
    synchronized boolean isClosed() { return closed; }

    synchronized void close() {
        closed = true; frames.clear(); partialSize = 0; forget(); notifyAll();
    }

    /** Reuse after a failed carrier attach. The previous device threads must already be joined. */
    synchronized void reopen() {
        closed = false; frames.clear(); partialSize = 0; forget();
    }

    private byte[] emit(byte[] pcm) {
        if (discontinuity && tailValid) {
            // Cross-fade from the last emitted sample into the new frame.
            for (int i = 0; i < rampSamples; i++) {
                int weight = i + 1;
                write(pcm, i, (lastSample * (rampSamples + 1 - weight) + sample(pcm, i) * weight) / (rampSamples + 1));
            }
        }
        concealing = false;
        discontinuity = false;
        consumed++;
        remember(pcm);
        return pcm;
    }

    private void remember(byte[] pcm) {
        System.arraycopy(pcm, 0, tail, 0, frameBytes);
        tailValid = true;
        lastSample = sample(pcm, frameSamples - 1);
    }

    private void forget() {
        Arrays.fill(tail, (byte) 0);
        tailValid = false; lastSample = 0; discontinuity = false; concealing = false;
    }

    private void drop() {
        frames.removeFirst();
        drops++;
        discontinuity = true;
    }

    private void dropExpired(long nowNanos) {
        while (!frames.isEmpty() && nowNanos - frames.peekFirst().enqueuedAt > maxAgeNanos) drop();
    }

    // Android PCM16 byte arrays are little-endian.
    static int sample(byte[] pcm, int index) {
        return (short) ((pcm[index * 2] & 0xff) | (pcm[index * 2 + 1] << 8));
    }

    private static void write(byte[] pcm, int index, int value) {
        int clamped = Math.max(Short.MIN_VALUE, Math.min(Short.MAX_VALUE, value));
        pcm[index * 2] = (byte) clamped;
        pcm[index * 2 + 1] = (byte) (clamped >> 8);
    }

    private static final class Frame {
        final byte[] pcm;
        final long enqueuedAt;
        Frame(byte[] pcm, long enqueuedAt) { this.pcm = pcm; this.enqueuedAt = enqueuedAt; }
    }
}
