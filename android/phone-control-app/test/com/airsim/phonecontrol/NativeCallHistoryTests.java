package com.airsim.phonecontrol;

final class NativeCallHistoryTests {
    public static void main(String[] args) {
        NativeCallHistoryRecord outgoing = NativeCallHistoryRecord.from("android-a", 17, 2,
                "+821012345678", 1_700_000_000_000L, 42);
        check(outgoing.direction().equals("outgoing") && !outgoing.missed());
        check(outgoing.startedAt().equals("2023-11-14T22:13:20Z"));
        check(outgoing.endedAt().equals("2023-11-14T22:14:02Z"));
        check(outgoing.index() == 17);
        check(outgoing.id().equals(NativeCallHistoryRecord.from("android-a", 17, 2, "", 0, 0).id()));
        check(!outgoing.id().equals(NativeCallHistoryRecord.from("android-b", 17, 2, "", 0, 0).id()));
        NativeCallHistoryRecord missed = NativeCallHistoryRecord.from("android-a", 18, 3, null, 0, 0);
        check(missed.missed() && missed.direction().equals("incoming") && missed.number().isEmpty());
        for (int type : new int[]{1, 2, 5, 6, 7}) {
            check(!NativeCallHistoryRecord.from("a", 1, type, "", 0, 0).missed());
        }
        check(NativeCallHistoryRecord.from("a", 1, 1, "x".repeat(200), -1, -1).number().length() == 82);
        check(NativeCallHistoryRecord.from("a", 1, 1, "", -1, -1).endedAt().equals("1970-01-01T00:00:00Z"));
        check(NativeCallHistoryRecord.limit(0) == 100 && NativeCallHistoryRecord.limit(-1) == 100);
        check(NativeCallHistoryRecord.limit(1) == 1 && NativeCallHistoryRecord.limit(1000) == 100);
        check(RuntimePermissionPolicy.optionalCallHistoryPermissions(false, false).length == 1);
        check(RuntimePermissionPolicy.optionalCallHistoryPermissions(false, true).length == 0);
        check(RuntimePermissionPolicy.optionalCallHistoryPermissions(true, false).length == 0);
        System.out.println("Native call history tests passed");
    }
    private static void check(boolean value) { if (!value) throw new AssertionError(); }
}
