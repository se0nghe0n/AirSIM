import AVFoundation
import CallKit

enum CallKitSynchronizationPolicy {
    static func mayFinishEndedHistory(currentBackendID: String?, endedID: String) -> Bool {
        currentBackendID == endedID
    }
}
import Foundation

/// Forwards system CallKit actions to the module control layer; main-actor isolated to protect AppModel state.
@MainActor
protocol CallKitActionHandling: AnyObject {
    func callKitPrepareAudioSession() throws
    func callKitStart(number: String) async throws
    func callKitAnswer(origin: CallAnswerOrigin) async throws
    func callKitEnd() async throws
    func callKitSetMuted(_ muted: Bool) async
    func callKitPlayDTMF(_ digits: String) async throws
    func callKitAudioSessionDidActivate() async
    func callKitAudioSessionDidDeactivate()
    func callKitProviderDidReset() async
    func callKitDidFail(_ message: String)
    func callKitDidReceiveIncoming(_ call: IncomingVoIPCall)
    func callKitCallDidEnd()
}

enum CallAnswerOrigin: Equatable, Sendable {
    case system
    case app
}

/// CallKit system transactions must complete before slow Agent/Relay I/O so the system activates
/// AVAudioSession promptly. Backend errors are returned separately for the caller to end the established system call.
enum CallKitActionCoordinator {
    static func perform(
        prepare: () throws -> Void,
        fulfill: () -> Void,
        backend: () async throws -> Void
    ) async throws -> Error? {
        try prepare()
        fulfill()
        do {
            try await backend()
            return nil
        } catch {
            return error
        }
    }
}

enum CallKitEndActionPolicy {
    static func shouldForwardToBackend(systemCallWasCurrent: Bool) -> Bool {
        systemCallWasCurrent
    }
}

extension CallKitActionHandling {
    func callKitPrepareAudioSession() throws {}
    func callKitDidReceiveIncoming(_ call: IncomingVoIPCall) {}
    func callKitCallDidEnd() {}
}

/// After hangup, PushKit, USB long-polling, and system callbacks may arrive out of order. Retain recently ended
/// call_id/UUID pairs briefly so late events cannot re-present the same call after CallKit closes.
struct IncomingCallDeduplicator {
    let retention: TimeInterval
    private var endedCallIDs: [String: Date] = [:]
    private var endedUUIDs: [UUID: Date] = [:]

    init(retention: TimeInterval = 90) {
        self.retention = retention
    }

    mutating func recordEnded(callID: String?, uuid: UUID?, at date: Date = Date()) {
        purgeExpired(now: date)
        if let callID, !callID.isEmpty { endedCallIDs[callID] = date }
        if let uuid { endedUUIDs[uuid] = date }
    }

    mutating func shouldAccept(callID: String?, uuid: UUID?, now: Date = Date()) -> Bool {
        purgeExpired(now: now)
        if let callID, endedCallIDs[callID] != nil { return false }
        if let uuid, endedUUIDs[uuid] != nil { return false }
        return true
    }

    private mutating func purgeExpired(now: Date) {
        endedCallIDs = endedCallIDs.filter { now.timeIntervalSince($0.value) <= retention }
        endedUUIDs = endedUUIDs.filter { now.timeIntervalSince($0.value) <= retention }
    }
}

/// Maintains a 1-to-1 mapping between module calls and system call UUIDs, handling lock-screen and system call UI actions.
@MainActor
final class CallKitController: NSObject {
    static let shared = CallKitController()

    private let provider: CXProvider
    private let callController = CXCallController()
    private(set) var audioSessionIsActive = false
    private var entitlementAvailable = true
    private var featureEnabled = !LocalModePreference.isEnabled()
    weak var handler: (any CallKitActionHandling)?

