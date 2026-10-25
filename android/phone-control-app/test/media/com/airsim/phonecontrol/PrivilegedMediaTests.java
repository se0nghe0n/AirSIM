package com.airsim.phonecontrol;
import org.json.*;
import java.io.*;
import java.util.UUID;
import java.util.concurrent.*;

public final class PrivilegedMediaTests {
    static int checks;
    static final String CALL=UUID.randomUUID().toString(), OWNER=UUID.randomUUID().toString();
    static long request;
    static JSONObject message(String action, String owner) throws Exception {
        return new JSONObject().put("version",2).put("request_id",++request).put("action",action)
                .put("call_uuid",CALL).put("generation",1).put("owner_id",owner);
    }
    interface Checked { void run() throws Exception; }
    static void rejected(Checked work) throws Exception {
        try { work.run();throw new AssertionError("accepted rejected operation"); }
        catch (IllegalArgumentException | IllegalStateException expected) { checks++; }
    }
    static void check(boolean result) { if(!result)throw new AssertionError();checks++; }
    public static void main(String[] args) throws Exception {
        rejected(() -> PrivilegedMediaProtocol.bounded("x".repeat(PrivilegedMediaProtocol.MAX_BYTES+1)));
        rejected(() -> PrivilegedMediaProtocol.bounded("é".repeat(PrivilegedMediaProtocol.MAX_BYTES/2+1)));
        rejected(() -> PrivilegedMediaProtocol.requireIdentity("bad",1));
        rejected(() -> PrivilegedMediaProtocol.requireIdentity(CALL,0));
        check("hello".equals(PrivilegedMediaProtocol.readLine(new BufferedReader(new StringReader("hello\n")))));
        check(PrivilegedMediaProtocol.readLine(new BufferedReader(new StringReader(""))) == null);
        try { PrivilegedMediaProtocol.readLine(new BufferedReader(new StringReader("partial")));throw new AssertionError(); }
        catch(IOException expected){checks++;}
        int[] restores={0};
        boolean[] muted={false};
        try(PrivilegedMediaService service=new PrivilegedMediaService(new android.content.Context(),()->{restores[0]++;muted[0]=false;},()->muted[0]=true)) {
            rejected(()->service.request(message("start",OWNER).put("ice_servers",new JSONArray()).toString()));
            service.initialize();check(service.available());
            rejected(()->service.request(message("start",OWNER).put("version",1).toString()));
            rejected(()->service.request(message("start",OWNER).put("request_id",0).toString()));
            JSONObject start=message("start",OWNER).put("ice_servers",new JSONArray()).put("host_only",true);
            service.request(start.toString()); service.request(start.toString()); check(TelephonyWebRTCPeer.starts==1);
            rejected(()->service.request(message("start",UUID.randomUUID().toString()).put("ice_servers",new JSONArray()).toString()));
            JSONObject signal=new JSONObject().put("action","webrtc_offer").put("call_uuid",CALL).put("generation",1);
            rejected(()->service.request(message("signal",OWNER).put("signal",new JSONObject(signal.toString()).put("generation",2)).toString()));
            rejected(()->service.request(message("signal",OWNER).put("signal",new JSONObject(signal.toString()).put("action","pcm")).toString()));
            service.request(message("signal",OWNER).put("signal",signal).toString());
            check(new JSONObject(service.request(message("poll",OWNER).toString())).getJSONObject("event").getString("action").equals("webrtc_offer"));
            service.request(message("stop",OWNER).toString());check(TelephonyWebRTCPeer.closes==1);
            rejected(()->service.request(start.toString()));
            String next=UUID.randomUUID().toString();
            service.request(message("start",next).put("ice_servers",new JSONArray()).toString());check(TelephonyWebRTCPeer.starts==2);check(muted[0]);
            rejected(()->service.request(message("stop",OWNER).toString()));
            android.os.SystemClock.time += PrivilegedMediaProtocol.OWNER_LEASE_MILLIS + 1;
            var expiry=PrivilegedMediaService.class.getDeclaredMethod("expireOwner");expiry.setAccessible(true);expiry.invoke(service);
            JSONObject ended=new JSONObject(service.request(message("poll",next).toString()));
            check(!ended.getBoolean("active"));check("webrtc_failed".equals(ended.getJSONObject("event").getString("status")));
            check(restores[0]>=2);
        }
        delayedDisposal();
        failedDisposal();
        delayedFailureAndLease();
        closeDuringDisposal();
        failedAcquisitionAndStart();
        failedRestore();
        System.out.println("Privileged media protocol/owner tests passed ("+checks+" checks)");
    }

