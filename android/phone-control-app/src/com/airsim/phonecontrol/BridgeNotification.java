package com.airsim.phonecontrol;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.content.Context;
import android.content.Intent;
import android.net.Uri;

public final class BridgeNotification {
    public static final String CHANNEL = "airsim_bridge_status";
    private static final String CALL_CHANNEL = "airsim_incoming_calls_v1";
    public static final int WATCHDOG_ID = 5071;
    public static final int RECOVERY_ID = 5074;
    private static final int CALL_ID = 5072;
    public static final int VOWLAN_ID = 5073;
    private BridgeNotification() {}

    public static void createChannel(Context context) {
        NotificationChannel channel = new NotificationChannel(CHANNEL, "AirSIM call bridge", NotificationManager.IMPORTANCE_LOW);
        channel.setSound(null, null);
        channel.enableVibration(false);
        context.getSystemService(NotificationManager.class).createNotificationChannel(channel);
    }

    private static void createCallChannel(Context context) {
        NotificationChannel channel = new NotificationChannel(
                CALL_CHANNEL, "AirSIM incoming call", NotificationManager.IMPORTANCE_HIGH);
        // The iPhone is the primary ringer in remote_silent mode. Android still
        // needs a visible, actionable call surface when the phone is locked.
        channel.setSound(null, null);
        channel.enableVibration(false);
        context.getSystemService(NotificationManager.class).createNotificationChannel(channel);
    }

    public static Notification status(Context context, String detail) {
        createChannel(context);
        PendingIntent open = PendingIntent.getActivity(context, 0, new Intent(context, MainActivity.class),
                PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
        return new Notification.Builder(context, CHANNEL)
                .setSmallIcon(android.R.drawable.stat_sys_phone_call)
                .setContentTitle("AirSIM call bridge")
                .setContentText(detail)
                .setContentIntent(open)
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .build();
    }

    public static Notification terminalRecovery(Context context, Intent terminal) {
        createChannel(context);
        PendingIntent open = PendingIntent.getActivity(context, RECOVERY_ID, terminal,
                PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
        return new Notification.Builder(context, CHANNEL)
                .setSmallIcon(android.R.drawable.stat_sys_phone_call)
                .setContentTitle("AirSIM needs to restore Linux VM")
                .setContentText("Tap to open Terminal and restore connection")
                .setContentIntent(open)
                .addAction(android.R.drawable.ic_menu_view, "Open Terminal", open)
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .build();
    }

    public static Notification vowlan(Context context, String detail) {
        createChannel(context);
        PendingIntent open = PendingIntent.getActivity(context, 2, new Intent(context, MainActivity.class),
                PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
        return new Notification.Builder(context, CHANNEL)
                .setSmallIcon(android.R.drawable.stat_sys_phone_call)
                .setContentTitle("AirSIM VoWLAN")
                .setContentText(detail)
                .setContentIntent(open)
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .build();
    }

    public static void showCall(Context context, String callId, String direction, String mode, String state) {
        if (callId == null || callId.isEmpty() || "ended".equals(state) || "unknown".equals(state)) return;
        boolean incoming = "incoming".equals(direction) && "incoming".equals(state);
        if (incoming) createCallChannel(context);
        else createChannel(context);
        Intent screenIntent = new Intent(context, CallScreenActivity.class)
                .setData(Uri.parse("airsim-call://screen/" + Uri.encode(callId)))
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_CLEAR_TOP
                        | Intent.FLAG_ACTIVITY_SINGLE_TOP)
                .putExtra(CallScreenActivity.EXTRA_CALL_ID, callId);
        PendingIntent screen = PendingIntent.getActivity(context, 1, screenIntent,
                PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
        String text = incoming
                ? (AppConfig.MODE_REMOTE_SILENT.equals(mode)
                    ? "Forwarded to iPhone; you can also answer here" : "Answer or decline here")
                : "Call in progress · Tap to view";
        Notification.Builder builder = new Notification.Builder(context, incoming ? CALL_CHANNEL : CHANNEL)
                .setSmallIcon(android.R.drawable.stat_sys_phone_call)
                .setContentTitle(incoming ? "AirSIM incoming call" : "AirSIM call")
                .setContentText(text)
                .setContentIntent(screen)
                .setCategory(Notification.CATEGORY_CALL)
                .setVisibility(Notification.VISIBILITY_PUBLIC)
                .setOngoing(true)
                .setOnlyAlertOnce(true);
        if (incoming) {
            builder.setPriority(Notification.PRIORITY_HIGH)
                    .setFullScreenIntent(screen, true)
                    .addAction(android.R.drawable.sym_action_call, "Answer",
                            CallNotificationActionReceiver.pendingIntent(context, callId, "answer"))
                    .addAction(android.R.drawable.ic_menu_close_clear_cancel, "Decline",
                            CallNotificationActionReceiver.pendingIntent(context, callId, "reject"));
        } else {
            builder.addAction(android.R.drawable.ic_menu_close_clear_cancel, "End call",
                    CallNotificationActionReceiver.pendingIntent(context, callId, "end"));
        }
        context.getSystemService(NotificationManager.class).notify(callId, CALL_ID, builder.build());
    }

    public static void clearCall(Context context, String callId) {
        context.getSystemService(NotificationManager.class).cancel(callId, CALL_ID);
    }
}
