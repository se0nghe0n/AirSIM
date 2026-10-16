package com.airsim.phonecontrol;

import android.content.Context;
import android.os.Looper;
import android.os.Process;
import android.util.Base64;
import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.nio.charset.StandardCharsets;

/** Pipe-only RPC entry point. No network listener or app-wide/root configuration changes. */
public final class PrivilegedBridgeProcess {
    private PrivilegedBridgeProcess() {}

    public static void main(String[] args) {
        ShizukuBridgeUserService service = null;
        try {
            if (args.length != 1 || !PrivilegedBridgeProtocol.supportsUid(Process.myUid())) {
                throw new SecurityException("invalid process bridge identity");
            }
            Looper.prepareMainLooper();
            Class<?> at = Class.forName("android.app.ActivityThread");
            Object thread = at.getMethod("systemMain").invoke(null);
            Context system = (Context) at.getMethod("getSystemContext").invoke(thread);
            Context context = system.createPackageContext(args[0], 0);
            service = new ShizukuBridgeUserService(context);
            ShizukuBridgeUserService active = service;
            Runtime.getRuntime().addShutdownHook(new Thread(active::closeBridge));
            emit("READY");
            try (BufferedReader input = new BufferedReader(new InputStreamReader(System.in, StandardCharsets.UTF_8))) {
                String line;
                while ((line = input.readLine()) != null && !"quit".equals(line)) {
                    try {
                        if (!line.matches("[1-4] [01]")) throw new IllegalArgumentException("invalid command");
                        String result = service.executeCommand(line.charAt(0) - '0', line.charAt(2) == '1');
                        emit("OK  " + encode(result));
                    } catch (Exception error) {
                        emit("ERR " + encode(error.getClass().getSimpleName() + ": " + error.getMessage()));
                    }
                }
            }
        } catch (Throwable error) {
            emit("ERR " + encode(error.getClass().getSimpleName()));
        } finally {
            if (service != null) service.closeBridge();
        }
        System.exit(0);
    }

    private static String encode(String value) {
        return Base64.encodeToString(value.getBytes(StandardCharsets.UTF_8), Base64.NO_WRAP);
    }

    private static void emit(String value) {
        System.out.println(PrivilegedProcessTransport.PREFIX + value);
        System.out.flush();
    }
}
