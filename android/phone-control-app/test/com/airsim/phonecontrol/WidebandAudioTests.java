package com.airsim.phonecontrol;

import java.nio.ByteBuffer;
import java.util.Arrays;
import org.webrtc.audio.PcmFormat;

/** Synthetic PCM only: no JNI, routes, microphones, calls or private audio. */
public final class WidebandAudioTests {
    private static int checks;

    public static void main(String[] args) throws Exception {
        formats(); selection(); contracts(); fallback();
        for (PcmFormat format : new PcmFormat[]{PcmFormat.NARROWBAND, PcmFormat.WIDEBAND}) {
            framing(format); timingAndRamps(format);
        }
        System.out.println("Wideband PCM/selection/contract tests passed (" + checks + " checks; synthetic, no JNI)");
    }

    private static void formats() {
        for (int rate : new int[]{8000, 48000}) {
            PcmFormat format = PcmFormat.atRate(rate);
            check(format.frameSamples() == rate / 100 && format.frameBytes() == rate / 50, "10 ms PCM frame");
            check(format.rampSamples() == rate / 200, "5 ms ramp");
            check(format.bufferBytes(80) == format.frameBytes() * 8, "80 ms buffer is not a fixed byte count");
        }
        for (int rate : new int[]{0, 8001, 16000, 44100, 96000}) {
            try { PcmFormat.atRate(rate); throw new AssertionError("unsupported rate accepted"); }
            catch (IllegalArgumentException expected) { checks++; }
        }
    }

    private static CarrierAudioFormatPolicy.Endpoint endpoint(boolean source, int encoding, int rate, int channels) {
        return new CarrierAudioFormatPolicy.Endpoint(true, source, !source,
                new int[]{encoding}, new int[]{rate}, new int[]{channels});
    }

    private static void selection() {
        var rx = endpoint(true, PcmFormat.PCM16, 48000, 1);
        var tx = endpoint(false, PcmFormat.PCM16, 48000, 1);
        check(CarrierAudioFormatPolicy.select(new CarrierAudioFormatPolicy.Endpoint[]{rx, tx}) == PcmFormat.WIDEBAND,
                "explicit wideband PCM16 mono in both directions");
        for (var endpoints : new CarrierAudioFormatPolicy.Endpoint[][]{
                null, {}, {rx}, {tx}, {rx, endpoint(false, PcmFormat.PCM16, 8000, 1)},
                {rx, endpoint(false, 4, 48000, 1)}, {rx, endpoint(false, PcmFormat.PCM16, 48000, 2)},
                {rx, new CarrierAudioFormatPolicy.Endpoint(false, false, true, new int[]{2}, new int[]{48000}, new int[]{1})},
                {rx, new CarrierAudioFormatPolicy.Endpoint(true, false, true, new int[0], new int[]{48000}, new int[]{1})},
                {rx, new CarrierAudioFormatPolicy.Endpoint(true, false, true, new int[]{2}, new int[0], new int[]{1})},
                {rx, new CarrierAudioFormatPolicy.Endpoint(true, false, true, new int[]{2}, new int[]{48000}, new int[0])},
                // Each row is one actual profile: never combine PCM16 from one with 48 kHz from another.
                {rx, endpoint(false, 2, 8000, 1), endpoint(false, 4, 48000, 1)},
                {rx, endpoint(false, 2, 48000, 2), endpoint(false, 2, 8000, 1)}
        }) check(CarrierAudioFormatPolicy.select(endpoints) == PcmFormat.NARROWBAND,
                "unknown, mismatched, non-carrier or incompatible profiles remain narrowband");
    }

