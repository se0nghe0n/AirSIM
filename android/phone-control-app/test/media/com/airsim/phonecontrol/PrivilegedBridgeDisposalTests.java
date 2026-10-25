package com.airsim.phonecontrol;

import java.io.IOException;
import java.lang.reflect.Field;
import java.util.concurrent.*;
import org.json.JSONArray;

/** Runs the actual Binder service's retirement gate, without Binder IPC, native audio or a device. */
public final class PrivilegedBridgeDisposalTests {
    private static int checks;
    private static void check(boolean value) { if (!value) throw new AssertionError(); checks++; }
    private static Field field(String name) throws Exception {
        Field field = ShizukuBridgeUserService.class.getDeclaredField(name);
        field.setAccessible(true);
        return field;
    }
    private static void blocked(ShizukuBridgeUserService bridge) throws Exception {
        try {
            bridge.executeCommand(PrivilegedBridgeProtocol.TRANSACTION_START_BRIDGE, false);
            throw new AssertionError("recreated a retiring bridge");
        } catch (IOException expected) { check("media_service_closing".equals(expected.getMessage())); }
        try {
            bridge.mediaRequest("{}");
            throw new AssertionError("accepted a retiring bridge request");
        } catch (IllegalStateException expected) { check("media_service_closing".equals(expected.getMessage())); }
    }
    public static void main(String[] args) throws Exception {
        for (boolean fail : new boolean[]{false, true}) {
            TelephonyWebRTCPeer.delayedDisposal = true;
            PrivilegedMediaService media = new PrivilegedMediaService(new android.content.Context(), () -> {}, () -> {});
            media.initialize();
            media.request(PrivilegedMediaTests.message("start", PrivilegedMediaTests.OWNER)
                    .put("ice_servers", new JSONArray()).toString());
            TelephonyWebRTCPeer peer = TelephonyWebRTCPeer.latest;
            ShizukuBridgeUserService bridge = new ShizukuBridgeUserService();
            field("media").set(bridge, media);
            boolean[] muted = {false};
            LocalOutputMuteController output = new LocalOutputMuteController(new LocalOutputMuteController.Backend() {
                public boolean isMuted() { return muted[0]; }
                public int volume() { return 3; }
                public void setMuted(boolean value) { muted[0] = value; }
                public void setVolume(int value) {}
            });
            output.setMuted(true);
            field("outputMute").set(bridge, output);
            field("desiredOutputMuted").setBoolean(bridge, true);
            int closes = TelephonyWebRTCPeer.closes;
            bridge.closeBridge(); bridge.closeBridge();
            // destroy()/pipe EOF can exit now; global audio must already be restored.
            check(!muted[0]);
            check(!field("desiredOutputMuted").getBoolean(bridge));
            check(TelephonyWebRTCPeer.closes == closes + 1);
            check(field("media").get(bridge) == media);
            check(field("bridgeClosing").getBoolean(bridge));
            blocked(bridge);
            ExecutorService completion = Executors.newSingleThreadExecutor();
            try { completion.submit(() -> {
                if (fail) peer.failDisposal(); else peer.completeDisposal();
            }).get(2, TimeUnit.SECONDS); }
            finally { completion.shutdownNow(); }
            if (fail) {
                check(field("media").get(bridge) == media);
                check(field("bridgeClosing").getBoolean(bridge));
                blocked(bridge);
            } else {
                check(field("media").get(bridge) == null);
                check(!field("bridgeClosing").getBoolean(bridge));
                // No Android Context is supplied, so the next error proves it passed the retirement gate.
                try {
                    bridge.executeCommand(PrivilegedBridgeProtocol.TRANSACTION_START_BRIDGE, false);
                    throw new AssertionError();
                } catch (IOException expected) { check("application context unavailable".equals(expected.getMessage())); }
            }
            media.close();
        }
        System.out.println("Privileged bridge disposal tests passed (" + checks + " checks)");
    }
}
