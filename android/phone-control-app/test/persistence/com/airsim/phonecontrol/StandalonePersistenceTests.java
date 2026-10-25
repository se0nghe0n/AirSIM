package com.airsim.phonecontrol;

import android.content.Context;
import java.util.Arrays;
import org.json.JSONArray;
import org.json.JSONObject;

/** Exercise real preference stores with pre-upgrade records, without network or device writes. */
public final class StandalonePersistenceTests {
    private static int checks;
    private static void check(boolean value) {
        if (!value) throw new AssertionError("persistence check " + checks);
        checks++;
    }

    public static void main(String[] args) throws Exception {
        Context context = new Context();
        String registration = new JSONObject()
                .put("device_id", "existing-device")
                .put("device_secret", "fixture-secret-unchanged")
                .put("relay_url", "https://relay.example.test")
                .put("bundle_id", "example.airsim")
                .put("environment", "sandbox")
                .put("voip_token", "0123456789abcdef")
                .put("android_agent_id", "existing-agent")
                .put("cloud_enabled", true).toString();
        context.getSharedPreferences("standalone_agent", 0).edit()
                .putString("registration", registration).putLong("last_seen", 42).apply();
        context.getSharedPreferences("control", 0).edit()
                .putString("mode", AppConfig.MODE_REMOTE_SILENT)
                .putString("endpoint", "retired-endpoint")
                .putString("token", "retired-token").putBoolean("debug_enabled", false).apply();
        byte[] pairingKey = new byte[32];
        Arrays.fill(pairingKey, (byte) 7);
        VoWLANPairingStore.saveEncoded(context, java.util.Base64.getUrlEncoder().encodeToString(pairingKey));
        String pending = new JSONObject().put("delivery_id", "before-upgrade")
                .put("sender", "fixture-sender").put("content", "fixture-message")
                .put("timestamp", "2026-10-25T00:00:00Z")
                .put("local_ack", false).put("cloud_sent", false).toString();
        context.getSharedPreferences("standalone_sms", 0).edit()
                .putString("records", "[" + pending + "]").putLong("revision", 7)
                .putString("recent_delivery_ids", "[\"already-delivered\"]").apply();

        AppConfig.saveMode(context, AppConfig.MODE_LOCAL_AND_PUSH);
        Context reopened = context.reopen();
        StandaloneAgentStore agent = new StandaloneAgentStore(reopened);
        StandaloneSMSStore sms = new StandaloneSMSStore(reopened);
        check(StandaloneAgentService.starts == 1);
        check(agent.configured() && agent.cloudEnabled());
        check(agent.registration().getString("device_id").equals("existing-device"));
        check(agent.registration().getString("device_secret").equals("fixture-secret-unchanged"));
        check(agent.registration().getString("android_agent_id").equals("existing-agent"));
        check(agent.lastSeen() == 42);
        check(context.getSharedPreferences("standalone_agent", 0).getString("registration", "").equals(registration));
        check(Arrays.equals(VoWLANPairingStore.load(reopened), pairingKey));
        check(AppConfig.mode(reopened).equals(AppConfig.MODE_LOCAL_AND_PUSH));
        check(!AppConfig.debugEnabled(reopened));
        check(reopened.getSharedPreferences("control", 0).getString("token", "").equals("retired-token"));
        check(sms.revision() == 7 && sms.localMessages().length() == 1 && sms.cloudPending().length() == 1);
        check(sms.localMessages().getJSONObject(0).getString("content").equals("fixture-message"));
        // Local consumption must retain the record until cloud delivery completes.
        sms.acknowledge(new JSONArray().put("before-upgrade"));
        sms = new StandaloneSMSStore(reopened.reopen());
        check(sms.localMessages().isEmpty() && sms.cloudPending().length() == 1);
        sms.markCloudSent("before-upgrade");
        check(new StandaloneSMSStore(reopened.reopen()).cloudPending().isEmpty());
        check(!sms.add(new JSONObject(pending), true));
        check(!sms.add(new JSONObject(pending).put("delivery_id", "already-delivered"), true));
        // Reading a pre-upgrade local-only pairing must not enable cloud mode.
        reopened.getSharedPreferences("standalone_agent", 0).edit()
                .putString("registration", "{\"local_mode\":true,\"cloud_enabled\":false}").apply();
        agent = new StandaloneAgentStore(reopened.reopen());
        check(agent.configured() && !agent.cloudEnabled());
        check(Arrays.equals(VoWLANPairingStore.load(reopened), pairingKey));
        System.out.println("Standalone persistence tests passed (" + checks + " checks)");
    }
}
