import XCTest
import WebRTC
import AudioToolbox
@testable import AirSIM

final class CloudWebRTCTests: XCTestCase {
    func testSignalUsesContractKeysAndRoundTrips() throws {
        let signal = CloudWebRTCSignal(action: .ice, callUUID: UUID(), generation: 7, sessionID: UUID(),
            candidate: .init(candidate: "candidate:1 1 udp 1 127.0.0.1 1234 typ host", sdpMid: "0", sdpMlineIndex: 0))
        let data = try JSONEncoder().encode(signal)
        XCTAssertEqual(try JSONDecoder().decode(CloudWebRTCSignal.self, from: data), signal)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["call_uuid"] as? String, signal.callUUID.uuidString.lowercased())
        XCTAssertEqual(json["session_id"] as? String, signal.sessionID.uuidString.lowercased())
        XCTAssertEqual((json["candidate"] as? [String: Any])?["sdp_mline_index"] as? Int, 0)
        XCTAssertTrue(signal.isValid)
    }
    @MainActor
    func testAgentReconnectReplaysAnswerBeforeAllowingNewOffer() {
        let handshake = CloudWebRTCAnswerHandshake()
        var events: [String] = []
        handshake.confirm { events.append("initial_offer") }
        XCTAssertTrue(handshake.acknowledged)

        // These are the same stop, send, timer and offer callbacks wired into
        // IPhoneCloudCallSession, driven in actual Relay/agent event order.
        handshake.agentReconnected(role: "agent", stopMedia: {
            XCTAssertFalse(handshake.acknowledged)
            events.append("stop_old_peer")
        }, replayAnswer: {
            events.append("answer")
        }, scheduleConfirmation: {
            events.append("arm_bounded_confirmation")
        })
        XCTAssertEqual(events, ["initial_offer", "stop_old_peer", "answer", "arm_bounded_confirmation"])
        XCTAssertFalse(handshake.acknowledged)
        // agent_ready may arrive after peer_connected. Replay is idempotent,
        // and still must not produce SDP while the agent has no answer ack.
        handshake.replayIfNeeded { events.append("answer_retry") }
        XCTAssertFalse(events.contains("replacement_offer"))
        handshake.confirm(status: "active") { XCTFail("Call activity is not a fresh peer answer acknowledgement") }
        XCTAssertFalse(handshake.acknowledged)
        handshake.confirm { events.append("replacement_offer") }
        XCTAssertEqual(events.suffix(2), ["answer_retry", "replacement_offer"])
        XCTAssertTrue(handshake.acknowledged)
        handshake.replayIfNeeded { XCTFail("agent_ready must not create an answer loop after ack") }
        handshake.confirm { XCTFail("duplicate answer_ok must not renegotiate") }
    }

    @MainActor
    func testWatchReconnectPreservesAcknowledgedAnswerAndMedia() {
        let handshake = CloudWebRTCAnswerHandshake()
        handshake.confirm {}
        handshake.agentReconnected(role: "watch", stopMedia: { XCTFail("Watch stopped the agent peer") },
            replayAnswer: { XCTFail("Watch replayed answer") },
            scheduleConfirmation: { XCTFail("Watch armed answer retry") })
        XCTAssertTrue(handshake.acknowledged)
    }

    func testWireBoundsMatchRelay() {
        let id = UUID()
        XCTAssertFalse(CloudWebRTCSignal(action: .offer, callUUID: id, generation: 1, sessionID: id,
            sdp: String(repeating: "a", count: 48 * 1024 + 1)).isValid)
        XCTAssertFalse(CloudWebRTCSignal(action: .ice, callUUID: id, generation: 1, sessionID: id,
            candidate: .init(candidate: String(repeating: "a", count: 4097), sdpMid: nil, sdpMlineIndex: 0)).isValid)
        XCTAssertFalse(CloudWebRTCSignal(action: .ice, callUUID: id, generation: 1, sessionID: id,
            candidate: .init(candidate: "candidate:x", sdpMid: String(repeating: "a", count: 257), sdpMlineIndex: 0)).isValid)
    }
    func testReadinessRequiresNativeAndAgentForCurrentSession() {
        var state = CloudWebRTCReadiness()
        let old = UUID(), current = UUID()
        state.begin(old)
        state.nativeConnected(old)
        XCTAssertFalse(state.isReady)
        state.agentConnected(old)
        XCTAssertTrue(state.isReady)
        state.begin(current)
        state.nativeConnected(current)
        state.agentConnected(old)
        XCTAssertFalse(state.isReady)
        state.agentConnected(current)
        XCTAssertTrue(state.isReady)
        state.agentRecovering()
        XCTAssertFalse(state.isReady)
        state.reset()
        state.nativeConnected(current)
        state.agentConnected(current)
        XCTAssertFalse(state.isReady)
    }
    func testOnlyAgentReconnectRenegotiatesAndStatusDecodesSession() throws {
        XCTAssertTrue(CloudWebRTCReadiness.shouldRenegotiatePeer(role: "agent"))
        XCTAssertFalse(CloudWebRTCReadiness.shouldRenegotiatePeer(role: "watch"))
        XCTAssertFalse(CloudWebRTCReadiness.shouldRenegotiatePeer(role: nil))
        let id = UUID()
        let control = try XCTUnwrap(CloudPCMControlMessage.decode("{\"status\":\"webrtc_ready\",\"session_id\":\"\(id.uuidString.lowercased())\",\"role\":\"agent\"}"))
        XCTAssertEqual(control.sessionID, id)
        XCTAssertEqual(control.role, "agent")
    }
    func testVoiceSDPForcesMonoOpusAndTwentyMillisecondFrames() {
        let input = "v=0\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111 0\r\na=rtpmap:111 opus/48000/2\r\na=fmtp:111 minptime=10;useinbandfec=1\r\na=rtpmap:0 PCMU/8000\r\n"
        let output = CloudWebRTCPeer.voiceSDP(input)
        XCTAssertTrue(output.contains("m=audio 9 UDP/TLS/RTP/SAVPF 111\r\n"))
        XCTAssertFalse(output.contains("PCMU"))
        XCTAssertTrue(output.contains("stereo=0"))
        XCTAssertTrue(output.contains("a=ptime:20\r\na=maxptime:20"))
        XCTAssertTrue(output.contains("useinbandfec=1"))
        XCTAssertTrue(output.contains("usedtx=1"))
    }
    func testICERequestKeepsSecretOutOfURL() throws {
        let id = UUID()
        let call = try IncomingVoIPCall(outgoingCallID: "test", uuid: id, number: "1",
            secret: String(repeating: "x", count: 32), mediaURL: URL(string: "wss://relay.test/v1/calls/test/connect")!)
        let request = try CloudICEConfiguration.request(for: call)
        XCTAssertEqual(request.url?.absoluteString, "https://relay.test/v1/calls/\(id.uuidString.lowercased())/ice?role=iphone")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer " + String(repeating: "x", count: 32))
    }
    func testInvalidAndStaleSignalsAreRejected() throws {
        let id = UUID(), session = UUID()
        let call = try IncomingVoIPCall(outgoingCallID: "test", uuid: id, number: "1",
            secret: String(repeating: "x", count: 32), mediaURL: URL(string: "wss://relay.test/connect")!, generation: 7)
        XCTAssertFalse(CloudWebRTCSignal(action: .answer, callUUID: id, generation: 7, sessionID: UUID(), sdp: "sdp").matches(call: call, sessionID: session))
        XCTAssertFalse(CloudWebRTCSignal(action: .answer, callUUID: id, generation: 6, sessionID: session, sdp: "sdp").matches(call: call, sessionID: session))
        XCTAssertFalse(CloudWebRTCSignal(action: .ice, callUUID: id, generation: 7, sessionID: session,
            candidate: .init(candidate: "x", sdpMid: nil, sdpMlineIndex: -1)).isValid)
    }
    func testRemoteICEQueueIsBoundedAndFencedBySession() throws {
        RTCInitializeSSL()
        let queue = DispatchQueue(label: "airsim.webrtc.ice-bound")
        let id = UUID(), session = UUID()
        var failures = 0
        try queue.sync {
            let peer = try CloudWebRTCPeer(callUUID: id, generation: 7, sessionID: session,
                servers: [], queue: queue, signal: { _ in }, connected: {}, failure: { failures += 1 }, statistics: { _ in })
            defer { peer.close() }
            func ice(_ session: UUID) -> CloudWebRTCSignal {
                .init(action: .ice, callUUID: id, generation: 7, sessionID: session,
                    candidate: .init(candidate: "candidate:1 1 udp 2122260223 127.0.0.1 1234 typ host", sdpMid: "0", sdpMlineIndex: 0))
            }
            for _ in 0..<200 { peer.receive(ice(UUID())) }
            XCTAssertEqual(failures, 0)
            for _ in 0..<128 { peer.receive(ice(session)) }
            XCTAssertEqual(failures, 0)
            peer.receive(ice(session))
            XCTAssertEqual(failures, 1)
            peer.receive(ice(session))
            XCTAssertEqual(failures, 1)
        }
    }
    func testNativePeersNegotiateOpusOverHostICE() async throws {
        try await runLoopback(servers: [], relayOnly: false)
    }
    func testNativePeersNegotiateOpusThroughTURN() async throws {
        guard let path = ProcessInfo.processInfo.environment["AIRSIM_WEBRTC_TURN_CONFIG"] else {
            throw XCTSkip("Set AIRSIM_WEBRTC_TURN_CONFIG to a private ephemeral TURN test configuration")
        }
        struct TURN: Decodable { let ios_url: String; let username: String; let credential: String }
        let turn = try JSONDecoder().decode(TURN.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        try await runLoopback(servers: [RTCIceServer(urlStrings: [turn.ios_url], username: turn.username, credential: turn.credential)], relayOnly: true)
    }
    private func runLoopback(servers: [RTCIceServer], relayOnly: Bool) async throws {
        RTCInitializeSSL()
        let queue = DispatchQueue(label: "airsim.webrtc.loopback")
        let connected = expectation(description: "Native host ICE and DTLS connected")
        connected.expectedFulfillmentCount = 2
        let stats = expectation(description: "Both native peers report Opus RTP")
        stats.expectedFulfillmentCount = 2
        let id = UUID(), session = UUID()
        let outputA = SyntheticWebRTCAudioDevice(), outputB = SyntheticWebRTCAudioDevice()
        let factoryA = RTCPeerConnectionFactory(encoderFactory: nil, decoderFactory: nil, audioDevice: outputA)
        let factoryB = RTCPeerConnectionFactory(encoderFactory: nil, decoderFactory: nil, audioDevice: outputB)
        var offerer: CloudWebRTCPeer!
        var answerer: CloudWebRTCPeer!
        var reported = Set<String>()
        var negotiatedOpus = false
        var observedRelayCandidate = false
        try queue.sync {
            offerer = try CloudWebRTCPeer(callUUID: id, generation: 1, sessionID: session, servers: servers, queue: queue, factory: factoryA, relayOnly: relayOnly,
                signal: { signal in answerer.receive(signal, answering: true) }, connected: { connected.fulfill() },
                failure: { XCTFail("Offerer native negotiation failed") }, statistics: { fields in
                    if fields["codec.mimeType"]?.lowercased() == "audio/opus" { negotiatedOpus = true }
                    if fields["local-candidate.candidateType"] == "relay" { observedRelayCandidate = true }
                    if Int(fields["outbound-rtp.packetsSent"] ?? "0") ?? 0 > 0, reported.insert("offerer").inserted { stats.fulfill() }
                })
            answerer = try CloudWebRTCPeer(callUUID: id, generation: 1, sessionID: session, servers: servers, queue: queue, factory: factoryB, relayOnly: relayOnly,
                signal: { signal in offerer.receive(signal) }, connected: { connected.fulfill() },
                failure: { XCTFail("Answerer native negotiation failed") }, statistics: { fields in
                    if Int(fields["inbound-rtp.packetsReceived"] ?? "0") ?? 0 > 0, reported.insert("answerer").inserted { stats.fulfill() }
                })
            offerer.offer()
        }
        await fulfillment(of: [connected, stats], timeout: 20)
        let observed = queue.sync { (negotiatedOpus, observedRelayCandidate) }
        XCTAssertTrue(observed.0, "Native codec stats must identify audio/opus")
        if relayOnly { XCTAssertTrue(observed.1, "Force-relay test must gather TURN candidates") }
        XCTAssertGreaterThan(outputA.receivedAudibleFrames, 0, "Real Opus decode must deliver audible PCM to peer A")
        XCTAssertGreaterThan(outputB.receivedAudibleFrames, 0, "Real Opus decode must deliver audible PCM to peer B")
        queue.sync { offerer.close(); answerer.close() }
    }
}

