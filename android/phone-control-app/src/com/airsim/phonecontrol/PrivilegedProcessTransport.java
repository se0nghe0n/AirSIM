package com.airsim.phonecontrol;

import android.content.Context;
import android.os.ParcelFileDescriptor;
import android.util.Base64;
import java.io.BufferedReader;
import java.io.BufferedWriter;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.io.OutputStreamWriter;
import java.nio.charset.StandardCharsets;
import java.util.concurrent.ArrayBlockingQueue;
import java.util.concurrent.TimeUnit;
import java.util.ArrayList;
import java.util.List;
import moe.shizuku.server.IRemoteProcess;
import moe.shizuku.server.IShizukuService;
import rikka.shizuku.Shizuku;

/** App-local fallback for ROMs whose LoadedApk.makeApplication breaks UserService startup. */
final class PrivilegedProcessTransport {
    static final String PREFIX = "AIRSIM_MEDIA_RPC ";
    private final IRemoteProcess remote;
    private final BufferedWriter commands;
    private final ArrayBlockingQueue<String> responses = new ArrayBlockingQueue<>(16);
    private volatile boolean closed;
    private volatile String processError = "";

    private PrivilegedProcessTransport(IRemoteProcess remote) throws Exception {
        this.remote = remote;
        commands = new BufferedWriter(new OutputStreamWriter(
                new ParcelFileDescriptor.AutoCloseOutputStream(remote.getOutputStream()), StandardCharsets.UTF_8));
        readStream(new ParcelFileDescriptor.AutoCloseInputStream(remote.getInputStream()), true);
        readStream(new ParcelFileDescriptor.AutoCloseInputStream(remote.getErrorStream()), false);
        if (!"READY".equals(awaitResponse())) throw new IllegalStateException("process bridge startup failed");
    }

    static PrivilegedProcessTransport open(Context context) throws Exception {
        if (!Shizuku.pingBinder() || Shizuku.checkSelfPermission()
                != android.content.pm.PackageManager.PERMISSION_GRANTED) {
            throw new SecurityException("Shizuku permission is required");
        }
        List<String> environment = new ArrayList<>();
        // Pass only Android's runtime path variables: the Shizuku server may log this array.
        for (String key : new String[]{"PATH", "ANDROID_DATA", "ANDROID_ROOT", "ANDROID_ART_ROOT",
                "ANDROID_I18N_ROOT", "ANDROID_TZDATA_ROOT", "BOOTCLASSPATH", "DEX2OATBOOTCLASSPATH"}) {
            String value = System.getenv(key);
            if (value != null) environment.add(key + "=" + value);
        }
        environment.add("CLASSPATH=" + context.getApplicationInfo().sourceDir);
        IRemoteProcess child = IShizukuService.Stub.asInterface(Shizuku.getBinder()).newProcess(
                new String[]{"/system/bin/app_process", "/system/bin",
                        PrivilegedBridgeProcess.class.getName(), context.getPackageName()},
                environment.toArray(new String[0]),
                "/");
        try { return new PrivilegedProcessTransport(child); }
        catch (Exception error) { child.destroy(); throw error; }
    }

    private void readStream(InputStream stream, boolean protocol) {
        Thread reader = new Thread(() -> {
            try (BufferedReader lines = new BufferedReader(new InputStreamReader(stream, StandardCharsets.UTF_8))) {
                String line;
                while ((line = PrivilegedMediaProtocol.readLine(lines)) != null) {
                    if (protocol && line.startsWith(PREFIX)) {
                        if (!responses.offer(line.substring(PREFIX.length()))) {
                            responses.clear(); responses.offer("EOF"); return;
                        }
                    } else if (!protocol) {
                        processError = "privileged runtime diagnostics suppressed";
                    }
                }
            } catch (Exception ignored) {
                // EOF is surfaced to the next bounded request; do not print privileged process output.
            } finally {
                if (protocol) responses.offer("EOF");
            }
        }, protocol ? "airsim-pixel-rpc" : "airsim-pixel-stderr");
        reader.setDaemon(true);
        reader.start();
    }

    private String awaitResponse() throws Exception {
        String result = responses.poll(10, TimeUnit.SECONDS);
        if (result == null || "EOF".equals(result)) {
            throw new IllegalStateException((result == null ? "bridge response timeout" : "bridge process exited")
                    + (processError.isEmpty() ? "" : ": " + processError));
        }
        return result;
    }

    boolean isAlive() {
        try { return !closed && remote.alive(); } catch (Exception error) { return false; }
    }

    synchronized String request(int code, boolean value) throws Exception {
        if (closed || !remote.alive()) throw new IllegalStateException("bridge process not running");
        if (code < 1 || code > 4) throw new IllegalArgumentException("unknown bridge command");
        commands.write(code + " " + (value ? "1" : "0") + "\n");
        commands.flush();
        String line;
        try { line = awaitResponse(); }
        catch (Exception error) { close(); throw error; }
        if (line.startsWith("ERR ")) throw new IllegalStateException("privileged_operation_rejected");
        try {
            if (!line.startsWith("OK  ")) throw new IllegalStateException("invalid_bridge_response");
            return new String(Base64.decode(line.substring(4), Base64.NO_WRAP), StandardCharsets.UTF_8);
        } catch (Exception error) { close(); throw error; }
    }

    synchronized String mediaRequest(String payload) throws Exception {
        if (closed || !remote.alive()) throw new IllegalStateException("media_process_unavailable");
        commands.write("5 " + PrivilegedMediaProtocol.bounded(payload) + "\n");
        commands.flush();
        String response;
        try { response = awaitResponse(); }
        catch (Exception error) { close(); throw error; }
        // A rejected competing owner is not a dead transport. Keep the incumbent peer alive.
        if (response.startsWith("ERR ")) throw new IllegalStateException("media_request_rejected");
        try {
            if (!response.startsWith("DATA ")) throw new IllegalStateException("invalid_media_response");
            return PrivilegedMediaProtocol.bounded(response.substring(5));
        } catch (Exception error) { close(); throw error; }
    }

    synchronized void close() {
        if (closed) return;
        closed = true;
        try { commands.write("quit\n"); commands.flush(); } catch (Exception ignored) {}
        try { remote.destroy(); } catch (Exception ignored) {}
        try { commands.close(); } catch (Exception ignored) {}
    }
}
