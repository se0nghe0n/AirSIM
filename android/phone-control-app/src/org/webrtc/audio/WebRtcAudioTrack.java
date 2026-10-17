/*
 * AirSIM's external PCM playout adapter for webrtc-sdk 144.7559.15.
 * JNI method/constructor contract derived from the BSD-licensed WebRTC project.
 * See third_party/webrtc/LICENSE and README.md. Keep package/class/signatures pinned.
 */
package org.webrtc.audio;

import android.content.Context;
import android.media.AudioAttributes;
import android.media.AudioFormat;
import android.media.AudioManager;
import android.os.Process;
import java.nio.ByteBuffer;
import java.util.concurrent.locks.LockSupport;
import org.webrtc.CalledByNative;

/** No AudioTrack or physical speaker is created. The callback owns external PCM routing. */
class WebRtcAudioTrack {
    private final JavaAudioDeviceModule.PlaybackSamplesReadyCallback callback;
    private final JavaAudioDeviceModule.AudioTrackStateCallback stateCallback;
    private final JavaAudioDeviceModule.AudioTrackErrorCallback errorCallback;
    private long nativeAudioTrack;
    private ByteBuffer buffer;
    private int sampleRate;
    private int channels;
    private int volume = 1;
    private volatile boolean running;
    private volatile boolean muted;
    private Thread thread;

    @CalledByNative
    WebRtcAudioTrack(Context context, AudioManager audioManager) {
        this(context, audioManager, null, null, null, null, false, false);
    }

    WebRtcAudioTrack(Context context, AudioManager audioManager, AudioAttributes attributes,
                    JavaAudioDeviceModule.AudioTrackErrorCallback errorCallback,
                    JavaAudioDeviceModule.AudioTrackStateCallback stateCallback,
                    JavaAudioDeviceModule.PlaybackSamplesReadyCallback callback,
                    boolean useLowLatency, boolean enableVolumeLogger) {
        this.callback = callback;
        this.stateCallback = stateCallback;
        this.errorCallback = errorCallback;
    }

    @CalledByNative public void setNativeAudioTrack(long pointer) { nativeAudioTrack = pointer; }

    @CalledByNative private int initPlayout(int sampleRate, int channels, double bufferSizeFactor) {
        if (sampleRate != 8000 || channels != 1 || thread != null || callback == null) return -1;
        this.sampleRate = sampleRate;
        this.channels = channels;
        buffer = ByteBuffer.allocateDirect(sampleRate / 100 * channels * 2);
        nativeCacheDirectBufferAddress(nativeAudioTrack, buffer);
        return buffer.capacity();
    }

    @CalledByNative private boolean startPlayout() {
        if (buffer == null || thread != null) return false;
        running = true;
        thread = new Thread(() -> {
            Process.setThreadPriority(Process.THREAD_PRIORITY_URGENT_AUDIO);
            if (stateCallback != null) stateCallback.onWebRtcAudioTrackStart();
            long next = System.nanoTime();
            try {
                while (running) {
                    long now = System.nanoTime();
                    if (now < next) { LockSupport.parkNanos(next - now); continue; }
                    // Never replay a backlog in a burst after suspension.
                    next += 10_000_000L;
                    if (next < now) next = now + 10_000_000L;
                    if (!running) break;
                    nativeGetPlayoutData(nativeAudioTrack, buffer.capacity());
                    byte[] pcm = new byte[buffer.capacity()];
                    buffer.position(0);
                    if (!muted) buffer.get(pcm);
                    buffer.position(0);
                    callback.onWebRtcAudioTrackSamplesReady(new JavaAudioDeviceModule.AudioSamples(
                            AudioFormat.ENCODING_PCM_16BIT, channels, sampleRate, pcm));
                }
            } catch (RuntimeException failure) {
                if (errorCallback != null) errorCallback.onWebRtcAudioTrackError("External PCM playout failed");
            } finally {
                if (stateCallback != null) stateCallback.onWebRtcAudioTrackStop();
            }
        }, "AirSIM-WebRTC-playout");
        thread.start();
        return true;
    }

    @CalledByNative private boolean stopPlayout() {
        running = false;
        Thread stopping = thread;
        if (stopping != null) {
            stopping.interrupt();
            boolean interrupted = false;
            // Callback only enqueues; joining before disposal protects the native pointer.
            for (;;) {
                try { stopping.join(); break; }
                catch (InterruptedException ignored) { interrupted = true; }
            }
            if (interrupted) Thread.currentThread().interrupt();
        }
        thread = null;
        buffer = null;
        return true;
    }

    @CalledByNative private int getStreamMaxVolume() { return 1; }
    @CalledByNative private boolean setStreamVolume(int volume) { this.volume = volume; return true; }
    @CalledByNative private int getStreamVolume() { return volume; }
    @CalledByNative private int GetPlayoutUnderrunCount() { return 0; }
    @CalledByNative private int getBufferSizeInFrames() { return sampleRate / 100; }
    @CalledByNative private int getInitialBufferSizeInFrames() { return sampleRate / 100; }
    public void setSpeakerMute(boolean muted) { this.muted = muted; }
    private static native void nativeCacheDirectBufferAddress(long pointer, ByteBuffer buffer);
    private static native void nativeGetPlayoutData(long pointer, int bytes);
}
