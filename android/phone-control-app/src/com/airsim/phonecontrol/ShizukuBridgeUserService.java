package com.airsim.phonecontrol;

import android.content.Context;
import android.media.AudioManager;
import android.os.Binder;
import android.os.IBinder;
import android.os.Parcel;
import android.os.Process;
import android.os.RemoteException;
import android.util.Log;

import java.io.BufferedReader;
import java.io.File;
import java.io.IOException;
import java.io.InputStreamReader;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.TimeUnit;

public final class ShizukuBridgeUserService extends Binder {
    private static final String TAG = "AirSIMShizuku";
    private static final int DESTROY_TRANSACTION = 16777115;
    private static final int DESTROY_TRANSACTION_AIDL = 16777114;

    private final Object lock = new Object();
    private String sourceApk = "";
    private String packageName = "";
    private PrivilegedMediaService media;
    private boolean bridgeClosing;
    private IBinder ownerBinder;
    private Context serviceContext;
    private LocalOutputMuteController outputMute;
    private boolean desiredOutputMuted;

    public ShizukuBridgeUserService() {
        Log.i(TAG, "created without context uid=" + Process.myUid());
    }

    public ShizukuBridgeUserService(Context context) {
        serviceContext = context;
        sourceApk = context.getApplicationInfo().sourceDir;
        packageName = context.getPackageName();

        Log.i(TAG, "created uid=" + Process.myUid());
    }

    @Override protected boolean onTransact(int code, Parcel data, Parcel reply, int flags)
            throws RemoteException {
        if (code == IBinder.INTERFACE_TRANSACTION) {
            reply.writeString(PrivilegedBridgeProtocol.DESCRIPTOR);
            return true;
        }
        if (code == DESTROY_TRANSACTION || code == DESTROY_TRANSACTION_AIDL) {
            destroy();
            return true;
        }
        data.enforceInterface(PrivilegedBridgeProtocol.DESCRIPTOR);
        try {
            verifyCaller(data.readStrongBinder());
            String result = switch (code) {
                case PrivilegedBridgeProtocol.TRANSACTION_START_BRIDGE -> ensureBridgeStarted();
                case PrivilegedBridgeProtocol.TRANSACTION_MEDIA -> mediaRequest(data.readString());
                case PrivilegedBridgeProtocol.TRANSACTION_STATUS -> status();
                case PrivilegedBridgeProtocol.TRANSACTION_SET_LOCAL_OUTPUT_MUTED ->
                        setLocalOutputMuted(data.readInt() != 0);
                case PrivilegedBridgeProtocol.TRANSACTION_ENSURE_DIALER_ROLE -> ensureDialerRole();
                default -> null;
            };
            if (result == null) return super.onTransact(code, data, reply, flags);
            reply.writeNoException();
            reply.writeString(result);
            return true;
        } catch (Throwable error) {
            Log.w(TAG, "privileged transaction rejected code=" + code);
            reply.writeException(new IllegalStateException("privileged_operation_failed"));
            return true;
        }
    }

    private String ensureBridgeStarted() throws IOException {
        PrivilegedMediaService current;
        synchronized (lock) {
            verifyIdentity();
            if (bridgeClosing) throw new IOException("media_service_closing");
            if (serviceContext == null || sourceApk.isEmpty()) throw new IOException("application context unavailable");
            if (media == null) {
                stopStaleAudioBridges();
                media = new PrivilegedMediaService(serviceContext, () -> {
                    try { applyLocalOutputMuted(false); }
                    catch (Exception error) { throw new IllegalStateException("local_output_unavailable"); }
                }, () -> {
                    try { synchronized (lock) { applyLocalOutputMuted(desiredOutputMuted); } }
                    catch (Exception error) { throw new IllegalStateException("local_output_unavailable"); }
                });
            }
            current = media;
        }
        current.initialize();
        return status();
    }

    private void verifyCaller(IBinder token) throws RemoteException {
        if (serviceContext == null || Binder.getCallingUid() != serviceContext.getApplicationInfo().uid)
            throw new SecurityException("media caller is not the owning APK");
        if (token == null) throw new SecurityException("owner token required");
        synchronized (lock) {
            if (bridgeClosing) throw new IllegalStateException("media_service_closing");
            if (ownerBinder == null) {
                token.linkToDeath(this::closeBridge, 0);
                ownerBinder = token;
            } else if (!ownerBinder.equals(token)) throw new SecurityException("another owner already attached");
        }
    }

