package com.airsim.phonecontrol;

import android.content.Context;
import org.json.JSONArray;
import org.json.JSONObject;
import java.io.ByteArrayOutputStream;
import java.io.Closeable;
import java.io.IOException;
import java.io.InputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.Executors;
import java.util.concurrent.RejectedExecutionException;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;

/** App-owned signaling proxy. All audio, codec and RTP work stays in the privileged native peer. */
final class WebRTCCloudPeer implements Closeable {
    interface Signals { void send(JSONObject value) throws Exception; }
    private final ShizukuBridgeManager bridge;
    private final String callUUID;
    private final long generation;
    private final String ownerID = java.util.UUID.randomUUID().toString();
    private final String relayURL;
    private final String secret;
    private final Signals signals;
    private final Runnable failed;
    private final boolean hostOnly;
    private final ScheduledExecutorService worker = Executors.newSingleThreadScheduledExecutor();
    private final AtomicBoolean closed = new AtomicBoolean();
    private volatile HttpURLConnection iceRequest;
    private long requestID;
    private boolean started;
    private boolean carrierAudioActive;
    private PreparedICE preparedICE;
    private CompletableFuture<Boolean> preparation;

    record PreparedICE(JSONArray servers, long expiresAtNanos) {
        boolean usableAt(long now) { return now < expiresAtNanos; }
    }

    WebRTCCloudPeer(Context context, String callUUID, long generation, String relayURL,
                    String secret, Signals signals, Runnable failed) {
        this(context, callUUID, generation, relayURL, secret, signals, failed, false);
    }

    static WebRTCCloudPeer host(Context context, String callUUID, long generation, Signals signals, Runnable failed) {
        return new WebRTCCloudPeer(context, callUUID, generation, "", "", signals, failed, true);
    }

    private WebRTCCloudPeer(Context context, String callUUID, long generation, String relayURL,
                    String secret, Signals signals, Runnable failed, boolean hostOnly) {
        PrivilegedMediaProtocol.requireIdentity(callUUID, generation);
        this.bridge = ShizukuBridgeManager.get(context); this.callUUID = callUUID; this.generation = generation;
        this.relayURL = relayURL; this.secret = secret; this.signals = signals; this.failed = failed; this.hostOnly = hostOnly;
    }

    /** Fetch call-scoped credentials only. Never opens carrier audio or starts a native peer. */
    synchronized CompletableFuture<Boolean> prepare() {
        if (closed.get() || hostOnly) return CompletableFuture.completedFuture(false);
        if (preparation != null) return preparation;
        preparation = new CompletableFuture<>();
        try {
            worker.execute(() -> {
                if (closed.get()) { preparation.complete(false); return; }
                try {
                    PreparedICE value = fetchICE();
                    if (!closed.get()) preparedICE = value;
                    preparation.complete(!closed.get());
                } catch (Exception | LinkageError error) {
                    // A speculative request failing while the call rings is not a call failure.
                    // start() retries through the normal, bounded request path after answer.
                    BridgeLog.info("webrtc_ice_prefetch_unavailable");
                    preparation.complete(false);
                }
            });
        } catch (RejectedExecutionException closedWorker) { preparation.complete(false); }
        return preparation;
    }

    void start() {
        start(false);
    }

