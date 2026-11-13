import Foundation
import Testing
import os

@testable import AirSIM

private struct DialFailure: Error {}

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

private func outgoingCall(
    id: UUID = UUID(),
    generation: UInt64 = 1,
    host: String = "relay.test"
) throws -> IncomingVoIPCall {
    try IncomingVoIPCall(
        outgoingCallID: "outgoing-\(id.uuidString.lowercased())",
        uuid: id,
        number: "1",
        secret: String(repeating: "x", count: 32),
        mediaURL: URL(string: "wss://\(host)/connect")!,
        generation: generation,
        mediaTransport: .webRTC
    )
}

private func incomingCall(id: UUID = UUID(), generation: UInt64 = 1, host: String = "relay.test") throws
    -> IncomingVoIPCall
{
    try IncomingVoIPCall(userInfo: [
        "event": "incoming_call", "call_id": "incoming-\(id.uuidString.lowercased())",
        "call_uuid": id.uuidString, "generation": generation,
        "media_url": "wss://\(host)/connect", "call_secret": String(repeating: "x", count: 32),
    ])
}

struct CloudCommandPollScheduleTests {
    @Test func `Dial result is polled sooner at first and then at the steady interval`() {
        let intervals = (0..<6).map { CloudCommandPollSchedule.dial.interval(afterPoll: $0) }
        #expect(
            intervals == [
                .milliseconds(100), .milliseconds(200), .milliseconds(300),
                .milliseconds(500), .milliseconds(500), .milliseconds(500),
            ]
        )
        // The early polls only use up the first steady intervals' worth of time.
        let early = CloudCommandPollSchedule.dialInitialIntervals.reduce(Duration.zero, +)
        #expect(early <= CloudCommandPollSchedule.steadyInterval * 2)
        #expect(
            CloudCommandPollSchedule.dialInitialIntervals.allSatisfy { $0 < CloudCommandPollSchedule.steadyInterval }
        )
    }

    @Test func `Other commands keep one poll per steady interval from the first poll`() {
        for poll in [0, 1, 2, 3, 10, 600] {
            #expect(CloudCommandPollSchedule.steady.interval(afterPoll: poll) == .milliseconds(500))
        }
        #expect(CloudCommandPollSchedule.dial.interval(afterPoll: 600) == .milliseconds(500))
    }
}

private func dialAcceptanceControl(
    for call: IncomingVoIPCall,
    overrides: [String: Any] = [:],
    omitting: String? = nil
) throws -> CloudCallControlMessage {
    var payload: [String: Any] = [
        "status": "outgoing_dial_accepted", "call_id": call.callID,
        "call_uuid": call.uuid.uuidString, "generation": call.generation,
    ]
    payload.merge(overrides) { _, new in new }
    if let omitting { payload.removeValue(forKey: omitting) }
    let data = try JSONSerialization.data(withJSONObject: payload)
    let control = try CloudCallControlMessage.decode(String(decoding: data, as: UTF8.self))
    return try #require(control)
}

struct CloudOutgoingDialAcceptancePolicyTests {
    @Test func `Only exact current outgoing dial proof is accepted`() throws {
        let call = try outgoingCall()
        let proof = try dialAcceptanceControl(for: call)
        #expect(CloudOutgoingDialAcceptancePolicy.accepts(proof, for: call, currentConnection: true))
        #expect(!CloudOutgoingDialAcceptancePolicy.accepts(proof, for: call, currentConnection: false))
        for field in ["call_id", "call_uuid", "generation"] {
            #expect(
                !CloudOutgoingDialAcceptancePolicy.accepts(
                    try dialAcceptanceControl(for: call, omitting: field),
                    for: call,
                    currentConnection: true
                )
            )
        }
        for overrides: [String: Any] in [
            ["call_id": "other"], ["call_uuid": UUID().uuidString], ["generation": 0],
            ["generation": 2], ["status": "agent_ready"], ["status": "media_prepared"], ["status": "active"],
        ] {
            #expect(
                !CloudOutgoingDialAcceptancePolicy.accepts(
                    try dialAcceptanceControl(for: call, overrides: overrides),
                    for: call,
                    currentConnection: true
                )
            )
        }
        let incoming = try incomingCall()
        #expect(
            !CloudOutgoingDialAcceptancePolicy.accepts(
                try dialAcceptanceControl(for: incoming),
                for: incoming,
                currentConnection: true
            )
        )
    }

    @Test @MainActor func `Dial proof is not answer acknowledgement or audio permission`() {
        #expect(!CloudCallAnswerPolicy.isAcknowledged(status: "outgoing_dial_accepted"))
        let handshake = CloudWebRTCAnswerHandshake()
        handshake.confirm(
            status: "outgoing_dial_accepted",
            isOutgoing: true,
            callConnected: { Issue.record("Dial invocation cannot report remote answer") }
        ) { Issue.record("Dial invocation cannot start WebRTC") }
        #expect(!handshake.acknowledged)
    }
}

@MainActor
struct CloudOutgoingDialAcceptanceRaceTests {
    @Test func `Proof before waiting is latched`() async {
        let latch = CloudOutgoingDialAcceptance()
        latch.accept()
        #expect(await latch.wait())
        #expect(latch.waiterCount == 0)
    }

