import AVFoundation
import CallKit
import Foundation
import PushKit
import WatchConnectivity

/// Apple Watch 注册 VoIP Push 并上报 CallKit。拨号和接听控制走 WCSession。
/// 云端音频留在 iPhone 的 WebRTC peer；手表不打开 PCM WebSocket，也不发送 PCM 上行。
/// 本地 VoWLAN 音频由 iPhone 的 WebRTC peer 承载。
final class WatchCallSession: NSObject, ObservableObject {
    @Published private(set) var call = WatchCallPayload(
        callID: "", callUUID: nil, phase: .idle, number: nil,
        callerName: nil, updatedAt: Date()
    )
    @Published private(set) var isSendingAction = false
    @Published private(set) var isDialing = false
    @Published var errorMessage: String?
	@Published private(set) var pushStatus = "Registering Watch VoIP…"
	@Published private(set) var microphoneStatus = "Checking microphone access…"

    private let provider: CXProvider
    private let callController = CXCallController()
    private let media = WatchCallMediaBridge()
    private var pushRegistry: PKPushRegistry!
    private var connectivity: WCSession?
    private var voIPCall: WatchVoIPCall?
    private var answered = false
    private var answering = false
    private var dialRequestID: UUID?
    private var activeDialRequestID: UUID?
	private var pendingWatchToken: Data?
    private var endedCallIDs = Set<String>()
    private let cloudMediaPreferenceKey = "airsim.watch.cloud-media-allowed"

    private var cloudMediaAllowed: Bool {
        UserDefaults.standard.bool(forKey: cloudMediaPreferenceKey)
    }

    override init() {
        let configuration = CXProviderConfiguration()
        configuration.supportsVideo = false
        configuration.maximumCallGroups = 1
        configuration.maximumCallsPerCallGroup = 1
        configuration.supportedHandleTypes = [.phoneNumber, .generic]
        provider = CXProvider(configuration: configuration)
        super.init()

		requestMicrophonePermissionIfNeeded()

        provider.setDelegate(self, queue: .main)
        media.onRemoteEnded = { [weak self] in
            DispatchQueue.main.async { self?.finishRemoteCall() }
        }
        media.onStatus = { [weak self] status in
            DispatchQueue.main.async { self?.handleMediaStatus(status) }
        }

        let registry = PKPushRegistry(queue: .main)
        registry.delegate = self
        pushRegistry = registry
		registry.desiredPushTypes = [.voIP]

        if WCSession.isSupported() {
            let session = WCSession.default
            session.delegate = self
            session.activate()
            connectivity = session
        }
    }

    var displayName: String {
        if let name = call.callerName, !name.isEmpty { return name }
        if let number = call.number, !number.isEmpty { return number }
        return "AirSIM"
    }

    var secondaryText: String {
        guard let number = call.number, number != displayName else {
            return call.phase == .idle ? "Waiting for a module call" : "Apple Watch Voice"
        }
        return number
    }

    func requestLatestState() {
        guard let connectivity, connectivity.isReachable else { return }
        connectivity.sendMessage(["action": "status"], replyHandler: { [weak self] reply in
            self?.receiveMirror(reply)
        }, errorHandler: nil)
    }

    func answer() { request(answer: true) }
    func reject() { request(answer: false) }
    func end() { request(answer: false) }

    func dial(_ input: String) {
        guard let number = WatchDialNumber.validated(input) else {
            errorMessage = "Enter a valid phone number"
            return
        }
        guard voIPCall == nil, call.phase == .idle || call.phase == .ended,
              !isDialing else {
            errorMessage = "End the current call first"
            return
        }
        guard microphoneStatus == "Microphone access granted" else {
            errorMessage = "Allow microphone access on your watch first"
            return
        }
        guard let connectivity, connectivity.isReachable else {
            errorMessage = "Open AirSIM on your nearby paired iPhone first"
            return
        }
        let requestID = UUID()
        dialRequestID = requestID
        isDialing = true
        errorMessage = nil
        connectivity.sendMessage([
            "action": "dial", "request_id": requestID.uuidString, "number": number,
        ], replyHandler: { [weak self] reply in
            DispatchQueue.main.async { self?.receiveDialReply(reply, requestID: requestID) }
        }, errorHandler: { [weak self] error in
            DispatchQueue.main.async {
                guard let self, self.dialRequestID == requestID else { return }
                self.dialRequestID = nil
                self.isDialing = false
                self.errorMessage = "iPhone did not respond to the call request: \(error.localizedDescription)"
                self.abortCompanionDial(requestID)
            }
        })
    }

