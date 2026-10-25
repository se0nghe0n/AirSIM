package com.airsim.phonecontrol;

/** VoWLAN signaling stays on the HMAC control link. Audio is WebRTC, not a PCM preface. */
public final class VoWLANWebRTCControl {
    public static final String PATH = "/api/calls/webrtc";
    public static final String STATUS_PATH = PATH + "/status";
    public static final String STOP_PATH = PATH + "/stop";
    public static final int CONTROL_PORT = 7592;
    public static final boolean LISTENS_ON_PCM_PORT = false;

    private VoWLANWebRTCControl() {}

    public static Message parse(String json) {
        if (json == null || json.isEmpty() || json.length() > 131_072) {
            throw new IllegalArgumentException("invalid vowlan webrtc message");
        }
        String action = field(json, "action");
        String callUUID = field(json, "call_uuid");
        String sessionID = field(json, "session_id");
        long generation;
        try { generation = Long.parseLong(field(json, "generation")); }
        catch (NumberFormatException error) { throw new IllegalArgumentException("invalid generation", error); }
        String sdp = "webrtc_ice".equals(action) ? "" : field(json, "sdp");
        if (!"webrtc_offer".equals(action) && !"webrtc_answer".equals(action) && !"webrtc_ice".equals(action)) {
            throw new IllegalArgumentException("invalid action");
        }
        if (callUUID.isEmpty() || sessionID.isEmpty() || generation <= 0) {
            throw new IllegalArgumentException("invalid identity");
        }
        if (!"webrtc_ice".equals(action) && (sdp.isEmpty() || sdp.length() > 131_072)) {
            throw new IllegalArgumentException("invalid sdp");
        }
        return new Message(action, callUUID, generation, sessionID, sdp);
    }

    public static String answer(Message offer, String sdp) {
        if (offer == null || !"webrtc_offer".equals(offer.action()) || sdp == null || sdp.isEmpty()) {
            throw new IllegalArgumentException("offer required");
        }
        return "{\"action\":\"webrtc_answer\",\"call_uuid\":\"" + offer.callUUID()
                + "\",\"generation\":" + offer.generation()
                + ",\"session_id\":\"" + offer.sessionID()
                + "\",\"sdp\":\"" + escape(sdp) + "\"}";
    }

    private static String field(String json, String key) {
        String needle = "\"" + key + "\":";
        int index = json.indexOf(needle);
        if (index < 0) throw new IllegalArgumentException("missing " + key);
        int start = index + needle.length();
        while (start < json.length() && json.charAt(start) == ' ') start++;
        if (start >= json.length()) throw new IllegalArgumentException("missing " + key);
        if (json.charAt(start) == '"') {
            int end = json.indexOf('"', start + 1);
            if (end < 0) throw new IllegalArgumentException("bad " + key);
            return json.substring(start + 1, end);
        }
        int end = start;
        while (end < json.length() && Character.isDigit(json.charAt(end))) end++;
        if (end == start) throw new IllegalArgumentException("bad " + key);
        return json.substring(start, end);
    }

    private static String escape(String value) {
        return value.replace("\\", "\\\\").replace("\"", "\\\"").replace("\r", "\\r").replace("\n", "\\n");
    }

    public record Message(String action, String callUUID, long generation, String sessionID, String sdp) {}

    public static final class Sessions {
        private String owner;

        public synchronized boolean acceptOffer(String sessionID) {
            if (owner != null || sessionID == null || sessionID.isEmpty()) return false;
            owner = sessionID;
            return true;
        }

        public synchronized void release() { owner = null; }
    }
}
