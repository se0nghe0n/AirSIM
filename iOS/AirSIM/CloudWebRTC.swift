import AVFoundation
import Foundation
import WebRTC

/// CallKit owns the system session for both local and cloud native peers.
/// Forward each activation exactly once, even before a peer has been created.
enum WebRTCCallAudioSession {
    static func didActivate(_ session: AVAudioSession) {
        let rtc = RTCAudioSession.sharedInstance()
        rtc.useManualAudio = true
        rtc.audioSessionDidActivate(session)
        rtc.isAudioEnabled = true
    }
    static func didDeactivate(_ session: AVAudioSession) {
        let rtc = RTCAudioSession.sharedInstance()
        rtc.isAudioEnabled = false
        rtc.audioSessionDidDeactivate(session)
    }
}

/// Shared v1 wire format. SDP and ICE are deliberately never included in diagnostics.
struct CloudWebRTCSignal: Codable, Equatable, Sendable {
    enum Action: String, Codable, Sendable { case offer = "webrtc_offer", answer = "webrtc_answer", ice = "webrtc_ice" }
    struct Candidate: Codable, Equatable, Sendable {
        let candidate: String
        let sdpMid: String?
        let sdpMlineIndex: Int32
        enum CodingKeys: String, CodingKey {
            case candidate
            case sdpMid = "sdp_mid"
            case sdpMlineIndex = "sdp_mline_index"
        }
    }
    let action: Action
    let callUUID: UUID
    let generation: UInt64
    let sessionID: UUID
    var sdp: String? = nil
    var candidate: Candidate? = nil
    enum CodingKeys: String, CodingKey {
        case action, generation, sdp, candidate
        case callUUID = "call_uuid"
        case sessionID = "session_id"
    }
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(action, forKey: .action)
        try values.encode(callUUID.uuidString.lowercased(), forKey: .callUUID)
        try values.encode(generation, forKey: .generation)
        try values.encode(sessionID.uuidString.lowercased(), forKey: .sessionID)
        try values.encodeIfPresent(sdp, forKey: .sdp)
        try values.encodeIfPresent(candidate, forKey: .candidate)
    }

    func matches(call: IncomingVoIPCall, sessionID: UUID) -> Bool {
        callUUID == call.uuid && generation == call.generation && self.sessionID == sessionID
    }
    var isValid: Bool {
        guard generation > 0 else { return false }
        switch action {
        case .offer, .answer: return candidate == nil && sdp.map { !$0.isEmpty && $0.utf8.count <= 48 * 1024 } == true
        case .ice: return sdp == nil && candidate.map { !$0.candidate.isEmpty && $0.candidate.utf16.count <= 4096 && ($0.sdpMid?.utf16.count ?? 0) <= 256 && $0.sdpMlineIndex >= 0 } == true
        }
    }
}

/// Owns the answer/offer ordering across agent WebSocket lifetimes. The call
/// identity survives reconnect, but the agent's native peer and PCM bridge do not.
@MainActor
final class CloudWebRTCAnswerHandshake {
    private(set) var acknowledged = false
    private var requiresAnswerOK = false

    func invalidate(requiringAnswerOK: Bool = false) {
        acknowledged = false
        requiresAnswerOK = requiringAnswerOK
    }

    func agentReconnected(role: String?, stopMedia: () -> Void,
                          replayAnswer: () -> Void, scheduleConfirmation: () -> Void) {
        guard CloudWebRTCReadiness.shouldRenegotiatePeer(role: role) else { return }
        invalidate(requiringAnswerOK: true)
        stopMedia()
        replayIfNeeded(replayAnswer)
        scheduleConfirmation()
    }

    func replayIfNeeded(_ sendAnswer: () -> Void) {
        guard !acknowledged else { return }
        sendAnswer()
    }

    func confirm(status: String = "answer_ok", callConnected: () -> Void = {}, _ startMedia: () -> Void) {
        guard !acknowledged, status == "answer_ok" || (!requiresAnswerOK && status == "active") else { return }
        acknowledged = true
        // Standalone WebRTC confirms Telecom with answer_ok; only legacy PCM
        // emits a subsequent active event. Publish connection before media starts.
        callConnected()
        startMedia()
    }
}

