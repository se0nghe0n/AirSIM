package com.airsim.phonecontrol;

import java.util.Arrays;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicInteger;

public final class WebRTCMediaTests {
    public static void main(String[] args) throws Exception {
        WebRTCPcmBuffer queue = new WebRTCPcmBuffer();
        byte[] twenty = new byte[320];
        Arrays.fill(twenty, 0, 160, (byte) 3); Arrays.fill(twenty, 160, 320, (byte) 7);
        queue.offer(twenty, 0, 73); queue.offer(twenty, 73, 247);
        require(queue.size() == 2, "fragmented20ms becomes two10ms frames");
        require(queue.poll()[159] == 3 && queue.poll()[0] == 7, "fragment boundaries preserve PCM");
        byte[] concealed = queue.poll();
        require(queue.underruns() == 1, "empty pull is counted");
        require(Math.abs(sample(concealed, 0) - 0x0707) < 0x0707 / 40 && sample(concealed, 79) == 0,
                "underflow continues the last sample and fades to silence");
        require(Arrays.equals(queue.poll(), new byte[160]), "continued underflow is silence");

        WebRTCPcmBuffer overflow = new WebRTCPcmBuffer();
        for (int i = 0; i < 20; i++) overflow.offer(frame(i * 100), 0, 160);
        require(overflow.size() == 6 && overflow.drops() == 14, "overflow drops oldest speech");
        require(sample(overflow.poll(), 0) == 1400, "first emitted frame is untouched");

        WebRTCPcmBuffer aged = new WebRTCPcmBuffer();
        aged.offer(frame(1), 0, 160, 0);
        aged.offer(frame(2), 0, 160, 50_000_000L);
        require(sample(aged.poll(100_000_000L), 0) == 2 && aged.drops() == 1, "expired frame is not encoded");

        // A dropped frame is joined with a ramp, not a step the listener hears as a pop.
        WebRTCPcmBuffer joined = new WebRTCPcmBuffer();
        joined.offer(frame(8000), 0, 160);
        byte[] before = joined.poll();
        for (int i = 0; i < WebRTCPcmBuffer.MAX_FRAMES + 1; i++) joined.offer(frame(-8000), 0, 160);
        byte[] after = joined.poll();
        require(joined.drops() == 1, "overflow is a discontinuity");
        require(maxStep(before, after) <= 16000 / WebRTCPcmBuffer.RAMP_SAMPLES + 1, "dropped audio is cross-faded");
        require(sample(after, WebRTCPcmBuffer.RAMP_SAMPLES) == -8000 && sample(after, 79) == -8000, "ramp is 5 ms");
        byte[] next = joined.poll();
        require(sample(next, 0) == -8000, "continuous frames are untouched");

        // Concealment and resumption have no step either.
        WebRTCPcmBuffer resumed = new WebRTCPcmBuffer();
        resumed.offer(frame(12000), 0, 160);
        byte[] speech = resumed.poll();
        byte[] gap = resumed.poll();
        resumed.offer(frame(12000), 0, 160);
        byte[] back = resumed.poll();
        require(maxStep(speech, gap) <= 12000 / 40 + 1 && maxStep(gap, back) <= 12000 / 40 + 1, "concealment is smooth");
        require(sample(back, 79) == 12000, "resumed speech keeps its level");

        WebRTCPcmBuffer reopened = new WebRTCPcmBuffer();
        reopened.offer(frame(5000), 0, 160); reopened.poll(); reopened.close(); reopened.reopen();
        require(Arrays.equals(reopened.poll(), new byte[160]), "reopen forgets the previous call's audio");

        require(WebRTCPlayout.JITTER_BUFFER_MAX_PACKETS == 50 && WebRTCPlayout.FAST_ACCELERATE, "NetEq caps one second and accelerates");
        queue.close(); require(queue.take() == null, "close clears queued speech");
        queue.offer(twenty, 0, 320); require(queue.size() == 0, "closed queue rejects late callback");
        WebRTCPcmBuffer waiting = new WebRTCPcmBuffer(); AtomicBoolean woke = new AtomicBoolean();
        Thread waiter = new Thread(() -> { try { woke.set(waiting.take() == null); } catch (InterruptedException error) { throw new AssertionError(error); } });
        waiter.start(); waiting.close(); waiter.join(1000); require(woke.get(), "close wakes blocked writer");

        WebRTCPcmBuffer timed = new WebRTCPcmBuffer();
        long started = System.nanoTime();
        require(timed.take(20_000_000L) == null && System.nanoTime() - started >= 20_000_000L, "timed take waits then gives up");
        require(timed.take(0) == null && timed.underruns() == 0, "a timed take does not conceal by itself");

        captureClockTests();
        playoutClockTests();

        String sdp = "v=0\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\na=rtpmap:111 opus/48000/2\r\na=fmtp:111 minptime=10;stereo=1\r\na=ptime:60\r\na=maxptime:120\r\na=sendrecv\r\n";
        String tuned = WebRTCOpusSDP.configure(sdp);
        require(tuned.contains("useinbandfec=1;usedtx=1;stereo=0;sprop-stereo=0"), "Opus FEC DTX mono");
        require(tuned.contains("a=ptime:20\r\na=maxptime:20") && !tuned.contains("ptime:60"), "packetization20ms");
        require(tuned.contains("a=sendrecv"), "SDP direction retained");
        require(WebRTCOpusSDP.configure(tuned).equals(tuned), "SDP tuning idempotent");
        try { WebRTCOpusSDP.configure("v=0\r\n"); throw new AssertionError("missingOpus accepted"); } catch (IllegalArgumentException expected) {}
        opusSectionTests();
        System.out.println("WebRTC media tests passed");
    }

