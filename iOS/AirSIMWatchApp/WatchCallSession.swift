import AVFoundation
@preconcurrency import CallKit
import Foundation
import PushKit
import WatchConnectivity

/// Apple Watch registers for VoIP push and reports calls to CallKit. Dialing and answer controls run over WCSession.
/// Cloud audio stays on the iPhone WebRTC peer; the Watch neither opens a PCM WebSocket nor sends PCM uplink.
/// Local VoWLAN audio is also carried by the iPhone WebRTC peer.
/// CallKit and PushKit deliver on the main queue; WCSession delegate callbacks run off it and hand Sendable values to
/// the main queue.
@MainActor
@Observable
final class WatchCallSession: NSObject {
    private(set) var call = WatchCallPayload(
        callID: "",
        callUUID: nil,
        phase: .idle,
        number: nil,
        callerName: nil,
        updatedAt: Date()
    )

    private(set) var isSendingAction = false
    private(set) var isDialing = false
    var errorMessage: String?
    private(set) var pushStatus = "Registering Watch VoIP…"
    private(set) var audioStatus = "Call audio plays on iPhone"

    private let provider: CXProvider
    private let callController = CXCallController()
    @ObservationIgnored private var pushRegistry: PKPushRegistry!
    @ObservationIgnored private var connectivity: WCSession?
    @ObservationIgnored private var voIPCall: WatchVoIPCall?
    @ObservationIgnored private var answered = false
    @ObservationIgnored private var answering = false
    @ObservationIgnored private var dialRequestID: UUID?
    @ObservationIgnored private var activeDialRequestID: UUID?
    @ObservationIgnored private var pendingWatchToken: Data?
    @ObservationIgnored private var endedCallIDs = Set<String>()
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

