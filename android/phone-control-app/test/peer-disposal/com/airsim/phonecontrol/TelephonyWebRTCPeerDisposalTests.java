package com.airsim.phonecontrol;

import java.lang.reflect.Field;
import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Method;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;
import org.json.JSONArray;
import org.webrtc.AudioSource;
import org.webrtc.AudioTrack;
import org.webrtc.PeerConnection;

/** Tests the production peer, not the separate IPC suite's fake peer. No JNI is loaded. */
public final class TelephonyWebRTCPeerDisposalTests {
    // Timeouts only bound broken tests. Latches, not sleeps or elapsed time, establish ordering.
    private static final long TIMEOUT_SECONDS = 5;
    private static int passed;

    public static void main(String[] args) throws Exception {
        run("close returns while queued disposal is pending", TelephonyWebRTCPeerDisposalTests::queuedCloseIsNotCompletion);
        run("device teardown must finish before completion", TelephonyWebRTCPeerDisposalTests::deviceCloseGatesCompletion);
        run("concurrent closes share one disposal", TelephonyWebRTCPeerDisposalTests::concurrentCloseIsIdempotent);
        run("peer close failure still disposes peer and later resources", TelephonyWebRTCPeerDisposalTests::peerCloseFailureStillDisposes);
        run("device failure still releases native resources", TelephonyWebRTCPeerDisposalTests::deviceFailureStillDisposes);
        run("track linkage failure still disposes source", TelephonyWebRTCPeerDisposalTests::linkageFailureStillDisposes);
        run("peer dispose failure is exceptional", TelephonyWebRTCPeerDisposalTests::peerDisposeFailureIsExceptional);
        run("earlier peer disposal failure stays sticky without retry", TelephonyWebRTCPeerDisposalTests::earlierDisposalFailureStaysSticky);
        run("rejected signaling submission fails closed", TelephonyWebRTCPeerDisposalTests::rejectedSubmissionFailsClosed);
        check(!(Boolean) field("initialized").get(null), "Native WebRTC must never be initialized");
        System.out.println("TelephonyWebRTCPeerDisposalTests: " + passed + " passed (production peer, no JNI)");
    }

    private static void queuedCloseIsNotCompletion() throws Exception {
        try (Fixture f = new Fixture()) {
            CountDownLatch entered = new CountDownLatch(1);
            CountDownLatch release = new CountDownLatch(1);
            f.signaling.execute(() -> { entered.countDown(); await(release, "release signaling queue"); });
            try {
                await(entered, "signaling queue held");
                // Calling close on another thread proves the Closeable entry point does not block.
                get(f.callers.submit(() -> { f.owner.close(); return null; }));
                CompletableFuture<Void> completion = f.owner.closeAsync();
                check(!completion.isDone(), "Queuing native disposal must not complete it");
                same(completion, f.owner.closeAsync(), "Repeated close must return the same pending future");
                check(f.device.closeCalls.get() == 0, "Device must stay untouched behind signaling work");
                check(f.nativePeer.closeCalls.get() == 0, "Peer must stay untouched behind signaling work");
                check(f.signaling.isShutdown(), "Close must reject new signaling work");
                release.countDown();
                get(completion);
                f.assertReleasedOnce();
                same(completion, f.owner.closeAsync(), "Completed close must retain its completion identity");
                f.owner.close();
                f.assertReleasedOnce();
            } finally {
                release.countDown();
            }
        }
    }

    private static void deviceCloseGatesCompletion() throws Exception {
        try (Fixture f = new Fixture()) {
            CountDownLatch entered = new CountDownLatch(1);
            CountDownLatch release = new CountDownLatch(1);
            f.device.duringClose = () -> { entered.countDown(); await(release, "release device teardown"); };
            try {
                CompletableFuture<Void> completion = get(f.callers.submit(f.owner::closeAsync));
                await(entered, "device teardown entered");
                check(!completion.isDone(), "Starting device.close must not complete disposal");
                same(completion, f.owner.closeAsync(), "A close during device teardown must share the future");
                check(f.nativePeer.disposeCalls.get() == 0, "Peer disposal must stay serialized behind carrier teardown");
                release.countDown();
                get(completion);
                f.assertReleasedOnce();
            } finally {
                release.countDown();
            }
        }
    }

