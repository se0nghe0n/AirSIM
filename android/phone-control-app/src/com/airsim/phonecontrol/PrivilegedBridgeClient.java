package com.airsim.phonecontrol;

import android.os.IBinder;
import android.os.Parcel;
import android.os.RemoteException;
import android.content.Context;

final class PrivilegedBridgeClient implements PrivilegedBridgeCoordinator.Transport {
    private final IBinder owner = new android.os.Binder();
    private final IBinder binder;
    private final PrivilegedProcessTransport process;

    PrivilegedBridgeClient(IBinder binder) {
        if (binder == null || !binder.pingBinder()) throw new IllegalArgumentException("privileged binder unavailable");
        this.binder = binder;
        this.process = null;
    }

    private PrivilegedBridgeClient(PrivilegedProcessTransport process) {
        this.binder = null;
        this.process = process;
    }

    static PrivilegedBridgeClient openProcess(Context context) throws Exception {
        return new PrivilegedBridgeClient(PrivilegedProcessTransport.open(context));
    }

    boolean isAlive() { return process != null ? process.isAlive() : binder.pingBinder(); }

    boolean isProcessTransport() { return process != null; }

    void close() {
        if (process != null) process.close();
    }

    @Override public String startBridge() throws RemoteException {
        return transact(PrivilegedBridgeProtocol.TRANSACTION_START_BRIDGE, false, false);
    }

    @Override public String status() throws RemoteException {
        return transact(PrivilegedBridgeProtocol.TRANSACTION_STATUS, false, false);
    }

    @Override public String setLocalOutputMuted(boolean muted) throws RemoteException {
        return transact(PrivilegedBridgeProtocol.TRANSACTION_SET_LOCAL_OUTPUT_MUTED, true, muted);
    }

    String ensureDialerRole() throws RemoteException {
        return transact(PrivilegedBridgeProtocol.TRANSACTION_ENSURE_DIALER_ROLE, false, false);
    }

    String mediaRequest(String request) throws Exception {
        PrivilegedMediaProtocol.bounded(request);
        if (process != null) return process.mediaRequest(request);
        Parcel data = Parcel.obtain();
        Parcel reply = Parcel.obtain();
        try {
            data.writeInterfaceToken(PrivilegedBridgeProtocol.DESCRIPTOR);
            data.writeStrongBinder(owner);
            data.writeString(request);
            if (!binder.transact(PrivilegedBridgeProtocol.TRANSACTION_MEDIA, data, reply, 0))
                throw new RemoteException("media_transaction_rejected");
            reply.readException();
            return PrivilegedMediaProtocol.bounded(reply.readString());
        } finally { reply.recycle(); data.recycle(); }
    }

    private String transact(int code, boolean hasBoolean, boolean value) throws RemoteException {
        if (process != null) {
            try { return process.request(code, hasBoolean && value); }
            catch (Exception error) {
                throw new RemoteException("Pixel process bridge: " + error.getMessage());
            }
        }
        Parcel data = Parcel.obtain();
        Parcel reply = Parcel.obtain();
        try {
            data.writeInterfaceToken(PrivilegedBridgeProtocol.DESCRIPTOR);
            data.writeStrongBinder(owner);
            if (hasBoolean) data.writeInt(value ? 1 : 0);
            if (!binder.transact(code, data, reply, 0)) throw new RemoteException("privileged transaction rejected");
            reply.readException();
            String result = reply.readString();
            return result == null ? "" : result;
        } finally {
            reply.recycle();
            data.recycle();
        }
    }
}
