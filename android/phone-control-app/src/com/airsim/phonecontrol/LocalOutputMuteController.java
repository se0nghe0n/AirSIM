package com.airsim.phonecontrol;

import java.io.IOException;

/** One remote-call mute cycle; the backend runs with Shizuku shell/root identity. */
final class LocalOutputMuteController {
    interface Backend {
        boolean isMuted() throws Exception;
        int volume() throws Exception;
        void setMuted(boolean muted) throws Exception;
        void setVolume(int volume) throws Exception;
    }

    private final Backend backend;
    private boolean started;
    private boolean previousMuted;
    private int previousVolume;
    private boolean verifiedMuted;

    LocalOutputMuteController(Backend backend) { this.backend = backend; }
    boolean isVerifiedMuted() { return verifiedMuted; }
    String setMuted(boolean muted) throws Exception {
        if (!muted) return restore();
        if (!started) {
            // Finish all reads before marking the snapshot usable or changing system audio.
            boolean originalMuted = backend.isMuted();
            int originalVolume = backend.volume();
            previousMuted = originalMuted;
            previousVolume = originalVolume;
            started = true;
        }
        try {
            if (!backend.isMuted()) backend.setMuted(true);
            verifiedMuted = backend.isMuted();
            if (!verifiedMuted) throw new IOException("System does not support verified local call muting");
            return "local_output_muted previous_muted=" + previousMuted + " verified=true";
        } catch (Exception failure) {
            verifiedMuted = false;
            try { restore(); }
            catch (Exception restoreFailure) { failure.addSuppressed(restoreFailure); }
            throw failure;
        }
    }

    private String restore() throws Exception {
        if (!started) return "local_output_unchanged";
        verifiedMuted = false;
        // Keep the snapshot until EVERY restoration check succeeds so disconnect/destroy can retry.
        if (backend.isMuted() != previousMuted) backend.setMuted(previousMuted);
        if (backend.volume() != previousVolume) backend.setVolume(previousVolume);
        if (backend.isMuted() != previousMuted || backend.volume() != previousVolume) {
            throw new IOException("Local call audio restoration verification failed");
        }
        boolean restoredMuted = previousMuted;
        started = false;
        verifiedMuted = false;
        return "local_output_restored previous_muted=" + restoredMuted + " verified=true";
    }
}