        provider.setDelegate(self, queue: .main)
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
            return call.phase == .idle ? "Waiting for a module call" : "Audio on iPhone"
        }
        return number
    }

    func requestLatestState() {
        guard let connectivity, connectivity.isReachable else { return }
        connectivity.sendMessage(
            ["action": "status"],
            replyHandler: { @Sendable [weak self] reply in
                self?.receiveMirror(reply)
            },
            errorHandler: nil
        )
    }

    func answer() { request(answer: true) }
    func reject() { request(answer: false) }
    func end() { request(answer: false) }

    func dial(_ input: String) {
        guard let number = WatchDialNumber.validated(input) else {
            errorMessage = "Enter a valid phone number"
            return
        }
        guard voIPCall == nil,
            call.phase == .idle || call.phase == .ended,
            !isDialing
        else {
            errorMessage = "End the current call first"
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
        connectivity.sendMessage(
            [
                "action": "dial", "request_id": requestID.uuidString, "number": number,
            ],
            replyHandler: { @Sendable [weak self] reply in
                let reply = WatchMessage(reply)
                DispatchQueue.main.async { self?.receiveDialReply(reply, requestID: requestID) }
            },
            errorHandler: { @Sendable [weak self] error in
                DispatchQueue.main.async {
                    guard let self, self.dialRequestID == requestID else { return }
                    self.dialRequestID = nil
                    self.isDialing = false
                    self.errorMessage = "iPhone did not respond to the call request: \(error.localizedDescription)"
                    self.abortCompanionDial(requestID)
                }
            }
        )
    }

    func cancelDial() {
        guard let requestID = dialRequestID else { return }
        dialRequestID = nil
        isDialing = false
        abortCompanionDial(requestID)
    }

    private func receiveDialReply(_ reply: WatchMessage, requestID: UUID) {
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
            let outgoing = try WatchVoIPCall(outgoingReply: reply.dictionary)
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
                            callID: "",
                            callUUID: nil,
                            phase: .idle,
                            number: nil,
                            callerName: nil,
                            updatedAt: Date()
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
            replyHandler: { @Sendable _ in },
            errorHandler: nil
        )
    }

    private func request(answer: Bool) {
        // A mirrored call the iPhone owns was never reported to this Watch's CallKit.
        guard let uuid = voIPCall?.uuid else {
            requestOnIPhone(answer: answer)
            return
        }
        let action: CXCallAction =
            answer
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

    private func requestOnIPhone(answer: Bool) {
        guard let uuid = call.callUUID else {
            errorMessage = "No system call is available"
            return
        }
        guard let connectivity, connectivity.isReachable else {
            errorMessage = "Open AirSIM on your nearby paired iPhone first"
            return
        }
        let control = WatchCloudAudioPlan.companionAction(answer: answer, phase: call.phase)
        isSendingAction = true
        connectivity.sendMessage(
            WatchCloudAudioPlan.companionControl(
                action: control,
                callID: call.callID,
                callUUID: uuid
            ),
            replyHandler: { @Sendable [weak self] reply in
                let reply = WatchMessage(reply)
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.isSendingAction = false
                    guard reply["ok"] as? Bool != true else { return }
                    self.errorMessage = reply["error"] as? String ?? "iPhone could not \(control) the call"
                }
            },
            errorHandler: { @Sendable [weak self] error in
                DispatchQueue.main.async {
                    self?.isSendingAction = false
                    self?.errorMessage = "iPhone did not respond: \(error.localizedDescription)"
                }
            }
        )
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
        notifyCompanion(
            event: "watch_call_owner",
            extra: [
                "call_id": voIPCall.callID,
                "call_uuid": voIPCall.uuid.uuidString,
                "phase": phase.rawValue,
            ]
        )
    }

    private nonisolated func receiveMirror(_ dictionary: [String: Any]) {
        if let allowed = dictionary["cloud_media_allowed"] as? Bool {
            UserDefaults.standard.set(allowed, forKey: cloudMediaPreferenceKey)
        }
        guard let payload = WatchCallPayload(dictionary: dictionary) else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let age = Date().timeIntervalSince(payload.updatedAt)
            if payload.phase == .incoming,
                self.voIPCall == nil,
                !self.endedCallIDs.contains(payload.callID),
                (-5...45).contains(age),
                let uuid = payload.callUUID,
                let incoming = try? WatchVoIPCall(userInfo: [
                    "event": "incoming_call", "call_id": payload.callID,
                    "call_uuid": uuid.uuidString, "number": payload.number ?? "",
                    "caller_name": payload.callerName ?? "",
                    "expires_at": Date().addingTimeInterval(45).timeIntervalSince1970,
                ])
            {
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
                        // CallKit calls this completion on the provider's delegate queue, which is main.
                        MainActor.assumeIsolated {
                            self?.errorMessage = error.localizedDescription
                            self?.voIPCall = nil
                        }
                    }
                }
            }
            if let ownCall = voIPCall, payload.callID == ownCall.callID {
                if payload.phase == .active, answered || ownCall.isOutgoing {
                    if ownCall.isOutgoing, call.phase != .active {
                        provider.reportOutgoingCall(with: ownCall.uuid, connectedAt: Date())
                    }
                    call = payload
                    return
                }
                if payload.phase == .active, !answered, !answering {
                    provider.reportCall(with: ownCall.uuid, endedAt: Date(), reason: .answeredElsewhere)
                    voIPCall = nil
                } else if payload.phase == .ended {
                    self.recordEnded(ownCall.callID)
                    provider.reportCall(with: ownCall.uuid, endedAt: Date(), reason: .remoteEnded)
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
        print(
            "[AirSIM Watch PushKit] Token generated; bytes=\(token.count), WC=\(connectivity?.activationState.rawValue ?? -1)"
        )
        #endif
        notifyCompanion(
            event: "watch_voip_registration",
            extra: [
                "watch_voip_token": token.map { String(format: "%02x", $0) }.joined(),
                "watch_bundle_id": Bundle.main.bundleIdentifier ?? "com.example.airsim.watchkitapp",
            ]
        )
    }

    private func notifyCompanion(event: String, extra: [String: Any]) {
        guard let connectivity, connectivity.activationState == .activated else {
            #if DEBUG
            print("[AirSIM Watch WC] Waiting for activation; event=\(event)")
            #endif
            return
        }
        var payload = extra
        payload["event"] = event
        do {
            try connectivity.updateApplicationContext(payload)
        } catch {
            #if DEBUG
            print("[AirSIM Watch WC] updateApplicationContext failed: \(error.localizedDescription)")
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
        print(
            "[AirSIM Watch WC] Sent; event=\(event), reachable=\(connectivity.isReachable), queued=\(connectivity.outstandingUserInfoTransfers.count)"
        )
        #endif
    }

    private func recordEnded(_ callID: String) {
        if endedCallIDs.count >= 32 { endedCallIDs.removeAll() }
        endedCallIDs.insert(callID)
    }

    private func requestLocalEnd(_ call: WatchVoIPCall) {
        notifyCompanion(
            event: "watch_local_end",
            extra: [
                "action": "watch_local_end", "call_id": call.callID,
                "call_uuid": call.uuid.uuidString,
            ]
        )
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
                action: "answer",
                callID: call.callID,
                callUUID: call.uuid
            ),
            replyHandler: { @Sendable [weak self] reply in
                let reply = WatchMessage(reply)
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
            errorHandler: { @Sendable [weak self] error in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.answering = false
                    self.errorMessage = "iPhone could not answer: \(error.localizedDescription)"
                    action.fail()
                }
            }
        )
    }

}