    @Test func `Latched proof wins a race whose HTTP result is still pending`() async throws {
        let latch = CloudOutgoingDialAcceptance()
        latch.accept()
        #expect(
            try await CloudOutgoingDialAcceptanceRace.wait(signaling: latch) {
                try await Task.sleep(for: .seconds(30))
            } == .signaling
        )
        #expect(latch.waiterCount == 0)
    }

    @Test func `Proof wins and cancels HTTP polling without releasing preparation`() async throws {
        let latch = CloudOutgoingDialAcceptance()
        var httpStarted = false
        var httpCancelled = false
        let race = Task {
            try await CloudOutgoingDialAcceptanceRace.wait(signaling: latch) {
                httpStarted = true
                do { try await Task.sleep(for: .seconds(30)) } catch {
                    httpCancelled = true
                    throw error
                }
            }
        }
        try await waitUntil({ httpStarted && latch.waiterCount == 1 }, "race did not start")
        latch.accept()
        #expect(try await race.value == .signaling)
        #expect(httpCancelled)
        #expect(latch.waiterCount == 0)
        #expect(await latch.wait())
    }

    @Test func `HTTP completion cancels only its proof waiter`() async throws {
        let latch = CloudOutgoingDialAcceptance()
        #expect(try await CloudOutgoingDialAcceptanceRace.wait(signaling: latch, http: {}) == .http)
        #expect(latch.waiterCount == 0)
        latch.accept()
        #expect(await latch.wait())
    }

    @Test func `Old Android without proof uses HTTP`() async throws {
        #expect(try await CloudOutgoingDialAcceptanceRace.wait(signaling: nil, http: {}) == .http)
    }

    @Test func `HTTP failure remains a failure and releases proof waiter`() async {
        let latch = CloudOutgoingDialAcceptance()
        await #expect(throws: DialFailure.self) {
            try await CloudOutgoingDialAcceptanceRace.wait(signaling: latch) { throw DialFailure() }
        }
        #expect(latch.waiterCount == 0)
    }

    @Test func `Cancellation promptly drains both pending lanes`() async throws {
        let latch = CloudOutgoingDialAcceptance()
        var httpStarted = false
        var httpCancelled = false
        let race = Task {
            try await CloudOutgoingDialAcceptanceRace.wait(signaling: latch) {
                httpStarted = true
                do { try await Task.sleep(for: .seconds(30)) } catch {
                    httpCancelled = true
                    throw error
                }
            }
        }
        try await waitUntil({ httpStarted && latch.waiterCount == 1 }, "race did not start")
        race.cancel()
        await #expect(throws: CancellationError.self) { try await race.value }
        #expect(httpCancelled)
        #expect(latch.waiterCount == 0)
    }

    @Test func `Cancellation before waiter registration does not leak`() async {
        let latch = CloudOutgoingDialAcceptance()
        let waiter = Task { await latch.wait() }
        waiter.cancel()
        #expect(!(await waiter.value))
        #expect(latch.waiterCount == 0)
    }

    @Test func `Socket loss disables proof but leaves HTTP fallback running`() async throws {
        let signaling = CloudOutgoingDialAcceptance()
        let http = CloudOutgoingDialAcceptance()
        var finished = false
        let race = Task {
            let result = try await CloudOutgoingDialAcceptanceRace.wait(signaling: signaling) {
                _ = await http.wait()
                try Task.checkCancellation()
            }
            finished = true
            return result
        }
        try await waitUntil({ signaling.waiterCount == 1 && http.waiterCount == 1 }, "race did not start")
        signaling.invalidate()
        signaling.accept() // A stale receive callback cannot resurrect this socket's proof.
        #expect(!(await signaling.wait()))
        #expect(!finished)
        http.accept()
        #expect(try await race.value == .http)
        #expect(signaling.waiterCount == 0 && http.waiterCount == 0)
    }

    @Test func `Replacing or discarding prewarm invalidates only the old proof`() async throws {
        let prewarm = CloudOutgoingPrewarm()
        let first = try outgoingCall()
        prewarm.begin(first, sessionHasCall: false, release: {}, connect: {}, expired: { _ in })
        let old = try #require(prewarm.entry?.acceptance)
        old.accept()
        let next = try outgoingCall()
        prewarm.begin(next, sessionHasCall: false, release: {}, connect: {}, expired: { _ in })
        #expect(!(await old.wait()))
        let current = try #require(prewarm.entry?.acceptance)
        #expect(!prewarm.discard(call: first, release: {}))
        current.accept()
        #expect(await current.wait())
        #expect(prewarm.discard(call: next, release: {}))
        #expect(!(await current.wait()))
    }
}

struct CloudSignalingConnectionGateTests {
    @Test func `Queued pong cannot steal cancellation cleanup ownership`() {
        let connection = UUID()
        let gate = CloudSignalingConnectionGate(connection: connection)
        var pending: CloudSignalingConnectionGate? = gate
        var socketOpen = true
        // The cancellation handler runs before an already queued pong, while its queue cleanup is still pending.
        #expect(gate.finish(.failure(CancellationError())))
        gate.finishPong(.success(()), pending: &pending)
        #expect(pending === gate)
        if gate.ownsConnection(connection) {
            pending = nil
            socketOpen = false
        }
        #expect(!socketOpen && pending == nil)
    }

    @Test func `Cancellation cleanup uses socket identity after pending marker is cleared`() {
        let connection = UUID()
        let gate = CloudSignalingConnectionGate(connection: connection)
        #expect(gate.finish(.failure(CancellationError())))
        // Receive failure can clear the pending marker before cancellation cleanup reaches the bridge queue.
        var pending: CloudSignalingConnectionGate?
        gate.finishPong(.failure(IPhoneCloudCallError.connectionClosed), pending: &pending)
        #expect(gate.ownsConnection(connection))
        let replacement = CloudSignalingConnectionGate(connection: UUID())
        pending = replacement
        gate.finishPong(.success(()), pending: &pending)
        #expect(pending === replacement)
        #expect(!gate.ownsConnection(replacement.connection))
    }

    @Test func `Exact outgoing proof resolves pending connection before pong only once`() throws {
        let call = try outgoingCall()
        let connection = UUID()
        let gate = CloudSignalingConnectionGate(connection: connection, outgoing: call)
        let results = OSAllocatedUnfairLock(initialState: [Bool]())
        gate.install { result in results.withLock { $0.append((try? result.get()) != nil) } }
        #expect(gate.accept(try dialAcceptanceControl(for: call), connection: connection))
        #expect(!gate.isPending)
        #expect(!gate.finish(.success(())))
        #expect(!gate.finish(.failure(DialFailure())))
        #expect(results.withLock { $0 } == [true])
    }

    @Test func `Wrong socket or incomplete proof cannot bypass pong`() throws {
        let call = try outgoingCall()
        let connection = UUID()
        let gate = CloudSignalingConnectionGate(connection: connection, outgoing: call)
        #expect(!gate.accept(try dialAcceptanceControl(for: call), connection: UUID()))
        for field in ["call_id", "call_uuid", "generation"] {
            #expect(!gate.accept(try dialAcceptanceControl(for: call, omitting: field), connection: connection))
        }
        #expect(gate.isPending)
        #expect(gate.finish(.success(())))
    }

