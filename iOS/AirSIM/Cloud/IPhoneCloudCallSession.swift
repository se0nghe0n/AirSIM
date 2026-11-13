import AVFoundation
import CallKit
import Foundation
import UIKit
import WebRTC

enum IPhoneCloudCallError: LocalizedError {
    case mediaUnavailable
    case microphonePermissionDenied
    case microphoneUnavailable
    case invalidAudioFormat
    case connectionClosed

    var errorDescription: String? {
        switch self {
        case .mediaUnavailable: return "Incoming call has no cloud media credentials"
        case .microphonePermissionDenied: return "Microphone access is required for cloud calls"
        case .microphoneUnavailable: return "No microphone input is currently available"
        case .invalidAudioFormat: return "Unable to create cloud call audio format"
        case .connectionClosed: return "Module cloud audio connection closed"
        }
    }
}

enum CloudCallAudioState: Equatable, Sendable {
    case idle
    case starting
    case connecting(attempt: Int, maximumAttempts: Int)
    case connected
    case failed(String)

    var isConnected: Bool { self == .connected }

    var isRetrying: Bool {
        if case .connecting = self { return true }
        return false
    }

    /// A native ICE disconnect before cloud audio was ever ready is not a retry. Showing
    /// "Retrying" there would persist until carrier audio is ready, though nothing failed.
    func afterNativeDisconnect(maximumAttempts: Int) -> CloudCallAudioState {
        isConnected ? .connecting(attempt: 1, maximumAttempts: maximumAttempts) : self
    }
}

struct CloudCarrierRouteRecovery: Sendable {
    static let message =
        "Android’s call-audio route is unavailable. Automatic audio retries have stopped. End the call, then restart the Android phone and reconnect Shizuku."
    private var callUUID: UUID?
    private var generation: UInt64?
    private(set) var required = false

    mutating func begin(uuid: UUID, generation: UInt64) {
        guard callUUID != uuid || self.generation != generation else { return }
        callUUID = uuid
        self.generation = generation
        required = false
    }

    mutating func receive(_ control: CloudCallControlMessage, callID: String) -> Bool {
        guard control.status == "agent_media_failed",
            control.message == "carrier_route_recovery_required",
            let callUUID, let generation,
            control.callUUID?.lowercased() == callUUID.uuidString.lowercased(),
            control.generation == generation,
            control.matches(callID: callID, uuid: callUUID, generation: generation)
        else { return false }
        required = true
        return true
    }

    func allowsControl(status: String) -> Bool {
        !required || ["ownership_lost", "rejected", "ended", "remote_ended", "active"].contains(status)
    }

    func audioState(_ proposed: CloudCallAudioState) -> CloudCallAudioState {
        required ? .failed(Self.message) : proposed
    }
}

enum CloudCallAudioStartupPolicy {
    static func shouldStart(
        answered: Bool,
        mediaPrepared: Bool,
        lifecycleState: CallLifecycleState,
        isOutgoing: Bool,
        managedByCallKit: Bool,
        callKitAudioSessionActive: Bool
    ) -> Bool {
        guard answered, mediaPrepared else { return false }
        // Acceptance permits arming startup before Android confirms ACTIVE. The session still
        // requires answerAcknowledged and CallKit activation before creating a peer.
        guard lifecycleState == .active || lifecycleState == .connecting else {
            return false
        }
        return !managedByCallKit || callKitAudioSessionActive
    }
}

enum CloudMediaHealthIssue: String, Equatable, Sendable {
    case connectionLost = "connection_lost"
}

struct CloudMediaHealthSnapshot: Equatable, Sendable {
    var rebuildCount: Int = 0
    var audioRoute = "unknown"
}

struct CloudMediaHealthTracker: Sendable {
    private let maximumRebuilds: Int
    private(set) var snapshot = CloudMediaHealthSnapshot()

    init(maximumRebuilds: Int = 3) {
        self.maximumRebuilds = max(0, maximumRebuilds)
    }

    mutating func recordRoute(_ route: String) {
        let normalized = route.trimmingCharacters(in: .whitespacesAndNewlines)
        snapshot.audioRoute = normalized.isEmpty ? "unknown" : normalized
    }

    @discardableResult
    mutating func beginRebuild() -> Bool {
        guard snapshot.rebuildCount < maximumRebuilds else { return false }
        snapshot.rebuildCount += 1
        return true
    }
}

enum CloudMediaTransport: String, Codable, CaseIterable, Sendable {
    case legacyPCM = "legacy_pcm"
    case webRTC = "webrtc"
}

enum CloudMediaTransportNegotiationError: Error, Equatable {
    case unsupported
}

enum CloudMediaTransportNegotiator {
    /// The only successful cloud carrier is WebRTC. `legacy_pcm` and the
    /// obsolete legacy preference never select another carrier.
    static func resolve(
        requested: CloudMediaTransport,
        appSupported: Set<CloudMediaTransport>,
        agentSupported: Set<CloudMediaTransport>
    ) -> Result<CloudMediaTransport, CloudMediaTransportNegotiationError> {
        guard requested == .webRTC,
            appSupported.contains(.webRTC),
            agentSupported.contains(.webRTC)
        else {
            return .failure(.unsupported)
        }
        return .success(.webRTC)
    }
}

enum CloudCallRetryPolicy {
    static let reconnectDelays: [TimeInterval] = [0.4, 1, 2, 4]
}

@MainActor
enum CloudCallRecoveryCoordinator {
    static func run(
        delays: [TimeInterval],
        isCurrent: () -> Bool,
        connect: (Int) async throws -> Void,
        connected: () -> Void,
        failed: (Error) -> Void
    ) async {
        var lastError: Error = IPhoneCloudCallError.connectionClosed
        for (index, delay) in delays.enumerated() {
            guard !Task.isCancelled, isCurrent() else { return }
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled, isCurrent() else { return }
            do {
                try await connect(index)
                guard !Task.isCancelled, isCurrent() else { return }
                connected()
                return
            } catch {
                guard !Task.isCancelled, isCurrent() else { return }
                lastError = error
            }
        }
        guard !Task.isCancelled, isCurrent() else { return }
        failed(lastError)
    }
}

enum CloudCallAnswerPolicy {
    // Agent ATA waits up to ~5 seconds; retry intervals must not create a high-frequency control-frame storm.
    static let confirmationDelays: [TimeInterval] = [0, 3, 3, 4, 5]

    static func isAcknowledged(status: String) -> Bool {
        status == "answer_ok" || status == "active" || status == "media_prepared"
    }

    static func shouldReplayImmediately(status: String) -> Bool {
        status == "agent_ready"
    }

    /// "Not yet" replies (Telecom not bound, old peer still releasing, Relay admission from a
    /// stale heartbeat) resend the answer after this delay instead of the next 3–5 s slot.
    static let quickReplayDelay: TimeInterval = 1

    /// An outgoing owner join reaches the Agent right after the dial result, often before Telecom has bound the
    /// call, so its first `answer_pending` is retried early.
    static let outgoingFirstPendingReplayDelay: TimeInterval = 0.3

    /// Delay before the resend that follows a "not yet" reply. `priorOutgoingPendingReplays` counts the resends
    /// already scheduled for `answer_pending` on this outgoing call. The second one completes the regular
    /// interval, so an outgoing join is never confirmed later than with `quickReplayDelay` alone; after that the
    /// regular interval applies. Incoming calls and other replies always use `quickReplayDelay`.
    static func quickReplayDelay(
        status: String,
        isOutgoing: Bool,
        priorOutgoingPendingReplays: Int
    ) -> TimeInterval {
        guard isOutgoing, status == "answer_pending" else { return quickReplayDelay }
        switch priorOutgoingPendingReplays {
        case 0: return outgoingFirstPendingReplayDelay
        case 1: return quickReplayDelay - outgoingFirstPendingReplayDelay
        default: return quickReplayDelay
        }
    }

    static func shouldReplaySoon(status: String, action: String?) -> Bool {
        guard action == nil || action == "answer" else { return false }
        return status == "answer_pending" || status == "action_error" || status == "action_rejected"
    }
}

enum CloudOutgoingPrewarmPolicy {
    /// The call ended before it was answered here. The prewarmed socket is released; `answer()`, if it still
    /// comes, then connects as before and receives the terminal status on that connection.
    static func endsPrewarm(status: String) -> Bool {
        ["remote_ended", "ended", "rejected", "ownership_lost"].contains(status)
    }
}

enum CloudWebRTCFailurePolicy {
    /// Relay rejections carry no session id. "peer unavailable" and "stale signaling session"
    /// mean the agent socket is away or its negotiation was cleared; the Relay's
    /// peer_connected(agent) already renegotiates, so tearing down this socket only costs time.
    static func requiresRebuild(sessionID: UUID?, currentSessionID: UUID?, error: String?) -> Bool {
        if let sessionID { return sessionID == currentSessionID }
        let error = error ?? ""
        return !(error.hasPrefix("peer unavailable") || error == "stale signaling session")
    }
}

enum CloudCallTerminationCoordinator {
    static func finish(
        closeMedia: @Sendable @MainActor () async -> Void,
        enqueuePersistentControl: @Sendable @MainActor () async -> Void
    ) async {
        await closeMedia()
        await enqueuePersistentControl()
    }
}

struct CloudCallControlMessage: Equatable, Sendable {
    func matches(callID: String, uuid: UUID, generation: UInt64) -> Bool {
        (self.callID == nil || self.callID == callID)
            && (callUUID == nil || callUUID?.lowercased() == uuid.uuidString.lowercased())
            && (self.generation == nil || self.generation == generation)
    }