    private static void contracts() {
        for (PcmFormat f : new PcmFormat[]{PcmFormat.NARROWBAND, PcmFormat.WIDEBAND}) {
            byte[] frame = tone(f, f == PcmFormat.WIDEBAND ? 6000 : 1000);
            ByteBuffer direct = ByteBuffer.allocateDirect(f.frameBytes());
            check(WebRTCPcmContract.copyCapture(f, direct, 2, 1, f.rate(), frame), "exact capture accepted");
            byte[] copied = new byte[f.frameBytes()]; direct.get(copied);
            check(Arrays.equals(frame, copied), "capture callback preserves every sample");
            check(WebRTCPcmContract.acceptsPlayback(f, 2, 1, f.rate(), frame), "exact playout accepted");
            for (int[] metadata : new int[][]{{4,1,f.rate()}, {2,2,f.rate()}, {2,1,44100}, {2,1,f.rate()==8000?48000:8000}}) {
                check(!WebRTCPcmContract.acceptsCapture(f, direct, metadata[0], metadata[1], metadata[2]), "capture metadata rejected");
                check(!WebRTCPcmContract.acceptsPlayback(f, metadata[0], metadata[1], metadata[2], frame), "playback metadata rejected");
            }
            for (int length : new int[]{0, f.frameBytes()-1, f.frameBytes()/2, f.frameBytes()*2}) {
                check(!WebRTCPcmContract.acceptsCapture(f, ByteBuffer.allocateDirect(length), 2, 1, f.rate()), "capture size rejected");
                check(!WebRTCPcmContract.acceptsPlayback(f, 2, 1, f.rate(), new byte[length]), "playback size rejected");
            }
            check(!WebRTCPcmContract.acceptsCapture(f, ByteBuffer.allocate(f.frameBytes()), 2, 1, f.rate()), "heap native buffer rejected");
            check(!WebRTCPcmContract.acceptsCapture(f, direct.asReadOnlyBuffer(), 2, 1, f.rate()), "read-only native buffer rejected");
            check(!WebRTCPcmContract.copyCapture(f, direct, 2, 1, f.rate(), new byte[1]), "bad capture frame rejected");
            direct.clear(); direct.put(frame); direct.limit(1);
            WebRTCPcmContract.silence(direct);
            byte[] silent = new byte[f.frameBytes()]; direct.get(silent);
            check(Arrays.equals(silent, new byte[f.frameBytes()]), "mismatched writable buffer is silenced across its capacity");
            WebRTCPcmContract.silence(null);
            WebRTCPcmContract.silence(direct.asReadOnlyBuffer());
            check(!WebRTCPcmContract.acceptsPlayback(f, 2, 1, f.rate(), null), "missing playback rejected");
            WebRTCPlayoutClock playout = new WebRTCPlayoutClock(new WebRTCPcmBuffer(f), () -> true);
            try { playout.accept(new byte[f.frameBytes()*2]); throw new AssertionError("oversized playout accepted"); }
            catch (IllegalArgumentException expected) { checks++; }
        }
    }

    private static void framing(PcmFormat f) throws Exception {
        int hz = f == PcmFormat.WIDEBAND ? 6000 : 1000;
        byte[] frame = tone(f, hz);
        WebRTCPcmBuffer capture = new WebRTCPcmBuffer(f);
        capture.offer(frame, 0, 13); capture.offer(frame, 13, frame.length-13);
        byte[] captured = new WebRTCCaptureClock(capture).next(true);
        check(Arrays.equals(captured, frame), "fragmented carrier capture preserves the full waveform");
        check(power(captured, f.rate(), hz) > 9_000_000, "generated tone energy survives capture");
        if (f == PcmFormat.WIDEBAND) check(power(captured, f.rate(), 2000) < 1, "6 kHz is not an aliased 2 kHz tone");
        WebRTCPcmBuffer playback = new WebRTCPcmBuffer(f, WebRTCPcmBuffer.NO_AGE_LIMIT);
        WebRTCPlayoutClock playout = new WebRTCPlayoutClock(playback, () -> true);
        playout.accept(frame);
        byte[] rendered = playback.take(0);
        check(Arrays.equals(rendered, frame), "native playout preserves all carrier-bound samples");
        check(power(rendered, f.rate(), hz) > 9_000_000, "tone survives the second direction");
        check(new WebRTCCaptureClock(new WebRTCPcmBuffer(f)).next(false).length == f.frameBytes(), "pre-answer silence uses this rate");
        capture.close(); playback.close();
    }

