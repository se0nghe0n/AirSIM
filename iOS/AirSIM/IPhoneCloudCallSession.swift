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
        guard lifecycleState == .active || (isOutgoing && lifecycleState == .connecting) else {
            return false
        }
        return !managedByCallKit || callKitAudioSessionActive
    }
}

enum CloudMediaHealthIssue: String, Equatable, Sendable {
    case connectionLost = "connection_lost"
    case downlinkStalled = "downlink_stalled"
    case downlinkSilent = "downlink_silent"
    case uplinkStalled = "uplink_stalled"
}

enum CloudMediaHealthDecision: Equatable, Sendable {
    case none
    case rebuild(CloudMediaHealthIssue)
    case failed(CloudMediaHealthIssue)
}

struct CloudMediaHealthSnapshot: Equatable, Sendable {
    var firstDownlinkAt: Date?
    var lastDownlinkAt: Date?
    var lastUplinkAt: Date?
    var downlinkBytes: UInt64 = 0
    var downlinkFrames: UInt64 = 0
    var downlinkPeak: Int = 0
    var uplinkBytes: UInt64 = 0
    var uplinkFrames: UInt64 = 0
    var uplinkPeak: Int = 0
    var droppedFrames: UInt64 = 0
    var jitterBufferHighWatermark: Int = 0
    var rebuildCount: Int = 0
    var audioRoute = "unknown"
    var lastIssue: CloudMediaHealthIssue?
}

struct CloudMediaHealthTracker: Sendable {
    private static let stallInterval: TimeInterval = 2
    private static let silentFrameThreshold = 50
    private static let audiblePeakThreshold = 32

    private var windowStartedAt: Date
    private var consecutiveSilentFrames = 0
    private let maximumRebuilds: Int
    private(set) var snapshot = CloudMediaHealthSnapshot()

    init(startedAt: Date, maximumRebuilds: Int = 3) {
        windowStartedAt = startedAt
        self.maximumRebuilds = max(0, maximumRebuilds)
    }

    mutating func recordDownlink(
        bytes: Int,
        peak: Int,
        at timestamp: Date,
        jitterBufferFrames: Int,
        droppedFrames: Int = 0
    ) {
        guard bytes > 0 else { return }
        snapshot.firstDownlinkAt = snapshot.firstDownlinkAt ?? timestamp
        snapshot.lastDownlinkAt = timestamp
        snapshot.downlinkBytes &+= UInt64(bytes)
        snapshot.downlinkFrames &+= UInt64(max(1, bytes / 320))
        snapshot.downlinkPeak = max(snapshot.downlinkPeak, peak)
        snapshot.droppedFrames &+= UInt64(max(0, droppedFrames))
        snapshot.jitterBufferHighWatermark = max(
            snapshot.jitterBufferHighWatermark,
            max(0, jitterBufferFrames)
        )
        consecutiveSilentFrames = peak < Self.audiblePeakThreshold
            ? consecutiveSilentFrames + max(1, bytes / 320)
            : 0
    }

    mutating func recordUplink(bytes: Int, peak: Int, at timestamp: Date) {
        guard bytes > 0 else { return }
        snapshot.lastUplinkAt = timestamp
        snapshot.uplinkBytes &+= UInt64(bytes)
        snapshot.uplinkFrames &+= UInt64(max(1, bytes / 320))
        snapshot.uplinkPeak = max(snapshot.uplinkPeak, peak)
    }

    mutating func recordRoute(_ route: String) {
        let normalized = route.trimmingCharacters(in: .whitespacesAndNewlines)
        snapshot.audioRoute = normalized.isEmpty ? "unknown" : normalized
    }