    private static void opusSectionTests() {
        String audio = "m=audio 9 UDP/TLS/RTP/SAVPF 111 0\r\n"
                + "a=rtpmap:111 OpUs/48000/2\r\n"
                + "a=fmtp:111 minptime = 60; useINbandFEC = 0;usedtx=0; stereo = 1; sprop-stereo=1;maxaveragebitrate=24000\r\n"
                + "a=fmtp:111 useinbandfec=0;maxplaybackrate=16000;cbr=1\r\n"
                + "a=rtpmap:0 PCMU/8000\r\na=rtcp-fb:111 transport-cc\r\na=rtcp-fb:* nack\r\n"
                + "a=ptime:60\r\na=maxptime:120\r\na=ptime:40\r\n";
        String second = "m=audio 9 UDP/TLS/RTP/SAVPF 112\r\na=rtpmap:112 opus/48000/2\r\na=sendrecv\r\n";
        String video = "m=video 9 UDP/TLS/RTP/SAVPF 111\r\na=rtpmap:111 VP8/90000\r\na=fmtp:111 max-fr=30\r\n"
                + "a=ptime:99\r\n";
        String rejected = "m=audio 0 UDP/TLS/RTP/SAVPF 111\r\na=rtpmap:111 opus/48000/2\r\na=fmtp:111 stereo=1\r\na=ptime:60\r\n";
        String nonOpus = "m=audio 9 UDP/TLS/RTP/SAVPF 0\r\na=rtpmap:0 PCMU/8000\r\na=ptime:40\r\n";
        String application = "m=application 9 UDP/DTLS/SCTP webrtc-datachannel\r\na=sctp-port:5000\r\n";
        String tuned = WebRTCOpusSDP.configure("v=0\r\n" + audio + video + second + rejected + nonOpus + application);
        require(tuned.contains("a=fmtp:111 minptime=10;useinbandfec=1;usedtx=1;stereo=0;sprop-stereo=0;maxaveragebitrate=24000;maxplaybackrate=16000;cbr=1\r\n"),
                "unowned native codec constraints survive and owned parameters are canonical");
        require(tuned.contains("a=fmtp:112 minptime=10;useinbandfec=1;usedtx=1;stereo=0;sprop-stereo=0\r\n"),
                "each audio section gets FEC/DTX even if native fmtp was absent");
        require(tuned.contains(video) && tuned.contains(rejected) && tuned.contains(nonOpus) && tuned.contains(application),
                "video, rejected audio, non-Opus audio and data sections are unchanged");
        require(tuned.contains("a=rtpmap:0 PCMU/8000\r\na=rtcp-fb:111 transport-cc\r\na=rtcp-fb:* nack\r\n"),
                "codec preferences remain native and feedback is preserved");
        require(occurrences(tuned, "a=ptime:20\r\n") == 2 && occurrences(tuned, "a=maxptime:20\r\n") == 2,
                "packetization is emitted once per tuned audio section");
        require(WebRTCOpusSDP.configure(tuned).equals(tuned), "multi-section tuning is idempotent");

        String multiple = "v=0\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111 112\r\n"
                + "a=rtpmap:111 opus/48000/2\r\na=rtpmap:112 OPUS/48000/2\r\na=fmtp:112 stereo=1\r\n";
        tuned = WebRTCOpusSDP.configure(multiple);
        require(occurrences(tuned, "useinbandfec=1") == 2 && occurrences(tuned, "a=ptime:20\r\n") == 1,
                "multiple offered Opus mappings have independent fmtp and one packetization attribute");
        require(WebRTCOpusSDP.configure(tuned).equals(tuned), "multiple-payload tuning is idempotent");

        for (String invalid : new String[]{"v=0\r\n" + rejected,
                "v=0\r\nm=audio 9 UDP/TLS/RTP/SAVPF 0\r\na=rtpmap:111 opus/48000/2\r\n",
                "v=0\r\nm=video 9 UDP/TLS/RTP/SAVPF 111\r\na=rtpmap:111 opus/48000/2\r\n",
                "v=0\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\na=rtpmap:111 opus/48000/1\r\n"}) {
            try { WebRTCOpusSDP.configure(invalid); throw new AssertionError("unnegotiated Opus accepted"); }
            catch (IllegalArgumentException expected) {}
        }
    }