/// Deterministic native ADM boundary: 440 Hz PCM goes into the real Opus encoder,
/// decoded PCM is measured here instead of touching a simulator microphone/speaker.
private final class SyntheticWebRTCAudioDevice: NSObject, RTCAudioDevice, @unchecked Sendable {
    let deviceInputSampleRate = 48_000.0
    let deviceOutputSampleRate = 48_000.0
    let inputIOBufferDuration = 0.01
    let outputIOBufferDuration = 0.01
    let inputNumberOfChannels = 1
    let outputNumberOfChannels = 1
    let inputLatency = 0.0
    let outputLatency = 0.0
    var isInitialized: Bool { lock.withLock { deviceDelegate != nil } }
    let isPlayoutInitialized = true
    let isRecordingInitialized = true
    var isPlaying: Bool { lock.withLock { playing } }
    var isRecording: Bool { lock.withLock { recording } }
    var receivedAudibleFrames: Int { lock.withLock { audibleFrames } }
    private let lock = NSLock()
    private var deviceDelegate: RTCAudioDeviceDelegate?
    private var playing = false
    private var recording = false
    private var audibleFrames = 0
    private var thread: Thread?
    private let threadStopped = DispatchSemaphore(value: 0)

    func initialize(with delegate: RTCAudioDeviceDelegate) -> Bool {
        lock.withLock { deviceDelegate = delegate }
        let thread = Thread { [weak self] in
            guard let self else { return }
            self.pump()
            self.threadStopped.signal()
        }
        self.thread = thread
        thread.start()
        return true
    }
    func terminateDevice() -> Bool {
        lock.withLock { deviceDelegate = nil; playing = false; recording = false }
        thread?.cancel()
        if thread != nil { _ = threadStopped.wait(timeout: .now() + 1) }
        thread = nil
        return true
    }
    func initializePlayout() -> Bool { true }
    func initializeRecording() -> Bool { true }
    func startPlayout() -> Bool { lock.withLock { playing = true }; return true }
    func stopPlayout() -> Bool { lock.withLock { playing = false }; return true }
    func startRecording() -> Bool { lock.withLock { recording = true }; return true }
    func stopRecording() -> Bool { lock.withLock { recording = false }; return true }

    private func pump() {
        var position = 0
        while !Thread.current.isCancelled {
            let state = lock.withLock { (deviceDelegate, playing, recording) }
            guard let delegate = state.0 else { break }
            var flags = AudioUnitRenderActionFlags()
            var timestamp = AudioTimeStamp()
            var samples = [Int16](repeating: 0, count: 480)
            if state.2 {
                for i in samples.indices { samples[i] = Int16(sin(Double(position + i) * 2 * .pi * 440 / 48_000) * 8000) }
                position += 480
                samples.withUnsafeMutableBytes { bytes in
                    var list = AudioBufferList(mNumberBuffers: 1,
                        mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: 960, mData: bytes.baseAddress))
                    _ = delegate.deliverRecordedData(&flags, &timestamp, 0, 480, &list, nil, nil)
                }
            }
            if state.1 {
                samples.withUnsafeMutableBytes { bytes in
                    var list = AudioBufferList(mNumberBuffers: 1,
                        mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: 960, mData: bytes.baseAddress))
                    _ = delegate.getPlayoutData(&flags, &timestamp, 0, 480, &list)
                }
                if samples.contains(where: { abs(Int($0)) > 100 }) { lock.withLock { audibleFrames += 1 } }
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
    }
}
