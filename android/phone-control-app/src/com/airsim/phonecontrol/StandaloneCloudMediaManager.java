package com.airsim.phonecontrol;

import org.json.JSONObject;

import java.io.Closeable;
import java.net.URI;
import java.nio.charset.StandardCharsets;
import java.security.SecureRandom;
import java.time.Instant;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/** Owns the single cloud call. WebRTC bridges audio to loopback Shizuku PCM. */
final class StandaloneCloudMediaManager implements Closeable {
    private static volatile StandaloneCloudMediaManager instance;

    static StandaloneCloudMediaManager get(android.content.Context context) {
        StandaloneCloudMediaManager value = instance;
        if (value == null) {
            synchronized (StandaloneCloudMediaManager.class) {
                value = instance;
                if (value == null) instance = value = new StandaloneCloudMediaManager(context);
            }
        }
        return value;
    }

    private final android.content.Context context;
    private final ExecutorService sessions = Executors.newCachedThreadPool();
    private final Object lock = new Object();
    private final Map<String, Descriptor> owners = new LinkedHashMap<>();
    private CloudSession active;
    private String pendingOutgoingTelecomID;

    private StandaloneCloudMediaManager(android.content.Context context) {
        this.context = context.getApplicationContext();
    }

    void detachTelecomCall(String androidID) {
        if (androidID == null || androidID.isBlank()) return;
        synchronized (lock) {
            // Keep the owner until the ended lifecycle is published. Only forget
            // the id as a candidate for the next outgoing session.
            if (androidID.equals(pendingOutgoingTelecomID)) pendingOutgoingTelecomID = null;
        }
    }

    /** Bind a Telecom call as soon as it exists, before the iPhone answer arrives. */
    void attachTelecomCall(String androidID, String direction) {
        if (androidID == null || androidID.isBlank() || !"outgoing".equals(direction)) return;
        synchronized (lock) {
            pendingOutgoingTelecomID = androidID;
            if (active != null && active.descriptor.androidID.isEmpty()
                    && "outgoing".equals(active.descriptor.direction)) {
                active.descriptor.androidID = androidID;
                remember(active.descriptor);
            }
        }
    }

    void startOutgoing(JSONObject call) {
        if (call == null) return;
        try { start(Descriptor.from(call)); }
        catch (Exception error) { BridgeLog.error("standalone_outgoing_media_invalid", error); }
    }

    String androidCallIDFor(JSONObject call) {
        if (call == null) return "";
        synchronized (lock) {
            if (active == null) return "";
            Descriptor descriptor = active.descriptor;
            return new CloudCallTarget(descriptor.callID, descriptor.callUUID,
                    descriptor.generation, descriptor.androidID).resolve(
                    call.optString("call_id"), call.optString("call_uuid"),
                    call.optLong("generation", 1));
        }
    }

    void handleCallEvent(JSONObject registration, JSONObject event, StandaloneRelayClient relay) throws Exception {
        String state = event.optString("state", "");
        String direction = event.optString("direction", "");
        String androidID = event.optString("call_id", "");
        Descriptor descriptor;
        synchronized (lock) {
            descriptor = owners.get(androidID);
            if (descriptor == null && active != null) descriptor = active.descriptor;
        }
        boolean sameTelecomCall = descriptor != null && androidID.equals(descriptor.androidID);
        if ("incoming".equals(direction) && "incoming".equals(state) && !sameTelecomCall
                && (descriptor == null || !descriptor.androidID.isEmpty())) {
            descriptor = Descriptor.incoming(registration, androidID);
            JSONObject payload = identity(registration).put("event", "incoming_call")
                    .put("call_id", descriptor.callID).put("call_uuid", descriptor.callUUID)
                    .put("generation", descriptor.generation).put("call_secret", descriptor.secret)
                    .put("number", event.optString("number", "")).put("caller_name", "")
                    .put("issued_at", Instant.now().toString())
                    .put("expires_at", Instant.now().plusSeconds(90).toString())
                    .put("media_transport", CloudCallMedia.WEBRTC)
                    .put("agent_media_capabilities", StandaloneAgentStore.mediaCapabilities());
            JSONObject accepted = relay.postJSON(registration, "/v1/events/call", payload, 15_000);
            descriptor.mediaTransport = accepted.optString("media_transport", CloudCallMedia.WEBRTC);
            start(descriptor);
        } else if (descriptor != null && descriptor.androidID.isEmpty()
                && "outgoing".equals(direction) && !"ended".equals(state)) {
            descriptor.androidID = androidID;
            synchronized (lock) { remember(descriptor); }
        }
        if (descriptor != null && !androidID.isBlank() && !androidID.equals(descriptor.androidID)) {
            descriptor = null;
        }
        if (descriptor != null) {
            String phase = phase(state);
            if (!phase.isEmpty()) publishLifecycle(registration, relay, descriptor, phase);
            if ("ended".equals(state)) {
                synchronized (lock) {
                    owners.remove(androidID);
                    if (androidID.equals(pendingOutgoingTelecomID)) pendingOutgoingTelecomID = null;
                }
                closeActive(descriptor);
            }
        }
    }

