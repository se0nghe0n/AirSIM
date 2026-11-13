package com.airsim.phonecontrol;

import org.webrtc.audio.PcmFormat;

/** Read-only endpoint capabilities are a selection hint, not proof of carrier speech bandwidth. */
final class CarrierAudioFormatPolicy {
    static final class Endpoint {
        final boolean telephony, source, sink;
        final int[] encodings, rates, channels;

        Endpoint(boolean telephony, boolean source, boolean sink, int[] encodings, int[] rates, int[] channels) {
            this.telephony = telephony; this.source = source; this.sink = sink;
            this.encodings = encodings; this.rates = rates; this.channels = channels;
        }
    }

    static boolean supportsWideband(Endpoint endpoint) {
        return endpoint != null && endpoint.telephony && contains(endpoint.encodings, PcmFormat.PCM16)
                && contains(endpoint.rates, PcmFormat.WIDEBAND.rate()) && contains(endpoint.channels, 1);
    }

    static PcmFormat select(Endpoint[] endpoints) {
        boolean source = false, sink = false;
        if (endpoints != null) for (Endpoint endpoint : endpoints) {
            if (!supportsWideband(endpoint)) continue;
            source |= endpoint.source;
            sink |= endpoint.sink;
        }
        // Empty/dynamic/unknown profiles are deliberately not treated as evidence of wideband support.
        return source && sink ? PcmFormat.WIDEBAND : PcmFormat.NARROWBAND;
    }

    private static boolean contains(int[] values, int expected) {
        if (values != null) for (int value : values) if (value == expected) return true;
        return false;
    }
}
