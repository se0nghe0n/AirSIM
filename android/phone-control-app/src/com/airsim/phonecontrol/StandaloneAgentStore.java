package com.airsim.phonecontrol;

import android.content.Context;
import android.content.SharedPreferences;

import org.json.JSONArray;
import org.json.JSONObject;

import java.net.URI;
import java.util.Locale;

/** Private persistent state for the Agent embedded in the standalone APK. */
final class StandaloneAgentStore {
    private static final String FILE = "standalone_agent";
    private static final String REGISTRATION = "registration";
    private static final String LAST_ERROR = "last_error";
    private static final String LAST_HEARTBEAT = "last_heartbeat";
    private static final String LAST_SEEN = "last_seen";

    private final SharedPreferences preferences;

    StandaloneAgentStore(Context context) {
        preferences = context.getSharedPreferences(FILE, Context.MODE_PRIVATE);
    }

    synchronized JSONObject registration() {
        String encoded = preferences.getString(REGISTRATION, "");
        if (encoded == null || encoded.isBlank()) return null;
        try { return new JSONObject(encoded)
                .put("agent_media_capabilities", mediaCapabilities()); }
        catch (Exception error) {
            BridgeLog.error("standalone_registration_corrupt", error);
            return null;
        }
    }

    synchronized JSONObject saveRegistration(String encoded) throws Exception {
        JSONObject value = new JSONObject(encoded);
        validateRegistration(value);
        boolean localMode = value.optBoolean("local_mode", false);
        if (localMode) value.put("cloud_enabled", false);
        if (value.has("device_id")) value.put("device_id", value.optString("device_id", "").trim());
        value.put("relay_url", trimTrailingSlash(value.optString("relay_url", "").trim()));
        for (String key : new String[]{"voip_token", "alert_token", "watch_voip_token",
                "live_activity_push_to_start_token"}) {
            if (value.has(key)) value.put(key, value.optString(key, "").toLowerCase(Locale.ROOT));
        }
        preferences.edit().putString(REGISTRATION, value.toString()).remove(LAST_ERROR).apply();
        return value;
    }

    boolean configured() {
        JSONObject value = registration();
        if (value != null && value.optBoolean("local_mode", false)) return true;
        return value != null && !value.optString("device_id", "").isBlank()
                && !value.optString("device_secret", "").isBlank()
                && !value.optString("relay_url", "").isBlank();
    }

    boolean cloudEnabled() {
        JSONObject value = registration();
        return value != null && !value.optBoolean("local_mode", false)
                && value.optBoolean("cloud_enabled", true);
    }

    synchronized JSONObject setCloudEnabled(boolean enabled) throws Exception {
        JSONObject value = registration();
        if (value == null) throw new IllegalStateException("Pairing has not completed");
        if (enabled && value.optBoolean("local_mode", false)) {
            throw new IllegalArgumentException("Cloud mode cannot be enabled in local mode");
        }
        value.put("cloud_enabled", enabled);
        return saveRegistration(value.toString());
    }

    void recordSuccess() {
        preferences.edit().putLong(LAST_SEEN, System.currentTimeMillis()).remove(LAST_ERROR).apply();
    }

    void recordHeartbeat() {
        preferences.edit().putLong(LAST_HEARTBEAT, System.currentTimeMillis())
                .putLong(LAST_SEEN, System.currentTimeMillis()).remove(LAST_ERROR).apply();
    }

    void recordError(String error) {
        preferences.edit().putString(LAST_ERROR, DebugRedactor.sanitize(error)).apply();
    }

    String lastError() { return preferences.getString(LAST_ERROR, ""); }
    long lastSeen() { return preferences.getLong(LAST_SEEN, 0L); }
    long lastHeartbeat() { return preferences.getLong(LAST_HEARTBEAT, 0L); }

    JSONObject pushStatus() throws Exception {
        JSONObject registration = registration();
        boolean configured = registration != null;
        boolean localMode = configured && registration.optBoolean("local_mode", false);
        JSONObject result = new JSONObject()
                .put("local_mode", localMode)
                .put("cloud_enabled", configured && !localMode
                        && registration.optBoolean("cloud_enabled", true))
                .put("configured", configured)
                .put("call_push_ready", configured && (!registration.optString("voip_token", "").isEmpty()
                        || !registration.optString("watch_voip_token", "").isEmpty()))
                .put("message_push_ready", configured && !registration.optString("alert_token", "").isEmpty())
                .put("last_error", lastError())
                .put("wan_interface", "android-default");
        if (configured) {
            result.put("device_id", registration.optString("device_id", ""));
            result.put("environment", registration.optString("environment", ""));
            result.put("relay_url", registration.optString("relay_url", ""));
        }
        return result;
    }

    static void validateRegistration(JSONObject value) throws Exception {
        if (value.optBoolean("local_mode", false)) {
            if (value.optBoolean("cloud_enabled", false)) {
                throw new IllegalArgumentException("Cloud mode cannot be enabled in local mode");
            }
            return;
        }
        String deviceID = value.optString("device_id", "").trim();
        String secret = value.optString("device_secret", "");
        String bundleID = value.optString("bundle_id", "").trim();
        String environment = value.optString("environment", "");
        String relayURL = value.optString("relay_url", "").trim();
        if (deviceID.isEmpty() || deviceID.length() > 128) throw new IllegalArgumentException("Invalid device_id");
        if (secret.length() < 16 || secret.length() > 512) throw new IllegalArgumentException("Invalid device_secret");
        if (bundleID.isEmpty() || bundleID.length() > 255) throw new IllegalArgumentException("Invalid bundle_id");
        if (!"sandbox".equals(environment) && !"production".equals(environment)) {
            throw new IllegalArgumentException("environment must be sandbox or production");
        }
        URI relay = URI.create(relayURL);
        if (!"https".equalsIgnoreCase(relay.getScheme()) || relay.getHost() == null
                || relay.getRawUserInfo() != null) {
            throw new IllegalArgumentException("relay_url must be an HTTPS address without embedded credentials");
        }
        boolean hasToken = false;
        for (String key : new String[]{"voip_token", "alert_token", "watch_voip_token",
                "live_activity_push_to_start_token"}) {
            String token = value.optString(key, "");
            if (!token.isEmpty()) {
                hasToken = true;
                if ((token.length() & 1) != 0 || !token.matches("[0-9a-fA-F]{16,512}")) {
                    throw new IllegalArgumentException(key + " is invalid");
                }
            }
        }
        if (!hasToken) throw new IllegalArgumentException("At least one APNs token is required");
        String watchToken = value.optString("watch_voip_token", "");
        if (!watchToken.isEmpty() && !(bundleID + ".watchkitapp").equals(value.optString("watch_bundle_id", ""))) {
            throw new IllegalArgumentException("watch_bundle_id does not match the main app");
        }
        // Capabilities describe this installed Agent, not the older pairing payload.
        value.put("agent_media_capabilities", mediaCapabilities());
    }

    static JSONArray mediaCapabilities() {
        return new JSONArray().put(CloudCallMedia.WEBRTC);
    }

    /** Answered cloud audio is WebRTC. The retired PCM pump is never started. */
    static void startCloudCallMedia(String mediaTransport, Runnable startWebRTC) {
        CloudCallMedia.start(mediaTransport, startWebRTC);
    }

    private static String trimTrailingSlash(String value) {
        while (value.endsWith("/")) value = value.substring(0, value.length() - 1);
        return value;
    }
}