    private var currentUUID: UUID?
    private var currentBackendID: String?
    private var currentState: String?
    private var currentNumber: String?
    private var currentDirection: String?
    private var incomingReportRequested = false
    private var incomingReportFailed = false
    private var systemCallReported = false
    private var endActionFulfilled = false
    private var missingCallPolls = 0
    private var outgoingStartInFlight = false
    private var outgoingStartID = UUID()
    private var handledOutgoingActions: Set<ObjectIdentifier> = []
    private var dialedOutgoingUUIDs: Set<UUID> = []
    private var appAnswerRequestUUID: UUID?
    private var incomingReportCompletions: [(Error?) -> Void] = []
    private var incomingDeduplicator = IncomingCallDeduplicator()
    private(set) var currentIncomingPush: IncomingVoIPCall?

    override init() {
        let configuration = CXProviderConfiguration()
        configuration.maximumCallGroups = 1
        configuration.maximumCallsPerCallGroup = 1
        configuration.supportedHandleTypes = [.phoneNumber]
        configuration.supportsVideo = false
        configuration.includesCallsInRecents = true
        provider = CXProvider(configuration: configuration)
        super.init()
        provider.setDelegate(self, queue: .main)
    }

    deinit {
        provider.invalidate()
    }

    var isAvailable: Bool { entitlementAvailable && featureEnabled }

    func setEnabled(_ enabled: Bool) {
        guard featureEnabled != enabled else { return }
        featureEnabled = enabled
        guard !enabled else { return }
        if let uuid = currentUUID, systemCallReported {
            provider.reportCall(with: uuid, endedAt: Date(), reason: .failed)
        }
        audioSessionIsActive = false
        resetCurrentCall()
#if DEBUG
        debugLog("CallKit disabled in local mode")
#endif
    }

    var managesCurrentCall: Bool {
        isAvailable && currentUUID != nil && (systemCallReported || currentDirection == "outgoing")
    }

    var currentCallIsAnswered: Bool {
        ["active", "held"].contains(currentState)
    }

    /// Exposes immutable call identity only; lifecycle state is managed centrally by CallLifecycleStore.
    var currentSystemCallUUID: UUID? { currentUUID }

    var suppressesInAppIncomingRingtone: Bool {
        incomingReportRequested && !incomingReportFailed
    }

    func watchCallUUID(for backendID: String?) -> UUID? {
        guard backendID == nil || backendID == currentBackendID else { return nil }
        return currentUUID
    }

    func matchesCurrentCall(callID: String?, uuid: UUID?) -> Bool {
        guard currentUUID != nil else { return false }
        let backendMatches = callID == nil || callID == currentBackendID
        let uuidMatches = uuid == nil || uuid == currentUUID
        return backendMatches && uuidMatches
    }

    /// Ends local CallKit immediately once a paired device takes over the same call to prevent dual ringing or media contention.
    func reportCurrentCallEnded(reason: CXCallEndedReason) {
        finishCurrentCall(previous: nil, reason: reason)
    }

    func reportCurrentOutgoingConnected() {
        guard currentDirection == "outgoing", let uuid = currentUUID,
              currentState != "active", systemCallReported else { return }
        currentState = "active"
        provider.reportOutgoingCall(with: uuid, connectedAt: Date())
    }

    /// PushKit cold launch must immediately hand the incoming call to the system. Subsequent USB status sync reuses
    /// the same call_id/UUID without creating a duplicate system call.
    func reportIncomingPush(
        _ call: IncomingVoIPCall,
        completion: @escaping (Error?) -> Void
    ) {
        guard isAvailable else {
            completion(CallKitBridgeError.unavailable)
            return
        }
        guard incomingDeduplicator.shouldAccept(callID: call.callID, uuid: call.uuid) else {
            debugLog("Ignoring late PushKit event for ended call")
            completion(nil)
            return
        }
        if currentUUID != nil {
            guard call.matches(backendID: currentBackendID, uuid: currentUUID) else {
                completion(CallKitBridgeError.callInProgress)
                return
            }
            currentIncomingPush = call
            currentBackendID = call.callID
            currentNumber = call.number ?? currentNumber
            if systemCallReported {
                handler?.callKitDidReceiveIncoming(call)
                completion(nil)
                return
            }
            incomingReportCompletions.append(completion)
            reportIncomingIfNeeded(number: currentNumber, callerName: call.callerName, source: "PushKit Redelivery")
            handler?.callKitDidReceiveIncoming(call)
            return
        }

        currentUUID = call.uuid
        currentBackendID = call.callID
        currentIncomingPush = call
        currentDirection = "incoming"
        currentState = "incoming"
        currentNumber = call.number
        missingCallPolls = 0
        endActionFulfilled = false
        incomingReportCompletions.append(completion)
        reportIncomingIfNeeded(number: call.number, callerName: call.callerName, source: "PushKit")
        handler?.callKitDidReceiveIncoming(call)
    }