    private void publishLifecycle(JSONObject registration, StandaloneRelayClient relay,
                                  Descriptor descriptor, String phase) throws Exception {
        JSONObject lifecycle = lifecycleEvent(registration, descriptor.callID, descriptor.callUUID,
                descriptor.generation, phase);
        try {
            relay.postJSON(registration, "/v1/events/call-state", lifecycle, 12_000);
        } catch (RelayHTTPException error) {
            JSONObject stuck = mismatchSnapshot(error);
            CallLifecycleConflict.Action action = CallLifecycleConflict.decide(
                    stuck != null, phase, descriptor.callID, descriptor.callUUID,
                    stuck == null ? "" : stuck.optString("call_id"),
                    stuck == null ? "" : stuck.optString("call_uuid"),
                    stuck == null ? "" : stuck.optString("phase"));
            if (action == CallLifecycleConflict.Action.RETHROW) throw error;
            if (action != CallLifecycleConflict.Action.DROP) {
                postPhase(registration, relay, stuck.optString("call_id"), stuck.optString("call_uuid"),
                        stuck.optLong("generation", 1), "ended");
            }
            if (action == CallLifecycleConflict.Action.END_OPEN_THEN_RETRY) {
                postPhase(registration, relay, descriptor.callID, descriptor.callUUID,
                        descriptor.generation, "connecting");
            }
            if (action == CallLifecycleConflict.Action.END_THEN_RETRY
                    || action == CallLifecycleConflict.Action.END_OPEN_THEN_RETRY) {
                relay.postJSON(registration, "/v1/events/call-state", lifecycle, 12_000);
            }
            BridgeLog.info("cloud_lifecycle_replaced_stuck_call phase=" + phase);
        }
    }

    private void postPhase(JSONObject registration, StandaloneRelayClient relay,
                           String callID, String callUUID, long generation, String phase) throws Exception {
        relay.postJSON(registration, "/v1/events/call-state",
                lifecycleEvent(registration, callID, callUUID, generation, phase), 12_000);
    }

    private static JSONObject lifecycleEvent(JSONObject registration, String callID, String callUUID,
                                             long generation, String phase) throws Exception {
        return identity(registration).put("event", "call_state")
                .put("call_id", callID).put("call_uuid", callUUID)
                .put("generation", generation).put("phase", phase)
                .put("source", "agent").put("timestamp", Instant.now().toString())
                .put("trace_id", "standalone-" + callUUID + "-" + phase);
    }

    private static JSONObject mismatchSnapshot(RelayHTTPException error) {
        if (error.statusCode() != 409 || error.getMessage() == null) return null;
        int start = error.getMessage().indexOf('{');
        if (start < 0) return null;
        try {
            JSONObject body = new JSONObject(error.getMessage().substring(start));
            if (!"identity_mismatch".equals(body.optString("reason"))) return null;
            return body.optJSONObject("lifecycle");
        } catch (Exception ignored) {
            return null;
        }
    }

    private void start(Descriptor descriptor) {
        synchronized (lock) {
            if (active != null && active.descriptor.same(descriptor)) return;
            if ("outgoing".equals(descriptor.direction) && descriptor.androidID.isEmpty()
                    && CallRepository.contains(pendingOutgoingTelecomID)) {
                descriptor.androidID = pendingOutgoingTelecomID;
            }
            if (active != null) active.close();
            active = new CloudSession(descriptor);
            remember(descriptor);
            sessions.execute(active);
        }
    }

    private void remember(Descriptor descriptor) {
        if (descriptor.androidID == null || descriptor.androidID.isBlank()) return;
        owners.put(descriptor.androidID, descriptor);
        while (owners.size() > 8) owners.remove(owners.keySet().iterator().next());
    }

