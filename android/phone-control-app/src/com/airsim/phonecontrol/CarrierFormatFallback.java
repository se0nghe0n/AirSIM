package com.airsim.phonecontrol;

import java.util.LinkedHashMap;
import java.util.Locale;
import java.util.Map;

/** One-way fallback for this call only, remembered after confirmed complete native disposal. */
final class CarrierFormatFallback {
    static final String FORMAT_INIT_FAILED = "carrier_format_init_failed";
    private final Map<String, Boolean> rejected = new LinkedHashMap<>();

    boolean useNarrowband(String call, long generation) { return rejected.containsKey(key(call, generation)); }

    boolean recordDisposedFailure(String call, long generation, int rate, String reason) {
        if (rate != 48000 || !FORMAT_INIT_FAILED.equals(reason)) return false;
        boolean fresh = !useNarrowband(call, generation);
        rejected.put(key(call, generation), Boolean.TRUE);
        while (rejected.size() > 64) rejected.remove(rejected.keySet().iterator().next());
        return fresh;
    }

    private static String key(String call, long generation) {
        return call.toLowerCase(Locale.ROOT) + ":" + generation;
    }
}
