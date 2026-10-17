package com.airsim.phonecontrol.voble;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.Service;
import android.Manifest;
import android.bluetooth.BluetoothGatt;
import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.content.pm.ServiceInfo;
import android.os.Build;
import android.os.IBinder;

import com.airsim.phonecontrol.AndroidAgentIdentity;
import com.airsim.phonecontrol.BridgeLog;
import com.airsim.phonecontrol.CallRepository;
import com.airsim.phonecontrol.RuntimeMode;
import com.airsim.phonecontrol.RemoteAudioSessionRegistry;

import org.json.JSONObject;

import java.nio.charset.StandardCharsets;
import java.security.SecureRandom;
import java.util.Arrays;
import java.util.Base64;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.atomic.AtomicLong;

public final class VoBLEGatewayService extends Service implements VoBLEGattServer.Listener {
    private static final String CHANNEL_ID = "airsim_voble";
    private static final int NOTIFICATION_ID = 4108;
    private static volatile VoBLEGatewayService instance;
    private static volatile VoBLEDiagnostics.Snapshot diagnostics =
            VoBLEDiagnostics.idle("Android");
    private static volatile String pendingPairingCode = "";

    public static String diagnosticsSummary() {
        return VoBLEDiagnostics.summary(diagnostics);
    }

    public static boolean isAuthenticated() {
        return diagnostics != null && diagnostics.authenticated();
    }

    public static String pendingPairingCode() {
        return pendingPairingCode;
    }

    public static boolean hasStoredCredential(Context context) {
        String identity = AndroidAgentIdentity.agentID(context);
        return VoBLECredentialStore.androidPrivatePreferences(context).hasCredential(identity);
    }

    /** Local recovery path for a stale iPhone credential. It never opens a remote reset endpoint. */
    public static void clearStoredCredential(Context context) {
        VoBLEGatewayService active = instance;
        if (active != null) {
            active.controlQueue.execute(active::revokeLocalCredential);
            return;
        }
        String identity = AndroidAgentIdentity.agentID(context);
        VoBLECredentialStore.androidPrivatePreferences(context).revoke(identity);
        pendingPairingCode = "";
        diagnostics = VoBLEDiagnostics.idle(RuntimeMode.agentLabel(context));
    }

    private record SessionContext(
            String deviceId, byte[] sessionId, String callId, long generation) {}

    private final ExecutorService controlQueue = Executors.newSingleThreadExecutor();
    private final ExecutorService mediaQueue = Executors.newSingleThreadExecutor();
    private final VoBLEControlChannel channel = new VoBLEControlChannel();
    private final AtomicLong generations = new AtomicLong();
    private final Map<String, Long> callGenerations = new ConcurrentHashMap<>();
    private final Map<String, String> peerIdentities = new ConcurrentHashMap<>();
    private final SecureRandom random = new SecureRandom();
    private VoBLEPairingManager pairingManager;
    private VoBLEGattServer gatt;
    private VoBLECallController calls;
    private VoBLEMediaSession media;
    private VoBLEMediaSession.Identity mediaIdentity;
    private volatile SessionContext session;

    public static void start(Context context) {
        if (!hasPermissions(context)) return;
        Intent intent = new Intent(context, VoBLEGatewayService.class);
        try {
            if (Build.VERSION.SDK_INT >= 26) context.startForegroundService(intent);
            else context.startService(intent);
        } catch (IllegalStateException | SecurityException restricted) {
            // Application/boot may run in the background. Retry when the Activity resumes;
            // do not let an expected platform restriction kill the app or clear pairing.
            BridgeLog.error("voble_service_start_deferred", restricted);
        }
    }

