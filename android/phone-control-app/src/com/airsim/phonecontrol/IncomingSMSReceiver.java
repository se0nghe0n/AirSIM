package com.airsim.phonecontrol;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.provider.Telephony;
import android.telephony.SmsMessage;

import org.json.JSONObject;

import java.time.Instant;
import java.util.UUID;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/** Receives carrier SMS without requiring the default-SMS-app role. */
public final class IncomingSMSReceiver extends BroadcastReceiver {
    private static final ExecutorService WORKER = Executors.newSingleThreadExecutor();

    @Override public void onReceive(Context context, Intent intent) {
        if (!Telephony.Sms.Intents.SMS_RECEIVED_ACTION.equals(intent.getAction())) return;
        PendingResult pending = goAsync();
        Context application = context.getApplicationContext();
        WORKER.execute(() -> {
            try {
                SmsMessage[] parts = Telephony.Sms.Intents.getMessagesFromIntent(intent);
                if (parts == null || parts.length == 0) return;
                StringBuilder content = new StringBuilder();
                String sender = parts[0].getOriginatingAddress();
                long timestamp = parts[0].getTimestampMillis();
                for (SmsMessage part : parts) {
                    if (part == null) continue;
                    content.append(part.getMessageBody() == null ? "" : part.getMessageBody());
                }
                if (content.length() == 0) return;
                long eventTimestamp = timestamp > 0 ? timestamp : System.currentTimeMillis();
                String id = SMSDeliveryIdentity.id(sender, content.toString(), eventTimestamp);
                JSONObject event = new JSONObject(WireJson.smsEvent(UUID.randomUUID().toString(),
                        id, sender == null ? "" : sender, content.toString(),
                        Instant.ofEpochMilli(eventTimestamp).toString()));
                StandaloneAgentGateway.get(application).sendSMSEvent(event.toString());
                BridgeLog.info("incoming_sms_queued delivery_id=" + DebugRedactor.safeIdentifier(id));
            } catch (Exception error) {
                BridgeLog.error("incoming_sms_queue_failed", error);
            } finally {
                pending.finish();
            }
        });
    }
}