    private static int occurrences(String text, String value) {
        int count = 0;
        for (int offset = 0; (offset = text.indexOf(value, offset)) >= 0; offset += value.length()) count++;
        return count;
    }

    /** The carrier, not a 10 ms timer, clocks capture: drift in either direction loses nothing. */
    private static void captureClockTests() throws Exception {
        for (long period : new long[]{18_000_000L, 23_000_000L}) {
            WebRTCPcmBuffer capture = new WebRTCPcmBuffer();
            WebRTCCaptureClock clock = new WebRTCCaptureClock(capture);
            int bursts = 20;
            // Carrier HALs deliver capture in bursts; here two 10 ms frames per period.
            Thread carrier = new Thread(() -> {
                long due = System.nanoTime();
                for (int i = 0; i < bursts; i++) {
                    due += period;
                    while (System.nanoTime() < due) java.util.concurrent.locks.LockSupport.parkNanos(due - System.nanoTime());
                    capture.offer(frame(i * 2 + 1), 0, 160);
                    capture.offer(frame(i * 2 + 2), 0, 160);
                }
            });
            capture.offer(frame(0), 0, 160);
            carrier.start();
            for (int expected = 0; expected <= bursts * 2; expected++) {
                byte[] value = clock.next(true);
                require(sample(value, 79) == expected, "device clock delivers every carrier frame in order");
            }
            carrier.join(2000);
            require(clock.deviceClocked() && capture.underruns() == 0 && capture.drops() == 0,
                    "device-clocked capture neither conceals nor drops at period " + period);
        }

        WebRTCPcmBuffer stalled = new WebRTCPcmBuffer();
        WebRTCCaptureClock clock = new WebRTCCaptureClock(stalled);
        stalled.offer(frame(9000), 0, 160);
        require(sample(clock.next(true), 0) == 9000 && clock.deviceClocked(), "carrier frames switch to the device clock");
        long started = System.nanoTime();
        byte[] gap = clock.next(true);
        long waited = System.nanoTime() - started;
        require(waited >= WebRTCCaptureClock.STALL_NANOS && !clock.deviceClocked() && stalled.underruns() == 1,
                "a stalled carrier is concealed after the stall timeout");
        require(Math.abs(sample(gap, 0) - 9000) < 9000 / 40, "stall concealment starts at the last sample");
        started = System.nanoTime();
        for (int i = 0; i < 5; i++) clock.next(true);
        long paced = System.nanoTime() - started;
        require(paced >= 4 * WebRTCCaptureClock.FRAME_NANOS && paced < 20 * WebRTCCaptureClock.FRAME_NANOS,
                "a stalled carrier falls back to the 10 ms timer");
        stalled.offer(frame(9000), 0, 160);
        require(sample(clock.next(true), 79) == 9000 && clock.deviceClocked(), "returning carrier frames resume the device clock");

        WebRTCPcmBuffer detached = new WebRTCPcmBuffer();
        WebRTCCaptureClock idle = new WebRTCCaptureClock(detached);
        started = System.nanoTime();
        for (int i = 0; i < 5; i++) require(Arrays.equals(idle.next(false), new byte[160]), "no carrier sends silence");
        paced = System.nanoTime() - started;
        require(paced >= 4 * WebRTCCaptureClock.FRAME_NANOS && detached.underruns() == 0, "pre-answer capture is timer paced and uncounted");
        detached.close();
        started = System.nanoTime();
        for (int i = 0; i < 3; i++) idle.next(true);
        require(System.nanoTime() - started >= 2 * WebRTCCaptureClock.FRAME_NANOS, "a closed carrier never spins the capture thread");
    }

