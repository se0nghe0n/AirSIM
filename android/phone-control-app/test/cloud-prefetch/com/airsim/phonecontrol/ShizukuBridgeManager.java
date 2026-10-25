package com.airsim.phonecontrol;

import android.content.Context;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.atomic.AtomicInteger;
import org.json.JSONObject;

final class ShizukuBridgeManager {
    static ShizukuBridgeManager current;
    final AtomicInteger starts = new AtomicInteger();
    final CountDownLatch started = new CountDownLatch(1);
    final CountDownLatch activated = new CountDownLatch(1);
    final AtomicInteger activations = new AtomicInteger();
    volatile boolean carrierDeferred;
    static ShizukuBridgeManager get(Context context) { return current; }
    boolean mediaAvailable() { return true; }
    String mediaRequest(String encoded) throws Exception {
        JSONObject request = new JSONObject(encoded);
        if ("start".equals(request.getString("action"))) {
            carrierDeferred = request.optBoolean("defer_carrier_audio");
            starts.incrementAndGet();
            started.countDown();
        } else if ("activate_audio".equals(request.getString("action"))) {
            activations.incrementAndGet();
            activated.countDown();
        }
        return new JSONObject().put("version", 2).put("request_id", request.getLong("request_id"))
                .put("ok", true).put("active", true).toString();
    }
}