    @Test func `Incoming and ordinary connections still require pong`() throws {
        let incoming = try incomingCall()
        let connection = UUID()
        for gate in [
            CloudSignalingConnectionGate(connection: connection),
            CloudSignalingConnectionGate(connection: connection, outgoing: incoming),
        ] {
            #expect(!gate.accept(try dialAcceptanceControl(for: incoming), connection: connection))
            #expect(gate.isPending)
            #expect(gate.finish(.success(())))
        }
    }

    @Test func `Stop socket loss or cancellation wins once even before continuation installation`() throws {
        for error: Error in [CancellationError(), IPhoneCloudCallError.connectionClosed, DialFailure()] {
            let call = try outgoingCall()
            let connection = UUID()
            let gate = CloudSignalingConnectionGate(connection: connection, outgoing: call)
            #expect(gate.finish(.failure(error)))
            let results = OSAllocatedUnfairLock(initialState: [Bool]())
            gate.install { result in results.withLock { $0.append((try? result.get()) != nil) } }
            #expect(!gate.finish(.success(())))
            #expect(!gate.accept(try dialAcceptanceControl(for: call), connection: connection))
            #expect(results.withLock { $0 } == [false])
        }
    }
}

struct OutgoingAnswerReplayPolicyTests {
    @Test func `First outgoing answer_pending is replayed early and the second completes the regular interval`() {
        let delays = (0..<4).map {
            CloudCallAnswerPolicy.quickReplayDelay(
                status: "answer_pending",
                isOutgoing: true,
                priorOutgoingPendingReplays: $0
            )
        }
        #expect(delays[0] == CloudCallAnswerPolicy.outgoingFirstPendingReplayDelay)
        #expect((0.25...0.3).contains(delays[0]))
        // Never confirmed later than with the regular one-second replay alone.
        #expect(abs(delays[0] + delays[1] - CloudCallAnswerPolicy.quickReplayDelay) < 0.000_1)
        #expect(delays[2] == CloudCallAnswerPolicy.quickReplayDelay)
        #expect(delays[3] == CloudCallAnswerPolicy.quickReplayDelay)
        // Replays stay inside the confirmation window instead of extending it.
        #expect(delays[0] < CloudCallAnswerPolicy.confirmationDelays[1])
    }

    @Test func `Incoming replay delay is unchanged`() {
        for status in ["answer_pending", "action_error", "action_rejected"] {
            for prior in 0..<3 {
                #expect(
                    CloudCallAnswerPolicy.quickReplayDelay(
                        status: status,
                        isOutgoing: false,
                        priorOutgoingPendingReplays: prior
                    ) == 1
                )
            }
        }
    }

    @Test func `Outgoing errors other than answer_pending keep the regular delay`() {
        for status in ["action_error", "action_rejected"] {
            #expect(
                CloudCallAnswerPolicy.quickReplayDelay(
                    status: status,
                    isOutgoing: true,
                    priorOutgoingPendingReplays: 0
                ) == CloudCallAnswerPolicy.quickReplayDelay
            )
        }
    }
}

@MainActor
struct CloudOutgoingDialCoordinatorTests {
    @Test func `Prewarm starts when the call is named and before the dial result`() async throws {
        var events: [String] = []
        let call = try await CloudOutgoingDialCoordinator.run(
            enqueue: {
                events.append("enqueue")
                return "call"
            },
            prewarm: { events.append("prewarm:\($0)") },
            awaitDialing: { events.append("dialing:\($0)") },
            discardPrewarm: { events.append("discard:\($0)") }
        )
        #expect(call == "call")
        #expect(events == ["enqueue", "prewarm:call", "dialing:call"])
    }

    @Test func `Failed or timed out dial releases the prewarm and reports the same error`() async {
        for error in [CloudCommandError.failed("Module could not start dialing"), CloudCommandError.timeout] {
            var events: [String] = []
            let thrown = await #expect(throws: CloudCommandError.self) {
                _ = try await CloudOutgoingDialCoordinator.run(
                    enqueue: { "call" },
                    prewarm: { events.append("prewarm:\($0)") },
                    awaitDialing: { _ in throw error },
                    discardPrewarm: { events.append("discard:\($0)") }
                )
            }
            #expect(thrown?.localizedDescription == error.localizedDescription)
            #expect(events == ["prewarm:call", "discard:call"])
        }
    }

    @Test func `Cancelled dial releases the prewarm`() async throws {
        var events: [String] = []
        var waiting = false
        let task = Task { @MainActor in
            try await CloudOutgoingDialCoordinator.run(
                enqueue: { "call" },
                prewarm: { events.append("prewarm:\($0)") },
                awaitDialing: { _ in
                    waiting = true
                    try await Task.sleep(for: .seconds(30))
                },
                discardPrewarm: { events.append("discard:\($0)") }
            )
        }
        try await waitUntil({ waiting }, "dial wait did not start")
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(events == ["prewarm:call", "discard:call"])
    }

    @Test func `Rejected enqueue prepares nothing`() async {
        var prepared = false
        await #expect(throws: CloudCommandError.self) {
            _ = try await CloudOutgoingDialCoordinator.run(
                enqueue: { () async throws -> String in throw CloudCommandError.invalidResponse },
                prewarm: { _ in prepared = true },
                awaitDialing: { _ in prepared = true },
                discardPrewarm: { _ in prepared = true }
            )
        }
        #expect(!prepared)
    }
}

@MainActor
struct CloudOutgoingPrewarmTests {
    @Test func `Answer for the prewarmed call adopts its socket without releasing it`() async throws {
        let prewarm = CloudOutgoingPrewarm()
        let call = try outgoingCall()
        var connects = 0
        var releases = 0
        let started = prewarm.begin(
            call,
            sessionHasCall: false,
            release: { releases += 1 },
            connect: { connects += 1 },
            expired: { _ in Issue.record("adopted prewarm must not expire") }
        )
        #expect(started)
        // Starting from a closed bridge is the only release.
        #expect(releases == 1)
        #expect(prewarm.callUUID == call.uuid)

        let entry = try #require(prewarm.beginAdoption(for: call))
        #expect(prewarm.isAdopting)
        // While `answer()` waits for the socket, nothing else may release it.
        #expect(!prewarm.discard(call: call) { releases += 1 })
        #expect(await entry.connection.value)
        prewarm.finishAdoption(entry)
        #expect(connects == 1)
        #expect(releases == 1)
        #expect(prewarm.entry == nil)
        #expect(!prewarm.isAdopting)
    }

