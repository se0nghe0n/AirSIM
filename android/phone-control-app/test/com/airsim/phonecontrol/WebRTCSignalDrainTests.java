package com.airsim.phonecontrol;

import java.io.IOException;
import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicLong;

public final class WebRTCSignalDrainTests {
    private static int checks;
    private static void check(boolean value) {
        checks++;
        if (!value) throw new AssertionError("signal drain check " + checks);
    }

    public static void main(String[] args) throws Exception {
        AtomicInteger calls = new AtomicInteger();
        check(WebRTCSignalDrain.run(() -> { calls.incrementAndGet(); return false; }, () -> false, () -> 0) == 0);
        check(calls.get() == 1); // Empty queue never spins or increases idle polling rate.
        calls.set(0);
        check(WebRTCSignalDrain.run(() -> { calls.incrementAndGet(); return true; }, () -> true, () -> 0) == 0);
        check(calls.get() == 0);
        check(WebRTCSignalDrain.run(() -> { calls.incrementAndGet(); return true; }, () -> false, () -> 0) == 8);
        check(calls.get() == 8); // Even an infinite producer yields to activation/stop tasks.

        AtomicLong clock = new AtomicLong();
        check(WebRTCSignalDrain.run(() -> { clock.addAndGet(3_000_000); return true; }, () -> false, clock::get) == 3);
        check(clock.get() == 9_000_000); // Budget checked between operations, not a promise to interrupt one.
        AtomicBoolean closed = new AtomicBoolean();
        check(WebRTCSignalDrain.run(() -> { closed.set(true); return true; }, closed::get, () -> 0) == 1);
        calls.set(0);
        try {
            WebRTCSignalDrain.run(() -> { if (calls.incrementAndGet() == 3) throw new IOException("fixture"); return true; },
                    () -> false, () -> 0);
            throw new AssertionError("error swallowed");
        } catch (IOException expected) { check(calls.get() == 3); }

        // Deterministic queue model: 12 already-ready SDP/ICE/status events, no transport cost.
        // Old policy inserts eleven 40 ms gaps. The bounded drain inserts one gap, preserving order.
        ArrayDeque<Integer> queued = new ArrayDeque<>();
        List<Integer> sent = new ArrayList<>();
        List<Long> at = new ArrayList<>();
        for (int i = 0; i < 12; i++) queued.add(i);
        clock.set(0);
        while (!queued.isEmpty()) {
            WebRTCSignalDrain.run(() -> {
                Integer value = queued.poll();
                if (value == null) return false;
                sent.add(value); at.add(clock.get()); return true;
            }, () -> false, clock::get);
            clock.addAndGet(WebRTCSignalDrain.POLL_INTERVAL_MILLIS * 1_000_000);
        }
        check(sent.size() == 12);
        for (int i = 0; i < 12; i++) check(sent.get(i) == i);
        check(at.get(11) == 40_000_000L);
        long oldLast = (12 - 1) * WebRTCSignalDrain.POLL_INTERVAL_MILLIS;
        check(oldLast == 440);
        System.out.println("Synthetic queued 12-event spacing: old=" + oldLast + "ms new=" + at.get(11) / 1_000_000 + "ms (not device latency)");
        System.out.println("WebRTC signal drain tests passed (" + checks + " checks)");
    }
}
