package com.airsim.phonecontrol;

import java.time.Instant;

/** Pure mapping from CallLog.Calls values; timestamps retain the carrier call duration. */
record NativeCallHistoryRecord(String id, long index, String direction, String number,
                               String startedAt, String endedAt, boolean missed) {
    static final int MAX_ROWS = 100;

    static int limit(int requested) {
        return requested <= 0 ? MAX_ROWS : Math.min(requested, MAX_ROWS);
    }

    static NativeCallHistoryRecord from(String agentID, long rowID, int type,
                                        String number, long dateMillis, long durationSeconds) {
        long start = Math.max(0, dateMillis);
        long seconds = Math.max(0, Math.min(durationSeconds, (Long.MAX_VALUE - start) / 1000));
        String boundedNumber = number == null ? "" : number.substring(0, Math.min(82, number.length()));
        return new NativeCallHistoryRecord("calllog-" + agentID + "-" + rowID, rowID,
                type == 2 ? "outgoing" : "incoming", boundedNumber,
                Instant.ofEpochMilli(start).toString(), Instant.ofEpochMilli(start + seconds * 1000).toString(),
                type == 3); // MISSED_TYPE; zero-duration rejected/blocked calls are not missed calls.
    }
}