    func cancelDial() {
        guard let requestID = dialRequestID else { return }
        dialRequestID = nil
        isDialing = false
        abortCompanionDial(requestID)
    }

    private func receiveDialReply(_ reply: [String: Any], requestID: UUID) {
        guard dialRequestID == requestID else {
            if reply["ok"] as? Bool == true { abortCompanionDial(requestID) }
            return
        }
        dialRequestID = nil
        isDialing = false
        guard reply["ok"] as? Bool == true else {
            errorMessage = reply["error"] as? String ?? "Unable to start a watch call"
            return
        }
        guard reply["request_id"] as? String == requestID.uuidString else {
            errorMessage = "The call response does not match the request"
            abortCompanionDial(requestID)
            return
        }
        do {
            let outgoing = try WatchVoIPCall(outgoingReply: reply)
            voIPCall = outgoing
            activeDialRequestID = requestID
            answered = false
            publishLocalPhase(.connecting)
            let handle = CXHandle(type: .phoneNumber, value: outgoing.number ?? "AirSIM")
            let action = CXStartCallAction(call: outgoing.uuid, handle: handle)
            isSendingAction = true
            callController.request(CXTransaction(action: action)) { [weak self] error in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.isSendingAction = false
                    if let error {
                        self.errorMessage = "CallKit could not start the call: \(error.localizedDescription)"
                        self.abortCompanionDial(requestID)
                        self.publishLocalPhase(.ended)
                        self.voIPCall = nil
                        self.activeDialRequestID = nil
                        self.call = WatchCallPayload(
                            callID: "", callUUID: nil, phase: .idle, number: nil,
                            callerName: nil, updatedAt: Date()
                        )
                    }
                }
            }
        } catch {
            errorMessage = error.localizedDescription
            abortCompanionDial(requestID)
        }
    }

    private func abortCompanionDial(_ requestID: UUID) {
        connectivity?.sendMessage(
            ["action": "cancel_dial", "request_id": requestID.uuidString],
            replyHandler: { _ in }, errorHandler: nil
        )
    }

    private func request(answer: Bool) {
        guard let uuid = voIPCall?.uuid ?? call.callUUID else {
            errorMessage = "No system call is available"
            return
        }
        let action: CXCallAction = answer
            ? CXAnswerCallAction(call: uuid)
            : CXEndCallAction(call: uuid)
        isSendingAction = true
        callController.request(CXTransaction(action: action)) { [weak self] error in
            DispatchQueue.main.async {
                self?.isSendingAction = false
                if let error { self?.errorMessage = error.localizedDescription }
            }
        }
    }

    private func publishLocalPhase(_ phase: WatchCallPhase) {
        guard let voIPCall else { return }
        call = WatchCallPayload(
            callID: voIPCall.callID,
            callUUID: voIPCall.uuid,
            phase: phase,
            number: voIPCall.number,
            callerName: voIPCall.callerName,
            updatedAt: Date()
        )
        notifyCompanion(event: "watch_call_owner", extra: [
            "call_id": voIPCall.callID,
            "call_uuid": voIPCall.uuid.uuidString,
            "phase": phase.rawValue,
        ])
    }

    private func handleMediaStatus(_ status: String) {
        switch status {
        case "active", "pcm_first_frame":
            if let outgoing = voIPCall, outgoing.isOutgoing, call.phase != .active {
                provider.reportOutgoingCall(with: outgoing.uuid, connectedAt: Date())
            }
            publishLocalPhase(.active)
        case "answer_ok":
            if voIPCall?.isOutgoing != true { publishLocalPhase(.active) }
        case "ownership_lost": finishRemoteCall()
        case "rejected", "ended", "remote_ended": finishRemoteCall()
        default: break
        }
    }

    private func finishRemoteCall() {
        guard let current = voIPCall else { return }
        recordEnded(current.callID)
        if case .local = current.media {
            requestLocalEnd(current)
        }
        provider.reportCall(with: current.uuid, endedAt: Date(), reason: .remoteEnded)
        media.stop()
        publishLocalPhase(.ended)
        voIPCall = nil
        answered = false
        activeDialRequestID = nil
    }

    private func receiveMirror(_ dictionary: [String: Any]) {
        if let allowed = dictionary["cloud_media_allowed"] as? Bool {
            UserDefaults.standard.set(allowed, forKey: cloudMediaPreferenceKey)
        }
        guard let payload = WatchCallPayload(dictionary: dictionary) else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let age = Date().timeIntervalSince(payload.updatedAt)
            if payload.phase == .incoming, self.voIPCall == nil,
               !self.endedCallIDs.contains(payload.callID),
               (-5...45).contains(age),
               let uuid = payload.callUUID,
               let incoming = try? WatchVoIPCall(userInfo: [
                    "event": "incoming_call", "call_id": payload.callID,
                    "call_uuid": uuid.uuidString, "number": payload.number ?? "",
                    "caller_name": payload.callerName ?? "",
                    "expires_at": Date().addingTimeInterval(45).timeIntervalSince1970,
               ]) {
                self.voIPCall = incoming
                self.call = payload
                let update = CXCallUpdate()
                update.remoteHandle = CXHandle(type: .phoneNumber, value: incoming.number ?? "AirSIM")
                update.localizedCallerName = incoming.callerName
                update.supportsHolding = false
                update.supportsGrouping = false
                update.supportsUngrouping = false
                self.provider.reportNewIncomingCall(with: uuid, update: update) { [weak self] error in
                    if let error {
                        self?.errorMessage = error.localizedDescription
                        self?.voIPCall = nil
                    }
                }
            }
            if let ownCall = voIPCall, payload.callID == ownCall.callID {
                // Watch 呼出由自己的 CallKit/媒体会话管理，iPhone 状态镜像不能提前结束它。
                if ownCall.isOutgoing, payload.phase != .ended { return }
                if payload.phase == .active, !answered, !answering {
                    provider.reportCall(with: ownCall.uuid, endedAt: Date(), reason: .answeredElsewhere)
                    media.stop()
                    voIPCall = nil
                } else if payload.phase == .ended {
                    self.recordEnded(ownCall.callID)
                    provider.reportCall(with: ownCall.uuid, endedAt: Date(), reason: .remoteEnded)
                    media.stop()
                    voIPCall = nil
                }
            }
            if voIPCall == nil { call = payload }
        }
    }

    private func sendWatchToken(_ token: Data) {
		pendingWatchToken = token
		pushStatus = "Watch VoIP registered. Syncing with iPhone…"
#if DEBUG
		print("[AirSIM Watch PushKit] token 已生成；字节数=\(token.count)，WC=\(connectivity?.activationState.rawValue ?? -1)")
#endif
        notifyCompanion(event: "watch_voip_registration", extra: [
            "watch_voip_token": token.map { String(format: "%02x", $0) }.joined(),
            "watch_bundle_id": Bundle.main.bundleIdentifier ?? "com.example.airsim.watchkitapp",
        ])
    }

    private func notifyCompanion(event: String, extra: [String: Any]) {
		guard let connectivity, connectivity.activationState == .activated else {
#if DEBUG
			print("[AirSIM Watch WC] 等待激活；event=\(event)")
#endif
			return
		}
        var payload = extra
        payload["event"] = event
		do {
			try connectivity.updateApplicationContext(payload)
		} catch {
#if DEBUG
			print("[AirSIM Watch WC] updateApplicationContext 失败：\(error.localizedDescription)")
#endif
		}
		connectivity.transferUserInfo(payload)
        if connectivity.isReachable {
            connectivity.sendMessage(payload, replyHandler: nil, errorHandler: nil)
        }
		if event == "watch_voip_registration" {
			pushStatus = "Watch VoIP synced"
		}
#if DEBUG
		print("[AirSIM Watch WC] 已发送；event=\(event)，reachable=\(connectivity.isReachable)，queued=\(connectivity.outstandingUserInfoTransfers.count)")
#endif
    }

    private func recordEnded(_ callID: String) {
        if endedCallIDs.count >= 32 { endedCallIDs.removeAll() }
        endedCallIDs.insert(callID)
    }

    private func requestLocalEnd(_ call: WatchVoIPCall) {
        notifyCompanion(event: "watch_local_end", extra: [
            "action": "watch_local_end", "call_id": call.callID,
            "call_uuid": call.uuid.uuidString,
        ])
    }

    private func answerOnIPhone(_ call: WatchVoIPCall, action: CXAnswerCallAction) {
        guard let connectivity, connectivity.isReachable else {
            answering = false
            errorMessage = "Open AirSIM on your nearby paired iPhone first"
            action.fail()
            return
        }
        connectivity.sendMessage(
            WatchCloudAudioPlan.companionControl(
                action: "answer", callID: call.callID, callUUID: call.uuid
            ),
            replyHandler: { [weak self] reply in
                DispatchQueue.main.async {
                    guard let self, self.voIPCall?.uuid == call.uuid else { return }
                    if reply["ok"] as? Bool == true {
                        self.answered = true
                        self.answering = false
                        action.fulfill()
                    } else {
                        self.answering = false
                        self.errorMessage = reply["error"] as? String ?? "iPhone could not answer"
                        action.fail()
                    }
                }
            },
            errorHandler: { [weak self] error in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.answering = false
                    self.errorMessage = "iPhone could not answer: \(error.localizedDescription)"
                    action.fail()
                }
            }
        )
    }

	private func requestMicrophonePermissionIfNeeded() {
		switch AVAudioApplication.shared.recordPermission {
		case .granted:
			microphoneStatus = "Microphone access granted"
		case .denied:
			microphoneStatus = "Allow microphone access in Watch Settings"
		case .undetermined:
			AVAudioApplication.requestRecordPermission { [weak self] granted in
				DispatchQueue.main.async {
					self?.microphoneStatus = granted ? "Microphone access granted" : "Allow microphone access in Watch Settings"
				}
			}
		@unknown default:
			microphoneStatus = "Microphone permission status unknown"
		}
	}
}