    let status: String
    let role: String?
    let sessionID: UUID?
    let message: String?
    var error: String? = nil
    let action: String?
    let callID: String?
    let callUUID: String?
    let generation: UInt64?
    let commandID: String?
    let traceID: String?

    private struct Payload: Decodable {
        let status: String?
        let role: String?
        let sessionID: UUID?
        let event: String?
        let message: String?
        let error: String?
        let action: String?
        let callID: String?
        let callUUID: String?
        let generation: UInt64?
        let commandID: String?
        let traceID: String?

        enum CodingKeys: String, CodingKey {
            case status, event, message, role, error
            case sessionID = "session_id"
            case action, generation
            case callID = "call_id"
            case callUUID = "call_uuid"
            case commandID = "command_id"
            case traceID = "trace_id"
        }
    }

    static func decode(_ text: String) throws -> CloudCallControlMessage? {
        guard let data = text.data(using: .utf8) else { return nil }
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        guard let status = payload.status ?? payload.event else { return nil }
        return CloudCallControlMessage(
            status: status,
            role: payload.role,
            sessionID: payload.sessionID,
            message: payload.message,
            error: payload.error,
            action: payload.action,
            callID: payload.callID,
            callUUID: payload.callUUID,
            generation: payload.generation,
            commandID: payload.commandID,
            traceID: payload.traceID
        )
    }

    var traceFields: [String: String] {
        var fields: [String: String] = [:]
        if let role { fields["role"] = role }
        if let action { fields["action"] = action }
        if let callID { fields["call_id"] = callID }
        if let callUUID { fields["call_uuid"] = callUUID }
        if let generation { fields["generation"] = String(generation) }
        if let commandID { fields["command_id"] = commandID }
        if let traceID { fields["trace_id"] = traceID }
        return fields
    }
}

struct CloudCallControlEnvelope: Codable, Equatable, Sendable {
    let action: String
    let callID: String
    let callUUID: String
    let generation: UInt64
    let commandID: String
    let traceID: String

    enum CodingKeys: String, CodingKey {
        case action, generation
        case callID = "call_id"
        case callUUID = "call_uuid"
        case commandID = "command_id"
        case traceID = "trace_id"
    }
}

struct CloudCallControlCredentials: Equatable, Sendable {
    let relayURL: String
    let deviceID: String
    let deviceSecret: String
}

struct CloudCallControlReceipt: Decodable, Equatable, Sendable {
    struct Result: Decodable, Equatable, Sendable {
        let ended: Bool?
        let modemConfirmed: Bool?
        let androidConfirmed: Bool?
        let clccAttempts: Int?
        let lastCLCC: String?

        enum CodingKeys: String, CodingKey {
            case ended
            case modemConfirmed = "modem_confirmed"
            case androidConfirmed = "android_confirmed"
            case clccAttempts = "clcc_attempts"
            case lastCLCC = "last_clcc"
        }
    }

    let accepted: Bool?
    let commandID: String
    let status: String
    let agentConnected: Bool?
    let rescueCommandID: String?
    let result: Result?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case accepted, status, result, error
        case commandID = "command_id"
        case agentConnected = "agent_connected"
        case rescueCommandID = "rescue_command_id"
    }

    var isFinal: Bool {
        status == "completed" || status == "failed" || status == "expired"
    }

    var cellularEndConfirmed: Bool {
        guard status == "completed" else { return false }
        return result?.modemConfirmed == true
            || (result?.ended == true && result?.androidConfirmed == true)
    }

    var confirmationPhase: String {
        let confirmation = result?.modemConfirmed == true ? "modem_confirmed" : "android_confirmed"
        return rescueCommandID == nil ? confirmation : "rescue_\(confirmation)"
    }
}

enum CloudCallControlClientError: LocalizedError {
    case invalidRelayURL
    case invalidResponse
    case rejected(String)
    case timeout

    var errorDescription: String? {
        switch self {
        case .invalidRelayURL: return "Invalid Relay URL"
        case .invalidResponse: return "Relay returned an invalid call control response"
        case let .rejected(message): return message
        case .timeout: return "Timed out waiting for Agent call control confirmation"
        }
    }
}

enum CloudCallControlClient {
    private struct Submission: Encodable {
        let action: String
        let callID: String
        let callUUID: String
        let generation: UInt64
        let commandID: String
        let traceID: String
        let owner = "iphone"
        let deviceID: String
        let deviceSecret: String

        enum CodingKeys: String, CodingKey {
            case action, generation, owner
            case callID = "call_id"
            case callUUID = "call_uuid"
            case commandID = "command_id"
            case traceID = "trace_id"
            case deviceID = "device_id"
            case deviceSecret = "device_secret"
        }
    }

    static func submissionRequest(
        envelope: CloudCallControlEnvelope,
        credentials: CloudCallControlCredentials
    ) throws -> URLRequest {
        guard
            let url = RelayEndpoint.url(
                base: credentials.relayURL,
                path: "/v1/calls/\(envelope.callUUID)/actions"
            )
        else { throw CloudCallControlClientError.invalidRelayURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 8
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            Submission(
                action: envelope.action,
                callID: envelope.callID,
                callUUID: envelope.callUUID,
                generation: envelope.generation,
                commandID: envelope.commandID,
                traceID: envelope.traceID,
                deviceID: credentials.deviceID,
                deviceSecret: credentials.deviceSecret
            )
        )
        return request
    }

    static func resultRequest(
        envelope: CloudCallControlEnvelope,
        credentials: CloudCallControlCredentials
    ) throws -> URLRequest {
        guard
            let url = RelayEndpoint.url(
                base: credentials.relayURL,
                path: "/v1/calls/\(envelope.callUUID)/actions/\(envelope.commandID)"
            )
        else { throw CloudCallControlClientError.invalidRelayURL }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 8
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(credentials.deviceSecret)", forHTTPHeaderField: "Authorization")
        request.setValue(credentials.deviceID, forHTTPHeaderField: "X-AirSIM-Device-ID")
        return request
    }

    static func submit(
        envelope: CloudCallControlEnvelope,
        credentials: CloudCallControlCredentials,
        session: URLSession = URLSession(configuration: .ephemeral)
    ) async throws -> CloudCallControlReceipt {
        try await execute(
            submissionRequest(envelope: envelope, credentials: credentials),
            session: session,
            acceptedStatusCodes: 200...202
        )
    }

    static func awaitFinalReceipt(
        envelope: CloudCallControlEnvelope,
        credentials: CloudCallControlCredentials,
        session: URLSession = URLSession(configuration: .ephemeral),
        timeout: TimeInterval = 30
    ) async throws -> CloudCallControlReceipt {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let receipt: CloudCallControlReceipt = try await execute(
                resultRequest(envelope: envelope, credentials: credentials),
                session: session,
                acceptedStatusCodes: 200...200
            )
            if receipt.isFinal { return receipt }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw CloudCallControlClientError.timeout
    }

    private static func execute<T: Decodable>(
        _ request: URLRequest,
        session: URLSession,
        acceptedStatusCodes: ClosedRange<Int>
    ) async throws -> T {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CloudCallControlClientError.invalidResponse
        }
        guard acceptedStatusCodes.contains(http.statusCode) else {
            let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw CloudCallControlClientError.rejected(
                detail ?? "Relay rejected call control (HTTP \(http.statusCode))"
            )
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw CloudCallControlClientError.invalidResponse
        }
    }
}

/// iPhone cloud call session. PushKit media keys are kept in memory only;
/// WebRTC starts only after CallKit activates AVAudioSession, while the control WebSocket can answer module calls
/// early.
@MainActor
final class IPhoneCloudCallSession {
    static let shared = IPhoneCloudCallSession()

    private let media = IPhoneCloudCallMediaBridge()
    private(set) var call: IncomingVoIPCall?
    private(set) var answered = false
    private(set) var lifecycleState: CallLifecycleState = .idle

    private var carrierRouteRecovery = CloudCarrierRouteRecovery()
    private var currentAudioState: CloudCallAudioState = .idle
    private(set) var audioState: CloudCallAudioState {
        get { currentAudioState }
        set {
            let next = carrierRouteRecovery.audioState(newValue)
            guard next != currentAudioState else { return }
            currentAudioState = next
            onAudioStateChange?(next)
        }
    }

    private(set) var mediaHealthSnapshot = CloudMediaHealthSnapshot()
    var onAudioStateChange: ((CloudCallAudioState) -> Void)?
    var onLifecycleEvent: ((CallLifecycleEvent) -> Void)?
    private var reconnectTask: Task<Void, Never>?
    private var reconnectID = UUID()
    private var mediaHealthTracker: CloudMediaHealthTracker?
    private var answerRetryTask: Task<Void, Never>?
    private var answerRetryGeneration = 0
    private var quickAnswerReplayTask: Task<Void, Never>?
    private var outgoingPendingReplays = 0
    private let outgoingPrewarm = CloudOutgoingPrewarm()
    private var preDial = CloudPreDialGate()
    private var preparedCarrierSession: UUID?