    void start(boolean deferCarrierAudio) {
        long waitStarted = System.nanoTime();
        submit(() -> {
            if (started) return;
            if (!bridge.mediaAvailable()) throw new IOException("privileged_media_unavailable");
            boolean warmed = preparedICE != null && preparedICE.usableAt(System.nanoTime());
            JSONArray ice = hostOnly ? new JSONArray()
                    : (warmed ? preparedICE : fetchICE()).servers();
            preparedICE = null;
            if (closed.get()) return;
            BridgeLog.info("webrtc_ice_ready prefetched=" + warmed
                    + " wait_ms=" + TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - waitStarted));
            request(identity("start").put("host_only", hostOnly).put("ice_servers", ice)
                    .put("defer_carrier_audio", deferCarrierAudio));
            started = true;
            carrierAudioActive = !deferCarrierAudio;
            worker.scheduleWithFixedDelay(() -> {
                if (closed.get()) return;
                try {
                    JSONObject response = request(identity("poll"));
                    JSONObject event = response.optJSONObject("event");
                    if (event != null) {
                        if ("webrtc_failed".equals(event.optString("status"))) { fail(); return; }
                        signals.send(event);
                    }
                    if (!response.optBoolean("active")) fail();
                } catch (Exception | LinkageError error) { fail(); }
            }, 0, 40, TimeUnit.MILLISECONDS);
        });
    }

    void activateCarrierAudio() {
        submit(() -> {
            if (!started || carrierAudioActive) return;
            request(identity("activate_audio"));
            carrierAudioActive = true;
        });
    }

    void receive(JSONObject signal) {
        if (!callUUID.equalsIgnoreCase(signal.optString("call_uuid")) || generation != signal.optLong("generation", -1)) return;
        String encoded = PrivilegedMediaProtocol.bounded(signal.toString());
        submit(() -> {
            if (!started) throw new IOException("media_not_started");
            request(identity("signal").put("signal", new JSONObject(encoded)));
        });
    }

    private JSONObject identity(String action) throws Exception {
        return new JSONObject().put("version", PrivilegedMediaProtocol.VERSION).put("action", action)
                .put("call_uuid", callUUID).put("generation", generation).put("owner_id", ownerID);
    }

    private JSONObject request(JSONObject value) throws Exception {
        long id = ++requestID;
        value.put("request_id", id);
        JSONObject reply = new JSONObject(bridge.mediaRequest(value.toString()));
        if (reply.optInt("version") != PrivilegedMediaProtocol.VERSION || reply.optLong("request_id") != id
                || !reply.optBoolean("ok")) throw new IOException("invalid_media_response");
        return reply;
    }

    private PreparedICE fetchICE() throws Exception {
        long requestedAt = System.nanoTime();
        HttpURLConnection connection = (HttpURLConnection) new URL(relayURL + "/v1/calls/" + callUUID + "/ice?role=agent").openConnection();
        iceRequest = connection;
        try {
            if (closed.get()) throw new IOException("media_closed");
            connection.setConnectTimeout(8000); connection.setReadTimeout(8000);
            connection.setInstanceFollowRedirects(false); connection.setUseCaches(false);
            connection.setRequestProperty("Authorization", "Bearer " + secret);
            if (connection.getResponseCode() != 200) throw new IOException("ICE configuration unavailable");
            ByteArrayOutputStream bytes = new ByteArrayOutputStream();
            try (InputStream input = connection.getInputStream()) {
                byte[] buffer = new byte[4096]; int count;
                while ((count = input.read(buffer)) != -1) {
                    if (bytes.size() + count > 65536) throw new IOException("ICE configuration too large");
                    bytes.write(buffer, 0, count);
                }
            }
            JSONObject configuration = new JSONObject(new String(bytes.toByteArray(), StandardCharsets.UTF_8));
            long ttl = Math.min(86400, Math.max(0, configuration.optLong("ttl", 0)));
            long margin = Math.min(30, ttl / 10);
            return new PreparedICE(configuration.getJSONArray("ice_servers"),
                    requestedAt + TimeUnit.SECONDS.toNanos(ttl - margin));
        } finally { connection.disconnect(); iceRequest = null; }
    }

    private interface Work { void run() throws Exception; }
    private void submit(Work work) {
        if (closed.get()) return;
        try { worker.execute(() -> {
            if (closed.get()) return;
            try { work.run(); } catch (Exception | LinkageError error) { fail(); }
        }); } catch (RejectedExecutionException ignored) {}
    }

    private void fail() {
        if (closed.get()) return;
        close();
        BridgeLog.info("privileged_webrtc_unavailable");
        failed.run();
    }

    @Override public void close() {
        if (!closed.compareAndSet(false, true)) return;
        HttpURLConnection request = iceRequest;
        if (request != null) request.disconnect();
        worker.execute(() -> {
            preparedICE = null;
            if (started) try { request(identity("stop")); } catch (Exception ignored) {}
        });
        worker.shutdown();
    }
}
