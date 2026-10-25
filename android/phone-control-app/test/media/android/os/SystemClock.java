package android.os;
public final class SystemClock {
    public static long time = 1000;
    public static long elapsedRealtime() { return time; }
}
