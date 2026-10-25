package com.airsim.phonecontrol;

import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.pm.ServiceInfo;
import android.os.IBinder;

import org.json.JSONArray;
import org.json.JSONObject;

import java.net.URI;
import java.net.SocketTimeoutException;
import java.net.URLEncoder;
import java.nio.charset.StandardCharsets;
import java.time.Instant;
import java.util.LinkedHashSet;
import java.util.Set;
import java.util.concurrent.ConcurrentLinkedQueue;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/** Standalone foreground Agent: Relay registration, heartbeat and command execution. */
public final class StandaloneAgentService extends Service {
    private static final ConcurrentLinkedQueue<String> CALL_EVENTS = new ConcurrentLinkedQueue<>();
    private final ExecutorService worker = Executors.newFixedThreadPool(2);
    private final Set<String> completedCommands = new LinkedHashSet<>();
    private final NotificationUpdateGate notificationGate = new NotificationUpdateGate();
    private volatile boolean running;
    private StandaloneAgentStore store;
    private StandaloneRelayClient relay;
    private int syncedRegistrationHash;
    private long lastHeartbeat;
    private long lastCommandPoll;
    private volatile StandaloneWebSocket commandSocket;
    private volatile boolean commandChannelConnected;
    private final Object commandLock = new Object();
    private final CommandRegistrationPolicy commandRegistration = new CommandRegistrationPolicy();
    private SharedPreferences preferences;
    private final SharedPreferences.OnSharedPreferenceChangeListener registrationListener =
            (ignored, key) -> { if ("registration".equals(key)) refreshCommandRegistration(); };

    private record CommandRegistration(JSONObject value, long generation) {}

    public static void start(Context context) {
        try { context.startForegroundService(new Intent(context, StandaloneAgentService.class)); }
        catch (RuntimeException error) { BridgeLog.error("standalone_agent_start_failed", error); }
    }

    static void enqueueCallEvent(Context context, String json) {
        CALL_EVENTS.add(json);
        start(context);
    }

    @Override public void onCreate() {
        super.onCreate();
        store = new StandaloneAgentStore(this);
        relay = new StandaloneRelayClient();
        preferences = getSharedPreferences("standalone_agent", Context.MODE_PRIVATE);
        preferences.registerOnSharedPreferenceChangeListener(registrationListener);
        startForeground(BridgeNotification.AGENT_ID,
                BridgeNotification.status(this, "Starting built-in Agent"),
                ServiceInfo.FOREGROUND_SERVICE_TYPE_REMOTE_MESSAGING);
        running = true;
        ShizukuBridgeManager.get(this).ensureStarted();
        VoWLANGatewayService.start(this);
        worker.execute(this::loop);
        worker.execute(this::commandLoop);
        BridgeLog.info("standalone_agent_created");
    }

    @Override public int onStartCommand(Intent intent, int flags, int startId) {
        refreshCommandRegistration();
        return START_STICKY;
    }

    private CommandRegistration refreshCommandRegistration() {
        synchronized (commandLock) {
            JSONObject value = store.registration();
            boolean enabled = value != null && !value.optBoolean("local_mode", false)
                    && value.optBoolean("cloud_enabled", true);
            if (commandRegistration.update(enabled,
                    value == null ? "" : value.optString("relay_url"),
                    value == null ? "" : value.optString("device_id"),
                    value == null ? "" : value.optString("device_secret"))) {
                commandChannelConnected = false;
                if (commandSocket != null) commandSocket.closeAsync();
                commandLock.notifyAll();
            }
            return new CommandRegistration(enabled ? value : null, commandRegistration.generation());
        }
    }

    private boolean isCurrentCommandRegistration(long generation) {
        refreshCommandRegistration();
        return running && commandRegistration.isCurrent(generation);
    }
    @Override public IBinder onBind(Intent intent) { return null; }

    private void loop() {
        int failures = 0;
        while (running) {
            try {
                SMSInboxScanner.scanIfDue(this);
                CommandRegistration current = refreshCommandRegistration();
                JSONObject registration = current.value();
                if (registration == null) {
                    update(store.registration() == null ? "Built-in Agent online · Waiting for iPhone pairing" : "Built-in Agent online · Cloud disabled");
                    Thread.sleep(2_000);
                    continue;
                }
                syncRegistration(registration);
                long now = System.currentTimeMillis();
                if (now - lastHeartbeat >= 30_000) sendHeartbeat(registration);
                flushEvents(registration);
                if (CommandPollingPolicy.shouldPoll(commandChannelConnected, lastCommandPoll, now)) {
                    lastCommandPoll = now;
                    pollCommands(registration, current.generation());
                }
                failures = 0;
                update("Built-in Agent online · Relay connected");
                Thread.sleep(2_000);
            } catch (InterruptedException interrupted) {
                Thread.currentThread().interrupt();
                return;
            } catch (Exception error) {
                failures++;
                store.recordError(error.getClass().getSimpleName() + ": " + error.getMessage());
                BridgeLog.error("standalone_agent_cycle_failed failures=" + failures, error);
                update("Built-in Agent reconnecting · " + failures);
                try { Thread.sleep(RelayRetryPolicy.delayMillis(failures, error)); }
                catch (InterruptedException interrupted) { Thread.currentThread().interrupt(); return; }
            }
        }
    }

