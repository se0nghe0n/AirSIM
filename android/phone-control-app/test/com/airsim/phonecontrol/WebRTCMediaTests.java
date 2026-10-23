package com.airsim.phonecontrol;

import java.util.Arrays;
import java.util.concurrent.atomic.AtomicBoolean;

public final class WebRTCMediaTests {
    public static void main(String[] args) throws Exception {
        WebRTCPcmBuffer queue = new WebRTCPcmBuffer();
        byte[] twenty = new byte[320];
        Arrays.fill(twenty, 0, 160, (byte) 3); Arrays.fill(twenty, 160, 320, (byte) 7);
        queue.offer(twenty, 0, 73); queue.offer(twenty, 73, 247);
        require(queue.size() == 2, "fragmented20ms becomes two10ms frames");
        require(queue.poll()[159] == 3 && queue.poll()[0] == 7, "fragment boundaries preserve PCM");
        require(Arrays.equals(queue.poll(), new byte[160]), "underflow silence");
        for (int i = 0; i < 20; i++) { byte[] frame = new byte[160]; Arrays.fill(frame, (byte)i); queue.offer(frame, 0, 160); }
        require(queue.size() == 6 && queue.drops() == 14 && queue.poll()[0] == 14, "overflow drops oldest speech");
        WebRTCPcmBuffer aged = new WebRTCPcmBuffer();
        byte[] old = new byte[160]; Arrays.fill(old, (byte) 1);
        byte[] fresh = new byte[160]; Arrays.fill(fresh, (byte) 2);
        aged.offer(old, 0, 160, 0);
        aged.offer(fresh, 0, 160, 50_000_000L);
        require(aged.poll(100_000_000L)[0] == 2 && aged.drops() == 1, "expired frame is not encoded");
        require(Arrays.equals(aged.poll(100_000_000L), new byte[160]) && aged.underruns() == 1, "empty pull is silence");
        require(WebRTCPlayout.JITTER_BUFFER_MAX_PACKETS == 50 && WebRTCPlayout.FAST_ACCELERATE, "NetEq caps one second and accelerates");
        require(WebRTCPcmBuffer.LOOPBACK_SOCKET_BYTES == 4096, "loopback socket hint is 4 KB");
        queue.close(); require(queue.take() == null, "close clears queued speech");
        queue.offer(twenty, 0, 320); require(queue.size() == 0, "closed queue rejects late callback");
        WebRTCPcmBuffer waiting = new WebRTCPcmBuffer(); AtomicBoolean woke = new AtomicBoolean();
        Thread waiter = new Thread(() -> { try { woke.set(waiting.take() == null); } catch (InterruptedException error) { throw new AssertionError(error); } });
        waiter.start(); waiting.close(); waiter.join(1000); require(woke.get(), "close wakes blocked writer");
        String sdp = "v=0\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\na=rtpmap:111 opus/48000/2\r\na=fmtp:111 minptime=10;stereo=1\r\na=ptime:60\r\na=maxptime:120\r\na=sendrecv\r\n";
        String tuned = WebRTCOpusSDP.configure(sdp);
        require(tuned.contains("useinbandfec=1;usedtx=1;stereo=0;sprop-stereo=0"), "Opus FEC DTX mono");
        require(tuned.contains("a=ptime:20\r\na=maxptime:20") && !tuned.contains("ptime:60"), "packetization20ms");
        require(tuned.contains("a=sendrecv"), "SDP direction retained");
        require(WebRTCOpusSDP.configure(tuned).equals(tuned), "SDP tuning idempotent");
        try { WebRTCOpusSDP.configure("v=0\r\n"); throw new AssertionError("missingOpus accepted"); } catch (IllegalArgumentException expected) {}
        System.out.println("WebRTC media tests passed");
    }
    private static void require(boolean value, String message) { if (!value) throw new AssertionError(message); }
}