    @Test func `Failed dial releases the socket and leaves nothing bound to the call`() async throws {
        let prewarm = CloudOutgoingPrewarm()
        let call = try outgoingCall()
        var releases = 0
        prewarm.begin(
            call,
            sessionHasCall: false,
            release: { releases += 1 },
            connect: {},
            expired: { _ in }
        )
        let entry = try #require(prewarm.entry)
        #expect(prewarm.discard(call: call) { releases += 1 })
        #expect(releases == 2)
        #expect(prewarm.entry == nil)
        #expect(prewarm.callUUID == nil)
        #expect(entry.connection.isCancelled)
        // A later answer finds nothing to adopt and connects as it always did.
        #expect(prewarm.beginAdoption(for: call) == nil)
        // The discard hooks can run more than once for one dial.
        #expect(!prewarm.discard(call: call) { releases += 1 })
        #expect(releases == 2)
    }

    @Test func `Superseded dial cannot release a newer prewarm`() async throws {
        let prewarm = CloudOutgoingPrewarm()
        let old = try outgoingCall()
        let new = try outgoingCall()
        var releases = 0
        var connected: [UUID] = []
        prewarm.begin(
            old,
            sessionHasCall: false,
            release: { releases += 1 },
            connect: { connected.append(old.uuid) },
            expired: { _ in }
        )
        prewarm.begin(
            new,
            sessionHasCall: false,
            release: { releases += 1 },
            connect: { connected.append(new.uuid) },
            expired: { _ in }
        )
        #expect(releases == 2)
        #expect(!prewarm.discard(call: old) { releases += 1 })
        #expect(releases == 2)
        #expect(prewarm.callUUID == new.uuid)
        let entry = try #require(prewarm.beginAdoption(for: new))
        #expect(await entry.connection.value)
        // The replaced prewarm never opened a socket after the newer one took the bridge.
        #expect(connected == [new.uuid])
    }

    @Test func `Existing call is never disturbed by a prewarm`() async throws {
        let prewarm = CloudOutgoingPrewarm()
        let started = prewarm.begin(
            try outgoingCall(),
            sessionHasCall: true,
            release: { Issue.record("prewarm released the media of an existing call") },
            connect: { Issue.record("prewarm connected over an existing call") },
            expired: { _ in }
        )
        #expect(!started)
        #expect(prewarm.entry == nil)
        try await Task.sleep(for: .milliseconds(20))
    }

    @Test func `Answer for another call drops the prewarm before it connects`() async throws {
        let prewarm = CloudOutgoingPrewarm()
        let dialing = try outgoingCall()
        let answered = try outgoingCall()
        prewarm.begin(
            dialing,
            sessionHasCall: false,
            release: {},
            connect: { Issue.record("dropped prewarm connected after another call took the bridge") },
            expired: { _ in Issue.record("dropped prewarm expired") }
        )
        let entry = try #require(prewarm.entry)
        #expect(prewarm.beginAdoption(for: answered) == nil)
        #expect(prewarm.entry == nil)
        #expect(!prewarm.isAdopting)
        #expect(await !entry.connection.value)
    }

    @Test func `Same UUID with another generation is not adopted`() throws {
        let prewarm = CloudOutgoingPrewarm()
        let id = UUID()
        prewarm.begin(try outgoingCall(id: id), sessionHasCall: false, release: {}, connect: {}, expired: { _ in })
        #expect(prewarm.beginAdoption(for: try outgoingCall(id: id, generation: 2)) == nil)
        #expect(prewarm.entry == nil)
    }

    @Test func `New generation replaces preparation and a stale cancellation cannot release it`() throws {
        let prewarm = CloudOutgoingPrewarm()
        let id = UUID()
        let first = try outgoingCall(id: id)
        let next = try outgoingCall(id: id, generation: 2)
        prewarm.begin(first, sessionHasCall: false, release: {}, connect: {}, expired: { _ in })
        let replaced = prewarm.begin(next, sessionHasCall: false, release: {}, connect: {}, expired: { _ in })
        #expect(replaced)
        #expect(!prewarm.discard(call: first) { Issue.record("stale generation released the new socket") })
        #expect(prewarm.beginAdoption(for: next) != nil)
        prewarm.reset()
    }

    @Test func `Changed Relay endpoint is not adopted even for the same call generation`() throws {
        let prewarm = CloudOutgoingPrewarm()
        let id = UUID()
        prewarm.begin(try outgoingCall(id: id), sessionHasCall: false, release: {}, connect: {}, expired: { _ in })
        #expect(prewarm.beginAdoption(for: try outgoingCall(id: id, host: "replacement.test")) == nil)
        #expect(prewarm.entry == nil)
    }

    @Test func `Socket that fails to connect is reported for fallback instead of adoption`() async throws {
        let prewarm = CloudOutgoingPrewarm()
        let call = try outgoingCall()
        prewarm.begin(
            call,
            sessionHasCall: false,
            release: {},
            connect: { throw IPhoneCloudCallError.connectionClosed },
            expired: { _ in }
        )
        let entry = try #require(prewarm.beginAdoption(for: call))
        #expect(await !entry.connection.value)
        prewarm.finishAdoption(entry)
        #expect(prewarm.entry == nil)
    }

    @Test func `Prewarm that is neither adopted nor discarded expires`() async throws {
        let prewarm = CloudOutgoingPrewarm(lifetime: .milliseconds(20))
        let call = try outgoingCall()
        var expired: [UUID] = []
        prewarm.begin(
            call,
            sessionHasCall: false,
            release: {},
            connect: {},
            expired: { expired.append($0.uuid) }
        )
        try await waitUntil({ !expired.isEmpty }, "prewarm did not expire")
        #expect(expired == [call.uuid])
    }

    @Test func `Session stop clears the prewarm and its expiry`() async throws {
        let prewarm = CloudOutgoingPrewarm(lifetime: .milliseconds(20))
        prewarm.begin(
            try outgoingCall(),
            sessionHasCall: false,
            release: {},
            connect: {},
            expired: { _ in Issue.record("reset prewarm expired") }
        )
        prewarm.reset()
        #expect(prewarm.entry == nil)
        try await Task.sleep(for: .milliseconds(60))
    }