    private void closeActive(Descriptor descriptor) {
        synchronized (lock) {
            if (active != null && active.descriptor.same(descriptor)) {
                active.close();
                active = null;
            }
        }
    }

    private final class CloudSession implements Runnable, Closeable {
        final Descriptor descriptor;
        volatile boolean running = true;
        volatile StandaloneWebSocket webSocket;
        volatile WebRTCCloudPeer webRTC;
        volatile String mediaTransport;
        volatile boolean mediaStarted;

        CloudSession(Descriptor descriptor) {
            this.descriptor = descriptor;
            this.mediaTransport = descriptor.mediaTransport;
        }

        @Override public void run() {
            while (running) {
                StandaloneWebSocket owner = null;
                try {
                    URI endpoint = URI.create(descriptor.relayURL.replaceFirst("^https", "wss")
                            + "/v1/calls/" + descriptor.callUUID + "/connect?role=agent");
                    owner = StandaloneWebSocket.connect(endpoint, descriptor.secret);
                    synchronized (this) {
                        if (!running) { closeSocket(owner); return; }
                        webSocket = owner;
                    }
                    // Overlap call-scoped ICE retrieval with ringing/signaling. Carrier audio
                    // still starts only after Telecom confirms the answer below.
                    prepareWebRTC(owner);
                    owner.writeText(status("agent_ready", ""));
                    BridgeLog.info("standalone_cloud_media_connected call_uuid="
                            + DebugRedactor.safeIdentifier(descriptor.callUUID));
                    readLoop(owner);
                } catch (Exception error) {
                    if (running) BridgeLog.error("standalone_cloud_media_disconnected", error);
                } finally {
                    closeSocket(owner);
                    synchronized (this) {
                        if (webSocket == owner) {
                            webSocket = null;
                            // The next answer on a new socket must start WebRTC again.
                            mediaStarted = false;
                            closeSocket(webRTC); webRTC = null;
                        }
                    }
                }
                if (running) {
                    try { Thread.sleep(1_000); }
                    catch (InterruptedException interrupted) { Thread.currentThread().interrupt(); return; }
                }
            }
        }

        private void readLoop(StandaloneWebSocket owner) throws Exception {
            while (running && webSocket == owner) {
                StandaloneWebSocket.Message message = owner.read();
                // Cloud audio is WebRTC. Binary Relay frames are not a PCM pump.
                if (message.opcode() == 2) continue;
                JSONObject control = new JSONObject(new String(message.payload(), StandardCharsets.UTF_8));
                if (control.has("call_uuid") && !descriptor.callUUID.equalsIgnoreCase(control.optString("call_uuid"))) continue;
                if (control.has("generation") && descriptor.generation != control.optLong("generation", -1)) continue;
                String action = control.optString("action", "");
                if (action.startsWith("webrtc_")) {
                    WebRTCCloudPeer peer = webRTC;
                    if (mediaStarted && peer != null && CloudCallMedia.WEBRTC.equals(mediaTransport)) peer.receive(control);
                    continue;
                }
                if (!"answer".equals(action) && !"reject".equals(action) && !"end".equals(action)) continue;
                if ("answer".equals(action)) mediaTransport = control.optString("media_transport", descriptor.mediaTransport);
                if ("answer".equals(action) && (!CloudCallMedia.WEBRTC.equals(mediaTransport)
                        || !ShizukuBridgeManager.get(context).mediaAvailable())) {
                    owner.writeText(status("action_error", "privileged_media_unavailable"));
                    continue;
                }
                JSONObject command = new JSONObject().put("command_id",
                                control.optString("command_id", UUID.randomUUID().toString()))
                        .put("type", "call_control").put("action", action)
                        .put("call", new JSONObject().put("call_id", descriptor.callID)
                                .put("call_uuid", descriptor.callUUID)
                                .put("generation", descriptor.generation));
                JSONObject result = StandaloneAgentGateway.get(context).executeCloudCommand(command);
                if (!"completed".equals(result.optString("status"))) {
                    String error = result.optString("error", "Telecom command failed");
                    if ("answer".equals(action) && !CloudAnswerReplayPolicy.isFinal(action, false, error)) {
                        owner.writeText(status("answer_pending", ""));
                        continue;
                    }
                    owner.writeText(status("action_error", error));
                    continue;
                }
                if ("answer".equals(action)) {
                    owner.writeText(status("answer_ok", ""));
                    if (!mediaStarted) {
                        StandaloneAgentStore.startCloudCallMedia(mediaTransport, () -> {
                            mediaStarted = true;
                            BridgeLog.info("standalone_webrtc_starting call_uuid="
                                    + DebugRedactor.safeIdentifier(descriptor.callUUID));
                            startWebRTC(owner);
                        });
                    }
                } else {
                    owner.writeText(status("reject".equals(action) ? "rejected" : "ended", ""));
                    running = false;
                }
            }
        }