    private var incomingPreparation: IncomingVoIPCall?
    private var incomingPreparationExpiry: Task<Void, Never>?
    private var setupTimeline: OutgoingCallSetupTimeline?
    private let icePreparation = CloudICEPreparation()
    private let answerHandshake = CloudWebRTCAnswerHandshake()
    private var answerAcknowledged: Bool { answerHandshake.acknowledged }
    private var webRTCReadiness = CloudWebRTCReadiness()
    private var webRTCStartTask: Task<Void, Never>?
    private var webRTCStartID = UUID()
    private var audioStartupPermitted = false
    private var audioSetupStartedAt: TimeInterval?
    private var ownsWebRTCAudioActivation = false
    private var usesWebRTC: Bool { call?.requestedMediaTransport == .webRTC }

    var isPrepared: Bool { call != nil && media.isConnected }
    var hasActiveCall: Bool { call != nil && answered && lifecycleState == .active }

    private var canAttemptAudio: Bool {
        !carrierRouteRecovery.required && call != nil && answered && isPrepared
            && (lifecycleState == .connecting || lifecycleState == .active)
    }

    var isRecovering: Bool { reconnectTask != nil }

    private init() {
        media.onWebRTCState = { connected, connection, negotiation in
            Task { @MainActor in
                let session = IPhoneCloudCallSession.shared
                if session.call == nil, let pending = session.outgoingPrewarm.entry?.call,
                    session.media.isCurrentWebRTCSession(negotiation, connection: connection)
                {
                    if connected {
                        session.preDial.nativeConnected(negotiation)
                        session.tracePreDial("native_connected")
                        session.markPreDial(.transportConnected)
                        session.media.sendTransportControl(
                            "webrtc_transport_ready",
                            call: pending,
                            sessionID: negotiation
                        )
                    } else {
                        session.preDial.fail("native_transport_failed")
                    }
                    return
                }
                guard !session.carrierRouteRecovery.required, session.usesWebRTC,
                    session.media.isCurrentWebRTCSession(negotiation, connection: connection)
                else { return }
                if connected {
                    session.webRTCReadiness.nativeConnected(negotiation)
                    session.traceAudio(phase: "native_connected", title: "WebRTC Connected")
                    session.markSetup(.nativeConnected)
                    if session.webRTCReadiness.isReady, session.media.isAudioRunning, !session.audioState.isConnected {
                        session.audioState = .connected
                        session.traceAudio(phase: "audio_ready", title: "Cloud Audio Ready")
                        session.markSetup(.audioReady)
                    }
                } else {
                    session.webRTCReadiness.reset()
                    session.requestMediaRebuild(.connectionLost)
                }
            }
        }
        media.onWebRTCRecovering = { connection, negotiation in
            Task { @MainActor in
                let session = IPhoneCloudCallSession.shared
                guard !session.carrierRouteRecovery.required,
                    session.media.isCurrentWebRTCSession(negotiation, connection: connection)
                else { return }
                if session.call == nil, session.outgoingPrewarm.entry != nil {
                    session.preDial.fail("native_transport_disconnected")
                    return
                }
                session.webRTCReadiness.nativeDisconnected(negotiation)
                session.traceAudio(phase: "native_disconnected", title: "WebRTC Path Interrupted")
                session.audioState = session.audioState.afterNativeDisconnect(
                    maximumAttempts: CloudCallRetryPolicy.reconnectDelays.count
                )
            }
        }
        media.onConnectionLost = { connection in
            Task { @MainActor in
                let session = IPhoneCloudCallSession.shared
                // A prewarmed socket that drops is not a media failure: before `answer()` there is no call, and
                // during adoption `answer()` falls back to its own connect.
                if session.media.isCurrentConnection(connection) {
                    session.outgoingPrewarm.entry?.acceptance.invalidate()
                    if session.outgoingPrewarm.entry != nil {
                        session.preDial.fail("signaling_lost")
                        session.markPreDial(.preparationFailed)
                    }
                }
                guard !session.carrierRouteRecovery.required, session.call != nil,
                    !session.outgoingPrewarm.isAdopting,
                    session.media.isCurrentConnection(connection)
                else { return }
                session.answerHandshake.invalidate()
                session.requestMediaRebuild(.connectionLost)
            }
        }
        media.onOwnerJoinSent = { call, connection, sentAt in
            Task { @MainActor in
                let session = IPhoneCloudCallSession.shared
                guard call.isOutgoing, session.call?.uuid == call.uuid, session.call?.generation == call.generation,
                    session.media.isCurrentConnection(connection), session.setupTimeline?.covers(call.uuid) == true
                else { return }
                session.setupTimeline?.mark(.ownerJoinSent, at: sentAt)
            }
        }
        media.onControl = { control, connection in
            Task { @MainActor in
                let session = IPhoneCloudCallSession.shared
                let status = control.status
                if session.call == nil, let pending = session.outgoingPrewarm.entry?.call,
                    session.media.isCurrentConnection(connection)
                {
                    session.preDial.receive(control, call: pending)
                    if control.callID == pending.callID,
                        control.callUUID?.lowercased() == pending.uuid.uuidString.lowercased(),
                        control.generation == pending.generation
                    {
                        if status == "pre_dial_peer_ready" { session.markPreDial(.peerAdmissionReady) }
                        if status == "pre_dial_ready", control.sessionID == session.preDial.sessionID {
                            session.markPreDial(.transportsReady)
                        }
                        if session.preDial.failure != nil { session.markPreDial(.preparationFailed) }
                    }
                    if status == "webrtc_ready", let negotiation = control.sessionID,
                        negotiation == session.preDial.sessionID,
                        control.matches(callID: pending.callID, uuid: pending.uuid, generation: pending.generation)
                    {
                        session.preparedCarrierSession = negotiation
                    }
                }
                let relayStatuses = ["action_queued", "action_forwarded", "peer_connected", "owner_claimed"]
                // File-backed diagnostics must not delay answer/readiness handling.
                Task {
                    await AgentVerboseTraceRecorder.shared.recordEvent(
                        source: relayStatuses.contains(status) ? "RELAY" : "AGENT",
                        category: relayStatuses.contains(status) ? "relay" : "cloud-call-control",
                        phase: status,
                        title: control.action.map { "Call Control · \($0)" } ?? "Cloud Call Status",
                        detail: control.message ?? control.error ?? "",
                        fields: control.traceFields,
                        isFailure: ["action_error", "action_rejected", "agent_media_failed", "webrtc_failed"]
                            .contains(status)
                    )
                }
                // Only successful outgoing dial invocation can bypass HTTP result polling. This does not accept
                // or activate a call, and the normal answer/adoption and audio gates still run afterward.
                if session.call == nil, let prewarmed = session.outgoingPrewarm.entry,
                    CloudOutgoingDialAcceptancePolicy.accepts(
                        control,
                        for: prewarmed.call,
                        currentConnection: session.media.isCurrentConnection(connection)
                    )
                {
                    prewarmed.acceptance.accept()
                    return
                }
                // Before `answer()` a prewarmed socket has no call. The Agent
                // and Relay send `agent_ready` and `peer_connected` only to prompt an `answer` that has not been
                // sent yet, and `answer()` sends it once the dial completed.
                if session.call == nil,
                    let prewarmed = session.outgoingPrewarm.entry?.call,
                    session.media.isCurrentConnection(connection),
                    control.matches(callID: prewarmed.callID, uuid: prewarmed.uuid, generation: prewarmed.generation),
                    CloudOutgoingPrewarmPolicy.endsPrewarm(status: status)
                {
                    session.discardOutgoingPrewarm(prewarmed)
                    return
                }
                // A queued callback can outlive hangup or even the next call.
                guard let call = session.call,
                    session.media.isCurrentConnection(connection),
                    control.matches(callID: call.callID, uuid: call.uuid, generation: call.generation)
                else { return }
                if session.usesWebRTC, session.carrierRouteRecovery.receive(control, callID: call.callID) {
                    session.requireCarrierRouteRecovery()
                    return
                }
                guard session.carrierRouteRecovery.allowsControl(status: status) else { return }
                if status == "peer_connected",
                    session.usesWebRTC,
                    CloudWebRTCReadiness.shouldRenegotiatePeer(role: control.role)
                {
                    session.restartWebRTCNegotiation()
                }
                switch status {
                case _ where CloudCallAnswerPolicy.isAcknowledged(status: status):
                    session.confirmAnswer(status: status, traceID: control.traceID)
                case _ where CloudCallAnswerPolicy.shouldReplayImmediately(status: status):
                    session.replayAnswerIfNeeded()
                case "ownership_lost":
                    session.emitLifecycle(.ended, source: .relay, traceID: control.traceID)
                    CallKitController.shared.reportCurrentCallEnded(reason: .answeredElsewhere)
                    session.stop()
                case "rejected", "ended", "remote_ended":
                    session.emitLifecycle(
                        .ended,
                        source: status == "remote_ended" ? .relay : .agent,
                        traceID: control.traceID
                    )
                    CallKitController.shared.reportCurrentCallEnded(reason: .remoteEnded)
                    session.stop()
                case "webrtc_ready":
                    if session.usesWebRTC, let negotiation = control.sessionID {
                        guard session.webRTCReadiness.sessionID == negotiation else { break }
                        session.webRTCReadiness.agentConnected(negotiation)
                        session.traceAudio(phase: "carrier_ready", title: "Android Carrier Audio Ready")
                        if session.webRTCReadiness.isReady, session.media.isAudioRunning,
                            !session.audioState.isConnected
                        {
                            session.audioState = .connected
                            session.traceAudio(phase: "audio_ready", title: "Cloud Audio Ready")
                            session.markSetup(.audioReady)
                        }
                    }
                case "webrtc_failed":
                    if session.usesWebRTC,
                        CloudWebRTCFailurePolicy.requiresRebuild(
                            sessionID: control.sessionID,
                            currentSessionID: session.webRTCReadiness.sessionID,
                            error: control.error
                        )
                    {
                        session.webRTCReadiness.reset()
                        session.requestMediaRebuild(.connectionLost)
                    }
                case _ where CloudCallAnswerPolicy.shouldReplaySoon(status: status, action: control.action):
                    if status == "answer_pending" { session.markSetup(.answerPending) }
                    session.scheduleQuickAnswerReplay(after: status)
                case "webrtc_recovering":
                    if session.usesWebRTC { session.webRTCReadiness.agentRecovering() }
                    session.audioState = .connecting(
                        attempt: 1,
                        maximumAttempts: CloudCallRetryPolicy.reconnectDelays.count
                    )
                default:
                    break
                }
            }
        }

    }

