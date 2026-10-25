package com.airsim.phonecontrol;

import org.json.JSONObject;
import java.io.Closeable;
import java.io.IOException;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicReference;

/** Authenticated local signaling and session-scoped carrier readiness. No local audio listener. */
final class VoWLANWebRTCBridge implements Closeable {
    private final android.content.Context context;
    private final Object lock = new Object();
    private final Map<String, String> terminal = new LinkedHashMap<>();
    private WebRTCCloudPeer peer;
    private String owner = "";
    private String state = "closed";
    private boolean closed;

    VoWLANWebRTCBridge(android.content.Context context) { this.context = context.getApplicationContext(); }

    String handle(String body) throws Exception {
        JSONObject message = new JSONObject(PrivilegedMediaProtocol.bounded(body));
        String action = message.optString("action");
        if ("webrtc_offer".equals(action)) return offer(message);
        if ("webrtc_ice".equals(action)) {
            String key = identity(message);
            synchronized (lock) {
                if (closed || peer == null || !key.equals(owner)) throw new IllegalStateException("session_mismatch");
                peer.receive(message);
            }
            return "{\"ok\":true}";
        }
        throw new IllegalArgumentException("bad_request");
    }

    String status(String body, boolean stop) throws Exception {
        JSONObject message = new JSONObject(PrivilegedMediaProtocol.bounded(body));
        if (message.optInt("version") != 1) throw new IllegalArgumentException("upgrade_required");
        String key = identity(message);
        if (stop) terminate(key, "closed"); // Also tombstones a canceled offer that has not arrived yet.
        String result;
        synchronized (lock) { result = terminal.getOrDefault(key, key.equals(owner) ? state : "closed"); }
        return new JSONObject().put("version", 1).put("call_uuid", message.getString("call_uuid"))
                .put("generation", message.getLong("generation")).put("session_id", message.getString("session_id"))
                .put("status", result).put("reason", "failed".equals(result) ? "carrier_media_unavailable" : "").toString();
    }

    private String offer(JSONObject message) throws Exception {
        String key = identity(message);
        String sdp = message.optString("sdp");
        if (sdp.isEmpty() || sdp.length() > PrivilegedMediaProtocol.MAX_SDP_CHARS) throw new IllegalArgumentException("invalid_sdp");
        CountDownLatch answered = new CountDownLatch(1);
        AtomicReference<JSONObject> answer = new AtomicReference<>();
        synchronized (lock) {
            if (closed || peer != null || terminal.containsKey(key)) throw new IllegalStateException("session_busy");
            owner = key; state = "preparing";
            peer = WebRTCCloudPeer.host(context, message.getString("call_uuid"), message.getLong("generation"), signal -> {
                synchronized (lock) {
                    if (!key.equals(owner) || peer == null) return;
                    if ("webrtc_answer".equals(signal.optString("action"))) { answer.set(signal); answered.countDown(); }
                    if ("webrtc_ready".equals(signal.optString("status"))
                            && message.getString("session_id").equals(signal.optString("session_id"))) state = "ready";
                }
            }, () -> { terminate(key, "failed"); answered.countDown(); });
            RemoteAudioSessionRegistry.setVoWLAN(true);
            peer.start(); peer.receive(message);
        }
        boolean received;
        try { received = answered.await(20, TimeUnit.SECONDS); }
        catch (InterruptedException interrupted) {
            terminate(key, "closed");
            Thread.currentThread().interrupt();
            throw interrupted;
        }
        if (!received || answer.get() == null) {
            terminate(key, "failed");
            throw new IOException("webrtc_answer_unavailable");
        }
        synchronized (lock) {
            if (!key.equals(owner) || peer == null || terminal.containsKey(key)) throw new IOException("webrtc_session_closed");
        }
        return answer.get().toString();
    }

    private static String identity(JSONObject message) throws Exception {
        String call = message.getString("call_uuid");
        long generation = message.getLong("generation");
        String session = message.getString("session_id");
        PrivilegedMediaProtocol.requireIdentity(call, generation);
        UUID.fromString(session);
        return call.toLowerCase(java.util.Locale.ROOT) + ":" + generation + ":" + session;
    }

    private void terminate(String key, String result) {
        WebRTCCloudPeer active = null;
        synchronized (lock) {
            terminal.put(key, result);
            while (terminal.size() > 64) terminal.remove(terminal.keySet().iterator().next());
            if (key.equals(owner)) {
                active = peer; peer = null; state = result;
                RemoteAudioSessionRegistry.setVoWLAN(false);
            }
        }
        if (active != null) active.close();
    }

    boolean hasSession() { synchronized (lock) { return peer != null; } }

    void stopCurrent() {
        synchronized (lock) { if (!owner.isEmpty()) terminate(owner, "closed"); }
    }

    @Override public void close() {
        synchronized (lock) {
            closed = true;
            if (!owner.isEmpty()) terminate(owner, "closed");
        }
    }
}
