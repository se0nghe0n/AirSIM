package com.airsim.phonecontrol;

import android.content.Context;
import java.io.File;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Comparator;

/** Runs the real BridgeLog/CrashReportStore, not the JVM suite's BridgeLog double. */
public final class DiagnosticFileTests {
    public static void main(String[] args) throws Exception {
        Path directory = Files.createTempDirectory("airsim-diagnostic-file-test");
        try {
            Context context = new Context() {
                @Override public File getFilesDir() { return directory.toFile(); }
            };
            BridgeLog.initialize(context);
            equal("No debug logs", BridgeLog.read());
            Files.write(directory.resolve("airsim-debug.previous.log"),
                    "Old log: Bluetooth\n".getBytes(StandardCharsets.UTF_8));
            Files.write(directory.resolve("airsim-debug.log"),
                    "New log: connected\n".getBytes(StandardCharsets.UTF_8));
            equal("Old log: Bluetooth\nNew log: connected\n", BridgeLog.read());
            CrashReportStore.write(directory.toFile(), "Exception: test\n");
            equal("Exception: test\n", CrashReportStore.read(directory.toFile()));
            BridgeLog.clear();
            equal("No debug logs", BridgeLog.read());
            equal("Exception: test\n", CrashReportStore.read(directory.toFile()));
        } finally {
            try (var paths = Files.walk(directory)) {
                for (Path path : paths.sorted(Comparator.reverseOrder()).toList()) Files.delete(path);
            }
        }
        System.out.println("Diagnostic UTF-8 file tests passed");
    }

    private static void equal(String expected, String actual) {
        if (!expected.equals(actual)) throw new AssertionError("expected=" + expected + " actual=" + actual);
    }
}
