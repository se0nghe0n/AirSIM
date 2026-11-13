package com.airsim.phonecontrol;

import android.media.AudioAttributes;
import android.media.AudioDeviceInfo;
import android.media.AudioFormat;
import android.media.AudioManager;
import android.media.AudioProfile;
import android.media.AudioRecord;
import android.media.AudioTrack;
import android.os.Process;
import android.os.Build;
import java.io.Closeable;
import java.io.IOException;
import java.lang.reflect.Method;
import java.util.Arrays;
import java.util.ArrayList;
import java.util.List;
import org.webrtc.audio.PcmFormat;
import java.util.concurrent.atomic.AtomicBoolean;

/** Privileged, in-process carrier device. Never opens a microphone/speaker or an audio socket. */
final class TelephonyAudioDevice implements Closeable {
    private final PcmFormat format;
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
    private volatile String failureReason = "carrier_media_unavailable";
    private volatile boolean unpublishedReleaseFailed;
    private boolean failing; // Guarded by this.
    private final CloudAudioSetupTimeline setup = new CloudAudioSetupTimeline(
            CloudAudioSetupTimeline.Scope.CARRIER, System::nanoTime, BridgeLog::info);

    TelephonyAudioDevice(WebRTCPcmBuffer capture, WebRTCPcmBuffer playback, Runnable ready, Runnable failed) {
        this.capture = capture; this.playback = playback; this.ready = ready; this.failed = failed;
        this.format = capture.format();
        if (playback.format() != format) throw new IllegalArgumentException("carrier PCM format mismatch");
    }

    synchronized void start() {
        if (closed.get()) return;
        // Close must never join an assigned but not-yet-started worker and then reuse its resources.
        worker = new Thread(this::run, "airsim-carrier-device");
        worker.start();
    }