    String mediaRequest(String request) throws Exception {
        verifyIdentity();
        PrivilegedMediaService current;
        synchronized (lock) {
            if (bridgeClosing) throw new IllegalStateException("media_service_closing");
            current = media;
        }
        if (current == null) throw new IllegalStateException("media_service_unavailable");
        return current.request(request);
    }

    String executeCommand(int code, boolean value) throws Exception {
        verifyIdentity();
        return switch (code) {
            case PrivilegedBridgeProtocol.TRANSACTION_START_BRIDGE -> ensureBridgeStarted();
            case PrivilegedBridgeProtocol.TRANSACTION_STATUS -> status();
            case PrivilegedBridgeProtocol.TRANSACTION_SET_LOCAL_OUTPUT_MUTED -> setLocalOutputMuted(value);
            case PrivilegedBridgeProtocol.TRANSACTION_ENSURE_DIALER_ROLE -> ensureDialerRole();
            default -> throw new IllegalArgumentException("invalid command");
        };
    }

    private void stopStaleAudioBridges() throws IOException {
        List<Integer> stalePids = findStaleAudioBridgePids();
        for (int pid : stalePids) {
            Log.w(TAG, "stopping stale PCM bridge pid=" + pid);
            Process.killProcess(pid);
        }
        long deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(2);
        while (!stalePids.isEmpty() && System.nanoTime() < deadline) {
            stalePids.removeIf(pid -> !new File("/proc/" + pid).exists());
            if (!stalePids.isEmpty()) {
                try { Thread.sleep(50); }
                catch (InterruptedException interrupted) {
                    Thread.currentThread().interrupt();
                    throw new IOException("interrupted while stopping stale PCM bridge", interrupted);
                }
            }
        }
        if (!stalePids.isEmpty()) {
            throw new IOException("stale PCM bridge did not exit pid=" + stalePids.get(0));
        }
    }

    private List<Integer> findStaleAudioBridgePids() {
        List<Integer> result = new ArrayList<>();
        File[] entries = new File("/proc").listFiles();
        if (entries == null) return result;
        int ownerPid = Process.myPid();
        for (File entry : entries) {
            int candidatePid;
            try { candidatePid = Integer.parseInt(entry.getName()); }
            catch (NumberFormatException ignored) { continue; }
            try {
                String commandLine = new String(
                        Files.readAllBytes(new File(entry, "cmdline").toPath()),
                        StandardCharsets.UTF_8);
                String processEnvironment = new String(
                        Files.readAllBytes(new File(entry, "environ").toPath()),
                        StandardCharsets.UTF_8);
                if (PhoneAudioBridgeProcessPolicy.isStaleBridge(
                        candidatePid, ownerPid, commandLine, processEnvironment, packageName)) {
                    result.add(candidatePid);
                }
            } catch (IOException | SecurityException ignored) {
                // Android hides most unrelated /proc entries. Same-UID bridge processes remain readable.
            }
        }
        return result;
    }

    private String setLocalOutputMuted(boolean muted) throws Exception {
        synchronized (lock) {
            desiredOutputMuted = muted;
            return applyLocalOutputMuted(muted);
        }
    }

    private String applyLocalOutputMuted(boolean muted) throws Exception {
        synchronized (lock) {
            verifyIdentity();
            if (outputMute == null && !muted) return "local_output_unchanged";
            if (outputMute == null) outputMute = new LocalOutputMuteController(audioBackend());
            return outputMute.setMuted(muted);
        }
    }