/// Readiness belongs to one negotiation, not merely the reusable WebSocket.
struct CloudWebRTCReadiness: Equatable, Sendable {
    private(set) var sessionID: UUID?
    private(set) var nativeReady = false
    private(set) var agentReady = false
    var isReady: Bool { sessionID != nil && nativeReady && agentReady }
    mutating func begin(_ sessionID: UUID) { self = .init(sessionID: sessionID) }
    mutating func reset() { self = .init() }
    mutating func nativeConnected(_ sessionID: UUID) {
        guard self.sessionID == sessionID else { return }
        nativeReady = true
    }
    mutating func nativeDisconnected(_ sessionID: UUID) {
        guard self.sessionID == sessionID else { return }
        nativeReady = false
    }
    mutating func agentConnected(_ sessionID: UUID) {
        guard self.sessionID == sessionID else { return }
        agentReady = true
    }
    mutating func agentRecovering() { agentReady = false }
    static func shouldRenegotiatePeer(role: String?) -> Bool { role == "agent" }
}

struct CloudICEServer: Decodable, Sendable {
    let urls: [String]
    let username: String?
    let credential: String?
    var native: RTCIceServer {
        RTCIceServer(urlStrings: urls, username: username, credential: credential)
    }
}

struct CloudICEConfiguration: Decodable, Sendable {
    let iceServers: [CloudICEServer]
    let ttl: Int
    enum CodingKeys: String, CodingKey { case iceServers = "ice_servers", ttl }

    static func request(for call: IncomingVoIPCall) throws -> URLRequest {
        guard let mediaURL = call.authenticatedMediaURL,
              var url = URLComponents(url: mediaURL, resolvingAgainstBaseURL: false),
              let secret = call.mediaSecret,
              !secret.isEmpty else { throw IPhoneCloudCallError.mediaUnavailable }
        url.scheme = "https"
        url.path = "/v1/calls/\(call.uuid.uuidString.lowercased())/ice"
        url.queryItems = [URLQueryItem(name: "role", value: "iphone")]
        url.fragment = nil
        guard let endpoint = url.url else { throw IPhoneCloudCallError.mediaUnavailable }
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        return request
    }

    static func fetch(for call: IncomingVoIPCall) async throws -> CloudICEConfiguration {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request(for: call))
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            throw CloudWebRTCError.iceUnavailable
        }
        let config = try JSONDecoder().decode(Self.self, from: data)
        guard config.ttl > 0, config.iceServers.contains(where: {
            $0.urls.contains { $0.hasPrefix("turn:") || $0.hasPrefix("turns:") }
        }) else { throw CloudWebRTCError.turnUnavailable }
        return config
    }
}

/// Per-call TURN preparation overlaps the control handshake without starting audio.
/// Credentials never survive a call, credential rotation, or an expired lease.
@MainActor
final class CloudICEPreparation {
    private struct Identity: Equatable {
        let callUUID: UUID
        let generation: UInt64
        let endpoint: URL?
        let authorization: String?
    }
    private struct Prepared {
        let configuration: CloudICEConfiguration
        let validUntil: TimeInterval
    }
    private struct Pending {
        let id: UUID
        let identity: Identity
        let task: Task<Prepared, Error>
    }
    private var pending: Pending?
    private let fetch: (IncomingVoIPCall) async throws -> CloudICEConfiguration
    private let now: () -> TimeInterval

    init(fetch: @escaping (IncomingVoIPCall) async throws -> CloudICEConfiguration = { try await CloudICEConfiguration.fetch(for: $0) },
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.fetch = fetch
        self.now = now
    }

    func prefetch(for call: IncomingVoIPCall) {
        // Failure stays private until audio needs the result; it can then retry once.
        _ = try? prepare(for: call)
    }

    func cancel() {
        pending?.task.cancel()
        pending = nil
    }

