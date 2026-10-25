package com.airsim.phonecontrol;

import android.content.Context;
import com.sun.net.httpserver.HttpServer;
import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;
import java.util.UUID;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;
import org.json.JSONArray;

/** Real HTTP and production signaling proxy; only privileged/native media is replaced. */
public final class WebRTCICEPreparationTests {
    private static int checks;
    private static void check(boolean value) {
        if (!value) throw new AssertionError("ICE preparation check " + checks);
        checks++;
    }

    private static final class Fixture implements AutoCloseable {
        final AtomicInteger requests = new AtomicInteger();
        final AtomicInteger failures = new AtomicInteger();
        final CountDownLatch requested = new CountDownLatch(1);
        final CountDownLatch release = new CountDownLatch(1);
        final ShizukuBridgeManager bridge = new ShizukuBridgeManager();
        final HttpServer server;
        final WebRTCCloudPeer peer;
        volatile boolean block;
        volatile boolean failFirst;
        volatile int ttl = 60;

        Fixture() throws Exception {
            ShizukuBridgeManager.current = bridge;
            server = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
            server.createContext("/", exchange -> {
                int attempt = requests.incrementAndGet();
                requested.countDown();
                try {
                    if (block && !release.await(3, TimeUnit.SECONDS)) throw new AssertionError("request gate timed out");
                    byte[] body = ("{\"ice_servers\":[{\"urls\":[\"turn:fixture.invalid\"]}],\"ttl\":" + ttl + "}")
                            .getBytes(StandardCharsets.UTF_8);
                    exchange.sendResponseHeaders(failFirst && attempt == 1 ? 503 : 200, body.length);
                    try (var output = exchange.getResponseBody()) { output.write(body); }
                } catch (Exception ignored) { exchange.close(); }
            });
            server.start();
            peer = new WebRTCCloudPeer(new Context(), UUID.randomUUID().toString(), 1,
                    "http://127.0.0.1:" + server.getAddress().getPort(), "fixture-secret",
                    signal -> {}, failures::incrementAndGet);
        }

        public void close() {
            release.countDown();
            peer.close();
            server.stop(0);
        }
    }

    public static void main(String[] args) throws Exception {
        // Preparation overlaps ringing; it must never start carrier capture by itself.
        try (Fixture f = new Fixture()) {
            check(f.peer.prepare().get(3, TimeUnit.SECONDS));
            check(f.requests.get() == 1);
            check(f.bridge.starts.get() == 0);
            check(f.peer.prepare().get(3, TimeUnit.SECONDS));
            check(f.requests.get() == 1);
            f.peer.start();
            check(f.bridge.started.await(3, TimeUnit.SECONDS));
            check(f.requests.get() == 1 && f.bridge.starts.get() == 1 && f.failures.get() == 0);
        }
        // Answer arriving during preparation joins the in-flight request, not a second fetch.
        try (Fixture f = new Fixture()) {
            f.block = true;
            var ready = f.peer.prepare();
            check(f.requested.await(3, TimeUnit.SECONDS));
            f.peer.start();
            check(f.bridge.starts.get() == 0);
            f.release.countDown();
            check(ready.get(3, TimeUnit.SECONDS));
            check(f.bridge.started.await(3, TimeUnit.SECONDS));
            check(f.requests.get() == 1 && f.failures.get() == 0);
        }
        // A failed speculative fetch does not end a ringing call and can recover on answer.
        try (Fixture f = new Fixture()) {
            f.failFirst = true;
            check(!f.peer.prepare().get(3, TimeUnit.SECONDS));
            check(f.failures.get() == 0 && f.bridge.starts.get() == 0);
            f.peer.start();
            check(f.bridge.started.await(3, TimeUnit.SECONDS));
            check(f.requests.get() == 2 && f.failures.get() == 0);
        }
        // Missing/expired TTL must not promote cached credentials into a new native session.
        try (Fixture f = new Fixture()) {
            f.ttl = 0;
            check(f.peer.prepare().get(3, TimeUnit.SECONDS));
            f.peer.start();
            check(f.bridge.started.await(3, TimeUnit.SECONDS));
            check(f.requests.get() == 2);
        }
        // Closing a prepared call never starts native audio, even if start was queued later.
        try (Fixture f = new Fixture()) {
            check(f.peer.prepare().get(3, TimeUnit.SECONDS));
            f.peer.close();
            check(!f.peer.prepare().get(3, TimeUnit.SECONDS));
            f.peer.start();
            check(f.bridge.starts.get() == 0 && f.failures.get() == 0);
        }
        try (Fixture f = new Fixture()) {
            f.block = true;
            var preparing = f.peer.prepare();
            check(f.requested.await(3, TimeUnit.SECONDS));
            f.peer.close();
            f.release.countDown();
            check(!preparing.get(3, TimeUnit.SECONDS));
            check(f.bridge.starts.get() == 0 && f.failures.get() == 0);
        }
        try (Fixture f = new Fixture()) {
            f.peer.start();
            check(f.bridge.started.await(3, TimeUnit.SECONDS));
            check(f.requests.get() == 1 && f.failures.get() == 0);
        }
        check(new WebRTCCloudPeer.PreparedICE(new JSONArray(), 100).usableAt(99));
        check(!new WebRTCCloudPeer.PreparedICE(new JSONArray(), 100).usableAt(100));
        System.out.println("WebRTC ICE preparation tests passed (" + checks + " checks)");
    }
}
