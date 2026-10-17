package com.airsim.phonecontrol.voble;

import java.io.ByteArrayOutputStream;
import java.io.Closeable;
import java.io.EOFException;
import java.io.IOException;
import java.net.InetSocketAddress;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.security.GeneralSecurityException;
import java.util.Arrays;
import java.util.HashMap;
import java.util.Map;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.atomic.AtomicLong;

import javax.crypto.Cipher;
import javax.crypto.spec.GCMParameterSpec;
import javax.crypto.spec.SecretKeySpec;

/** Call media is retired. This session does not open the PCM bridge. */
public final class VoBLEMediaSession implements Closeable {
    public record Identity(String callId, long generation) {
        public Identity {
            if (callId == null || callId.isBlank() || generation <= 0) {
                throw new IllegalArgumentException("valid call identity is required");
            }
        }
    }
    public record Encrypted(byte[] payload, byte[] authenticationTag) {
        public Encrypted {
            payload = payload.clone();
            authenticationTag = authenticationTag.clone();
        }
        @Override public byte[] payload() { return payload.clone(); }
        @Override public byte[] authenticationTag() { return authenticationTag.clone(); }
    }
    public record Stats(long downlinkFrames, long uplinkFrames, long droppedFrames) {}
    public interface BridgeFactory {
        VoBLEPCMBridgeSession open(InetSocketAddress endpoint) throws IOException;
    }
    public interface DownlinkSink { boolean offer(VoBLEProtocol.AudioPacket packet); }

    private final InetSocketAddress endpoint;
    private final BridgeFactory bridgeFactory;
    private final DownlinkSink downlink;
    private VoBLEProtocol.AudioReassembler uplinkReassembler =
            new VoBLEProtocol.AudioReassembler();
    private final VoBLEAudioQueue uplinkQueue = new VoBLEAudioQueue(8);
    private final Map<Integer, Long> uplinkSequences = new HashMap<>();
    private final AtomicLong downlinkFrames = new AtomicLong();
    private final AtomicLong uplinkFrames = new AtomicLong();
    private final AtomicLong droppedFrames = new AtomicLong();
    private volatile VoBLEPCMBridgeSession bridge;
    private volatile ExecutorService pumps;
    private volatile Identity identity;
    private volatile byte[] mediaKey;
    private volatile boolean running;
    private volatile boolean downlinkDiscontinuity;

    public VoBLEMediaSession(
            InetSocketAddress endpoint, BridgeFactory bridgeFactory, DownlinkSink downlink) {
        this.endpoint = endpoint;
        this.bridgeFactory = bridgeFactory;
        this.downlink = downlink;
    }

    public synchronized void start(Identity call, byte[] key) throws IOException {
        throw new IOException("bluetooth call audio is unavailable");
    }

    public synchronized boolean onUplinkFragment(Identity call, byte[] fragment) {
        return false;
    }

    public boolean matches(Identity call) { return running && call != null && call.equals(identity); }
    public boolean ready() { return running && bridge != null && bridge.ready(); }
    public Stats stats() {
        return new Stats(downlinkFrames.get(), uplinkFrames.get(),
                droppedFrames.get() + uplinkQueue.droppedFrames());
    }

    private void stopFromPump() {
        running = false;
        VoBLEPCMBridgeSession active = bridge;
        if (active != null) try { active.close(); } catch (IOException ignored) {}
    }

    @Override public synchronized void close() { stop(); }

    public synchronized void stop() {
        running = false;
        VoBLEPCMBridgeSession active = bridge;
        bridge = null;
        if (active != null) try { active.close(); } catch (IOException ignored) {}
        ExecutorService workers = pumps;
        pumps = null;
        if (workers != null) workers.shutdownNow();
        byte[] key = mediaKey;
        mediaKey = null;
        if (key != null) Arrays.fill(key, (byte) 0);
        identity = null;
        uplinkQueue.clear();
        uplinkSequences.clear();
    }

    private synchronized byte[] keySnapshot() throws GeneralSecurityException {
        if (!running || mediaKey == null) throw new GeneralSecurityException("media session stopped");
        return mediaKey.clone();
    }

    public static Encrypted encrypt(
            byte[] plaintext, byte[] key, boolean uplink, int streamId,
            long sequence, long timestamp) throws GeneralSecurityException {
        Cipher cipher = cipher(Cipher.ENCRYPT_MODE, key, uplink, streamId, sequence, timestamp);
        byte[] joined = cipher.doFinal(plaintext);
        return new Encrypted(
                Arrays.copyOf(joined, joined.length - VoBLEProtocol.AUTH_TAG_LENGTH),
                Arrays.copyOfRange(joined, joined.length - VoBLEProtocol.AUTH_TAG_LENGTH, joined.length));
    }

    public static byte[] decrypt(
            Encrypted encrypted, byte[] key, boolean uplink, int streamId,
            long sequence, long timestamp) throws GeneralSecurityException {
        Cipher cipher = cipher(Cipher.DECRYPT_MODE, key, uplink, streamId, sequence, timestamp);
        byte[] joined = new byte[encrypted.payload.length + encrypted.authenticationTag.length];
        System.arraycopy(encrypted.payload, 0, joined, 0, encrypted.payload.length);
        System.arraycopy(encrypted.authenticationTag, 0, joined, encrypted.payload.length,
                encrypted.authenticationTag.length);
        return cipher.doFinal(joined);
    }

    private static Cipher cipher(
            int mode, byte[] key, boolean uplink, int streamId,
            long sequence, long timestamp) throws GeneralSecurityException {
        if (key == null || key.length != 32 || (streamId & ~0xff) != 0
                || (sequence & ~0xffff_ffffL) != 0 || (timestamp & ~0xffff_ffffL) != 0) {
            throw new GeneralSecurityException("invalid media cryptography inputs");
        }
        ByteBuffer nonce = ByteBuffer.allocate(12).order(ByteOrder.BIG_ENDIAN);
        nonce.put((byte) (uplink ? 1 : 2)).put((byte) streamId).putShort((short) 0)
                .putInt((int) timestamp).putInt((int) sequence);
        ByteBuffer aad = ByteBuffer.allocate(11).order(ByteOrder.BIG_ENDIAN);
        aad.put((byte) (uplink ? 1 : 2)).put((byte) 0)
                .put((byte) streamId).putInt((int) sequence).putInt((int) timestamp);
        Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
        cipher.init(mode, new SecretKeySpec(key, "AES"), new GCMParameterSpec(128, nonce.array()));
        cipher.updateAAD(aad.array());
        return cipher;
    }

    private static byte[] readFrame(java.io.InputStream input, int length) throws IOException {
        ByteArrayOutputStream output = new ByteArrayOutputStream(length);
        byte[] buffer = new byte[length];
        while (output.size() < length) {
            int count = input.read(buffer, 0, length - output.size());
            if (count < 0) throw new EOFException("PCM stream ended");
            if (count > 0) output.write(buffer, 0, count);
        }
        return output.toByteArray();
    }
}