    func answer(_ incoming: IncomingVoIPCall) async throws {
        guard let url = incoming.authenticatedMediaURL,
            let secret = incoming.mediaSecret
        else {
            throw IPhoneCloudCallError.mediaUnavailable
        }
        let callChanged = call?.uuid != incoming.uuid || call?.generation != incoming.generation
        carrierRouteRecovery.begin(uuid: incoming.uuid, generation: incoming.generation)
        guard !carrierRouteRecovery.required else { return }
        if callChanged {
            reconnectID = UUID()
            reconnectTask?.cancel()
            reconnectTask = nil
            webRTCStartID = UUID()
            webRTCStartTask?.cancel()
            webRTCStartTask = nil
        }
        try media.prepareForCallKit(webRTC: true)
        // Keep exact incoming credentials but retire their ringing-only expiry before adopting the call.
        if let prepared = incomingPreparation, CloudOutgoingPrewarm.matches(prepared, incoming) {
            clearIncomingPreparation(cancelICE: false)
        } else {
            clearIncomingPreparation(cancelICE: true)
        }
        // An outgoing socket for this exact call is adopted; another call's socket is dropped.
        let prewarmed = outgoingPrewarm.beginAdoption(for: incoming)
        if incoming.isOutgoing, callChanged, prewarmed == nil {
            endUnadoptedOutgoing(incoming)
            throw CloudCommandError.failed("Strict outgoing WebRTC reservation was lost before adoption")
        }
        call = incoming
        if callChanged { outgoingPendingReplays = 0 }
        if callChanged || audioSetupStartedAt == nil {
            audioSetupStartedAt = ProcessInfo.processInfo.systemUptime
            audioState = .starting
            traceAudio(phase: "setup_started", title: "Cloud Audio Connecting")
        }
        answered = true
        lifecycleState = .connecting
        answerHandshake.invalidate()
        icePreparation.prefetch(for: incoming)
        // Native initialization and HTTPS can overlap the WebSocket and
        // Q25 answer confirmation. Neither creates a peer or opens a mic.
        Task.detached(priority: .userInitiated) { CloudWebRTCPeer.prepareFactory() }
        if callChanged || mediaHealthTracker == nil {
            mediaHealthTracker = CloudMediaHealthTracker(maximumRebuilds: 3)
            mediaHealthTracker?.recordRoute(media.audioRouteDescription)
            publishMediaHealth()
        }
        var outgoingPrewarmed = false
        if let prewarmed {
            markSetup(.signalingAdoptionStarted)
            let connected = await prewarmed.connection.value
            // `stop()` or a newer call during the wait already released the prewarm.
            guard !carrierRouteRecovery.required, call?.uuid == incoming.uuid,
                call?.generation == incoming.generation, answered
            else { return }
            outgoingPrewarm.finishAdoption(prewarmed)
            outgoingPrewarmed = connected && media.isConnected
            guard outgoingPrewarmed, preDial.committed, preDial.failure == nil, media.hasConnectedTransport else {
                endUnadoptedOutgoing(incoming)
                stop()
                throw IPhoneCloudCallError.connectionClosed
            }
            if let negotiation = preDial.sessionID {
                webRTCReadiness.begin(negotiation)
                webRTCReadiness.nativeConnected(negotiation)
                if preparedCarrierSession == negotiation { webRTCReadiness.agentConnected(negotiation) }
            }
        }
        if !outgoingPrewarmed, callChanged || !media.isConnected {
            media.stop()
            do {
                try await media.connect(to: url, secret: secret)
            } catch {
                // System answer actions must not fail outright due to initial WebSocket connection jitter.
                // Retain the same call and perform bounded background reconnection, then resend the answer control
                // frame upon success.
                guard !carrierRouteRecovery.required, call?.uuid == incoming.uuid,
                    call?.generation == incoming.generation, answered
                else { return }
                requestMediaRebuild(.connectionLost)
                scheduleAnswerConfirmation(for: incoming)
                return
            }
        }
        guard !carrierRouteRecovery.required, call?.uuid == incoming.uuid, call?.generation == incoming.generation,
            answered
        else { return }
        traceAudio(
            phase: "signaling_connected",
            title: "Cloud Signaling Connected",
            additionalFields: ["prewarmed": String(outgoingPrewarmed)]
        )
        markSetup(.signalingConnected, outgoingPrewarmed ? .prewarmed : .notPrewarmed)
        scheduleAnswerConfirmation(for: incoming)
    }

    private func markPreDial(_ phase: OutgoingCallSetupPhase) {
        guard let pending = outgoingPrewarm.entry?.call, setupTimeline?.covers(pending.uuid) == true else { return }
        setupTimeline?.mark(phase)
    }

    private func tracePreDial(_ phase: String, failed: Bool = false) {
        Task {
            await AgentVerboseTraceRecorder.shared.recordEvent(
                source: "APP",
                category: "cloud-pre-dial",
                phase: phase,
                title: "Strict Pre-dial WebRTC",
                fields: [:],
                isFailure: failed
            )
        }
    }

