package android.os;

/** Host-only UID for the bridge lifecycle test; no process or privilege operations occur. */
public final class Process {
    public static int myUid() { return 2000; }
}