    private static void concurrentCloseIsIdempotent() throws Exception {
        try (Fixture f = new Fixture()) {
            CountDownLatch blocked = new CountDownLatch(1);
            CountDownLatch release = new CountDownLatch(1);
            CountDownLatch ready = new CountDownLatch(8);
            CountDownLatch start = new CountDownLatch(1);
            f.signaling.execute(() -> { blocked.countDown(); await(release, "release concurrent teardown"); });
            try {
                await(blocked, "signaling queue held for concurrent close");
                List<Future<CompletableFuture<Void>>> calls = new ArrayList<>();
                for (int i = 0; i < 8; i++) {
                    calls.add(f.callers.submit(() -> {
                        ready.countDown();
                        await(start, "start concurrent close");
                        return f.owner.closeAsync();
                    }));
                }
                await(ready, "all close callers ready");
                start.countDown();
                CompletableFuture<Void> completion = get(calls.get(0));
                for (Future<CompletableFuture<Void>> call : calls) {
                    same(completion, get(call), "Concurrent callers must observe one disposal future");
                }
                check(!completion.isDone(), "Concurrent close must not bypass pending signaling work");
                release.countDown();
                get(completion);
                f.assertReleasedOnce();
            } finally {
                start.countDown();
                release.countDown();
            }
        }
    }

    private static void peerCloseFailureStillDisposes() throws Exception {
        try (Fixture f = new Fixture()) {
            f.nativePeer.duringClose = () -> { throw new IllegalStateException("private SDK close detail"); };
            CompletableFuture<Void> completion = f.owner.closeAsync();
            failed(completion);
            f.assertReleasedOnce();
            same(completion, f.owner.closeAsync(), "Failed disposal must not be replaced by success on retry");
            failed(f.owner.closeAsync());
            f.assertReleasedOnce();
        }
    }

    private static void deviceFailureStillDisposes() throws Exception {
        try (Fixture f = new Fixture()) {
            f.device.duringClose = () -> { throw new IllegalStateException("carrier_cleanup_failed"); };
            failed(f.owner.closeAsync());
            f.assertReleasedOnce();
        }
    }

    private static void linkageFailureStillDisposes() throws Exception {
        try (Fixture f = new Fixture()) {
            // This is deliberately injected, not an actual JNI call or library-loading failure.
            f.track.duringDispose = () -> { throw new UnsatisfiedLinkError("injected release failure"); };
            failed(f.owner.closeAsync());
            f.assertReleasedOnce();
        }
    }

    private static void peerDisposeFailureIsExceptional() throws Exception {
        try (Fixture f = new Fixture()) {
            f.nativePeer.duringDispose = () -> { throw new IllegalStateException("private SDK disposal detail"); };
            failed(f.owner.closeAsync());
            f.assertReleasedOnce();
        }
    }

    private static void earlierDisposalFailureStaysSticky() throws Exception {
        for (boolean failClose : new boolean[]{true, false}) {
            try (Fixture f = new Fixture()) {
                Runnable fail = () -> { throw new IllegalStateException("private SDK retirement detail"); };
                if (failClose) f.nativePeer.duringClose = fail;
                else f.nativePeer.duringDispose = fail;
                Method retire = TelephonyWebRTCPeer.class.getDeclaredMethod("disposePeer");
                retire.setAccessible(true);
                // Offer replacement retires a peer on this executor before the final close begins.
                Throwable retirementFailure = get(f.signaling.submit(() -> {
                    try {
                        retire.invoke(f.owner);
                        return null;
                    } catch (InvocationTargetException error) {
                        return error.getCause();
                    }
                }));
                check(retirementFailure instanceof IllegalStateException,
                        "Early peer retirement must surface the native cleanup failure");
                check(field("peer").get(f.owner) == null, "Uncertain native handle must be detached before final close");
                check(f.nativePeer.closeCalls.get() == 1 && f.nativePeer.disposeCalls.get() == 1,
                        "Both retirement actions must be attempted even if close fails");
                check(f.device.closeCalls.get() == 0 && f.track.disposeCalls.get() == 0
                                && f.source.disposeCalls.get() == 0,
                        "Peer replacement must not perform the final carrier/track/source teardown");
                CompletableFuture<Void> completion = f.owner.closeAsync();
                failed(completion);
                f.assertReleasedOnce();
                same(completion, f.owner.closeAsync(), "An earlier failure must remain sticky on repeated close");
                failed(completion);
                f.assertReleasedOnce();
            }
        }
    }

    private static void rejectedSubmissionFailsClosed() throws Exception {
        try (Fixture f = new Fixture()) {
            f.signaling.shutdown();
            CompletableFuture<Void> completion = f.owner.closeAsync();
            failed(completion);
            same(completion, f.owner.closeAsync(), "Rejected teardown must retain its failed completion");
            check(f.device.closeCalls.get() == 0, "Rejected cleanup must not move carrier teardown onto caller thread");
            check(f.nativePeer.closeCalls.get() == 0 && f.nativePeer.disposeCalls.get() == 0,
                    "Rejected cleanup must not run SDK teardown outside its executor");
            check(f.track.disposeCalls.get() == 0 && f.source.disposeCalls.get() == 0,
                    "Rejected cleanup must not claim later resources were released");
        }
    }

