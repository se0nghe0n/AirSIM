package com.airsim.phonecontrol;

import android.Manifest;
import android.content.Context;
import android.content.pm.PackageManager;
import android.database.Cursor;
import android.provider.CallLog;
import org.json.JSONArray;
import org.json.JSONObject;
import java.nio.charset.StandardCharsets;

/** Read-only, bounded snapshot of the system call log (including calls before app restart). */
final class NativeCallHistory {
    static JSONArray read(Context context, int requestedLimit) throws Exception {
        if (context.checkSelfPermission(Manifest.permission.READ_CALL_LOG) != PackageManager.PERMISSION_GRANTED) {
            throw new SecurityException("Call history permission is not granted");
        }
        int limit = NativeCallHistoryRecord.limit(requestedLimit);
        String agentID = AndroidAgentIdentity.agentID(context);
        JSONArray history = new JSONArray();
        int historyBytes = 2; // JSON array brackets; leave room for the completion envelope.
        String[] columns = {CallLog.Calls._ID, CallLog.Calls.TYPE, CallLog.Calls.NUMBER,
                CallLog.Calls.DATE, CallLog.Calls.DURATION};
        try (Cursor cursor = context.getContentResolver().query(
                CallLog.Calls.CONTENT_URI.buildUpon().appendQueryParameter("limit", Integer.toString(limit)).build(),
                columns, null, null, CallLog.Calls.DATE + " DESC, " + CallLog.Calls._ID + " DESC")) {
            if (cursor == null) throw new IllegalStateException("Call history provider is unavailable");
            while (history.length() < limit && cursor.moveToNext()) {
                NativeCallHistoryRecord row = NativeCallHistoryRecord.from(agentID, cursor.getLong(0),
                        cursor.getInt(1), cursor.getString(2), cursor.getLong(3), cursor.getLong(4));
                JSONObject record = new JSONObject().put("id", row.id()).put("index", row.index())
                        .put("direction", row.direction()).put("state", "ended").put("number", row.number())
                        .put("started_at", row.startedAt()).put("updated_at", row.endedAt())
                        .put("ended_at", row.endedAt()).put("missed", row.missed());
                int recordBytes = record.toString().getBytes(StandardCharsets.UTF_8).length + 1;
                if (historyBytes + recordBytes > 56 * 1024) break;
                history.put(record);
                historyBytes += recordBytes;
            }
        }
        return history;
    }
}