    private void syncRegistration(JSONObject registration) throws Exception {
        int hash = registration.toString().hashCode();
        if (hash == syncedRegistrationHash) return;
        relay.postJSON(registration, "/v1/devices/register", new JSONObject(registration.toString()).put("registration_source", "agent"), 15_000);
        syncedRegistrationHash = hash;
        store.recordSuccess();
        BridgeLog.info("standalone_relay_registration_synced");
    }

    private void sendHeartbeat(JSONObject registration) throws Exception {
        boolean mediaReady = ShizukuBridgeManager.get(this).mediaAvailable();
        JSONObject heartbeat = StandaloneAgentStore.applyMediaHeartbeat(identity(registration), mediaReady)
                .put("event", "agent_heartbeat").put("agent_version", "standalone-0.1.0")
                .put("agent_id", registration.optString("android_agent_id", AndroidAgentIdentity.agentID(this)))
                .put("agent_kind", "standalone")
                .put("device_name", AndroidAgentIdentity.deviceName())
                .put("manufacturer", registration.optString("android_manufacturer", android.os.Build.MANUFACTURER))
                .put("model", registration.optString("android_model", android.os.Build.MODEL))
                .put("phone_number", AndroidAgentIdentity.phoneNumber(this))
                .put("at_ok", true).put("cellular_state", "registered")
                .put("cellular_registration", "Android Telecom")
                .put("cellular_recovery", "not_required").put("ecm_carrier", "android-default");
        relay.postJSON(registration, "/v1/events/heartbeat", heartbeat, 12_000);
        lastHeartbeat = System.currentTimeMillis();
        store.recordHeartbeat();
    }

    private void pollCommands(JSONObject registration, long generation) throws Exception {
        if (!isCurrentCommandRegistration(generation)) return;
        JSONObject batch = relay.postJSON(registration, "/v1/commands/pull", identity(registration), 12_000);
        JSONArray commands = batch.optJSONArray("commands");
        if (commands == null) return;
        for (int index = 0; index < commands.length(); index++) {
            if (!isCurrentCommandRegistration(generation)) return;
            JSONObject command = commands.getJSONObject(index);
            String commandID = command.optString("command_id", "").toLowerCase();
            if (commandID.isBlank() || completedCommands.contains(generation + ":" + commandID)) continue;
            JSONObject result;
            try {
                String expires = command.optString("expires_at", "");
                if (expires.isEmpty() || Instant.now().isAfter(Instant.parse(expires))) {
                    result = new JSONObject().put("command_id", commandID).put("status", "failed")
                            .put("error", "Cloud command expired");
                } else {
                    if (!isCurrentCommandRegistration(generation)) return;
                    result = StandaloneAgentGateway.get(this).executeCloudCommand(command);
                    if (!isCurrentCommandRegistration(generation)) return;
                    if (result.optString("status").equals("completed") && "dial".equals(command.optString("type"))) {
                        StandaloneCloudMediaManager.get(this).startOutgoing(command.optJSONObject("call"));
                    }
                }
            } catch (Exception error) {
                result = new JSONObject().put("command_id", commandID).put("status", "failed")
                        .put("error", DebugRedactor.sanitize(error.getMessage()));
            }
            if (!isCurrentCommandRegistration(generation)) return;
            JSONObject completion = identity(registration);
            for (String key : new String[]{"command_id", "status", "result", "error"}) {
                if (result.has(key)) completion.put(key, result.get(key));
            }
            relay.postJSON(registration, "/v1/commands/complete", completion, 12_000);
            rememberCompleted(generation + ":" + commandID);
        }
    }

