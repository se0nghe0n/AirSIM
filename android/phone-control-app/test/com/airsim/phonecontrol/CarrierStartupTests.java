package com.airsim.phonecontrol;

import java.io.IOException;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;

public final class CarrierStartupTests {
    private static final class Fixture {
        long now;
        boolean closed;
        int pauses;
        final CarrierStartup startup = new CarrierStartup(() -> closed, () -> now, nanos -> {
            now += nanos;
            pauses++;
        });
    }
    interface Checked { void run() throws Exception; }
    static void require(boolean value, String message) {
        if (!value) throw new AssertionError(message);
    }
    static void fails(String reason, Checked work) throws Exception {
        try { work.run(); throw new AssertionError("Expected " + reason); }
        catch (IOException error) { require(reason.equals(error.getMessage()), "Fixed failure reason: " + error); }
    }
    public static void main(String[] args) throws Exception {
        Fixture stalled = new Fixture();
        fails("carrier route unverified", () -> stalled.startup.verifyRoute(new byte[160],
                (b, o, n) -> 0, () -> false));
        require(stalled.now == CarrierStartup.ROUTE_TIMEOUT_NANOS && stalled.pauses == 200,
                "stalled output expires without blocking or spinning");
        Fixture capture = new Fixture();
        fails("carrier capture timeout", () -> capture.startup.firstCapture(new byte[160], (b, o, n) -> 0));
        require(capture.now == CarrierStartup.FIRST_CAPTURE_TIMEOUT_NANOS, "stalled capture is bounded");

        Fixture partial = new Fixture();
        List<Integer> offsets = new ArrayList<>();
        require(partial.startup.verifyRoute(new byte[8], (b, o, n) -> {
            require(Arrays.equals(b, new byte[8]), "only silence primes route");
            offsets.add(o);
            return 2;
        }, () -> offsets.size() == 5), "verified route succeeds");
        require(offsets.equals(List.of(0, 2, 4, 6, 0)), "partial writes preserve position and wrap");
        Fixture partialRead = new Fixture();
        byte[] frame = new byte[8];
        require(partialRead.startup.firstCapture(frame, (b, o, n) -> {
            b[o] = (byte) (o + 1); b[o + 1] = (byte) (o + 2); return 2;
        }), "partial capture assembles a whole frame");
        require(Arrays.equals(frame, new byte[]{1,2,3,4,5,6,7,8}), "capture bytes remain ordered");
        Fixture partialStall = new Fixture();
        fails("carrier capture timeout", () -> partialStall.startup.firstCapture(new byte[8],
                (b, o, n) -> o == 0 ? 2 : 0));
        Fixture partialWrites = new Fixture();
        fails("carrier route unverified", () -> partialWrites.startup.verifyRoute(new byte[8],
                (b, o, n) -> 2, () -> false));
        require(partialWrites.now == CarrierStartup.ROUTE_TIMEOUT_NANOS,
                "partial progress never resets the route budget");
        Fixture lateRoute = new Fixture();
        fails("carrier route unverified", () -> lateRoute.startup.verifyRoute(new byte[8],
                (b, o, n) -> { lateRoute.now += CarrierStartup.ROUTE_TIMEOUT_NANOS; return n; }, () -> true));
        Fixture lateCapture = new Fixture();
        fails("carrier capture timeout", () -> lateCapture.startup.firstCapture(new byte[8],
                (b, o, n) -> { lateCapture.now += CarrierStartup.FIRST_CAPTURE_TIMEOUT_NANOS; return n; }));

        Fixture cancelled = new Fixture(); cancelled.closed = true;
        CarrierStartup.Transfer forbidden = (b, o, n) -> { throw new AssertionError("I/O after cancellation"); };
        require(!cancelled.startup.verifyRoute(new byte[8], forbidden, () -> true), "closed route returns quietly");
        require(!cancelled.startup.firstCapture(new byte[8], forbidden), "closed capture returns quietly");
        Fixture midWrite = new Fixture();
        require(!midWrite.startup.verifyRoute(new byte[8], (b, o, n) -> {
            midWrite.closed = true; return n;
        }, () -> { throw new AssertionError("Ready after cancel"); }), "cancel during write cannot report ready");
        Fixture midRead = new Fixture();
        require(!midRead.startup.firstCapture(new byte[8], (b, o, n) -> {
            midRead.closed = true; return n;
        }), "cancel during read cannot report ready");

        for (int invalid : new int[]{-1, 1, 10}) {
            fails("carrier playback stopped", () -> new Fixture().startup.verifyRoute(new byte[8],
                    (b, o, n) -> invalid, () -> true));
            fails("carrier capture failed", () -> new Fixture().startup.firstCapture(new byte[8],
                    (b, o, n) -> invalid));
        }
        CarrierStartup interrupted = new CarrierStartup(() -> false, () -> 0L,
                nanos -> { throw new InterruptedException("cancelled"); });
        try {
            interrupted.firstCapture(new byte[8], (b, o, n) -> 0);
            throw new AssertionError("Capture ignored interruption");
        } catch (InterruptedException expected) { /* Owner can finish disposal. */ }
        try {
            interrupted.verifyRoute(new byte[8], (b, o, n) -> 0, () -> false);
            throw new AssertionError("Route ignored interruption");
        } catch (InterruptedException expected) { /* Owner can finish disposal. */ }
        Fixture success = new Fixture();
        require(success.startup.verifyRoute(new byte[8], (b, o, n) -> n, () -> true), "immediate verified route");
        require(success.startup.firstCapture(new byte[8], (b, o, n) -> n), "immediate capture");
        require(success.pauses == 0, "no delay on successful startup");
        System.out.println("Carrier startup tests passed");
    }
}
