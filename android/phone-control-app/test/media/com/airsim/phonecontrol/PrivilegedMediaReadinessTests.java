package com.airsim.phonecontrol;

import java.io.IOException;
import java.lang.reflect.Field;
import java.util.UUID;
import org.json.JSONObject;

/** Exercises live service status through the coordinator into the real heartbeat projection. */
public final class PrivilegedMediaReadinessTests {
    private static int checks;
    private static void check(boolean value) { if (!value) throw new AssertionError(); checks++; }
    private static boolean prepared(PrivilegedMediaService service) throws Exception {
        return new JSONObject(service.request(PrivilegedMediaTests.message("prepare", PrivilegedMediaTests.OWNER)
                .toString())).getBoolean("service_ready");
    }
    private static void heartbeat(PrivilegedBridgeCoordinator coordinator, boolean ready) throws Exception {
        boolean snapshot = coordinator.mediaAvailable();
        JSONObject heartbeat = StandaloneAgentStore.applyMediaHeartbeat(new JSONObject(), snapshot);
        check(snapshot == ready);
        check(heartbeat.getBoolean("agent_media_ready") == ready);
        check(heartbeat.getInt("media_capability_revision") == 2);
        check(heartbeat.getJSONArray("agent_media_capabilities").length() == (ready ? 1 : 0));
        if (ready) check(CloudCallMedia.WEBRTC.equals(heartbeat.getJSONArray("agent_media_capabilities").getString(0)));
    }
    public static void main(String[] args) throws Exception {
        TelephonyWebRTCPeer.delayedDisposal = true;
        try (PrivilegedMediaService service = new PrivilegedMediaService(new android.content.Context(), () -> {}, () -> {})) {
            check(!service.available());
            check(prepared(service));
            ShizukuBridgeUserService bridge = new ShizukuBridgeUserService();
            Field media = ShizukuBridgeUserService.class.getDeclaredField("media");
            media.setAccessible(true); media.set(bridge, service);
            boolean[] statusFailure = {false};
            int[] reads = {0};
            PrivilegedBridgeCoordinator coordinator = new PrivilegedBridgeCoordinator();
            coordinator.connect(new PrivilegedBridgeCoordinator.Transport() {
                public String startBridge() throws Exception { return status(); }
                public String status() throws Exception {
                    reads[0]++;
                    if (statusFailure[0]) throw new IOException("test_status_unavailable");
                    return bridge.executeCommand(PrivilegedBridgeProtocol.TRANSACTION_STATUS, false);
                }
                public String setLocalOutputMuted(boolean muted) { return "unchanged"; }
            });
            heartbeat(coordinator, true);
            service.request(PrivilegedMediaTests.start(PrivilegedMediaTests.OWNER));
            TelephonyWebRTCPeer first = TelephonyWebRTCPeer.latest;
            // An active owner is NOT an unavailable/quarantined service. Do not kill its heartbeat.
            check(service.available()); check(prepared(service)); heartbeat(coordinator, true);
            check(PrivilegedMediaTests.poll(service, PrivilegedMediaTests.OWNER).getBoolean("active"));
            first.signals.send(PrivilegedMediaTests.signal());
            check(PrivilegedMediaTests.poll(service, PrivilegedMediaTests.OWNER).has("event"));
            service.request(PrivilegedMediaTests.message("stop", PrivilegedMediaTests.OWNER).toString());
            check(!service.available()); check(!prepared(service));
            check(coordinator.bridgeRunning()); // Old UI cache is intentionally still ready here.
            int before = reads[0]; heartbeat(coordinator, false);
            check(reads[0] == before + 1); check(!coordinator.bridgeRunning());
            check(!PrivilegedMediaTests.poll(service, PrivilegedMediaTests.OWNER).getBoolean("active"));
            service.request(PrivilegedMediaTests.message("stop", PrivilegedMediaTests.OWNER).toString());
            PrivilegedMediaTests.rejected("media_owner_busy", () -> service.request(PrivilegedMediaTests.start(UUID.randomUUID().toString())));
            first.completeDisposal();
            check(service.available()); check(prepared(service)); heartbeat(coordinator, true);
            // A transient status error withdraws admission readiness, not the control transport.
            statusFailure[0] = true; heartbeat(coordinator, false); check(!coordinator.bridgeRunning());
            statusFailure[0] = false; heartbeat(coordinator, true);
            String next = UUID.randomUUID().toString();
            service.request(PrivilegedMediaTests.start(next));
            TelephonyWebRTCPeer second = TelephonyWebRTCPeer.latest;
            heartbeat(coordinator, true);
            second.failed.run();
            check(!service.available()); check(!prepared(service)); heartbeat(coordinator, false);
            // Terminal status and idempotent stop remain accessible even while readiness is false.
            JSONObject event = PrivilegedMediaTests.poll(service, next);
            check(!event.getBoolean("active"));
            check("webrtc_failed".equals(event.getJSONObject("event").getString("status")));
            second.failDisposal();
            check(!service.available()); check(!prepared(service)); heartbeat(coordinator, false);
            service.request(PrivilegedMediaTests.message("stop", next).toString());
            check(!PrivilegedMediaTests.poll(service, next).getBoolean("active"));
            PrivilegedMediaTests.rejected("media_owner_busy", () -> service.request(PrivilegedMediaTests.start(UUID.randomUUID().toString())));
            second.completeDisposal(); // A later success must not undo an exceptional completion.
            check(!service.available()); check(!prepared(service)); heartbeat(coordinator, false);
            coordinator.disconnect(); heartbeat(coordinator, false);
        }
        System.out.println("Privileged media readiness/heartbeat tests passed (" + checks + " checks)");
    }
}