    private static final class Fixture implements AutoCloseable {
        final TelephonyWebRTCPeer owner = new TelephonyWebRTCPeer(null,
                "00000000-0000-0000-0000-000000000001", 1, new JSONArray(),
                ignored -> { throw new AssertionError("Disposal must not signal"); },
                () -> { throw new AssertionError("Explicit disposal must not emit a call failure"); }, true);
        final ScheduledExecutorService signaling;
        final ExecutorService callers = Executors.newFixedThreadPool(8);
        final TelephonyAudioDevice device = new TelephonyAudioDevice(null, null, null, null);
        final FakePeerConnection nativePeer = new FakePeerConnection();
        final FakeAudioTrack track = new FakeAudioTrack();
        final FakeAudioSource source = new FakeAudioSource();

        Fixture() throws Exception {
            signaling = (ScheduledExecutorService) field("signaling").get(owner);
            field("device").set(owner, device);
            field("peer").set(owner, nativePeer);
            field("track").set(owner, track);
            field("source").set(owner, source);
        }

        void assertReleasedOnce() {
            check(device.closeCalls.get() == 1, "Carrier close must be attempted exactly once");
            check(nativePeer.closeCalls.get() == 1, "Peer close must be attempted exactly once");
            check(nativePeer.disposeCalls.get() == 1, "Peer dispose must be attempted exactly once");
            check(track.disposeCalls.get() == 1, "Track dispose must be attempted exactly once");
            check(source.disposeCalls.get() == 1, "Source dispose must be attempted exactly once");
        }

        @Override public void close() throws Exception {
            signaling.shutdownNow();
            callers.shutdownNow();
            check(signaling.awaitTermination(TIMEOUT_SECONDS, TimeUnit.SECONDS), "Signaling worker leaked");
            check(callers.awaitTermination(TIMEOUT_SECONDS, TimeUnit.SECONDS), "Close caller leaked");
        }
    }

    // These subclass the pinned SDK classes. Constructors only initialize Java state;
    // every SDK method this suite calls is overridden, so no native method is reached.
    private static final class FakePeerConnection extends PeerConnection {
        final AtomicInteger closeCalls = new AtomicInteger();
        final AtomicInteger disposeCalls = new AtomicInteger();
        Runnable duringClose = () -> {};
        Runnable duringDispose = () -> {};

        FakePeerConnection() { super(() -> 0L); }
        @Override public void close() { closeCalls.incrementAndGet(); duringClose.run(); }
        @Override public void dispose() { disposeCalls.incrementAndGet(); duringDispose.run(); }
    }

    private static final class FakeAudioTrack extends AudioTrack {
        final AtomicInteger disposeCalls = new AtomicInteger();
        Runnable duringDispose = () -> {};
        FakeAudioTrack() { super(1L); }
        @Override public void dispose() { disposeCalls.incrementAndGet(); duringDispose.run(); }
    }

    private static final class FakeAudioSource extends AudioSource {
        final AtomicInteger disposeCalls = new AtomicInteger();
        FakeAudioSource() { super(1L); }
        @Override public void dispose() { disposeCalls.incrementAndGet(); }
    }

    private static Field field(String name) throws Exception {
        Field field = TelephonyWebRTCPeer.class.getDeclaredField(name);
        field.setAccessible(true);
        return field;
    }

    private static void failed(CompletableFuture<Void> completion) throws Exception {
        try {
            get(completion);
            throw new AssertionError("Uncertain cleanup must complete exceptionally, never report disposal success");
        } catch (ExecutionException expected) {
            check(expected.getCause() instanceof IllegalStateException, "Cleanup failure must have a stable exception type");
            check("media_cleanup_failed".equals(expected.getCause().getMessage()),
                    "Cleanup failure must not expose private native error details");
        }
    }

    private static <T> T get(Future<T> future) throws Exception {
        return future.get(TIMEOUT_SECONDS, TimeUnit.SECONDS);
    }

    private static void await(CountDownLatch latch, String description) {
        try {
            check(latch.await(TIMEOUT_SECONDS, TimeUnit.SECONDS), "Timed out: " + description);
        } catch (InterruptedException error) {
            Thread.currentThread().interrupt();
            throw new AssertionError("Interrupted: " + description, error);
        }
    }

    private static void same(Object expected, Object actual, String message) { check(expected == actual, message); }
    private static void check(boolean condition, String message) {
        if (!condition) throw new AssertionError(message);
    }

    private interface Test { void run() throws Exception; }
    private static void run(String name, Test test) throws Exception {
        test.run();
        passed++;
        System.out.println("PASS: " + name);
    }
}