    private LocalOutputMuteController.Backend audioBackend() throws Exception {
        Context context = serviceContext;
        if (context == null) {
            // Shizuku can instantiate a UserService without passing a Context.
            Class<?> activityThread = Class.forName("android.app.ActivityThread");
            Object thread = activityThread.getMethod("currentActivityThread").invoke(null);
            if (thread == null) thread = activityThread.getMethod("systemMain").invoke(null);
            context = (Context) activityThread.getMethod("getSystemContext").invoke(thread);
        }
        // Attribute public AudioManager operations to the actual shell UID, not the APK UID.
        Context shell = context.createPackageContext("com.android.shell", 0);
        AudioManager audio = shell.getSystemService(AudioManager.class);
        if (audio == null) throw new IOException("System call audio service unavailable");
        return new LocalOutputMuteController.Backend() {
            public boolean isMuted() { return audio.isStreamMute(AudioManager.STREAM_VOICE_CALL); }
            public int volume() { return audio.getStreamVolume(AudioManager.STREAM_VOICE_CALL); }
            public void setVolume(int volume) {
                audio.setStreamVolume(AudioManager.STREAM_VOICE_CALL, volume, 0);
            }
            public void setMuted(boolean muted) {
                audio.adjustStreamVolume(AudioManager.STREAM_VOICE_CALL,
                        muted ? AudioManager.ADJUST_MUTE : AudioManager.ADJUST_UNMUTE, 0);
            }
        };
    }

    private String ensureDialerRole() throws Exception {
        verifyIdentity();
        if (packageName.isEmpty()) throw new IOException("application package unavailable");
        String holders = runCommand(PrivilegedBridgeProtocol.dialerRoleQueryCommand());
        if (!PrivilegedBridgeProtocol.isDialerRoleHolder(holders, packageName)) {
            runCommand(PrivilegedBridgeProtocol.dialerRoleGrantCommand(packageName));
            holders = runCommand(PrivilegedBridgeProtocol.dialerRoleQueryCommand());
        }
        if (!PrivilegedBridgeProtocol.isDialerRoleHolder(holders, packageName)) {
            throw new IOException("dialer role was not applied by the system");
        }
        return "dialer_role=granted verified=true";
    }

    private String runCommand(String[] command) throws Exception {
        java.lang.Process process = new ProcessBuilder(command).redirectErrorStream(true).start();
        StringBuilder output = new StringBuilder();
        try (BufferedReader reader = new BufferedReader(new InputStreamReader(
                process.getInputStream(), StandardCharsets.UTF_8))) {
            String line;
            while ((line = reader.readLine()) != null) {
                if (output.length() > 0) output.append('\n');
                output.append(line);
            }
        }
        if (!process.waitFor(3, TimeUnit.SECONDS)) {
            process.destroyForcibly();
            throw new IOException("privileged command timed out");
        }
        if (process.exitValue() != 0) throw new IOException("privileged command failed: " + output);
        return output.toString();
    }

    private String status() {
        synchronized (lock) {
            return statusLocked();
        }
    }

    private String statusLocked() {
        return "uid=" + Process.myUid()
                + " media=" + (media != null && media.available() ? "ready" : "unavailable")
                + " local_output=" + (outputMute != null && outputMute.isVerifiedMuted() ? "muted" : "normal");
    }

    private void verifyIdentity() {
        if (!PrivilegedBridgeProtocol.supportsUid(Process.myUid())) {
            throw new SecurityException("Shizuku service is not shell/root uid");
        }
    }

    void closeBridge() {
        PrivilegedMediaService current;
        synchronized (lock) {
            if (bridgeClosing) return;
            bridgeClosing = true;
            current = media;
            ownerBinder = null;
        }
        if (current != null) {
            // Retain the closed service as a process-wide retirement barrier. A new Binder owner
            // cannot create another native peer while the old service is still disposing one.
            java.util.concurrent.CompletableFuture<Void> disposal = current.closeAsync();
            // destroy()/pipe EOF may exit the process immediately after this returns. Restore
            // global call output now as well as at completion, while the recreation gate is shut.
            try { setLocalOutputMuted(false); }
            catch (Throwable error) { Log.w(TAG, "restore output during destroy failed"); }
            disposal.whenComplete((unused, error) -> {
                synchronized (lock) {
                    if (media != current || error != null) return;
                    try { setLocalOutputMuted(false); }
                    catch (Throwable restoreError) { Log.w(TAG, "restore output during destroy failed"); return; }
                    media = null;
                    bridgeClosing = false;
                }
            });
        } else {
            synchronized (lock) {
                try { setLocalOutputMuted(false); bridgeClosing = false; }
                catch (Throwable error) { Log.w(TAG, "restore output during destroy failed"); }
            }
        }
    }

    public void destroy() {
        closeBridge();
        System.exit(0);
    }

    private static String safeMessage(Throwable error) {
        String message = error.getMessage();
        return error.getClass().getSimpleName() + (message == null ? "" : ": " + message);
    }
}