extension WatchCallSession: PKPushRegistryDelegate {
    func pushRegistry(
        _ registry: PKPushRegistry,
        didUpdate pushCredentials: PKPushCredentials,
        for type: PKPushType
    ) {
        guard type == .voIP else { return }
        sendWatchToken(pushCredentials.token)
    }

    func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
        guard type == .voIP else { return }
        notifyCompanion(event: "watch_voip_registration", extra: [
            "watch_voip_token": "",
            "watch_bundle_id": Bundle.main.bundleIdentifier ?? "com.example.airsim.watchkitapp",
        ])
    }

    func pushRegistry(
        _ registry: PKPushRegistry,
        didReceiveIncomingPushWith payload: PKPushPayload,
        for type: PKPushType,
        completion: @escaping () -> Void
    ) {
        guard type == .voIP else { completion(); return }
        do {
            let incoming = try WatchVoIPCall(userInfo: payload.dictionaryPayload)
            if voIPCall?.callID == incoming.callID || endedCallIDs.contains(incoming.callID) {
                completion()
                return
            }
            voIPCall = incoming
            answered = false
            errorMessage = nil
            publishLocalPhase(.incoming)

            let update = CXCallUpdate()
            update.remoteHandle = CXHandle(
                type: incoming.number == nil ? .generic : .phoneNumber,
                value: incoming.number ?? incoming.displayName
            )
            update.localizedCallerName = incoming.callerName
            update.hasVideo = false
            update.supportsHolding = false
            update.supportsGrouping = false
            update.supportsUngrouping = false
            update.supportsDTMF = false
            provider.reportNewIncomingCall(with: incoming.uuid, update: update) { [weak self] error in
                if let error {
                    self?.voIPCall = nil
                    self?.errorMessage = error.localizedDescription
                }
                completion()
            }
        } catch {
            errorMessage = error.localizedDescription
            completion()
        }
    }
}

