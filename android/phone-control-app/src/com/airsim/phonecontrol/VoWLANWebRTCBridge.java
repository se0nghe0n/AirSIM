package com.airsim.phonecontrol;

import org.json.JSONObject;

import java.io.Closeable;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicReference;

/** One host-ICE WebRTC session on the VoWLAN control link. Telephony PCM stays on 127.0.0.1:7580. */
final class VoWLANWebRTCBridge implements Closeable {
    private final android.content.Context context;
    private final VoWLANWebRTCControl.Sessions sessions = new VoWLANWebRTCControl.Sessions();
    private final Object lock = new Object();
    private WebRTCCloudPeer peer;

    VoWLANWebRTCBridge(android.content.Context context) {
        this.context = context.getApplicationContext();
    }

    String handle(String body) throws Exception {
        JSONObject message = new JSONObject(body == null ? "" : body);
        String action = message.optString("action");
        if ("webrtc_offer".equals(action)) return offer(message);
        if ("webrtc_ice".equals(action)) {
            WebRTCCloudPeer active;
            synchronized (lock) { active = peer; }
            if (active == null) throw new IllegalStateException("session_busy");
            active.receive(message);
            return "{\"ok\":true}";
        }
        throw new IllegalArgumentException("bad_request");
    }

    private String offer(JSONObject message) throws Exception {
        String sessionID = message.optString("session_id");
        if (!sessions.acceptOffer(sessionID)) throw new IllegalStateException("session_busy");
        CountDownLatch ready = new CountDownLatch(1);
        AtomicReference<JSONObject> answer = new AtomicReference<>();
        AtomicReference<Exception> failure = new AtomicReference<>();
        WebRTCCloudPeer created = WebRTCCloudPeer.host(
                context,
                message.optString("call_uuid"),
                message.optLong("generation"),
                signal -> {
                    if ("webrtc_answer".equals(signal.optString("action"))) {
                        answer.set(signal);
                        ready.countDown();
                    }
                },
                () -> {
                    failure.set(new java.io.IOException("webrtc_failed"));
                    ready.countDown();
                });
        synchronized (lock) {
            closePeer();
            peer = created;
        }
        RemoteAudioSessionRegistry.setVoWLAN(true);
        created.start();
        created.receive(message);
        if (!ready.await(20, TimeUnit.SECONDS) || answer.get() == null) {
            close();
            if (failure.get() != null) throw failure.get();
            throw new java.io.IOException("webrtc_answer_timeout");
        }
        String payload = answer.get().toString();
        if (!payload.contains("webrtc_answer")) {
            close();
            throw new IllegalArgumentException("invalid webrtc answer");
        }
        return payload;
    }

    boolean hasSession() {
        synchronized (lock) { return peer != null; }
    }

    @Override public void close() {
        sessions.release();
        closePeer();
        RemoteAudioSessionRegistry.setVoWLAN(false);
    }

    private void closePeer() {
        WebRTCCloudPeer active;
        synchronized (lock) {
            active = peer;
            peer = null;
        }
        if (active != null) active.close();
    }
}