    /// No polling result or old peer can substitute for both native transport proofs.
    func commitPreparedOutgoing(_ outgoing: IncomingVoIPCall) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        while true {
            try Task.checkCancellation()
            guard let entry = outgoingPrewarm.entry, CloudOutgoingPrewarm.matches(entry.call, outgoing) else {
                throw CloudCommandError.failed("Pre-dial WebRTC stopped before carrier dialing")
            }
            if let failure = preDial.failure { throw CloudCommandError.failed("Pre-dial WebRTC: \(failure)") }
            if preDial.canCommit, let negotiation = preDial.sessionID {
                preDial.commit()
                tracePreDial("commit_sent")
                markPreDial(.commitSent)
                media.sendTransportControl("commit_dial", call: outgoing, sessionID: negotiation)
                return
            }
            guard ContinuousClock.now < deadline else {
                preDial.fail("transport_timeout_20s")
                tracePreDial("transport_timeout_20s", failed: true)
                markPreDial(.preparationTimedOut)
                throw CloudCommandError.failed("Pre-dial WebRTC transport timed out (20s)")
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    func outgoingDialAcceptance(for outgoing: IncomingVoIPCall) -> CloudOutgoingDialAcceptance? {
        guard let entry = outgoingPrewarm.entry, CloudOutgoingPrewarm.matches(entry.call, outgoing) else { return nil }
        return entry.acceptance
    }

    /// Reserves the exact outgoing identity and connects native ICE/DTLS without audio or active call state.
    /// Only both transport proofs permit commit; answer and microphone activation remain separate gates.
    func prewarmOutgoing(_ outgoing: IncomingVoIPCall, timeline: OutgoingCallSetupTimeline? = nil) {
        guard outgoing.isOutgoing,
            let url = outgoing.authenticatedMediaURL,
            let secret = outgoing.mediaSecret,
            call == nil
        else { return }
        if let existing = outgoingPrewarm.entry?.call, !CloudOutgoingPrewarm.matches(existing, outgoing) {
            endUnadoptedOutgoing(existing)
        }
        clearIncomingPreparation(cancelICE: true)
        if let timeline { setupTimeline = timeline }
        let media = media
        let started = outgoingPrewarm.begin(
            outgoing,
            sessionHasCall: call != nil,
            release: { releaseOutgoingPrewarmMedia() },
            connect: {
                do {
                    try await media.connect(to: url, secret: secret, outgoingDial: outgoing)
                    try Task.checkCancellation()
                    guard self.outgoingPrewarm.entry.map({ CloudOutgoingPrewarm.matches($0.call, outgoing) }) == true
                    else { throw CancellationError() }
                    media.sendControl("reserve_dial", call: outgoing)
                    let config = try await self.icePreparation.configuration(for: outgoing)
                    try Task.checkCancellation()
                    guard self.outgoingPrewarm.entry.map({ CloudOutgoingPrewarm.matches($0.call, outgoing) }) == true
                    else { throw CancellationError() }
                    while !self.preDial.peerAvailable {
                        try Task.checkCancellation()
                        guard
                            self.outgoingPrewarm.entry.map({ CloudOutgoingPrewarm.matches($0.call, outgoing) }) == true,
                            self.preDial.failure == nil
                        else { throw IPhoneCloudCallError.connectionClosed }
                        try await Task.sleep(for: .milliseconds(50))
                    }
                    let rtc = RTCAudioSession.sharedInstance()
                    WebRTCCallAudioSession.setTransportOnly(true)
                    rtc.useManualAudio = true
                    rtc.isAudioEnabled = false
                    let negotiation = try media.startWebRTC(
                        call: outgoing,
                        servers: config.iceServers.map(\.native),
                        transportOnly: true
                    )
                    self.preDial.begin(negotiation)
                    self.tracePreDial("silent_peer_started")
                    timeline?.mark(.prewarmSignalingConnected)
                } catch {
                    if self.outgoingPrewarm.entry.map({ CloudOutgoingPrewarm.matches($0.call, outgoing) }) == true {
                        self.preDial.fail("transport_preparation_failed")
                        self.markPreDial(.preparationFailed)
                    }
                    throw error
                }
            },
            expired: { [weak self] expired in self?.endUnadoptedOutgoing(expired) }
        )
        guard started else { return }
        preDial = CloudPreDialGate()
        preparedCarrierSession = nil
        icePreparation.prefetch(for: outgoing)
        Task.detached(priority: .userInitiated) { CloudWebRTCPeer.prepareFactory() }
    }

    /// Ringing may prepare credentials/native initialization only. A normal Relay socket can replace
    /// another iPhone's owner, so incoming signaling must still wait for the user's answer.
    func prewarmIncoming(_ incoming: IncomingVoIPCall) {
        guard !incoming.isOutgoing, !incoming.isVirtual, incoming.authenticatedMediaURL != nil,
            incoming.mediaSecret != nil, call == nil, outgoingPrewarm.entry == nil
        else { return }
        if let prepared = incomingPreparation, CloudOutgoingPrewarm.matches(prepared, incoming) { return }
        clearIncomingPreparation(cancelICE: true)
        incomingPreparation = incoming
        icePreparation.prefetch(for: incoming)
        Task.detached(priority: .userInitiated) { CloudWebRTCPeer.prepareFactory() }
        incomingPreparationExpiry = Task { @MainActor [weak self] in
            try? await Task.sleep(for: CloudOutgoingPrewarm.maximumLifetime)
            guard !Task.isCancelled else { return }
            self?.discardIncomingPrewarm(incoming)
        }
    }

    /// Failure, timeout, cancellation or replacement releases only the unadopted call's preparation.
    func discardOutgoingPrewarm(_ outgoing: IncomingVoIPCall) {
        guard outgoing.isOutgoing else { return }
        if let pending = outgoingPrewarm.entry?.call, CloudOutgoingPrewarm.matches(pending, outgoing) {
            markPreDial(.preparationCancelled)
        }
        outgoingPrewarm.discard(call: outgoing) { releaseOutgoingPrewarmMedia() }
        if setupTimeline?.covers(outgoing.uuid) == true, call?.uuid != outgoing.uuid { setupTimeline = nil }
    }

    func discardIncomingPrewarm(_ incoming: IncomingVoIPCall) {
        guard let prepared = incomingPreparation, CloudOutgoingPrewarm.matches(prepared, incoming) else { return }
        clearIncomingPreparation(cancelICE: true)
    }

    private func clearIncomingPreparation(cancelICE: Bool) {
        guard incomingPreparation != nil else { return }
        incomingPreparation = nil
        incomingPreparationExpiry?.cancel()
        incomingPreparationExpiry = nil
        if cancelICE { icePreparation.cancel() }
    }

    /// Only reached while the session has no call: the bridge then holds nothing but the prewarmed socket.
    private func releaseOutgoingPrewarmMedia() {
        WebRTCCallAudioSession.setTransportOnly(false)
        preDial.fail("preparation_released")
        icePreparation.cancel()
        media.stop()
    }

    private func markSetup(_ phase: OutgoingCallSetupPhase, _ detail: OutgoingCallSetupDetail? = nil) {
        guard let call, call.isOutgoing, let setupTimeline, setupTimeline.covers(call.uuid) else { return }
        setupTimeline.mark(phase, detail)
    }

    func reject(_ incoming: IncomingVoIPCall) async throws {
        call = incoming
        answered = false
        guard let envelope = media.controlEnvelope(action: "reject", call: incoming),
            let credentials = VoIPPushController.shared.cloudCallControlCredentials()
        else {
            stop()
            throw IPhoneCloudCallError.mediaUnavailable
        }
        stop()
        submitPersistentControl(envelope, credentials: credentials)
    }

    func end() async {
        guard let call else {
            stop()
            return
        }
        let action = answered ? "end" : "reject"
        let envelope = media.controlEnvelope(action: action, call: call)
        let credentials = VoIPPushController.shared.cloudCallControlCredentials()
        await CloudCallTerminationCoordinator.finish(
            closeMedia: { [weak self] in self?.stop() },
            enqueuePersistentControl: { [weak self] in
                guard let self else { return }
                guard let envelope, let credentials else {
                    await self.tracePersistentControlUnavailable(action: action, call: call)
                    return
                }
                self.submitPersistentControl(envelope, credentials: credentials)
            }
        )
    }

    /// A cancelled dial can return a cloud identity after its UI is gone. End
    /// exactly that remote call without replacing/stopping a newer media session.
    func endUnadoptedOutgoing(_ outgoing: IncomingVoIPCall) {
        discardOutgoingPrewarm(outgoing)
        guard let envelope = media.controlEnvelope(action: "end", call: outgoing),
            let credentials = VoIPPushController.shared.cloudCallControlCredentials()
        else {
            Task { await tracePersistentControlUnavailable(action: "end", call: outgoing) }
            return
        }
        submitPersistentControl(envelope, credentials: credentials)
    }

    private func submitPersistentControl(
        _ envelope: CloudCallControlEnvelope,
        credentials: CloudCallControlCredentials
    ) {
        let backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "AirSIMCallControl")
        Task { @MainActor in
            defer {
                if backgroundTask != .invalid {
                    UIApplication.shared.endBackgroundTask(backgroundTask)
                }
            }
            do {
                await tracePersistentControl(envelope, phase: "submitting")
                let receipt = try await CloudCallControlClient.submit(
                    envelope: envelope,
                    credentials: credentials
                )
                await tracePersistentControl(
                    envelope,
                    phase: receipt.agentConnected == true ? "forwarded" : "persisted",
                    detail: receipt.status
                )
                let final =
                    receipt.isFinal
                    ? receipt
                    : try await CloudCallControlClient.awaitFinalReceipt(
                        envelope: envelope,
                        credentials: credentials
                    )
                guard final.cellularEndConfirmed else {
                    throw CloudCallControlClientError.rejected(
                        final.error ?? "Agent has not confirmed the cellular call ended"
                    )
                }
                await tracePersistentControl(
                    envelope,
                    phase: final.confirmationPhase,
                    detail: [
                        final.result?.androidConfirmed == true
                            ? "Android Telecom confirmed the call ended"
                            : "CLCC checks: \(final.result?.clccAttempts ?? 0) times",
                        final.rescueCommandID.map { "Recovery command \($0)" },
                    ].compactMap { $0 }.joined(separator: " · ")
                )
                emitLifecycle(from: envelope, state: .ended, source: .relay)
            } catch {
                await tracePersistentControl(
                    envelope,
                    phase: "failed",
                    detail: error.localizedDescription,
                    isFailure: true
                )
                emitLifecycle(
                    from: envelope,
                    state: .failed,
                    source: .relay,
                    failure: error.localizedDescription
                )
            }
        }
    }

    private func emitLifecycle(
        _ state: CallLifecycleState,
        source: CallLifecycleSource,
        traceID: String? = nil,
        failure: String? = nil
    ) {
        guard let call else { return }
        lifecycleState = state
        onLifecycleEvent?(
            CallLifecycleEvent(
                callID: call.callID,
                callUUID: call.uuid,
                generation: call.generation,
                state: state,
                source: source,
                timestamp: Date(),
                traceID: traceID,
                failure: failure
            )
        )
    }

    private func emitLifecycle(
        from envelope: CloudCallControlEnvelope,
        state: CallLifecycleState,
        source: CallLifecycleSource,
        failure: String? = nil
    ) {
        guard let uuid = UUID(uuidString: envelope.callUUID) else { return }
        // A delayed receipt still goes to the lifecycle merger, but must never
        // overwrite the media state of a subsequent call.
        if call?.uuid == uuid { lifecycleState = state }
        onLifecycleEvent?(
            CallLifecycleEvent(
                callID: envelope.callID,
                callUUID: uuid,
                generation: envelope.generation,
                state: state,
                source: source,
                timestamp: Date(),
                traceID: envelope.traceID,
                failure: failure
            )
        )
    }

    private func tracePersistentControlUnavailable(action: String, call: IncomingVoIPCall) async {
        await AgentVerboseTraceRecorder.shared.recordEvent(
            source: "APP",
            category: "cloud-call-control",
            phase: "credentials_unavailable",
            title: "Call Control · \(action)",
            detail: "Missing Relay device credentials",
            fields: [
                "action": action,
                "call_id": call.callID,
                "call_uuid": call.uuid.uuidString.lowercased(),
                "generation": String(call.generation),
            ],
            isFailure: true
        )
    }

    private func tracePersistentControl(
        _ envelope: CloudCallControlEnvelope,
        phase: String,
        detail: String = "",
        isFailure: Bool = false
    ) async {
        await AgentVerboseTraceRecorder.shared.recordEvent(
            source: "APP",
            category: "cloud-call-control",
            phase: phase,
            title: "Call Control · \(envelope.action)",
            detail: detail,
            fields: [
                "action": envelope.action,
                "call_id": envelope.callID,
                "call_uuid": envelope.callUUID,
                "generation": String(envelope.generation),
                "command_id": envelope.commandID,
                "trace_id": envelope.traceID,
            ],
            isFailure: isFailure
        )
    }

    func startAudioWithRetry() {
        guard canAttemptAudio, usesWebRTC else { return }
        audioStartupPermitted = true
        startWebRTCIfReady()
    }

    private func traceAudio(
        phase: String,
        title: String,
        detail: String = "",
        attempt: Int? = nil,
        additionalFields: [String: String] = [:],
        isFailure: Bool = false
    ) {
        guard let call else { return }
        var fields = [
            "call_id": call.callID,
            "call_uuid": call.uuid.uuidString.lowercased(),
            "generation": String(call.generation),
            "audio_route": media.audioRouteDescription,
        ]
        if let audioSetupStartedAt {
            fields["setup_elapsed_ms"] = String(
                format: "%.1f",
                locale: Locale(identifier: "en_US_POSIX"),
                max(0, ProcessInfo.processInfo.systemUptime - audioSetupStartedAt) * 1_000
            )
        }
        fields.merge(additionalFields) { current, _ in current }
        if let attempt { fields["attempt"] = String(attempt) }
        Task {
            await AgentVerboseTraceRecorder.shared.recordEvent(
                source: "APP",
                category: "cloud-call-audio",
                phase: phase,
                title: title,
                detail: detail,
                fields: fields,
                isFailure: isFailure
            )
        }
    }

    private func releaseWebRTCAudioActivation() {
        guard ownsWebRTCAudioActivation else { return }
        ownsWebRTCAudioActivation = false
        let rtc = RTCAudioSession.sharedInstance()
        rtc.isAudioEnabled = false
        rtc.lockForConfiguration()
        defer { rtc.unlockForConfiguration() }
        try? rtc.setActive(false)
    }

    func stopAudio() {
        webRTCReadiness.reset()
        releaseWebRTCAudioActivation()
        audioStartupPermitted = false
        webRTCStartID = UUID()
        webRTCStartTask?.cancel()
        webRTCStartTask = nil
        media.stopAudio()
        audioState = hasActiveCall ? .starting : .idle
    }

    func setMuted(_ muted: Bool) { media.setMuted(muted) }

    var recordingSource: CallRecordingSource? {
        call.map { .init(callUUID: $0.uuid) }
    }

    func recordAudioRoute(_ route: String) {
        guard call != nil else { return }
        mediaHealthTracker?.recordRoute(route)
        publishMediaHealth()
    }

    func stop() {
        if let pending = outgoingPrewarm.entry?.call { endUnadoptedOutgoing(pending) }
        WebRTCCallAudioSession.setTransportOnly(false)
        preDial.fail("cancelled")
        icePreparation.cancel()
        webRTCReadiness.reset()
        releaseWebRTCAudioActivation()
        audioStartupPermitted = false
        webRTCStartID = UUID()
        webRTCStartTask?.cancel()
        webRTCStartTask = nil
        answerRetryGeneration &+= 1
        answerRetryTask?.cancel()
        answerRetryTask = nil
        quickAnswerReplayTask?.cancel()
        quickAnswerReplayTask = nil
        outgoingPendingReplays = 0
        outgoingPrewarm.reset()
        clearIncomingPreparation(cancelICE: false)
        setupTimeline = nil
        reconnectID = UUID()
        reconnectTask?.cancel()
        reconnectTask = nil
        carrierRouteRecovery = CloudCarrierRouteRecovery()
        media.stop()
        call = nil
        answered = false
        lifecycleState = .idle
        answerHandshake.invalidate()
        audioState = .idle
        audioSetupStartedAt = nil
        mediaHealthTracker = nil
        mediaHealthSnapshot = CloudMediaHealthSnapshot()
    }

    private func scheduleAnswerConfirmation(for incoming: IncomingVoIPCall) {
        guard !carrierRouteRecovery.required else { return }
        answerRetryGeneration &+= 1
        let generation = answerRetryGeneration
        answerRetryTask?.cancel()
        answerRetryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if answerRetryGeneration == generation { answerRetryTask = nil }
            }
            for delay in CloudCallAnswerPolicy.confirmationDelays {
                guard !Task.isCancelled,
                    answered,
                    !answerAcknowledged,
                    call?.uuid == incoming.uuid
                else { return }
                if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
                guard !Task.isCancelled,
                    answered,
                    !answerAcknowledged,
                    call?.uuid == incoming.uuid
                else { return }
                media.sendControl("answer", call: incoming)
            }
            guard answered, !answerAcknowledged, call?.uuid == incoming.uuid else { return }
            audioState = .failed(
                "Module has not confirmed answering. Waiting for the Agent control channel to recover."
            )
        }
    }

    private func replayAnswerIfNeeded() {
        guard !carrierRouteRecovery.required, answered, let call else { return }
        answerHandshake.replayIfNeeded { media.sendControl("answer", call: call) }
    }

    /// Resend once, shortly, after an explicit "not yet". Only inside the current confirmation
    /// window, so the overall answer budget and its final failure state are unchanged.
    private func scheduleQuickAnswerReplay(after status: String) {
        guard !carrierRouteRecovery.required, answered,
            !answerAcknowledged,
            answerRetryTask != nil,
            quickAnswerReplayTask == nil,
            let uuid = call?.uuid
        else { return }
        let isOutgoing = call?.isOutgoing == true
        let delay = CloudCallAnswerPolicy.quickReplayDelay(
            status: status,
            isOutgoing: isOutgoing,
            priorOutgoingPendingReplays: outgoingPendingReplays
        )
        if isOutgoing, status == "answer_pending" { outgoingPendingReplays += 1 }
        quickAnswerReplayTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            quickAnswerReplayTask = nil
            guard answered,
                !answerAcknowledged,
                answerRetryTask != nil,
                let call,
                call.uuid == uuid
            else { return }
            media.sendControl("answer", call: call)
        }
    }

    private func confirmAnswer(status: String, traceID: String?) {
        let wasAcknowledged = answerAcknowledged
        answerHandshake.confirm(
            status: status,
            isOutgoing: call?.isOutgoing == true,
            callConnected: {
                emitLifecycle(.active, source: .agent, traceID: traceID)
                markSetup(.active)
            }
        ) { startWebRTCIfReady() }
        guard answerAcknowledged else { return }
        if !wasAcknowledged {
            traceAudio(
                phase: status == "media_prepared" ? "media_prepared" : "answer_confirmed",
                title: status == "media_prepared" ? "Outgoing WebRTC Prepared" : "Android Answer Confirmed"
            )
            markSetup(status == "media_prepared" ? .mediaPrepared : .answerConfirmed)
        }
        answerRetryGeneration &+= 1
        answerRetryTask?.cancel()
        answerRetryTask = nil
        quickAnswerReplayTask?.cancel()
        quickAnswerReplayTask = nil
    }

    private func restartWebRTCNegotiation() {
        guard !carrierRouteRecovery.required, usesWebRTC, answered, let call else { return }
        let replacingPeer = media.isAudioRunning
        answerHandshake.agentReconnected(
            role: "agent",
            stopMedia: {
                webRTCReadiness.reset()
                webRTCStartID = UUID()
                webRTCStartTask?.cancel()
                webRTCStartTask = nil
                media.stopWebRTC()
                audioState =
                    replacingPeer
                    ? .connecting(attempt: 1, maximumAttempts: CloudCallRetryPolicy.reconnectDelays.count)
                    : .starting
            },
            replayAnswer: {
                media.sendControl("answer", call: call)
            },
            scheduleConfirmation: {
                scheduleAnswerConfirmation(for: call)
            }
        )
        // A fresh answer_ok (or outgoing media_prepared) must confirm the agent
        // recreated its native peer before we send new SDP.
    }

    private func startWebRTCIfReady() {
        guard usesWebRTC,
            audioStartupPermitted,
            answerAcknowledged,
            canAttemptAudio,
            !media.isAudioRunning,
            webRTCStartTask == nil,
            !CallKitController.shared.managesCurrentCall || CallKitController.shared.audioSessionIsActive,
            let call
        else { return }
        let id = UUID()
        webRTCStartID = id
        // Keep a real recovery indication; the first negotiation is ordinary startup.
        if !audioState.isRetrying { audioState = .starting }
        webRTCStartTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if webRTCStartID == id { webRTCStartTask = nil }
            }
            do {
                let permission = await AVAudioApplication.requestRecordPermission()
                guard permission else { throw IPhoneCloudCallError.microphonePermissionDenied }
                let iceWaitStarted = ProcessInfo.processInfo.systemUptime
                let config = try await icePreparation.configuration(for: call)
                guard !Task.isCancelled,
                    self.call?.uuid == call.uuid,
                    self.call?.generation == call.generation,
                    webRTCStartID == id,
                    audioStartupPermitted,
                    answerAcknowledged,
                    !CallKitController.shared.managesCurrentCall || CallKitController.shared.audioSessionIsActive
                else { return }
                traceAudio(
                    phase: "ice_prepared",
                    title: "WebRTC ICE Prepared",
                    additionalFields: [
                        "ice_wait_ms": String(
                            format: "%.1f",
                            (ProcessInfo.processInfo.systemUptime - iceWaitStarted) * 1_000
                        )
                    ]
                )
                markSetup(.iceConfigReady)
                let rtc = RTCAudioSession.sharedInstance()
                if !CallKitController.shared.managesCurrentCall, !ownsWebRTCAudioActivation {
                    rtc.lockForConfiguration()
                    defer { rtc.unlockForConfiguration() }
                    try rtc.setActive(true)
                    ownsWebRTCAudioActivation = true
                }
                WebRTCCallAudioSession.setTransportOnly(false)
                rtc.isAudioEnabled = true
                if !media.enablePreparedAudio(call: call) {
                    let negotiation = try media.startWebRTC(call: call, servers: config.iceServers.map(\.native))
                    webRTCReadiness.begin(negotiation)
                }
                if webRTCReadiness.isReady { audioState = .connected }
                traceAudio(phase: "peer_started", title: "WebRTC Peer Started")
                markSetup(.peerStarted)
            } catch {
                guard !Task.isCancelled, webRTCStartID == id else { return }
                audioState = .failed(error.localizedDescription)
                traceAudio(
                    phase: "webrtc_failed",
                    title: "WebRTC Audio Failed",
                    detail: error.localizedDescription,
                    isFailure: true
                )
            }
        }
    }

    private func requireCarrierRouteRecovery() {
        icePreparation.cancel()
        answerRetryGeneration &+= 1
        answerRetryTask?.cancel()
        answerRetryTask = nil
        quickAnswerReplayTask?.cancel()
        quickAnswerReplayTask = nil
        reconnectID = UUID()
        reconnectTask?.cancel()
        reconnectTask = nil
        stopAudio()
        audioState = .failed(CloudCarrierRouteRecovery.message)
        traceAudio(phase: "carrier_route_recovery_required", title: "Android Audio Recovery Required", isFailure: true)
    }

    private func requestMediaRebuild(_ issue: CloudMediaHealthIssue) {
        guard !carrierRouteRecovery.required, reconnectTask == nil, let call, answered else { return }
        if mediaHealthTracker == nil {
            mediaHealthTracker = CloudMediaHealthTracker(maximumRebuilds: 3)
        }
        guard mediaHealthTracker?.beginRebuild() == true else {
            audioState = .failed("Cloud media has been rebuilt three times. Automatic retries stopped.")
            publishMediaHealth()
            traceMediaHealth(issue: issue, phase: "rebuild_exhausted", call: call, isFailure: true)
            return
        }
        publishMediaHealth()
        traceMediaHealth(issue: issue, phase: "rebuilding", call: call)
        recoverConnectionIfNeeded()
    }

    private func publishMediaHealth() {
        mediaHealthSnapshot = mediaHealthTracker?.snapshot ?? CloudMediaHealthSnapshot()
    }

    private func traceMediaHealth(
        issue: CloudMediaHealthIssue,
        phase: String,
        call: IncomingVoIPCall,
        isFailure: Bool = false
    ) {
        let snapshot = mediaHealthSnapshot
        Task {
            await AgentVerboseTraceRecorder.shared.recordEvent(
                source: "APP",
                category: "cloud-media-health",
                phase: phase,
                title: "Cloud Media Recovery",
                detail: issue.rawValue,
                fields: [
                    "call_id": call.callID,
                    "call_uuid": call.uuid.uuidString.lowercased(),
                    "generation": String(call.generation),
                    "rebuild_count": String(snapshot.rebuildCount),
                    "audio_route": snapshot.audioRoute,
                ],
                isFailure: isFailure
            )
        }
    }

    private func recoverConnectionIfNeeded() {
        guard !carrierRouteRecovery.required, reconnectTask == nil,
            let call,
            answered,
            let url = call.authenticatedMediaURL,
            let secret = call.mediaSecret
        else { return }
        webRTCReadiness.reset()
        webRTCStartID = UUID()
        webRTCStartTask?.cancel()
        webRTCStartTask = nil
        media.stopAudio()
        audioState = .connecting(attempt: 1, maximumAttempts: CloudCallRetryPolicy.reconnectDelays.count)
        let id = UUID()
        reconnectID = id
        reconnectTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if reconnectID == id { reconnectTask = nil }
            }
            let delays = CloudCallRetryPolicy.reconnectDelays
            await CloudCallRecoveryCoordinator.run(
                delays: delays,
                isCurrent: {
                    !self.carrierRouteRecovery.required && self.call?.uuid == call.uuid
                        && self.call?.generation == call.generation && self.answered && self.reconnectID == id
                },
                connect: { index in
                    self.audioState = .connecting(attempt: index + 1, maximumAttempts: delays.count)
                    self.media.stop()
                    try await self.media.connect(to: url, secret: secret)
                },
                connected: {
                    guard !self.carrierRouteRecovery.required, self.reconnectID == id else { return }
                    // Logged only when the first connect of this call failed; later rebuilds keep the timeline.
                    self.markSetup(.signalingConnected, .notPrewarmed)
                    self.answerHandshake.invalidate()
                    self.replayAnswerIfNeeded()
                    self.scheduleAnswerConfirmation(for: call)
                    self.startAudioWithRetry()
                },
                failed: { error in
                    guard !self.carrierRouteRecovery.required, self.reconnectID == id else { return }
                    self.audioState = .failed(error.localizedDescription)
                    self.emitLifecycle(.failed, source: .relay, traceID: nil, failure: error.localizedDescription)
                    CallKitController.shared.reportCurrentCallEnded(reason: .failed)
                    self.stop()
                }
            )
        }
    }
}

