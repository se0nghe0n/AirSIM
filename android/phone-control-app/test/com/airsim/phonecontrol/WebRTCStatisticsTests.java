package com.airsim.phonecontrol;

import java.util.*;

public final class WebRTCStatisticsTests {
    private static void check(boolean value, String message) { if (!value) throw new AssertionError(message); }
    private static WebRTCStatistics.Entry entry(String id, String type, Object... values) {
        Map<String, Object> members = new HashMap<>();
        for (int i = 0; i < values.length; i += 2) members.put((String) values[i], values[i + 1]);
        return new WebRTCStatistics.Entry(id, type, members);
    }
    private static Map<String, WebRTCStatistics.Entry> report(long packets, long lost, long concealed, long total, double delay, long emitted) {
        Map<String, WebRTCStatistics.Entry> all = new LinkedHashMap<>();
        for (WebRTCStatistics.Entry e : new WebRTCStatistics.Entry[]{
                entry("secret-rtp", "inbound-rtp", "kind", "audio", "transportId", "secret-transport", "codecId", "secret-codec",
                        "packetsReceived", packets, "packetsLost", lost, "bytesReceived", packets * 100,
                        "concealedSamples", concealed, "totalSamplesReceived", total, "jitterBufferDelay", delay,
                        "jitterBufferEmittedCount", emitted, "jitter", .012, "sdp", "SECRET"),
                entry("secret-transport", "transport", "selectedCandidatePairId", "secret-pair"),
                entry("secret-pair", "candidate-pair", "currentRoundTripTime", .05, "availableOutgoingBitrate", 32000,
                        "localCandidateId", "secret-local", "remoteCandidateId", "secret-remote"),
                entry("secret-local", "local-candidate", "candidateType", "relay", "address", "SECRET", "port", 9999, "url", "SECRET"),
                entry("secret-remote", "remote-candidate", "candidateType", "host", "protocol", "udp", "address", "SECRET"),
                entry("decoy", "candidate-pair", "selected", true, "nominated", true, "state", "succeeded", "currentRoundTripTime", 9),
                entry("secret-codec", "codec", "mimeType", "audio/opus", "clockRate", 48000, "channels", 2, "sdpFmtpLine", "SECRET")}) all.put(e.id, e);
        return all;
    }
    private static void equalsNumber(Map<String, Object> row, String key, double expected) {
        check(row.get(key) instanceof Number && Math.abs(((Number) row.get(key)).doubleValue() - expected) < .000001, key + "=" + row.get(key));
    }
    public static void main(String[] args) {
        WebRTCStatistics stats = new WebRTCStatistics();
        Map<String, Object> first = stats.sample(report(100, 2, 10, 1000, 1, 100)).get(0);
        equalsNumber(first, "path_rtt_ms", 50); equalsNumber(first, "rx_jitter_ms", 12);
        check("relay".equals(first.get("local-candidate.candidateType")), "selected local candidate");
        check("udp".equals(first.get("remote-candidate.protocol")), "selected remote protocol");
        check(!first.containsKey("rx_lost_packets") && !first.containsKey("rx_buffer_ms"), "first sample has no deltas");
        String log = first.toString();
        for (String forbidden : new String[]{"secret", "SECRET", "address", "port=", "url", "sdp", "credential"}) check(!log.contains(forbidden), "leak: " + forbidden);
        Map<String, Object> next = stats.sample(report(200, 5, 30, 2000, 3, 200)).get(0);
        equalsNumber(next, "rx_lost_packets", 3); equalsNumber(next, "rx_concealed_samples", 20);
        equalsNumber(next, "rx_concealment_pct", 2); equalsNumber(next, "rx_buffer_ms", 20);
        Map<String, Object> correctedLoss = stats.sample(report(300, 4, 40, 3000, 5, 300)).get(0);
        equalsNumber(correctedLoss, "rx_lost_packets", -1);
        equalsNumber(correctedLoss, "rx_buffer_ms", 20);
        Map<String, Object> reset = stats.sample(report(1, 0, 0, 20, .1, 2)).get(0);
        check(!reset.containsKey("rx_buffer_ms") && !reset.containsKey("rx_lost_packets"), "reset suppresses all intervals");
        equalsNumber(stats.sample(report(2, 1, 1, 40, .2, 4)).get(0), "rx_buffer_ms", 50);
        stats.reset();
        check(!stats.sample(report(3, 2, 2, 60, .3, 6)).get(0).containsKey("rx_lost_packets"), "negotiation reset");
        stats.sample(Collections.emptyMap());
        check(!stats.sample(report(4, 3, 3, 80, .4, 8)).get(0).containsKey("rx_lost_packets"), "disappeared RTP reset");
        Map<String, WebRTCStatistics.Entry> absent = report(100, 2, 10, 1000, 1, 100);
        absent.put("secret-transport", entry("secret-transport", "transport"));
        Map<String, Object> missing = stats.sample(absent).get(0);
        check(!missing.containsKey("path_rtt_ms") && !missing.containsKey("local-candidate.candidateType"), "do not select decoy without selected pair");
        absent = report(100, 2, 10, 1000, 1, 100);
        WebRTCStatistics.Entry oldRtp = absent.remove("secret-rtp");
        absent.put("new-rtp", new WebRTCStatistics.Entry("new-rtp", oldRtp.type, oldRtp.members));
        check(!stats.sample(absent).get(0).containsKey("rx_lost_packets"), "new RTP identity reset");
        Map<String, Object> unchanged = stats.sample(absent).get(0);
        check(!unchanged.containsKey("rx_buffer_ms") && !unchanged.containsKey("rx_concealment_pct"), "zero denominator omitted");
        absent = report(100, 2, 10, 1000, 1, 100);
        absent.remove("secret-transport");
        check(!stats.sample(absent).get(0).containsKey("path_rtt_ms"), "missing transport");
        absent = report(100, 2, 10, 1000, 1, 100);
        absent.remove("secret-remote");
        check(!stats.sample(absent).get(0).containsKey("path_rtt_ms"), "incomplete candidate chain");
        absent = report(100, 2, 10, 1000, 1, 100);
        absent.put("secret-remote", entry("secret-remote", "remote-candidate", "candidateType", "SECRET", "protocol", "SECRET"));
        log = stats.sample(absent).toString(); check(!log.contains("SECRET"), "candidate enum validation");
        absent.put("out", entry("out", "outbound-rtp", "mediaType", "audio", "packetsSent", 123, "bytesSent", 456));
        absent.put("video", entry("video", "inbound-rtp", "kind", "video", "packetsReceived", 999));
        List<Map<String, Object>> rows = stats.sample(absent);
        check(rows.size() == 2, "audio only"); equalsNumber(rows.get(1), "outbound-rtp.packetsSent", 123);
        System.out.println("PASS WebRTCStatisticsTests");
    }
}
