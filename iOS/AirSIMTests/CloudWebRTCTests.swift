import Testing
import Foundation
import WebRTC
import AudioToolbox
@testable import AirSIM

struct CloudWebRTCTests {
    @Test func `Local readiness is versioned and bound to the exact call negotiation`() throws {
        let session = VoWLANWebRTCSession(callUUID: UUID(), generation: 4, sessionID: UUID())
        let body = try JSONEncoder().encode(session)
        var payload = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(payload["version"] as? Int == 1)
        #expect(payload["call_uuid"] as? String == session.callUUID.uuidString.lowercased())
        #expect(payload["session_id"] as? String == session.sessionID.uuidString.lowercased())
        payload["status"] = "ready"
        func status() throws -> VoWLANWebRTCStatus {
            try JSONDecoder().decode(VoWLANWebRTCStatus.self,
                from: JSONSerialization.data(withJSONObject: payload))
        }
        #expect(try status().matches(session))
        payload["session_id"] = UUID().uuidString
        #expect(try !status().matches(session))
        payload["session_id"] = session.sessionID.uuidString
        payload["generation"] = 3
        #expect(try !status().matches(session))
        payload["generation"] = 4
        payload["call_uuid"] = UUID().uuidString
        #expect(try !status().matches(session))
        payload["call_uuid"] = session.callUUID.uuidString
        payload["version"] = 2
        #expect(try !status().matches(session))
    }

    @Test func `Local host ICE alone never claims ready carrier audio`() {
        var readiness = CloudWebRTCReadiness()
        let session = UUID()
        readiness.begin(session)
        readiness.nativeConnected(session)
        #expect(!readiness.isReady)
        readiness.agentConnected(UUID())
        #expect(!readiness.isReady)
        readiness.agentConnected(session)
        #expect(readiness.isReady)
        readiness.nativeDisconnected(UUID())
        #expect(readiness.isReady)
        readiness.nativeDisconnected(session)
        #expect(!readiness.isReady)
        readiness.nativeConnected(session)
        #expect(readiness.isReady)
        readiness.agentRecovering()
        #expect(!readiness.isReady)
        readiness.reset()
        readiness.agentConnected(session)
        readiness.nativeConnected(session)
        #expect(!readiness.isReady)
    }

