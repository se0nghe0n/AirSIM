import Foundation
import WatchConnectivity

/// Mirrors iPhone call state and proxies dialing for cloud calls initiated from Apple Watch.
/// Dialing and answer controls stay on WCSession. Both cloud and local VoWLAN audio are carried by the iPhone WebRTC peer.
final class WatchCallCoordinator: NSObject, WCSessionDelegate {
    static let shared = WatchCallCoordinator()

    private var session: WCSession?
    private var lastPayload: WatchCallPayload?
    private var lastCloudMediaAllowed: Bool?
    private var pendingWatchDialID: UUID?
    private var cancelledWatchDialIDs = Set<UUID>()
    private var watchOutgoingCall: (requestID: UUID, call: IncomingVoIPCall)?
    private var cloudWatchIdentity: (callID: String, uuid: UUID)?
    private weak var model: AppModel?
    private struct LocalWatchCall {
        let requestID: UUID?
        let callID: String
        let uuid: UUID
        let api: AirSIMAPI
    }
    private var localWatchCall: LocalWatchCall?
    private var localEndInFlight: String?

    @MainActor
    func configure(model: AppModel) { self.model = model }

    @MainActor
    func refreshMediaPolicy() {
        lastCloudMediaAllowed = nil
        if let lastPayload { publish(lastPayload) }
    }

    @MainActor
    func ownsMedia(callID: String?) -> Bool {
        if pendingWatchDialID != nil { return true }
        guard let callID else { return false }
        return watchOutgoingCall?.call.callID == callID
    }

    func start() {
        guard WCSession.isSupported() else { return }
        if session == nil {
            let session = WCSession.default
            session.delegate = self
            session.activate()
            self.session = session
#if DEBUG
			print("[AirSIM iPhone WC] Activation requested; paired=\(session.isPaired) watchAppInstalled=\(session.isWatchAppInstalled)")
#endif
        }
    }

    @MainActor
    func publish(
        call: CallRecord?, previous: CallRecord?, callerName: String?,
        transport: String? = nil
    ) {
        start()
        let phase: WatchCallPhase
        if let call {
            switch call.state {
            case "incoming", "waiting": phase = .incoming
            case "active", "held": phase = .active
            default: phase = .connecting
            }
        } else {
            phase = previous == nil ? .idle : .ended
        }
        let identityCall = call ?? previous
        let payload = WatchCallPayload(
            callID: identityCall?.id ?? "",
            callUUID: CallKitController.shared.watchCallUUID(for: identityCall?.id),
            phase: phase,
            number: identityCall?.number,
            callerName: callerName,
            transport: transport,
            updatedAt: identityCall?.updatedAt ?? Date()
        )
        publish(payload)
    }

    @MainActor
    func publishIncoming(
        _ call: IncomingVoIPCall, callerName: String? = nil,
        transport: String? = nil
    ) {
        start()
        publish(WatchCallPayload(
            callID: call.callID,
            callUUID: call.uuid,
            phase: .incoming,
            number: call.number,
            callerName: callerName ?? call.callerName,
            transport: transport,
            updatedAt: Date()
        ))
    }

