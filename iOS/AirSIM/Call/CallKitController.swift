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
    @MainActor
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

    /// An end action acts only on the call it names. Any other UUID is cleanup for a call that already ended or was
    /// replaced, including when the current call changes while the backend request is pending.
    static func targetsCurrentCall(actionCallUUID: UUID, currentCallUUID: UUID?) -> Bool {
        currentCallUUID == actionCallUUID
    }
}

/// How a delivered CXStartCallAction completes. Every disposition except `repeatedDelivery` fulfills or fails the
/// action; a repeated delivery belongs to a transaction whose first delivery does.
enum OutgoingStartActionDisposition: Equatable {
    case repeatedDelivery
    /// The call was already dialed or reported; fulfill without dialing again.
    case fulfill
    /// Another outgoing start is still dialing and the provider allows one call.
    case fail
    case start
}

/// Remembers CXStartCallAction deliveries by transaction UUID. Object addresses are reused once an action is freed, so
/// they cannot tell a new action from a repeated one.
struct OutgoingStartActionLedger {
    private static let retainedLimit = 32
    private var handledActionUUIDs: Set<UUID> = []
    private var dialedCallUUIDs: Set<UUID> = []

    mutating func disposition(
        for action: CXStartCallAction,
        startInFlight: Bool,
        currentOutgoingCallReported: Bool
    ) -> OutgoingStartActionDisposition {
        guard handledActionUUIDs.insert(action.uuid).inserted else { return .repeatedDelivery }
        if dialedCallUUIDs.contains(action.callUUID) { return .fulfill }
        if startInFlight { return .fail }
        if currentOutgoingCallReported { return .fulfill }
        return .start
    }

    mutating func recordDialed(_ action: CXStartCallAction) {
        dialedCallUUIDs.insert(action.callUUID)
        guard handledActionUUIDs.count > Self.retainedLimit || dialedCallUUIDs.count > Self.retainedLimit else {
            return
        }
        handledActionUUIDs = [action.uuid]
        dialedCallUUIDs = [action.callUUID]
    }
}

/// Why an incoming PushKit call cannot become or repeat the current system call.
enum IncomingPushRejection: String, Equatable {
    case unavailable
    case recentlyEnded
    case callInProgress
}

/// How an incoming PushKit call reaches CallKit. iOS 13+ terminates an app that completes a VoIP push without
/// reporting a call, and repeated misses stop VoIP delivery, so a push that cannot share the current call's report is
/// reported as a placeholder that ends at once.
enum IncomingPushDisposition: Equatable {
    /// No call is current; the push becomes the current call and is reported.
    case reportNewCall
    /// The push repeats the current call, which CallKit already shows.
    case currentCallReported
    /// The push repeats the current call before CallKit shows it and completes with that call's report.
    case awaitCurrentCallReport
    /// The push repeats the current call after its report failed, which left no report to wait for.
    case currentCallPlaceholder
    /// The push cannot become the current call, so it must not ring the Watch or update the in-app call.
    case rejected(IncomingPushRejection)
}

enum IncomingPushPolicy {
    static func disposition(
        callKitAvailable: Bool,
        recentlyEnded: Bool,
        hasCurrentCall: Bool,
        matchesCurrentCall: Bool,
        currentCallReported: Bool,
        currentReportFailed: Bool
    ) -> IncomingPushDisposition {
        guard callKitAvailable else { return .rejected(.unavailable) }
        guard !recentlyEnded else { return .rejected(.recentlyEnded) }
        guard hasCurrentCall else { return .reportNewCall }
        guard matchesCurrentCall else { return .rejected(.callInProgress) }
        if currentCallReported { return .currentCallReported }
        return currentReportFailed ? .currentCallPlaceholder : .awaitCurrentCallReport
    }