    /// Lets the system take over the outgoing call transaction first; the actual module ATD is executed only inside the CXProvider delegate callback.
    func startOutgoingCall(number: String) async throws {
        guard isAvailable else { throw CallKitBridgeError.unavailable }
        guard currentUUID == nil else { throw CallKitBridgeError.callInProgress }

        let uuid = UUID()
        currentUUID = uuid
        currentDirection = "outgoing"
        currentNumber = number
        currentState = "dialing"
        missingCallPolls = 0
        endActionFulfilled = false

        do {
            let handle = CXHandle(type: .phoneNumber, value: number)
            try await request(CXStartCallAction(call: uuid, handle: handle))
        } catch {
            let unavailable = disableCallKitIfUnentitled(error)
            resetCurrentCall()
            if unavailable { throw CallKitBridgeError.unavailable }
            throw error
        }
    }

    /// Cloud calls do not pass through the local status poll that normally binds this ID.
    func bindOutgoingBackendCall(_ callID: String) {
        guard !callID.isEmpty, currentDirection == "outgoing", currentUUID != nil,
              currentBackendID == nil || currentBackendID == callID else { return }
        currentBackendID = callID
    }

    func performLiveActivityAction(_ action: AirSIMLiveActivityAction, callID: String) async throws {
        guard managesCurrentCall else { throw LiveActivityCallError.unavailable }
        guard try LiveActivityCallActionPolicy.shouldPerform(action, callID: callID,
                currentCallID: currentBackendID, state: currentState, direction: currentDirection) else { return }
        switch action {
        case .answer: try await answerCurrentCall()
        case .reject, .hangup: try await endCurrentCall()
        }
    }

    func answerCurrentCall(presentInApp: Bool = false) async throws {
        guard let uuid = currentUUID, systemCallReported else {
            throw CallKitBridgeError.noSystemCall
        }
        if presentInApp { appAnswerRequestUUID = uuid }
        do {
            try await requestSystemAction(CXAnswerCallAction(call: uuid))
        } catch {
            if appAnswerRequestUUID == uuid { appAnswerRequestUUID = nil }
            throw error
        }
    }

    func endCurrentCall() async throws {
        guard let uuid = currentUUID, systemCallReported || currentDirection == "outgoing" else {
            throw CallKitBridgeError.noSystemCall
        }
        try await requestSystemAction(CXEndCallAction(call: uuid))
    }

    func setMuted(_ muted: Bool) async throws {
        guard let uuid = currentUUID, systemCallReported else {
            throw CallKitBridgeError.noSystemCall
        }
        try await requestSystemAction(CXSetMutedCallAction(call: uuid, muted: muted))
    }

    /// In-app keypad digits also go through CallKit transactions so the system call screen and in-app UI do not maintain separate DTMF states.
    func playDTMF(_ digits: String) async throws {
        guard let uuid = currentUUID, systemCallReported else {
            throw CallKitBridgeError.noSystemCall
        }
        let validDigits = digits.filter { "0123456789*#".contains($0) }
        guard !validDigits.isEmpty else { return }
        try await requestSystemAction(
            CXPlayDTMFCallAction(call: uuid, digits: validDigits, type: .singleTone)
        )
    }