    @Test func `Only terminal statuses end a prewarm`() {
        for status in ["remote_ended", "ended", "rejected", "ownership_lost"] {
            #expect(CloudOutgoingPrewarmPolicy.endsPrewarm(status: status))
        }
        for status in [
            "agent_ready", "peer_connected", "peer_disconnected", "owner_claimed", "answer_pending",
            "media_prepared", "active", "webrtc_failed",
        ] {
            #expect(!CloudOutgoingPrewarmPolicy.endsPrewarm(status: status))
        }
    }
}

@MainActor
@Suite(.serialized)
struct CloudOutgoingPrewarmSessionTests {
    @Test func `Dial acceptance alone leaves outgoing prewarm without call peer or audio`() async throws {
        let session = IPhoneCloudCallSession.shared
        session.stop()
        defer { session.stop() }
        let call = try outgoingCall(host: "127.0.0.1:9")
        session.prewarmOutgoing(call)
        let acceptance = try #require(session.outgoingDialAcceptance(for: call))
        acceptance.accept()
        #expect(await acceptance.wait())
        session.startAudioWithRetry()
        #expect(session.call == nil && !session.answered && !session.isPrepared)
        #expect(!session.hasActiveCall && session.lifecycleState == .idle)
        #expect(session.audioState == .idle && session.recordingSource == nil)
    }

    /// Uses the loopback discard port: nothing answers, and nothing leaves the test host.
    @Test func `Prewarm leaves the session without a call and discard leaves it idle`() async throws {
        let session = IPhoneCloudCallSession.shared
        session.stop()
        defer { session.stop() }
        let call = try outgoingCall(host: "127.0.0.1:9")

        session.prewarmOutgoing(call)
        func expectNoCall() {
            #expect(session.call == nil)
            #expect(!session.answered)
            #expect(!session.isPrepared)
            #expect(!session.hasActiveCall)
            #expect(!session.isRecovering)
            #expect(session.lifecycleState == .idle)
            #expect(session.audioState == .idle)
            #expect(session.recordingSource == nil)
            #expect(session.mediaHealthSnapshot == CloudMediaHealthSnapshot())
        }
        expectNoCall()
        // Audio activation for another reason must not start anything for a prewarmed call.
        session.startAudioWithRetry()
        try await Task.sleep(for: .milliseconds(100))
        expectNoCall()

        session.discardOutgoingPrewarm(call)
        try await Task.sleep(for: .milliseconds(50))
        expectNoCall()
    }

    @Test func `Ringing prewarm never answers or starts audio and can be discarded`() async throws {
        let session = IPhoneCloudCallSession.shared
        session.stop()
        defer { session.stop() }
        let incoming = try incomingCall(host: "127.0.0.1:9")
        session.prewarmIncoming(incoming)
        session.startAudioWithRetry()
        try await Task.sleep(for: .milliseconds(100))
        #expect(session.call == nil)
        #expect(!session.answered)
        #expect(!session.isPrepared)
        #expect(!session.hasActiveCall)
        #expect(!session.isRecovering)
        #expect(session.lifecycleState == .idle)
        #expect(session.audioState == .idle)
        #expect(session.recordingSource == nil)
        session.discardIncomingPrewarm(incoming)
        #expect(session.call == nil)
        #expect(session.audioState == .idle)
    }

    @Test func `Outgoing entry point still rejects an incoming call`() throws {
        let session = IPhoneCloudCallSession.shared
        session.stop()
        defer { session.stop() }
        session.prewarmOutgoing(try incomingCall(host: "127.0.0.1:9"))
        #expect(session.call == nil)
        #expect(!session.isPrepared)
    }

}

struct VoWLANLocalPathPolicyTests {
    private func interface(_ name: String, ipv4: Bool, loopback: Bool = false) -> LocalNetworkInterface {
        LocalNetworkInterface(name: name, isLoopback: loopback, hasIPv4Address: ipv4)
    }

    private var cellularOnly: [LocalNetworkInterface] {
        [
            interface("lo0", ipv4: true, loopback: true),
            interface("pdp_ip0", ipv4: true),
            interface("pdp_ip1", ipv4: false),
            // Wi-Fi radio on but not joined, and AirDrop interfaces: no IPv4 address.
            interface("en0", ipv4: false),
            interface("awdl0", ipv4: false),
            interface("llw0", ipv4: false),
            interface("utun0", ipv4: false),
        ]
    }

    @Test func `Cellular-only path cannot reach a VoWLAN endpoint`() {
        #expect(!VoWLANLocalPathPolicy.localRouteIsPossible(interfaces: cellularOnly))
        #expect(!VoWLANLocalPathPolicy.localRouteIsPossible(interfaces: []))
    }

    @Test(arguments: ["en0", "en2", "bridge100", "utun4", "ipsec0", "anything-new"])
    func `Wi-Fi, wired, hotspot, VPN and unknown interfaces keep the probe`(_ name: String) {
        #expect(VoWLANLocalPathPolicy.localRouteIsPossible(interfaces: cellularOnly + [interface(name, ipv4: true)]))
    }

    @Test func `Unreadable interface list keeps the probe`() {
        #expect(VoWLANLocalPathPolicy.localRouteIsPossible(interfaces: nil))
    }

    @Test func `Interface snapshot reports loopback and never counts it as a local route`() throws {
        let interfaces = try #require(VoWLANLocalPathPolicy.currentInterfaces())
        let loopback = try #require(interfaces.first { $0.isLoopback })
        #expect(loopback.hasIPv4Address)
        #expect(!VoWLANLocalPathPolicy.localRouteIsPossible(interfaces: [loopback]))
        #expect(Set(interfaces.map(\.name)).count == interfaces.count)
    }
}

