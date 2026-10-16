package com.airsim.phonecontrol;

import java.io.BufferedInputStream;
import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.DataInputStream;
import java.io.OutputStream;
import java.lang.reflect.Constructor;
import java.util.Arrays;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicReference;
import javax.net.ssl.SSLSocket;

public final class StandaloneWebSocketTests {
    public static void main(String[] args) throws Exception {
        ByteArrayOutputStream bytes = new ByteArrayOutputStream();
        CountDownLatch firstWrite = new CountDownLatch(1);
        CountDownLatch readerFinished = new CountDownLatch(1);
        AtomicInteger writes = new AtomicInteger();
        AtomicReference<Throwable> failure = new AtomicReference<>();
        OutputStream output = new OutputStream() {
            @Override public void write(int value) { throw new AssertionError("complete frame required"); }
            @Override public void write(byte[] data, int offset, int count) {
                synchronized (bytes) { bytes.write(data, offset, count); }
                if (writes.incrementAndGet() == 1) {
                    firstWrite.countDown();
                    try { readerFinished.await(300, TimeUnit.MILLISECONDS); }
                    catch (InterruptedException error) { Thread.currentThread().interrupt(); }
                }
            }
        };
        Constructor<StandaloneWebSocket> constructor = StandaloneWebSocket.class.getDeclaredConstructor(
                SSLSocket.class, BufferedInputStream.class, OutputStream.class);
        constructor.setAccessible(true);
        // A server ping followed by an empty text message lets read() return after its pong.
        StandaloneWebSocket socket = constructor.newInstance(null,
                new BufferedInputStream(new ByteArrayInputStream(new byte[] {(byte) 0x89, 1, 7, (byte) 0x81, 0})), output);
        byte[] voice = new byte[320];
        Arrays.fill(voice, (byte) 0x55);
        Thread writer = new Thread(() -> {
            try { socket.writeBinary(voice); }
            catch (Throwable error) { failure.set(error); }
        });
        Thread reader = new Thread(() -> {
            try { socket.read(); }
            catch (Throwable error) { failure.set(error); }
            finally { readerFinished.countDown(); }
        });
        writer.start();
        check(firstWrite.await(2, TimeUnit.SECONDS), "voice write started");
        reader.start();
        writer.join(2_000); reader.join(2_000);
        check(!writer.isAlive() && !reader.isAlive(), "concurrent writes finish");
        check(failure.get() == null, "no writer failure: " + failure.get());
        DataInputStream wire = new DataInputStream(new ByteArrayInputStream(bytes.toByteArray()));
        check(Arrays.equals(readFrame(wire, 2), voice), "pong must not corrupt the media payload");
        check(Arrays.equals(readFrame(wire, 10), new byte[] {7}), "pong follows a complete media frame");
        check(wire.available() == 0 && writes.get() == 2, "one output write per WebSocket frame");
        System.out.println("StandaloneWebSocketTests passed (concurrent media/pong, no network)");
    }

    private static byte[] readFrame(DataInputStream input, int opcode) throws Exception {
        check(input.readUnsignedByte() == (0x80 | opcode), "expected WebSocket opcode " + opcode);
        int size = input.readUnsignedByte();
        check((size & 0x80) != 0, "client frame is masked");
        size &= 0x7f;
        if (size == 126) size = input.readUnsignedShort();
        byte[] mask = input.readNBytes(4);
        byte[] payload = input.readNBytes(size);
        check(payload.length == size, "complete WebSocket payload");
        for (int i = 0; i < size; i++) payload[i] ^= mask[i & 3];
        return payload;
    }

    private static void check(boolean value, String message) {
        if (!value) throw new AssertionError(message);
    }
}
