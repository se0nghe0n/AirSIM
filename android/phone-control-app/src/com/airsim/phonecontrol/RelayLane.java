package com.airsim.phonecontrol;

import java.util.function.BooleanSupplier;
import java.util.function.LongSupplier;

/** One serial transport lane; retries and blocking I/O never occupy another lane's worker. */
final class RelayLane {
    interface Cycle { void run(long generation) throws Exception; }
    interface Waiter { void await(long generation, long delayMillis) throws InterruptedException; }
    interface Failure { void record(Exception error, int failures); }

    void run(BooleanSupplier running, LongSupplier generation, Cycle cycle, Waiter waiter, Failure failure) {
        long previousGeneration = -1;
        int failures = 0;
        while (running.getAsBoolean()) {
            long current = generation.getAsLong();
            if (current != previousGeneration) {
                previousGeneration = current;
                failures = 0;
            }
            long delay = 2_000;
            try {
                if (!running.getAsBoolean()) return;
                cycle.run(current);
                failures = 0;
            } catch (InterruptedException interrupted) {
                Thread.currentThread().interrupt();
                return;
            } catch (Exception error) {
                failures++;
                failure.record(error, failures);
                delay = RelayRetryPolicy.delayMillis(failures, error);
            }
            try {
                if (running.getAsBoolean()) waiter.await(current, delay);
            } catch (InterruptedException interrupted) {
                Thread.currentThread().interrupt();
                return;
            }
        }
    }
}