@MainActor
struct OutgoingRoutePreparationTests {
    @Test func `Relay is asked early only when the cloud route may be needed`() {
        #expect(
            OutgoingRoutePreparation.overlapsCloudStatus(
                probesVoWLAN: true,
                cloudModeEnabled: true,
                vowlanVerified: false
            )
        )
        // A verified local route is expected to carry the call: no Relay request for it.
        #expect(
            !OutgoingRoutePreparation.overlapsCloudStatus(
                probesVoWLAN: true,
                cloudModeEnabled: true,
                vowlanVerified: true
            )
        )
        // VoWLAN-only mode never queries the Relay; cloud-only mode has no probe to overlap.
        #expect(
            !OutgoingRoutePreparation.overlapsCloudStatus(
                probesVoWLAN: true,
                cloudModeEnabled: false,
                vowlanVerified: false
            )
        )
        #expect(
            !OutgoingRoutePreparation.overlapsCloudStatus(
                probesVoWLAN: false,
                cloudModeEnabled: true,
                vowlanVerified: false
            )
        )
    }

    @Test func `Status check starts while the VoWLAN probe is still running`() async throws {
        var statusStarted = false
        var probeFinished: CheckedContinuation<Void, Never>?
        let preparation = Task { @MainActor in
            await OutgoingRoutePreparation.run(
                overlapsCloudStatus: true,
                readyVoWLAN: { () async -> String? in
                    await withCheckedContinuation { probeFinished = $0 }
                    return nil
                },
                fetchCloudStatus: {
                    statusStarted = true
                    return "online"
                }
            )
        }
        try await waitUntil({ probeFinished != nil && statusStarted }, "status did not overlap the probe")
        probeFinished?.resume()
        let result = await preparation.value
        #expect(result.vowlanRoute == nil)
        #expect(try result.cloudStatus?.get() == "online")
    }

    @Test func `Ready VoWLAN is chosen and the status request is cancelled unread`() async throws {
        var statusCancelled = false
        var statusStarted = false
        var probeFinished: CheckedContinuation<Void, Never>?
        let preparation = Task { @MainActor in
            await OutgoingRoutePreparation.run(
                overlapsCloudStatus: true,
                readyVoWLAN: { () async -> String? in
                    await withCheckedContinuation { probeFinished = $0 }
                    return "vowlan"
                },
                fetchCloudStatus: { () async throws -> String in
                    statusStarted = true
                    do {
                        try await Task.sleep(for: .seconds(30))
                    } catch {
                        statusCancelled = true
                        throw error
                    }
                    return "online"
                }
            )
        }
        try await waitUntil({ probeFinished != nil && statusStarted }, "status did not overlap the probe")
        probeFinished?.resume()
        let result = await preparation.value
        #expect(result.vowlanRoute == "vowlan")
        #expect(result.cloudStatus == nil)
        #expect(statusCancelled)
    }

    @Test func `Failed overlapped status is reported once instead of being retried`() async {
        var requests = 0
        let result = await OutgoingRoutePreparation.run(
            overlapsCloudStatus: true,
            readyVoWLAN: { () async -> String? in nil },
            fetchCloudStatus: { () async throws -> String in
                requests += 1
                throw CloudAgentStatusError.invalidResponse
            }
        )
        #expect(requests == 1)
        #expect(throws: CloudAgentStatusError.self) { _ = try result.cloudStatus?.get() }
    }

    @Test func `Without overlap the Relay is not asked before the route is known`() async {
        let result = await OutgoingRoutePreparation.run(
            overlapsCloudStatus: false,
            readyVoWLAN: { () async -> String? in "vowlan" },
            fetchCloudStatus: { () async throws -> String in
                Issue.record("local call queried the Relay")
                return "online"
            }
        )
        #expect(result.vowlanRoute == "vowlan")
        #expect(result.cloudStatus == nil)
    }
}

@MainActor
struct OutgoingCallSetupTimelineTests {
    @Test func `Acceptance source and captured socket send time distinguish startup gates`() {
        var time: TimeInterval = 10
        var lines: [String] = []
        let timeline = OutgoingCallSetupTimeline(now: { time }, sink: { lines.append($0) })
        time = 10.4
        timeline.mark(.dialAcceptance, .acceptanceSignaling)
        time = 10.5
        timeline.mark(.signalingAdoptionStarted)
        time = 12
        timeline.mark(.ownerJoinSent, at: 10.6)
        #expect(
            lines == [
                "dial=\(timeline.dial) phase=dial_acceptance elapsed_ms=400 source=signaling",
                "dial=\(timeline.dial) phase=signaling_adoption_started elapsed_ms=500",
                "dial=\(timeline.dial) phase=owner_join_sent elapsed_ms=600",
            ]
        )
        #expect(OutgoingCallSetupDetail.acceptanceHTTP.rawValue == "source=http")
    }

    @Test func `Lines carry only a dial counter, phase, elapsed milliseconds and a fixed detail`() {
        var time: TimeInterval = 100
        var lines: [String] = []
        let timeline = OutgoingCallSetupTimeline(now: { time }, sink: { lines.append($0) })
        timeline.mark(.dialStarted)
        time = 100.0424
        timeline.mark(.vowlanDecision, .vowlanNotReady)
        time = 100.9
        timeline.mark(.signalingConnected, .prewarmed)
        #expect(
            lines == [
                "dial=\(timeline.dial) phase=dial_started elapsed_ms=0",
                "dial=\(timeline.dial) phase=vowlan_decision elapsed_ms=42 vowlan=not_ready",
                "dial=\(timeline.dial) phase=signaling_connected elapsed_ms=900 prewarmed=true",
            ]
        )
    }

    @Test func `Each dial has its own counter and start time`() {
        var time: TimeInterval = 5
        var lines: [String] = []
        let first = OutgoingCallSetupTimeline(now: { time }, sink: { lines.append($0) })
        time = 8
        let second = OutgoingCallSetupTimeline(now: { time }, sink: { lines.append($0) })
        #expect(second.dial > first.dial)
        time = 9
        second.mark(.enqueueAccepted)
        #expect(lines == ["dial=\(second.dial) phase=enqueue_accepted elapsed_ms=1000"])
    }

    @Test func `Rebuilds do not rewrite the timeline and answer_pending may repeat`() {
        var lines: [String] = []
        let timeline = OutgoingCallSetupTimeline(now: { 1 }, sink: { lines.append($0) })
        for _ in 0..<2 {
            timeline.mark(.answerPending)
            timeline.mark(.nativeConnected)
            timeline.mark(.audioReady)
        }
        #expect(lines.filter { $0.contains("phase=answer_pending") }.count == 2)
        #expect(lines.filter { $0.contains("phase=native_connected") }.count == 1)
        #expect(lines.filter { $0.contains("phase=audio_ready") }.count == 1)
    }

    @Test func `Session phases are accepted only for the bound call`() {
        let timeline = OutgoingCallSetupTimeline(now: { 1 }, sink: { _ in })
        let call = UUID()
        #expect(!timeline.covers(call))
        timeline.bind(to: call)
        #expect(timeline.covers(call))
        #expect(!timeline.covers(UUID()))
    }

    @Test func `Every phase and detail is a fixed token`() {
        let tokens = OutgoingCallSetupPhase.allCases.map(\.rawValue)
        #expect(Set(tokens).count == tokens.count)
        #expect(tokens.allSatisfy { $0.allSatisfy { $0.isLowercase || $0 == "_" } })
        #expect(OutgoingCallSetupPhase.allCases.filter(\.repeats) == [.answerPending])
    }
}