    /// Synchronizes incoming and outgoing call lifecycle with the system after each module poll.
    func synchronize(call: CallRecord?, previous: CallRecord?, callerName: String?) {
        // Keep only the in-app state machine once CallKit is denied by the system; do not continue fabricating system call UUIDs.
        guard isAvailable else {
            if call == nil { resetCurrentCall() }
            return
        }
        guard let call else {
            // The module has written the same ID into history with ended_at, which is a definitive end event;
            // close the system call immediately without waiting for empty-CLCC debouncing.
            if previous?.endedAt != nil {
                guard let previous,
                      CallKitSynchronizationPolicy.mayFinishEndedHistory(
                        currentBackendID: currentBackendID, endedID: previous.id
                      ) else { return }
                finishCurrentCall(previous: previous)
                return
            }
            // An occasional empty AT+CLCC response does not mean the call ended; retain the UUID so speaker/mute transactions do not fail with unknown UUID.
            if currentDirection == "outgoing", outgoingStartInFlight { return }
            if currentUUID != nil, systemCallReported || currentDirection == "outgoing" {
                missingCallPolls += 1
                guard missingCallPolls >= 3 else { return }
            }
            finishCurrentCall(previous: previous)
            return
        }

        if call.direction == "outgoing" {
            // Synchronize only system outgoing calls started via startOutgoingCall; do not fabricate UUIDs for external ATD calls.
            guard currentDirection == "outgoing", let uuid = currentUUID else { return }
            if let backendID = currentBackendID, backendID != call.id {
                finishCurrentCall(previous: previous, reason: .failed)
                return
            }
            currentBackendID = call.id
            currentNumber = call.number ?? currentNumber
            missingCallPolls = 0
            if call.state == "active", currentState != "active", systemCallReported {
                provider.reportOutgoingCall(with: uuid, connectedAt: call.updatedAt)
            }
            currentState = call.state
            return
        }

        if currentDirection == "outgoing" {
            finishCurrentCall(previous: previous, reason: .failed)
        }

        missingCallPolls = 0
        outgoingStartInFlight = false

        if let backendID = currentBackendID, backendID != call.id {
            finishCurrentCall(previous: previous, reason: .failed)
        }
        if currentUUID == nil,
           !incomingDeduplicator.shouldAccept(callID: call.id, uuid: nil) {
            debugLog("Ignoring late module state for ended call")
            return
        }
        if currentUUID == nil { currentUUID = UUID() }
        currentDirection = "incoming"
        currentBackendID = call.id
        currentNumber = call.number

        if ["incoming", "waiting"].contains(call.state) {
            reportIncomingIfNeeded(number: call.number, callerName: callerName, source: "Module Status")
        }
        currentState = call.state
    }