extension WatchCallSession: CXProviderDelegate {
    func providerDidReset(_ provider: CXProvider) {
        if let voIPCall { recordEnded(voIPCall.callID) }
        if let voIPCall, case .local = voIPCall.media { requestLocalEnd(voIPCall) }
        if let voIPCall, case .iphoneWebRTC = voIPCall.media {
            notifyCompanion(
                event: "watch_call_control",
                extra: WatchCloudAudioPlan.companionControl(
                    action: "end", callID: voIPCall.callID, callUUID: voIPCall.uuid
                )
            )
        }
        if voIPCall != nil { publishLocalPhase(.ended) }
        if let activeDialRequestID { abortCompanionDial(activeDialRequestID) }
        media.stop(); voIPCall = nil; answered = false; answering = false
        activeDialRequestID = nil
    }

    func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        guard let voIPCall, voIPCall.isOutgoing, voIPCall.uuid == action.callUUID else {
            action.fail(); return
        }
        do {
            try media.prepareForCallKit()
            provider.reportOutgoingCall(with: voIPCall.uuid, startedConnectingAt: Date())
            if case .iphoneWebRTC = voIPCall.media {
                answered = true
                action.fulfill()
                return
            }
            media.connect(to: voIPCall.media) { [weak self] error in
                DispatchQueue.main.async {
                    guard let self else { action.fail(); return }
                    if let error {
                        self.errorMessage = "Watch voice connection failed: \(error.localizedDescription)"
                        action.fail()
                        self.provider.reportCall(with: voIPCall.uuid, endedAt: Date(), reason: .failed)
                        if let requestID = self.activeDialRequestID { self.abortCompanionDial(requestID) }
                        self.publishLocalPhase(.ended)
                        self.media.stop()
                        self.voIPCall = nil
                        self.activeDialRequestID = nil
                    } else {
                        self.answered = true
                        action.fulfill()
                    }
                }
            }
        } catch {
            errorMessage = error.localizedDescription
            action.fail()
            if let activeDialRequestID { abortCompanionDial(activeDialRequestID) }
            publishLocalPhase(.ended)
            media.stop()
            self.voIPCall = nil
            activeDialRequestID = nil
        }
    }

    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        guard let voIPCall, voIPCall.uuid == action.callUUID else { action.fail(); return }
        do {
            try media.prepareForCallKit()
            answering = true
            publishLocalPhase(.connecting)
            let connect: (WatchCallMedia) -> Void = { [weak self] selectedMedia in
                guard let self else { action.fail(); return }
                self.media.connect(to: selectedMedia) { [weak self] error in
                DispatchQueue.main.async {
                    guard let self else { action.fail(); return }
                    if let error {
                        self.errorMessage = error.localizedDescription
                        self.answering = false
                        action.fail()
                        self.provider.reportCall(with: voIPCall.uuid, endedAt: Date(), reason: .failed)
                        self.media.stop()
                    } else {
                        self.answered = true
                        self.answering = false
                        action.fulfill()
                    }
                }
                }
            }
            // Prefer the verified local gateway. Cloud audio stays on the iPhone WebRTC peer,
            // so a cloud answer is only a WCSession control message.
            if let connectivity, connectivity.isReachable {
                connectivity.sendMessage([
                    "action": "watch_local_answer", "call_id": voIPCall.callID,
                    "call_uuid": voIPCall.uuid.uuidString,
                ], replyHandler: { [weak self] reply in
                    DispatchQueue.main.async {
                        guard let self, self.voIPCall?.uuid == voIPCall.uuid else { return }
                        if let allowed = reply["cloud_media_allowed"] as? Bool {
                            UserDefaults.standard.set(allowed, forKey: self.cloudMediaPreferenceKey)
                        }
                        if reply["ok"] as? Bool == true,
                           WatchLocalPCMEndpoint(dictionary: reply) != nil
                            || WatchCloudAudioPlan.accepts(transport: reply["media_transport"] as? String) {
                            self.voIPCall = voIPCall.usingIPhoneVoWLANAudio()
                            connect(.iphoneWebRTC)
                        } else if case .iphoneWebRTC = voIPCall.media, self.cloudMediaAllowed {
                            self.answerOnIPhone(voIPCall, action: action)
                        } else {
                            self.answering = false
                            self.errorMessage = reply["error"] as? String ?? "VoWLAN is unavailable on iPhone"
                            action.fail()
                        }
                    }
                }, errorHandler: { [weak self] error in
                    DispatchQueue.main.async {
                        guard let self, self.voIPCall?.uuid == voIPCall.uuid else { return }
                        if case .iphoneWebRTC = voIPCall.media, self.cloudMediaAllowed {
                            self.answerOnIPhone(voIPCall, action: action)
                        } else {
                            self.answering = false
                            self.errorMessage = "Unable to get a local audio route: \(error.localizedDescription)"
                            action.fail()
                        }
                    }
                })
            } else if case .iphoneWebRTC = voIPCall.media, cloudMediaAllowed {
                answerOnIPhone(voIPCall, action: action)
            } else {
                answering = false
                errorMessage = "Connect your watch to its paired iPhone first"
                action.fail()
            }
        } catch {
            answering = false
            errorMessage = error.localizedDescription
            action.fail()
        }
    }

    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        if let voIPCall {
            recordEnded(voIPCall.callID)
            if voIPCall.endsOnVoWLAN {
                requestLocalEnd(voIPCall)
            } else if case .local = voIPCall.media {
                requestLocalEnd(voIPCall)
            } else if case .pendingLocal = voIPCall.media, !answered {
                notifyCompanion(event: "watch_local_reject", extra: [
                    "action": "watch_local_reject", "call_id": voIPCall.callID,
                    "call_uuid": voIPCall.uuid.uuidString,
                ])
            } else if voIPCall.isOutgoing && !answered, let activeDialRequestID {
                abortCompanionDial(activeDialRequestID)
            } else {
                let control = answered || voIPCall.isOutgoing ? "end" : "reject"
                notifyCompanion(
                    event: "watch_call_control",
                    extra: WatchCloudAudioPlan.companionControl(
                        action: control, callID: voIPCall.callID, callUUID: voIPCall.uuid
                    )
                )
            }
            publishLocalPhase(.ended)
        }
        media.stop(); voIPCall = nil; answered = false; answering = false
        activeDialRequestID = nil
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        media.setMuted(action.isMuted)
        action.fulfill()
    }

    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        do {
            if case .iphoneWebRTC = voIPCall?.media {
                return
            }
            if voIPCall?.endsOnVoWLAN == true {
                return
            }
            // The Watch owns both ends of a local VoWLAN audio session.
            try media.startAudio()
            if voIPCall?.isOutgoing != true,
               voIPCall?.media != .pendingLocal,
               !isLocalMedia {
                publishLocalPhase(.active)
            }
        } catch {
            errorMessage = "Unable to start watch voice: \(error.localizedDescription)"
            if let voIPCall, case .local = voIPCall.media { requestLocalEnd(voIPCall) }
            if let voIPCall { provider.reportCall(with: voIPCall.uuid, endedAt: Date(), reason: .failed) }
            if let activeDialRequestID { abortCompanionDial(activeDialRequestID) }
            if voIPCall != nil { publishLocalPhase(.ended) }
            media.stop()
            voIPCall = nil
            activeDialRequestID = nil
        }
    }

    private var isLocalMedia: Bool {
        guard let voIPCall else { return false }
        if case .local = voIPCall.media { return true }
        return false
    }

    func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        media.stopAudio()
    }
}