private final class RelayStubProtocol: URLProtocol, @unchecked Sendable {
    enum Behavior: Sendable {
        case respond(status: Int, body: String)
        case fail(URLError.Code)
        case hang
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var behaviors: [Behavior] = []
    nonisolated(unsafe) private static var requests: [URLRequest] = []

    static func script(_ scripted: [Behavior]) {
        lock.withLock {
            behaviors = scripted
            requests = []
        }
    }

    static var recordedRequests: [URLRequest] { lock.withLock { requests } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let behavior = Self.lock.withLock { () -> Behavior in
            Self.requests.append(request)
            return Self.behaviors.isEmpty ? .hang : Self.behaviors.removeFirst()
        }
        switch behavior {
        case let .respond(status, body):
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: "HTTP/2",
                headerFields: nil
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        case let .fail(code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        case .hang:
            break
        }
    }

    override func stopLoading() {}
}

@Suite(.serialized)
struct RelayHTTPClientTests {
    private static func stubbedSession() -> URLSession {
        let configuration = RelayHTTPClient.makeConfiguration()
        configuration.protocolClasses = [RelayStubProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func client() -> RelayHTTPClient {
        RelayHTTPClient(makeSession: { Self.stubbedSession() })
    }

    private var request: URLRequest {
        var request = URLRequest(url: URL(string: "https://relay.test/v1/commands/result")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        return request
    }

    @Test func `Shared session keeps no cookies, cache or credentials between requests`() {
        let configuration = RelayHTTPClient.makeConfiguration()
        #expect(configuration.urlCache == nil)
        #expect(configuration.httpCookieStorage == nil)
        #expect(!configuration.httpShouldSetCookies)
        #expect(configuration.httpCookieAcceptPolicy == .never)
        #expect(configuration.urlCredentialStorage == nil)
        #expect(configuration.requestCachePolicy == .reloadIgnoringLocalCacheData)
    }

    @Test func `Requests that follow each other closely share a session and a pause starts a new one`() async throws {
        let time = OSAllocatedUnfairLock(initialState: TimeInterval(1_000))
        let sessions = OSAllocatedUnfairLock(initialState: 0)
        let client = RelayHTTPClient(
            makeSession: {
                sessions.withLock { $0 += 1 }
                return Self.stubbedSession()
            },
            now: { time.withLock { $0 } }
        )
        RelayStubProtocol.script((0..<4).map { _ in .respond(status: 200, body: "ok") })
        // Status, enqueue and a result poll of one dial.
        for _ in 0..<3 {
            _ = try await client.data(for: request, resourceTimeout: 12)
            time.withLock { $0 += 0.5 }
        }
        #expect(sessions.withLock { $0 } == 1)
        time.withLock { $0 += RelayHTTPReusePolicy.reuseWindow + 1 }
        _ = try await client.data(for: request, resourceTimeout: 12)
        #expect(sessions.withLock { $0 } == 2)
        #expect(RelayStubProtocol.recordedRequests.count == 4)
    }

    @Test func `Idle session is replaced only when nothing is in flight`() {
        let window = RelayHTTPReusePolicy.reuseWindow
        #expect(RelayHTTPReusePolicy.reusesSession(idleFor: 0, inFlight: 0))
        #expect(RelayHTTPReusePolicy.reusesSession(idleFor: window, inFlight: 0))
        #expect(!RelayHTTPReusePolicy.reusesSession(idleFor: window + 0.1, inFlight: 0))
        #expect(RelayHTTPReusePolicy.reusesSession(idleFor: window * 10, inFlight: 1))
        // The polls of one command always stay on one connection.
        #expect(Duration.seconds(window) > CloudCommandPollSchedule.steadyInterval * 10)
    }

    @Test func `Requests on one client return each response unchanged`() async throws {
        RelayStubProtocol.script([.respond(status: 202, body: "first"), .respond(status: 500, body: "second")])
        let client = client()
        let (firstData, firstResponse) = try await client.data(for: request, resourceTimeout: 12)
        let (secondData, secondResponse) = try await client.data(for: request, resourceTimeout: 12)
        #expect(String(decoding: firstData, as: UTF8.self) == "first")
        #expect((firstResponse as? HTTPURLResponse)?.statusCode == 202)
        #expect(String(decoding: secondData, as: UTF8.self) == "second")
        #expect((secondResponse as? HTTPURLResponse)?.statusCode == 500)
        #expect(RelayStubProtocol.recordedRequests.count == 2)
    }

    @Test func `Whole-request deadline fails with the timeout a per-request session reported`() async {
        RelayStubProtocol.script([.hang])
        let error = await #expect(throws: URLError.self) {
            _ = try await client().data(for: request, resourceTimeout: 0.05)
        }
        #expect(error?.code == .timedOut)
    }

    @Test func `Connection closed under a reused session is retried once`() async throws {
        RelayStubProtocol.script([.fail(.networkConnectionLost), .respond(status: 200, body: "ok")])
        let (data, _) = try await client().data(for: request, resourceTimeout: 12)
        #expect(String(decoding: data, as: UTF8.self) == "ok")
        #expect(RelayStubProtocol.recordedRequests.count == 2)

        RelayStubProtocol.script([
            .fail(.networkConnectionLost), .fail(.networkConnectionLost), .respond(status: 200, body: "late"),
        ])
        let error = await #expect(throws: URLError.self) {
            _ = try await client().data(for: request, resourceTimeout: 12)
        }
        #expect(error?.code == .networkConnectionLost)
        #expect(RelayStubProtocol.recordedRequests.count == 2)
    }

    @Test func `Other transport errors are reported unchanged without a retry`() async {
        #expect(RelayHTTPReusePolicy.retriesOnNewConnection(after: .networkConnectionLost))
        for code in [URLError.Code.timedOut, .notConnectedToInternet, .cannotConnectToHost, .cancelled] {
            #expect(!RelayHTTPReusePolicy.retriesOnNewConnection(after: code))
            RelayStubProtocol.script([.fail(code), .respond(status: 200, body: "unexpected")])
            let error = await #expect(throws: URLError.self) {
                _ = try await client().data(for: request, resourceTimeout: 12)
            }
            #expect(error?.code == code)
            #expect(RelayStubProtocol.recordedRequests.count == 1)
        }
    }