    /// A placeholder reuses the payload UUID unless it names the current system call, which must not be ended.
    static func placeholderUUID(payloadUUID: UUID?, currentCallUUID: UUID?) -> UUID {
        if let payloadUUID, payloadUUID != currentCallUUID { return payloadUUID }
        return UUID()
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

/// Maintains a 1-to-1 mapping between module calls and system call UUIDs, handling lock-screen and system call UI
/// actions.
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
    private var outgoingStartActions = OutgoingStartActionLedger()
    private var appAnswerRequestUUID: UUID?
    private var incomingReportCompletions: [(Error?) -> Void] = []
    private var placeholderReportCompletions: [UUID: () -> Void] = [:]
    private var incomingDeduplicator = IncomingCallDeduplicator()
    private(set) var currentIncomingPush: IncomingVoIPCall?

    private override init() {
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

    /// Ends local CallKit immediately once a paired device takes over the same call to prevent dual ringing or media
    /// contention.
    func reportCurrentCallEnded(reason: CXCallEndedReason) {
        finishCurrentCall(previous: nil, reason: reason)
    }

    func reportCurrentOutgoingConnected() {
        guard currentDirection == "outgoing",
            let uuid = currentUUID,
            currentState != "active",
            systemCallReported
        else { return }
        currentState = "active"
        provider.reportOutgoingCall(with: uuid, connectedAt: Date())
    }

    /// PushKit cold launch must immediately hand the incoming call to the system. Subsequent USB status sync reuses
    /// the same call_id/UUID without creating a duplicate system call. Every push is reported to CallKit before
    /// `completion` runs; returns whether the push is for the current call.
    func reportIncomingPush(
        _ call: IncomingVoIPCall,
        completion: @escaping (Error?) -> Void
    ) -> Bool {
        let disposition = IncomingPushPolicy.disposition(
            callKitAvailable: isAvailable,
            recentlyEnded: !incomingDeduplicator.shouldAccept(callID: call.callID, uuid: call.uuid),
            hasCurrentCall: currentUUID != nil,
            matchesCurrentCall: call.matches(backendID: currentBackendID, uuid: currentUUID),
            currentCallReported: systemCallReported,
            currentReportFailed: incomingReportFailed
        )
        switch disposition {
        case .rejected(let rejection):
            debugLog("Reporting ended placeholder for rejected PushKit event; reason=\(rejection.rawValue)")
            let error: Error? =
                switch rejection {
                case .unavailable: CallKitBridgeError.unavailable
                case .callInProgress: CallKitBridgeError.callInProgress
                case .recentlyEnded: nil
                }
            reportEndedPlaceholder(payloadUUID: call.uuid) { completion(error) }
            return false
        case .currentCallReported, .awaitCurrentCallReport, .currentCallPlaceholder:
            currentIncomingPush = call
            currentBackendID = call.callID
            currentNumber = call.number ?? currentNumber
            if disposition == .currentCallReported {
                handler?.callKitDidReceiveIncoming(call)
                completion(nil)
                prepareIncomingCloudMediaIfNeeded()
                return true
            }
            if disposition == .currentCallPlaceholder {
                reportEndedPlaceholder(payloadUUID: call.uuid) { completion(nil) }
            } else {
                incomingReportCompletions.append(completion)
                reportIncomingIfNeeded(number: currentNumber, callerName: call.callerName, source: "PushKit Redelivery")
            }
            handler?.callKitDidReceiveIncoming(call)
            return true
        case .reportNewCall:
            break
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
        return true
    }

    /// Satisfies the PushKit rule for a push that cannot use the current call's report: reports a placeholder call, ends
    /// it at once and completes the push when CallKit answers. The provider stays usable while CallKit calls are
    /// disabled for local mode; if the system refuses the report, the push still completes.
    func reportEndedPlaceholder(payloadUUID: UUID?, completion: @escaping () -> Void) {
        let uuid = IncomingPushPolicy.placeholderUUID(payloadUUID: payloadUUID, currentCallUUID: currentUUID)
        let requestID = UUID()
        placeholderReportCompletions[requestID] = completion
        provider.reportNewIncomingCall(with: uuid, update: update(number: nil, callerName: nil)) { @Sendable error in
            Task { @MainActor in
                self.finishEndedPlaceholder(requestID: requestID, uuid: uuid, reported: error == nil)
            }
        }
    }

    private func finishEndedPlaceholder(requestID: UUID, uuid: UUID, reported: Bool) {
        // A failed report (for example a UUID CallKit still shows) must not end that existing call.
        if reported {
            provider.reportCall(with: uuid, endedAt: Date(), reason: .failed)
        } else {
            debugLog("System refused ended placeholder for PushKit event")
        }
        placeholderReportCompletions.removeValue(forKey: requestID)?()
    }

    /// Lets the system take over the outgoing call transaction first; the actual module ATD is executed only inside the
    /// CXProvider delegate callback.
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
        guard !callID.isEmpty,
            currentDirection == "outgoing",
            currentUUID != nil,
            currentBackendID == nil || currentBackendID == callID
        else { return }
        currentBackendID = callID
    }

    func performLiveActivityAction(_ action: AirSIMLiveActivityAction, callID: String) async throws {
        guard managesCurrentCall else { throw LiveActivityCallError.unavailable }
        guard
            try LiveActivityCallActionPolicy.shouldPerform(
                action,
                callID: callID,
                currentCallID: currentBackendID,
                state: currentState,
                direction: currentDirection
            )
        else { return }
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

    /// In-app keypad digits also go through CallKit transactions so the system call screen and in-app UI do not
    /// maintain separate DTMF states.
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
        // Keep only the in-app state machine once CallKit is denied by the system; do not continue fabricating system
        // call UUIDs.
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
                        currentBackendID: currentBackendID,
                        endedID: previous.id
                    )
                else { return }
                finishCurrentCall(previous: previous)
                return
            }
            // An occasional empty AT+CLCC response does not mean the call ended; retain the UUID so speaker/mute
            // transactions do not fail with unknown UUID.
            if currentDirection == "outgoing", outgoingStartInFlight { return }
            if currentUUID != nil, systemCallReported || currentDirection == "outgoing" {
                missingCallPolls += 1
                guard missingCallPolls >= 3 else { return }
            }
            finishCurrentCall(previous: previous)
            return
        }

