package com.airsim.phonecontrol;

import android.content.Context;
import java.util.UUID;
import java.util.concurrent.ExecutorService;
import java.util.function.BooleanSupplier;
import org.json.JSONObject;

/** Production CloudSession behavior with no phone, network, credentials, or carrier audio. */
public final class CloudCarrierRecoveryTests {
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
    private static JSONObject call(String uuid, long generation) throws Exception {
        return new JSONObject().put("call_id", "fixture-call").put("call_uuid", uuid)
                .put("generation", generation).put("call_secret", "fixture-secret")
                .put("relay_url", "https://fixture.invalid").put("direction", "outgoing")
                .put("media_transport", "webrtc");
    }
    private static boolean recoverySent(StandaloneWebSocket socket) {
        return socket.sent.stream().anyMatch(s -> s.contains(CloudCarrierRecovery.RECOVERY_REQUIRED));
    }
    private static StandaloneWebSocket connection(int count) throws Exception {
        await(() -> StandaloneWebSocket.connections.size() >= count);
        var socket = StandaloneWebSocket.connections.get(count - 1);
        await(() -> !socket.sent.isEmpty());
        return socket;
    }
    private static WebRTCCloudPeer answer(StandaloneWebSocket socket, int count) throws Exception {
        socket.receive("answer");
        await(() -> WebRTCCloudPeer.peers.size() >= count && WebRTCCloudPeer.peers.get(count - 1).started);
        return WebRTCCloudPeer.peers.get(count - 1);
    }

    public static void main(String[] args) throws Exception {
        var policy = new CloudCarrierRecovery();
        for (String value : new String[]{"ice_failed", "ice_configuration_unavailable", "privileged_media_unavailable", "", null}) {
            for (int i = 0; i < 4; i++) check(!policy.recordFailure(value), "non-route error must retain recovery");
        }
        check(!policy.recordFailure("carrier_route_lost"), "first route failure retries");
        check(!policy.recordFailure("carrier_route_inactive"), "second route failure retries");
        check(policy.recordFailure("carrier_route_unverified"), "third route failure blocks");
        check(policy.recordFailure("ice_failed") && policy.isBlocked(), "later network failures cannot clear latch");
        for (String value : new String[]{"carrier_route_unavailable", "carrier_route_rejected", "carrier_route_changed_type_2"}) {
            var route = new CloudCarrierRecovery();
            for (int i = 0; i < 3; i++) route.recordFailure(value);
            check(route.isBlocked(), "known unsafe route is bounded");
        }
        var unknown = new CloudCarrierRecovery();
        for (int i = 0; i < 5; i++) unknown.recordFailure("carrier_route_changed_type_untrusted");
        check(!unknown.isBlocked(), "unknown diagnostic is not a terminal command");

        var constructor = StandaloneCloudMediaManager.class.getDeclaredConstructor(Context.class);
        constructor.setAccessible(true);
        var manager = constructor.newInstance(new Context());
        try {
            String uuid = UUID.randomUUID().toString();
            manager.startOutgoing(call(uuid, 1));
            manager.attachTelecomCall("fixture-android-id", "outgoing");
            var firstSocket = connection(1);
            var firstPeer = answer(firstSocket, 1);
            // Network/ICE errors keep the pre-existing reconnect behavior and spend no route budget.
            firstPeer.fail("ice_configuration_unavailable");
            var secondSocket = connection(2);
            var secondPeer = answer(secondSocket, 2);
            secondPeer.fail("carrier_route_inactive");
            var thirdSocket = connection(3);
            var thirdPeer = answer(thirdSocket, 3);
            // A late callback from the retired socket must not spend the current budget.
            firstPeer.fail("carrier_route_unverified");
            check(!thirdSocket.closed, "old peer cannot poison a replacement socket");
            thirdPeer.fail("carrier_route_unverified");
            var fourthSocket = connection(4);
            var fourthPeer = answer(fourthSocket, 4);
            fourthPeer.fail("carrier_route_lost");
            await(() -> recoverySent(fourthSocket));
            check(!fourthSocket.closed, "terminal media failure retains call-control socket");
            check(fourthPeer.closed, "terminal media failure releases native peer");
            check(StandaloneAgentGateway.actions.isEmpty(), "media failure never ends the carrier call");
            int sent = fourthSocket.sent.size();
            int activations = fourthPeer.activations.get();
            fourthSocket.receive("answer");
            await(() -> fourthSocket.sent.size() > sent);
            fourthSocket.receive("webrtc_offer");
            manager.telecomCallActive("fixture-android-id");
            manager.startOutgoing(call(uuid, 1));
            Thread.sleep(100);
            check(WebRTCCloudPeer.peers.size() == 4, "answer/SDP/duplicate call cannot restart blocked media");
            check(fourthPeer.signals.get() == 0, "blocked media consumes no SDP");
            check(fourthPeer.activations.get() == activations, "ACTIVE cannot reactivate blocked carrier audio");
            // Real network loss still reconnects controls, but does not prefetch or recreate media.
            fourthSocket.close();
            var fifthSocket = connection(5);
            check(recoverySent(fifthSocket), "blocked status is replayed on control reconnect");
            check(fifthSocket.sent.stream().noneMatch(s -> s.contains("agent_ready")), "reconnect does not advertise media readiness");
            check(WebRTCCloudPeer.peers.size() == 4, "control reconnect does not construct a peer");
            fifthSocket.receive("end");
            await(() -> StandaloneAgentGateway.actions.contains("end"));
            check(StandaloneAgentGateway.actions.size() == 1, "only explicit end reaches Telecom");

            // New generation has a fresh budget, even with the same UUID; old callbacks remain inert.
            manager.startOutgoing(call(uuid, 2));
            var sixthSocket = connection(6);
            var sixthPeer = answer(sixthSocket, 5);
            fourthPeer.fail("carrier_route_lost");
            check(!sixthSocket.closed && !recoverySent(sixthSocket), "old call cannot poison a new generation");
            check(sixthPeer.started, "new generation can start media");
            sixthSocket.receive("reject");
            await(() -> StandaloneAgentGateway.actions.contains("reject"));
            check(StandaloneAgentGateway.actions.size() == 2, "reject control is preserved");
        } finally {
            manager.close();
            var field = StandaloneCloudMediaManager.class.getDeclaredField("sessions");
            field.setAccessible(true);
            ((ExecutorService) field.get(manager)).shutdownNow();
        }
        System.out.println("Cloud carrier recovery tests passed (" + checks + " checks)");
    }
}