    @Test func `Cancelled caller cancels the request instead of timing out`() async throws {
        RelayStubProtocol.script([.hang])
        let client = client()
        let request = request
        let task = Task { try await client.data(for: request, resourceTimeout: 30) }
        while RelayStubProtocol.recordedRequests.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        task.cancel()
        let error = await #expect(throws: URLError.self) { _ = try await task.value }
        #expect(error?.code == .cancelled)
    }
}

struct CloudPreDialGateTests {
    private func status(_ status: String, call: IncomingVoIPCall, session: UUID?) throws -> CloudCallControlMessage {
        var fields: [String: Any] = [
            "status": status, "call_id": call.callID,
            "call_uuid": call.uuid.uuidString, "generation": call.generation,
        ]
        if let session { fields["session_id"] = session.uuidString }
        let data = try JSONSerialization.data(withJSONObject: fields)
        let message = try CloudCallControlMessage.decode(String(decoding: data, as: UTF8.self))
        return try #require(message)
    }

    @Test(arguments: ["pre_dial_timeout", "preparation_timeout", "agent_preparation_failed", "peer_disconnected"])
    func `Relay failure preserves only known pre-dial reasons`(_ reason: String) throws {
        let call = try outgoingCall()
        let data = try JSONSerialization.data(withJSONObject: [
            "status": "pre_dial_aborted", "reason": reason, "call_id": call.callID,
            "call_uuid": call.uuid.uuidString, "generation": call.generation,
        ])
        let decoded = try #require(try CloudCallControlMessage.decode(String(decoding: data, as: UTF8.self)))
        var gate = CloudPreDialGate()
        gate.receive(decoded, call: call)
        #expect(gate.failure == "relay_pre_dial_aborted:\(reason)")
        #expect(decoded.traceFields["reason"] == reason)
        #expect(!gate.canCommit)
    }

    @Test(arguments: ["", "unrecognized_code", "Bearer private-test-value", "pre_dial_timeout\nprivate-test-value"])
    func `Arbitrary relay reasons never reach pre-dial diagnostics`(_ reason: String) throws {
        let call = try outgoingCall()
        let data = try JSONSerialization.data(withJSONObject: [
            "status": "pre_dial_aborted", "reason": reason, "call_id": call.callID,
            "call_uuid": call.uuid.uuidString, "generation": call.generation,
        ])
        let decoded = try #require(try CloudCallControlMessage.decode(String(decoding: data, as: UTF8.self)))
        var gate = CloudPreDialGate()
        gate.receive(decoded, call: call)
        #expect(gate.failure == "relay_pre_dial_aborted")
        #expect(decoded.reason == nil)
        #expect(decoded.traceFields["reason"] == nil)
    }

    @Test func `Both native proofs precede exactly one commit`() throws {
        let call = try outgoingCall()
        let session = UUID()
        var gate = CloudPreDialGate()
        gate.begin(session)
        gate.receive(try status("pre_dial_ready", call: call, session: session), call: call)
        #expect(!gate.canCommit)
        gate.nativeConnected(UUID())
        #expect(!gate.canCommit)
        gate.nativeConnected(session)
        #expect(gate.canCommit)
        gate.commit()
        #expect(gate.committed)
        #expect(!gate.canCommit)
        gate.receive(try status("pre_dial_ready", call: call, session: session), call: call)
        #expect(!gate.canCommit)
    }

    @Test func `Carrier readiness and foreign or missing transport identity never authorize dialing`() throws {
        let call = try outgoingCall()
        let session = UUID()
        var gate = CloudPreDialGate()
        gate.begin(session)
        gate.nativeConnected(session)
        for message in [
            try status("webrtc_ready", call: call, session: session),
            try status("pre_dial_ready", call: call, session: UUID()),
            try status("pre_dial_ready", call: call, session: nil),
            try status("pre_dial_ready", call: outgoingCall(), session: session),
        ] {
            gate.receive(message, call: call)
            #expect(!gate.canCommit)
        }
    }

    @Test func `Timeout cancellation socket replacement and failure are terminal`() throws {
        let call = try outgoingCall()
        let session = UUID()
        for reason in ["transport_timeout_20s", "cancelled", "signaling_lost", "replaced", "native_transport_failed"] {
            var gate = CloudPreDialGate()
            gate.begin(session)
            gate.fail(reason)
            gate.nativeConnected(session)
            gate.receive(try status("pre_dial_ready", call: call, session: session), call: call)
            gate.commit()
            #expect(!gate.canCommit)
            #expect(!gate.committed)
            #expect(gate.failure == reason)
        }
    }
}

struct CloudPreDialPeerAdmissionTests {
    @Test func `Only exact relay peer admission unlocks initial offer`() throws {
        let call = try outgoingCall()
        var gate = CloudPreDialGate()
        for status in ["peer_connected", "agent_ready", "dial_reserved"] {
            let data = try JSONSerialization.data(withJSONObject: [
                "status": status, "call_id": call.callID,
                "call_uuid": call.uuid.uuidString, "generation": call.generation,
            ])
            let decoded = try CloudCallControlMessage.decode(String(decoding: data, as: UTF8.self))
            gate.receive(try #require(decoded), call: call)
            #expect(!gate.peerAvailable)
        }
        let data = try JSONSerialization.data(withJSONObject: [
            "status": "pre_dial_peer_ready", "call_id": call.callID,
            "call_uuid": call.uuid.uuidString, "generation": call.generation,
        ])
        let decoded = try CloudCallControlMessage.decode(String(decoding: data, as: UTF8.self))
        gate.receive(try #require(decoded), call: call)
        #expect(gate.peerAvailable)
        #expect(!gate.canCommit)
    }
}
