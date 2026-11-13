package com.airsim.phonecontrol;

import android.content.Context;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ConcurrentLinkedQueue;
import java.util.concurrent.atomic.AtomicInteger;
import org.json.JSONObject;

final class ShizukuBridgeManager {
    static ShizukuBridgeManager current;
    final AtomicInteger starts = new AtomicInteger();
    final CountDownLatch started = new CountDownLatch(1);
    final CountDownLatch activated = new CountDownLatch(1);
    final AtomicInteger activations = new AtomicInteger();
    volatile boolean carrierDeferred;
    volatile String failureReason;
    final ConcurrentLinkedQueue<JSONObject> events = new ConcurrentLinkedQueue<>();
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
        JSONObject response = new JSONObject().put("version", 2).put("request_id", request.getLong("request_id"))
                .put("ok", true).put("active", true);
        if ("poll".equals(request.getString("action"))) {
            JSONObject event = events.poll();
            if (event != null) response.put("event", event);
            else if (failureReason != null) response.put("event", new JSONObject().put("status", "webrtc_failed").put("reason", failureReason));
        }
        return response.toString();
    }
}