private struct CloudCallControlOperationIdentity {
    let commandID: String
    let traceID: String
}

private final class IPhoneCloudCallMediaBridge: @unchecked Sendable {
    var onWebRTCState: ((_ connected: Bool, _ connection: UUID, _ negotiation: UUID) -> Void)?
    var onWebRTCRecovering: ((_ connection: UUID, _ negotiation: UUID) -> Void)?
    private var webRTCSessionID: UUID?

    func isCurrentWebRTCSession(_ id: UUID, connection: UUID) -> Bool {
        queue.sync { connectionID == connection && webRTCSessionID == id }
    }

    private var webRTCPeer: CloudWebRTCPeer?
    private var webRTCCall: IncomingVoIPCall?
    private var webRTCMode = false
    private var webRTCAudioEnabled = false
    var onConnectionLost: ((UUID) -> Void)?
    var onControl: ((CloudCallControlMessage, UUID) -> Void)?
    var onOwnerJoinSent: ((IncomingVoIPCall, UUID, TimeInterval) -> Void)?

    private let queue = DispatchQueue(label: "com.example.airsim.iphone-cloud-media", qos: .userInteractive)
    private var webSocket: URLSessionWebSocketTask?
    private var networkSession: URLSession?
    private var connectionID = UUID()
    private var pendingConnection: CloudSignalingConnectionGate?