    private void run() {
        audioPriority();
        byte[] frame = new byte[format.frameBytes()];
        try {
            if (!PrivilegedBridgeProtocol.supportsUid(Process.myUid())) throw new SecurityException("privilege required");
            int recordBytes = AudioRecord.getMinBufferSize(format.rate(), AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT);
            int trackBytes = AudioTrack.getMinBufferSize(format.rate(), AudioFormat.CHANNEL_OUT_MONO, AudioFormat.ENCODING_PCM_16BIT);
            if (recordBytes == AudioRecord.ERROR_BAD_VALUE || trackBytes == AudioTrack.ERROR_BAD_VALUE)
                throw new IOException("carrier format init failed");
            if (recordBytes <= 0 || trackBytes <= 0) throw new IOException("device format unavailable");
            AudioAttributes.Builder attributes = new AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION).setContentType(AudioAttributes.CONTENT_TYPE_SPEECH);
            boolean vendorRoute = addVoiceTxTag(attributes);
            AudioDeviceInfo sink = findTelephonyDevice(false, format);
            AudioDeviceInfo captureSource = format == PcmFormat.WIDEBAND ? findTelephonyDevice(true, format) : null;
            if ((!vendorRoute && sink == null)
                    || (format == PcmFormat.WIDEBAND && (sink == null || captureSource == null)))
                throw new IOException("carrier route unavailable");
            AudioRecord input;
            try {
                input = new AudioRecord(SOURCE_VOICE_DOWNLINK, format.rate(), AudioFormat.CHANNEL_IN_MONO,
                        AudioFormat.ENCODING_PCM_16BIT, Math.max(recordBytes, format.bufferBytes(80)));
            } catch (IllegalArgumentException unsupported) { throw new IOException("carrier format init failed"); }
            synchronized (this) {
                if (closed.get()) {
                    try { input.release(); }
                    catch (RuntimeException | LinkageError error) { unpublishedReleaseFailed = true; }
                    return;
                }
                recorder = input;
            }
            AudioTrack output;
            try {
                output = new AudioTrack.Builder().setAudioAttributes(attributes.build())
                        .setAudioFormat(new AudioFormat.Builder().setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                                .setSampleRate(format.rate()).setChannelMask(AudioFormat.CHANNEL_OUT_MONO).build())
                        .setBufferSizeInBytes(Math.max(trackBytes, format.bufferBytes(80)))
                        .setTransferMode(AudioTrack.MODE_STREAM).build();
            } catch (IllegalArgumentException unsupported) { throw new IOException("carrier format init failed"); }
            synchronized (this) {
                if (closed.get()) {
                    try { output.release(); }
                    catch (RuntimeException | LinkageError error) { unpublishedReleaseFailed = true; }
                    return;
                }
                track = output;
            }
            synchronized (this) {
                // Close must not stop a published device only for this worker to start it afterward.
                if (closed.get()) return;
                if (input.getState() != AudioRecord.STATE_INITIALIZED || output.getState() != AudioTrack.STATE_INITIALIZED)
                    throw new IOException("carrier device initialization failed");
                if (input.getSampleRate() != format.rate() || output.getSampleRate() != format.rate()
                        || input.getAudioFormat() != AudioFormat.ENCODING_PCM_16BIT
                        || output.getAudioFormat() != AudioFormat.ENCODING_PCM_16BIT
                        || input.getChannelCount() != 1 || output.getChannelCount() != 1)
                    throw new IOException("carrier format init failed");
                if (sink != null && !output.setPreferredDevice(sink)) throw new IOException("carrier route rejected");
                if (captureSource != null && !input.setPreferredDevice(captureSource)) throw new IOException("carrier route rejected");
                BridgeLog.info("standalone_carrier_pcm_format selected_rate_hz=" + format.rate()
                        + " capture_api_rate_hz=" + input.getSampleRate() + " playback_api_rate_hz=" + output.getSampleRate()
                        + " channels=1 frame_bytes=" + format.frameBytes());
                input.startRecording(); output.play();
            }
            if (input.getRecordingState() != AudioRecord.RECORDSTATE_RECORDING) throw new IOException("carrier capture unavailable");
            // Zero samples prime the output route, not a synthesized caller or fallback speaker.
            // A vendor tag alone is NOT evidence of a working route. Hidden OEM routes remain
            // unavailable until their native verification mechanism is implemented and device-tested.
            CarrierStartup startup = new CarrierStartup(closed::get, System::nanoTime,
                    nanos -> java.util.concurrent.TimeUnit.NANOSECONDS.sleep(nanos));
            if (!startup.verifyRoute(frame,
                    (bytes, offset, length) -> output.write(bytes, offset, length, AudioTrack.WRITE_NON_BLOCKING),
                    () -> {
                        AudioDeviceInfo routed = output.getRoutedDevice();
                        AudioDeviceInfo captured = captureSource == null ? null : input.getRoutedDevice();
                        return routed != null && routed.getType() == AudioDeviceInfo.TYPE_TELEPHONY && routed.isSink()
                                && (captureSource == null || (captured != null
                                && captured.getType() == AudioDeviceInfo.TYPE_TELEPHONY && captured.isSource()));
                    })) return;
            setup.mark(CloudAudioSetupTimeline.Phase.ROUTE_VERIFIED);
            // Fill the carrier buffer with silence so the carrier clock paces NetEq from the first
            // frame instead of decoding a burst faster than real time.
            for (int i = 0; i < 64; i++) {
                if (output.write(frame, 0, frame.length, AudioTrack.WRITE_NON_BLOCKING) < frame.length) break;
            }
            // From here the track is never left without data: the uplink writes silence until
            // WebRTC playout delivers frames, however long capture and negotiation take.
            uplink = new Thread(() -> play(output), "airsim-carrier-uplink");
            uplink.start();
            // Discard capture queued during route verification; only live audio starts the stream.
            for (int i = 0; i < 64; i++) {
                if (input.read(frame, 0, frame.length, AudioRecord.READ_NON_BLOCKING) < frame.length) break;
            }
            if (!startup.firstCapture(frame,
                    (bytes, offset, length) -> input.read(bytes, offset, length, AudioRecord.READ_NON_BLOCKING))) return;
            if (input.getAudioSource() != SOURCE_VOICE_DOWNLINK) throw new IOException("carrier capture failed");
            setup.mark(CloudAudioSetupTimeline.Phase.FIRST_CAPTURE);
            capture.offer(frame, 0, frame.length);
            synchronized (this) {
                // The uplink is already running. A device it has failed must not report ready
                // afterwards, or the peer would treat an unverified retry as a verified route.
                if (closed.get() || failing) return;
                ready.run();
            }
            while (!closed.get()) {
                int count = input.read(frame, 0, frame.length, AudioRecord.READ_BLOCKING);
                if (count < 0 || count > frame.length || (count & 1) != 0) throw new IOException("carrier capture stopped");
                if (captureSource != null) {
                    AudioDeviceInfo captured = input.getRoutedDevice();
                    if (captured == null || captured.getType() != AudioDeviceInfo.TYPE_TELEPHONY || !captured.isSource())
                        throw new IOException("carrier route lost");
                }
                if (count > 0) capture.offer(frame, 0, count);
            }
        } catch (Exception | LinkageError error) {
            if (!closed.get()) fail(error); // Never log SDK/native or private audio data.
        } finally {
            Arrays.fill(frame, (byte) 0);
            // The peer's signaling executor owns disposal, including joining this worker.
            // Do not win a close CAS here and let the owner's close return before release.
        }
    }

    private void play(AudioTrack output) {
        audioPriority();
        CarrierUplink.Sink sink = new CarrierUplink.Sink() {
            @Override public int routedType() {
                AudioDeviceInfo route = output.getRoutedDevice();
                return route == null ? CarrierUplink.ROUTE_NONE : route.getType();
            }
            @Override public int write(byte[] frame, int offset, int length) {
                return output.write(frame, offset, length, AudioTrack.WRITE_BLOCKING);
            }
            @Override public int writeNow(byte[] frame, int offset, int length) {
                return output.write(frame, offset, length, AudioTrack.WRITE_NON_BLOCKING);
            }
        };
        // The route check, the silence that keeps the track active and their limits are in CarrierUplink.
        try {
            new CarrierUplink(playback, sink, AudioDeviceInfo.TYPE_TELEPHONY, closed::get,
                    System::nanoTime, BridgeLog::info).run();
        } catch (Exception | LinkageError error) { if (!closed.get()) fail(error); }
    }

    /** These threads clock WebRTC capture and playout, so they run at the SDK's audio priority. */
    private static void audioPriority() {
        try { Process.setThreadPriority(Process.THREAD_PRIORITY_URGENT_AUDIO); }
        catch (RuntimeException ignored) { /* Best effort; the queues still absorb scheduling delay. */ }
    }

    /** Stable, non-sensitive code for the most recent carrier failure. */
    String failureReason() { return failureReason; }

    /** Underruns the platform counted on the carrier AudioTrack, or -1 when unavailable. */
    int playbackUnderruns() {
        AudioTrack output = track;
        if (output == null) return -1;
        try { return output.getUnderrunCount(); }
        catch (RuntimeException | LinkageError error) { return -1; }
    }

    private void fail(Throwable error) {
        synchronized (this) { failing = true; failureReason = reason(error); }
        failed.run();
    }

    // Our own IOException messages are fixed phrases. Other errors expose only their type.
    static String reason(Throwable error) {
        String value = error instanceof IOException && error.getMessage() != null
                ? error.getMessage() : error instanceof SecurityException
                ? "carrier permission denied" : "carrier " + error.getClass().getSimpleName();
        value = value.toLowerCase(java.util.Locale.ROOT).replaceAll("[^a-z0-9]+", "_");
        return value.length() > 48 ? value.substring(0, 48) : value;
    }

    private static boolean addVoiceTxTag(AudioAttributes.Builder builder) {
        try {
            builder.getClass().getMethod("semAddAudioTag", String.class).invoke(builder, "VOICE_TX");
            return true;
        } catch (ReflectiveOperationException | RuntimeException error) { return false; }
    }

    /** Profiles are inspected without opening an AudioRecord, AudioTrack or audio route. */
    static PcmFormat preferredFormat() {
        if (Build.VERSION.SDK_INT < 31) return PcmFormat.NARROWBAND;
        try {
            List<CarrierAudioFormatPolicy.Endpoint> profiles = new ArrayList<>();
            for (AudioDeviceInfo device : telephonyDevices()) profiles.addAll(profiles(device));
            return CarrierAudioFormatPolicy.select(profiles.toArray(new CarrierAudioFormatPolicy.Endpoint[0]));
        } catch (ReflectiveOperationException | RuntimeException | LinkageError error) {
            return PcmFormat.NARROWBAND; // Unknown capabilities cannot authorize a wider format.
        }
    }

    private static AudioDeviceInfo[] telephonyDevices() throws ReflectiveOperationException {
        Method get = AudioManager.class.getMethod("getDevicesStatic", int.class);
        AudioDeviceInfo[] devices = (AudioDeviceInfo[]) get.invoke(null, AudioManager.GET_DEVICES_ALL);
        return devices == null ? new AudioDeviceInfo[0] : devices;
    }

    private static List<CarrierAudioFormatPolicy.Endpoint> profiles(AudioDeviceInfo device) {
        List<CarrierAudioFormatPolicy.Endpoint> result = new ArrayList<>();
        if (Build.VERSION.SDK_INT < 31 || device.getType() != AudioDeviceInfo.TYPE_TELEPHONY) return result;
        // Never combine AudioDeviceInfo's union of formats/rates/masks across different profiles.
        for (AudioProfile profile : device.getAudioProfiles()) {
            boolean mono = false;
            for (int mask : profile.getChannelMasks()) {
                mono |= (device.isSource() && mask == AudioFormat.CHANNEL_IN_MONO)
                        || (device.isSink() && mask == AudioFormat.CHANNEL_OUT_MONO);
            }
            for (int mask : profile.getChannelIndexMasks()) mono |= mask == 1;
            result.add(new CarrierAudioFormatPolicy.Endpoint(true, device.isSource(), device.isSink(),
                    new int[]{profile.getFormat()}, profile.getSampleRates(), mono ? new int[]{1} : new int[0]));
        }
        return result;
    }

    private static AudioDeviceInfo findTelephonyDevice(boolean source, PcmFormat format) {
        try {
            for (AudioDeviceInfo device : telephonyDevices()) {
                if (device.getType() != AudioDeviceInfo.TYPE_TELEPHONY
                        || (source ? !device.isSource() : !device.isSink())) continue;
                if (format == PcmFormat.NARROWBAND) return device;
                for (CarrierAudioFormatPolicy.Endpoint profile : profiles(device))
                    if (CarrierAudioFormatPolicy.supportsWideband(profile)) return device;
            }
        } catch (ReflectiveOperationException | RuntimeException | LinkageError error) { /* Fail closed below. */ }
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
        boolean released = captureStopped && playbackStopped && !unpublishedReleaseFailed;
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
