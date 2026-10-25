package com.airsim.phonecontrol;

import org.json.*;
import java.util.concurrent.CompletableFuture;

/** Native boundary only: disposal may finish well after close returns, as in the real peer. */
final class TelephonyWebRTCPeer implements AutoCloseable {
    interface Signals { void send(JSONObject signal) throws Exception; }
    static int starts, closes;
    static boolean delayedDisposal, rejectStart;
    static TelephonyWebRTCPeer latest;
    final Signals signals;
    final Runnable failed;
    private final CompletableFuture<Void> disposal = new CompletableFuture<>();
    private boolean closing;

    TelephonyWebRTCPeer(android.content.Context c, String call, long generation, JSONArray ice,
                        Signals signals, Runnable failed, boolean host) {
        this.signals = signals; this.failed = failed; latest = this;
    }
    static void initialize(android.content.Context context) {}
    void start() {
        starts++;
        if (rejectStart) throw new IllegalStateException("fake_start_failure");
    }
    void receive(JSONObject signal) throws Exception { signals.send(signal); }
    CompletableFuture<Void> closeAsync() {
        if (!closing) {
            closing = true;
            closes++;
            if (!delayedDisposal) completeDisposal();
        }
        return disposal;
    }
    void completeDisposal() { disposal.complete(null); }
    void failDisposal() { disposal.completeExceptionally(new IllegalStateException("fake_disposal_failure")); }
    public void close() { closeAsync(); }
}
