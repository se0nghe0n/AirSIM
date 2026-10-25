package com.airsim.phonecontrol;

import android.content.Context;
import org.json.JSONArray;
import org.json.JSONObject;
import java.io.Closeable;
import java.util.ArrayDeque;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.Executors;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.TimeUnit;

/** One native peer per privileged process. IPC carries identities, SDP/ICE and status, never samples. */
final class PrivilegedMediaService implements Closeable {
    private final Context context;
    private final Runnable restoreOutput;
    private final Runnable acquireOutput;
    private final ArrayDeque<JSONObject> events = new ArrayDeque<>();
    private final Map<String, Long> terminal = new LinkedHashMap<>();
    private final ScheduledExecutorService leases = Executors.newSingleThreadScheduledExecutor();
    private TelephonyWebRTCPeer peer;
    // A closing peer still occupies the process until every native resource is disposed.
    private volatile boolean closing;
    private CompletableFuture<Void> disposal = CompletableFuture.completedFuture(null);
    private String owner = "";
    private String callUUID = "";
    private long generation;
    private long lastPoll;
    private volatile boolean initialized;
    private volatile boolean closed;

    PrivilegedMediaService(Context context, Runnable restoreOutput, Runnable acquireOutput) {
        this.context = context; this.restoreOutput = restoreOutput; this.acquireOutput = acquireOutput;
        leases.scheduleWithFixedDelay(this::expireOwner, 5, 5, TimeUnit.SECONDS);
    }

    synchronized void initialize() {
        if (closed) throw new IllegalStateException("media_service_closed");
        if (!initialized) {
            TelephonyWebRTCPeer.initialize(context);
            initialized = true;
        }
    }

    // Admission/heartbeat readiness is distinct from the owner's poll/stop control channel.
    // A healthy live owner remains ready; closing or quarantined native cleanup does not.
    boolean available() { return controlAvailable() && !closing; }

    private boolean controlAvailable() { return initialized && !closed; }

    synchronized String request(String encoded) throws Exception {
        JSONObject request = new JSONObject(PrivilegedMediaProtocol.bounded(encoded));
        if (request.optInt("version") != PrivilegedMediaProtocol.VERSION) throw new IllegalArgumentException("media_upgrade_required");
        long requestID = request.optLong("request_id", -1);
        if (requestID <= 0) throw new IllegalArgumentException("invalid_request_id");
        String action = request.optString("action");
        JSONObject result = new JSONObject().put("version", PrivilegedMediaProtocol.VERSION)
                .put("request_id", requestID).put("ok", true);
        if ("prepare".equals(action)) {
            initialize();
            return result.put("service_ready", available()).toString();
        }
        if (!controlAvailable()) throw new IllegalStateException("media_service_unavailable");
        String call = request.optString("call_uuid");
        long gen = request.optLong("generation", -1);
        PrivilegedMediaProtocol.requireIdentity(call, gen);
        String token = request.optString("owner_id");
        java.util.UUID.fromString(token);
        String key = call.toLowerCase(java.util.Locale.ROOT) + ":" + gen + ":" + token;
        if ("start".equals(action)) {
            if (terminal.containsKey(key)) throw new IllegalStateException("media_session_ended");
            if (peer != null) {
                if (!key.equals(owner)) throw new IllegalStateException("media_owner_busy");
                return result.toString();
            }
            boolean hostOnly = request.optBoolean("host_only", false);
            JSONArray ice = request.getJSONArray("ice_servers");
            owner = key; callUUID = call; generation = gen; lastPoll = now(); events.clear();
            peer = new TelephonyWebRTCPeer(context, call, gen, ice,
                    message -> enqueue(key, message), () -> fail(key), hostOnly);
            disposal = new CompletableFuture<>();
            try {
                acquireOutput.run();
                peer.start();
            } catch (RuntimeException | LinkageError error) {
                stopOwned();
                throw error;
            }
        } else {
            if (!key.equals(owner)) throw new IllegalStateException("media_owner_mismatch");
            lastPoll = now();
            if ("poll".equals(action)) {
                // One bounded event per response avoids overflowing the same framing limit.
                JSONObject event = events.pollFirst();
                if (event != null) result.put("event", event);
                result.put("active", peer != null && !closing);
            } else if ("signal".equals(action)) {
                if (peer == null || closing) throw new IllegalStateException("media_session_ended");
                JSONObject signal = request.getJSONObject("signal");
                if (!call.equalsIgnoreCase(signal.optString("call_uuid")) || gen != signal.optLong("generation", -1))
                    throw new IllegalArgumentException("media_identity_mismatch");
                String type = signal.optString("action");
                if (!"webrtc_offer".equals(type) && !"webrtc_ice".equals(type)) throw new IllegalArgumentException("media_signal_rejected");
                peer.receive(signal);
            } else if ("stop".equals(action)) {
                stopOwned();
            } else throw new IllegalArgumentException("media_command_rejected");
        }
        return PrivilegedMediaProtocol.bounded(result.toString());
    }

    private synchronized void enqueue(String key, JSONObject signal) throws Exception {
        if (closed || closing || !key.equals(owner) || peer == null) return;
        PrivilegedMediaProtocol.bounded(signal.toString());
        if (events.size() >= PrivilegedMediaProtocol.MAX_EVENTS) { fail(key); return; }
        events.addLast(signal);
    }

    private synchronized void fail(String key) {
        if (closing || !key.equals(owner) || peer == null) return;
        stopOwned();
        events.clear();
        try { events.add(new JSONObject().put("status", "webrtc_failed")
                .put("call_uuid", callUUID).put("generation", generation).put("reason", "carrier_media_unavailable")); }
        catch (Exception ignored) {}
    }

    private void stopOwned() {
        if (peer == null || closing) return;
        TelephonyWebRTCPeer active = peer;
        String key = owner;
        CompletableFuture<Void> completion = disposal;
        closing = true;
        terminal.put(key, now());
        while (terminal.size() > 64) terminal.remove(terminal.keySet().iterator().next());
        events.clear();
        // Never wait for native/audio workers while holding this monitor or a Binder/UI thread.
        active.closeAsync().whenComplete((unused, error) -> finishDisposal(active, key, completion, error));
    }

    private synchronized void finishDisposal(TelephonyWebRTCPeer active, String key,
                                             CompletableFuture<Void> completion, Throwable error) {
        if (peer != active || !closing || !key.equals(owner)) return;
        try { restoreOutput.run(); }
        catch (RuntimeException | LinkageError restoreError) { error = restoreError; }
        if (error == null) {
            peer = null;
            closing = false;
            completion.complete(null);
        } else {
            // A failed/unconfirmed release must never admit a second owner. Service restart is required.
            completion.completeExceptionally(new IllegalStateException("media_cleanup_failed"));
        }
    }

    private synchronized void expireOwner() {
        if (peer != null && !closing && now() - lastPoll > PrivilegedMediaProtocol.OWNER_LEASE_MILLIS) fail(owner);
    }

    private static long now() { return android.os.SystemClock.elapsedRealtime(); }

    synchronized CompletableFuture<Void> closeAsync() {
        if (!closed) {
            closed = true;
            stopOwned(); events.clear(); leases.shutdownNow();
        }
        return disposal;
    }

    @Override public void close() { closeAsync(); }
}