    @Test(arguments: ["failed", "closed"])
    func `Local terminal status is not readiness`(_ terminal: String) throws {
        let session = VoWLANWebRTCSession(callUUID: UUID(), generation: 1, sessionID: UUID())
        var payload = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(session)) as? [String: Any])
        payload["status"] = terminal
        let status = try JSONDecoder().decode(VoWLANWebRTCStatus.self,
            from: JSONSerialization.data(withJSONObject: payload))
        #expect(status.matches(session))
        #expect(status.status != .ready)
    }

    @Test @MainActor
    func `ICE prefetch and concurrent audio starts share one request`() async throws {
        let gate = ICEFetchGate()
        let preparation = CloudICEPreparation(fetch: { try await gate.fetch($0) })
        let call = try iceCall()
        try await confirmation("first ICE request") { firstRequest in
            gate.onFirstRequest = firstRequest
            preparation.prefetch(for: call)
            try await waitUntil({ !gate.calls.isEmpty }, "first ICE request was not started")
        }
        let first = Task { try await preparation.configuration(for: call) }
        let second = Task { try await preparation.configuration(for: call) }
        gate.complete(0, username: "one")
        let results = try await [first.value, second.value]
        #expect(results.map { $0.iceServers.first?.username } == ["one", "one"])
        #expect(gate.calls.count == 1)
    }

    @Test @MainActor
    func `ICE lease refreshes before expiry and reuses fresh lease`() async throws {
        var time: TimeInterval = 100
        var requests = 0
        let preparation = CloudICEPreparation(fetch: { _ in
            requests += 1
            return self.iceConfig(username: String(requests), ttl: 100)
        }, now: { time })
        let call = try iceCall()
        preparation.prefetch(for: call)
        let first = try await preparation.configuration(for: call)
        time = 189
        let reused = try await preparation.configuration(for: call)
        #expect(first.iceServers.first?.username == reused.iceServers.first?.username)
        #expect(requests == 1)
        time = 190
        let refreshed = try await preparation.configuration(for: call)
        #expect(refreshed.iceServers.first?.username == "2")
        #expect(requests == 2)
    }

    @Test @MainActor
    func `ICE failed prefetch retries once when audio needs it`() async throws {
        var requests = 0
        try await confirmation("prefetch failed") { fetched in
            let preparation = CloudICEPreparation(fetch: { _ in
                requests += 1
                if requests == 1 {
                    fetched()
                    throw CloudWebRTCError.iceUnavailable
                }
                return self.iceConfig(username: "retry")
            })
            let call = try iceCall()
            preparation.prefetch(for: call)
            try await waitUntil({ requests >= 1 }, "failed prefetch did not run")
            let config = try await preparation.configuration(for: call)
            #expect(config.iceServers.first?.username == "retry")
            #expect(requests == 2)
        }
    }

    @Test @MainActor
    func `ICE repeated failure stops after one retry`() async throws {
        var requests = 0
        let preparation = CloudICEPreparation(fetch: { _ in
            requests += 1
            throw CloudWebRTCError.iceUnavailable
        })
        await #expect(throws: CloudWebRTCError.self) {
            _ = try await preparation.configuration(for: iceCall())
        }
        #expect(requests == 2)
    }

    @Test @MainActor
    func `ICE hangup discards late response before next call`() async throws {
        let gate = ICEFetchGate()
        let preparation = CloudICEPreparation(fetch: { try await gate.fetch($0) })
        let old = try iceCall(), next = try iceCall()
        try await confirmation("first ICE request") { firstRequest in
            gate.onFirstRequest = firstRequest
            preparation.prefetch(for: old)
            try await waitUntil({ !gate.calls.isEmpty }, "first ICE request was not started")
        }
        var waiterEntered = false
        let waiter = Task {
            waiterEntered = true
            return try await preparation.configuration(for: old)
        }
        try await waitUntil({ waiterEntered }, "old waiter did not enter the configuration call")
        preparation.cancel()
        try await confirmation("second ICE request") { secondRequest in
            gate.onSecondRequest = secondRequest
            preparation.prefetch(for: next)
            try await waitUntil({ gate.calls.count >= 2 }, "second ICE request was not started")
        }
        // Simulate a transport that delivers a response despite cancellation.
        gate.complete(0, username: "stale")
        await #expect(throws: CancellationError.self) {
            try await waiter.value
        }
        gate.complete(1, username: "next")
        let config = try await preparation.configuration(for: next)
        #expect(config.iceServers.first?.username == "next")
        #expect(gate.calls.map(\.uuid) == [old.uuid, next.uuid])
    }

    @Test @MainActor
    func `ICE audio interruption does not cancel shared preparation`() async throws {
        let gate = ICEFetchGate()
        let preparation = CloudICEPreparation(fetch: { try await gate.fetch($0) })
        let call = try iceCall()
        try await confirmation("first ICE request") { firstRequest in
            gate.onFirstRequest = firstRequest
            preparation.prefetch(for: call)
            try await waitUntil({ !gate.calls.isEmpty }, "first ICE request was not started")
        }
        var waiterEntered = false
        let waiter = Task {
            waiterEntered = true
            return try await preparation.configuration(for: call)
        }
        try await waitUntil({ waiterEntered }, "audio waiter did not enter the configuration call")
        waiter.cancel()
        gate.complete(0, username: "retained")
        await #expect(throws: CancellationError.self) {
            try await waiter.value
        }
        let config = try await preparation.configuration(for: call)
        #expect(config.iceServers.first?.username == "retained")
        #expect(gate.calls.count == 1)
    }

    @Test @MainActor
    func `ICE credentials are scoped to generation secret and relay`() async throws {
        var requests = 0
        let preparation = CloudICEPreparation(fetch: { _ in
            requests += 1
            return self.iceConfig(username: String(requests))
        })
        let id = UUID()
        let calls = try [
            iceCall(id: id),
            iceCall(id: id, generation: 2),
            iceCall(id: id, generation: 2, secret: "y"),
            iceCall(id: id, generation: 2, secret: "y", host: "other.test")
        ]
        for (index, call) in calls.enumerated() {
            let config = try await preparation.configuration(for: call)
            #expect(config.iceServers.first?.username == String(index + 1))
        }
        #expect(requests == 4)
    }

    /// Bounded replacement for the former `await fulfillment(of:timeout:)` waits.
    @MainActor
    private func waitUntil(
        _ condition: @MainActor () -> Bool,
        timeout seconds: TimeInterval = 2,
        _ timeoutMessage: String
    ) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            guard Date() < deadline else {
                struct WaitTimeout: Error {}
                Issue.record("\(timeoutMessage)")
                throw WaitTimeout()
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private func iceCall(id: UUID = UUID(), generation: UInt64 = 1, secret: String = "x",
                         host: String = "relay.test") throws -> IncomingVoIPCall {
        try IncomingVoIPCall(outgoingCallID: "test", uuid: id, number: "1",
            secret: String(repeating: secret, count: 32), mediaURL: URL(string: "wss://\(host)/connect")!,
            generation: generation, mediaTransport: .webRTC)
    }

    private func iceConfig(username: String, ttl: Int = 600) -> CloudICEConfiguration {
        .init(iceServers: [.init(urls: ["turn:relay.test"], username: username, credential: "test")], ttl: ttl)
    }

    @Test func `Signal uses contract keys and round trips`() throws {
        let signal = CloudWebRTCSignal(action: .ice, callUUID: UUID(), generation: 7, sessionID: UUID(),
            candidate: .init(candidate: "candidate:1 1 udp 1 127.0.0.1 1234 typ host", sdpMid: "0", sdpMlineIndex: 0))
        let data = try JSONEncoder().encode(signal)
        #expect(try JSONDecoder().decode(CloudWebRTCSignal.self, from: data) == signal)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["call_uuid"] as? String == signal.callUUID.uuidString.lowercased())
        #expect(json["session_id"] as? String == signal.sessionID.uuidString.lowercased())
        #expect((json["candidate"] as? [String: Any])?["sdp_mline_index"] as? Int == 0)
        #expect(signal.isValid)
    }

    @Test @MainActor
    func `Standalone answer OK publishes connected before media without active message`() {
        let handshake = CloudWebRTCAnswerHandshake()
        var events: [String] = []
        // The standalone agent sends answer_ok only after Telecom is active.
        // No later legacy PCM active event is present on its WebRTC path.
        handshake.confirm(status: "answer_ok", callConnected: {
            events.append("call_connected")
        }) {
            #expect(events == ["call_connected"])
            events.append("start_media")
        }
        #expect(events == ["call_connected", "start_media"])
        handshake.confirm(status: "active", callConnected: {
            Issue.record("Duplicate status republished connection")
        }) { Issue.record("Duplicate status restarted media") }
    }

    @Test @MainActor
    func `Outgoing ringback prepares media without publishing a connected call`() {
        let handshake = CloudWebRTCAnswerHandshake()
        var events: [String] = []
        handshake.confirm(status: "media_prepared", isOutgoing: true,
            callConnected: { events.append("connected") }) { events.append("media") }
        #expect(handshake.acknowledged)
        #expect(events == ["media"])
        handshake.confirm(status: "media_prepared", isOutgoing: true) {
            Issue.record("Duplicate preparation restarted the peer")
        }
        handshake.confirm(status: "active", isOutgoing: true,
            callConnected: { events.append("connected") }) {
            Issue.record("Answer must reuse the prepared peer")
        }
        #expect(events == ["media", "connected"])
        handshake.confirm(status: "answer_ok", isOutgoing: true,
            callConnected: { Issue.record("Duplicate answer republished connection") }) {}
    }

    @Test @MainActor
    func `Incoming call rejects outgoing preparation acknowledgement`() {
        let handshake = CloudWebRTCAnswerHandshake()
        handshake.confirm(status: "media_prepared", isOutgoing: false,
            callConnected: { Issue.record("Unanswered incoming call became active") }) {
            Issue.record("Unanswered incoming call opened audio")
        }
        #expect(!handshake.acknowledged)
    }

    @Test @MainActor
    func `Outgoing reconnect requires fresh preparation and preserves answer ordering`() {
        let handshake = CloudWebRTCAnswerHandshake()
        handshake.invalidate(requiringAnswerOK: true)
        handshake.confirm(status: "active", isOutgoing: true) {
            Issue.record("Old activity bypassed peer preparation")
        }
        #expect(!handshake.acknowledged)
        var offers = 0, connected = 0
        handshake.confirm(status: "media_prepared", isOutgoing: true,
            callConnected: { connected += 1 }) { offers += 1 }
        #expect(offers == 1 && connected == 0)
        handshake.confirm(status: "active", isOutgoing: true,
            callConnected: { connected += 1 }) { offers += 1 }
        #expect(offers == 1 && connected == 1)
    }

    @Test @MainActor
    func `Standalone answer enables recording in app model and ending disables it`() {
        let session = IPhoneCloudCallSession.shared
        let previousLifecycle = session.onLifecycleEvent
        let previousAudio = session.onAudioStateChange
        defer {
            session.onLifecycleEvent = previousLifecycle
            session.onAudioStateChange = previousAudio
        }
        let model = AppModel()
        let id = UUID()
        func publish(_ state: CallLifecycleState) {
            session.onLifecycleEvent?(.init(callID: "record-button-test", callUUID: id,
                generation: 1, state: state, source: .agent, timestamp: Date(), traceID: nil, failure: nil))
        }
        publish(.connecting)
        #expect(!model.canToggleRecording)
        let handshake = CloudWebRTCAnswerHandshake()
        handshake.confirm(status: "answer_ok", callConnected: { publish(.active) }) {}
        #expect(model.callLifecycleSnapshot.state == .active)
        #expect(model.canToggleRecording)
        publish(.ending)
        #expect(!model.canToggleRecording)
        // Late confirmation may not undo an explicit hangup.
        handshake.invalidate()
        handshake.confirm(status: "answer_ok", callConnected: { publish(.active) }) {}
        #expect(model.callLifecycleSnapshot.state == .ending)
        #expect(!model.canToggleRecording)
    }

    @Test @MainActor
    func `Unconfirmed answer cannot publish connected or enable recording`() {
        let handshake = CloudWebRTCAnswerHandshake()
        for status in ["agent_ready", "action_queued", "action_forwarded", "action_error", "webrtc_ready"] {
            handshake.confirm(status: status, callConnected: {
                Issue.record("Unconfirmed call became connected")
            }) { Issue.record("Unconfirmed call started media") }
        }
        #expect(!handshake.acknowledged)
        handshake.invalidate(requiringAnswerOK: true)
        handshake.confirm(status: "active", callConnected: {
            Issue.record("Reconnect requires fresh answer confirmation")
        }) { Issue.record("Stale activity restarted media") }
        #expect(!handshake.acknowledged)
    }

    @Test @MainActor
    func `Agent reconnect replays answer before allowing new offer`() {
        let handshake = CloudWebRTCAnswerHandshake()
        var events: [String] = []
        handshake.confirm { events.append("initial_offer") }
        #expect(handshake.acknowledged)

        // These are the same stop, send, timer and offer callbacks wired into
        // IPhoneCloudCallSession, driven in actual Relay/agent event order.
        handshake.agentReconnected(role: "agent", stopMedia: {
            #expect(!handshake.acknowledged)
            events.append("stop_old_peer")
        }, replayAnswer: {
            events.append("answer")
        }, scheduleConfirmation: {
            events.append("arm_bounded_confirmation")
        })
        #expect(events == ["initial_offer", "stop_old_peer", "answer", "arm_bounded_confirmation"])
        #expect(!handshake.acknowledged)
        // agent_ready may arrive after peer_connected. Replay is idempotent,
        // and still must not produce SDP while the agent has no answer ack.
        handshake.replayIfNeeded { events.append("answer_retry") }
        #expect(!events.contains("replacement_offer"))
        handshake.confirm(status: "active") { Issue.record("Call activity is not a fresh peer answer acknowledgement") }
        #expect(!handshake.acknowledged)
        handshake.confirm { events.append("replacement_offer") }
        #expect(Array(events.suffix(2)) == ["answer_retry", "replacement_offer"])
        #expect(handshake.acknowledged)
        handshake.replayIfNeeded { Issue.record("agent_ready must not create an answer loop after ack") }
        handshake.confirm { Issue.record("duplicate answer_ok must not renegotiate") }
    }

    @Test @MainActor
    func `Watch reconnect preserves acknowledged answer and media`() {
        let handshake = CloudWebRTCAnswerHandshake()
        handshake.confirm {}
        handshake.agentReconnected(role: "watch", stopMedia: { Issue.record("Watch stopped the agent peer") },
            replayAnswer: { Issue.record("Watch replayed answer") },
            scheduleConfirmation: { Issue.record("Watch armed answer retry") })
        #expect(handshake.acknowledged)
    }

    @Test func `Wire bounds match relay`() {
        let id = UUID()
        #expect(!CloudWebRTCSignal(action: .offer, callUUID: id, generation: 1, sessionID: id,
            sdp: String(repeating: "a", count: 48 * 1024 + 1)).isValid)
        #expect(!CloudWebRTCSignal(action: .ice, callUUID: id, generation: 1, sessionID: id,
            candidate: .init(candidate: String(repeating: "a", count: 4097), sdpMid: nil, sdpMlineIndex: 0)).isValid)
        #expect(!CloudWebRTCSignal(action: .ice, callUUID: id, generation: 1, sessionID: id,
            candidate: .init(candidate: "candidate:x", sdpMid: String(repeating: "a", count: 257), sdpMlineIndex: 0)).isValid)
    }

    @Test func `Readiness requires native and agent for current session`() {
        var state = CloudWebRTCReadiness()
        let old = UUID(), current = UUID()
        state.begin(old)
        state.nativeConnected(old)
        #expect(!state.isReady)
        state.agentConnected(old)
        #expect(state.isReady)
        state.begin(current)
        state.nativeConnected(current)
        state.agentConnected(old)
        #expect(!state.isReady)
        state.agentConnected(current)
        #expect(state.isReady)
        state.agentRecovering()
        #expect(!state.isReady)
        state.reset()
        state.nativeConnected(current)
        state.agentConnected(current)
        #expect(!state.isReady)
    }

    @Test func `Only agent reconnect renegotiates and status decodes session`() throws {
        #expect(CloudWebRTCReadiness.shouldRenegotiatePeer(role: "agent"))
        #expect(!CloudWebRTCReadiness.shouldRenegotiatePeer(role: "watch"))
        #expect(!CloudWebRTCReadiness.shouldRenegotiatePeer(role: nil))
        let id = UUID()
        let decoded = try CloudCallControlMessage.decode("{\"status\":\"webrtc_ready\",\"session_id\":\"\(id.uuidString.lowercased())\",\"role\":\"agent\"}")
        let control = try #require(decoded)
        #expect(control.sessionID == id)
        #expect(control.role == "agent")
    }

    @Test func `NetEq caps delay at one second and accelerates the backlog`() {
        let config = RTCConfiguration()
        CloudWebRTCPeer.configurePlayout(config)
        #expect(config.audioJitterBufferMaxPackets == 50)
        #expect(config.audioJitterBufferFastAccelerate)
        #expect(CloudWebRTCPeer.jitterBufferMaxPackets == 50)
    }

    @Test func `Voice SDP forces mono Opus and twenty millisecond frames`() {
        let input = "v=0\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111 0\r\na=rtpmap:111 opus/48000/2\r\na=fmtp:111 minptime=10;useinbandfec=1\r\na=rtpmap:0 PCMU/8000\r\n"
        let output = CloudWebRTCPeer.voiceSDP(input)
        #expect(output.contains("m=audio 9 UDP/TLS/RTP/SAVPF 111\r\n"))
        #expect(!output.contains("PCMU"))
        #expect(output.contains("stereo=0"))
        #expect(output.contains("a=ptime:20\r\na=maxptime:20"))
        #expect(output.contains("useinbandfec=1"))
        #expect(output.contains("usedtx=1"))
    }

    @Test func `ICE request keeps secret out of URL`() throws {
        let id = UUID()
        let call = try IncomingVoIPCall(outgoingCallID: "test", uuid: id, number: "1",
            secret: String(repeating: "x", count: 32), mediaURL: URL(string: "wss://relay.test/v1/calls/test/connect")!)
        let request = try CloudICEConfiguration.request(for: call)
        #expect(request.url?.absoluteString == "https://relay.test/v1/calls/\(id.uuidString.lowercased())/ice?role=iphone")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer " + String(repeating: "x", count: 32))
    }

    @Test func `Invalid and stale signals are rejected`() throws {
        let id = UUID(), session = UUID()
        let call = try IncomingVoIPCall(outgoingCallID: "test", uuid: id, number: "1",
            secret: String(repeating: "x", count: 32), mediaURL: URL(string: "wss://relay.test/connect")!, generation: 7)
        #expect(!CloudWebRTCSignal(action: .answer, callUUID: id, generation: 7, sessionID: UUID(), sdp: "sdp").matches(call: call, sessionID: session))
        #expect(!CloudWebRTCSignal(action: .answer, callUUID: id, generation: 6, sessionID: session, sdp: "sdp").matches(call: call, sessionID: session))
        #expect(!CloudWebRTCSignal(action: .ice, callUUID: id, generation: 7, sessionID: session,
            candidate: .init(candidate: "x", sdpMid: nil, sdpMlineIndex: -1)).isValid)
    }

    @Test func `Remote ICE queue is bounded and fenced by session`() throws {
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
            #expect(failures == 0)
            for _ in 0..<128 { peer.receive(ice(session)) }
            #expect(failures == 0)
            peer.receive(ice(session))
            #expect(failures == 1)
            peer.receive(ice(session))
            #expect(failures == 1)
        }
    }

    @Test func `Statistics use selected audio path and do not leak candidates`() {
        var reducer = CloudWebRTCStatistics()
        var records = statisticsRecords()
        records["decoy"] = .init(type: "candidate-pair", values: [
            "state": "succeeded", "nominated": "true", "currentRoundTripTime": "9",
            "localCandidateId": "unused", "remoteCandidateId": "unused"
        ])
        records["unused"] = .init(type: "local-candidate", values: [
            "candidateType": "relay", "address": "private-candidate-address", "url": "private-turn-url"
        ])
        records["video"] = .init(type: "inbound-rtp", values: [
            "kind": "video", "jitter": "99", "packetsReceived": "999999", "transportId": "video-transport"
        ])
        let fields = reducer.fields(for: records, at: 10)
        #expect(fields["path_rtt_ms"] == "125.000")
        #expect(fields["candidate-pair.currentRoundTripTime"] == "0.125")
        #expect(fields["local-candidate.candidateType"] == "host")
        #expect(fields["remote-candidate.candidateType"] == "srflx")
        #expect(fields["rx_jitter_ms"] == "12.000")
        #expect(fields["codec.mimeType"] == "audio/opus")
        #expect(fields["inbound-rtp.packetsReceived"] == "100")
        #expect(fields["rx_buffer_ms"] == nil, "The first sample is not a measurement interval")
        #expect(!fields.values.contains(where: { $0.contains("private-") }))
    }

    @Test func `Statistics omit path without explicit selected pair`() {
        var reducer = CloudWebRTCStatistics()
        var records = statisticsRecords()
        records["transport"] = .init(type: "transport", values: [:])
        let fields = reducer.fields(for: records, at: 10)
        #expect(fields["path_rtt_ms"] == nil)
        #expect(fields["candidate-pair.currentRoundTripTime"] == nil)
        #expect(fields["local-candidate.candidateType"] == nil)
        #expect(fields["rx_jitter_ms"] == "12.000")
    }

    @Test func `Statistics report interval delay and concealment`() {
        var reducer = CloudWebRTCStatistics()
        _ = reducer.fields(for: statisticsRecords(), at: 10)
        let fields = reducer.fields(for: statisticsRecords(packets: 350, lost: 5,
            concealed: 320, samples: 48_000, delay: 1_440, emitted: 24_000), at: 15)
        #expect(fields["rx_sample_interval_ms"] == "5000.000")
        #expect(fields["rx_buffer_ms"] == "80.000") // (1440 - 800) / (24000 - 16000)
        #expect(fields["rx_concealed_samples"] == "160.000")
        #expect(fields["rx_concealment_pct"] == "1.000")
        #expect(fields["rx_lost_packets"] == "3.000")
    }

    @Test func `Statistics reset intervals for new stream and counter restart`() {
        var reducer = CloudWebRTCStatistics()
        _ = reducer.fields(for: statisticsRecords(), at: 10)
        let reset = reducer.fields(for: statisticsRecords(packets: 1, lost: 0,
            concealed: 0, samples: 160, delay: 8, emitted: 160), at: 15)
        #expect(reset["rx_buffer_ms"] == nil)
        #expect(reset["rx_concealment_pct"] == nil)
        var replacement = statisticsRecords()
        replacement["replacement"] = replacement.removeValue(forKey: "rx")
        #expect(reducer.fields(for: replacement, at: 20)["rx_buffer_ms"] == nil)
        _ = reducer.fields(for: [:], at: 21)
        #expect(reducer.fields(for: replacement, at: 22)["rx_buffer_ms"] == nil)
    }

    @Test func `Statistics handle idle and corrected loss without inventing delay`() {
        var reducer = CloudWebRTCStatistics()
        _ = reducer.fields(for: statisticsRecords(), at: 10)
        let fields = reducer.fields(for: statisticsRecords(lost: 1), at: 15)
        #expect(fields["rx_lost_packets"] == "-1.000")
        #expect(fields["rx_buffer_ms"] == nil)
        #expect(fields["rx_concealment_pct"] == nil)
        var invalid = statisticsRecords()
        invalid["path"] = .init(type: "candidate-pair", values: [
            "state": "succeeded", "currentRoundTripTime": "nan"
        ])
        #expect(reducer.fields(for: invalid, at: 20)["path_rtt_ms"] == nil)
    }

    private func statisticsRecords(packets: Int = 100, lost: Int = 2, concealed: Int = 160,
                                   samples: Int = 32_000, delay: Int = 800, emitted: Int = 16_000)
        -> [String: CloudWebRTCStatistics.Record] {
        [
            "rx": .init(type: "inbound-rtp", values: [
                "kind": "audio", "transportId": "transport", "codecId": "opus",
                "packetsReceived": String(packets), "packetsLost": String(lost), "jitter": "0.012",
                "concealedSamples": String(concealed), "totalSamplesReceived": String(samples),
                "jitterBufferDelay": String(delay), "jitterBufferEmittedCount": String(emitted)
            ]),
            "tx": .init(type: "outbound-rtp", values: [
                "kind": "audio", "transportId": "transport", "codecId": "opus",
                "packetsSent": "90", "bytesSent": "5000"
            ]),
            "opus": .init(type: "codec", values: ["mimeType": "audio/opus", "clockRate": "48000", "channels": "2"]),
            "transport": .init(type: "transport", values: ["selectedCandidatePairId": "path"]),
            "path": .init(type: "candidate-pair", values: [
                "state": "succeeded", "currentRoundTripTime": "0.125",
                "localCandidateId": "local", "remoteCandidateId": "remote",
                "availableOutgoingBitrate": "64000"
            ]),
            "local": .init(type: "local-candidate", values: [
                "candidateType": "host", "protocol": "udp", "address": "private-local-address"
            ]),
            "remote": .init(type: "remote-candidate", values: [
                "candidateType": "srflx", "protocol": "udp", "address": "private-remote-address"
            ])
        ]
    }

    @Test func `Native peers negotiate Opus over host ICE`() async throws {
        try await runLoopback(servers: [], relayOnly: false)
    }

    @Test func `Native peers negotiate Opus through TURN`() async throws {
        guard let path = ProcessInfo.processInfo.environment["AIRSIM_WEBRTC_TURN_CONFIG"] else {
            try Test.cancel("Set AIRSIM_WEBRTC_TURN_CONFIG to a private ephemeral TURN test configuration")
        }
        struct TURN: Decodable { let ios_url: String; let username: String; let credential: String }
        let turn = try JSONDecoder().decode(TURN.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        try await runLoopback(servers: [RTCIceServer(urlStrings: [turn.ios_url], username: turn.username, credential: turn.credential)], relayOnly: true)
    }

    private func runLoopback(servers: [RTCIceServer], relayOnly: Bool) async throws {
        RTCInitializeSSL()
        let queue = DispatchQueue(label: "airsim.webrtc.loopback")
        let id = UUID(), session = UUID()
        let outputA = SyntheticWebRTCAudioDevice(), outputB = SyntheticWebRTCAudioDevice()
        let factoryA = RTCPeerConnectionFactory(encoderFactory: nil, decoderFactory: nil, audioDevice: outputA)
        let factoryB = RTCPeerConnectionFactory(encoderFactory: nil, decoderFactory: nil, audioDevice: outputB)
        var offerer: CloudWebRTCPeer!
        var answerer: CloudWebRTCPeer!
        // Close the peers even when the wait times out, so the audio pump
        // threads cannot leak into other tests running in parallel.
        defer { queue.sync { offerer?.close(); answerer?.close() } }
        var reported = Set<String>()
        var connectedCount = 0
        var negotiatedOpus = false
        var observedRelayCandidate = false
        var observedSelectedPath = false
        try await confirmation("Native host ICE and DTLS connected", expectedCount: 2) { connected in
            try await confirmation("Both native peers report Opus RTP", expectedCount: 2) { stats in
                try queue.sync {
                    offerer = try CloudWebRTCPeer(callUUID: id, generation: 1, sessionID: session, servers: servers, queue: queue, factory: factoryA, relayOnly: relayOnly,
                        signal: { signal in answerer.receive(signal, answering: true) }, connected: { connectedCount += 1; connected() },
                        failure: { Issue.record("Offerer native negotiation failed") }, statistics: { fields in
                            if fields["codec.mimeType"]?.lowercased() == "audio/opus" { negotiatedOpus = true }
                            if fields["local-candidate.candidateType"] == "relay" { observedRelayCandidate = true }
                            if fields["local-candidate.candidateType"] != nil && fields["remote-candidate.candidateType"] != nil {
                                observedSelectedPath = true
                            }
                            if Int(fields["outbound-rtp.packetsSent"] ?? "0") ?? 0 > 0, reported.insert("offerer").inserted { stats() }
                        })
                    answerer = try CloudWebRTCPeer(callUUID: id, generation: 1, sessionID: session, servers: servers, queue: queue, factory: factoryB, relayOnly: relayOnly,
                        signal: { signal in offerer.receive(signal) }, connected: { connectedCount += 1; connected() },
                        failure: { Issue.record("Answerer native negotiation failed") }, statistics: { fields in
                            if Int(fields["inbound-rtp.packetsReceived"] ?? "0") ?? 0 > 0, reported.insert("answerer").inserted { stats() }
                        })
                    offerer.offer()
                }
                // Bounded stand-in for the former shared 20 s fulfillment timeout.
                let deadline = Date().addingTimeInterval(20)
                while queue.sync(execute: { reported.count < 2 || connectedCount < 2 }) {
                    guard Date() < deadline else {
                        struct LoopbackTimeout: Error {}
                        Issue.record("Native peers did not both connect and report Opus RTP within 20 seconds")
                        throw LoopbackTimeout()
                    }
                    try await Task.sleep(for: .milliseconds(20))
                }
            }
        }
        let observed = queue.sync { (negotiatedOpus, observedRelayCandidate, observedSelectedPath) }
        #expect(observed.0, "Native codec stats must identify audio/opus")
        #expect(observed.2, "Native transport references must resolve the selected candidate pair")
        if relayOnly { #expect(observed.1, "Force-relay test must gather TURN candidates") }
        #expect(outputA.receivedAudibleFrames > 0, "Real Opus decode must deliver audible PCM to peer A")
        #expect(outputB.receivedAudibleFrames > 0, "Real Opus decode must deliver audible PCM to peer B")
    }

    @Test func `Cloud call rejects legacy PCM`() throws {
        let supported: Set<CloudMediaTransport> = [.legacyPCM, .webRTC]
        let legacy = CloudMediaTransportNegotiator.resolve(
            requested: .legacyPCM,
            appSupported: supported,
            agentSupported: supported
        )
        #expect(legacy == .failure(.unsupported))

        let forced = CloudMediaTransportNegotiator.resolve(
            requested: .webRTC,
            appSupported: [.webRTC],
            agentSupported: [.webRTC]
        )
        #expect(try forced.get() == .webRTC)

        let call = try IncomingVoIPCall(
            outgoingCallID: "legacy",
            uuid: UUID(),
            number: "1",
            secret: String(repeating: "s", count: 32),
            mediaURL: URL(string: "wss://relay.test/connect")!,
            mediaTransport: .legacyPCM
        )
        #expect(call.requestedMediaTransport == .webRTC)
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

@MainActor
private final class ICEFetchGate {
    var onFirstRequest: Confirmation?
    var onSecondRequest: Confirmation?
    private(set) var calls: [IncomingVoIPCall] = []
    private var continuations: [CheckedContinuation<CloudICEConfiguration, Error>] = []

    func fetch(_ call: IncomingVoIPCall) async throws -> CloudICEConfiguration {
        try await withCheckedThrowingContinuation { continuation in
            calls.append(call)
            continuations.append(continuation)
            if calls.count == 1 { onFirstRequest?() }
            if calls.count == 2 { onSecondRequest?() }
        }
    }

    func complete(_ index: Int, username: String) {
        continuations[index].resume(returning: .init(
            iceServers: [.init(urls: ["turn:relay.test"], username: username, credential: "test")], ttl: 600))
    }
}

struct CloudAudioStatusTests {
    @Test func `First cloud audio startup is not presented as a retry`() {
        #expect(!CloudCallAudioState.starting.isRetrying)
        #expect(CloudCallAudioState.connecting(attempt: 1, maximumAttempts: 4).isRetrying)
        #expect(CallAudioStatusPresentation.text(localAudioActive: false, cloudState: .starting)
                == "Connecting Cloud Audio")
        #expect(CallAudioStatusPresentation.text(localAudioActive: false,
                                                cloudState: .connecting(attempt: 1, maximumAttempts: 4))
                == "Retrying Cloud Audio 1/4")
        #expect(CallAudioStatusPresentation.text(localAudioActive: false, cloudState: .connected)
                == "Cloud Audio Connected")
    }
}