    private static void timingAndRamps(PcmFormat f) {
        WebRTCPcmBuffer q = new WebRTCPcmBuffer(f);
        byte[] positive = constant(f, 10000), negative = constant(f, -10000);
        q.offer(positive, 0, positive.length, 0); q.poll(0);
        for (int i = 0; i <= WebRTCPcmBuffer.MAX_FRAMES; i++) q.offer(negative, 0, negative.length, 0);
        check(q.size() == 6 && q.drops() == 1, "60 ms cap independent of rate");
        byte[] ramped = q.poll(0);
        check(WebRTCPcmBuffer.sample(ramped, f.rampSamples()-1) > -10000
                && WebRTCPcmBuffer.sample(ramped, f.rampSamples()) == -10000, "ramp remains exactly 5 ms");
        q = new WebRTCPcmBuffer(f);
        q.offer(positive, 0, positive.length, 0);
        check(Arrays.equals(q.poll(80_000_000L), positive), "80 ms frame is retained");
        q.offer(positive, 0, positive.length, 0); q.poll(80_000_001L);
        check(q.drops() == 1, "frame older than 80 ms expires");
        q.close(); q.reopen();
        check(Arrays.equals(q.poll(), new byte[f.frameBytes()]), "reopen erases prior waveform");
    }

    private static void fallback() {
        CarrierFormatFallback f = new CarrierFormatFallback();
        for (String reason : new String[]{"carrier_route_unverified", "carrier_permission_denied", "carrier_capture_timeout",
                "carrier_playback_stopped", "carrier_cleanup_failed", "carrier_device_initialization_failed", "device_format_unavailable"}) {
            check(!f.recordDisposedFailure("CALL", 1, 48000, reason) && !f.useNarrowband("call", 1), "ordinary errors never downgrade");
        }
        check(!f.recordDisposedFailure("CALL", 1, 8000, CarrierFormatFallback.FORMAT_INIT_FAILED), "no repeated downgrade from 8 kHz");
        check(f.recordDisposedFailure("CALL", 1, 48000, CarrierFormatFallback.FORMAT_INIT_FAILED), "one explicit format failure selects fallback");
        check(f.useNarrowband("call", 1), "same call identity survives new owner");
        check(!f.useNarrowband("call", 2) && !f.useNarrowband("another", 1), "generation and other calls stay independent");
        check(!f.recordDisposedFailure("CALL", 1, 48000, CarrierFormatFallback.FORMAT_INIT_FAILED), "fallback event is emitted once");
    }

    private static byte[] tone(PcmFormat f, int hz) {
        byte[] bytes = new byte[f.frameBytes()];
        for (int i=0;i<f.frameSamples();i++) {
            short sample = (short)(12000*Math.sin(2*Math.PI*hz*i/f.rate()));
            bytes[2*i]=(byte)sample; bytes[2*i+1]=(byte)(sample>>8);
        }
        return bytes;
    }
    private static byte[] constant(PcmFormat f, int sample) {
        byte[] bytes = new byte[f.frameBytes()];
        for (int i=0;i<f.frameSamples();i++) { bytes[2*i]=(byte)sample; bytes[2*i+1]=(byte)(sample>>8); }
        return bytes;
    }
    private static double power(byte[] bytes, int rate, int hz) {
        double real=0, imaginary=0; int samples=bytes.length/2;
        for (int i=0;i<samples;i++) {
            int sample=WebRTCPcmBuffer.sample(bytes,i);
            real += sample*Math.cos(2*Math.PI*hz*i/rate);
            imaginary += sample*Math.sin(2*Math.PI*hz*i/rate);
        }
        return (real*real+imaginary*imaginary)/(samples*samples);
    }
    private static void check(boolean ok, String message) { if (!ok) throw new AssertionError(message); checks++; }
}