    private void commandLoop() {
        int failures = 0;
        long retryGeneration = -1;
        while (running) {
            StandaloneWebSocket socket = null;
            Throwable failure = null;
            CommandRegistration current = refreshCommandRegistration();
            long generation = current.generation();
            if (generation != retryGeneration) {
                failures = 0;
                retryGeneration = generation;
            }
            try {
                JSONObject registration = current.value();
                if (registration == null) {
                    awaitCommandRetry(generation, 2_000);
                    continue;
                }
                URI relayURI = URI.create(registration.getString("relay_url"));
                String deviceID = URLEncoder.encode(registration.getString("device_id"), "UTF-8")
                        .replace("+", "%20");
                URI endpoint = URI.create("wss://" + relayURI.getRawAuthority()
                        + "/v1/devices/" + deviceID + "/commands/connect");
                socket = StandaloneWebSocket.connect(endpoint, registration.getString("device_secret"));
                synchronized (commandLock) {
                    if (!isCurrentCommandRegistration(generation)) continue;
                    commandSocket = socket;
                    commandChannelConnected = true;
                }
                failures = 0;
                socket.setReadTimeout(20_000);
                BridgeLog.info("standalone_command_channel_connected");
                while (isCurrentCommandRegistration(generation)) {
                    try {
                        StandaloneWebSocket.Message message = socket.read();
                        if (!isCurrentCommandRegistration(generation)) break;
                        if (message.opcode() != 1) continue;
                        JSONObject command = new JSONObject(new String(message.payload(), StandardCharsets.UTF_8));
                        if (!isCurrentCommandRegistration(generation)) break;
                        JSONObject result = StandaloneAgentGateway.get(this).executeCloudCommand(command);
                        if (!isCurrentCommandRegistration(generation)) break;
                        if (result.optString("status").equals("completed")
                                && "dial".equals(command.optString("type"))) {
                            StandaloneCloudMediaManager.get(this).startOutgoing(command.optJSONObject("call"));
                        }
                        if (!isCurrentCommandRegistration(generation)) break;
                        socket.writeText(result.toString());
                    } catch (SocketTimeoutException timeout) {
                        if (!isCurrentCommandRegistration(generation)) break;
                        socket.writePing("command-keepalive".getBytes(StandardCharsets.US_ASCII));
                    }
                }
            } catch (InterruptedException interrupted) {
                Thread.currentThread().interrupt();
                return;
            } catch (Exception error) {
                if (isCurrentCommandRegistration(generation)) {
                    failures++;
                    failure = error;
                    BridgeLog.error("standalone_command_channel_failed failures=" + failures, error);
                }
            } finally {
                synchronized (commandLock) {
                    if (commandSocket == socket) {
                        commandChannelConnected = false;
                        commandSocket = null;
                    }
                }
                if (socket != null) socket.close();
            }
            if (running) {
                try { awaitCommandRetry(generation, RelayRetryPolicy.delayMillis(failures, failure)); }
                catch (InterruptedException interrupted) { Thread.currentThread().interrupt(); return; }
            }
        }
    }

    private void awaitCommandRetry(long generation, long delayMillis) throws InterruptedException {
        long deadline = System.nanoTime() + delayMillis * 1_000_000L;
        synchronized (commandLock) {
            while (running && commandRegistration.generation() == generation) {
                long remaining = deadline - System.nanoTime();
                if (remaining <= 0) return;
                commandLock.wait(Math.max(1, remaining / 1_000_000L));
            }
        }
    }

    private void flushEvents(JSONObject registration) throws Exception {
        String encoded;
        while ((encoded = CALL_EVENTS.peek()) != null) {
            JSONObject event = new JSONObject(encoded);
            StandaloneCloudMediaManager.get(this).handleCallEvent(registration, event, relay);
            CALL_EVENTS.poll();
        }
        StandaloneSMSStore smsStore = new StandaloneSMSStore(this);
        JSONArray smsPending = smsStore.cloudPending();
        for (int index = 0; index < smsPending.length(); index++) {
            JSONObject source = smsPending.getJSONObject(index);
            JSONObject event = identity(registration).put("event", "incoming_sms")
                    .put("delivery_id", source.optString("delivery_id"))
                    .put("sender", source.optString("sender")).put("content", source.optString("content"))
                    .put("timestamp", source.optString("timestamp", Instant.now().toString()));
            relay.postJSON(registration, "/v1/events/sms", event, 12_000);
            smsStore.markCloudSent(source.getString("delivery_id"));
        }
    }

    private static JSONObject identity(JSONObject registration) throws Exception {
        return new JSONObject().put("device_id", registration.getString("device_id"))
                .put("device_secret", registration.getString("device_secret"));
    }

    private void rememberCompleted(String commandID) {
        completedCommands.add(commandID);
        while (completedCommands.size() > 128) {
            completedCommands.remove(completedCommands.iterator().next());
        }
    }

    private void update(String detail) {
        long now = System.currentTimeMillis();
        if (!notificationGate.shouldPublish(detail, now)) return;
        getSystemService(android.app.NotificationManager.class).notify(
                BridgeNotification.AGENT_ID, BridgeNotification.status(this, detail));
        notificationGate.published(detail, now);
    }

    @Override public void onDestroy() {
        running = false;
        preferences.unregisterOnSharedPreferenceChangeListener(registrationListener);
        synchronized (commandLock) {
            StandaloneWebSocket socket = commandSocket;
            if (socket != null) socket.closeAsync();
            commandLock.notifyAll();
        }
        worker.shutdownNow();
        StandaloneCloudMediaManager.get(this).close();
        BridgeLog.info("standalone_agent_destroyed");
        super.onDestroy();
    }
}