        private void prepareWebRTC(StandaloneWebSocket owner) {
            synchronized (this) {
                if (!running || webSocket != owner || webRTC != null) return;
                webRTC = new WebRTCCloudPeer(context, descriptor.callUUID, descriptor.generation,
                        descriptor.relayURL, descriptor.secret, signal -> {
                    if (running && webSocket == owner) owner.writeText(signal.toString());
                }, () -> closeSocket(owner));
                webRTC.prepare();
            }
        }

        private void startWebRTC(StandaloneWebSocket owner) {
            synchronized (this) {
                if (!running || webSocket != owner) return;
                prepareWebRTC(owner);
                if (webRTC != null) webRTC.start();
            }
        }

        private String status(String value, String message) throws Exception {
            JSONObject result = new JSONObject().put("status", value).put("call_id", descriptor.callID)
                    .put("call_uuid", descriptor.callUUID).put("generation", descriptor.generation);
            if (!message.isEmpty()) result.put("message", message);
            return result.toString();
        }

        @Override public synchronized void close() {
            running = false;
            mediaStarted = false;
            closeSocket(webSocket);
            closeSocket(webRTC); webRTC = null;
        }
    }

    private static final class Descriptor {
        final String callID;
        final String callUUID;
        final long generation;
        final String secret;
        final String relayURL;
        final String direction;
        String mediaTransport = CloudCallMedia.WEBRTC;
        volatile String androidID;

        Descriptor(String callID, String callUUID, long generation, String secret,
                   String relayURL, String direction, String androidID) {
            this.callID = callID;
            this.callUUID = callUUID;
            this.generation = generation <= 0 ? 1 : generation;
            this.secret = secret;
            this.relayURL = relayURL;
            this.direction = direction;
            this.androidID = androidID;
        }

        static Descriptor from(JSONObject call) {
            Descriptor result = new Descriptor(call.optString("call_id"), call.optString("call_uuid"),
                    call.optLong("generation", 1), call.optString("call_secret"),
                    call.optString("relay_url"), call.optString("direction", "outgoing"), "");
            result.mediaTransport = call.optString("media_transport", CloudCallMedia.WEBRTC);
            result.validate();
            return result;
        }

        static Descriptor incoming(JSONObject registration, String androidID) {
            byte[] secret = new byte[32];
            new SecureRandom().nextBytes(secret);
            StringBuilder encoded = new StringBuilder(64);
            for (byte value : secret) encoded.append(String.format("%02x", value & 0xff));
            Descriptor result = new Descriptor("android-" + System.currentTimeMillis(), UUID.randomUUID().toString(), 1,
                    encoded.toString(), registration.optString("relay_url"), "incoming", androidID);
            result.validate();
            return result;
        }

        private void validate() {
            if (callID.isBlank() || callUUID.isBlank() || secret.isBlank()) {
                throw new IllegalArgumentException("Cloud call description is missing identity or key");
            }
            URI relay = URI.create(relayURL);
            if (!"https".equalsIgnoreCase(relay.getScheme()) || relay.getHost() == null
                    || relay.getRawUserInfo() != null) {
                throw new IllegalArgumentException("Cloud call Relay must be an HTTPS address without embedded credentials");
            }
        }

        boolean same(Descriptor other) { return other != null && generation == other.generation && callUUID.equalsIgnoreCase(other.callUUID); }
    }

    private static JSONObject identity(JSONObject registration) throws Exception {
        return new JSONObject().put("device_id", registration.getString("device_id"))
                .put("device_secret", registration.getString("device_secret"));
    }

    private static String phase(String state) {
        return switch (state) {
            case "incoming" -> "ringing";
            case "dialing", "alerting" -> "connecting";
            case "active", "held" -> "active";
            case "ended" -> "ended";
            default -> "";
        };
    }

    private static void closeSocket(Object value) {
        if (value instanceof Closeable closeable) {
            try { closeable.close(); } catch (Exception ignored) {}
        }
    }

    @Override public void close() {
        synchronized (lock) {
            if (active != null) active.close();
            active = null;
        }
    }
}
