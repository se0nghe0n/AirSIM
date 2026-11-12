package com.airsim.phonecontrol;

import android.Manifest;
import android.content.ContentResolver;
import android.content.ContentUris;
import android.content.Context;
import android.content.SharedPreferences;
import android.content.pm.PackageManager;
import android.database.ContentObserver;
import android.database.Cursor;
import android.net.Uri;
import android.provider.BaseColumns;
import android.provider.Telephony;

import org.json.JSONObject;

import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.time.Instant;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;

/**
 * Optional READ_SMS fallback. It recovers SMS whose broadcast was missed and relays the text of
 * received MMS (for example Korean LMS), which never arrive as SMS_RECEIVED. Messages present
 * before the first authorized scan are never imported.
 */
final class SMSInboxScanner {
    private static final String PREFS = "sms_inbox_fallback";
    private static final String LAST_ID = "last_inbox_id";
    private static final String LAST_MMS_ID = "last_mms_inbox_id";
    private static final long INTERVAL_MS = 30_000;
    private static final long SOON_INTERVAL_MS = 2_000;
    /** While an MMS row waits for its download or parts, look again this often. */
    private static final long MMS_WAIT_INTERVAL_MS = 5_000;
    private static final int BATCH_SIZE = 100;
    private static final int MAX_TRACKED_ROWS = 64;
    /** When this process first saw each MMS row it is waiting on; bounded, rebuilt after restart. */
    private static final Map<Long, Long> MMS_FIRST_SEEN = new LinkedHashMap<>();
    private static long lastScanTime;
    private static boolean mmsWaiting;

    /** Whether a scan ran, and how long until the next scan is useful. */
    record Result(boolean scanned, long nextScanMillis) {}

    private SMSInboxScanner() {}

    static void scanIfDue(Context context) { scan(context, false); }

    /**
     * Scans when due: every 30 s, every 5 s while an MMS is waiting for its download, or within
     * 2 s of a provider change ({@code soon}). A throttled call reports when to try again, so a
     * change notification is never lost.
     */
    static synchronized Result scan(Context context, boolean soon) {
        if (context.checkSelfPermission(Manifest.permission.READ_SMS)
                != PackageManager.PERMISSION_GRANTED) return new Result(true, INTERVAL_MS);
        long now = System.currentTimeMillis();
        long interval = soon ? SOON_INTERVAL_MS : mmsWaiting ? MMS_WAIT_INTERVAL_MS : INTERVAL_MS;
        long elapsed = now - lastScanTime;
        if (elapsed >= 0 && elapsed < interval) return new Result(false, interval - elapsed);
        lastScanTime = now;
        Context application = context.getApplicationContext();
        try {
            scanSMS(application);
        } catch (Exception error) {
            BridgeLog.error("sms_inbox_scan_failed", error);
        }
        // MMS is independent: a provider error here never stops SMS recovery above.
        try {
            mmsWaiting = scanMMS(application, now);
        } catch (Exception error) {
            mmsWaiting = false;
            BridgeLog.error("mms_inbox_scan_failed", error);
        }
        return new Result(true, mmsWaiting ? MMS_WAIT_INTERVAL_MS : INTERVAL_MS);
    }

    /** Wakes the SMS lane when the SMS/MMS provider changes. Returns null without READ_SMS. */
    static ContentObserver observe(Context context, Runnable onChange) {
        if (context.checkSelfPermission(Manifest.permission.READ_SMS)
                != PackageManager.PERMISSION_GRANTED) return null;
        ContentObserver observer = new ContentObserver(null) {
            @Override public void onChange(boolean selfChange) { onChange.run(); }
        };
        try {
            context.getContentResolver().registerContentObserver(Telephony.MmsSms.CONTENT_URI, true, observer);
            return observer;
        } catch (RuntimeException unavailable) {
            BridgeLog.error("sms_inbox_observer_unavailable", unavailable);
            return null;
        }
    }

    static void unobserve(Context context, ContentObserver observer) {
        if (observer == null) return;
        try { context.getContentResolver().unregisterContentObserver(observer); }
        catch (RuntimeException ignored) {}
    }

    private static void scanSMS(Context context) throws Exception {
        SharedPreferences preferences = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE);
        SMSInboxCursor progress = new SMSInboxCursor(preferences.getLong(LAST_ID, -1));
        if (!progress.initialized()) {
            String[] projection = {BaseColumns._ID};
            try (Cursor cursor = context.getContentResolver().query(Telephony.Sms.Inbox.CONTENT_URI,
                    projection, null, null, BaseColumns._ID + " DESC")) {
                if (cursor == null) throw new IllegalStateException("SMS inbox provider unavailable");
                progress.baseline(cursor.moveToFirst() ? cursor.getLong(0) : 0);
            }
            persist(preferences, LAST_ID, progress);
            BridgeLog.info("sms_inbox_baseline_initialized");
            return;
        }

