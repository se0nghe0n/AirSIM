package android.os;

public final class Handler {
    public static java.util.concurrent.Executor dispatch = Runnable::run;
    public Handler(Looper looper) {}

    public boolean post(Runnable action) {
        dispatch.execute(action);
        return true;
    }
}
