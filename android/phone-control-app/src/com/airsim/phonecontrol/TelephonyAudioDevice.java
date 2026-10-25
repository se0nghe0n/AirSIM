package com.airsim.phonecontrol;

import android.media.AudioAttributes;
import android.media.AudioDeviceInfo;
import android.media.AudioFormat;
import android.media.AudioManager;
import android.media.AudioRecord;
import android.media.AudioTrack;
import android.os.Process;
import java.io.Closeable;
import java.io.IOException;
import java.lang.reflect.Method;
import java.util.Arrays;
import java.util.concurrent.atomic.AtomicBoolean;

/** Privileged, in-process carrier device. Never opens a microphone/speaker or an audio socket. */
final class TelephonyAudioDevice implements Closeable {
    private static final int RATE = 8000;
    private static final int SOURCE_VOICE_DOWNLINK = 3;
    private final WebRTCPcmBuffer capture;
    private final WebRTCPcmBuffer playback;
    private final Runnable ready;
    private final Runnable failed;
    private final AtomicBoolean closed = new AtomicBoolean();
    private volatile AudioRecord recorder;
    private volatile AudioTrack track;
    private volatile Thread worker;
    private volatile Thread uplink;

    TelephonyAudioDevice(WebRTCPcmBuffer capture, WebRTCPcmBuffer playback, Runnable ready, Runnable failed) {
        this.capture = capture; this.playback = playback; this.ready = ready; this.failed = failed;
    }

    void start() {
        worker = new Thread(this::run, "airsim-carrier-device");
        worker.start();
    }

