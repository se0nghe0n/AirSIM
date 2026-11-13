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
        run("cancelled ringback cannot activate carrier audio", TelephonyWebRTCPeerDisposalTests::cancelledRingbackCannotActivateCarrier);
        run("carrier attach retries in place before the route is ready", TelephonyWebRTCPeerDisposalTests::carrierAttachRetriesInPlace);
        run("carrier attach gives up after bounded attempts with a reason", TelephonyWebRTCPeerDisposalTests::carrierAttachIsBounded);
        run("carrier failure after ready is not retried", TelephonyWebRTCPeerDisposalTests::carrierFailureAfterReadyFails);
        run("format rejection ends peer without same-format retry", TelephonyWebRTCPeerDisposalTests::formatFailureRequiresNewPeer);
        run("host-only remains narrowband and cloud can select wideband", TelephonyWebRTCPeerDisposalTests::formatIsImmutablePerPeer);
        check(!(Boolean) field("initialized").get(null), "Native WebRTC must never be initialized");
        System.out.println("TelephonyWebRTCPeerDisposalTests: " + passed + " passed (production peer, no JNI)");
    }

    private static void cancelledRingbackCannotActivateCarrier() throws Exception {
        TelephonyWebRTCPeer owner = new TelephonyWebRTCPeer(null,
                java.util.UUID.randomUUID().toString(), 1, new JSONArray(), signal -> {}, () -> {}, true);
        ScheduledExecutorService signaling = (ScheduledExecutorService) field("signaling").get(owner);
        CountDownLatch entered = new CountDownLatch(1), release = new CountDownLatch(1);
        try {
            signaling.execute(() -> { entered.countDown(); await(release, "release prepared peer"); });
            await(entered, "prepared peer queue held");
            owner.activateCarrierAudio();
            CompletableFuture<Void> completion = owner.closeAsync();
            release.countDown();
            get(completion);
            check(field("device").get(owner) == null, "Cancelled ringback opened a carrier device");
            owner.activateCarrierAudio();
            check(field("device").get(owner) == null, "Late activation resurrected carrier audio");
        } finally {
            release.countDown();
            get(owner.closeAsync());
        }
    }

    private static void carrierAttachRetriesInPlace() throws Exception {
        List<TelephonyAudioDevice> devices = java.util.Collections.synchronizedList(new ArrayList<>());
        CountDownLatch second = new CountDownLatch(2);
        AtomicInteger failures = new AtomicInteger();
        TelephonyAudioDevice.onStart = device -> { devices.add(device); second.countDown(); };
        TelephonyWebRTCPeer owner = new TelephonyWebRTCPeer(null, java.util.UUID.randomUUID().toString(), 1,
                new JSONArray(), signal -> {}, failures::incrementAndGet, true);
        try {
            owner.activateCarrierAudio();
            awaitCount(devices, 1, "first carrier attach");
            devices.get(0).failed.run();
            await(second, "carrier attach retry");
            check(devices.get(0).closeCalls.get() == 1, "Failed carrier attempt must be released before retry");
            check(field("device").get(owner) == devices.get(1), "Retry must attach a new device to the same peer");
            devices.get(1).ready.run();
            check(failures.get() == 0, "A recovered carrier attach must not fail the peer");
            get(owner.closeAsync());
            check(devices.get(1).closeCalls.get() == 1, "Close must release the recovered device");
            check(devices.size() == 2, "Ready carrier must not be attached again");
        } finally {
            TelephonyAudioDevice.onStart = device -> { throw new AssertionError("native route start"); };
            owner.closeAsync();
        }
    }

    private static void carrierAttachIsBounded() throws Exception {
        List<TelephonyAudioDevice> devices = java.util.Collections.synchronizedList(new ArrayList<>());
        CountDownLatch failed = new CountDownLatch(1);
        TelephonyAudioDevice.onStart = device -> { devices.add(device); device.failed.run(); };
        TelephonyWebRTCPeer owner = new TelephonyWebRTCPeer(null, java.util.UUID.randomUUID().toString(), 1,
                new JSONArray(), signal -> {}, failed::countDown, true);
        try {
            owner.activateCarrierAudio();
            await(failed, "bounded carrier failure");
            check(devices.size() == TelephonyWebRTCPeer.CARRIER_ATTACH_ATTEMPTS,
                    "Carrier attach must stop after the configured attempts");
            check("carrier_route_unverified".equals(owner.failureReason()),
                    "Final failure must keep the non-sensitive carrier reason");
            get(owner.closeAsync());
        } finally {
            TelephonyAudioDevice.onStart = device -> { throw new AssertionError("native route start"); };
            owner.closeAsync();
        }
        for (TelephonyAudioDevice device : devices) {
            check(device.closeCalls.get() == 1, "Every carrier attempt must be released exactly once");
        }
    }

    private static void carrierFailureAfterReadyFails() throws Exception {
        List<TelephonyAudioDevice> devices = java.util.Collections.synchronizedList(new ArrayList<>());
        CountDownLatch failed = new CountDownLatch(1);
        TelephonyAudioDevice.onStart = device -> { devices.add(device); device.ready.run(); device.failed.run(); };
        TelephonyWebRTCPeer owner = new TelephonyWebRTCPeer(null, java.util.UUID.randomUUID().toString(), 1,
                new JSONArray(), signal -> {}, failed::countDown, true);
        try {
            owner.activateCarrierAudio();
            await(failed, "verified carrier loss");
            check(devices.size() == 1, "A verified route loss must not be retried silently");
        } finally {
            TelephonyAudioDevice.onStart = device -> { throw new AssertionError("native route start"); };
            owner.closeAsync();
        }
    }

    private static void formatFailureRequiresNewPeer() throws Exception {
        List<TelephonyAudioDevice> devices = java.util.Collections.synchronizedList(new ArrayList<>());
        CountDownLatch failed = new CountDownLatch(1);
        TelephonyAudioDevice.onStart = device -> {
            devices.add(device);
            device.failureReason = CarrierFormatFallback.FORMAT_INIT_FAILED;
            device.failed.run();
        };
        TelephonyWebRTCPeer owner = new TelephonyWebRTCPeer(null, java.util.UUID.randomUUID().toString(), 1,
                new JSONArray(), signal -> {}, failed::countDown, false);
        try {
            check(owner.sampleRate() == 48000, "Cloud peer selects the advertised wideband format");
            owner.activateCarrierAudio(); await(failed, "explicit format rejection");
            get(owner.closeAsync());
            check(devices.size() == 1, "A rejected PCM format must not use the four route retries");
            check(devices.get(0).closeCalls.get() == 1, "Format-rejected carrier is fully disposed exactly once");
            check(CarrierFormatFallback.FORMAT_INIT_FAILED.equals(owner.failureReason()), "Format reason preserved for scoped fallback");
        } finally {
            TelephonyAudioDevice.onStart = device -> { throw new AssertionError("native route start"); };
            get(owner.closeAsync());
        }
    }

    private static void formatIsImmutablePerPeer() throws Exception {
        for (boolean host : new boolean[]{false, true}) for (boolean fallback : new boolean[]{false, true}) {
            TelephonyWebRTCPeer owner = new TelephonyWebRTCPeer(null, java.util.UUID.randomUUID().toString(), 1,
                    new JSONArray(), signal -> {}, () -> {}, host, fallback);
            try {
                int expected = host || fallback ? 8000 : 48000;
                check(owner.sampleRate() == expected, "Host-only and explicit fallback stay narrowband");
                WebRTCPcmBuffer capture = (WebRTCPcmBuffer) field("capture").get(owner);
                WebRTCPcmBuffer playback = (WebRTCPcmBuffer) field("playback").get(owner);
                check(capture.frameBytes() == expected / 50 && playback.frameBytes() == expected / 50,
                        "Both queues share the immutable ADM format");
            } finally { get(owner.closeAsync()); }
        }
    }

    private static void awaitCount(List<?> values, int count, String description) throws Exception {
        long deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(TIMEOUT_SECONDS);
        while (values.size() < count) {
            check(System.nanoTime() < deadline, "Timed out: " + description);
            Thread.sleep(5);
        }
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