    public static boolean hasPermissions(Context context) {
        return Build.VERSION.SDK_INT < 31
                || (context.checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT)
                        == PackageManager.PERMISSION_GRANTED
                && context.checkSelfPermission(Manifest.permission.BLUETOOTH_ADVERTISE)
                        == PackageManager.PERMISSION_GRANTED);
    }

    public static void publishCallState(
            Context context, String callId, String direction, String state, String number) {
        VoBLEGatewayService active = instance;
        if (active == null) {
            start(context);
            return;
        }
        active.controlQueue.execute(() -> active.publishCallState(callId, direction, state, number));
    }

    @Override public void onCreate() {
        super.onCreate();
        instance = this;
        createNotificationChannel();
        Notification notification = new Notification.Builder(this, CHANNEL_ID)
                .setSmallIcon(android.R.drawable.stat_sys_data_bluetooth)
                .setContentTitle("AirSIM Bluetooth calls")
                .setContentText("Waiting for an authenticated iPhone")
                .setOngoing(true).build();
        if (Build.VERSION.SDK_INT >= 34) {
            startForeground(NOTIFICATION_ID, notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE);
        } else {
            startForeground(NOTIFICATION_ID, notification);
        }
        VoBLECredentialStore credentials = VoBLECredentialStore.androidPrivatePreferences(this);
        pairingManager = new VoBLEPairingManager(credentials);
        calls = new VoBLECallController(request -> {
            CallRepository.ActionResult result = CallRepository.executeRemote(
                    VoBLEGatewayService.this, request.requestId(), request.action(), request.callId(), request.number());
            return result.success
                    ? VoBLECallController.Result.success("accepted")
                    : VoBLECallController.Result.failure("telecom_failed", result.error);
        });
        gatt = new VoBLEGattServer(this, this, channel);
        if (!gatt.start()) BridgeLog.info("voble_waiting_for_bluetooth_permission");
    }

    @Override public int onStartCommand(Intent intent, int flags, int startId) {
        if (gatt != null && gatt.hasBluetoothPermissions()) gatt.start();
        return START_STICKY;
    }

    @Override public IBinder onBind(Intent intent) { return null; }

    @Override public void onPairingWrite(String deviceId, byte[] value) {
        controlQueue.execute(() -> handlePairing(deviceId, value));
    }

    private void handlePairing(String deviceId, byte[] value) {
        try {
            JSONObject request = new JSONObject(new String(value, StandardCharsets.UTF_8));
            String operation = request.optString("op", "");
            JSONObject response = new JSONObject().put("version", 1).put("op", operation);
            String identity = AndroidAgentIdentity.agentID(this);
            if ("begin".equals(operation)) {
                pendingPairingCode = "";
                VoBLEPairingManager.Challenge challenge = pairingManager.begin(
                        identity, System.currentTimeMillis());
                response.put("challenge_id", challenge.id())
                        .put("android_identity", identity)
                        .put("android_public", base64(challenge.androidPublicKey()))
                        .put("android_nonce", base64(challenge.androidNonce()))
                        .put("expires_at_ms", challenge.expiresAtMillis());
            } else if ("prepare".equals(operation)) {
                VoBLEPairingManager.PairingMaterial material = pairingManager.preview(
                        request.getString("challenge_id"),
                        decode(request.getString("iphone_public")),
                        decode(request.getString("iphone_nonce")), System.currentTimeMillis());
                response.put("sas", material.sas());
                showPairingCode(material.sas());
            } else if ("confirm".equals(operation)) {
                if (!channel.canAuthenticate(deviceId)) {
                    throw new SecurityException("another central owns VoBLE");
                }
                VoBLEPairingManager.PairingMaterial material;
                if (request.has("reconnect_tag")) {
                    material = pairingManager.confirmReconnect(
                            request.getString("challenge_id"),
                            decode(request.getString("iphone_public")),
                            decode(request.getString("iphone_nonce")),
                            decode(request.getString("reconnect_tag")), System.currentTimeMillis());
                } else {
                    material = pairingManager.confirm(
                            request.getString("challenge_id"),
                            decode(request.getString("iphone_public")),
                            decode(request.getString("iphone_nonce")),
                            request.getString("sas"), System.currentTimeMillis());
                }
                if (!channel.authenticate(deviceId)) throw new SecurityException("another central owns VoBLE");
                peerIdentities.put(deviceId, identity);
                diagnostics = new VoBLEDiagnostics.Snapshot(
                        RuntimeMode.agentLabel(this), true, false, "unavailable",
                        0, 0, 0, "");
                publishDiagnostics();
                response.put("ready", true).put("sas", material.sas())
                        .put("confirmation_tag", base64(VoBLEPairingManager.confirmationTag(
                                material.pairingKey(), request.getString("challenge_id"))));
                showReadyNotification();
            } else {
                throw new IllegalArgumentException("unsupported pairing operation");
            }
            gatt.indicatePairing(deviceId, response.toString().getBytes(StandardCharsets.UTF_8));
        } catch (Exception error) {
            sendPairingError(deviceId, error.getMessage());
        }
    }

    @Override public void onControlWrite(String deviceId, byte[] value) {
        controlQueue.execute(() -> handleControl(deviceId, value));
    }

    private void handleControl(String deviceId, byte[] value) {
        try {
            if (!channel.isReady(deviceId)) throw new SecurityException("peer is not authenticated");
            VoBLEProtocol.ControlEnvelope envelope = VoBLEProtocol.decodeControl(value);
            JSONObject body = new JSONObject(new String(envelope.ciphertext(), StandardCharsets.UTF_8));
            long timestamp = body.getLong("timestamp_ms");
            String identity = peerIdentities.get(deviceId);
            if (identity == null) throw new SecurityException("peer identity is unavailable");
            byte[] authenticated = Arrays.copyOf(value, value.length - VoBLEProtocol.AUTH_TAG_LENGTH);
            boolean valid = pairingManager.authenticate(
                    identity, envelope.sessionId(), envelope.callId(), envelope.generation(),
                    envelope.nonce(), timestamp, authenticated,
                    envelope.authenticationTag(), System.currentTimeMillis());
            if (!valid) throw new SecurityException("control authentication failed");
            String requestId = body.getString("request_id");
            String action = normalizeAction(envelope.command());
            // Reading fresh metadata must not replace an active call's ID/generation.
            if (!"device_info".equals(action) || session == null) {
                session = new SessionContext(deviceId, envelope.sessionId(),
                        envelope.callId(), envelope.generation());
            }
            VoBLECallController.Request request = new VoBLECallController.Request(
                    requestId, action, envelope.callId(), body.optString("number", ""),
                    envelope.generation());
            VoBLECallController.Result result;
            boolean revokeAfterResponse = false;
            if ("ping".equals(action)) {
                result = calls.executeOnce(request, true,
                        ignored -> VoBLECallController.Result.success("ready"));
            } else if ("device_info".equals(action)) {
                result = VoBLECallController.Result.success(new JSONObject()
                        .put("agent_id", AndroidAgentIdentity.agentID(this))
                        .put("device_name", AndroidAgentIdentity.deviceName())
                        .put("agent_kind", RuntimeMode.isStandalone(this) ? "standalone" : "avf")
                        .put("phone_number", AndroidAgentIdentity.phoneNumber(this)).toString());
            } else if ("start_media".equals(action) || "dial".equals(action) || "answer".equals(action)) {
                result = VoBLECallController.Result.failure("bluetooth_unavailable");
            } else if ("stop_media".equals(action)) {
                result = calls.executeOnce(request, true, ignored -> {
                    if (!calls.ownsCall(envelope.callId(), envelope.generation())) {
                        return VoBLECallController.Result.failure("call_mismatch");
                    }
                    stopMedia(envelope.callId(), envelope.generation());
                    return VoBLECallController.Result.success("stopped");
                });
            } else if ("unpair".equals(action)) {
                result = VoBLECallController.Result.success("unpaired");
                revokeAfterResponse = true;
            } else {
                result = calls.execute(request, true);
            }
            sendControl(deviceId, envelope.sessionId(), envelope.callId(), envelope.generation(),
                    "response", new JSONObject().put("request_id", requestId)
                            .put("ok", result.success()).put("code", result.code())
                            .put("detail", result.detail()));
            if (revokeAfterResponse && result.success()) revokeAuthenticatedPeer(deviceId, identity);
        } catch (Exception error) {
            sendPlainControlError(deviceId, error instanceof SecurityException
                    ? "authentication_failed" : "invalid_request");
        }
    }

    @Override public void onAudioWrite(String deviceId, byte[] value) {
        mediaQueue.execute(() -> {
            VoBLEMediaSession active = media;
            VoBLEMediaSession.Identity identity = mediaIdentity;
            if (!channel.owns(deviceId) || active == null || identity == null
                    || !active.onUplinkFragment(identity, value)) {
                BridgeLog.info("voble_audio_rejected_unowned_or_stale");
            }
        });
    }

    @Override public void onDisconnected(String deviceId) {
        controlQueue.execute(() -> {
            peerIdentities.remove(deviceId);
            SessionContext value = session;
            if (value != null && value.deviceId.equals(deviceId)) {
                session = null;
                stopMedia("", 0);
            }
            pendingPairingCode = "";
            diagnostics = VoBLEDiagnostics.idle(RuntimeMode.agentLabel(this));
        });
    }

    private void publishCallState(String callId, String direction, String state, String number) {
        Long generation = callGenerations.get(callId);
        if (generation == null && !"ended".equals(state)) {
            SessionContext activeSession = session;
            boolean ownsPendingOutgoing = "outgoing".equals(direction)
                    && activeSession != null
                    && calls.ownsCall(activeSession.callId, activeSession.generation);
            if (ownsPendingOutgoing) {
                // `dial` starts with an iOS provisional ID. Android's first
                // Telecom event authoritatively replaces the ID, not the
                // generation; advancing both strands iOS on the old call.
                generation = activeSession.generation;
            } else {
                long candidate = generations.incrementAndGet();
                generation = Math.max(candidate, calls.currentGeneration() + 1);
            }
            generations.accumulateAndGet(generation, Math::max);
            callGenerations.put(callId, generation);
        }
        if (generation == null) return;
        boolean terminal = calls.observeCall(callId, generation, state);
        if ("ended".equals(state) && !terminal) return;
        SessionContext target = session;
        if (target != null && channel.isReady(target.deviceId)) {
            try {
                sendControl(target.deviceId, target.sessionId, callId, generation,
                        "call_state", new JSONObject().put("direction", direction).put("state", state)
                                .put("number", number == null ? "" : number));
            } catch (Exception error) {
                BridgeLog.error("voble_call_state_failed", error);
            }
        }
        if (terminal) callGenerations.remove(callId);
        if (terminal) stopMedia(callId, generation);
    }

    private void stopMedia(String callId, long generation) {
        VoBLEMediaSession.Identity identity = mediaIdentity;
        if (identity != null && callId != null && !callId.isEmpty()
                && (!identity.callId().equals(callId) || identity.generation() != generation)) return;
        VoBLEMediaSession active = media;
        media = null;
        mediaIdentity = null;
        RemoteAudioSessionRegistry.setVoBLE(false);
        if (active != null) {
            VoBLEMediaSession.Stats stats = active.stats();
            diagnostics = new VoBLEDiagnostics.Snapshot(
                    RuntimeMode.agentLabel(this), session != null, false,
                    "unavailable", stats.downlinkFrames(), stats.uplinkFrames(),
                    stats.droppedFrames(), "");
            publishDiagnostics();
            active.close();
        }
    }

    private void revokeLocalCredential() {
        String identity = AndroidAgentIdentity.agentID(this);
        pairingManager.revoke(identity);
        for (String deviceId : peerIdentities.keySet()) {
            channel.revokeOwnerAndDisconnect(deviceId, () -> {
                VoBLEGattServer active = gatt;
                if (active != null) active.disconnectPeer(deviceId);
            });
        }
        peerIdentities.clear();
        session = null;
        pendingPairingCode = "";
        stopMedia("", 0);
        diagnostics = VoBLEDiagnostics.idle(RuntimeMode.agentLabel(this));
        publishDiagnostics();
        BridgeLog.info("voble_pairing_cleared_locally");
    }

    private void revokeAuthenticatedPeer(String deviceId, String identity) {
        pairingManager.revoke(identity);
        channel.revokeOwner(deviceId);
        peerIdentities.remove(deviceId);
        SessionContext current = session;
        if (current != null && current.deviceId.equals(deviceId)) session = null;
        pendingPairingCode = "";
        stopMedia("", 0);
        diagnostics = VoBLEDiagnostics.idle(RuntimeMode.agentLabel(this));
        publishDiagnostics();
        BridgeLog.info("voble_pairing_revoked_by_authenticated_peer");
    }

    private void publishDiagnostics() {
        VoBLEGattServer active = gatt;
        if (active == null) return;
        active.updateDiagnostics(new JSONObject(diagnostics.sanitizedFields())
                .toString().getBytes(StandardCharsets.UTF_8));
    }

    private void sendControl(
            String deviceId, byte[] sessionId, String callId, long generation,
            String command, JSONObject body) throws Exception {
        long timestamp = System.currentTimeMillis();
        body.put("timestamp_ms", timestamp);
        byte[] nonce = new byte[12];
        random.nextBytes(nonce);
        byte[] payload = body.toString().getBytes(StandardCharsets.UTF_8);
        VoBLEProtocol.ControlEnvelope unsigned = new VoBLEProtocol.ControlEnvelope(
                command, callId == null ? "" : callId, generation,
                sessionId, nonce, payload, new byte[16]);
        byte[] encoded = VoBLEProtocol.encodeControl(unsigned);
        byte[] prefix = Arrays.copyOf(encoded, encoded.length - VoBLEProtocol.AUTH_TAG_LENGTH);
        String identity = peerIdentities.get(deviceId);
        byte[] tag = pairingManager.signSessionMessage(
                identity, sessionId, callId, generation, nonce, timestamp, prefix);
        VoBLEProtocol.ControlEnvelope signed = new VoBLEProtocol.ControlEnvelope(
                command, callId == null ? "" : callId, generation,
                sessionId, nonce, payload, tag);
        gatt.indicateControl(deviceId, VoBLEProtocol.encodeControl(signed));
    }

    private void sendPairingError(String deviceId, String detail) {
        try {
            JSONObject response = new JSONObject().put("ok", false)
                    .put("error", detail == null ? "pairing_failed" : detail);
            gatt.indicatePairing(deviceId, response.toString().getBytes(StandardCharsets.UTF_8));
        } catch (Exception ignored) {}
    }

    private void sendPlainControlError(String deviceId, String code) {
        try {
            JSONObject response = new JSONObject().put("ok", false).put("code", code);
            gatt.indicateControl(deviceId, response.toString().getBytes(StandardCharsets.UTF_8));
        } catch (Exception ignored) {}
    }

    private static String normalizeAction(String command) {
        return switch (command) {
            case "hangup" -> "end";
            default -> command;
        };
    }

    private static String base64(byte[] value) {
        return Base64.getUrlEncoder().withoutPadding().encodeToString(value);
    }

    private static byte[] decode(String value) { return Base64.getUrlDecoder().decode(value); }

    private void createNotificationChannel() {
        NotificationManager manager = getSystemService(NotificationManager.class);
        if (manager != null) manager.createNotificationChannel(new NotificationChannel(
                CHANNEL_ID, "AirSIM Bluetooth calls", NotificationManager.IMPORTANCE_LOW));
    }

    private void showPairingCode(String sas) {
        pendingPairingCode = sas == null ? "" : sas;
        NotificationManager manager = getSystemService(NotificationManager.class);
        if (manager == null) return;
        manager.notify(NOTIFICATION_ID, new Notification.Builder(this, CHANNEL_ID)
                .setSmallIcon(android.R.drawable.stat_sys_data_bluetooth)
                .setContentTitle("AirSIM Bluetooth pairing")
                .setContentText("Security code " + sas + " · Verify on iPhone")
                .setOngoing(true).build());
    }

    private void showReadyNotification() {
        pendingPairingCode = "";
        NotificationManager manager = getSystemService(NotificationManager.class);
        if (manager == null) return;
        manager.notify(NOTIFICATION_ID, new Notification.Builder(this, CHANNEL_ID)
                .setSmallIcon(android.R.drawable.stat_sys_data_bluetooth)
                .setContentTitle("AirSIM Bluetooth calls")
                .setContentText("Authenticated iPhone connected")
                .setOngoing(true).build());
    }

    @Override public void onDestroy() {
        instance = null;
        pendingPairingCode = "";
        diagnostics = VoBLEDiagnostics.idle(RuntimeMode.agentLabel(this));
        controlQueue.shutdownNow();
        mediaQueue.shutdownNow();
        stopMedia("", 0);
        if (gatt != null) gatt.close();
        super.onDestroy();
    }
}