    /** The carrier AudioTrack paces NetEq; a stalled carrier hands pacing back to the timer. */
    private static void playoutClockTests() throws Exception {
        WebRTCPcmBuffer playback = new WebRTCPcmBuffer(WebRTCPcmBuffer.NO_AGE_LIMIT);
        playback.offer(frame(5), 0, 160, 0);
        require(sample(playback.poll(1_000_000_000L), 0) == 5 && playback.drops() == 0,
                "a carrier-paced queue does not age out frames a large device period holds");
        AtomicBoolean attached = new AtomicBoolean();
        WebRTCPlayoutClock clock = new WebRTCPlayoutClock(playback, attached::get);
        require(!clock.awaitPlayoutSlot(), "no carrier uses the timer");
        clock.accept(frame(1));
        require(playback.size() == 0, "detached playout is discarded");

        attached.set(true);
        require(clock.awaitPlayoutSlot(), "an empty carrier queue takes a frame at once");
        clock.accept(frame(1)); clock.accept(frame(2));
        require(playback.size() == WebRTCPlayout.CARRIER_QUEUE_FRAMES, "attached playout is queued");
        AtomicInteger taken = new AtomicInteger();
        Thread carrier = new Thread(() -> {
            try {
                Thread.sleep(30);
                byte[] value = playback.take();
                taken.set(sample(value, 0));
            } catch (InterruptedException error) { throw new AssertionError(error); }
        });
        long started = System.nanoTime();
        carrier.start();
        require(clock.awaitPlayoutSlot(), "a full carrier queue waits for the carrier clock");
        require(System.nanoTime() - started >= 25_000_000L, "playout resumes only after the carrier takes a frame");
        carrier.join(1000);
        require(taken.get() == 1, "the carrier takes the oldest decoded frame");

        // A carrier that stops consuming with its normal two-frame queue hands pacing to the timer.
        clock.accept(frame(3));
        require(playback.size() == WebRTCPlayout.CARRIER_QUEUE_FRAMES, "queue is at its carrier depth");
        started = System.nanoTime();
        require(!clock.awaitPlayoutSlot(), "a carrier that stops taking frames is a stall");
        require(System.nanoTime() - started >= WebRTCPlayout.CARRIER_STALL_NANOS, "stall is declared after its timeout");
        started = System.nanoTime();
        for (int tick = 0; tick < 10; tick++) {
            require(!clock.awaitPlayoutSlot(), "a stalled carrier stays on the timer");
            clock.accept(frame(4));
        }
        require(System.nanoTime() - started < WebRTCPlayout.CARRIER_STALL_NANOS / 2,
                "a stalled carrier does not block any timer tick, full queue or not");
        require(playback.size() == WebRTCPcmBuffer.MAX_FRAMES, "the timer replaces the oldest frame while stalled");
        playback.take();
        Thread drain = new Thread(() -> {
            try { for (int i = 0; i < WebRTCPcmBuffer.MAX_FRAMES - 2; i++) { Thread.sleep(5); playback.take(); } }
            catch (InterruptedException error) { throw new AssertionError(error); }
        });
        drain.start();
        require(clock.awaitPlayoutSlot(), "a recovered carrier clocks playout again");
        drain.join(1000);
        require(playback.size() < WebRTCPlayout.CARRIER_QUEUE_FRAMES, "recovered playout waits for the carrier queue to drain");

        attached.set(false);
        require(!clock.awaitPlayoutSlot(), "detaching returns pacing to the timer");
    }

    private static byte[] frame(int value) {
        byte[] pcm = new byte[160];
        for (int i = 0; i < 80; i++) { pcm[i * 2] = (byte) value; pcm[i * 2 + 1] = (byte) (value >> 8); }
        return pcm;
    }

    private static int sample(byte[] pcm, int index) { return WebRTCPcmBuffer.sample(pcm, index); }

    /** Largest sample-to-sample change across two consecutive frames. */
    private static int maxStep(byte[] first, byte[] second) {
        int step = 0, previous = sample(first, 0);
        for (byte[] pcm : new byte[][]{first, second}) {
            for (int i = 0; i < 80; i++) { int value = sample(pcm, i); step = Math.max(step, Math.abs(value - previous)); previous = value; }
        }
        return step;
    }

    private static void require(boolean value, String message) { if (!value) throw new AssertionError(message); }
}