    static String start(String owner) throws Exception {
        return message("start", owner).put("ice_servers", new JSONArray()).toString();
    }
    static JSONObject poll(PrivilegedMediaService service, String owner) throws Exception {
        return new JSONObject(service.request(message("poll", owner).toString()));
    }
    static void rejected(String reason, Checked work) throws Exception {
        try { work.run(); throw new AssertionError("accepted " + reason); }
        catch (IllegalStateException expected) { check(reason.equals(expected.getMessage())); }
    }
    static JSONObject signal() throws Exception {
        return new JSONObject().put("action", "webrtc_offer").put("call_uuid", CALL).put("generation", 1);
    }
    static PrivilegedMediaService delayedService(int[] restores) {
        TelephonyWebRTCPeer.delayedDisposal = true;
        PrivilegedMediaService service = new PrivilegedMediaService(new android.content.Context(), () -> restores[0]++, () -> {});
        service.initialize();
        return service;
    }
    static void finishOffThread(TelephonyWebRTCPeer peer) throws Exception {
        ExecutorService executor = Executors.newSingleThreadExecutor();
        try { executor.submit(peer::completeDisposal).get(2, TimeUnit.SECONDS); }
        finally { executor.shutdownNow(); }
    }
    static void delayedDisposal() throws Exception {
        int[] restores = {0};
        try (PrivilegedMediaService service = delayedService(restores)) {
            service.request(start(OWNER));
            TelephonyWebRTCPeer old = TelephonyWebRTCPeer.latest;
            int starts = TelephonyWebRTCPeer.starts, closes = TelephonyWebRTCPeer.closes;
            old.signals.send(signal()); // Even already queued events must not resurrect a stopped session.
            service.request(message("stop", OWNER).toString());
            service.request(message("stop", OWNER).toString());
            check(TelephonyWebRTCPeer.closes == closes + 1);
            check(restores[0] == 0);
            check(!poll(service, OWNER).getBoolean("active"));
            check(!poll(service, OWNER).has("event"));
            String next = UUID.randomUUID().toString();
            rejected("media_owner_busy", () -> service.request(start(next)));
            rejected("media_session_ended", () -> service.request(start(OWNER)));
            rejected("media_session_ended", () -> service.request(message("signal", OWNER).put("signal", signal()).toString()));
            old.signals.send(signal()); old.failed.run();
            check(!poll(service, OWNER).has("event"));
            check(TelephonyWebRTCPeer.starts == starts);
            finishOffThread(old);
            check(restores[0] == 1);
            service.request(start(next));
            check(TelephonyWebRTCPeer.starts == starts + 1);
            old.completeDisposal(); old.failed.run(); old.signals.send(signal());
            check(restores[0] == 1);
            check(poll(service, next).getBoolean("active"));
            check(!poll(service, next).has("event"));
            service.request(message("stop", next).toString());
            finishOffThread(TelephonyWebRTCPeer.latest);
            check(restores[0] == 2);
        }
    }
    static void failedDisposal() throws Exception {
        int[] restores = {0};
        try (PrivilegedMediaService service = delayedService(restores)) {
            service.request(start(OWNER));
            TelephonyWebRTCPeer old = TelephonyWebRTCPeer.latest;
            service.request(message("stop", OWNER).toString());
            old.failDisposal();
            check(restores[0] == 1);
            rejected("media_owner_busy", () -> service.request(start(UUID.randomUUID().toString())));
            check(!poll(service, OWNER).getBoolean("active"));
            service.request(message("stop", OWNER).toString());
            old.completeDisposal();
            check(restores[0] == 1);
            check(service.closeAsync().isCompletedExceptionally());
        }
    }
    static void delayedFailureAndLease() throws Exception {
        for (boolean lease : new boolean[]{false, true}) {
            int[] restores = {0};
            try (PrivilegedMediaService service = delayedService(restores)) {
                service.request(start(OWNER));
                TelephonyWebRTCPeer old = TelephonyWebRTCPeer.latest;
                if (lease) {
                    android.os.SystemClock.time += PrivilegedMediaProtocol.OWNER_LEASE_MILLIS + 1;
                    var expiry = PrivilegedMediaService.class.getDeclaredMethod("expireOwner");
                    expiry.setAccessible(true); expiry.invoke(service); expiry.invoke(service);
                } else { old.failed.run(); old.failed.run(); }
                JSONObject ended = poll(service, OWNER);
                check(!ended.getBoolean("active"));
                check("webrtc_failed".equals(ended.getJSONObject("event").getString("status")));
                check(!poll(service, OWNER).has("event"));
                rejected("media_owner_busy", () -> service.request(start(UUID.randomUUID().toString())));
                check(restores[0] == 0);
                finishOffThread(old);
                check(restores[0] == 1);
            }
        }
    }
    static void closeDuringDisposal() throws Exception {
        int[] restores = {0};
        PrivilegedMediaService service = delayedService(restores);
        service.request(start(OWNER));
        TelephonyWebRTCPeer old = TelephonyWebRTCPeer.latest;
        CompletableFuture<Void> closed = service.closeAsync();
        check(!closed.isDone()); check(!service.available());
        check(service.closeAsync() == closed);
        rejected("media_service_closed", service::initialize);
        rejected("media_service_unavailable", () -> service.request(start(UUID.randomUUID().toString())));
        finishOffThread(old);
        closed.get(2, TimeUnit.SECONDS);
        check(restores[0] == 1);
        service.close(); check(restores[0] == 1);
    }
    static void failedAcquisitionAndStart() throws Exception {
        for (boolean acquisition : new boolean[]{true, false}) {
            int[] restores = {0};
            TelephonyWebRTCPeer.delayedDisposal = true;
            TelephonyWebRTCPeer.rejectStart = !acquisition;
            try (PrivilegedMediaService service = new PrivilegedMediaService(new android.content.Context(), () -> restores[0]++, () -> {
                if (acquisition) throw new IllegalStateException("fake_acquire_failure");
            })) {
                service.initialize();
                rejected(acquisition ? "fake_acquire_failure" : "fake_start_failure", () -> service.request(start(OWNER)));
                rejected("media_owner_busy", () -> service.request(start(UUID.randomUUID().toString())));
                check(restores[0] == 0);
                finishOffThread(TelephonyWebRTCPeer.latest);
                check(restores[0] == 1);
            } finally { TelephonyWebRTCPeer.rejectStart = false; }
        }
    }
    static void failedRestore() throws Exception {
        TelephonyWebRTCPeer.delayedDisposal = true;
        try (PrivilegedMediaService service = new PrivilegedMediaService(new android.content.Context(), () -> {
            throw new IllegalStateException("fake_restore_failure");
        }, () -> {})) {
            service.initialize(); service.request(start(OWNER));
            service.request(message("stop", OWNER).toString());
            finishOffThread(TelephonyWebRTCPeer.latest);
            rejected("media_owner_busy", () -> service.request(start(UUID.randomUUID().toString())));
            check(service.closeAsync().isCompletedExceptionally());
        }
    }
}
