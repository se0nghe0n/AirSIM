package com.airsim.phonecontrol;

import java.util.EnumSet;
import java.util.Locale;
import java.util.function.Consumer;
import java.util.function.LongSupplier;

/** Fixed, once-per-stage monotonic diagnostics. No call metadata or audio enters this logger. */
final class CloudAudioSetupTimeline {
    enum Scope { APP, NATIVE, CARRIER }
    enum Phase {
        DIAL_ACCEPTED, OWNER_JOIN_RECEIVED, MEDIA_START_DEFERRED, MEDIA_START_ACTIVE,
        CARRIER_ACTIVATION, CARRIER_READY, NATIVE_CONNECTED, ROUTE_VERIFIED, FIRST_CAPTURE
    }

    private final Scope scope;
    private final LongSupplier clock;
    private final Consumer<String> log;
    private final long started;
    private final EnumSet<Phase> recorded = EnumSet.noneOf(Phase.class);

    CloudAudioSetupTimeline(Scope scope, LongSupplier clock, Consumer<String> log) {
        this.scope = scope;
        this.clock = clock;
        this.log = log;
        started = clock.getAsLong();
    }

    synchronized void mark(Phase phase) {
        if (!recorded.add(phase)) return;
        long now = clock.getAsLong();
        // Diagnostics must not interrupt signaling or an audio callback.
        try {
            log.accept("standalone_audio_setup scope=" + scope.name().toLowerCase(Locale.ROOT)
                    + " phase=" + phase.name().toLowerCase(Locale.ROOT)
                    + " elapsed_ms=" + Math.max(0, (now - started) / 1_000_000L)
                    + " monotonic_s=" + String.format(Locale.ROOT, "%.3f", now / 1_000_000_000.0));
        } catch (RuntimeException ignored) {}
    }
}
