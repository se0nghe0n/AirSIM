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

/** Standalone foreground Agent: Relay registration, heartbeat, command execution and SMS delivery. */
public final class StandaloneAgentService extends Service {
    private static final ConcurrentLinkedQueue<String> CALL_EVENTS = new ConcurrentLinkedQueue<>();
    private static final Object SMS_SIGNAL = new Object();
    private static boolean smsDeliveryRequested;
    private static boolean smsScanRequested;
    private final ExecutorService worker = Executors.newFixedThreadPool(3);
    private final Set<String> completedCommands = new LinkedHashSet<>();
    private final NotificationUpdateGate notificationGate = new NotificationUpdateGate();
    private volatile boolean running;
    private StandaloneAgentStore store;
    private StandaloneRelayClient relay;
    private int syncedRegistrationHash;
    private long lastHeartbeat;
    private boolean lastHeartbeatMediaReady;
    private long lastCommandPoll;
    private volatile StandaloneWebSocket commandSocket;
    private volatile boolean commandChannelConnected;
    private final Object commandLock = new Object();
    private final CommandRegistrationPolicy commandRegistration = new CommandRegistrationPolicy();
    private SharedPreferences preferences;
    private volatile android.database.ContentObserver inboxObserver;
    private String rejectedCallEvent;
    private long rejectedCallEventSince;
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

    /** A received SMS is durable in {@link StandaloneSMSStore}; wake the SMS lane to send it now. */
    static void requestSMSDelivery(Context context) {
        synchronized (SMS_SIGNAL) {
            smsDeliveryRequested = true;
            SMS_SIGNAL.notifyAll();
        }
        start(context);
    }

    /** The SMS/MMS provider changed; let the optional inbox fallback look before its 30 s cadence. */
    static void requestInboxScan() {
        synchronized (SMS_SIGNAL) {
            smsScanRequested = true;
            SMS_SIGNAL.notifyAll();
        }
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
        worker.execute(this::smsLoop);
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
                CommandRegistration current = refreshCommandRegistration();
                JSONObject registration = current.value();
                if (registration == null) {
                    update(store.registration() == null ? "Built-in Agent online · Waiting for iPhone pairing" : "Built-in Agent online · Cloud disabled");
                    Thread.sleep(2_000);
                    continue;
                }
                syncRegistration(registration);
                long now = System.currentTimeMillis();
                if (now - lastHeartbeat >= 30_000 || heartbeatMediaRecovered()) sendHeartbeat(registration);
                flushCallEvents(registration);
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
        lastHeartbeatMediaReady = mediaReady;
        store.recordSuccess();
    }