        if call.direction == "outgoing" {
            // Synchronize only system outgoing calls started via startOutgoingCall; do not fabricate UUIDs for external
            // ATD calls.
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
            !incomingDeduplicator.shouldAccept(callID: call.id, uuid: nil)
        {
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
                guard let self, self.currentUUID == uuid else { return }
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
                    self.handler?.callKitDidFail(
                        "Unable to show system incoming call screen: \(error.localizedDescription)"
                    )
                    self.finishIncomingReport(error)
                } else {
                    self.debugLog("System incoming call reported successfully")
                    self.systemCallReported = true
                    self.finishIncomingReport(nil)
                    self.prepareIncomingCloudMediaIfNeeded()
                }
            }
        }
    }

    private func prepareIncomingCloudMediaIfNeeded() {
        guard CloudModePreference.isEnabled(), systemCallReported,
            currentDirection == "incoming", currentState == "incoming",
            let incoming = currentIncomingPush, incoming.uuid == currentUUID
        else { return }
        IPhoneCloudCallSession.shared.prewarmIncoming(incoming)
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
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
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
                nsError.code == CXErrorCodeRequestTransactionError.Code.unknownCallUUID.rawValue
            {
                throw CallKitBridgeError.staleSystemCall
            }
            throw error
        }
    }

    /// Personal team signing or restricted devices may return requesttransaction/unentitled; automatically fall back to
    /// in-app calls.
    private func disableCallKitIfUnentitled(_ error: Error) -> Bool {
        let error = error as NSError
        guard error.domain == CXErrorDomainRequestTransaction,
            error.code == CXErrorCodeRequestTransactionError.Code.unentitled.rawValue
        else {
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
        if let incoming = currentIncomingPush {
            IPhoneCloudCallSession.shared.discardIncomingPrewarm(incoming)
        }
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
                    // The system transaction confirms only that the user accepted the call. Cloud WebSocket, Telecom,
                    // and WebRTC
                    // are established asynchronously afterward and must not block CallKit from activating
                    // AVAudioSession.
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
        switch outgoingStartActions.disposition(
            for: action,
            startInFlight: outgoingStartInFlight,
            currentOutgoingCallReported: systemCallReported && currentUUID == action.callUUID
                && currentDirection == "outgoing"
        ) {
        case .repeatedDelivery:
            return
        case .fulfill:
            action.fulfill()
            return
        case .fail:
            // Not reported to the handler: that would cancel the outgoing attempt that is still dialing.
            debugLog("Failing outgoing start while another start is in flight")
            action.fail()
            return
        case .start:
            break
        }
        outgoingStartInFlight = true
        let operationID = UUID()
        outgoingStartID = operationID
        defer {
            if outgoingStartID == operationID { outgoingStartInFlight = false }
        }
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
            outgoingStartActions.recordDialed(action)
            let backendError = try await CallKitActionCoordinator.perform(
                prepare: { try handler.callKitPrepareAudioSession() },
                fulfill: {
                    self.provider.reportOutgoingCall(with: action.callUUID, startedConnectingAt: Date())
                    self.systemCallReported = true
                    // Let CallKit establish the system call and audio session first; cloud dial polling can take up to
                    // 25s
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

    private func performEnd(_ action: CXEndCallAction) async {
        let currentHandler = handler
        // reportCall(ended:) may be followed by a delayed CXEndCallAction after
        // the authoritative Agent state already cleared or replaced this UUID,
        // and an ended placeholder may be declined. That action is cleanup, not
        // a hangup of whichever call is current now.
        let endedUUID = action.callUUID
        let systemCallWasCurrent = CallKitEndActionPolicy.targetsCurrentCall(
            actionCallUUID: endedUUID,
            currentCallUUID: currentUUID
        )
        guard CallKitEndActionPolicy.shouldForwardToBackend(systemCallWasCurrent: systemCallWasCurrent) else {
            action.fulfill()
            return
        }
        let endedBackendID = currentBackendID
        // Unlike start/answer, the action stays pending until the hangup or reject
        // is sent: callKitEnd picks its route from this call's push and answer
        // state, and callKitCallDidEnd tears down the session it uses.
        var backendError: Error?
        do {
            guard let currentHandler else { throw CallKitBridgeError.handlerUnavailable }
            try await currentHandler.callKitEnd()
        } catch {
            backendError = error
        }

        // A call that ended or was replaced during the request was finished by
        // that path; recording or resetting now would end the current call.
        guard CallKitEndActionPolicy.targetsCurrentCall(actionCallUUID: endedUUID, currentCallUUID: currentUUID) else {
            action.fulfill()
            return
        }
        // CallKit owns the local system-call lifecycle. A temporarily missing
        // module must not leave the UUID registered after the user hangs up.
        endActionFulfilled = true
        action.fulfill()
        incomingDeduplicator.recordEnded(
            callID: currentBackendID ?? endedBackendID,
            uuid: endedUUID,
            at: Date()
        )
        currentHandler?.callKitCallDidEnd()
        resetCurrentCall()

        if let backendError {
            currentHandler?.callKitDidFail(backendError.localizedDescription)
        }
    }
}

extension CallKitController: @preconcurrency CXProviderDelegate {
    func providerDidReset(_ provider: CXProvider) {
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

    func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        Task { @MainActor [weak self] in await self?.performStart(action) }
    }

    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        Task { @MainActor [weak self] in await self?.performAnswer(action) }
    }

    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        Task { @MainActor [weak self] in await self?.performEnd(action) }
    }

    func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        Task { @MainActor [weak self] in
            guard let self, let handler = self.handler else {
                action.fail()
                return
            }
            await handler.callKitSetMuted(action.isMuted)
            action.fulfill()
        }
    }

    func provider(_ provider: CXProvider, perform action: CXPlayDTMFCallAction) {
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

    func provider(
        _ provider: CXProvider,
        didActivate audioSession: AVAudioSession
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if !self.audioSessionIsActive {
                WebRTCCallAudioSession.didActivate(audioSession)
            }
            self.audioSessionIsActive = true
            let fields = self.audioTraceFields(audioSession)
            // File-backed diagnostics must not delay the cloud/local audio start below.
            Task {
                await AgentVerboseTraceRecorder.shared.recordEvent(
                    source: "APP",
                    category: "callkit-audio",
                    phase: "activated",
                    title: "CallKit Audio Session Activated",
                    fields: fields
                )
            }
            await self.handler?.callKitAudioSessionDidActivate()
        }
    }

    func provider(
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
