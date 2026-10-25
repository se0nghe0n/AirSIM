package com.airsim.phonecontrol;

import android.content.Intent;
import android.net.Uri;
import android.telecom.Call;
import android.telecom.InCallService;
import android.os.Handler;
import android.os.Looper;

import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.atomic.AtomicLong;

public final class AirSIMInCallService extends InCallService {
    private static volatile AirSIMInCallService instance;
    private static final Handler MAIN = new Handler(Looper.getMainLooper());
    private final ExecutorService network = Executors.newSingleThreadExecutor();
    private final Map<Call, Call.Callback> callbacks = new ConcurrentHashMap<>();
	private final Map<Call, String> callStates = new ConcurrentHashMap<>();
    private final AtomicLong events = new AtomicLong();
    private final CallEventDeduplicator deduplicator = new CallEventDeduplicator();
	private LocalCallAudioController localAudio;

    @Override
    public void onCallAdded(Call call) {
        super.onCallAdded(call);
		instance = this;
		if (localAudio == null) localAudio = new LocalCallAudioController(this);
        String callId = CallRepository.add(call);
        StandaloneCloudMediaManager.get(this).attachTelecomCall(callId, direction(call));
        BridgeLog.info("telecom_call_added call_id=" + DebugRedactor.safeIdentifier(callId)
                + " direction=" + direction(call) + " state=" + TelecomStateMapper.toWireState(call.getState()));
        Call.Callback callback = new Call.Callback() {
            @Override public void onStateChanged(Call changed, int state) { emit(changed, state); }
            @Override public void onDetailsChanged(Call changed, Call.Details details) { emit(changed, changed.getState()); }
        };
        callbacks.put(call, callback);
        call.registerCallback(callback);
        StandaloneAgentService.start(this);
        emit(call, call.getState());
    }

    @Override
    public void onCallRemoved(Call call) {
        String callId = CallRepository.id(call);
        StandaloneCloudMediaManager.get(this).detachTelecomCall(callId);
        BridgeLog.info("telecom_call_removed call_id=" + DebugRedactor.safeIdentifier(callId));
        emit(callId, direction(call), "ended", number(call));
		deduplicator.remove(callId);
		callStates.remove(call);
		updateLocalAudioPolicy();
        Call.Callback callback = callbacks.remove(call);
        if (callback != null) call.unregisterCallback(callback);
        CallRepository.remove(call);
        BridgeNotification.clearCall(this, callId);
        super.onCallRemoved(call);
    }

    private void emit(Call call, int state) {
        String wireState = TelecomStateMapper.toWireState(state);
		callStates.put(call, wireState);
		updateLocalAudioPolicy();
        String callId = CallRepository.id(call);
        String callDirection = direction(call);
        String callNumber = number(call);
        BridgeNotification.showCall(this, callId, callDirection, AppConfig.mode(this), wireState);
        BridgeLog.debug("telecom_state_changed call_id=" + DebugRedactor.safeIdentifier(callId)
                + " direction=" + callDirection + " state=" + wireState);
        if (!"unknown".equals(wireState) && deduplicator.shouldSend(callId, callDirection, wireState, callNumber)) {
			emit(callId, callDirection, wireState, callNumber);
		}
    }

	private void updateLocalAudioPolicy() {
		if (localAudio == null) return;
		String mode = AppConfig.mode(this);
		boolean shouldSilence = RemoteAudioSessionRegistry.active();
		for (String state : callStates.values()) {
			if (TelecomStateMapper.shouldSilenceLocalOutput(mode, state)) {
				shouldSilence = true;
				break;
			}
		}
		localAudio.update(shouldSilence);
	}

    public static void refreshAudioPolicy() {
        AirSIMInCallService active = instance;
        if (active != null) MAIN.post(active::updateLocalAudioPolicy);
    }

    private void emit(String callId, String direction, String state, String number) {
        String eventId = Long.toString(System.currentTimeMillis()) + "-" + events.incrementAndGet();
        String json = WireJson.callEvent(eventId, callId, direction, state, number, AppConfig.mode(this));
        network.execute(() -> {
            try {
                new AgentClient(this).sendEvent(json);
                BridgeLog.info("call_event_sent state=" + state + " call_id=" + DebugRedactor.safeIdentifier(callId));
            } catch (Exception error) {
                BridgeLog.error("call_event_failed state=" + state, error);
            }
        });
    }

    private static String direction(Call call) {
        if (call.getState() == Call.STATE_RINGING) return "incoming";
        Call.Details details = call.getDetails();
        return details != null && details.getCallDirection() == Call.Details.DIRECTION_INCOMING ? "incoming" : "outgoing";
    }

    private static String number(Call call) {
        Call.Details details = call.getDetails();
        Uri handle = details == null ? null : details.getHandle();
        return handle == null || handle.getSchemeSpecificPart() == null ? "" : handle.getSchemeSpecificPart();
    }

    @Override public void onDestroy() {
		BridgeLog.info("incall_service_destroyed");
		if (localAudio != null) localAudio.update(false);
        if (instance == this) instance = null;
        network.shutdownNow();
        super.onDestroy();
    }
}
