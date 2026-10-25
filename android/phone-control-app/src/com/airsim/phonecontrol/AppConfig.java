package com.airsim.phonecontrol;

import android.content.Context;
import android.content.SharedPreferences;

/** UI preferences. Existing keys are retained across Standalone upgrades. */
public final class AppConfig {
    public static final String MODE_REMOTE_SILENT = "remote_silent";
    public static final String MODE_LOCAL_AND_PUSH = "local_and_push";
    private static final String FILE = "control";

    private AppConfig() {}

    public static String mode(Context context) {
        return preferences(context).getString("mode", MODE_REMOTE_SILENT);
    }

    public static boolean debugEnabled(Context context) {
        return preferences(context).getBoolean("debug_enabled", true);
    }

    public static void setDebugEnabled(Context context, boolean enabled) {
        preferences(context).edit().putBoolean("debug_enabled", enabled).apply();
    }

    public static void saveMode(Context context, String mode) {
        String normalized = MODE_LOCAL_AND_PUSH.equals(mode) ? MODE_LOCAL_AND_PUSH : MODE_REMOTE_SILENT;
        preferences(context).edit().putString("mode", normalized).apply();
        StandaloneAgentService.start(context);
    }

    private static SharedPreferences preferences(Context context) {
        return context.getSharedPreferences(FILE, Context.MODE_PRIVATE);
    }
}