    private void run() {
        byte[] frame = new byte[WebRTCPcmBuffer.FRAME_BYTES];
        try {
            if (!PrivilegedBridgeProtocol.supportsUid(Process.myUid())) throw new SecurityException("privilege required");
            int recordBytes = AudioRecord.getMinBufferSize(RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT);
            int trackBytes = AudioTrack.getMinBufferSize(RATE, AudioFormat.CHANNEL_OUT_MONO, AudioFormat.ENCODING_PCM_16BIT);
            if (recordBytes <= 0 || trackBytes <= 0) throw new IOException("device format unavailable");
            AudioAttributes.Builder attributes = new AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION).setContentType(AudioAttributes.CONTENT_TYPE_SPEECH);
            boolean vendorRoute = addVoiceTxTag(attributes);
            AudioDeviceInfo sink = findTelephonySink();
            if (!vendorRoute && sink == null) throw new IOException("carrier route unavailable");
            AudioRecord input = new AudioRecord(SOURCE_VOICE_DOWNLINK, RATE, AudioFormat.CHANNEL_IN_MONO,
                    AudioFormat.ENCODING_PCM_16BIT, Math.max(recordBytes, 1280));
            synchronized (this) {
                if (closed.get()) { input.release(); return; }
                recorder = input;
            }
            AudioTrack output = new AudioTrack.Builder().setAudioAttributes(attributes.build())
                    .setAudioFormat(new AudioFormat.Builder().setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                            .setSampleRate(RATE).setChannelMask(AudioFormat.CHANNEL_OUT_MONO).build())
                    .setBufferSizeInBytes(Math.max(trackBytes, 1280)).setTransferMode(AudioTrack.MODE_STREAM).build();
            synchronized (this) {
                if (closed.get()) { output.release(); return; }
                track = output;
            }
            synchronized (this) {
                // Close must not stop a published device only for this worker to start it afterward.
                if (closed.get()) return;
                if (input.getState() != AudioRecord.STATE_INITIALIZED || output.getState() != AudioTrack.STATE_INITIALIZED)
                    throw new IOException("carrier device initialization failed");
                if (sink != null && !output.setPreferredDevice(sink)) throw new IOException("carrier route rejected");
                input.startRecording(); output.play();
            }
            if (input.getRecordingState() != AudioRecord.RECORDSTATE_RECORDING) throw new IOException("carrier capture unavailable");
            // Zero samples prime the output route, not a synthesized caller or fallback speaker.
            // A vendor tag alone is NOT evidence of a working route. Hidden OEM routes remain
            // unavailable until their native verification mechanism is implemented and device-tested.
            long deadline = System.nanoTime() + 2_000_000_000L;
            while (!closed.get()) {
                write(output, frame);
                AudioDeviceInfo routed = output.getRoutedDevice();
                if (routed != null && routed.getType() == AudioDeviceInfo.TYPE_TELEPHONY && routed.isSink()) break;
                if (System.nanoTime() >= deadline) throw new IOException("carrier route unverified");
                Thread.sleep(10);
            }
            if (closed.get()) return;
            int count = input.read(frame, 0, frame.length, AudioRecord.READ_BLOCKING);
            if (count <= 0 || input.getAudioSource() != SOURCE_VOICE_DOWNLINK) throw new IOException("carrier capture failed");
            capture.offer(frame, 0, count & ~1);
            ready.run();
            uplink = new Thread(() -> play(output), "airsim-carrier-uplink");
            uplink.start();
            while (!closed.get()) {
                count = input.read(frame, 0, frame.length, AudioRecord.READ_BLOCKING);
                if (count < 0) throw new IOException("carrier capture stopped");
                if (count > 0) capture.offer(frame, 0, count & ~1);
            }
        } catch (Exception | LinkageError error) {
            if (!closed.get()) failed.run(); // Never log SDK/native or private audio data.
        } finally {
            Arrays.fill(frame, (byte) 0);
            // The peer's signaling executor owns disposal, including joining this worker.
            // Do not win a close CAS here and let the owner's close return before release.
        }
    }

    private void play(AudioTrack output) {
        try {
            while (!closed.get()) {
                byte[] frame = playback.take();
                if (frame == null) return;
                AudioDeviceInfo route = output.getRoutedDevice();
                if (route == null || route.getType() != AudioDeviceInfo.TYPE_TELEPHONY)
                    throw new IOException("carrier route lost");
                try { write(output, frame); } finally { Arrays.fill(frame, (byte) 0); }
            }
        } catch (Exception | LinkageError error) { if (!closed.get()) failed.run(); }
    }

    private void write(AudioTrack output, byte[] frame) throws IOException {
        int offset = 0;
        while (!closed.get() && offset < frame.length) {
            int count = output.write(frame, offset, frame.length - offset, AudioTrack.WRITE_BLOCKING);
            if (count <= 0) throw new IOException("carrier playback stopped");
            offset += count;
        }
    }

    private static boolean addVoiceTxTag(AudioAttributes.Builder builder) {
        try {
            builder.getClass().getMethod("semAddAudioTag", String.class).invoke(builder, "VOICE_TX");
            return true;
        } catch (ReflectiveOperationException | RuntimeException error) { return false; }
    }

    private static AudioDeviceInfo findTelephonySink() {
        try {
            Method get = AudioManager.class.getMethod("getDevicesStatic", int.class);
            AudioDeviceInfo[] devices = (AudioDeviceInfo[]) get.invoke(null, AudioManager.GET_DEVICES_OUTPUTS);
            if (devices != null) for (AudioDeviceInfo device : devices)
                if (device.isSink() && device.getType() == AudioDeviceInfo.TYPE_TELEPHONY) return device;
        } catch (ReflectiveOperationException | RuntimeException error) { /* Fail closed below. */ }
        return null;
    }

    @Override public void close() {
        if (!closed.compareAndSet(false, true)) return;
        capture.close(); playback.close();
        AudioRecord input; AudioTrack output;
        synchronized (this) { input = recorder; recorder = null; output = track; track = null; }
        // Stop first to unblock device-clock reads/writes; join before releasing their objects.
        if (input != null) try { input.stop(); } catch (RuntimeException | LinkageError ignored) {}
        if (output != null) {
            try { output.pause(); } catch (RuntimeException | LinkageError ignored) {}
            try { output.flush(); } catch (RuntimeException | LinkageError ignored) {}
            try { output.stop(); } catch (RuntimeException | LinkageError ignored) {}
        }
        boolean captureStopped = join(worker);
        boolean playbackStopped = join(uplink);
        boolean released = captureStopped && playbackStopped;
        // A timed-out worker may still use its native handles. Quarantine, never release under it.
        try { if (captureStopped && input != null) input.release(); }
        catch (RuntimeException | LinkageError error) { released = false; }
        try { if (captureStopped && playbackStopped && output != null) output.release(); }
        catch (RuntimeException | LinkageError error) { released = false; }
        if (!released) throw new IllegalStateException("carrier_cleanup_failed");
    }

    private static boolean join(Thread thread) {
        if (thread == null) return true;
        if (thread == Thread.currentThread()) return false;
        thread.interrupt();
        try { thread.join(2000); }
        catch (InterruptedException error) { Thread.currentThread().interrupt(); return false; }
        return !thread.isAlive();
    }
}
