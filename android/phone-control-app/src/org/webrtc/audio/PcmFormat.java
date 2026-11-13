package org.webrtc.audio;

/** Immutable AirSIM PCM16 mono contract. A format never changes during a native peer's lifetime. */
public final class PcmFormat {
    public static final int PCM16 = 2; // android.media.AudioFormat.ENCODING_PCM_16BIT
    public static final PcmFormat NARROWBAND = new PcmFormat(8000);
    public static final PcmFormat WIDEBAND = new PcmFormat(48000);
    private final int rate;

    private PcmFormat(int rate) { this.rate = rate; }

    public static PcmFormat atRate(int rate) {
        if (rate == 8000) return NARROWBAND;
        if (rate == 48000) return WIDEBAND;
        throw new IllegalArgumentException("unsupported PCM rate");
    }

    public int rate() { return rate; }
    public int frameSamples() { return rate / 100; }
    public int frameBytes() { return frameSamples() * 2; }
    public int rampSamples() { return rate / 200; }
    public int bufferBytes(int millis) {
        if (millis < 0 || millis > 1000) throw new IllegalArgumentException("invalid PCM duration");
        return rate * 2 * millis / 1000;
    }

    public boolean matches(int encoding, int channels, int sampleRate, int bytes) {
        return encoding == PCM16 && channels == 1 && sampleRate == rate && bytes == frameBytes();
    }
}