        String[] projection = {BaseColumns._ID, Telephony.Sms.ADDRESS, Telephony.Sms.BODY,
                Telephony.Sms.DATE, Telephony.Sms.DATE_SENT};
        try (Cursor cursor = context.getContentResolver().query(Telephony.Sms.Inbox.CONTENT_URI,
                projection, BaseColumns._ID + " > ?",
                new String[]{Long.toString(progress.value())}, BaseColumns._ID + " ASC")) {
            if (cursor == null) throw new IllegalStateException("SMS inbox provider unavailable");
            int scanned = 0;
            int nonempty = 0;
            long startingID = progress.value();
            while (scanned < BATCH_SIZE && cursor.moveToNext()) {
                scanned++;
                long rowID = cursor.getLong(0);
                if (!progress.shouldQueue(rowID)) continue;
                String sender = cursor.getString(1);
                String content = cursor.getString(2);
                if (content != null && !content.isEmpty()) {
                    nonempty++;
                    long receivedAt = cursor.getLong(3);
                    long sentAt = cursor.getLong(4);
                    long timestamp = SMSDeliveryIdentity.providerTimestamp(sentAt, receivedAt);
                    if (timestamp <= 0) timestamp = System.currentTimeMillis();
                    queue(context, sender, content, timestamp);
                }
                progress.processed(rowID);
                persist(preferences, LAST_ID, progress);
            }
            if (scanned > 0) BridgeLog.info("sms_inbox_scan rows=" + scanned
                    + " nonempty=" + nonempty + " cursor_before=" + startingID
                    + " cursor_after=" + progress.value());
        }
    }

    /** @return true when the scan stopped at a row that is still being downloaded or written. */
    private static boolean scanMMS(Context context, long now) throws Exception {
        SharedPreferences preferences = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE);
        SMSInboxCursor progress = new SMSInboxCursor(preferences.getLong(LAST_MMS_ID, -1));
        ContentResolver resolver = context.getContentResolver();
        if (!progress.initialized()) {
            // Baseline over every box, so an upgrade never imports MMS received before it.
            try (Cursor cursor = resolver.query(Telephony.Mms.CONTENT_URI,
                    new String[]{BaseColumns._ID}, null, null, BaseColumns._ID + " DESC")) {
                if (cursor == null) throw new IllegalStateException("MMS provider unavailable");
                progress.baseline(cursor.moveToFirst() ? cursor.getLong(0) : 0);
            }
            persist(preferences, LAST_MMS_ID, progress);
            BridgeLog.info("mms_inbox_baseline_initialized");
            return false;
        }
        String[] projection = {BaseColumns._ID, Telephony.Mms.DATE, Telephony.Mms.MESSAGE_TYPE};
        try (Cursor cursor = resolver.query(Telephony.Mms.Inbox.CONTENT_URI, projection,
                BaseColumns._ID + " > ?", new String[]{Long.toString(progress.value())},
                BaseColumns._ID + " ASC")) {
            if (cursor == null) throw new IllegalStateException("MMS inbox provider unavailable");
            int scanned = 0;
            int queued = 0;
            boolean waiting = false;
            long startingID = progress.value();
            while (scanned < BATCH_SIZE && cursor.moveToNext()) {
                scanned++;
                long rowID = cursor.getLong(0);
                if (!progress.shouldQueue(rowID)) continue;
                long timestamp = cursor.getLong(1) * 1_000L;
                int messageType = cursor.getInt(2);
                String text = "";
                if (messageType == MMSInboxPolicy.MESSAGE_TYPE_RETRIEVE_CONF) {
                    try {
                        text = readText(resolver, rowID);
                    } catch (Exception unreadable) {
                        // Treated as "no text yet": waits briefly, then the row is skipped
                        // instead of stalling every later MMS.
                        BridgeLog.error("mms_text_unavailable", unreadable);
                    }
                }
                MMSInboxPolicy.Step step = MMSInboxPolicy.step(messageType, !text.isEmpty(),
                        firstSeen(rowID, now), now);
                if (step == MMSInboxPolicy.Step.WAIT) {
                    waiting = true;
                    break;
                }
                if (step == MMSInboxPolicy.Step.QUEUE) {
                    queue(context, readSender(resolver, rowID), text, timestamp > 0 ? timestamp : now);
                    queued++;
                }
                MMS_FIRST_SEEN.remove(rowID);
                progress.processed(rowID);
                persist(preferences, LAST_MMS_ID, progress);
            }
            // A waiting row is re-read every 5 s; log only progress, not each wait.
            if (queued > 0 || progress.value() != startingID) BridgeLog.info("mms_inbox_scan rows=" + scanned + " queued=" + queued
                    + " waiting=" + waiting + " cursor_before=" + startingID
                    + " cursor_after=" + progress.value());
            return waiting;
        }
    }

    private static long firstSeen(long rowID, long now) {
        Long seen = MMS_FIRST_SEEN.get(rowID);
        if (seen != null) return seen;
        MMS_FIRST_SEEN.put(rowID, now);
        while (MMS_FIRST_SEEN.size() > MAX_TRACKED_ROWS) {
            MMS_FIRST_SEEN.remove(MMS_FIRST_SEEN.keySet().iterator().next());
        }
        return now;
    }

    private static String readText(ContentResolver resolver, long messageID) throws Exception {
        List<String> parts = new ArrayList<>();
        String[] projection = {BaseColumns._ID, Telephony.Mms.Part.CONTENT_TYPE, Telephony.Mms.Part.TEXT,
                Telephony.Mms.Part.CHARSET};
        try (Cursor cursor = resolver.query(Telephony.Mms.Part.CONTENT_URI, projection,
                Telephony.Mms.Part.MSG_ID + " = ?", new String[]{Long.toString(messageID)},
                BaseColumns._ID + " ASC")) {
            if (cursor == null) return "";
            while (cursor.moveToNext()) {
                if (!MMSInboxPolicy.isTextPart(cursor.getString(1))) continue;
                String text = cursor.getString(2);
                if (text == null || text.isEmpty()) {
                    // Larger text parts are stored as a file behind content://mms/part/<id>.
                    Uri part = ContentUris.withAppendedId(Telephony.Mms.Part.CONTENT_URI, cursor.getLong(0));
                    text = readPartFile(resolver, part, cursor.isNull(3) ? 106 : cursor.getInt(3));
                }
                parts.add(text);
            }
        }
        return MMSInboxPolicy.joinText(parts);
    }

    private static String readPartFile(ContentResolver resolver, Uri part, int charset) {
        try (InputStream input = resolver.openInputStream(part);
             ByteArrayOutputStream output = new ByteArrayOutputStream()) {
            if (input == null) return "";
            byte[] buffer = new byte[4096];
            int count;
            while ((count = input.read(buffer)) >= 0 && output.size() < MMSInboxPolicy.MAX_TEXT_BYTES) {
                output.write(buffer, 0, Math.min(count, MMSInboxPolicy.MAX_TEXT_BYTES - output.size()));
            }
            return new String(output.toByteArray(), MMSInboxPolicy.charset(charset));
        } catch (Exception missing) {
            return "";
        }
    }

    private static String readSender(ContentResolver resolver, long messageID) {
        Uri addresses = Telephony.Mms.CONTENT_URI.buildUpon()
                .appendPath(Long.toString(messageID)).appendPath("addr").build();
        try (Cursor cursor = resolver.query(addresses,
                new String[]{Telephony.Mms.Addr.ADDRESS, Telephony.Mms.Addr.TYPE}, null, null, null)) {
            if (cursor == null) return "";
            while (cursor.moveToNext()) {
                String address = cursor.getString(0);
                if (MMSInboxPolicy.isSenderAddress(cursor.getInt(1), address)) return address.trim();
            }
        } catch (RuntimeException unavailable) {
            BridgeLog.error("mms_sender_unavailable", unavailable);
        }
        return "";
    }

    private static void queue(Context context, String sender, String content, long timestamp) throws Exception {
        String deliveryID = SMSDeliveryIdentity.id(sender, content, timestamp);
        JSONObject event = new JSONObject(WireJson.smsEvent(UUID.randomUUID().toString(),
                deliveryID, sender == null ? "" : sender, content,
                Instant.ofEpochMilli(timestamp).toString()));
        StandaloneAgentGateway.get(context).sendSMSEvent(event.toString());
    }

    private static void persist(SharedPreferences preferences, String key, SMSInboxCursor progress) {
        if (!preferences.edit().putLong(key, progress.value()).commit()) {
            throw new IllegalStateException("SMS inbox cursor could not be saved");
        }
    }
}
