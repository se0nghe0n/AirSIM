package com.airsim.phonecontrol;

import android.content.Context;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.UUID;
import java.util.concurrent.ExecutorService;
import java.util.function.BooleanSupplier;
import org.json.JSONObject;

/** Actual CloudSession loop with inert network/native boundaries. No phone or audio access. */
public final class OutgoingDialAcceptanceTests {
    private static int checks;

    private static void check(boolean value, String detail) {
        if (!value) throw new AssertionError(detail);
        checks++;
    }

    private static void await(BooleanSupplier predicate) throws Exception {
        long deadline = System.nanoTime() + 5_000_000_000L;
        while (!predicate.getAsBoolean() && System.nanoTime() < deadline) Thread.sleep(5);
        check(predicate.getAsBoolean(), "asynchronous condition timed out");
    }

    private static JSONObject call(String uuid, long generation, String direction) throws Exception {
        return new JSONObject().put("call_id", "fixture-call").put("call_uuid", uuid)
                .put("generation", generation).put("call_secret", "fixture-secret")
                .put("relay_url", "https://fixture.invalid").put("direction", direction)
                .put("media_transport", "webrtc");
    }

    private static JSONObject peerConnected(String role) throws Exception {
        // This is the deployed Relay's broadcastStatus envelope: the field is event, not status.
        return new JSONObject().put("event", "peer_connected").put("role", role);
    }

    private static long accepted(StandaloneWebSocket socket) {
        return socket.sent.stream().filter(s -> s.contains(OutgoingDialAcceptance.STATUS)).count();
    }

    private static StandaloneWebSocket connection(int count) throws Exception {
        await(() -> StandaloneWebSocket.connections.size() >= count);
        StandaloneWebSocket socket = StandaloneWebSocket.connections.get(count - 1);
        await(() -> socket.sent.stream().anyMatch(s -> s.contains("agent_ready")));
        return socket;
    }

    private static void policiesAndWiring(Path servicePath) throws Exception {
        for (String type : new String[]{"dial", "call_control", "send_sms", "", null}) {
            for (String status : new String[]{"completed", "failed", "pending", "", null}) {
                check(OutgoingDialAcceptance.completed(type, status)
                        == ("dial".equals(type) && "completed".equals(status)), "success is dial-specific");
            }
        }
        for (String direction : new String[]{"outgoing", "incoming", "", null}) {
            for (int bits = 0; bits < 8; bits++) {
                boolean running = (bits & 1) != 0, current = (bits & 2) != 0, blocked = (bits & 4) != 0;
                check(OutgoingDialAcceptance.mayAnnounce(direction, running, current, blocked)
                        == ("outgoing".equals(direction) && running && current && !blocked), "announcement gates");
            }
        }
        check(OutgoingDialAcceptance.replayFor("peer_connected", "iphone", ""), "late iPhone gets replay");
        for (String role : new String[]{"agent", "watch", "", null}) {
            check(!OutgoingDialAcceptance.replayFor("peer_connected", role, ""), "other roles do not replay");
        }
        for (String action : new String[]{"answer", "reject", "end", "webrtc_offer", "peer_connected", null}) {
            check(!OutgoingDialAcceptance.replayFor("peer_connected", "iphone", action), "actions cannot trigger status replay");
        }
        check(!OutgoingDialAcceptance.replayFor("agent_ready", "iphone", ""), "other statuses do not replay");
        // Both production command transports must use the exact same completion policy before creating a session.
        String source = Files.readString(servicePath);
        String gate = "OutgoingDialAcceptance.completed(command.optString(\"type\"), result.optString(\"status\"))";
        for (String method : new String[]{"private void pollCommands", "private void commandLoop"}) {
            int start = source.indexOf(method);
            int next = source.indexOf("\n    private ", start + 1);
            String body = source.substring(start, next < 0 ? source.length() : next);
            check(body.contains(gate), method + " uses the success policy");
            check(body.indexOf(gate) < body.indexOf(".startOutgoing(command.optJSONObject(\"call\"))"),
                    method + " gates outgoing-session creation");
        }
    }

    private static void timeline() {
        long[] now = {123_456_789_000_000L};
        var lines = new ArrayList<String>();
        var timeline = new CloudAudioSetupTimeline(CloudAudioSetupTimeline.Scope.APP, () -> now[0], lines::add);
        now[0] += 12_000_000L;
        timeline.mark(CloudAudioSetupTimeline.Phase.DIAL_ACCEPTED);
        timeline.mark(CloudAudioSetupTimeline.Phase.DIAL_ACCEPTED);
        check(lines.size() == 1, "replayed status does not flood diagnostics");
        check(lines.get(0).equals("standalone_audio_setup scope=app phase=dial_accepted elapsed_ms=12 monotonic_s=123456.801"),
                "fixed monotonic timing contains no identity or media");
        var brokenLog = new CloudAudioSetupTimeline(CloudAudioSetupTimeline.Scope.NATIVE, () -> now[0],
                line -> { throw new IllegalStateException("fixture"); });
        brokenLog.mark(CloudAudioSetupTimeline.Phase.CARRIER_READY);
        check(true, "diagnostic failure cannot fail media");
    }

