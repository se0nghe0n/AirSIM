package android.telecom;

public class Call {
    public static final int STATE_DIALING = 1;
    public static final int STATE_RINGING = 2;
    public static final int STATE_ACTIVE = 4;
    public static final int STATE_DISCONNECTING = 9;
    public static final int STATE_DISCONNECTED = 10;

    private int state;

    public Call(int state) { this.state = state; }

    public int getState() { return state; }

    public void answer(int videoState) { state = STATE_ACTIVE; }

    public void reject(boolean withMessage, String textMessage) { state = STATE_DISCONNECTED; }

    public void disconnect() { state = STATE_DISCONNECTED; }

    public void playDtmfTone(char digit) {}

    public void stopDtmfTone() {}
}