    @MainActor
    private func publish(_ payload: WatchCallPayload) {
        if payload.phase == .ended, localWatchCall?.callID == payload.callID {
            localWatchCall = nil
        }
        if payload.phase == .ended
            && (payload.callID == watchOutgoingCall?.call.callID
                || payload.callID == cloudWatchIdentity?.callID) {
            watchOutgoingCall = nil
            cloudWatchIdentity = nil
        }
        if let lastPayload,
           lastCloudMediaAllowed == CloudModePreference.isEnabled(),
           lastPayload.callID == payload.callID,
           lastPayload.callUUID == payload.callUUID,
           lastPayload.phase == payload.phase,
           lastPayload.number == payload.number,
           lastPayload.callerName == payload.callerName,
           lastPayload.transport == payload.transport {
            return
        }
        lastPayload = payload
        lastCloudMediaAllowed = CloudModePreference.isEnabled()
        guard let session, session.activationState == .activated else { return }
        var dictionary = payload.dictionary
        dictionary["cloud_media_allowed"] = CloudModePreference.isEnabled()
        try? session.updateApplicationContext(dictionary)
        if session.isReachable {
            session.sendMessage(dictionary, replyHandler: nil, errorHandler: nil)
        }
        // State transitions use background queueing so the Watch app converges on next wake even if not currently running;
        // real-time answer/reject actions bypass the queue so delayed actions cannot affect the next call.
        session.transferUserInfo(dictionary)
    }

    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
#if DEBUG
		print("[AirSIM iPhone WC] Activation completed; state=\(activationState.rawValue) context=\(session.receivedApplicationContext["event"] as? String ?? "none") error=\(error?.localizedDescription ?? "none")")
#endif
		guard activationState == .activated,
			  !session.receivedApplicationContext.isEmpty else { return }
		let context = session.receivedApplicationContext
		Task { @MainActor in
			_ = self.consumeWatchRegistration(context) || self.consumeWatchOwnership(context)
		}
	}

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        Task { @MainActor in
            if self.consumeWatchRegistration(message) {
                replyHandler(["ok": true])
                return
            }
            if self.consumeWatchOwnership(message) {
                replyHandler(["ok": true])
                return
            }
            guard let action = message["action"] as? String else {
                replyHandler(["ok": false, "error": "missing_action"])
                return
            }
            if action == "status" {
                if let payload = self.lastPayload {
                    replyHandler(payload.dictionary.merging([
                        "ok": true, "cloud_media_allowed": CloudModePreference.isEnabled(),
                    ]) { _, new in new })
                } else {
                    replyHandler(["ok": true, "event": "watch_call_state", "call_id": "", "call_uuid": "", "phase": "idle", "updated_at": Date().timeIntervalSince1970,
                                  "cloud_media_allowed": CloudModePreference.isEnabled()])
                }
                return
            }
            if action == "dial" {
                await self.dialFromWatch(message, replyHandler: replyHandler)
                return
            }
            if action == "cancel_dial" {
                self.cancelWatchDial(message)
                replyHandler(["ok": true])
                return
            }
            if action == "watch_local_answer" {
                await self.answerLocallyFromWatch(message, replyHandler: replyHandler)
                return
            }
            if action == "end" || action == "reject",
               await self.finishOwnedCloudCall(message) {
                replyHandler(["ok": true])
                return
            }
            if action == "watch_local_end" {
                await self.endLocalWatchCall(message, replyHandler: replyHandler)
                return
            }
            if action == "watch_local_reject" {
                await self.rejectLocalWatchCall(message, replyHandler: replyHandler)
                return
            }
            let callID = message["call_id"] as? String
            let uuid = (message["call_uuid"] as? String).flatMap(UUID.init(uuidString:))
            guard CallKitController.shared.matchesCurrentCall(callID: callID, uuid: uuid) else {
                replyHandler(["ok": false, "error": "stale_call"])
                return
            }
            do {
                switch action {
                case "answer": try await CallKitController.shared.answerCurrentCall()
                case "reject", "end": try await CallKitController.shared.endCurrentCall()
                default:
                    replyHandler(["ok": false, "error": "unsupported_action"])
                    return
                }
                replyHandler(["ok": true])
            } catch {
                replyHandler(["ok": false, "error": error.localizedDescription])
            }
        }
    }

    @MainActor
    private func dialFromWatch(
        _ message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) async {
        guard let requestID = (message["request_id"] as? String).flatMap(UUID.init(uuidString:)),
              let number = (message["number"] as? String).flatMap(WatchDialNumber.validated) else {
            replyHandler(["ok": false, "error": "Enter a valid phone number"])
            return
        }
        guard pendingWatchDialID == nil, watchOutgoingCall == nil, localWatchCall == nil,
              CallKitController.shared.currentSystemCallUUID == nil else {
            replyHandler(["ok": false, "error": "A call or dial request is already in progress"])
            return
        }
        if cancelledWatchDialIDs.remove(requestID) != nil {
            replyHandler(["ok": false, "error": "Call canceled"])
            return
        }
        pendingWatchDialID = requestID
        defer { pendingWatchDialID = nil; cancelledWatchDialIDs.remove(requestID) }
        do {
            if let model, let (api, pcmRoute) = await model.readyVoWLANRoute(),
               case .vowlan = pcmRoute {
                guard !cancelledWatchDialIDs.contains(requestID) else {
                    replyHandler(["ok": false, "error": "Call canceled"])
                    return
                }
                try await api.dial(number: number)
                guard let record = await waitForOutgoingCall(api: api, number: number) else {
                    try? await api.hangupCall()
                    replyHandler(["ok": false, "error": "VoWLAN did not confirm the call status"])
                    return
                }
                if cancelledWatchDialIDs.contains(requestID) {
                    try? await api.hangupCall(callID: record.id)
                    replyHandler(["ok": false, "error": "Call canceled"])
                    return
                }
                let uuid = UUID()
                localWatchCall = LocalWatchCall(
                    requestID: requestID, callID: record.id, uuid: uuid, api: api
                )
                monitorLocalAudio(callID: record.id, api: api)
                replyHandler([
                    "ok": true, "request_id": requestID.uuidString,
                    "call_id": record.id, "call_uuid": uuid.uuidString,
                    "number": number, "media_route": "vowlan",
                    "media_transport": WatchCloudAudioPlan.requestedTransport,
                    "expires_at": Date().addingTimeInterval(300).timeIntervalSince1970,
                ])
                return
            }
            guard CloudModePreference.isEnabled() else {
                replyHandler(["ok": false, "error": "VoWLAN is unreachable and cloud mode is disabled"])
                return
            }
            let status = try await VoIPPushController.shared.fetchCloudAgentStatus()
            guard status.cloudOnline else { throw CloudCommandError.unavailable }
            guard !cancelledWatchDialIDs.contains(requestID) else {
                replyHandler(["ok": false, "error": "Call canceled"])
                return
            }
            // When no verified local VoWLAN is available, audio is carried by the iPhone WebRTC peer.
            guard let requested = CloudMediaTransport(rawValue: WatchCloudAudioPlan.requestedTransport),
                  requested == .webRTC else {
                replyHandler(["ok": false, "error": "Watch audio requires WebRTC"])
                return
            }
            let outgoing = try await VoIPPushController.shared.startCloudOutgoingCall(
                number: number, mediaTransport: requested, timeout: 15
            )
            guard !cancelledWatchDialIDs.contains(requestID) else {
                await abandonCloudCall(outgoing)
                replyHandler(["ok": false, "error": "Call canceled"])
                return
            }
            guard WatchCloudAudioPlan.accepts(transport: outgoing.requestedMediaTransport.rawValue) else {
                await abandonCloudCall(outgoing)
                replyHandler(["ok": false, "error": "The iPhone WebRTC audio path is unavailable"])
                return
            }
            do {
                try await IPhoneCloudCallSession.shared.answer(outgoing)
                IPhoneCloudCallSession.shared.startAudioWithRetry()
            } catch {
                await abandonCloudCall(outgoing)
                replyHandler(["ok": false, "error": error.localizedDescription])
                return
            }
            guard !cancelledWatchDialIDs.contains(requestID) else {
                await abandonCloudCall(outgoing)
                replyHandler(["ok": false, "error": "Call canceled"])
                return
            }
            watchOutgoingCall = (requestID, outgoing)
            cloudWatchIdentity = (outgoing.callID, outgoing.uuid)
            replyHandler(WatchCloudAudioPlan.dialReply(
                requestID: requestID,
                callID: outgoing.callID,
                callUUID: outgoing.uuid,
                number: number,
                expiresAt: outgoing.expiresAt ?? Date().addingTimeInterval(300)
            ))
        } catch {
            replyHandler(["ok": false, "error": error.localizedDescription])
        }
    }

    @MainActor
    private func cancelWatchDial(_ message: [String: Any]) {
        guard let requestID = (message["request_id"] as? String).flatMap(UUID.init(uuidString:)) else { return }
        if cancelledWatchDialIDs.count >= 20 { cancelledWatchDialIDs.removeAll() }
        cancelledWatchDialIDs.insert(requestID)
        if let active = localWatchCall, active.requestID == requestID {
            Task { @MainActor in
                do {
                    try await active.api.hangupCall(callID: active.callID)
                    if localWatchCall?.callID == active.callID { localWatchCall = nil }
                } catch {
                    NSLog("[AirSIM Watch Dial] VoWLAN cancel failed: %@", error.localizedDescription)
                }
            }
        }
        if let active = watchOutgoingCall, active.requestID == requestID {
            watchOutgoingCall = nil
            cloudWatchIdentity = nil
            cancelledWatchDialIDs.remove(requestID)
            Task { await self.abandonCloudCall(active.call) }
        }
    }

    @MainActor
    private func waitForOutgoingCall(api: AirSIMAPI, number: String) async -> CallRecord? {
        for _ in 0..<12 {
            if let call = try? await api.callStatus().active,
               call.direction == "outgoing", call.number == nil || call.number == number {
                return call
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return nil
    }

    @MainActor
    private func answerLocallyFromWatch(
        _ message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void
    ) async {
        guard let callID = message["call_id"] as? String, !callID.isEmpty,
              let uuid = (message["call_uuid"] as? String).flatMap(UUID.init(uuidString:)),
              localWatchCall == nil, let model,
              let (api, pcmRoute) = await model.readyVoWLANRoute(),
              case .vowlan = pcmRoute else {
            replyHandler(["ok": false, "error": "VoWLAN is not ready",
                          "cloud_media_allowed": CloudModePreference.isEnabled()])
            return
        }
        do {
            guard let current = try await api.callStatus().active,
                  current.id == callID,
                  ["incoming", "waiting"].contains(current.state) else {
                replyHandler(["ok": false, "error": "This incoming call is no longer available",
                              "cloud_media_allowed": CloudModePreference.isEnabled()])
                return
            }
            localWatchCall = LocalWatchCall(requestID: nil, callID: callID, uuid: uuid, api: api)
            do {
                try await api.answerCall(callID: current.id)
            } catch {
                localWatchCall = nil
                throw error
            }
            if CallKitController.shared.matchesCurrentCall(callID: callID, uuid: nil) {
                CallKitController.shared.reportCurrentCallEnded(reason: .answeredElsewhere)
            }
            monitorLocalAudio(callID: callID, api: api)
            replyHandler([
                "ok": true, "call_id": callID, "call_uuid": uuid.uuidString,
                "media_route": "vowlan",
                "media_transport": WatchCloudAudioPlan.requestedTransport,
                "cloud_media_allowed": CloudModePreference.isEnabled(),
            ])
        } catch {
            replyHandler(["ok": false, "error": error.localizedDescription,
                          "cloud_media_allowed": CloudModePreference.isEnabled()])
        }
    }

    @MainActor
    private func endLocalWatchCall(
        _ message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void
    ) async {
        guard let call = localWatchCall,
              message["call_id"] as? String == call.callID,
              message["call_uuid"] as? String == call.uuid.uuidString else {
            replyHandler(["ok": false, "error": "stale_call"])
            return
        }
        guard localEndInFlight != call.callID else {
            replyHandler(["ok": true])
            return
        }
        localEndInFlight = call.callID
        defer { localEndInFlight = nil }
        do {
            try await call.api.hangupCall(callID: call.callID)
            if localWatchCall?.callID == call.callID { localWatchCall = nil }
            replyHandler(["ok": true])
        } catch {
            replyHandler(["ok": false, "error": error.localizedDescription])
        }
    }

    @MainActor
    private func rejectLocalWatchCall(
        _ message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void
    ) async {
        guard let callID = message["call_id"] as? String, !callID.isEmpty,
              let model, let (api, _) = await model.readyVoWLANRoute() else {
            replyHandler(["ok": false, "error": "VoWLAN is not ready"])
            return
        }
        do {
            guard let current = try await api.callStatus().active,
                  current.id == callID,
                  ["incoming", "waiting"].contains(current.state) else {
                replyHandler(["ok": false, "error": "This incoming call is no longer available"])
                return
            }
            _ = try await api.rejectCall(callID: current.id)
            replyHandler(["ok": true])
        } catch {
            replyHandler(["ok": false, "error": error.localizedDescription])
        }
    }

    @MainActor
    private func monitorLocalAudio(callID: String, api: AirSIMAPI) {
        Task { @MainActor in
            for _ in 0..<120 {
                guard localWatchCall?.callID == callID else { return }
                if let current = try? await api.callStatus().active {
                    guard current.id == callID else { return }
                    if current.state == "active" {
                        let outcome = try? await CallAudioRegistrationCoordinator.register(service: api)
                        if outcome == .registered { return }
                    }
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
            NSLog("[AirSIM Watch] VoWLAN audio host registration timed out; call=%@", callID)
        }
    }

    @MainActor
    private func finishOwnedCloudCall(_ message: [String: Any]) async -> Bool {
        guard message["action"] as? String == "end" || message["action"] as? String == "reject",
              let callID = message["call_id"] as? String,
              let identity = cloudWatchIdentity,
              identity.callID == callID else { return false }
        cloudWatchIdentity = nil
        watchOutgoingCall = nil
        if IPhoneCloudCallSession.shared.call?.callID == callID {
            await IPhoneCloudCallSession.shared.end()
        }
        if CallKitController.shared.matchesCurrentCall(callID: identity.callID, uuid: identity.uuid) {
            try? await CallKitController.shared.endCurrentCall()
        }
        return true
    }

    @MainActor
    private func abandonCloudCall(_ call: IncomingVoIPCall) async {
        if IPhoneCloudCallSession.shared.call?.uuid == call.uuid {
            await IPhoneCloudCallSession.shared.end()
            return
        }
        await endAbandonedWatchCall(call)
    }

    @MainActor
    private func endAbandonedWatchCall(_ call: IncomingVoIPCall) async {
        guard let credentials = VoIPPushController.shared.cloudCallControlCredentials() else { return }
        let envelope = CloudCallControlEnvelope(
            action: "end", callID: call.callID, callUUID: call.uuid.uuidString.lowercased(),
            generation: call.generation, commandID: UUID().uuidString.lowercased(),
            traceID: "watch-dial-abort-\(UUID().uuidString.lowercased())"
        )
        do {
            let receipt = try await CloudCallControlClient.submit(envelope: envelope, credentials: credentials)
            Task {
                do {
                    let final = receipt.isFinal ? receipt : try await CloudCallControlClient.awaitFinalReceipt(
                        envelope: envelope, credentials: credentials
                    )
                    if final.status != "completed" || final.result?.ended != true {
                        NSLog("[AirSIM Watch Dial] Module did not confirm hangup: %@", final.error ?? final.status)
                    }
                } catch {
                    NSLog("[AirSIM Watch Dial] Failed waiting for module hangup confirmation: %@", error.localizedDescription)
                }
            }
        } catch {
            // A dialed call whose handoff failed must remain diagnosable and never silently leave a cellular call behind.
            NSLog("[AirSIM Watch Dial] Failed to cancel outgoing call: %@", error.localizedDescription)
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        Task { @MainActor in
            if message["action"] as? String == "cancel_dial" {
                self.cancelWatchDial(message)
                return
            }
            if await self.finishOwnedCloudCall(message) { return }
            if message["action"] as? String == "watch_local_end" {
                await self.endLocalWatchCall(message, replyHandler: { _ in })
                return
            }
            if message["action"] as? String == "watch_local_reject" {
                await self.rejectLocalWatchCall(message, replyHandler: { _ in })
                return
            }
            _ = self.consumeWatchRegistration(message) || self.consumeWatchOwnership(message)
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        Task { @MainActor in
            if await self.finishOwnedCloudCall(userInfo) { return }
            if userInfo["action"] as? String == "watch_local_end" {
                await self.endLocalWatchCall(userInfo, replyHandler: { _ in })
                return
            }
            if userInfo["action"] as? String == "watch_local_reject" {
                await self.rejectLocalWatchCall(userInfo, replyHandler: { _ in })
                return
            }
            _ = self.consumeWatchRegistration(userInfo) || self.consumeWatchOwnership(userInfo)
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveApplicationContext applicationContext: [String: Any]
    ) {
        Task { @MainActor in
            if await self.finishOwnedCloudCall(applicationContext) { return }
            if applicationContext["action"] as? String == "watch_local_end" {
                await self.endLocalWatchCall(applicationContext, replyHandler: { _ in })
                return
            }
            if applicationContext["action"] as? String == "watch_local_reject" {
                await self.rejectLocalWatchCall(applicationContext, replyHandler: { _ in })
                return
            }
            _ = self.consumeWatchRegistration(applicationContext) || self.consumeWatchOwnership(applicationContext)
        }
    }

    @MainActor
    private func consumeWatchRegistration(_ message: [String: Any]) -> Bool {
        guard message["event"] as? String == "watch_voip_registration",
              let token = message["watch_voip_token"] as? String,
              let bundleID = message["watch_bundle_id"] as? String,
              !token.isEmpty, !bundleID.isEmpty else { return false }
        VoIPPushController.shared.storeWatchVoIPRegistration(token: token, bundleID: bundleID)
#if DEBUG
		print("[AirSIM iPhone WC] Received Watch VoIP token; length=\(token.count)")
#endif
        return true
    }

    @MainActor
    private func consumeWatchOwnership(_ message: [String: Any]) -> Bool {
        guard message["event"] as? String == "watch_call_owner",
              let phase = message["phase"] as? String else { return false }
        let callID = message["call_id"] as? String
        let uuid = (message["call_uuid"] as? String).flatMap(UUID.init(uuidString:))
        if let active = watchOutgoingCall, active.call.callID == callID,
           phase == WatchCallPhase.ended.rawValue {
            let call = active.call
            watchOutgoingCall = nil
            Task { await self.abandonCloudCall(call) }
        }
        guard CallKitController.shared.matchesCurrentCall(callID: callID, uuid: uuid) else { return true }
        if phase == WatchCallPhase.active.rawValue {
            CallKitController.shared.reportCurrentCallEnded(reason: .answeredElsewhere)
        } else if phase == WatchCallPhase.ended.rawValue {
            CallKitController.shared.reportCurrentCallEnded(reason: .declinedElsewhere)
        }
        return true
    }
}