extension WatchCallSession: WCSessionDelegate {
	func sessionReachabilityDidChange(_ session: WCSession) {
#if DEBUG
		print("[AirSIM Watch WC] reachable=\(session.isReachable)")
#endif
		if session.isReachable, let token = pendingWatchToken ?? pushRegistry.pushToken(for: .voIP) {
			sendWatchToken(token)
		}
	}

    func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        if activationState == .activated {
			let token = pendingWatchToken ?? pushRegistry.pushToken(for: .voIP)
#if DEBUG
			print("[AirSIM Watch WC] 激活完成；token=\(token == nil ? "无" : "有") error=\(error?.localizedDescription ?? "无")")
#endif
			if let token { sendWatchToken(token) }
            if !session.receivedApplicationContext.isEmpty { receiveMirror(session.receivedApplicationContext) }
            requestLatestState()
        }
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        receiveMirror(applicationContext)
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        receiveMirror(userInfo)
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        receiveMirror(message)
    }
}

private final class WatchCallMediaBridge: @unchecked Sendable {
    var onRemoteEnded: (() -> Void)?
    var onStatus: ((String) -> Void)?

    private let queue = DispatchQueue(label: "com.example.airsim.watch-media")
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var encoder: WatchVoicePCMEncoder?
    private var uplinkBuffer = Data()
    private var scheduledFrames = 0
    private var muted = false
    private var stopped = true

