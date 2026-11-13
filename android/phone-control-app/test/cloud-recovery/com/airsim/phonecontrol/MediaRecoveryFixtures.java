package com.airsim.phonecontrol;

import android.content.Context;
import java.io.Closeable;
import java.io.IOException;
import java.net.URI;
import java.nio.charset.StandardCharsets;
import java.util.List;
import java.util.concurrent.BlockingQueue;
import java.util.concurrent.CopyOnWriteArrayList;
import java.util.concurrent.LinkedBlockingQueue;
import java.util.concurrent.atomic.AtomicInteger;
import org.json.JSONArray;
import org.json.JSONObject;

// Only platform, network and native boundaries are fake. Tests run the actual CloudSession loop.
final class StandaloneWebSocket implements Closeable {
    record Message(int opcode, byte[] payload) {}
    static final List<StandaloneWebSocket> connections = new CopyOnWriteArrayList<>();
    final List<String> sent = new CopyOnWriteArrayList<>();
    final BlockingQueue<Message> received = new LinkedBlockingQueue<>();
    volatile boolean closed;
    static StandaloneWebSocket connect(URI uri, String secret) {
        var socket = new StandaloneWebSocket(); connections.add(socket); return socket;
    }
    void writeText(String text) throws IOException {
        if (closed) throw new IOException("fixture socket closed");
        sent.add(text);
    }
    Message read() throws IOException, InterruptedException {
        Message value = received.take();
        if (closed) throw new IOException("fixture socket closed");
        return value;
    }
    void receive(String action) throws Exception {
        receive(new JSONObject().put("action", action));
    }
    void receive(JSONObject value) {
        received.add(new Message(1, value.toString().getBytes(StandardCharsets.UTF_8)));
    }
    public void close() { closed = true; received.offer(new Message(8, new byte[0])); }
}
final class WebRTCCloudPeer implements Closeable {
    interface Signals { void send(JSONObject signal) throws Exception; }
    interface Failure { void failed(String reason); }
    static final List<WebRTCCloudPeer> peers = new CopyOnWriteArrayList<>();
    final Failure failure;
    volatile boolean started, closed, deferred;
    final AtomicInteger activations = new AtomicInteger();
    final AtomicInteger signals = new AtomicInteger();
    WebRTCCloudPeer(Context context, String uuid, long generation, String relay, String secret,
                    Signals signal, Failure failure) { this.failure = failure; peers.add(this); }
    volatile boolean connected = true;
    boolean transportConnected(String session) { return connected && !closed; }
    void prepare() {}
    void start(boolean deferred) { this.deferred = deferred; started = true; }
    void replayCarrierReady(String session) {}
    void activateCarrierAudio() { activations.incrementAndGet(); }
    void receive(JSONObject signal) { signals.incrementAndGet(); }
    void fail(String reason) { close(); failure.failed(reason); }
    public void close() { closed = true; }
}
final class BridgeLog {
    static void info(String text) {}
    static void error(String text, Throwable error) {}
}
final class DebugRedactor { static String safeIdentifier(String value) { return "fixture"; } }
final class CallRepository {
    static volatile boolean preparable = true;
    static volatile int callState = android.telecom.Call.STATE_ACTIVE;
    static void executeRemote(Context context, String request, String action, String id, String number) { StandaloneAgentGateway.actions.add(action + ":" + id); }
    static volatile boolean live;
    static boolean hasLiveCalls() { return live; }
    static boolean belongsToReservation(String id, String reservation) { return id.equals(reservation); }
    static boolean contains(String id) { return false; }
    static boolean canPrepareOutgoingMedia(String id) { return preparable; }
    static int state(String id) { return callState; }
}
final class ShizukuBridgeManager {
    static ShizukuBridgeManager get(Context context) { return new ShizukuBridgeManager(); }
    boolean mediaAvailable() { return true; }
}
final class StandaloneAgentStore {
    static JSONArray mediaCapabilities() { return new JSONArray().put("webrtc"); }
    static void startCloudCallMedia(String transport, Runnable start) { CloudCallMedia.start(transport, start); }
}
final class StandaloneAgentGateway {
    static final List<String> actions = new CopyOnWriteArrayList<>();
    static StandaloneAgentGateway get(Context context) { return new StandaloneAgentGateway(); }
    JSONObject executeCloudCommand(JSONObject command) throws Exception {
        actions.add(command.getString("action"));
        return new JSONObject().put("status", "completed");
    }
}
final class StandaloneRelayClient {
    JSONObject postJSON(JSONObject registration, String path, JSONObject payload, int timeout) throws Exception { return new JSONObject(); }
}