    func evaluate(at timestamp: Date) -> CloudMediaHealthDecision {
        let issue: CloudMediaHealthIssue?
        let lastDownlink = snapshot.lastDownlinkAt ?? windowStartedAt
        if timestamp.timeIntervalSince(lastDownlink) >= Self.stallInterval {
            issue = .downlinkStalled
        } else {
            let lastUplink = snapshot.lastUplinkAt ?? windowStartedAt
            issue = snapshot.downlinkFrames > 0 &&
                timestamp.timeIntervalSince(lastUplink) >= Self.stallInterval
                ? .uplinkStalled
                : nil
        }
        guard let issue else { return .none }
        return snapshot.rebuildCount < maximumRebuilds ? .rebuild(issue) : .failed(issue)
    }

    @discardableResult
    mutating func beginRebuild(for issue: CloudMediaHealthIssue, at timestamp: Date) -> Bool {
        guard snapshot.rebuildCount < maximumRebuilds else { return false }
        snapshot.rebuildCount += 1
        snapshot.lastIssue = issue
        windowStartedAt = timestamp
        consecutiveSilentFrames = 0
        snapshot.lastDownlinkAt = nil
        snapshot.lastUplinkAt = nil
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
              agentSupported.contains(.webRTC) else {
            return .failure(.unsupported)
        }
        return .success(.webRTC)
    }
}

enum CloudCallRetryPolicy {
    /// A brief race can occur between CallKit activating the audio session and AVAudioEngine becoming ready; cover ~12 seconds
    /// while bounding the retry count so genuine permission errors do not spin in the background.
    static let audioDelays: [TimeInterval] = [0, 0.35, 0.8, 1.5, 3, 6]
    static let reconnectDelays: [TimeInterval] = [0.4, 1, 2, 4]

    static func shouldRetryAudio(after error: Error) -> Bool {
        if case IPhoneCloudCallError.microphonePermissionDenied = error { return false }
        return true
    }
}

@MainActor
enum CloudCallRecoveryCoordinator {
    static func run(delays: [TimeInterval], isCurrent: () -> Bool,
                    connect: (Int) async throws -> Void,
                    connected: () -> Void, failed: (Error) -> Void) async {
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
        status == "answer_ok" || status == "active"
    }

    static func shouldReplayImmediately(status: String) -> Bool {
        status == "agent_ready"
    }
}

enum CloudCallTerminationCoordinator {
    static func finish(
        closeMedia: () async -> Void,
        enqueuePersistentControl: () async -> Void
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
    let action: String?
    let callID: String?
    let callUUID: String?
    let generation: UInt64?
    let commandID: String?
    let traceID: String?
    let downlinkBytes: UInt64?
    let downlinkFrames: UInt64?
    let downlinkPeak: UInt64?

    private struct Payload: Decodable {
        let status: String?
        let role: String?
        let sessionID: UUID?
        let event: String?
        let message: String?
        let action: String?
        let callID: String?
        let callUUID: String?
        let generation: UInt64?
        let commandID: String?
        let traceID: String?
        let downlinkBytes: UInt64?
        let downlinkFrames: UInt64?
        let downlinkPeak: UInt64?

        enum CodingKeys: String, CodingKey {
            case status, event, message, role
            case sessionID = "session_id"
            case action, generation
            case callID = "call_id"
            case callUUID = "call_uuid"
            case commandID = "command_id"
            case traceID = "trace_id"
            case downlinkBytes = "downlink_bytes"
            case downlinkFrames = "downlink_frames"
            case downlinkPeak = "downlink_peak"
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
            action: payload.action,
            callID: payload.callID,
            callUUID: payload.callUUID,
            generation: payload.generation,
            commandID: payload.commandID,
            traceID: payload.traceID,
            downlinkBytes: payload.downlinkBytes,
            downlinkFrames: payload.downlinkFrames,
            downlinkPeak: payload.downlinkPeak
        )
    }

    var traceFields: [String: String] {
        var fields: [String: String] = [:]
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
        guard let url = RelayEndpoint.url(
            base: credentials.relayURL,
            path: "/v1/calls/\(envelope.callUUID)/actions"
        ) else { throw CloudCallControlClientError.invalidRelayURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 8
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(Submission(
            action: envelope.action,
            callID: envelope.callID,
            callUUID: envelope.callUUID,
            generation: envelope.generation,
            commandID: envelope.commandID,
            traceID: envelope.traceID,
            deviceID: credentials.deviceID,
            deviceSecret: credentials.deviceSecret
        ))
        return request
    }

    static func resultRequest(
        envelope: CloudCallControlEnvelope,
        credentials: CloudCallControlCredentials
    ) throws -> URLRequest {
        guard let url = RelayEndpoint.url(
            base: credentials.relayURL,
            path: "/v1/calls/\(envelope.callUUID)/actions/\(envelope.commandID)"
        ) else { throw CloudCallControlClientError.invalidRelayURL }
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
            throw CloudCallControlClientError.rejected(detail ?? "Relay rejected call control (HTTP \(http.statusCode))")
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw CloudCallControlClientError.invalidResponse
        }
    }
}

/// iPhone cloud call session. PushKit media keys are kept in memory only;
/// WebRTC starts only after CallKit activates AVAudioSession, while the control WebSocket can answer module calls early.
@MainActor
final class IPhoneCloudCallSession {
    static let shared = IPhoneCloudCallSession()

