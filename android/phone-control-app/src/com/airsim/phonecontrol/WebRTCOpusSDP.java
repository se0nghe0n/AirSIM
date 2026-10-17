package com.airsim.phonecontrol;

/** Add mono/FEC/DTX and 20 ms packetization to the native Opus answer. */
final class WebRTCOpusSDP {
    static String configure(String sdp) {
        String[] lines = sdp.replace("\r\n", "\n").split("\n");
        String payload = null;
        for (String line : lines) {
            if (line.matches("a=rtpmap:[0-9]+ opus/48000/2")) payload = line.substring(9, line.indexOf(' '));
        }
        if (payload == null) throw new IllegalArgumentException("Opus not negotiated");
        StringBuilder output = new StringBuilder();
        boolean audio = false;
        for (String line : lines) {
            if (line.startsWith("m=")) audio = line.startsWith("m=audio ");
            if (audio && (line.startsWith("a=ptime:") || line.startsWith("a=maxptime:"))) continue;
            if (line.startsWith("a=fmtp:" + payload + " ")) continue;
            output.append(line).append("\r\n");
            if (line.startsWith("a=rtpmap:" + payload + " ")) {
                output.append("a=fmtp:").append(payload).append(" minptime=10;useinbandfec=1;usedtx=1;stereo=0;sprop-stereo=0\r\n")
                        .append("a=ptime:20\r\na=maxptime:20\r\n");
            }
        }
        return output.toString();
    }
}