    private func reportIncomingIfNeeded(number: String?, callerName: String?, source: String) {
        guard !incomingReportRequested, !systemCallReported, let uuid = currentUUID else { return }
        incomingReportRequested = true
        debugLog("Requesting system incoming call UI; source=\(source)")
        provider.reportNewIncomingCall(
            with: uuid,
            update: update(number: number, callerName: callerName)
        ) { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let error {
                    let diagnosticError = error as NSError
                    self.debugLog(
                        "Failed to report system incoming call; domain=\(diagnosticError.domain) code=\(diagnosticError.code) "
                            + "message=\(diagnosticError.localizedDescription)"
                    )
                    if self.disableCallKitIfUnentitled(error) {
                        self.finishIncomingReport(error)
                        self.resetCurrentCall()
                        return
                    }
                    self.systemCallReported = false
                    self.incomingReportFailed = true
                    self.handler?.callKitDidFail("Unable to show system incoming call screen: \(error.localizedDescription)")
                    self.finishIncomingReport(error)
                } else {
                    self.debugLog("System incoming call reported successfully")
                    self.systemCallReported = true
                    self.finishIncomingReport(nil)
                }
            }
        }
    }

    private func finishIncomingReport(_ error: Error?) {
        let completions = incomingReportCompletions
        incomingReportCompletions.removeAll()
        completions.forEach { $0(error) }
    }

    private func finishCurrentCall(
        previous: CallRecord?,
        reason explicitReason: CXCallEndedReason? = nil
    ) {
        guard let uuid = currentUUID else { return }
        if systemCallReported, !endActionFulfilled {
            let reason = explicitReason ?? endedReason(for: previous)
            provider.reportCall(with: uuid, endedAt: previous?.endedAt ?? Date(), reason: reason)
        }
        incomingDeduplicator.recordEnded(
            callID: currentBackendID ?? previous?.id,
            uuid: uuid,
            at: previous?.endedAt ?? Date()
        )
        handler?.callKitCallDidEnd()
        resetCurrentCall()
    }

    private func endedReason(for call: CallRecord?) -> CXCallEndedReason {
        guard let call else { return .failed }
        return call.state == "active" || call.state == "held" ? .remoteEnded : .unanswered
    }

    private func update(number: String?, callerName: String?) -> CXCallUpdate {
        let update = CXCallUpdate()
        let value = number?.isEmpty == false ? number! : "Unknown Number"
        update.remoteHandle = CXHandle(type: .phoneNumber, value: value)
        if let callerName, !callerName.isEmpty, callerName != number {
            update.localizedCallerName = callerName
        }
        update.supportsHolding = false
        update.supportsGrouping = false
        update.supportsUngrouping = false
        update.supportsDTMF = true
        update.hasVideo = false
        return update
    }

    private func request(_ action: CXAction) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            callController.request(CXTransaction(action: action)) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }

    /// CallKit may briefly lose the UUID while rebuilding system UI; convert it into a recoverable domain error
    /// rather than letting error code 4 propagate as "call ended".
    private func requestSystemAction(_ action: CXAction) async throws {
        do {
            try await request(action)
        } catch {
            let nsError = error as NSError
            if nsError.domain == CXErrorDomainRequestTransaction,
               nsError.code == CXErrorCodeRequestTransactionError.Code.unknownCallUUID.rawValue {
                throw CallKitBridgeError.staleSystemCall
            }
            throw error
        }
    }

    /// Personal team signing or restricted devices may return requesttransaction/unentitled; automatically fall back to in-app calls.
    private func disableCallKitIfUnentitled(_ error: Error) -> Bool {
        let error = error as NSError
        guard error.domain == CXErrorDomainRequestTransaction,
              error.code == CXErrorCodeRequestTransactionError.Code.unentitled.rawValue else {
            return false
        }
        entitlementAvailable = false
        audioSessionIsActive = false
        debugLog("CallKit marked unentitled by system; falling back to in-app call UI")
        return true
    }

    /// Logs only state and system error codes during device debugging to avoid writing phone numbers to device logs.
    private func debugLog(_ message: String) {
#if DEBUG
        print("[AirSIM CallKit] \(message)")
#endif
    }

    private func resetCurrentCall() {
        if !incomingReportCompletions.isEmpty {
            finishIncomingReport(CallKitBridgeError.staleSystemCall)
        }
        currentUUID = nil
        currentBackendID = nil
        currentState = nil
        currentNumber = nil
        currentDirection = nil
        currentIncomingPush = nil
        incomingReportRequested = false
        incomingReportFailed = false
        systemCallReported = false
        endActionFulfilled = false
        missingCallPolls = 0
        outgoingStartInFlight = false
        appAnswerRequestUUID = nil
    }

    private func fail(_ action: CXAction, error: Error) {
        action.fail()
        handler?.callKitDidFail(error.localizedDescription)
    }

    private func performAnswer(_ action: CXAnswerCallAction) async {
        guard currentUUID == action.callUUID else {
            action.fail()
            return
        }
        do {
            guard let handler else { throw CallKitBridgeError.handlerUnavailable }
            let origin: CallAnswerOrigin = appAnswerRequestUUID == action.callUUID ? .app : .system
            appAnswerRequestUUID = nil
            let backendError = try await CallKitActionCoordinator.perform(
                prepare: { try handler.callKitPrepareAudioSession() },
                fulfill: {
                    self.currentState = "connecting"
                    // The system transaction confirms only that the user accepted the call. Cloud WebSocket, Telecom, and WebRTC
                    // are established asynchronously afterward and must not block CallKit from activating AVAudioSession.
                    action.fulfill()
                },
                backend: { try await handler.callKitAnswer(origin: origin) }
            )
            if let backendError {
                finishCurrentCall(previous: nil, reason: .failed)
                handler.callKitDidFail(backendError.localizedDescription)
            }
        } catch {
            fail(action, error: error)
        }
    }

    private func performStart(_ action: CXStartCallAction) async {
        if action.isComplete { return }
        let actionIdentity = ObjectIdentifier(action)
        guard handledOutgoingActions.insert(actionIdentity).inserted else { return }
        if dialedOutgoingUUIDs.contains(action.callUUID) {
            action.fulfill()
            return
        }
        if outgoingStartInFlight { return }
        if systemCallReported, currentUUID == action.callUUID, currentDirection == "outgoing" {
            action.fulfill()
            return
        }
        outgoingStartInFlight = true
        let operationID = UUID()
        outgoingStartID = operationID
        defer { if outgoingStartID == operationID { outgoingStartInFlight = false } }
        do {
            guard let handler else { throw CallKitBridgeError.handlerUnavailable }
            // Besides transactions submitted in-app, the system may hand outgoing calls directly to the provider
            // via Siri or Contacts; establish the same state using the system UUID.
            if currentUUID == nil {
                currentUUID = action.callUUID
                currentDirection = "outgoing"
                currentNumber = action.handle.value
                currentState = "dialing"
            }
            guard currentUUID == action.callUUID, currentDirection == "outgoing" else {
                throw CallKitBridgeError.staleSystemCall
            }
            dialedOutgoingUUIDs.insert(action.callUUID)
            trimOutgoingDeduplicationState(keeping: action)
            let backendError = try await CallKitActionCoordinator.perform(
                prepare: { try handler.callKitPrepareAudioSession() },
                fulfill: {
                    self.provider.reportOutgoingCall(with: action.callUUID, startedConnectingAt: Date())
                    self.systemCallReported = true
                    // Let CallKit establish the system call and audio session first; cloud dial polling can take up to 25s
                    // and must not block CXStartCallAction, otherwise both system UI and didActivate will lag.
                    action.fulfill()
                },
                backend: { try await handler.callKitStart(number: action.handle.value) }
            )
            // A completed backend request belongs to this CXCall only. The user
            // may have ended it and started another while the request was pending.
            guard currentUUID == action.callUUID else { return }
            if let backendError {
                finishCurrentCall(previous: nil, reason: .failed)
                handler.callKitDidFail(backendError.localizedDescription)
                return
            }
            if currentState == "active" {
                provider.reportOutgoingCall(with: action.callUUID, connectedAt: Date())
            }
        } catch {
            if currentUUID == action.callUUID { resetCurrentCall() }
            fail(action, error: error)
        }
    }

    private func trimOutgoingDeduplicationState(keeping action: CXStartCallAction) {
        guard handledOutgoingActions.count > 32 || dialedOutgoingUUIDs.count > 32 else { return }
        handledOutgoingActions = [ObjectIdentifier(action)]
        dialedOutgoingUUIDs = [action.callUUID]
    }

    private func performEnd(_ action: CXEndCallAction) async {
        let currentHandler = handler
        // reportCall(ended:) may be followed by a delayed CXEndCallAction after
        // the authoritative Agent state already cleared this UUID. That action
        // is cleanup, not a new user hangup whose missing transport needs an alert.
        let systemCallWasCurrent = currentUUID != nil
        var backendError: Error?
        if CallKitEndActionPolicy.shouldForwardToBackend(
            systemCallWasCurrent: systemCallWasCurrent
        ) {
            do {
                guard let currentHandler else { throw CallKitBridgeError.handlerUnavailable }
                try await currentHandler.callKitEnd()
            } catch {
                backendError = error
            }
        }

        // CallKit owns the local system-call lifecycle. A temporarily missing
        // module must not leave the UUID registered after the user hangs up.
        endActionFulfilled = true
        action.fulfill()
        incomingDeduplicator.recordEnded(
            callID: currentBackendID,
            uuid: currentUUID,
            at: Date()
        )
        currentHandler?.callKitCallDidEnd()
        resetCurrentCall()

        if let backendError {
            currentHandler?.callKitDidFail(backendError.localizedDescription)
        }
    }
}

