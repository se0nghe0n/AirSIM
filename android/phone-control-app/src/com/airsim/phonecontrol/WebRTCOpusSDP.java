package com.airsim.phonecontrol;

import java.util.*;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/** Add mono/FEC/DTX and 20 ms packetization to the native Opus answer. */
final class WebRTCOpusSDP {
    private static final Pattern OPUS = Pattern.compile("^a=rtpmap:([0-9]+)\\s+opus/48000/2\\s*$", Pattern.CASE_INSENSITIVE);
    private static final Pattern FMTP = Pattern.compile("^a=fmtp:([0-9]+)\\s+(.*)$", Pattern.CASE_INSENSITIVE);
    private static final String PARAMETERS = "minptime=10;useinbandfec=1;usedtx=1;stereo=0;sprop-stereo=0";
    private static final Set<String> OWNED_KEYS = new HashSet<>(Arrays.asList(
            "minptime", "useinbandfec", "usedtx", "stereo", "sprop-stereo"));

    static String configure(String sdp) {
        String[] lines = sdp.replace("\r\n", "\n").split("\n");
        StringBuilder output = new StringBuilder();
        boolean negotiated = false;
        for (int start = 0; start < lines.length;) {
            int end = start + 1;
            while (end < lines.length && !lines[end].startsWith("m=")) end++;
            negotiated |= configureSection(lines, start, end, output);
            start = end;
        }
        if (!negotiated) throw new IllegalArgumentException("Opus not negotiated");
        return output.toString();
    }

    private static boolean configureSection(String[] lines, int start, int end, StringBuilder output) {
        String[] media = lines[start].trim().split("\\s+");
        Set<String> payloads = new LinkedHashSet<>();
        if (media.length >= 4 && "m=audio".equals(media[0]) && !media[1].split("/", 2)[0].equals("0")) {
            Set<String> offered = new HashSet<>(Arrays.asList(media).subList(3, media.length));
            for (int i = start + 1; i < end; i++) {
                Matcher opus = OPUS.matcher(lines[i]);
                if (opus.matches() && offered.contains(opus.group(1))) payloads.add(opus.group(1));
            }
        }
        // Payload numbers are scoped to this media section. A rejected or non-audio section must
        // remain intact even if it reuses the same dynamic payload number.
        if (payloads.isEmpty()) {
            for (int i = start; i < end; i++) output.append(lines[i]).append("\r\n");
            return false;
        }
        Map<String, List<String>> retained = new LinkedHashMap<>();
        for (String payload : payloads) retained.put(payload, new ArrayList<>());
        for (int i = start + 1; i < end; i++) {
            Matcher fmtp = FMTP.matcher(lines[i]);
            if (!fmtp.matches() || !payloads.contains(fmtp.group(1))) continue;
            for (String parameter : fmtp.group(2).split(";")) {
                String value = parameter.trim();
                String key = value.split("=", 2)[0].trim().toLowerCase(Locale.ROOT);
                // Preserve SDK/remote codec constraints. Overwrite only parameters we own, even
                // when their keys have whitespace, different casing, or duplicate entries.
                if (!value.isEmpty() && !OWNED_KEYS.contains(key)) retained.get(fmtp.group(1)).add(value);
            }
        }
        Set<String> emitted = new HashSet<>();
        boolean packetization = false;
        for (int i = start; i < end; i++) {
            String line = lines[i];
            if (line.startsWith("a=ptime:") || line.startsWith("a=maxptime:")) continue;
            Matcher fmtp = FMTP.matcher(line);
            if (fmtp.matches() && payloads.contains(fmtp.group(1))) continue;
            output.append(line).append("\r\n");
            Matcher opus = OPUS.matcher(line);
            if (!opus.matches() || !payloads.contains(opus.group(1)) || !emitted.add(opus.group(1))) continue;
            String payload = opus.group(1);
            output.append("a=fmtp:").append(payload).append(' ').append(PARAMETERS);
            for (String parameter : retained.get(payload)) output.append(';').append(parameter);
            output.append("\r\n");
            if (!packetization) {
                output.append("a=ptime:20\r\na=maxptime:20\r\n");
                packetization = true;
            }
        }
        return true;
    }
}
