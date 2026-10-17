package com.airsim.phonecontrol;

import java.util.*;

/** Pure, allowlisted RTC statistics projection. IDs are only used internally for joins. */
final class WebRTCStatistics {
    static final class Entry {
        final String id;
        final String type;
        final Map<String, Object> members;
        Entry(String id, String type, Map<String, Object> members) {
            this.id = id; this.type = type; this.members = members;
        }
    }
    private Map<String, Map<String, Double>> previous = new HashMap<>();
    private static final String[] COUNTERS = {"packetsReceived", "packetsLost", "bytesReceived",
            "concealedSamples", "totalSamplesReceived", "jitterBufferDelay", "jitterBufferEmittedCount"};

    void reset() { previous.clear(); }

    List<Map<String, Object>> sample(Map<String, Entry> entries) {
        List<Map<String, Object>> result = new ArrayList<>();
        Map<String, Map<String, Double>> next = new HashMap<>();
        for (Entry rtp : entries.values()) {
            boolean inbound = "inbound-rtp".equals(rtp.type);
            if (!inbound && !"outbound-rtp".equals(rtp.type)) continue;
            if (!"audio".equals(rtp.members.get("kind")) && !"audio".equals(rtp.members.get("mediaType"))) continue;
            // Audio-only peers normally have two rows; keep diagnostic output bounded.
            if (result.size() >= 8) break;
            Map<String, Object> out = new LinkedHashMap<>();
            out.put("direction", inbound ? "inbound" : "outbound");
            if (inbound) {
                for (String key : COUNTERS) copyNumber(out, rtp, key);
                copyNumber(out, rtp, "jitter");
                Double jitter = number(rtp.members.get("jitter"));
                if (jitter != null && jitter >= 0) out.put("rx_jitter_ms", jitter * 1000);
                Map<String, Double> current = new HashMap<>();
                for (String key : COUNTERS) {
                    Double value = number(rtp.members.get(key));
                    if (value != null) current.put(key, value);
                }
                Map<String, Double> before = previous.get(rtp.id);
                if (before != null && !resetDetected(before, current)) {
                    delta(out, "rx_lost_packets", "packetsLost", before, current);
                    delta(out, "rx_concealed_samples", "concealedSamples", before, current);
                    ratio(out, "rx_concealment_pct", "concealedSamples", "totalSamplesReceived", 100, before, current);
                    ratio(out, "rx_buffer_ms", "jitterBufferDelay", "jitterBufferEmittedCount", 1000, before, current);
                }
                next.put(rtp.id, current);
            } else {
                copyNumber(out, rtp, "packetsSent"); copyNumber(out, rtp, "bytesSent");
            }
            Entry codec = linked(entries, rtp, "codecId", "codec");
            if (codec != null) {
                // Do not echo arbitrary SDK strings, even in an allowlisted member.
                if ("audio/opus".equalsIgnoreCase(String.valueOf(codec.members.get("mimeType")))) out.put("codec.mimeType", "audio/opus");
                copyNumber(out, codec, "clockRate"); copyNumber(out, codec, "channels");
            }
            Entry transport = linked(entries, rtp, "transportId", "transport");
            Entry pair = transport == null ? null : linked(entries, transport, "selectedCandidatePairId", "candidate-pair");
            Entry local = pair == null ? null : linked(entries, pair, "localCandidateId", "local-candidate");
            Entry remote = pair == null ? null : linked(entries, pair, "remoteCandidateId", "remote-candidate");
            if (local != null && remote != null) {
                copyNumber(out, pair, "currentRoundTripTime"); copyNumber(out, pair, "availableOutgoingBitrate");
                Double rtt = number(pair.members.get("currentRoundTripTime"));
                if (rtt != null && rtt >= 0) out.put("path_rtt_ms", rtt * 1000);
                candidate(out, local); candidate(out, remote);
            }
            result.add(out);
        }
        previous = next;
        return result;
    }

    private static Entry linked(Map<String, Entry> entries, Entry from, String key, String type) {
        Object id = from.members.get(key);
        Entry entry = id instanceof String ? entries.get(id) : null;
        return entry != null && type.equals(entry.type) ? entry : null;
    }
    private static void candidate(Map<String, Object> out, Entry entry) {
        if (entry == null) return;
        Object type = entry.members.get("candidateType");
        if (Arrays.asList("host", "srflx", "prflx", "relay").contains(type)) out.put(entry.type + ".candidateType", type);
        if ("remote-candidate".equals(entry.type)) {
            Object protocol = entry.members.get("protocol");
            if ("udp".equals(protocol) || "tcp".equals(protocol)) out.put(entry.type + ".protocol", protocol);
        }
    }
    private static Double number(Object value) {
        if (!(value instanceof Number)) return null;
        double number = ((Number) value).doubleValue();
        return Double.isFinite(number) ? number : null;
    }
    private static void copyNumber(Map<String, Object> out, Entry entry, String key) {
        Double value = number(entry.members.get(key));
        if (value != null) out.put(entry.type + "." + key, value);
    }
    private static boolean resetDetected(Map<String, Double> before, Map<String, Double> now) {
        for (String key : COUNTERS) {
            // Loss can decrease when late packets arrive; it is not a monotonic counter.
            if (!"packetsLost".equals(key) && before.containsKey(key) && now.containsKey(key)
                    && now.get(key) < before.get(key)) return true;
        }
        return false;
    }
    private static Double difference(String key, Map<String, Double> before, Map<String, Double> now) {
        return before.containsKey(key) && now.containsKey(key) ? now.get(key) - before.get(key) : null;
    }
    private static void delta(Map<String, Object> out, String name, String key, Map<String, Double> before, Map<String, Double> now) {
        Double value = difference(key, before, now);
        if (value != null && (value >= 0 || "packetsLost".equals(key))) out.put(name, value);
    }
    private static void ratio(Map<String, Object> out, String name, String numerator, String denominator, double scale,
                              Map<String, Double> before, Map<String, Double> now) {
        Double top = difference(numerator, before, now), bottom = difference(denominator, before, now);
        if (top != null && bottom != null && top >= 0 && bottom > 0) out.put(name, scale * top / bottom);
    }
}