    /**
     * The Relay admits dial/answer from the latest heartbeat. If that heartbeat caught the
     * privileged service between calls, report its recovery on the next 2 s cycle, not 30 s later.
     */
    private boolean heartbeatMediaRecovered() {
        return lastHeartbeat != 0 && !lastHeartbeatMediaReady
                && ShizukuBridgeManager.get(this).mediaAvailable();
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
                    if (OutgoingDialAcceptance.completed(command.optString("type"), result.optString("status"))) {
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
                        if (OutgoingDialAcceptance.completed(command.optString("type"), result.optString("status"))) {
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

    /**
     * Publishes queued Telecom events in order. A transient failure leaves the event at the head
     * for the next cycle. An event the Relay keeps refusing permanently (4xx) is dropped after a
     * short grace period: before, it was retried forever and blocked every later call event and,
     * until the SMS lane, all incoming SMS behind it.
     */
    private void flushCallEvents(JSONObject registration) throws Exception {
        String encoded;
        while ((encoded = CALL_EVENTS.peek()) != null) {
            JSONObject event;
            try {
                event = new JSONObject(encoded);
            } catch (org.json.JSONException malformed) {
                BridgeLog.info("cloud_call_event_dropped reason=malformed");
                CALL_EVENTS.poll();
                continue;
            }
            try {
                StandaloneCloudMediaManager.get(this).handleCallEvent(registration, event, relay);
            } catch (RelayHTTPException rejected) {
                long now = System.currentTimeMillis();
                if (!encoded.equals(rejectedCallEvent)) {
                    rejectedCallEvent = encoded;
                    rejectedCallEventSince = now;
                }
                if (!CallLifecycleConflict.dropRejectedEvent(rejected.statusCode(), rejectedCallEventSince, now)) {
                    throw rejected;
                }
                BridgeLog.info("cloud_call_event_dropped status=" + rejected.statusCode()
                        + " state=" + DebugRedactor.safeIdentifier(event.optString("state")));
            }
            CALL_EVENTS.poll();
            rejectedCallEvent = null;
        }
    }

    /**
     * SMS lane. Runs independently of the Relay loop above, so heartbeats, call events and their
     * back-off never delay or block received messages. It also drives the optional inbox fallback.
     */
    private void smsLoop() {
        int failures = 0;
        long retryAt = 0;
        long lastPass = 0;
        boolean scanPending = false;
        while (running) {
            try {
                boolean requested;
                synchronized (SMS_SIGNAL) {
                    requested = smsDeliveryRequested;
                    scanPending |= smsScanRequested;
                    smsDeliveryRequested = false;
                    smsScanRequested = false;
                }
                // Read SMS may be granted after the service started.
                if (inboxObserver == null) {
                    inboxObserver = SMSInboxScanner.observe(this, StandaloneAgentService::requestInboxScan);
                    if (!running) SMSInboxScanner.unobserve(this, inboxObserver);
                }
                SMSInboxScanner.Result scan = SMSInboxScanner.scan(this, scanPending);
                if (scan.scanned()) scanPending = false;
                JSONObject registration = refreshCommandRegistration().value();
                long now = System.currentTimeMillis();
                long wait = Math.max(1, Math.min(SMSRelayPolicy.IDLE_WAIT_MILLIS, scan.nextScanMillis()));
                // New messages request a pass; otherwise retry on back-off, or check every 30 s.
                boolean due = retryAt != 0 ? now >= retryAt
                        : now - lastPass >= SMSRelayPolicy.IDLE_WAIT_MILLIS || now < lastPass;
                if (registration != null && (requested || due)) {
                    lastPass = now;
                    int status = deliverPendingSMS(registration);
                    if (SMSRelayPolicy.outcome(status) == SMSRelayPolicy.Outcome.RETRY) {
                        failures++;
                        long delay = SMSRelayPolicy.retryDelayMillis(failures);
                        retryAt = now + delay;
                        wait = Math.min(wait, delay);
                    } else {
                        failures = 0;
                        retryAt = 0;
                    }
                } else if (registration != null && retryAt > now) {
                    wait = Math.min(wait, retryAt - now);
                }
                awaitSMSSignal(wait);
            } catch (InterruptedException interrupted) {
                Thread.currentThread().interrupt();
                return;
            } catch (Exception error) {
                failures++;
                BridgeLog.error("cloud_sms_lane_failed failures=" + failures, error);
                retryAt = System.currentTimeMillis() + SMSRelayPolicy.retryDelayMillis(failures);
                try { awaitSMSSignal(SMSRelayPolicy.retryDelayMillis(failures)); }
                catch (InterruptedException interrupted) { Thread.currentThread().interrupt(); return; }
            }
        }
    }

    private void awaitSMSSignal(long delayMillis) throws InterruptedException {
        long deadline = System.nanoTime() + Math.max(1, delayMillis) * 1_000_000L;
        synchronized (SMS_SIGNAL) {
            while (running && !smsDeliveryRequested && !smsScanRequested) {
                long remaining = deadline - System.nanoTime();
                if (remaining <= 0) return;
                SMS_SIGNAL.wait(Math.max(1, remaining / 1_000_000L));
            }
        }
    }

    /**
     * Sends cloud-pending SMS oldest first. Delivered and permanently rejected messages leave the
     * cloud queue; local VoWLAN delivery and acknowledgement remain independent. A device-wide
     * failure (network, credentials, missing iPhone token, rate limit) ends the pass. A 5xx may be
     * specific to one message, so the pass moves on and that message is retried on the next pass.
     *
     * @return 200 when every message was sent or rejected, otherwise a status to back off on.
     */
    private int deliverPendingSMS(JSONObject registration) throws Exception {
        StandaloneSMSStore smsStore = new StandaloneSMSStore(this);
        JSONArray pending = smsStore.cloudPending();
        int retryStatus = 200;
        int consecutiveMessageFailures = 0;
        for (int index = 0; index < pending.length() && running; index++) {
            JSONObject source = pending.getJSONObject(index);
            String deliveryID = source.getString("delivery_id");
            long now = System.currentTimeMillis();
            JSONObject event = identity(registration).put("event", "incoming_sms")
                    .put("delivery_id", deliveryID)
                    .put("sender", source.optString("sender"))
                    .put("content", SMSRelayPolicy.cloudContent(source.optString("content")))
                    .put("timestamp", SMSRelayPolicy.cloudTimestamp(source.optString("timestamp"), now));
            int status;
            try {
                status = relay.post(registration, "/v1/events/sms", event, 12_000).status();
            } catch (java.io.IOException network) {
                status = 0;
            }
            String safeID = DebugRedactor.safeIdentifier(deliveryID);
            switch (SMSRelayPolicy.outcome(status)) {
                case DELIVERED -> {
                    consecutiveMessageFailures = 0;
                    smsStore.markCloudSent(deliveryID);
                    SMSRelayStatus.delivered(System.currentTimeMillis());
                    BridgeLog.info("cloud_sms_delivered delivery_id=" + safeID);
                }
                case REJECTED -> {
                    consecutiveMessageFailures = 0;
                    smsStore.markCloudRejected(deliveryID);
                    SMSRelayStatus.rejected(status);
                    BridgeLog.info("cloud_sms_rejected status=" + status + " delivery_id=" + safeID);
                }
                case RETRY -> {
                    retryStatus = status;
                    SMSRelayStatus.failed(status);
                    BridgeLog.info("cloud_sms_retry status=" + status + " delivery_id=" + safeID
                            + " pending=" + (pending.length() - index));
                    if (SMSRelayPolicy.stopsPass(status)
                            || ++consecutiveMessageFailures >= SMSRelayPolicy.MAX_MESSAGE_FAILURES_PER_PASS) {
                        return status;
                    }
                }
            }
        }
        return retryStatus;
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
        SMSInboxScanner.unobserve(this, inboxObserver);
        synchronized (SMS_SIGNAL) { SMS_SIGNAL.notifyAll(); }
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
