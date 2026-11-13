package com.airsim.phonecontrol;

import android.content.Context;
import android.telecom.TelecomManager;
import android.app.role.RoleManager;
import java.lang.reflect.Field;
import java.time.Instant;
import java.util.UUID;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.LinkedBlockingQueue;
import java.util.function.BooleanSupplier;
import org.json.JSONObject;

/** Actual CloudSession reservation/commit state machine with fake OS/network/native boundaries. */
public final class StrictPreDialTests {
    static int checks;
    static void check(boolean value, String message) { if (!value) throw new AssertionError(message); checks++; }
    static void await(BooleanSupplier condition) throws Exception {
        long until = System.nanoTime() + 3_000_000_000L;
        while (!condition.getAsBoolean() && System.nanoTime() < until) Thread.sleep(5);
        check(condition.getAsBoolean(), "asynchronous condition timeout");
    }
    static final class Fixture implements AutoCloseable {
        final Context context;
        final TelecomManager telecom = new TelecomManager();
        final StandaloneCloudMediaManager manager;
        final String uuid = UUID.randomUUID().toString(), session = UUID.randomUUID().toString();
        final JSONObject call, command;
        StandaloneWebSocket socket;
        WebRTCCloudPeer peer;
        Fixture() throws Exception { this(new Context()); }
        Fixture(Context context) throws Exception {
            this.context = context;
            context.setSystemService(RoleManager.class, new RoleManager());
            context.setSystemService(TelecomManager.class, telecom);
            CallRepository.live = false;
            StandaloneWebSocket.connections.clear(); WebRTCCloudPeer.peers.clear(); StandaloneAgentGateway.actions.clear();
            var constructor = StandaloneCloudMediaManager.class.getDeclaredConstructor(Context.class);
            constructor.setAccessible(true); manager = constructor.newInstance(context);
            call = new JSONObject().put("call_id", "call-" + uuid).put("call_uuid", uuid).put("generation", 1)
                    .put("call_secret", "test-only").put("relay_url", "https://fixture.invalid")
                    .put("direction", "outgoing").put("pre_dial", true).put("preparation_expires_at", Instant.now().plusSeconds(20).toString());
            command = new JSONObject().put("type", "prepare_dial").put("number", "fixture-not-a-phone")
                    .put("command_id", UUID.randomUUID().toString()).put("call", call);
        }
        void prepare() throws Exception {
            manager.prepareOutgoing(command);
            await(() -> !WebRTCCloudPeer.peers.isEmpty() && WebRTCCloudPeer.peers.get(0).started);
            socket = StandaloneWebSocket.connections.get(0); peer = WebRTCCloudPeer.peers.get(0);
            check(peer.deferred && peer.activations.get() == 0 && telecom.dialCount == 0, "Preparation must not dial/capture");
            socket.receive(new JSONObject().put("action", "webrtc_offer").put("session_id", session).put("call_uuid", uuid).put("generation", 1));
            await(() -> peer.signals.get() == 1);
        }
        JSONObject commit() throws Exception {
            return new JSONObject().put("action", "commit_dial").put("call_id", call.getString("call_id"))
                    .put("call_uuid", uuid).put("generation", 1).put("session_id", session).put("command_id", command.getString("command_id"));
        }
        void assertNoDial() throws Exception { Thread.sleep(60); check(telecom.dialCount == 0, "Unexpected Telecom effect"); }
        public void close() throws Exception {
            android.os.Handler.dispatch = Runnable::run;
            manager.close(); Field field = StandaloneCloudMediaManager.class.getDeclaredField("sessions");
            field.setAccessible(true); ((ExecutorService) field.get(manager)).shutdownNow(); CallRepository.live = false;
        }
    }
    public static void main(String[] args) throws Exception {
        try (Fixture f = new Fixture()) {
            f.prepare(); f.socket.receive(f.commit().put("session_id", "stale")); f.assertNoDial();
            f.socket.receive(f.commit().put("generation", 2)); f.assertNoDial();
            f.socket.receive(f.commit()); await(() -> f.telecom.dialCount == 1);
            f.socket.receive(f.commit()); Thread.sleep(60); check(f.telecom.dialCount == 1, "Commit replay dialed twice");
            check(f.peer.activations.get() == 0, "Dial invocation must not imply carrier ACTIVE");
            f.manager.attachTelecomCall("foreign", "outgoing");
            check(f.manager.androidCallIDFor(f.call).isEmpty(), "Foreign Telecom call was bound");
            f.manager.attachTelecomCall(f.uuid, "outgoing");
            check(f.uuid.equals(f.manager.androidCallIDFor(f.call)), "Tagged Telecom call not bound");
            f.manager.telecomCallActive(f.uuid); await(() -> f.peer.activations.get() == 1);
            try { f.manager.prepareOutgoing(f.command); throw new AssertionError("Reservation replay accepted"); }
            catch (IllegalStateException expected) { checks++; }
        }
        try (Fixture f = new Fixture()) {
            f.prepare(); f.peer.connected = false; f.socket.receive(f.commit()); await(() -> f.socket.closed); f.assertNoDial();
        }
        try (Fixture f = new Fixture()) {
            f.prepare(); f.manager.attachTelecomCall("incoming", "incoming"); f.socket.receive(f.commit()); f.assertNoDial();
            check(f.socket.closed && f.peer.closed, "Incoming interruption retained reservation");
        }
        try (Fixture f = new Fixture()) {
            f.prepare(); f.socket.close(); await(() -> f.peer.closed); Thread.sleep(100);
            check(StandaloneWebSocket.connections.size() == 1, "Pre-dial reconnected/fell back"); f.assertNoDial();
        }
        try (Fixture f = new Fixture()) {
            f.prepare(); f.socket.receive(new JSONObject().put("action", "webrtc_offer").put("session_id", UUID.randomUUID().toString()));
            await(() -> f.socket.closed); f.socket.receive(f.commit()); f.assertNoDial();
        }
        try (Fixture f = new Fixture()) {
            f.prepare(); LinkedBlockingQueue<Runnable> pending = new LinkedBlockingQueue<>(); android.os.Handler.dispatch = pending::add;
            f.socket.receive(f.commit()); await(() -> !pending.isEmpty());
            check(!f.manager.cancelStrictOutgoing(new JSONObject(f.call.toString()).put("generation", 2)), "Foreign HTTP cancellation accepted");
            check(f.manager.cancelStrictOutgoing(f.call), "HTTP end must cancel queued commit"); await(() -> f.socket.closed); pending.take().run(); f.assertNoDial();
        }
        try (Fixture f = new Fixture()) {
            f.prepare(); f.socket.receive(f.commit()); await(() -> f.telecom.dialCount == 1);
            check(f.manager.cancelStrictOutgoing(f.call), "HTTP end must cancel pending tagged binding"); await(() -> f.socket.closed);
            JSONObject second = new JSONObject(f.command.toString());
            second.getJSONObject("call").put("call_uuid", UUID.randomUUID().toString());
            try { f.manager.prepareOutgoing(second); throw new AssertionError("Unbound committed cancellation was replaced"); }
            catch (IllegalStateException expected) { checks++; }
            f.manager.attachTelecomCall("foreign", "outgoing"); check(StandaloneAgentGateway.actions.isEmpty(), "Cancellation ended foreign call");
            f.manager.attachTelecomCall(f.uuid, "outgoing"); await(() -> StandaloneAgentGateway.actions.contains("end:" + f.uuid));
            check(f.telecom.dialCount == 1, "Cancel raced into a duplicate dial");
        }
        try (Fixture f = new Fixture()) {
            f.prepare(); f.telecom.dialFailure = new SecurityException("fixture revoked role");
            f.socket.receive(f.commit()); await(() -> f.socket.closed); f.assertNoDial();
            JSONObject retry = new JSONObject(f.command.toString());
            retry.getJSONObject("call").put("call_uuid", UUID.randomUUID().toString());
            f.manager.prepareOutgoing(retry);
            await(() -> StandaloneWebSocket.connections.size() == 2);
            check(true, "Definite Telecom refusal must release admission");
        }
        Context persisted;
        JSONObject previous;
        try (Fixture f = new Fixture()) { f.prepare(); persisted = f.context.reopen(); previous = f.command; }
        try (Fixture f = new Fixture(persisted)) {
            try { f.manager.prepareOutgoing(previous); throw new AssertionError("Restart resurrected reservation"); }
            catch (IllegalStateException expected) { checks++; }
            f.assertNoDial();
        }
        try (Fixture f = new Fixture()) {
            f.call.put("preparation_expires_at", Instant.now().plusMillis(100).toString()); f.prepare(); await(() -> f.socket.closed);
            f.socket.receive(f.commit()); f.assertNoDial();
        }
        System.out.println("Strict pre-dial production CloudSession tests passed (" + checks + " checks; no real calls)");
    }
}