    func prepareForCallKit() throws {
        try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .voiceChat)
    }

    func connect(to media: WatchCallMedia, completion: @escaping (Error?) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            stopped = false
            switch media {
            case .iphoneWebRTC:
                completion(nil)
            case .local:
                // VoWLAN audio is the iPhone host-ICE peer. The watch does not open a PCM socket.
                completion(nil)
            case .pendingLocal:
                completion(WatchMediaError.localRouteUnavailable)
            }
        }
    }

    func setMuted(_ muted: Bool) {
        queue.async { [weak self] in self?.muted = muted; self?.encoder?.setMuted(muted) }
    }

    func startAudio() throws {
        if engine?.isRunning == true { return }
		guard AVAudioApplication.shared.recordPermission == .granted else {
			throw WatchMediaError.microphonePermissionDenied
		}
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let encoder = WatchVoicePCMEncoder()
        encoder.setMuted(muted)
        engine.attach(player)
        guard let playbackFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 8_000,
            channels: 1, interleaved: false
        ) else { throw WatchMediaError.invalidAudioFormat }
        engine.connect(player, to: engine.mainMixerNode, format: playbackFormat)

        let input = engine.inputNode
        try? input.setVoiceProcessingEnabled(true)
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.channelCount > 0, inputFormat.sampleRate >= 8_000 else {
            throw WatchMediaError.microphoneUnavailable
        }
        input.installTap(onBus: 0, bufferSize: 960, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            let pcm = encoder.encode(buffer)
            if !pcm.isEmpty { enqueueUplink(pcm) }
        }
        engine.prepare()
        try engine.start()
        player.play()
        self.engine = engine; self.player = player; self.encoder = encoder
    }

    func stopAudio() {
        if engine != nil { engine?.inputNode.removeTap(onBus: 0) }
        player?.stop(); engine?.stop()
        engine = nil; player = nil; encoder = nil; scheduledFrames = 0
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            stopped = true
            uplinkBuffer.removeAll(keepingCapacity: false)
        }
        DispatchQueue.main.async { [weak self] in self?.stopAudio() }
    }

    private func enqueueUplink(_ data: Data) {
        queue.async { [weak self] in
            guard let self, !stopped else { return }
            uplinkBuffer.append(data)
            while uplinkBuffer.count >= 320 {
                uplinkBuffer.removeFirst(320)
            }
            if uplinkBuffer.count > 2_560 { uplinkBuffer = Data(uplinkBuffer.suffix(320)) }
        }
    }

    private func schedulePlayback(_ pcm: Data) {
        guard let player, engine?.isRunning == true, !pcm.isEmpty else { return }
        let frames = pcm.count / 2
        guard frames > 0, scheduledFrames + frames <= 3_200,
              let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: 8_000,
                channels: 1, interleaved: false
              ),
              let buffer = AVAudioPCMBuffer(
                pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)
              ), let output = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        pcm.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            for frame in 0 ..< frames {
                let bits = UInt16(bytes[frame * 2]) | UInt16(bytes[frame * 2 + 1]) << 8
                output[frame] = Float(Int16(bitPattern: bits)) / 32_768
            }
        }
        scheduledFrames += frames
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async { self?.scheduledFrames = max(0, (self?.scheduledFrames ?? 0) - frames) }
        }
        if !player.isPlaying { player.play() }
    }
}

