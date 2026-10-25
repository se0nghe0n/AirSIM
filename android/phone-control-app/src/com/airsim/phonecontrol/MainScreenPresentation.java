package com.airsim.phonecontrol;

public final class MainScreenPresentation {
    private MainScreenPresentation() {}

    public static String connectionModeTitle(
            boolean vowlanReady,
            boolean cloudEnabled,
            boolean relayConfigured,
            String lastError) {
        if (vowlanReady) return "VoWLAN mode";
        if (cloudEnabled && relayConfigured && lastError != null && !lastError.isBlank()) {
            return "Cloud connection error";
        }
        if (cloudEnabled && relayConfigured) return "Cloud mode";
        if (cloudEnabled) return "Cloud not configured";
        return "VoWLAN disconnected";
    }

    public static String connectionModeDetail(
            boolean vowlanReady,
            boolean cloudEnabled,
            boolean relayConfigured,
            String lastError) {
        if (vowlanReady) return "Android local network control and WebRTC service ready; calls prefer VoWLAN";
        if (cloudEnabled && relayConfigured && lastError != null && !lastError.isBlank()) {
            return "Latest Relay / Agent error: " + lastError;
        }
        if (cloudEnabled && relayConfigured) return "Cloud Relay configured; waiting for Agent heartbeat verification";
        if (cloudEnabled) return "Cloud enabled, but Relay or device registration is incomplete";
        return "Connect to the same Wi-Fi / Android hotspot, or enable and configure cloud Relay";
    }

    public static String formatPairingCode(String code) {
        if (code == null) return "--- ---";
        String digits = code.replaceAll("[^0-9]", "");
        if (digits.length() != 6) return "--- ---";
        return digits.substring(0, 3) + " " + digits.substring(3);
    }

    public static String recentLogLines(String log, String filter, int maximum) {
        if (log == null || log.isBlank() || maximum <= 0) return "No debug logs";
        String category = filter == null ? "" : filter.trim();
        String[] lines = log.split("\\R");
        StringBuilder visible = new StringBuilder();
        int count = 0;
        for (int index = lines.length - 1; index >= 0 && count < maximum; index--) {
            String line = lines[index].trim();
            if (line.isEmpty()) continue;
            if (!category.isEmpty() && !"All".equals(category)
                    && !line.toLowerCase(java.util.Locale.ROOT)
                    .contains(category.toLowerCase(java.util.Locale.ROOT))) continue;
            if (visible.length() > 0) visible.append('\n');
            visible.append(line);
            count++;
        }
        return visible.length() == 0 ? "No logs in this category" : visible.toString();
    }

    public static String recentMatchingLogLines(String log, int maximum, String... keywords) {
        if (log == null || log.isBlank() || maximum <= 0) return "No related logs";
        String[] lines = log.split("\\R");
        StringBuilder visible = new StringBuilder();
        int count = 0;
        for (int index = lines.length - 1; index >= 0 && count < maximum; index--) {
            String line = lines[index].trim();
            if (line.isEmpty() || !matchesAny(line, keywords)) continue;
            if (visible.length() > 0) visible.append('\n');
            visible.append(line);
            count++;
        }
        return visible.length() == 0 ? "No related logs" : visible.toString();
    }

    public static String latestContaining(String log, String keyword) {
        if (log == null || log.isBlank() || keyword == null || keyword.isBlank()) return "";
        String[] lines = log.split("\\R");
        for (int index = lines.length - 1; index >= 0; index--) {
            if (lines[index].contains(keyword)) return lines[index].trim();
        }
        return "";
    }

    private static boolean matchesAny(String line, String... keywords) {
        if (keywords == null || keywords.length == 0) return true;
        String lower = line.toLowerCase(java.util.Locale.ROOT);
        for (String keyword : keywords) {
            if (keyword != null && !keyword.isBlank()
                    && lower.contains(keyword.toLowerCase(java.util.Locale.ROOT))) return true;
        }
        return false;
    }

    public static String activitySummary(String line) {
        if (line == null || line.isBlank()) return "No event details";
        String value = line.toLowerCase(java.util.Locale.ROOT);
        if (value.contains("pairing_completed")) return "VoWLAN pairing complete";
        if (value.contains("pairing_started")) return "Waiting for iPhone pairing";
        if (value.contains("standalone_agent_created")) return "Built-in Agent started";
        if (value.contains("application_started")) return "App service started";
        if (value.contains("shizuku_user_service_connected")) return "Shizuku WebRTC service connected";
        if (value.contains("shizuku_binder_received")) return "Shizuku connected";
        if (value.contains("shizuku_permission_granted")) return "Shizuku permission granted";
        if (value.contains("vowlan_service_created")) return "VoWLAN service started";
        if (value.contains("vowlan_service_start_requested")) return "Starting VoWLAN service";
        if (value.contains("vowlan_ready")) return "VoWLAN local network service ready";
        if (value.contains("vowlan_state") && value.contains("paired=true")
                && value.contains("agent_ready=true") && value.contains("media_ready=true")) {
            return "VoWLAN health check passed";
        }
        if (value.contains("standalone_status_refresh") && value.contains("ok=true")) {
            return "Built-in Agent status ready";
        }
        if (value.contains("telecom_call_added")) return "System call connected";
        if (value.contains("telecom_call_removed")) return "System call ended";
        if (value.contains("command_result") && value.contains("success=true")) {
            return "Android command succeeded";
        }
        String event = eventBody(line).split("\\s+", 2)[0];
        if (event.isBlank()) return "No event details";
        return event;
    }

    public static String logMetadata(String line) {
        if (line == null) return "";
        String[] fields = line.trim().split("\\s+", 4);
        if (fields.length >= 3 && isLogLevel(fields[1]) && fields[2].startsWith("[")) {
            return fields[0] + " · " + fields[1] + " · " + fields[2];
        }
        return "Raw log";
    }

    public static String eventBody(String line) {
        if (line == null) return "";
        String value = line.trim();
        String[] fields = value.split("\\s+", 4);
        if (fields.length == 4 && isLogLevel(fields[1]) && fields[2].startsWith("[")) {
            return fields[3];
        }
        return value;
    }

    public static boolean isErrorLog(String line) {
        return line != null && line.matches("(?s)^\\S+ ERROR \\[.*");
    }

    private static boolean isLogLevel(String value) {
        return "DEBUG".equals(value) || "INFO".equals(value) || "ERROR".equals(value);
    }
}