    private let media = IPhoneCloudCallMediaBridge()
    private(set) var call: IncomingVoIPCall?
    private(set) var answered = false
    private(set) var lifecycleState: CallLifecycleState = .idle
    private(set) var audioState: CloudCallAudioState = .idle {
        didSet {
            guard audioState != oldValue else { return }
            onAudioStateChange?(audioState)
        }
    }
    private(set) var mediaHealthSnapshot = CloudMediaHealthSnapshot() {
        didSet { onMediaHealthChange?(mediaHealthSnapshot) }
    }
    var onAudioStateChange: ((CloudCallAudioState) -> Void)?
    var onMediaHealthChange: ((CloudMediaHealthSnapshot) -> Void)?
    var onLifecycleEvent: ((CallLifecycleEvent) -> Void)?
    private var reconnectTask: Task<Void, Never>?
    private var reconnectID = UUID()
    private var mediaHealthTracker: CloudMediaHealthTracker?
    private var answerRetryTask: Task<Void, Never>?
    private var answerRetryGeneration = 0
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
        call != nil && answered && isPrepared &&
            (lifecycleState == .connecting || lifecycleState == .active)
    }
    var isRecovering: Bool { reconnectTask != nil }
    var isAudioRunning: Bool { media.isAudioRunning }

    private init() {
        media.onWebRTCState = { connected, connection, negotiation in
            Task { @MainActor in
                let session = IPhoneCloudCallSession.shared
                guard session.usesWebRTC, session.media.isCurrentWebRTCSession(negotiation, connection: connection) else { return }
                if connected {
                    session.webRTCReadiness.nativeConnected(negotiation)
                    session.traceAudio(phase: "native_connected", title: "WebRTC Connected")
                    if session.webRTCReadiness.isReady, !session.audioState.isConnected {
                        session.audioState = .connected
                        session.traceAudio(phase: "audio_ready", title: "Cloud Audio Ready")
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
                guard session.media.isCurrentWebRTCSession(negotiation, connection: connection) else { return }
                session.webRTCReadiness.nativeDisconnected(negotiation)
                session.audioState = .connecting(attempt: 1, maximumAttempts: CloudCallRetryPolicy.reconnectDelays.count)
            }
        }
        media.onConnectionLost = { connection in
            Task { @MainActor in
                let session = IPhoneCloudCallSession.shared
                guard session.call != nil, session.media.isCurrentConnection(connection) else { return }
                session.answerHandshake.invalidate()
                session.requestMediaRebuild(.connectionLost)
            }
        }
        media.onControl = { control, connection in
            Task { @MainActor in
                let session = IPhoneCloudCallSession.shared
                let status = control.status
                let relayStatuses = ["action_queued", "action_forwarded", "peer_connected", "owner_claimed"]
                // File-backed diagnostics must not delay answer/readiness handling.
                Task {
                    await AgentVerboseTraceRecorder.shared.recordEvent(
                        source: relayStatuses.contains(status) ? "RELAY" : "AGENT",
                        category: relayStatuses.contains(status) ? "relay" : "cloud-call-control",
                        phase: status,
                        title: control.action.map { "Call Control · \($0)" } ?? "Cloud Call Status",
                        detail: control.message ?? "",
                        fields: control.traceFields,
                        isFailure: status == "action_error"
                    )
                }
                // A queued callback can outlive hangup or even the next call.
                guard let call = session.call, session.media.isCurrentConnection(connection),
                      control.matches(callID: call.callID, uuid: call.uuid, generation: call.generation) else { return }
                if status == "peer_connected", session.usesWebRTC,
                   CloudWebRTCReadiness.shouldRenegotiatePeer(role: control.role) {
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
                        if session.webRTCReadiness.isReady, !session.audioState.isConnected {
                            session.audioState = .connected
                            session.traceAudio(phase: "audio_ready", title: "Cloud Audio Ready")
                        }
                    }
                case "webrtc_failed":
                    if session.usesWebRTC,
                       control.sessionID == nil || control.sessionID == session.webRTCReadiness.sessionID {
                        session.webRTCReadiness.reset()
                        session.requestMediaRebuild(.connectionLost)
                    }
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
              let secret = incoming.mediaSecret else {
            throw IPhoneCloudCallError.mediaUnavailable
        }
        try media.prepareForCallKit(webRTC: true)
        let callChanged = call?.uuid != incoming.uuid
        call = incoming
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
            mediaHealthTracker = CloudMediaHealthTracker(startedAt: Date(), maximumRebuilds: 3)
            mediaHealthTracker?.recordRoute(media.audioRouteDescription)
            publishMediaHealth()
        }
        if callChanged || !media.isConnected {
            media.stop()
            do {
                try await media.connect(to: url, secret: secret)
            } catch {
                // System answer actions must not fail outright due to initial WebSocket connection jitter.
                // Retain the same call and perform bounded background reconnection, then resend the answer control frame upon success.
                guard call?.uuid == incoming.uuid, answered else { return }
                requestMediaRebuild(.connectionLost)
                scheduleAnswerConfirmation(for: incoming)
                return
            }
        }
        guard call?.uuid == incoming.uuid, answered else { return }
        traceAudio(phase: "signaling_connected", title: "Cloud Signaling Connected")
        scheduleAnswerConfirmation(for: incoming)
    }

    func reject(_ incoming: IncomingVoIPCall) async throws {
        call = incoming
        answered = false
        guard let envelope = media.controlEnvelope(action: "reject", call: incoming),
              let credentials = VoIPPushController.shared.cloudCallControlCredentials() else {
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
        guard let envelope = media.controlEnvelope(action: "end", call: outgoing),
              let credentials = VoIPPushController.shared.cloudCallControlCredentials() else {
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
                let final = receipt.isFinal ? receipt : try await CloudCallControlClient.awaitFinalReceipt(
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
        onLifecycleEvent?(CallLifecycleEvent(
            callID: call.callID,
            callUUID: call.uuid,
            generation: call.generation,
            state: state,
            source: source,
            timestamp: Date(),
            traceID: traceID,
            failure: failure
        ))
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
        onLifecycleEvent?(CallLifecycleEvent(
            callID: envelope.callID,
            callUUID: uuid,
            generation: envelope.generation,
            state: state,
            source: source,
            timestamp: Date(),
            traceID: envelope.traceID,
            failure: failure
        ))
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

    func startAudio() throws {
        guard usesWebRTC else { return }
        audioStartupPermitted = true
        startWebRTCIfReady()
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
            fields["setup_elapsed_ms"] = String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"),
                    max(0, ProcessInfo.processInfo.systemUptime - audioSetupStartedAt) * 1_000)
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

    var recordingSource: CallRecordingSource? { call.map { .init(callUUID: $0.uuid) } }

    func recordAudioRoute(_ route: String) {
        guard call != nil else { return }
        mediaHealthTracker?.recordRoute(route)
        publishMediaHealth()
    }

    func stop() {
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
        reconnectTask?.cancel()
        reconnectTask = nil
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
                      call?.uuid == incoming.uuid else { return }
                if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
                guard !Task.isCancelled,
                      answered,
                      !answerAcknowledged,
                      call?.uuid == incoming.uuid else { return }
                media.sendControl("answer", call: incoming)
            }
            guard answered, !answerAcknowledged, call?.uuid == incoming.uuid else { return }
            audioState = .failed("Module has not confirmed answering. Waiting for the Agent control channel to recover.")
        }
    }

    private func replayAnswerIfNeeded() {
        guard answered, let call else { return }
        answerHandshake.replayIfNeeded { media.sendControl("answer", call: call) }
    }

    private func confirmAnswer(status: String, traceID: String?) {
        let wasAcknowledged = answerAcknowledged
        answerHandshake.confirm(status: status, callConnected: {
            emitLifecycle(.active, source: .agent, traceID: traceID)
        }) { startWebRTCIfReady() }
        guard answerAcknowledged else { return }
        if !wasAcknowledged { traceAudio(phase: "answer_confirmed", title: "Android Answer Confirmed") }
        answerRetryGeneration &+= 1
        answerRetryTask?.cancel()
        answerRetryTask = nil
    }

    private func restartWebRTCNegotiation() {
        guard usesWebRTC, answered, let call else { return }
        let replacingPeer = media.isAudioRunning
        answerHandshake.agentReconnected(role: "agent", stopMedia: {
            webRTCReadiness.reset()
            webRTCStartID = UUID()
            webRTCStartTask?.cancel()
            webRTCStartTask = nil
            media.stopWebRTC()
            audioState = replacingPeer
                ? .connecting(attempt: 1, maximumAttempts: CloudCallRetryPolicy.reconnectDelays.count)
                : .starting
        }, replayAnswer: {
            media.sendControl("answer", call: call)
        }, scheduleConfirmation: {
            scheduleAnswerConfirmation(for: call)
        })
        // Only a fresh answer_ok can re-open startWebRTCIfReady. The agent must
        // recreate its native peer/phone audio bridge before we send new SDP.
    }

    private func startWebRTCIfReady() {
        guard usesWebRTC, audioStartupPermitted, answerAcknowledged,
              canAttemptAudio, !media.isAudioRunning, webRTCStartTask == nil,
              !CallKitController.shared.managesCurrentCall || CallKitController.shared.audioSessionIsActive,
              let call else { return }
        let id = UUID()
        webRTCStartID = id
        // Keep a real recovery indication; the first negotiation is ordinary startup.
        if !audioState.isRetrying { audioState = .starting }
        webRTCStartTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if webRTCStartID == id { webRTCStartTask = nil } }
            do {
                let permission = await AVAudioApplication.requestRecordPermission()
                guard permission else { throw IPhoneCloudCallError.microphonePermissionDenied }
                let iceWaitStarted = ProcessInfo.processInfo.systemUptime
                let config = try await icePreparation.configuration(for: call)
                guard !Task.isCancelled, self.call?.uuid == call.uuid,
                      webRTCStartID == id, audioStartupPermitted, answerAcknowledged,
                      !CallKitController.shared.managesCurrentCall || CallKitController.shared.audioSessionIsActive else { return }
                traceAudio(phase: "ice_prepared", title: "WebRTC ICE Prepared",
                           additionalFields: ["ice_wait_ms": String(format: "%.1f", (ProcessInfo.processInfo.systemUptime - iceWaitStarted) * 1_000)])
                let rtc = RTCAudioSession.sharedInstance()
                if !CallKitController.shared.managesCurrentCall, !ownsWebRTCAudioActivation {
                    rtc.lockForConfiguration()
                    defer { rtc.unlockForConfiguration() }
                    try rtc.setActive(true)
                    ownsWebRTCAudioActivation = true
                }
                rtc.isAudioEnabled = true
                let negotiation = try media.startWebRTC(call: call, servers: config.iceServers.map(\.native))
                webRTCReadiness.begin(negotiation)
                traceAudio(phase: "peer_started", title: "WebRTC Peer Started")
            } catch {
                guard !Task.isCancelled, webRTCStartID == id else { return }
                audioState = .failed(error.localizedDescription)
                traceAudio(phase: "webrtc_failed", title: "WebRTC Audio Failed", detail: error.localizedDescription, isFailure: true)
            }
        }
    }

    private func requestMediaRebuild(_ issue: CloudMediaHealthIssue) {
        guard reconnectTask == nil, let call, answered else { return }
        if mediaHealthTracker == nil {
            mediaHealthTracker = CloudMediaHealthTracker(startedAt: Date(), maximumRebuilds: 3)
        }
        guard mediaHealthTracker?.beginRebuild(for: issue, at: Date()) == true else {
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
                    "downlink_frames": String(snapshot.downlinkFrames),
                    "uplink_frames": String(snapshot.uplinkFrames),
                    "audio_route": snapshot.audioRoute,
                ],
                isFailure: isFailure
            )
        }
    }

    private func recoverConnectionIfNeeded() {
        guard reconnectTask == nil, let call, answered,
              let url = call.authenticatedMediaURL,
              let secret = call.mediaSecret else { return }
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
            defer { if reconnectID == id { reconnectTask = nil } }
            let delays = CloudCallRetryPolicy.reconnectDelays
            await CloudCallRecoveryCoordinator.run(
                delays: delays,
                isCurrent: { self.call?.uuid == call.uuid && self.answered && self.reconnectID == id },
                connect: { index in
                    self.audioState = .connecting(attempt: index + 1, maximumAttempts: delays.count)
                    self.media.stop()
                    try await self.media.connect(to: url, secret: secret)
                }, connected: {
                    self.answerHandshake.invalidate()
                    self.replayAnswerIfNeeded()
                    self.scheduleAnswerConfirmation(for: call)
                    self.startAudioWithRetry()
                }, failed: { error in
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
    var onConnectionLost: ((UUID) -> Void)?
    var onControl: ((CloudCallControlMessage, UUID) -> Void)?

    private let queue = DispatchQueue(label: "com.example.airsim.iphone-cloud-media", qos: .userInteractive)
    private var webSocket: URLSessionWebSocketTask?
    private var networkSession: URLSession?
    private var connectionID = UUID()
    func isCurrentConnection(_ id: UUID) -> Bool { queue.sync { connectionID == id } }
    private var muted = false
    private var stopped = true
    private var controlOperations: [String: CloudCallControlOperationIdentity] = [:]

    var isConnected: Bool {
        queue.sync { webSocket != nil && !stopped }
    }

    var isAudioRunning: Bool { queue.sync { webRTCPeer != nil } }

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

    func startWebRTC(call: IncomingVoIPCall, servers: [RTCIceServer]) throws -> UUID {
        try queue.sync {
            guard !stopped, let socket = webSocket else { throw IPhoneCloudCallError.connectionClosed }
            webRTCPeer?.close()
            let owner = connectionID
            let negotiation = UUID()
            webRTCSessionID = negotiation
            webRTCCall = call
            let peer = try CloudWebRTCPeer(callUUID: call.uuid, generation: call.generation, sessionID: negotiation,
                servers: servers, queue: queue, signal: { [weak self, weak socket] signal in
                    guard let self, let socket, self.webSocket === socket, self.connectionID == owner,
                          self.webRTCPeer?.sessionID == signal.sessionID,
                          let data = try? JSONEncoder().encode(signal), let text = String(data: data, encoding: .utf8) else { return }
                    socket.send(.string(text)) { [weak self] error in
                        guard error != nil else { return }
                        self?.queue.async { [weak self] in
                            guard let self, self.connectionID == owner, self.webRTCSessionID == negotiation else { return }
                            self.onConnectionLost?(owner)
                        }
                    }
                }, connected: { [weak self] in self?.onWebRTCState?(true, owner, negotiation) },
                disconnected: { [weak self] in self?.onWebRTCRecovering?(owner, negotiation) },
                failure: { [weak self] in
                    guard let self else { return }
                    self.webRTCPeer = nil
                    self.onWebRTCState?(false, owner, negotiation)
                }, statistics: { fields in
                    Task { await AgentVerboseTraceRecorder.shared.recordEvent(
                        source: "APP", category: "cloud-call-audio", phase: "webrtc_stats",
                        title: "WebRTC Audio Statistics", fields: fields) }
                })
            webRTCPeer = peer
            peer.setMuted(muted)
            peer.offer()
            return negotiation
        }
    }

    func connect(to url: URL, secret: String) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: IPhoneCloudCallError.connectionClosed)
                    return
                }
                stopped = false
                connectionID = UUID()
                let configuration = URLSessionConfiguration.ephemeral
                configuration.networkServiceType = .voice
                let deliveryQueue = OperationQueue()
                deliveryQueue.name = "com.example.airsim.iphone-cloud-receive"
                deliveryQueue.qualityOfService = .userInteractive
                deliveryQueue.maxConcurrentOperationCount = 1
                let session = URLSession(configuration: configuration, delegate: nil,
                                         delegateQueue: deliveryQueue)
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
                            continuation.resume(throwing: IPhoneCloudCallError.connectionClosed)
                            return
                        }
                        if let error { continuation.resume(throwing: error) }
                        else { continuation.resume() }
                    }
                }
            }
        }
    }

    func sendControl(_ action: String, call: IncomingVoIPCall) {
        queue.async { [weak self] in
            guard let self, let socket = webSocket,
                  let (text, envelope) = controlText(action: action, call: call) else { return }
            traceControl(envelope, phase: "sending")
            socket.send(.string(text)) { [weak self] error in
                guard let error else { return }
                self?.traceControl(envelope, phase: "send_failed", detail: error.localizedDescription, isFailure: true)
            }
        }
    }

    func sendControlAndWait(_ action: String, call: IncomingVoIPCall) async {
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let self, !stopped, let socket = webSocket else {
                    continuation.resume()
                    return
                }
                guard let (text, envelope) = controlText(action: action, call: call) else {
                    continuation.resume()
                    return
                }
                traceControl(envelope, phase: "sending")
                socket.send(.string(text)) { [weak self] error in
                    if let error {
                        self?.traceControl(envelope, phase: "send_failed", detail: error.localizedDescription, isFailure: true)
                    } else {
                        self?.traceControl(envelope, phase: "socket_sent")
                    }
                    continuation.resume()
                }
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
              let text = String(data: data, encoding: .utf8) else { return nil }
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
            self?.webRTCPeer?.setMuted(muted)
        }
    }

    func stopAudio() { queue.sync { stopAudioLocked() } }

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
           let signal = try? JSONDecoder().decode(CloudWebRTCSignal.self, from: data) {
            guard webRTCMode, let call = webRTCCall, let peer = webRTCPeer,
                  signal.matches(call: call, sessionID: peer.sessionID) else { return }
            peer.receive(signal)
            return
        }
        guard let control = try? CloudCallControlMessage.decode(text) else { return }
        onControl?(control, connectionID)
    }
}