    private static void sessions() throws Exception {
        var constructor = StandaloneCloudMediaManager.class.getDeclaredConstructor(Context.class);
        constructor.setAccessible(true);
        var manager = constructor.newInstance(new Context());
        try {
            String uuid = UUID.randomUUID().toString();
            CallRepository.preparable = false;
            manager.startOutgoing(call(uuid, 1, "outgoing"));
            var first = connection(1);
            check(accepted(first) == 1, "successful invocation announced even before Telecom binding");
            JSONObject status = new JSONObject(first.sent.stream().filter(s -> s.contains(OutgoingDialAcceptance.STATUS)).findFirst().orElseThrow());
            check(status.getString("call_id").equals("fixture-call") && status.getString("call_uuid").equals(uuid)
                    && status.getLong("generation") == 1, "acceptance has exact complete identity");
            var peer = WebRTCCloudPeer.peers.get(0);
            check(!peer.started && peer.activations.get() == 0 && StandaloneAgentGateway.actions.isEmpty(),
                    "acceptance has no Telecom, native peer or carrier side effect");

            first.receive(peerConnected("iphone"));
            await(() -> accepted(first) == 2);
            first.receive(peerConnected("iphone"));
            await(() -> accepted(first) == 3);
            first.receive(peerConnected("watch"));
            first.receive(peerConnected("agent"));
            first.receive(peerConnected("iphone").put("action", "unknown"));
            first.receive(peerConnected("iphone").put("call_uuid", UUID.randomUUID().toString()));
            first.receive(peerConnected("iphone").put("generation", 2));
            // A subsequent valid replay is a deterministic queue barrier for the rejected messages.
            first.receive(peerConnected("iphone"));
            await(() -> accepted(first) >= 4);
            check(accepted(first) == 4 && !peer.started, "foreign identity, generation, role and action cannot trigger replay");

            first.receive("answer");
            await(() -> first.sent.stream().anyMatch(s -> s.contains("answer_pending")));
            check(!peer.started, "dial acceptance does not bypass Telecom binding readiness");
            manager.attachTelecomCall("fixture-android", "outgoing");
            CallRepository.preparable = true;
            CallRepository.callState = android.telecom.Call.STATE_DIALING;
            first.receive("answer");
            await(() -> peer.started);
            check(peer.deferred && peer.activations.get() == 0, "owner can prepare while dialing with carrier closed");
            check(first.sent.stream().anyMatch(s -> s.contains("media_prepared")), "preparation is not active confirmation");
            CallRepository.callState = android.telecom.Call.STATE_ACTIVE;
            manager.telecomCallActive("fixture-android");
            await(() -> peer.activations.get() == 1);

            // A fresh socket gets the invocation result again. The old socket cannot send for its replacement.
            first.close();
            var second = connection(2);
            check(accepted(second) == 1, "reconnect replays acceptance");
            var activeField = StandaloneCloudMediaManager.class.getDeclaredField("active");
            activeField.setAccessible(true);
            Object session = activeField.get(manager);
            var announce = session.getClass().getDeclaredMethod("announceOutgoingDialAccepted", StandaloneWebSocket.class);
            announce.setAccessible(true);
            announce.invoke(session, first);
            check(accepted(second) == 1, "stale socket invocation is ignored");

            var recoveryField = session.getClass().getDeclaredField("carrierRecovery");
            recoveryField.setAccessible(true);
            var recovery = (CloudCarrierRecovery) recoveryField.get(session);
            for (int i = 0; i < 3; i++) recovery.recordFailure("carrier_route_unverified");
            announce.invoke(session, second);
            check(accepted(second) == 1, "blocked recovery cannot announce acceptance");

            manager.startOutgoing(call(UUID.randomUUID().toString(), 1, "incoming"));
            var incoming = connection(3);
            check(accepted(incoming) == 0, "incoming session never announces outgoing acceptance");
            incoming.receive(peerConnected("iphone"));
            incoming.receive("reject");
            await(() -> StandaloneAgentGateway.actions.contains("reject"));
            check(accepted(incoming) == 0, "incoming peer connect cannot emit outgoing result");
            check(second.closed, "replacement closes old outgoing socket");
            announce.invoke(session, second);
            check(accepted(second) == 1, "closed session cannot emit");
        } finally {
            manager.close();
            var field = StandaloneCloudMediaManager.class.getDeclaredField("sessions");
            field.setAccessible(true);
            ((ExecutorService) field.get(manager)).shutdownNow();
            CallRepository.preparable = true;
            CallRepository.callState = android.telecom.Call.STATE_ACTIVE;
        }
    }

    public static void main(String[] args) throws Exception {
        policiesAndWiring(Path.of(args[0]));
        timeline();
        sessions();
        System.out.println("Outgoing dial acceptance tests passed (" + checks + " checks)");
    }
}
