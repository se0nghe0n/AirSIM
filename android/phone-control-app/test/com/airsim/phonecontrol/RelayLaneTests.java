package com.airsim.phonecontrol;

import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;

public final class RelayLaneTests {
    public static void main(String[] args) throws Exception {
        independentLanesProgressDuringCallFailure();
        registrationChangeResetsRetryAndShutdownStopsWork();
        interruptionStopsWithoutRetry();
        System.out.println("RelayLaneTests passed");
    }

    private static void independentLanesProgressDuringCallFailure() throws Exception {
        CountDownLatch retrying = new CountDownLatch(1);
        CountDownLatch recover = new CountDownLatch(1);
        AtomicBoolean callsRunning = new AtomicBoolean(true);
        List<Integer> delivered = new ArrayList<>();
        int[] attempts = {0};
        Thread calls = new Thread(() -> new RelayLane().run(callsRunning::get, () -> 1,
                generation -> {
                    if (++attempts[0] == 1) throw new RelayHTTPException(503, "synthetic APNs failure");
                    delivered.add(1);
                    delivered.add(2);
                    callsRunning.set(false);
                }, (generation, delay) -> {
                    check(delay == 15_000, "call retry keeps its backoff");
                    retrying.countDown();
                    check(recover.await(5, TimeUnit.SECONDS), "recovery signaled");
                }, (error, failures) -> {}));
        calls.start();
        try {
            check(retrying.await(5, TimeUnit.SECONDS), "call lane entered retry");
            // The real lane runner executes many independent cadence ticks while call retry is blocked.
            for (long interval : new long[] {30_000, 15_000}) {
                long[] now = {0};
                long[] nextSend = {0};
                List<Long> sent = new ArrayList<>();
                new RelayLane().run(() -> now[0] <= 90_000, () -> 1, generation -> {
                    if (now[0] >= nextSend[0]) {
                        sent.add(now[0]);
                        nextSend[0] = now[0] + interval;
                    }
                }, (generation, delay) -> now[0] += delay, (error, failures) -> {
                    throw new AssertionError(error);
                });
                check(sent.size() >= 4, "heartbeat and fallback progress during APNs backoff");
                check(sent.get(1) <= interval + 2_000, "cadence stays bounded");
            }
        } finally {
            recover.countDown();
            calls.join(5_000);
        }
        check(!calls.isAlive(), "call worker stopped");
        check(delivered.equals(List.of(1, 2)), "recovery preserves order without duplicate sends");
    }

    private static void registrationChangeResetsRetryAndShutdownStopsWork() {
        AtomicBoolean running = new AtomicBoolean(true);
        long[] identity = {1};
        List<Long> generations = new ArrayList<>();
        List<Long> delays = new ArrayList<>();
        new RelayLane().run(running::get, () -> identity[0], generation -> {
            generations.add(generation);
            throw new RelayHTTPException(503, "synthetic failure");
        }, (generation, delay) -> {
            delays.add(delay);
            if (delays.size() == 2) identity[0] = 2;
            if (delays.size() == 3) running.set(false);
        }, (error, failures) -> {});
        check(generations.equals(List.of(1L, 1L, 2L)), "new work uses new registration and stops on shutdown");
        check(delays.equals(List.of(15_000L, 30_000L, 15_000L)), "registration resets backoff");
    }

    private static void interruptionStopsWithoutRetry() throws Exception {
        int[] attempts = {0};
        AtomicBoolean retainedInterrupt = new AtomicBoolean();
        Thread lane = new Thread(() -> {
            new RelayLane().run(() -> true, () -> 1, generation -> {
                attempts[0]++;
                throw new InterruptedException("shutdown");
            }, (generation, delay) -> { throw new AssertionError("must not wait after interruption"); },
                    (error, failures) -> { throw new AssertionError("must not retry interruption"); });
            retainedInterrupt.set(Thread.currentThread().isInterrupted());
        });
        lane.start();
        lane.join(5_000);
        check(!lane.isAlive() && attempts[0] == 1 && retainedInterrupt.get(),
                "shutdown retains interruption and ends worker without duplicate work");
    }

    private static void check(boolean condition, String message) {
        if (!condition) throw new AssertionError(message);
    }
}