    func isCurrentConnection(_ id: UUID) -> Bool {
        queue.sync { connectionID == id }
    }

    private var muted = false
    private var stopped = true
    private var controlOperations: [String: CloudCallControlOperationIdentity] = [:]

    var isConnected: Bool {
        queue.sync { webSocket != nil && !stopped }
    }

    var hasConnectedTransport: Bool { queue.sync { webRTCPeer?.isConnected == true } }

    var isAudioRunning: Bool {
        queue.sync { webRTCPeer != nil && webRTCAudioEnabled }
    }

    var audioRouteDescription: String {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
            .map { $0.portType.rawValue }
        return outputs.isEmpty ? "unknown" : outputs.joined(separator: ",")
    }

    func prepareForCallKit(webRTC: Bool) throws {
        queue.sync { webRTCMode = webRTC }
        if webRTC {
            let rtc = RTCAudioSession.sharedInstance()
            rtc.useManualAudio = true
            rtc.isAudioEnabled = false
        }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetoothHFP])
        try session.setPreferredSampleRate(48_000)
        try session.setPreferredIOBufferDuration(0.02)
        // Every call starts on the receiver; the user can switch to speaker on the call screen afterward.
        try session.overrideOutputAudioPort(.none)
    }

    func stopWebRTC() {
        queue.sync {
            webRTCPeer?.close()
            webRTCPeer = nil
            webRTCCall = nil
            webRTCSessionID = nil
        }
    }

    func enablePreparedAudio(call: IncomingVoIPCall) -> Bool {
        queue.sync {
            guard let prepared = webRTCCall, CloudOutgoingPrewarm.matches(prepared, call), webRTCPeer != nil else {
                return false
            }
            webRTCAudioEnabled = true
            webRTCPeer?.setMuted(muted)
            return true
        }
    }

    func startWebRTC(call: IncomingVoIPCall, servers: [RTCIceServer], transportOnly: Bool = false) throws -> UUID {
        try queue.sync {
            guard !stopped, let socket = webSocket else { throw IPhoneCloudCallError.connectionClosed }
            webRTCPeer?.close()
            let owner = connectionID
            let negotiation = UUID()
            webRTCSessionID = negotiation
            webRTCCall = call
            webRTCAudioEnabled = !transportOnly
            let peer = try CloudWebRTCPeer(
                callUUID: call.uuid,
                generation: call.generation,
                sessionID: negotiation,
                servers: servers,
                queue: queue,
                audioEnabled: !transportOnly,
                signal: { [weak self, weak socket] signal in
                    guard let self,
                        let socket,
                        self.webSocket === socket,
                        self.connectionID == owner,
                        self.webRTCPeer?.sessionID == signal.sessionID,
                        let data = try? JSONEncoder().encode(signal),
                        let text = String(data: data, encoding: .utf8)
                    else { return }
                    socket.send(.string(text)) { [weak self] error in
                        guard error != nil else { return }
                        self?.queue.async { [weak self] in
                            guard let self, self.connectionID == owner, self.webRTCSessionID == negotiation else {
                                return
                            }
                            self.onConnectionLost?(owner)
                        }
                    }
                },
                connected: { [weak self] in self?.onWebRTCState?(true, owner, negotiation) },
                disconnected: { [weak self] in self?.onWebRTCRecovering?(owner, negotiation) },
                failure: { [weak self] in
                    guard let self else { return }
                    self.webRTCPeer = nil
                    self.onWebRTCState?(false, owner, negotiation)
                },
                statistics: { fields in
                    Task {
                        await AgentVerboseTraceRecorder.shared.recordEvent(
                            source: "APP",
                            category: "cloud-call-audio",
                            phase: "webrtc_stats",
                            title: "WebRTC Audio Statistics",
                            fields: fields
                        )
                    }
                }
            )
            webRTCPeer = peer
            peer.setMuted(transportOnly || muted)
            peer.offer()
            return negotiation
        }
    }

    func connect(to url: URL, secret: String, outgoingDial: IncomingVoIPCall? = nil) async throws {
        let gate = CloudSignalingConnectionGate(connection: UUID(), outgoing: outgoingDial)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                gate.install { continuation.resume(with: $0) }
                queue.async { [weak self] in
                    guard let self else {
                        gate.finish(.failure(IPhoneCloudCallError.connectionClosed))
                        return
                    }
                    guard gate.isPending else { return }
                    pendingConnection?.finish(.failure(IPhoneCloudCallError.connectionClosed))
                    pendingConnection = gate
                    stopped = false
                    connectionID = gate.connection
                    let configuration = URLSessionConfiguration.ephemeral
                    configuration.networkServiceType = .voice
                    let deliveryQueue = OperationQueue()
                    deliveryQueue.name = "com.example.airsim.iphone-cloud-receive"
                    deliveryQueue.qualityOfService = .userInteractive
                    deliveryQueue.maxConcurrentOperationCount = 1
                    let session = URLSession(
                        configuration: configuration,
                        delegate: nil,
                        delegateQueue: deliveryQueue
                    )
                    networkSession = session
                    var request = URLRequest(url: url)
                    request.networkServiceType = .voice
                    request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
                    let socket = session.webSocketTask(with: request)
                    socket.priority = URLSessionTask.highPriority
                    webSocket = socket
                    socket.resume()
                    receiveNext(socket)
                    socket.sendPing { error in
                        self.queue.async {
                            guard !self.stopped, self.webSocket === socket else {
                                gate.finish(.failure(IPhoneCloudCallError.connectionClosed))
                                return
                            }
                            gate.finishPong(
                                error.map { .failure($0) } ?? .success(()),
                                pending: &self.pendingConnection
                            )
                        }
                    }
                }
            }
        } onCancel: { [weak self] in
            // Complete synchronously even if cancellation precedes the queue's socket creation.
            guard gate.finish(.failure(CancellationError())) else { return }
            self?.queue.async { [weak self] in
                guard let self, gate.ownsConnection(self.connectionID) else { return }
                self.pendingConnection = nil
                self.webSocket?.cancel(with: .goingAway, reason: nil)
                self.webSocket = nil
                self.networkSession?.invalidateAndCancel()
                self.networkSession = nil
                self.stopped = true
            }
        }
    }

    func sendTransportControl(_ action: String, call: IncomingVoIPCall, sessionID: UUID) {
        queue.async { [weak self] in
            guard let self, let socket = self.webSocket, self.webRTCSessionID == sessionID,
                let prepared = self.webRTCCall, CloudOutgoingPrewarm.matches(prepared, call)
            else { return }
            let payload: [String: Any] = [
                "action": action, "call_id": call.callID,
                "call_uuid": call.uuid.uuidString.lowercased(), "generation": call.generation,
                "session_id": sessionID.uuidString.lowercased(),
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: payload),
                let text = String(data: data, encoding: .utf8)
            else { return }
            socket.send(.string(text)) { [weak self] error in
                guard error != nil else { return }
                self?.queue.async { [weak self] in
                    guard let self, self.webSocket === socket else { return }
                    self.onConnectionLost?(self.connectionID)
                }
            }
        }
    }

    func sendControl(_ action: String, call: IncomingVoIPCall) {
        queue.async { [weak self] in
            guard let self,
                let socket = webSocket,
                let (text, envelope) = controlText(action: action, call: call)
            else { return }
            traceControl(envelope, phase: "sending")
            socket.send(.string(text)) { [weak self] error in
                guard let error else { return }
                self?.traceControl(envelope, phase: "send_failed", detail: error.localizedDescription, isFailure: true)
            }
            if action == "answer", call.isOutgoing {
                onOwnerJoinSent?(call, connectionID, ProcessInfo.processInfo.systemUptime)
            }
        }
    }

    func controlEnvelope(action: String, call: IncomingVoIPCall) -> CloudCallControlEnvelope? {
        queue.sync { controlEnvelopeLocked(action: action, call: call) }
    }

    private func controlText(
        action: String,
        call: IncomingVoIPCall
    ) -> (String, CloudCallControlEnvelope)? {
        guard let envelope = controlEnvelopeLocked(action: action, call: call) else { return nil }
        guard let data = try? JSONEncoder().encode(envelope),
            let text = String(data: data, encoding: .utf8)
        else { return nil }
        return (text, envelope)
    }

    private func controlEnvelopeLocked(
        action: String,
        call: IncomingVoIPCall
    ) -> CloudCallControlEnvelope? {
        let operationKey = "\(call.uuid.uuidString.lowercased()):\(action)"
        let identity: CloudCallControlOperationIdentity
        if let existing = controlOperations[operationKey] {
            identity = existing
        } else {
            let commandID = UUID().uuidString.lowercased()
            identity = CloudCallControlOperationIdentity(
                commandID: commandID,
                traceID: String(commandID.prefix(8))
            )
            controlOperations[operationKey] = identity
        }
        let envelope = CloudCallControlEnvelope(
            action: action,
            callID: call.callID,
            callUUID: call.uuid.uuidString.lowercased(),
            generation: call.generation,
            commandID: identity.commandID,
            traceID: identity.traceID
        )
        return envelope
    }

    private func traceControl(
        _ envelope: CloudCallControlEnvelope,
        phase: String,
        detail: String = "",
        isFailure: Bool = false
    ) {
        Task {
            await AgentVerboseTraceRecorder.shared.recordEvent(
                source: "APP",
                category: "cloud-call-control",
                phase: phase,
                title: "Call Control · \(envelope.action)",
                detail: detail,
                fields: [
                    "action": envelope.action,
                    "call_id": envelope.callID,
                    "call_uuid": envelope.callUUID,
                    "generation": String(envelope.generation),
                    "command_id": envelope.commandID,
                    "trace_id": envelope.traceID,
                ],
                isFailure: isFailure
            )
        }
    }

    func setMuted(_ muted: Bool) {
        CallAudioRecorder.shared.setMuted(muted)
        queue.async { [weak self] in
            self?.muted = muted
            if let self { self.webRTCPeer?.setMuted(!self.webRTCAudioEnabled || muted) }
        }
    }

    func stopAudio() {
        queue.sync { stopAudioLocked() }
    }

    private func stopAudioLocked() {
        webRTCPeer?.close()
        webRTCPeer = nil
        webRTCCall = nil
        webRTCSessionID = nil
        if webRTCMode { RTCAudioSession.sharedInstance().isAudioEnabled = false }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            stopped = true
            pendingConnection?.finish(.failure(IPhoneCloudCallError.connectionClosed))
            pendingConnection = nil
            connectionID = UUID()
            webSocket?.cancel(with: .normalClosure, reason: nil)
            webSocket = nil
            networkSession?.invalidateAndCancel()
            networkSession = nil
            controlOperations.removeAll(keepingCapacity: false)
            stopAudioLocked()
        }
    }

    private func receiveNext(_ socket: URLSessionWebSocketTask) {
        socket.receive { [weak self, weak socket] result in
            guard let self, let socket else { return }
            queue.async {
                guard !self.stopped, self.webSocket === socket else { return }
                switch result {
                case .success(.data):
                    break // Call WebSockets carry signaling; binary payloads never enter the audio engine.
                case let .success(.string(text)):
                    self.consumeControl(text)
                case .success:
                    break
                case .failure:
                    self.pendingConnection?.finish(.failure(IPhoneCloudCallError.connectionClosed))
                    self.pendingConnection = nil
                    self.webSocket = nil
                    self.stopped = true
                    self.onConnectionLost?(self.connectionID)
                }
            }
            // Keep the network receive armed independently of audio scheduling.
            // Enqueue first so the serial delivery queue preserves message order.
            if case .success = result { self.receiveNext(socket) }
        }
    }

    private func consumeControl(_ text: String) {
        if let data = text.data(using: .utf8),
            let signal = try? JSONDecoder().decode(CloudWebRTCSignal.self, from: data)
        {
            guard webRTCMode,
                let call = webRTCCall,
                let peer = webRTCPeer,
                signal.matches(call: call, sessionID: peer.sessionID)
            else { return }
            peer.receive(signal)
            return
        }
        guard let control = try? CloudCallControlMessage.decode(text) else { return }
        // A strict proof received on this authenticated outgoing socket establishes it without an extra pong RTT.
        // Other statuses and incoming sockets retain the existing ping completion behavior.
        if pendingConnection?.accept(control, connection: connectionID) == true { pendingConnection = nil }
        onControl?(control, connectionID)
    }
}