private final class WatchVoicePCMEncoder: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float] = []
    private var position = 0.0
    private var sampleRate = 0.0
    private var muted = false

    func setMuted(_ muted: Bool) { lock.lock(); self.muted = muted; lock.unlock() }

    func encode(_ buffer: AVAudioPCMBuffer) -> Data {
        guard let input = buffer.floatChannelData?[0] else { return Data() }
        let frameCount = Int(buffer.frameLength)
        let copied = Array(UnsafeBufferPointer(start: input, count: frameCount))
        let rate = buffer.format.sampleRate
        lock.lock(); defer { lock.unlock() }
        if sampleRate != rate { sampleRate = rate; samples.removeAll(keepingCapacity: true); position = 0 }
        samples.append(contentsOf: copied)
        let step = rate / 8_000
        var pcm = Data()
        while position + 1 < Double(samples.count) {
            let lower = Int(position)
            let fraction = Float(position - Double(lower))
            let value = samples[lower] * (1 - fraction) + samples[lower + 1] * fraction
            let scaled = muted ? Int16(0) : Int16(max(-1, min(1, value)) * 32_767)
            var littleEndian = scaled.littleEndian
            withUnsafeBytes(of: &littleEndian) { pcm.append(contentsOf: $0) }
            position += step
        }
        let consumed = max(0, min(Int(position), samples.count - 1))
        if consumed > 0 { samples.removeFirst(consumed); position -= Double(consumed) }
        return pcm
    }
}

private enum WatchMediaError: LocalizedError {
    case invalidAudioFormat
    case microphoneUnavailable
	case microphonePermissionDenied
    case localRouteUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidAudioFormat: return "The watch does not support the 8 kHz audio format"
        case .microphoneUnavailable: return "The watch microphone is unavailable"
		case .microphonePermissionDenied: return "Allow AirSIM to use the watch microphone first"
        case .localRouteUnavailable: return "The local VoWLAN audio route is unavailable"
        }
    }
}