extension WatchCallSession: @preconcurrency PKPushRegistryDelegate {
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
        notifyCompanion(
            event: "watch_voip_registration",
            extra: [
                "watch_voip_token": "",
                "watch_bundle_id": Bundle.main.bundleIdentifier ?? "com.example.airsim.watchkitapp",
            ]
        )
    }

    func pushRegistry(
        _ registry: PKPushRegistry,
        didReceiveIncomingPushWith payload: PKPushPayload,
        for type: PKPushType,
        completion: @escaping @Sendable () -> Void
    ) {
        guard type == .voIP else {
            completion()
            return
        }
        switch WatchVoIPPushPolicy.disposition(
            userInfo: payload.dictionaryPayload,
            tracked: voIPCall,
            endedCallIDs: endedCallIDs
        ) {
        case .ring(let incoming):
            voIPCall = incoming
            answered = false
            errorMessage = nil
            publishLocalPhase(.incoming)
            let update = incomingCallUpdate(incoming)
            provider.reportNewIncomingCall(with: incoming.uuid, update: update) { [weak self] error in
                if let error {
                    // CallKit calls this completion on the provider's delegate queue, which is main.
                    MainActor.assumeIsolated {
                        self?.voIPCall = nil
                        self?.errorMessage = error.localizedDescription
                    }
                }
                completion()
            }
        case .reportTracked(let tracked):
            // The mirror often reports this call before its own push arrives. The tracked call stays as it is.
            provider.reportNewIncomingCall(with: tracked.uuid, update: incomingCallUpdate(tracked)) { _ in
                completion()
            }
        case .endAlreadyEnded(let placeholder):
            reportEndedPlaceholder(placeholder, reason: .remoteEnded, completion: completion)
        case .endUnusable(let placeholder, let error):
            errorMessage = error
            reportEndedPlaceholder(placeholder, reason: .failed, completion: completion)
        }
    }

    private func incomingCallUpdate(_ incoming: WatchVoIPCall) -> CXCallUpdate {
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
        return update
    }

    /// Satisfies PushKit for a push that must not ring, without touching the tracked call.
    private func reportEndedPlaceholder(
        _ uuid: UUID,
        reason: CXCallEndedReason,
        completion: @escaping @Sendable () -> Void
    ) {
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: "AirSIM")
        update.hasVideo = false
        provider.reportNewIncomingCall(with: uuid, update: update) { [weak self] error in
            if error == nil {
                // CallKit calls this completion on the provider's delegate queue, which is main.
                MainActor.assumeIsolated {
                    self?.provider.reportCall(with: uuid, endedAt: Date(), reason: reason)
                }
            }
            completion()
        }
    }
}

extension WatchCallSession: @preconcurrency CXProviderDelegate {
    func providerDidReset(_ provider: CXProvider) {
        if let voIPCall { recordEnded(voIPCall.callID) }
        if let voIPCall, voIPCall.endsOnVoWLAN { requestLocalEnd(voIPCall) }
        if let voIPCall, !voIPCall.endsOnVoWLAN, case .iphoneWebRTC = voIPCall.media {
            notifyCompanion(
                event: "watch_call_control",
                extra: WatchCloudAudioPlan.companionControl(
                    action: "end",
                    callID: voIPCall.callID,
                    callUUID: voIPCall.uuid
                )
            )
        }
        if voIPCall != nil { publishLocalPhase(.ended) }
        if let activeDialRequestID { abortCompanionDial(activeDialRequestID) }
        voIPCall = nil
        answered = false
        answering = false
        activeDialRequestID = nil
    }