    func configuration(for call: IncomingVoIPCall) async throws -> CloudICEConfiguration {
        for attempt in 0..<2 {
            try Task.checkCancellation()
            let request = try prepare(for: call)
            do {
                let prepared = try await request.task.value
                try Task.checkCancellation()
                guard pending?.id == request.id else { throw CancellationError() }
                guard now() < prepared.validUntil else { throw CloudWebRTCError.iceUnavailable }
                return prepared.configuration
            } catch {
                // An interrupted audio start must not cancel another waiter's
                // preparation. Hangup/new-call cancellation is explicit above.
                try Task.checkCancellation()
                guard pending?.id == request.id else { throw CancellationError() }
                pending = nil
                if attempt == 1 { throw error }
            }
        }
        throw CloudWebRTCError.iceUnavailable
    }

    private func prepare(for call: IncomingVoIPCall) throws -> Pending {
        let request = try CloudICEConfiguration.request(for: call)
        let identity = Identity(callUUID: call.uuid, generation: call.generation,
                                endpoint: request.url, authorization: request.value(forHTTPHeaderField: "Authorization"))
        if let pending, pending.identity == identity { return pending }
        cancel()
        let startedAt = now()
        let fetch = self.fetch
        let task = Task { @MainActor in
            let configuration = try await fetch(call)
            try Task.checkCancellation()
            // Start the lease at request time, leaving room for network delay
            // and clock differences. A reconnect may reuse only a fresh lease.
            let ttl = Double(configuration.ttl)
            return Prepared(configuration: configuration,
                            validUntil: startedAt + ttl - min(30, ttl * 0.1))
        }
        let requestState = Pending(id: UUID(), identity: identity, task: task)
        pending = requestState
        return requestState
    }
}

enum CloudWebRTCError: LocalizedError {
    case iceUnavailable, turnUnavailable, negotiationFailed, candidateOverflow
    var errorDescription: String? {
        switch self {
        case .iceUnavailable: return "WebRTC ICE configuration is unavailable."
        case .turnUnavailable: return "WebRTC TURN relay is not configured."
        case .negotiationFailed: return "WebRTC audio negotiation failed."
        case .candidateOverflow: return "WebRTC received too many pending ICE candidates."
        }
    }
}

/// Reduces native reports to the active audio path. Never expose candidate
/// addresses, URLs, credentials or unrelated streams in diagnostic output.
struct CloudWebRTCStatistics {
    struct Record {
        let type: String
        let values: [String: String]
    }
    private struct Sample {
        let id: String
        let time: TimeInterval
        let counters: [String: Double]
    }
    private var previous: Sample?

