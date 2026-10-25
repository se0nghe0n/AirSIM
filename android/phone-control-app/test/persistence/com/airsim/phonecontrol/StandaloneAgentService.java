package com.airsim.phonecontrol;

import android.content.Context;

/** Only the Android service-launch boundary is replaced in persistent-store tests. */
public final class StandaloneAgentService {
    static int starts;
    public static void start(Context context) { starts++; }
}