extension CallKitController: CXProviderDelegate {
    nonisolated func providerDidReset(_ provider: CXProvider) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if self.audioSessionIsActive {
                WebRTCCallAudioSession.didDeactivate(AVAudioSession.sharedInstance())
            }
            self.audioSessionIsActive = false
            await self.handler?.callKitProviderDidReset()
            self.resetCurrentCall()
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        Task { @MainActor [weak self] in await self?.performStart(action) }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        Task { @MainActor [weak self] in await self?.performAnswer(action) }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        Task { @MainActor [weak self] in await self?.performEnd(action) }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        Task { @MainActor [weak self] in
            guard let self, let handler = self.handler else {
                action.fail()
                return
            }
            await handler.callKitSetMuted(action.isMuted)
            action.fulfill()
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXPlayDTMFCallAction) {
        Task { @MainActor [weak self] in
            do {
                guard let handler = self?.handler else { throw CallKitBridgeError.handlerUnavailable }
                try await handler.callKitPlayDTMF(action.digits)
                action.fulfill()
            } catch {
                self?.fail(action, error: error)
            }
        }
    }

    nonisolated func provider(
        _ provider: CXProvider,
        didActivate audioSession: AVAudioSession
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if !self.audioSessionIsActive {
                WebRTCCallAudioSession.didActivate(audioSession)
            }
            self.audioSessionIsActive = true
            await AgentVerboseTraceRecorder.shared.recordEvent(
                source: "APP",
                category: "callkit-audio",
                phase: "activated",
                title: "CallKit Audio Session Activated",
                fields: self.audioTraceFields(audioSession)
            )
            await self.handler?.callKitAudioSessionDidActivate()
        }
    }

    nonisolated func provider(
        _ provider: CXProvider,
        didDeactivate audioSession: AVAudioSession
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if self.audioSessionIsActive {
                WebRTCCallAudioSession.didDeactivate(audioSession)
            }
            self.audioSessionIsActive = false
            await AgentVerboseTraceRecorder.shared.recordEvent(
                source: "APP",
                category: "callkit-audio",
                phase: "deactivated",
                title: "CallKit Audio Session Deactivated",
                fields: self.audioTraceFields(audioSession)
            )
            self.handler?.callKitAudioSessionDidDeactivate()
        }
    }

    private func audioTraceFields(_ audioSession: AVAudioSession) -> [String: String] {
        let inputs = audioSession.currentRoute.inputs.map { $0.portType.rawValue }.joined(separator: ",")
        let outputs = audioSession.currentRoute.outputs.map { $0.portType.rawValue }.joined(separator: ",")
        return [
            "call_uuid": currentUUID?.uuidString.lowercased() ?? "none",
            "state": currentState ?? "none",
            "input_route": inputs.isEmpty ? "none" : inputs,
            "output_route": outputs.isEmpty ? "none" : outputs,
            "sample_rate": String(Int(audioSession.sampleRate)),
            "io_buffer_ms": String(Int(audioSession.ioBufferDuration * 1_000)),
        ]
    }
}

enum CallKitBridgeError: LocalizedError {
    case noSystemCall
    case staleSystemCall
    case handlerUnavailable
    case unavailable
    case callInProgress
    case noReachableTransport
    case cloudMediaDisabled

    var errorDescription: String? {
        switch self {
        case .noSystemCall: return "System call has not started"
        case .staleSystemCall: return "System call state refreshed"
        case .handlerUnavailable: return "Call controller is not ready"
        case .unavailable: return "System CallKit is unavailable"
        case .callInProgress: return "A system call is already in progress"
        case .noReachableTransport: return "Android is unreachable locally and through cloud audio"
        case .cloudMediaDisabled: return "Android local connection is unavailable and cloud audio relay is disabled"
        }
    }
}