    mutating func fields(for records: [String: Record], at time: TimeInterval) -> [String: String] {
        var fields: [String: String] = [:]
        func audio(_ record: Record) -> Bool {
            if let kind = record.values["kind"] ?? record.values["mediaType"] { return kind == "audio" }
            guard let id = record.values["codecId"] else { return false }
            return records[id]?.values["mimeType"]?.lowercased().hasPrefix("audio/") == true
        }
        func single(_ type: String) -> (key: String, value: Record)? {
            let matches = records.filter { $0.value.type == type && audio($0.value) }
            return matches.count == 1 ? matches.first : nil
        }
        func copy(_ record: Record?, prefix: String, keys: [String]) {
            guard let record else { return }
            for key in keys {
                if let value = record.values[key] { fields["\(prefix).\(key)"] = value }
            }
        }
        let inbound = single("inbound-rtp")
        let outbound = single("outbound-rtp")
        copy(inbound?.value, prefix: "inbound-rtp", keys: [
            "packetsReceived", "bytesReceived", "packetsLost", "jitter", "concealedSamples",
            "totalSamplesReceived", "jitterBufferDelay", "jitterBufferEmittedCount"
        ])
        copy(outbound?.value, prefix: "outbound-rtp", keys: ["packetsSent", "bytesSent"])
        let codecID = inbound?.value.values["codecId"] ?? outbound?.value.values["codecId"]
        copy(codecID.flatMap { records[$0] }, prefix: "codec", keys: ["mimeType", "clockRate", "channels"])

        let transportIDs = Set([inbound?.value.values["transportId"], outbound?.value.values["transportId"]].compactMap { $0 })
        // The native audio-only peer normally has one transport. Refuse to pick
        // a path if the report is ambiguous or its reference is incomplete.
        let transports = transportIDs.isEmpty
            ? records.filter { $0.value.type == "transport" }.map(\.value)
            : transportIDs.compactMap { records[$0] }.filter { $0.type == "transport" }
        if transports.count == 1, let id = transports.first?.values["selectedCandidatePairId"],
           let pair = records[id], pair.type == "candidate-pair", pair.values["state"] == "succeeded" {
            copy(pair, prefix: "candidate-pair", keys: ["currentRoundTripTime", "availableOutgoingBitrate"])
            if let rtt = number(pair.values["currentRoundTripTime"]), rtt >= 0 {
                fields["path_rtt_ms"] = formatted(rtt * 1_000)
            }
            if let id = pair.values["localCandidateId"], let candidate = records[id], candidate.type == "local-candidate" {
                copy(candidate, prefix: "local-candidate", keys: ["candidateType", "protocol"])
            }
            if let id = pair.values["remoteCandidateId"], let candidate = records[id], candidate.type == "remote-candidate" {
                copy(candidate, prefix: "remote-candidate", keys: ["candidateType", "protocol"])
            }
        }
        if let jitter = number(inbound?.value.values["jitter"]), jitter >= 0 {
            fields["rx_jitter_ms"] = formatted(jitter * 1_000)
        }

        guard let inbound else { previous = nil; return fields }
        let keys = ["packetsReceived", "packetsLost", "concealedSamples", "totalSamplesReceived",
                    "jitterBufferDelay", "jitterBufferEmittedCount"]
        let counters = Dictionary(uniqueKeysWithValues: keys.compactMap { key -> (String, Double)? in
            number(inbound.value.values[key]).map { (key, $0) }
        })
        let current = Sample(id: inbound.key, time: time, counters: counters)
        defer { previous = current }
        guard let previous, previous.id == current.id, current.time > previous.time else { return fields }
        // packetsLost may fall when a late packet corrects the loss estimate.
        // The other cumulative counters must not run backwards.
        for key in keys where key != "packetsLost" {
            if let old = previous.counters[key], let new = counters[key], new < old { return fields }
        }
        func delta(_ key: String) -> Double? {
            guard let old = previous.counters[key], let new = counters[key] else { return nil }
            return new - old
        }
        fields["rx_sample_interval_ms"] = formatted((time - previous.time) * 1_000)
        if let loss = delta("packetsLost") { fields["rx_lost_packets"] = formatted(loss) }
        if let concealed = delta("concealedSamples") {
            fields["rx_concealed_samples"] = formatted(concealed)
            if let total = delta("totalSamplesReceived"), total > 0 {
                fields["rx_concealment_pct"] = formatted(100 * concealed / total)
            }
        }
        if let delay = delta("jitterBufferDelay"), let emitted = delta("jitterBufferEmittedCount"), emitted > 0 {
            fields["rx_buffer_ms"] = formatted(1_000 * delay / emitted)
        }
        return fields
    }

    private func number(_ value: String?) -> Double? {
        guard let value, let number = Double(value), number.isFinite else { return nil }
        return number
    }
    private func formatted(_ number: Double) -> String {
        String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), number)
    }
}

/// All peer operations and callbacks run on the owning transport's serial queue.
/// Native WebRTC owns capture, Opus, AEC, jitter buffering, PLC and playout.
final class CloudWebRTCPeer: NSObject, RTCPeerConnectionDelegate, @unchecked Sendable {
    private static let initializeNative: Void = {
        RTCInitializeSSL()
        RTCSetMinDebugLogLevel(.none)
    }()
    /// Native setup never activates capture; CallKit or the in-app call owns it.
    static func prepareFactory() { _ = initializeNative }
    private var recordingAudio: CloudWebRTCRecordingAudio?
    private var ownedFactory: RTCPeerConnectionFactory?

