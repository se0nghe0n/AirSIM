package com.airsim.phonecontrol;

import java.io.Closeable;
import java.io.InputStream;
import java.io.OutputStream;
import java.io.EOFException;
import java.io.IOException;
import java.util.concurrent.Executor;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicLong;
import java.util.concurrent.locks.LockSupport;

final class CloudPCMMediaPump implements Closeable {
    /** Returns local WebSocket write completion duration, including its lock, in milliseconds. */
    interface Sender { long send(byte[] frame, long capturedAtMillis) throws Exception; }
    interface Failure { void failed(Exception error); }
    private final InputStream capture;
    private final OutputStream playback;
    private final Sender sender;
    private final Failure failure;
    private final Executor executor;
    private final CloudPCMAudioQueue outgoing = new CloudPCMAudioQueue(false);
    private final CloudPCMAudioQueue incoming = new CloudPCMAudioQueue(true);
    private final AtomicBoolean running = new AtomicBoolean(true);
    private final AtomicBoolean started = new AtomicBoolean();
    private volatile long sendingSince, playingSince;
    private final AtomicLong maxCaptureGap = new AtomicLong();
    private final AtomicLong maxQueueAge = new AtomicLong();
    private final AtomicLong maxSendGap = new AtomicLong();
    private final AtomicLong maxLocalWrite = new AtomicLong();

    CloudPCMMediaPump(InputStream capture, OutputStream playback, Sender sender,
                      Failure failure, Executor executor) {
        this.capture = capture; this.playback = playback; this.sender = sender;
        this.failure = failure; this.executor = executor;
    }
    void start() {
        if (!running.get() || !started.compareAndSet(false, true)) return;
        executor.execute(this::capture);
        executor.execute(this::sendCaptured);
        executor.execute(this::playIncoming);
        executor.execute(this::watchdog);
    }
    void receive(byte[] pcm) {
        if (!running.get() || pcm.length == 0 || pcm.length % 320 != 0) return;
        long now = nowMillis();
        for (int offset = 0; offset < pcm.length; offset += 320) {
            incoming.offer(java.util.Arrays.copyOfRange(pcm, offset, offset + 320), now);
        }
    }
    private void capture() {
        byte[] frame = new byte[320];
        int offset = 0;
        long previousCapture = -1;
        try {
            while (running.get()) {
                int count = capture.read(frame, offset, frame.length - offset);
                if (count < 0) throw new EOFException("Cloud PCM capture closed");
                offset += count;
                if (offset == frame.length) {
                    long capturedAt = nowMillis();
                    if (previousCapture >= 0) maxCaptureGap.accumulateAndGet(capturedAt - previousCapture, Math::max);
                    previousCapture = capturedAt;
                    synchronized (outgoing) {
                        if (!running.get()) break;
                        outgoing.offer(frame, capturedAt);
                        outgoing.notifyAll();
                    }
                    offset = 0;
                }
            }
        } catch (Exception error) { fail(error); }
    }
    private void sendCaptured() {
        long nextSend = System.nanoTime();
        long previousSend = -1;
        try {
            while (running.get() && !Thread.currentThread().isInterrupted()) {
                CloudPCMAudioQueue.Frame captured;
                synchronized (outgoing) {
                    // Check queue and deadline under the same monitor used by capture/close.
                    // Arrivals wake an idle sender without losing notifications at wait entry.
                    while (true) {
                        if (!running.get() || Thread.currentThread().isInterrupted()) return;
                        if (outgoing.size() == 0) {
                            outgoing.wait();
                            continue;
                        }
                        long remaining = nextSend - System.nanoTime();
                        if (remaining > 0) {
                            outgoing.wait(remaining / 1_000_000L, (int) (remaining % 1_000_000L));
                            continue;
                        }
                        captured = outgoing.pollCapturedFrame(nowMillis());
                        if (captured != null) break;
                    }
                }
                if (!running.get()) return;
                long sendStarted = System.nanoTime();
                sendingSince = sendStarted;
                long sendAt = nowMillis();
                maxQueueAge.accumulateAndGet(Math.max(0, sendAt - captured.capturedAt), Math::max);
                if (previousSend >= 0) maxSendGap.accumulateAndGet(sendAt - previousSend, Math::max);
                previousSend = sendAt;
                try {
                    maxLocalWrite.accumulateAndGet(sender.send(captured.pcm, captured.capturedAt), Math::max);
                } finally { sendingSince = 0; }
                nextSend = nextSendNanos(sendStarted, System.nanoTime());
            }
        } catch (InterruptedException interrupted) {
            Thread.currentThread().interrupt();
            if (running.get()) fail(interrupted);
        } catch (Exception error) { fail(error); }
    }
    // A stalled write starts a fresh interval; queued frames must never catch up in a burst.
    static long nextSendNanos(long started, long completed) {
        return CloudPCMAudioQueue.nextTickNanos(started, completed);
    }
    private void playIncoming() {
        long tick = System.nanoTime();
        try {
            while (running.get() && !Thread.currentThread().isInterrupted()) {
                byte[] frame = incoming.poll(nowMillis());
                if (frame != null && running.get()) {
                    playingSince = System.nanoTime();
                    try { playback.write(frame); } finally { playingSince = 0; }
                }
                tick = CloudPCMAudioQueue.nextTickNanos(tick, System.nanoTime());
                LockSupport.parkNanos(Math.max(0, tick - System.nanoTime()));
            }
        } catch (Exception error) { fail(error); }
    }
    private void watchdog() {
        long lastStats = System.nanoTime();
        while (running.get() && !Thread.currentThread().isInterrupted()) {
            long now = System.nanoTime();
            long sending = sendingSince, playing = playingSince;
            if ((sending != 0 && now - sending > 2_000_000_000L)
                    || (playing != 0 && now - playing > 2_000_000_000L)) {
                fail(new IOException("Cloud PCM write stalled"));
                return;
            }
            if (now - lastStats >= 5_000_000_000L) {
                BridgeLog.info("cloud_pcm_quality tx_queue=" + outgoing.size()
                        + " tx_drop=" + outgoing.droppedFrames() + " rx_queue=" + incoming.size()
                        + " rx_target_ms=" + incoming.targetFrames() * 20
                        + " rx_drop=" + incoming.droppedFrames() + " underruns=" + incoming.underruns()
                        + " concealed=" + incoming.concealedFrames()
                        + " max_capture_gap_ms=" + maxCaptureGap.getAndSet(0)
                        + " max_queue_age_ms=" + maxQueueAge.getAndSet(0)
                        + " max_send_gap_ms=" + maxSendGap.getAndSet(0)
                        + " max_local_write_ms=" + maxLocalWrite.getAndSet(0));
                lastStats = now;
            }
            LockSupport.parkNanos(100_000_000L);
        }
    }
    private static long nowMillis() { return System.nanoTime() / 1_000_000L; }
    private void fail(Exception error) {
        if (!running.compareAndSet(true, false)) return;
        closeIO();
        failure.failed(error);
    }
    int pendingCaptureFrames() { return outgoing.size(); }
    @Override public void close() {
        if (running.getAndSet(false)) closeIO();
    }
    private void closeIO() {
        synchronized (outgoing) {
            outgoing.clear();
            outgoing.notifyAll();
        }
        try { capture.close(); } catch (Exception ignored) {}
        try { playback.close(); } catch (Exception ignored) {}
        incoming.clear();
    }
}