    func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        guard let voIPCall,
            voIPCall.isOutgoing,
            voIPCall.uuid == action.callUUID,
            voIPCall.media == .iphoneWebRTC
        else {
            action.fail()
            return
        }
        provider.reportOutgoingCall(with: voIPCall.uuid, startedConnectingAt: Date())
        answered = true
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        guard let voIPCall, voIPCall.uuid == action.callUUID else {
            action.fail()
            return
        }
        answering = true
        publishLocalPhase(.connecting)
        guard let connectivity, connectivity.isReachable else {
            answering = false
            errorMessage = "Open AirSIM on your nearby paired iPhone first"
            action.fail()
            return
        }
        connectivity.sendMessage(
            [
                "action": "watch_local_answer", "call_id": voIPCall.callID,
                "call_uuid": voIPCall.uuid.uuidString,
            ],
            replyHandler: { @Sendable [weak self] reply in
                let reply = WatchMessage(reply)
                DispatchQueue.main.async {
                    guard let self, self.voIPCall?.uuid == voIPCall.uuid else { return }
                    if let allowed = reply["cloud_media_allowed"] as? Bool {
                        UserDefaults.standard.set(allowed, forKey: self.cloudMediaPreferenceKey)
                    }
                    if reply["ok"] as? Bool == true,
                        reply["media_route"] as? String == "vowlan",
                        WatchCloudAudioPlan.accepts(transport: reply["media_transport"] as? String)
                    {
                        self.voIPCall = voIPCall.usingIPhoneVoWLANAudio()
                        self.answered = true
                        self.answering = false
                        action.fulfill()
                    } else if voIPCall.media == .iphoneWebRTC,
                        !voIPCall.endsOnVoWLAN,
                        self.cloudMediaAllowed
                    {
                        self.answerOnIPhone(voIPCall, action: action)
                    } else {
                        self.answering = false
                        self.errorMessage = reply["error"] as? String ?? "VoWLAN is unavailable on iPhone"
                        action.fail()
                    }
                }
            },
            errorHandler: { @Sendable [weak self] error in
                DispatchQueue.main.async {
                    guard let self, self.voIPCall?.uuid == voIPCall.uuid else { return }
                    // An uncertain local answer must not switch transport or answer twice.
                    self.answering = false
                    self.errorMessage = "iPhone did not confirm answering: \(error.localizedDescription)"
                    action.fail()
                }
            }
        )
    }

    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        // A placeholder reported for a push that must not ring is never the tracked call.
        if let voIPCall, voIPCall.uuid != action.callUUID {
            action.fulfill()
            return
        }
        if let voIPCall {
            recordEnded(voIPCall.callID)
            if voIPCall.endsOnVoWLAN {
                requestLocalEnd(voIPCall)
            } else if case .pendingLocal = voIPCall.media, !answered {
                notifyCompanion(
                    event: "watch_local_reject",
                    extra: [
                        "action": "watch_local_reject", "call_id": voIPCall.callID,
                        "call_uuid": voIPCall.uuid.uuidString,
                    ]
                )
            } else if voIPCall.isOutgoing && !answered, let activeDialRequestID {
                abortCompanionDial(activeDialRequestID)
            } else {
                let control = answered || voIPCall.isOutgoing ? "end" : "reject"
                notifyCompanion(
                    event: "watch_call_control",
                    extra: WatchCloudAudioPlan.companionControl(
                        action: control,
                        callID: voIPCall.callID,
                        callUUID: voIPCall.uuid
                    )
                )
            }
            publishLocalPhase(.ended)
        }
        voIPCall = nil
        answered = false
        answering = false
        activeDialRequestID = nil
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        guard let current = voIPCall,
            current.uuid == action.callUUID,
            let connectivity,
            connectivity.isReachable
        else {
            action.fail()
            return
        }
        var message = WatchCloudAudioPlan.companionControl(
            action: "mute",
            callID: current.callID,
            callUUID: current.uuid
        )
        message["muted"] = action.isMuted
        connectivity.sendMessage(
            message,
            replyHandler: { @Sendable [weak self] reply in
                let reply = WatchMessage(reply)
                DispatchQueue.main.async {
                    guard self?.voIPCall?.uuid == current.uuid, reply["ok"] as? Bool == true else {
                        action.fail()
                        return
                    }
                    action.fulfill()
                }
            },
            errorHandler: { @Sendable _ in action.fail() }
        )
    }

    // This is a companion controller, never an independent Watch audio device.
    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {}
    func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {}

}

extension WatchCallSession: WCSessionDelegate {
    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let isReachable = session.isReachable
        #if DEBUG
        print("[AirSIM Watch WC] reachable=\(isReachable)")
        #endif
        guard isReachable else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let token = pendingWatchToken ?? pushRegistry.pushToken(for: .voIP) else { return }
            sendWatchToken(token)
        }
    }

    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        guard activationState == .activated else { return }
        let receivedContext = session.receivedApplicationContext
        let context = receivedContext.isEmpty ? nil : WatchMessage(receivedContext)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let token = pendingWatchToken ?? pushRegistry.pushToken(for: .voIP)
            #if DEBUG
            print(
                "[AirSIM Watch WC] Activation completed; token=\(token == nil ? "none" : "present") error=\(error?.localizedDescription ?? "none")"
            )
            #endif
            if let token { sendWatchToken(token) }
            if let context { receiveMirror(context.dictionary) }
            requestLatestState()
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        receiveMirror(applicationContext)
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        receiveMirror(userInfo)
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        receiveMirror(message)
    }
}