    let sessionID: UUID
    private let callUUID: UUID
    private let generation: UInt64
    private let queue: DispatchQueue
    private let signal: (CloudWebRTCSignal) -> Void
    private let failure: () -> Void
    private let connected: () -> Void
    private let disconnected: () -> Void
    private let statistics: ([String: String]) -> Void
    private var peer: RTCPeerConnection?
    private var track: RTCAudioTrack?
    private var remoteDescriptionSet = false
    private var remoteCandidates: [RTCIceCandidate] = []
    private var localDescriptionSent = false
    private var localCandidates: [RTCIceCandidate] = []
    private var timer: DispatchSourceTimer?
    private var statisticsReducer = CloudWebRTCStatistics()
    private var statisticsPending = false
    private let hostOnly: Bool
    private var hostLocalAction: CloudWebRTCSignal.Action?
    private var hostLocalReady = false
    private var hostGatheringComplete = false
    private var hostLocalSent = false
    private(set) var isConnected = false
    let usesHostICE: Bool

    init(callUUID: UUID, generation: UInt64, sessionID: UUID = UUID(), servers: [RTCIceServer],
         queue: DispatchQueue, factory factoryOverride: RTCPeerConnectionFactory? = nil, relayOnly: Bool = false,
         hostOnly: Bool = false,
         signal: @escaping (CloudWebRTCSignal) -> Void, connected: @escaping () -> Void,
         disconnected: @escaping () -> Void = {},
         failure: @escaping () -> Void, statistics: @escaping ([String: String]) -> Void) throws {
        self.callUUID = callUUID
        self.generation = generation
        self.sessionID = sessionID
        self.queue = queue
        self.signal = signal
        self.connected = connected
        self.disconnected = disconnected
        self.failure = failure
        self.statistics = statistics
        self.hostOnly = hostOnly
        self.usesHostICE = hostOnly && !relayOnly
        super.init()
        Self.prepareFactory()
        let factory: RTCPeerConnectionFactory
        if let providedFactory = factoryOverride {
            factory = providedFactory
        } else {
            let audio = CloudWebRTCRecordingAudio(source: .init(callUUID: callUUID))
            let native = RTCPeerConnectionFactory(
                audioDeviceModuleType: .platformDefault, bypassVoiceProcessing: false,
                encoderFactory: RTCVideoEncoderFactoryH264(), decoderFactory: RTCVideoDecoderFactoryH264(),
                audioProcessingModule: audio.module)
            recordingAudio = audio
            ownedFactory = native
            factory = native
        }
        let config = RTCConfiguration()
        Self.configurePlayout(config)
        config.iceServers = servers
        if relayOnly { config.iceTransportPolicy = .relay }
        config.sdpSemantics = .unifiedPlan
        config.continualGatheringPolicy = hostOnly ? .gatherOnce : .gatherContinually
        guard let peer = factory.peerConnection(with: config,
            constraints: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil), delegate: self) else {
            throw CloudWebRTCError.negotiationFailed
        }
        self.peer = peer
        let source = factory.audioSource(with: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil))
        let track = factory.audioTrack(with: source, trackId: "airsim-audio")
        self.track = track
        peer.add(track, streamIds: ["airsim"])
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in self?.collectStatistics() }
        timer.resume()
        self.timer = timer
        queue.asyncAfter(deadline: .now() + 25) { [weak self] in
            guard let self, self.peer != nil, !self.isConnected else { return }
            self.fail()
        }
    }

    func setMuted(_ muted: Bool) {
        track?.isEnabled = !muted
    }
    func close() {
        timer?.cancel()
        timer = nil
        let old = peer
        peer = nil
        old?.delegate = nil
        old?.close()
        track = nil
        remoteCandidates.removeAll()
        localCandidates.removeAll()
        isConnected = false
    }
    private func fail() { guard peer != nil else { return }; close(); failure() }

    func offer() {
        guard let peer else { return }
        peer.offer(for: RTCMediaConstraints(mandatoryConstraints: ["OfferToReceiveAudio": "true", "OfferToReceiveVideo": "false"], optionalConstraints: nil)) { [weak self] sdp, error in
            self?.queue.async { [weak self] in
                guard let self, self.peer === peer else { return }
                guard error == nil, let sdp else { self.fail(); return }
                self.setLocal(sdp, action: .offer)
            }
        }
    }

    func receive(_ message: CloudWebRTCSignal, answering: Bool = false) {
        guard message.isValid, message.callUUID == callUUID, message.generation == generation,
              message.sessionID == sessionID, let peer else { return }
        switch message.action {
        case .answer, .offer:
            guard (message.action == .offer) == answering, !remoteDescriptionSet, let sdp = message.sdp else { return }
            let description = RTCSessionDescription(type: answering ? .offer : .answer, sdp: sdp)
            peer.setRemoteDescription(description) { [weak self] error in
                self?.queue.async { [weak self] in
                    guard let self, self.peer === peer else { return }
                    guard error == nil else { self.fail(); return }
                    self.remoteDescriptionSet = true
                    for candidate in self.remoteCandidates { self.add(candidate, to: peer) }
                    self.remoteCandidates.removeAll()
                    if answering {
                        peer.answer(for: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)) { [weak self] answer, error in
                            self?.queue.async { [weak self] in
                                guard let self, self.peer === peer else { return }
                                guard error == nil, let answer else { self.fail(); return }
                                self.setLocal(answer, action: .answer)
                            }
                        }
                    }
                }
            }
        case .ice:
            guard let wire = message.candidate else { return }
            let candidate = RTCIceCandidate(sdp: wire.candidate, sdpMLineIndex: wire.sdpMlineIndex, sdpMid: wire.sdpMid)
            if remoteDescriptionSet { add(candidate, to: peer) }
            else if remoteCandidates.count < 128 { remoteCandidates.append(candidate) }
            else { fail() }
        }
    }

    private func add(_ candidate: RTCIceCandidate, to peer: RTCPeerConnection) {
        peer.add(candidate) { [weak self] error in
            self?.queue.async { [weak self] in
                guard let self, self.peer === peer, error != nil else { return }
                self.fail()
            }
        }
    }

    /// One second of 20 ms Opus. Fast accelerate lets NetEq shorten a grown buffer.
    static let jitterBufferMaxPackets: Int32 = 50
    static func configurePlayout(_ config: RTCConfiguration) {
        config.audioJitterBufferMaxPackets = jitterBufferMaxPackets
        config.audioJitterBufferFastAccelerate = true
    }

    /// Keep Opus mono at 20 ms; no SDP or credentials enter trace output.
    static func voiceSDP(_ sdp: String) -> String {
        let lines = sdp.components(separatedBy: "\r\n")
        let opus = lines.first(where: { $0.hasPrefix("a=rtpmap:") && $0.lowercased().contains("opus/48000") })?
            .dropFirst("a=rtpmap:".count).split(separator: " ").first.map(String.init)
        guard let opus else { return sdp }
        var inAudio = false
        var result: [String] = []
        for line in lines {
            if line.hasPrefix("m=") { inAudio = line.hasPrefix("m=audio ") }
            if inAudio {
                if line.hasPrefix("m=audio ") {
                    result.append(line.split(separator: " ").prefix(3).joined(separator: " ") + " " + opus)
                    continue
                }
                if line.hasPrefix("a=ptime:") || line.hasPrefix("a=maxptime:") { continue }
                let codecPrefix = ["a=rtpmap:", "a=fmtp:", "a=rtcp-fb:"].first { line.hasPrefix($0) }
                if let codecPrefix {
                    let payload = line.dropFirst(codecPrefix.count).split(separator: " ").first.map(String.init)
                    if payload != opus && payload != "*" { continue }
                }
            }
            result.append(line)
        }
        if let index = result.firstIndex(where: { $0.hasPrefix("a=fmtp:\(opus) ") }) {
            let prefix = "a=fmtp:\(opus) "
            let other = result[index].dropFirst(prefix.count).split(separator: ";").map(String.init)
                .filter { !["stereo", "sprop-stereo", "useinbandfec", "usedtx", "minptime"].contains($0.split(separator: "=").first.map(String.init) ?? "") }
            result[index] = prefix + (other + ["minptime=20", "useinbandfec=1", "usedtx=1", "stereo=0", "sprop-stereo=0"]).joined(separator: ";")
        }
        if let index = result.firstIndex(where: { $0.hasPrefix("a=rtpmap:\(opus) ") }) {
            result.insert(contentsOf: ["a=ptime:20", "a=maxptime:20"], at: index)
        }
        return result.joined(separator: "\r\n")
    }

    private func setLocal(_ description: RTCSessionDescription, action: CloudWebRTCSignal.Action) {
        guard let peer else { return }
        let description = RTCSessionDescription(type: description.type, sdp: Self.voiceSDP(description.sdp))
        peer.setLocalDescription(description) { [weak self] error in
            self?.queue.async { [weak self] in
                guard let self, self.peer === peer else { return }
                guard error == nil else { self.fail(); return }
                if self.hostOnly {
                    self.hostLocalAction = action
                    self.hostLocalReady = true
                    self.publishHostLocal()
                    return
                }
                self.signal(.init(action: action, callUUID: self.callUUID, generation: self.generation, sessionID: self.sessionID, sdp: description.sdp))
                self.localDescriptionSent = true
                for candidate in self.localCandidates { self.send(candidate) }
                self.localCandidates.removeAll()
            }
        }
    }
    private func publishHostLocal() {
        guard hostOnly, hostLocalReady, hostGatheringComplete, !hostLocalSent,
              let action = hostLocalAction, let sdp = peer?.localDescription?.sdp, !sdp.isEmpty else { return }
        hostLocalSent = true
        signal(.init(action: action, callUUID: callUUID, generation: generation, sessionID: sessionID, sdp: sdp))
    }

    private func send(_ candidate: RTCIceCandidate) {
        signal(.init(action: .ice, callUUID: callUUID, generation: generation, sessionID: sessionID,
            candidate: .init(candidate: candidate.sdp, sdpMid: candidate.sdpMid, sdpMlineIndex: candidate.sdpMLineIndex)))
    }
    func collectStatistics() {
        guard let peer, !statisticsPending else { return }
        statisticsPending = true
        peer.statistics { [weak self] report in
            self?.queue.async { [weak self] in
                guard let self, self.peer === peer else { return }
                self.statisticsPending = false
                let records = report.statistics.mapValues {
                    CloudWebRTCStatistics.Record(type: $0.type, values: $0.values.mapValues { String(describing: $0) })
                }
                var fields = self.statisticsReducer.fields(for: records, at: ProcessInfo.processInfo.systemUptime)
                fields["transport"] = "webrtc"
                fields["session_id"] = self.sessionID.uuidString.lowercased()
                self.statistics(fields)
            }
        }
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        queue.async { [weak self] in
            guard let self, self.peer === peerConnection, newState == .complete else { return }
            self.hostGatheringComplete = true
            self.publishHostLocal()
        }
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        queue.async { [weak self] in
            guard let self, self.peer === peerConnection, !self.hostOnly else { return }
            if self.localDescriptionSent { self.send(candidate) }
            else if self.localCandidates.count < 128 { self.localCandidates.append(candidate) }
            else { self.fail() }
        }
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {
        queue.async { [weak self] in
            guard let self, self.peer === peerConnection else { return }
            if newState == .connected, !self.isConnected {
                self.isConnected = true
                self.connected()
            } else if newState == .disconnected {
                self.isConnected = false
                self.disconnected()
            } else if newState == .failed {
                self.fail()
            }
        }
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        queue.async { [weak self] in
            guard let self, self.peer === peerConnection else { return }
            switch newState {
            case .connected, .completed: break
            case .failed: self.fail()
            case .disconnected:
                self.queue.asyncAfter(deadline: .now() + 8) { [weak self] in
                    guard let self, self.peer === peerConnection, peerConnection.iceConnectionState == .disconnected else { return }
                    self.fail()
                }
            default: break
            }
        }
    }
}
