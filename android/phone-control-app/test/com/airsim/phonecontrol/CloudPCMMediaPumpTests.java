package com.airsim.phonecontrol;

import java.io.ByteArrayOutputStream;
import java.io.PipedInputStream;
import java.io.PipedOutputStream;
import java.util.concurrent.*;
import java.util.concurrent.atomic.AtomicReference;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.List;

public final class CloudPCMMediaPumpTests {
    public static void main(String[] args) throws Exception {
        sendDeadlines();
        captureWakeupAndClose();
        stalledWriteWatchdog();
        System.out.println("CloudPCMMediaPumpTests passed (synthetic PCM only)");
    }
    private static void sendDeadlines() {
        long start = 1_000_000_000L;
        check(CloudPCMMediaPump.nextSendNanos(start, start) == start + 20_000_000L,
                "instant write still leaves a full packet interval");
        check(CloudPCMMediaPump.nextSendNanos(start, start + 19_000_000L) == start + 20_000_000L,
                "short write uses its original send deadline");
        check(CloudPCMMediaPump.nextSendNanos(start, start + 20_000_000L) == start + 20_000_000L,
                "write completing at deadline does not send before deadline");
        check(CloudPCMMediaPump.nextSendNanos(start, start + 200_000_000L) == start + 220_000_000L,
                "long write starts a fresh interval without catch-up bursts");
    }
    private static void captureWakeupAndClose() throws Exception {
        ExecutorService workers = Executors.newCachedThreadPool();
        AtomicInteger taskNumber = new AtomicInteger();
        AtomicReference<Thread> senderThread = new AtomicReference<>();
        CountDownLatch senderExited = new CountDownLatch(1);
        Executor executor = task -> {
            int number = taskNumber.getAndIncrement();
            workers.execute(() -> {
                if (number == 1) senderThread.set(Thread.currentThread());
                try { task.run(); }
                finally { if (number == 1) senderExited.countDown(); }
            });
        };
        PipedInputStream capture = new PipedInputStream(64 * 1024);
        PipedOutputStream source = new PipedOutputStream(capture);
        List<Integer> values = new CopyOnWriteArrayList<>();
        CountDownLatch sent = new CountDownLatch(8);
        AtomicReference<Exception> failure = new AtomicReference<>();
        CloudPCMMediaPump pump = new CloudPCMMediaPump(capture, new ByteArrayOutputStream(),
                (frame, capturedAtMillis) -> {
                    values.add(frame[0] & 0xff);
                    sent.countDown();
                    return 0;
                }, failure::set, executor);
        try {
            pump.start();
            awaitIdleSender(senderThread);
            for (int i = 0; i < 8; i++) {
                byte[] frame = new byte[320]; frame[0] = (byte) i;
                source.write(frame);
            }
            source.flush();
            check(sent.await(3, TimeUnit.SECONDS), "capture wakes idle sender and drains queued packets");
            for (int i = 0; i < 8; i++) check(values.get(i) == i, "sender preserves FIFO");
            awaitIdleSender(senderThread);
            pump.close();
            check(senderExited.await(2, TimeUnit.SECONDS), "close wakes idle sender without executor interruption");
            check(failure.get() == null, "normal close does not report failure");
        } finally {
            pump.close(); source.close(); workers.shutdownNow();
            check(workers.awaitTermination(2, TimeUnit.SECONDS), "closed pump workers terminate");
        }
    }
    private static void awaitIdleSender(AtomicReference<Thread> sender) throws Exception {
        long deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(2);
        while (System.nanoTime() < deadline) {
            Thread thread = sender.get();
            if (thread != null && thread.getState() == Thread.State.WAITING) return;
            Thread.sleep(2);
        }
        throw new AssertionError("empty sender must wait for capture instead of polling a timer");
    }
    private static void stalledWriteWatchdog() throws Exception {
        ExecutorService workers = Executors.newCachedThreadPool();
        PipedInputStream capture = new PipedInputStream(64 * 1024);
        PipedOutputStream source = new PipedOutputStream(capture);
        CountDownLatch sending = new CountDownLatch(1), release = new CountDownLatch(1);
        CountDownLatch played = new CountDownLatch(1);
        CountDownLatch disconnected = new CountDownLatch(1);
        AtomicReference<Exception> failure = new AtomicReference<>();
        ByteArrayOutputStream playback = new ByteArrayOutputStream() {
            @Override public synchronized void write(byte[] data, int offset, int length) {
                super.write(data, offset, length); played.countDown();
            }
        };
        CloudPCMMediaPump pump = new CloudPCMMediaPump(capture, playback, (frame, capturedAtMillis) -> {
            check(capturedAtMillis > 0 && capturedAtMillis <= System.nanoTime() / 1_000_000L,
                    "sender receives capture-complete monotonic time");
            sending.countDown(); release.await();
            return 0;
        }, error -> { failure.set(error); disconnected.countDown(); }, workers);
        try {
            pump.start();
            source.write(new byte[320]); source.flush();
            check(sending.await(2, TimeUnit.SECONDS), "capture reaches independent sender");
            source.write(new byte[320 * 100]); source.flush();
            for (int i = 0; i < 4; i++) pump.receive(new byte[320]);
            check(played.await(2, TimeUnit.SECONDS), "blocked network send cannot block playback/control receive");
            check(pump.pendingCaptureFrames() <= 12, "capture backlog stays bounded during blocked network");
            check(failure.get() == null, "short send stall is not an immediate disconnect");
            check(disconnected.await(3, TimeUnit.SECONDS), "persistent blocked write closes its own connection");
            check(failure.get() instanceof java.io.IOException, "watchdog reports a recoverable IO failure");
        } finally {
            pump.close(); release.countDown(); source.close(); workers.shutdownNow();
            workers.awaitTermination(2, TimeUnit.SECONDS);
        }
        int before = playback.size();
        pump.receive(new byte[320 * 12]);
        check(playback.size() == before, "closed old stream must not accept PCM into another session");
    }
    private static void check(boolean condition, String message) { if (!condition) throw new AssertionError(message); }
}
