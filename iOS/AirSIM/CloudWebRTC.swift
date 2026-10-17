import AVFoundation
import Foundation
import WebRTC

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
              let secret = url.queryItems?.first(where: { $0.name == "token" })?.value,
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

/// All peer operations and callbacks run on the owning transport's serial queue.
/// Native WebRTC owns capture, Opus, AEC, jitter buffering, PLC and playout.
final class CloudWebRTCPeer: NSObject, RTCPeerConnectionDelegate, @unchecked Sendable {
    private static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        RTCSetMinDebugLogLevel(.none)
        return RTCPeerConnectionFactory()
    }()
    let sessionID: UUID
    private let callUUID: UUID
    private let generation: UInt64
    private let queue: DispatchQueue
    private let signal: (CloudWebRTCSignal) -> Void
    private let failure: () -> Void
    private let connected: () -> Void
    private let statistics: ([String: String]) -> Void
    private var peer: RTCPeerConnection?
    private var track: RTCAudioTrack?
    private var remoteDescriptionSet = false
    private var remoteCandidates: [RTCIceCandidate] = []
    private var localDescriptionSent = false
    private var localCandidates: [RTCIceCandidate] = []
    private var timer: DispatchSourceTimer?
    private(set) var isConnected = false

    init(callUUID: UUID, generation: UInt64, sessionID: UUID = UUID(), servers: [RTCIceServer],
         queue: DispatchQueue, factory: RTCPeerConnectionFactory? = nil, relayOnly: Bool = false,
         signal: @escaping (CloudWebRTCSignal) -> Void, connected: @escaping () -> Void,
         failure: @escaping () -> Void, statistics: @escaping ([String: String]) -> Void) throws {
        self.callUUID = callUUID
        self.generation = generation
        self.sessionID = sessionID
        self.queue = queue
        self.signal = signal
        self.connected = connected
        self.failure = failure
        self.statistics = statistics
        super.init()
        let factory = factory ?? Self.factory
        let config = RTCConfiguration()
        config.iceServers = servers
        if relayOnly { config.iceTransportPolicy = .relay }
        config.sdpSemantics = .unifiedPlan
        config.continualGatheringPolicy = .gatherContinually
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

    func setMuted(_ muted: Bool) { track?.isEnabled = !muted }
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
                self.signal(.init(action: action, callUUID: self.callUUID, generation: self.generation, sessionID: self.sessionID, sdp: description.sdp))
                self.localDescriptionSent = true
                for candidate in self.localCandidates { self.send(candidate) }
                self.localCandidates.removeAll()
            }
        }
    }
    private func send(_ candidate: RTCIceCandidate) {
        signal(.init(action: .ice, callUUID: callUUID, generation: generation, sessionID: sessionID,
            candidate: .init(candidate: candidate.sdp, sdpMid: candidate.sdpMid, sdpMlineIndex: candidate.sdpMLineIndex)))
    }
    func collectStatistics() {
        guard let peer else { return }
        peer.statistics { [weak self] report in
            self?.queue.async { [weak self] in
                guard let self, self.peer === peer else { return }
                var fields = ["transport": "webrtc", "session_id": self.sessionID.uuidString.lowercased()]
                for stat in report.statistics.values {
                    let allowed: [String]
                    switch stat.type {
                    case "inbound-rtp": allowed = ["packetsReceived", "bytesReceived", "packetsLost", "jitter", "concealedSamples", "totalSamplesReceived", "jitterBufferDelay", "jitterBufferEmittedCount"]
                    case "outbound-rtp": allowed = ["packetsSent", "bytesSent"]
                    case "codec": allowed = ["mimeType", "clockRate", "channels"]
                    case "local-candidate": allowed = ["candidateType"]
                    case "candidate-pair": allowed = ["currentRoundTripTime", "availableOutgoingBitrate"]
                    default: continue
                    }
                    for key in allowed { if let value = stat.values[key] { fields["\(stat.type).\(key)"] = "\(value)" } }
                }
                self.statistics(fields)
            }
        }
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        queue.async { [weak self] in
            guard let self, self.peer === peerConnection else { return }
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
