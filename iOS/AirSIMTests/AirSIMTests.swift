import CryptoKit
import CoreBluetooth
import AVFoundation
import Testing
import Foundation
@testable import AirSIM

struct CloudMediaCredentialTests {
    @Test func `Incoming WebRTC credential stays out of WebSocket and ICE URLs`() throws {
        let callUUID = UUID()
        let secret = String(repeating: "s", count: 32)
        let call = try IncomingVoIPCall(userInfo: [
            "event": "incoming_call", "call_id": "security-test",
            "call_uuid": callUUID.uuidString,
            "media_url": "wss://relay.example/v1/calls/\(callUUID.uuidString)/connect",
            "call_secret": secret, "media_transport": "webrtc",
        ])
        let mediaURL = try #require(call.authenticatedMediaURL)
        #expect(call.mediaSecret == secret)
        #expect(URLComponents(url: mediaURL, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "role" })?.value == "iphone")
        #expect(!mediaURL.absoluteString.contains(secret))
        #expect(URLComponents(url: mediaURL, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "token" }) == nil)

        let iceRequest = try CloudICEConfiguration.request(for: call)
        #expect(iceRequest.value(forHTTPHeaderField: "Authorization") == "Bearer \(secret)")
        #expect(!(iceRequest.url?.absoluteString.contains(secret) ?? true))
    }
}

private actor OutgoingCallServiceProbe: OutgoingCallServicing {
    private let dialError: Error?
    private var actions: [String] = []

    init(dialError: Error? = nil) {
        self.dialError = dialError
    }

    func warmAudioHost() async throws { actions.append("warm") }
    func dial(number: String) async throws {
        actions.append("dial:\(number)")
        if let dialError { throw dialError }
    }

    func recordedActions() -> [String] { actions }
}

private struct LegacyAgentSMSProbe: LegacyAgentPolling {
    let pending: Int?
    let smsStatusAvailable: Bool

    func callStatus() async throws -> CallStatus {
        CallStatus(active: nil, history: [], polling: true, eventDriven: false,
                   pollIntervalSeconds: 1, lastPollError: "", revision: nil)
    }

    func smsStatus() async throws -> SMSStatus {
        if !smsStatusAvailable { throw URLError(.badServerResponse) }
        return SMSStatus(autoCleanupME: true, count: pending, lastPollError: nil)
    }
}

private struct AgentSMSInboxProbe: AgentSMSInboxServicing {
    let name: String
    let inbox: [SMSMessage]

    func messages() async throws -> [SMSMessage] { inbox }
}

struct CloudCallHistoryTests {
    private func record(_ id: String, start: TimeInterval, updated: TimeInterval) -> CallRecord {
        CallRecord(
            id: id, index: 0, direction: "outgoing", state: "ended", number: "test",
            startedAt: Date(timeIntervalSince1970: start),
            updatedAt: Date(timeIntervalSince1970: updated),
            endedAt: Date(timeIntervalSince1970: updated), missed: false
        )
    }

    @Test func `Cloud result decodes native history dates`() throws {
        let json = #"{"command_id":"test","status":"completed","result":{"history":[{"id":"calllog-agent-42","index":42,"direction":"incoming","state":"ended","number":null,"started_at":"2026-10-17T01:00:00.000Z","updated_at":"2026-10-17T01:01:00Z","ended_at":"2026-10-17T01:01:00Z","missed":false}]}}"#
        let result = try AirSIMAPI.makeDecoder().decode(
            CloudCommandResultResponse.self, from: Data(json.utf8)
        )
        let history = try #require(result.result?.history)
        #expect(history.count == 1)
        #expect(history[0].id == "calllog-agent-42")
        #expect(history[0].endedAt?.timeIntervalSince(history[0].startedAt) == 60)
        #expect(!history[0].missed)
    }

    @Test func `Empty remote preserves cache and newer record wins`() {
        let old = record("one", start: 10, updated: 20)
        let new = record("one", start: 10, updated: 30)
        #expect(CallHistoryPolicy.merged(
            local: [new], remote: [], deletedIDs: [], limit: 100
        ) == [new])
        #expect(CallHistoryPolicy.merged(
            local: [new], remote: [old], deletedIDs: [], limit: 100
        ) == [new])
    }

    @Test func `Merge uses stable IDs sorts by call time and bounds rows`() {
        let first = record("first", start: 10, updated: 100)
        let second = record("second", start: 20, updated: 30)
        #expect(CallHistoryPolicy.merged(
            local: [first], remote: [first, second], deletedIDs: [], limit: 1
        ).map(\.id) == ["second"])
    }

    @Test func `Deleted rows stay hidden after relaunch and remote refresh`() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LocalHistoryStore(directoryURL: directory)
        let deleted = record("deleted", start: 10, updated: 20)
        let kept = record("kept", start: 30, updated: 40)
        #expect(store.saveCallHistory([deleted, kept]))
        #expect(store.saveDeletedCallIDs(["deleted"]))
        let reopened = LocalHistoryStore(directoryURL: directory)
        #expect(CallHistoryPolicy.merged(
            local: reopened.loadCallHistory(), remote: [deleted],
            deletedIDs: reopened.loadDeletedCallIDs(), limit: 100
        ).map(\.id) == ["kept"])
    }
}

struct CloudCallControlReceiptTests {
    private func receipt(
        status: String = "completed",
        result: [String: Bool],
        rescueCommandID: String? = nil
    ) throws -> CloudCallControlReceipt {
        var payload: [String: Any] = [
            "command_id": "test-command",
            "status": status,
            "result": result,
        ]
        if let rescueCommandID { payload["rescue_command_id"] = rescueCommandID }
        return try JSONDecoder().decode(
            CloudCallControlReceipt.self,
            from: JSONSerialization.data(withJSONObject: payload)
        )
    }

    @Test func `Android Telecom confirmed end is accepted`() throws {
        let value = try receipt(result: ["ended": true, "android_confirmed": true])
        #expect(value.cellularEndConfirmed)
        #expect(value.confirmationPhase == "android_confirmed")
    }

    @Test func `Android confirmation requires completed end`() throws {
        for result in [
            ["ended": true],
            ["android_confirmed": true],
            ["ended": false, "android_confirmed": true],
            ["ended": true, "android_confirmed": false],
        ] {
            #expect(try !receipt(result: result).cellularEndConfirmed)
        }
        for status in ["delivered", "failed", "expired"] {
            #expect(try !receipt(
                status: status,
                result: ["ended": true, "android_confirmed": true]
            ).cellularEndConfirmed)
        }
    }

    @Test func `Legacy modem confirmation remains supported`() throws {
        let value = try receipt(result: ["modem_confirmed": true])
        #expect(value.cellularEndConfirmed)
        #expect(value.confirmationPhase == "modem_confirmed")
        #expect(!(try receipt(status: "failed", result: ["modem_confirmed": true]).cellularEndConfirmed))
    }

    @Test func `Rescue confirmation retains its source`() throws {
        #expect(try receipt(
            result: ["ended": true, "android_confirmed": true], rescueCommandID: "rescue"
        ).confirmationPhase == "rescue_android_confirmed")
        #expect(try receipt(
            result: ["modem_confirmed": true], rescueCommandID: "rescue"
        ).confirmationPhase == "rescue_modem_confirmed")
    }
}

struct AirSIMTests {

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

    @Test func `Old ended history cannot finish a new system call`() {
        #expect(CallKitSynchronizationPolicy.mayFinishEndedHistory(currentBackendID: "a", endedID: "a"))
        #expect(!CallKitSynchronizationPolicy.mayFinishEndedHistory(currentBackendID: "b", endedID: "a"))
        #expect(!CallKitSynchronizationPolicy.mayFinishEndedHistory(currentBackendID: nil, endedID: "a"))
    }

    @Test func `Retired agent call cannot bypass end intent with synthesized UUID`() throws {
        var store = CallLifecycleStore()
        let original = UUID()
        let now = Date()
        func event(_ id: String, _ uuid: UUID, _ state: CallLifecycleState) -> CallLifecycleEvent {
            .init(callID: id, callUUID: uuid, generation: 1, state: state,
                  source: .agent, timestamp: now, traceID: nil, failure: nil)
        }
        // The store is mutated by apply(), so each result is captured before asserting.
        var applied = store.apply(event("a", original, .active))
        #expect(applied)
        applied = store.apply(event("a", original, .ended))
        #expect(applied)
        applied = store.apply(event("b", UUID(), .ringing))
        #expect(applied)
        let b = try #require(store.snapshot.callUUID)
        applied = store.apply(event("b", b, .ended))
        #expect(applied)
        applied = store.apply(event("a", UUID(), .ringing))
        #expect(!applied)
        applied = store.apply(event("c", UUID(), .ringing))
        #expect(applied)
    }

    @Test @MainActor
    func `Cancelled cloud dial discards late call instead of adopting it`() async throws {
        var current = true
        try await confirmation("dial submitted") { started in
            var completion: CheckedContinuation<String, Error>?
            var discarded: [String] = []
            let task = Task { @MainActor in
                do {
                    _ = try await OutgoingCallRouteCoordinator.start(
                        number: "test", vowlanService: nil, cloudModeEnabled: true,
                        isCurrent: { current }, discardCloud: { discarded.append($0) }
                    ) {
                        try await withCheckedThrowingContinuation { continuation in
                            completion = continuation; started()
                        }
                    }
                    Issue.record("cancelled outgoing call must not be adopted")
                } catch is CancellationError { }
                catch { Issue.record("unexpected error: \(error)") }
            }
            try await waitUntil({ completion != nil }, "dial did not submit")
            current = false
            completion?.resume(returning: "late-call")
            await task.value
            #expect(discarded == ["late-call"])
        }
    }

    @Test(arguments: [true, false]) @MainActor
    func `Late cloud reconnect does not complete or fail a newer call`(_ succeeds: Bool) async throws {
        try await confirmation("connect suspended") { started in
            var current = UUID()
            let original = current
            var completion: CheckedContinuation<Void, Error>?
            var connected = 0
            var failed = 0
            let recovery = Task { @MainActor in
                await CloudCallRecoveryCoordinator.run(
                    delays: [0], isCurrent: { current == original },
                    connect: { _ in
                        try await withCheckedThrowingContinuation { continuation in
                            completion = continuation; started()
                        }
                    }, connected: { connected += 1 }, failed: { _ in failed += 1 }
                )
            }
            try await waitUntil({ completion != nil }, "connect did not suspend")
            current = UUID() // Hangup, followed by a new call, while connect is pending.
            if succeeds { completion?.resume() }
            else { completion?.resume(throwing: URLError(.networkConnectionLost)) }
            await recovery.value
            #expect(connected == 0)
            #expect(failed == 0)
        }
    }

    @Test func `Cloud control cannot acknowledge another call or generation`() throws {
        let uuid = UUID()
        let decoded = try CloudCallControlMessage.decode("""
            {"status":"active","call_id":"a","call_uuid":"\(uuid.uuidString)","generation":2}
            """)
        let control = try #require(decoded)
        #expect(control.matches(callID: "a", uuid: uuid, generation: 2))
        #expect(!control.matches(callID: "b", uuid: uuid, generation: 2))
        #expect(!control.matches(callID: "a", uuid: UUID(), generation: 2))
        #expect(!control.matches(callID: "a", uuid: uuid, generation: 3))
    }

    @Test func `Ending call cannot reopen in app presentation`() {
        let call = CallRecord(id: "ending-call", index: 0, direction: "outgoing",
                              state: "ending", number: nil, startedAt: Date(), updatedAt: Date(),
                              endedAt: nil, missed: false)
        #expect(CallPresentationPolicy.inAppCall(surface: .app, local: call, remote: nil) == nil)
    }

    @Test func `Local end intent rejects same call with higher generation`() {
        var store = CallLifecycleStore()
        let uuid = UUID()
        let now = Date()
        func event(_ state: CallLifecycleState, _ generation: UInt64) -> CallLifecycleEvent {
            .init(callID: "cloud-call", callUUID: uuid, generation: generation, state: state,
                  source: state == .ending ? .app : .relay, timestamp: now, traceID: nil, failure: nil)
        }
        // The store is mutated by apply(), so each result is captured before asserting.
        var applied = store.apply(event(.active, 1))
        #expect(applied)
        applied = store.apply(event(.ending, 1))
        #expect(applied)
        applied = store.apply(event(.active, 2))
        #expect(!applied, "reconnect must not revoke the user's end intent")
        #expect(store.snapshot.state == .ending)
    }

    @Test func `Retired cloud call cannot return after a newer call ends`() {
        var store = CallLifecycleStore()
        let first = UUID(), next = UUID(), now = Date()
        func event(_ id: String, _ uuid: UUID, _ state: CallLifecycleState) -> CallLifecycleEvent {
            .init(callID: id, callUUID: uuid, generation: 1, state: state,
                  source: .relay, timestamp: now, traceID: nil, failure: nil)
        }
        // The store is mutated by apply(), so each result is captured before asserting.
        var applied = store.apply(event("first", first, .active))
        #expect(applied)
        applied = store.apply(event("first", first, .ending))
        #expect(applied)
        applied = store.apply(event("next", next, .ringing))
        #expect(applied)
        applied = store.apply(event("next", next, .ended))
        #expect(applied)
        applied = store.apply(event("first", first, .connecting))
        #expect(!applied)
        #expect(store.snapshot.callID == "next")
    }


    @Test @MainActor
    func `Reject is not silently dropped while another action is busy`() async {
        let model = AppModel()
        model.isBusy = true
        model.errorMessage = "reject was not attempted"

        await model.reject()

        #expect(model.errorMessage != "reject was not attempted")
    }

    @Test @MainActor
    func `Hangup is not silently dropped while another action is busy`() async {
        let model = AppModel()
        model.isBusy = true
        model.errorMessage = "hangup was not attempted"

        await model.hangup()

        #expect(model.errorMessage != "hangup was not attempted")
    }

    @Test func `Local call control body carries call identity`() throws {
        let targeted = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(LocalCallControlBody(callID: "visible-call-7"))
        ) as? [String: String]
        #expect(targeted == ["call_id": "visible-call-7"])
        let legacy = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(LocalCallControlBody(callID: nil))
        ) as? [String: String]
        #expect(legacy == [String: String]())
    }

    @Test func `Unanswered push reject routes to relay even without prepared media`() {
        #expect(CallKitEndDecision.route(
            transport: nil, cloudSessionPrepared: false,
            hasIncomingPush: true, systemCallAnswered: false,
            activeIncomingRinging: false
        ) == .cloudReject)
        #expect(CallKitEndDecision.route(
            transport: .cloud, cloudSessionPrepared: false,
            hasIncomingPush: true, systemCallAnswered: false,
            activeIncomingRinging: false
        ) == .cloudReject)
        #expect(CallKitEndDecision.route(
            transport: .vowlan, cloudSessionPrepared: false,
            hasIncomingPush: true, systemCallAnswered: false,
            activeIncomingRinging: true
        ) == .localReject)
        #expect(CallKitEndDecision.route(
            transport: nil, cloudSessionPrepared: false,
            hasIncomingPush: false, systemCallAnswered: false,
            activeIncomingRinging: true
        ) == .localReject)
    }

    @Test func `Late end callback does not reach backend after call already ended`() {
        #expect(!CallKitEndActionPolicy.shouldForwardToBackend(
            systemCallWasCurrent: false
        ))
        #expect(CallKitEndActionPolicy.shouldForwardToBackend(
            systemCallWasCurrent: true
        ))
    }

    @Test func `Local reject keeps observed agent during reconnect`() {
        #expect(LocalCallControlTarget.select(
            locked: Optional<String>.none,
            observed: (callID: "call-on-samsung", service: "Samsung"),
            fallback: "Xiaomi",
            targetCallID: "call-on-samsung"
        ) == "Samsung")
        #expect(LocalCallControlTarget.select(
            locked: Optional<String>.none,
            observed: (callID: "call-on-samsung", service: "Samsung"),
            fallback: "Xiaomi",
            targetCallID: nil
        ) == nil)
        #expect(LocalCallControlTarget.select(
            locked: Optional<String>.none,
            observed: (callID: "old-call", service: "Samsung"),
            fallback: "Xiaomi",
            targetCallID: "new-call"
        ) == nil)
    }

    @Test @MainActor
    func `Initial permissions wait for microphone decision before other prompts`() async {
        let coordinator = InitialPermissionCoordinator()
        var microphoneUndetermined = true
        var events: [String] = []

        await coordinator.requestIfNeeded(
            isForeground: { true },
            microphoneIsUndetermined: { microphoneUndetermined },
            requestMicrophone: {
                events.append("microphone")
                await Task.yield()
                microphoneUndetermined = false
            },
            startDiscovery: { events.append("discovery") },
            requestNotifications: { events.append("notifications") }
        )

        #expect(events == ["microphone", "discovery", "notifications"])
        #expect(coordinator.didStartDiscovery)
    }

    @Test @MainActor
    func `Initial permissions retry when microphone prompt was deferred`() async {
        let coordinator = InitialPermissionCoordinator()
        var microphoneUndetermined = true
        var requestCount = 0
        var notifications = 0
        var discovery = 0

        func request() async {
            await coordinator.requestIfNeeded(
                isForeground: { true },
                microphoneIsUndetermined: { microphoneUndetermined },
                requestMicrophone: { requestCount += 1 },
                startDiscovery: { discovery += 1 },
                requestNotifications: { notifications += 1 }
            )
        }

        await request()
        #expect(requestCount == 1)
        #expect(discovery == 0)
        #expect(notifications == 0)

        microphoneUndetermined = false
        await request()
        await request()
        #expect(requestCount == 1)
        #expect(discovery == 1)
        #expect(notifications == 1)
    }

    @Test func `Relay retry does not repeat successful agent registration`() {
        #expect(!PushRegistrationAttemptPolicy.shouldRegisterAgent(
            fingerprint: "same-token",
            route: "samsung",
            lastFingerprint: "same-token",
            lastRoute: "samsung"
        ))
    }

    @Test func `New agent route requires registration even with same token`() {
        #expect(PushRegistrationAttemptPolicy.shouldRegisterAgent(
            fingerprint: "same-token",
            route: "new-samsung",
            lastFingerprint: "same-token",
            lastRoute: "old-samsung"
        ))
    }

    @Test func `Relay quota pauses only relay registration until retry time`() {
        let now = Date(timeIntervalSince1970: 43_200)
        let retryAfter = Date(timeIntervalSince1970: 43_500)
        #expect(!PushRegistrationRetryPolicy.shouldAttemptRelay(now: now, retryAfter: retryAfter))
        #expect(PushRegistrationRetryPolicy.shouldAttemptRelay(now: retryAfter, retryAfter: retryAfter))
        #expect(PushRegistrationRetryPolicy.quotaRetryDate(now: now) == retryAfter)
        #expect(
            PushRegistrationRetryPolicy.quotaRetryDate(now: Date(timeIntervalSince1970: 86_280))
                == Date(timeIntervalSince1970: 86_410)
        )
    }

    @Test func `Cloud status refresh does not repeat just because time elapsed`() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(!AppRefreshPolicy.shouldQueryCloudStatus(
            cloudModeEnabled: false, lastAttempt: .distantPast, appIsForeground: true))
        #expect(AppRefreshPolicy.shouldQueryCloudStatus(
            cloudModeEnabled: true, lastAttempt: .distantPast, appIsForeground: true))
        #expect(!AppRefreshPolicy.shouldQueryCloudStatus(
            cloudModeEnabled: true, lastAttempt: .distantPast, appIsForeground: false))
        #expect(AppRefreshPolicy.shouldQueryCloudStatus(
            cloudModeEnabled: true, lastAttempt: .distantPast,
            appIsForeground: false, beforeLiveActivityCall: true))
        #expect(!AppRefreshPolicy.shouldQueryCloudStatus(
            cloudModeEnabled: true, lastAttempt: now.addingTimeInterval(-5), appIsForeground: true))
        #expect(!AppRefreshPolicy.shouldQueryCloudStatus(
            cloudModeEnabled: true, lastAttempt: now.addingTimeInterval(-30), appIsForeground: true))
        #expect(!AppRefreshPolicy.shouldQueryCloudStatus(
            cloudModeEnabled: true, lastAttempt: now.addingTimeInterval(-3_600),
            appIsForeground: false, beforeLiveActivityCall: true))
    }

    @Test func `Legacy agent poll fetches pending SMS without event endpoint`() async throws {
        let withMessage = try await LegacyAgentPoller.next(
            LegacyAgentSMSProbe(pending: 1, smsStatusAvailable: true))
        #expect(withMessage.smsChanged)

        let empty = try await LegacyAgentPoller.next(
            LegacyAgentSMSProbe(pending: 0, smsStatusAvailable: true))
        #expect(!empty.smsChanged)

        let unavailableStatus = try await LegacyAgentPoller.next(
            LegacyAgentSMSProbe(pending: nil, smsStatusAvailable: false))
        #expect(unavailableStatus.smsChanged)
    }

    @Test func `Pending SMS is fetched even when revision was already observed`() {
        #expect(AgentEventPollingPolicy.shouldFetchSMS(
            pending: 1, eventRevision: 7, observedSMSRevision: 7))
        #expect(AgentEventPollingPolicy.shouldFetchSMS(
            pending: 1, eventRevision: 0, observedSMSRevision: 7))
        #expect(!AgentEventPollingPolicy.shouldFetchSMS(
            pending: 0, eventRevision: 8, observedSMSRevision: 7))
    }

    @Test func `SMS fetch uses reporting agent after discovery switches phones`() async throws {
        let samsung = AgentSMSInboxProbe(name: "Samsung", inbox: [SMSMessage(
            sender: "10086", content: "From Samsung", code: nil,
            timestamp: Date(timeIntervalSince1970: 1_791_448_212),
            deliveryID: "samsung-sms-1", direction: .incoming
        )])
        let xiaomi = AgentSMSInboxProbe(name: "Xiaomi", inbox: [])

        let fetched = try await AgentSMSInboxFetch.fetch(
            reportingAgent: samsung, discoveredAgent: xiaomi
        )

        #expect(fetched.messages.map(\.content) == ["From Samsung"])
        #expect(fetched.agent.name == "Samsung")
    }

    @Test func `VoWLAN control carries offer not PCM`() throws {
        #expect(VoWLANAudioPlan.controlPath == "/api/calls/webrtc")
        #expect(VoWLANAudioPlan.usesHostICE)
        #expect(!VoWLANAudioPlan.opensNetworkPCM)
        let callUUID = UUID()
        let sessionID = UUID()
        let offer = VoWLANAudioPlan.offerJSON(
            callUUID: callUUID, generation: 1, sessionID: sessionID, sdp: "v=0"
        )
        #expect(offer.contains("\"action\":\"webrtc_offer\""))
        #expect(!offer.contains("AIRSIMVWL1"))
        let peer = try CloudWebRTCPeer(
            callUUID: callUUID,
            generation: 1,
            sessionID: sessionID,
            servers: [],
            queue: DispatchQueue(label: "vowlan-offer-test"),
            hostOnly: true,
            signal: { _ in },
            connected: {},
            failure: {},
            statistics: { _ in }
        )
        #expect(peer.usesHostICE)
        peer.close()
    }

    @Test func `Incoming SMS push accepts agent nanosecond timestamp`() throws {
        let pushed = try IncomingRemoteSMS(userInfo: [
            "event": "incoming_sms",
            "delivery_id": "sms-nano-1",
            "sender": "10086",
            "content": "SMS body",
            "timestamp": "2026-10-08T08:30:12.123456789Z",
        ])
        #expect(pushed.deliveryID == "sms-nano-1")
        #expect(pushed.message.content == "SMS body")
        #expect(abs(pushed.timestamp.timeIntervalSince1970 - 1_791_448_212.123456789) <= 0.001)
    }

    @Test func `Incoming SMS push accepts whole second timestamp`() throws {
        let pushed = try IncomingRemoteSMS(userInfo: [
            "event": "incoming_sms",
            "delivery_id": "sms-second-1",
            "sender": "10086",
            "content": "SMS body",
            "timestamp": "2026-10-08T08:30:12Z",
        ])
        #expect(pushed.deliveryID == "sms-second-1")
    }

    @Test func `Cold launch SMS navigation request is consumed once`() {
        let suite = "airsim-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        IncomingSMSPresentationRequest.markPending(sender: "10086", defaults: defaults)
        #expect(IncomingSMSPresentationRequest.consume(defaults: defaults) == "10086")
        #expect(IncomingSMSPresentationRequest.consume(defaults: defaults) == nil)
    }

    @Test func `SMS delivery ID deduplicates push and agent copies`() {
        let pushed = SMSMessage(
            sender: "10086", content: "SMS body", code: nil,
            timestamp: Date(timeIntervalSince1970: 1_791_448_212),
            deliveryID: "sms-stable-1", direction: .incoming
        )
        let synchronized = SMSMessage(
            sender: "10086", content: "SMS body", code: nil,
            timestamp: Date(timeIntervalSince1970: 1_791_448_212.123456789),
            deliveryID: "sms-stable-1", direction: .incoming
        )
        #expect(pushed.id == synchronized.id)
    }

    @Test func `Only Samsung private endpoints are accepted`() throws {
        let endpoint = try VoWLANEndpoint(host: "192.168.43.1", controlPort: 7575)
        #expect(endpoint.controlBaseURL.absoluteString == "http://192.168.43.1:7575/")
        #expect(throws: (any Error).self) {
            _ = try VoWLANEndpoint(host: "8.8.8.8", controlPort: 7575)
        }
        #expect(!AirSIMRoutePolicy.permits(.moduleLocal))
    }

    @Test func `Legacy module request is rejected before network access`() async {
        // Expected: the old module route is blocked at the transport boundary.
        let error = await #expect(throws: APIError.self) {
            _ = try await AirSIMAPI().health()
        }
        guard case APIError.disabledLegacyRoute? = error else {
            Issue.record("Expected legacy route retired error, got \(String(describing: error))")
            return
        }
    }

    @Test func `Dial transport prefers VoWLAN over cloud`() {
        let route = DialPadTransportPresentation.make(
            mode: .automatic,
            vowlanOnline: true,
            moduleLocalReachable: false,
            cloudOnline: true,
        )
        #expect(route?.transport == .vowlan)
    }

    @Test func `Automatic dial route falls back from VoWLAN to cloud`() {
        #expect(DialRouteSelector.preferred(
            mode: .automatic,
            vowlanReady: true,
            cloudReady: true
        ) == .vowlan)
        #expect(DialRouteSelector.preferred(
            mode: .automatic,
            vowlanReady: false,
            cloudReady: true
        ) == .cloud)
        #expect(DialRouteSelector.preferred(
            mode: .automatic,
            vowlanReady: false,
            cloudReady: true
        ) == .cloud)
    }


    @Test func `Android agent binding persists and rejects other routes`() {
        let suite = "AirSIMTests.agent-binding.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(AndroidAgentBindingPreference.selected(defaults: defaults) == nil)
        #expect(AndroidAgentBindingPreference.permits("samsung", defaults: defaults))
        AndroidAgentBindingPreference.set("vivo-x60", defaults: defaults)
        #expect(AndroidAgentBindingPreference.selected(defaults: defaults) == "vivo-x60")
        #expect(AndroidAgentBindingPreference.permits("vivo-x60", defaults: defaults))
        #expect(!AndroidAgentBindingPreference.permits("samsung", defaults: defaults))
        AndroidAgentBindingPreference.set(nil, defaults: defaults)
        #expect(AndroidAgentBindingPreference.selected(defaults: defaults) == nil)
    }

    @Test func `Paired device deletion persists and does not return from discovery`() {
        let suite = "AirSIMTests.paired-devices.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let samsung = PairedAndroidDeviceRecord(id: "samsung", deviceName: "Flip7", agentKind: "standalone")
        let vivo = PairedAndroidDeviceRecord(id: "vivo", deviceName: "X60", agentKind: "standalone")
        PairedAndroidDeviceStore.remember(samsung, defaults: defaults)
        PairedAndroidDeviceStore.remember(vivo, defaults: defaults)
        AndroidAgentBindingPreference.set("samsung", defaults: defaults)
        PairedAndroidDeviceStore.forget("samsung", defaults: defaults)
        PairedAndroidDeviceStore.remember(samsung, defaults: defaults)
        #expect(PairedAndroidDeviceStore.records(defaults: defaults).map(\.id) == ["vivo"])
        #expect(!PairedAndroidDeviceStore.permits("samsung", defaults: defaults))
        #expect(AndroidAgentBindingPreference.selected(defaults: defaults) == nil)
        let reopened = UserDefaults(suiteName: suite)!
        #expect(!PairedAndroidDeviceStore.permits("samsung", defaults: reopened))
        PairedAndroidDeviceStore.allowPairing("samsung", defaults: reopened)
        PairedAndroidDeviceStore.remember(samsung, defaults: reopened)
        #expect(Set(PairedAndroidDeviceStore.records(defaults: reopened).map(\.id)) == ["vivo", "samsung"])
    }

    @Test func `Fresh VoWLAN identity clears old number when new SIM does not report number`() throws {
        let endpoint = try VoWLANEndpoint(host: "192.168.31.203", controlPort: 7592)
        let previous = VoWLANDiscoveredAgent(id: "samsung", endpoint: endpoint, deviceName: "Flip7",
            manufacturer: "samsung", model: "Flip7", phoneNumber: "+10000000001", agentKind: "standalone")
        let empty = try JSONDecoder().decode(VoWLANHealthIdentity.self,
            from: Data(#"{"ok":true,"agent_id":"samsung","phone_number":""}"#.utf8))
        #expect(previous.refreshed(with: empty).phoneNumber == nil)
        let changed = try JSONDecoder().decode(VoWLANHealthIdentity.self,
            from: Data(#"{"ok":true,"agent_id":"samsung","phone_number":"+10000000002"}"#.utf8))
        #expect(previous.refreshed(with: changed).phoneNumber == "+10000000002")
    }

    @Test func `Authenticated Bluetooth metadata uses current number and rejects another device`() throws {
        let metadata = try AndroidAgentMetadata.decode(
            Data(#"{"agent_id":"samsung","device_name":"Flip7","phone_number":"","agent_kind":"standalone"}"#.utf8),
            expectedID: "samsung")
        #expect(metadata.phoneNumber == nil)
        #expect(metadata.deviceName == "Flip7")
        #expect(throws: (any Error).self) {
            _ = try AndroidAgentMetadata.decode(
                Data(#"{"agent_id":"other","device_name":"Other"}"#.utf8), expectedID: "samsung")
        }
    }

    @Test func `Deleted Bluetooth advertisement cannot automatically reconnect`() {
        let suite = "AirSIMTests.deleted-peripheral.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        PairedAndroidDeviceStore.rememberPeripheral("peripheral-samsung", for: "samsung", defaults: defaults)
        PairedAndroidDeviceStore.rememberPeripheral("peripheral-vivo", for: "vivo", defaults: defaults)
        PairedAndroidDeviceStore.forget("samsung", defaults: defaults)
        #expect(!PairedAndroidDeviceStore.permitsPeripheral("peripheral-samsung", defaults: defaults))
        #expect(PairedAndroidDeviceStore.permitsPeripheral("peripheral-vivo", defaults: defaults))
        PairedAndroidDeviceStore.allowPairing("samsung", defaults: defaults)
        #expect(PairedAndroidDeviceStore.permitsPeripheral("peripheral-samsung", defaults: defaults))
    }


    @Test func `Cloud status decodes multiple Android agents and current route`() throws {
        let data = Data(#"""
        {
            "cloud_online": true,
            "active_agent_id": "samsung-standalone",
            "agents": [
                {
                    "agent_id": "xiaomi-standalone",
                    "agent_kind": "standalone",
                    "device_name": "Xiaomi 15",
                    "phone_number": "+8613800000001",
                    "agent_version": "standalone-0.1.0",
                    "cloud_online": false
                },
                {
                    "agent_id": "samsung-standalone",
                    "agent_kind": "standalone",
                    "device_name": "Samsung Flip7",
                    "phone_number": "+8613800000002",
                    "agent_version": "standalone-0.1.0",
                    "cloud_online": true
                }
            ]
        }
        """#.utf8)
        let status = try JSONDecoder().decode(CloudAgentStatus.self, from: data)
        #expect(status.activeAgentID == "samsung-standalone")
        #expect(status.agents.count == 2)
        #expect(status.agents.last?.deviceName == "Samsung Flip7")
        #expect(status.agents.last?.phoneNumber == "+8613800000002")
    }

    @Test func `Cloud mode can be disabled without disabling local calls`() {
        let suite = "airsim-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: CloudModePreference.key)
        #expect(!CloudModePreference.isEnabled(defaults: defaults))
        #expect(OutgoingCommandAvailability.isAvailable(
            localControlReachable: true,
            cloudModeEnabled: false,
            cloudHeartbeatFresh: false
        ))
    }


    @Test func `Watch payload carries Bluetooth transport`() {
        let payload = WatchCallPayload(
            callID: "ble-call", callUUID: UUID(), phase: .active,
            number: "10010", callerName: nil, transport: "bluetooth",
            updatedAt: Date(timeIntervalSince1970: 42))
        #expect(payload.dictionary["transport"] as? String == "bluetooth")
        #expect(WatchCallPayload(dictionary: payload.dictionary)?.transport == "bluetooth")
    }

    @Test func `Watch dial does not request legacy PCM`() throws {
        #expect(WatchCloudAudioPlan.requestedTransport == "webrtc")
        #expect(
            CloudMediaTransport(rawValue: WatchCloudAudioPlan.requestedTransport)
                == .webRTC
        )
        #expect(
            CloudMediaTransport(rawValue: WatchCloudAudioPlan.requestedTransport)
                != .legacyPCM
        )
        #expect(!WatchCloudAudioPlan.accepts(transport: "legacy_pcm"))
        let requestID = UUID()
        let callUUID = UUID()
        let reply = WatchCloudAudioPlan.dialReply(
            requestID: requestID, callID: "watch-cloud", callUUID: callUUID,
            number: "+15551212", expiresAt: Date().addingTimeInterval(60)
        )
        #expect(reply["media_transport"] as? String == "webrtc")
        #expect(reply["media_route"] as? String == "iphone")
        #expect(reply["call_secret"] == nil)
        #expect(reply["media_url"] == nil)
        #expect(reply["pcm_host"] == nil)
        #expect(reply["pcm_secret"] == nil)
        let outgoing = try WatchVoIPCall(outgoingReply: reply)
        #expect(outgoing.isOutgoing)
        #expect(outgoing.media == .iphoneWebRTC)
        #expect(!outgoing.opensBinaryPCMWebSocket)
        #expect(outgoing.authenticatedMediaURL == nil)
        #expect(throws: WatchVoIPPayloadError.legacyPCMNotCarrier) {
            try WatchVoIPCall(outgoingReply: [
                "call_id": "watch-cloud", "call_uuid": callUUID.uuidString,
                "number": "+15551212", "media_route": "iphone", "media_transport": "legacy_pcm",
            ])
        }
    }

    @Test func `Watch missing transport defaults to WebRTC`() throws {
        #expect(WatchCloudAudioPlan.accepts(transport: nil))
        #expect(WatchCloudAudioPlan.accepts(transport: ""))
        #expect(WatchCloudAudioPlan.accepts(transport: "webrtc"))
        let call = try WatchVoIPCall(userInfo: [
            "event": "incoming_call", "call_id": "cloud-watch",
            "call_uuid": UUID().uuidString,
            "media_url": "wss://relay.example/v1/calls/test/connect",
            "call_secret": String(repeating: "c", count: 32),
        ])
        #expect(call.media == .iphoneWebRTC)
        #expect(!call.opensBinaryPCMWebSocket)
    }

    @Test func `Watch rejects legacy local audio credentials instead of capturing discarded audio`() {
        #expect(throws: WatchVoIPPayloadError.legacyPCMNotCarrier) {
            try WatchVoIPCall(userInfo: [
                "event": "incoming_call", "call_id": "legacy-watch", "call_uuid": UUID().uuidString,
                "media_route": "vowlan", "media_transport": "webrtc",
                "pcm_host": "192.168.43.1", "pcm_port": 7593, "pcm_secret": "retired",
            ])
        }
    }

    @Test func `Watch hangup control does not open PCM socket`() {
        let callUUID = UUID()
        let message = WatchCloudAudioPlan.companionControl(
            action: "end", callID: "watch-cloud", callUUID: callUUID
        )
        #expect(message["action"] as? String == "end")
        #expect(message["call_id"] as? String == "watch-cloud")
        #expect(message["call_uuid"] as? String == callUUID.uuidString)
        #expect(message["media_url"] == nil)
        #expect(message["call_secret"] == nil)
        #expect(message["pcm_host"] == nil)
        #expect(!message.keys.contains("pcm_secret"))
    }


    @Test @MainActor
    func `VoWLAN transport failure falls back once to cloud`() async throws {
        let local = OutgoingCallServiceProbe(dialError: URLError(.timedOut))
        var cloudAttempts = 0

        let result = try await OutgoingCallRouteCoordinator.start(
            number: "10086",
            vowlanService: local,
            cloudModeEnabled: true
        ) {
            cloudAttempts += 1
            return "cloud-call"
        }

        #expect(result == .cloud("cloud-call"))
        #expect(cloudAttempts == 1)
        let localActions = await local.recordedActions()
        #expect(localActions == ["warm", "dial:10086"])
    }

    @Test @MainActor
    func `VoWLAN agent rejection does not replay dial through cloud`() async {
        let local = OutgoingCallServiceProbe(
            dialError: APIError.http(502, "Android Telecom rejected dial")
        )
        var cloudAttempts = 0

        let error = await #expect(throws: APIError.self) {
            _ = try await OutgoingCallRouteCoordinator.start(
                number: "10086",
                vowlanService: local,
                cloudModeEnabled: true
            ) {
                cloudAttempts += 1
                return "cloud-call"
            }
        }
        if case APIError.http(let status, _)? = error {
            #expect(status == 502)
        } else {
            Issue.record("Expected Agent HTTP error to be preserved, got \(String(describing: error))")
        }

        #expect(cloudAttempts == 0)
    }

    @Test func `VoWLAN dial waits past Samsung Telecom acknowledgement window`() {
        #expect(AirSIMAPI.voWLANDialTimeout > 12)
    }

    @Test func `Maintainer bundle uses dedicated relay fallback`() {
        #expect(
            RelayConfiguration.effectiveURL(
                stored: nil,
                buildSetting: "",
                bundleID: "com.eric3u.airsim"
            )
            == "https://airsim-push.remotepilot.site"
        )
        #expect(
            RelayConfiguration.effectiveURL(
                stored: nil,
                buildSetting: "",
                bundleID: "org.example.airsim"
            )
            == ""
        )
        #expect(
            RelayConfiguration.effectiveURL(
                stored: "https://push.remotepilot.site/",
                buildSetting: "",
                bundleID: "com.eric3u.airsim"
            )
            == "https://airsim-push.remotepilot.site"
        )
        #expect(
            RelayConfiguration.effectiveURL(
                stored: "https://push.remotepilot.site/",
                buildSetting: "",
                bundleID: "org.example.airsim"
            )
            == "https://push.remotepilot.site/"
        )
    }

    @Test func `Relay health requires AirSIM service identity`() {
        let airSIM = Data(#"{"ok":true,"service":"airsim-push-relay","version":"0.2.1"}"#.utf8)
        let djonehub = Data(#"{"ok":true,"service":"djonehub-push-relay","version":"1.0.0"}"#.utf8)
        #expect(RelayHealthValidation.accepts(statusCode: 200, data: airSIM))
        #expect(!RelayHealthValidation.accepts(statusCode: 200, data: djonehub))
        #expect(!RelayHealthValidation.accepts(statusCode: 503, data: airSIM))
    }

    @Test func `Relay quota response explains registration failure`() {
        let response = Data("error code: 1027".utf8)
        let error = CloudAgentStatusError.relayFailure(statusCode: 429, data: response)
        guard case .requestLimitExceeded = error else {
            Issue.record("Cloudflare 1027 must not be reported as an invalid Relay response")
            return
        }
        #expect(error.localizedDescription.contains("quota"))
    }

    @Test func `Current mode prefers VoWLAN and reports cloud failure`() {
        #expect(
            ConnectionModePresentation.make(
                selectedMode: .automatic,
                vowlanOnline: true,
                cloudModeEnabled: true,
                cloudOnline: true
            ).mode
            == .vowlan
        )
        let bluetooth = ConnectionModePresentation.make(
            selectedMode: .automatic,
            vowlanOnline: false,
            cloudModeEnabled: true,
            cloudOnline: true
        )
        #expect(bluetooth.mode == .cloud)
        #expect(bluetooth.status == "Connected")
        let cloud = ConnectionModePresentation.make(
            selectedMode: .automatic,
            vowlanOnline: false,
            cloudModeEnabled: true,
            cloudOnline: true
        )
        #expect(cloud.mode == .cloud)
        #expect(cloud.status == "Connected")

        let unreachable = ConnectionModePresentation.make(
            selectedMode: .cloud,
            vowlanOnline: false,
            cloudModeEnabled: true,
            cloudOnline: false
        )
        #expect(unreachable.mode == .cloud)
        #expect(unreachable.status == "Unreachable")
    }

    @Test func `Cloud self test report only passes when every stage passes`() {
        var report = CloudSelfTestReport.initial
        #expect(!report.allPassed)
        #expect(report.steps.map(\.id) == Array(CloudSelfTestStepID.allCases))

        for id in CloudSelfTestStepID.allCases {
            report.update(id, state: .passed, detail: "Passed")
        }
        report.completedAt = Date()
        #expect(report.allPassed)

        report.update(.agentHeartbeat, state: .failed, detail: "No heartbeat")
        #expect(!report.allPassed)
    }


    @Test func `Hidden live activity does not register push to start token`() {
        let suiteName = "AirSIMTests.live-activity.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(
            LiveActivityVisibilityPreference.registrationToken("abc123", defaults: defaults)
                == "abc123"
        )
        defaults.set(false, forKey: LiveActivityVisibilityPreference.key)
        #expect(
            LiveActivityVisibilityPreference.registrationToken("abc123", defaults: defaults)
                == ""
        )
    }

    @Test func `Local mode live activity does not request remote push updates`() {
        #expect(LiveActivityCreationPolicy.pushType(localModeEnabled: true) == nil)
        #expect(LiveActivityCreationPolicy.pushType(localModeEnabled: false) != nil)
    }

    @Test func `VoWLAN recovery retries after temporary VPN route loss`() {
        var recovery = VoWLANRecoveryGate()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let unavailable = VoWLANAvailability.unavailable("VPN route switch")

        // shouldAttempt() mutates the gate, so each result is captured before asserting.
        var attempted = recovery.shouldAttempt(for: unavailable, at: start)
        #expect(attempted)
        attempted = recovery.shouldAttempt(for: unavailable, at: start.addingTimeInterval(3))
        #expect(!attempted)
        attempted = recovery.shouldAttempt(for: unavailable, at: start.addingTimeInterval(10))
        #expect(attempted)
        attempted = recovery.shouldAttempt(for: .unpaired, at: start.addingTimeInterval(20))
        #expect(!attempted)
    }

    @Test func `Island call actions reserve only right side button width`() {
        typealias Phase = AirSIMCallActivityAttributes.ContentState.Phase
        #expect(IslandActionLayout.reservedWidth(for: Phase.incoming) == 96)
        #expect(IslandActionLayout.reservedWidth(for: Phase.active) == 44)
        #expect(IslandActionLayout.reservedWidth(for: Phase.held) == 44)
        #expect(IslandActionLayout.reservedWidth(for: Phase.standby) == 0)
    }

    @Test func `Live activity state decodes legacy payload without agent fields`() throws {
        let state = AirSIMCallActivityAttributes.ContentState(
            callID: "",
            number: "",
            displayName: "Waiting for module call",
            phase: .standby,
            startedAt: Date(timeIntervalSince1970: 1),
            transport: .vowlan
        )
        let encoded = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(
            AirSIMCallActivityAttributes.ContentState.self,
            from: encoded
        )

        #expect(decoded.agentDeviceName == nil)
        #expect(decoded.agentPhoneNumber == nil)
        #expect(decoded.pairedAgentCount == nil)
    }

    @Test func `Local mode forces effective cloud mode off`() {
        let suiteName = "AirSIMTests.local-mode.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: LocalModePreference.key)
        defaults.set(true, forKey: CloudModePreference.key)

        #expect(LocalModePreference.isEnabled(defaults: defaults))
        #expect(!CloudModePreference.isEnabled(defaults: defaults))
    }

    @Test func `Local pairing choice does not read cloud credentials or change global mode`() throws {
        let suite = "AirSIMTests.pairing-choice.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: LocalModePreference.key)
        let registration = try SamsungPairingRegistrationPolicy.registration(
            localOnly: true, vowlanSecret: "fixture-key",
            cloudRegistration: { Issue.record("local pairing must not request push credentials"); return nil }
        )
        let payload = try #require(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(registration)) as? [String: Any])
        #expect(payload["vowlan_secret"] as? String == "fixture-key")
        #expect(payload["relay_url"] == nil)
        #expect(!LocalModePreference.isEnabled(defaults: defaults))
    }

    @Test func `Cloud pairing choice requires credentials without falling back to local`() throws {
        #expect(throws: (any Error).self) {
            _ = try SamsungPairingRegistrationPolicy.registration(
                localOnly: false, vowlanSecret: "fixture-key", cloudRegistration: { nil }
            )
        }
        var cloud = AgentPushRegistration.local(vowlanSecret: "old-key")
        cloud.localMode = false
        let registration = try SamsungPairingRegistrationPolicy.registration(
            localOnly: false, vowlanSecret: "new-key", cloudRegistration: { cloud }
        )
        let payload = try #require(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(registration)) as? [String: Any])
        #expect(payload["local_mode"] as? Bool == false)
        #expect(payload["vowlan_secret"] as? String == "new-key")
        #expect(payload["relay_url"] != nil)
    }

    @Test @MainActor
    func `Local pairing waits for old agent write and blocks new writes`() async throws {
        let gate = SamsungPairingRegistrationGate()
        #expect(gate.beginAgentWrite())
        var pairingStarted = false
        let pair = Task { @MainActor in
            try await gate.withPairing {
                pairingStarted = true
                #expect(!gate.beginAgentWrite())
            }
        }
        await Task.yield()
        #expect(!pairingStarted, "old cloud write must finish before local claim")
        #expect(!gate.beginAgentWrite(), "no new cloud write while pairing is waiting")
        gate.endAgentWrite()
        try await pair.value
        #expect(pairingStarted)
        #expect(gate.beginAgentWrite(), "other/global operations resume after pairing")
        gate.endAgentWrite()
    }

    @Test @MainActor
    func `Pairing failure releases agent write gate`() async throws {
        let gate = SamsungPairingRegistrationGate()
        let error = await #expect(throws: SamsungPairingClientError.self) {
            try await gate.withPairing { throw SamsungPairingClientError.expired }
        }
        #expect(error == .expired, "pairing must fail with the expiry error")
        #expect(gate.beginAgentWrite())
        gate.endAgentWrite()
    }

    @Test func `Automatic registration preserves local pairing for standalone and legacy agent`() throws {
        for json in [
            #"{"local_mode":true,"configured":true,"cloud_enabled":false,"call_push_ready":false,"message_push_ready":false}"#,
            #"{"configured":true,"cloud_enabled":false,"call_push_ready":false,"message_push_ready":false}"#
        ] {
            let status = try JSONDecoder().decode(AgentPushStatus.self, from: Data(json.utf8))
            #expect(status.preservesLocalPairing)
        }
        let unconfigured = try JSONDecoder().decode(AgentPushStatus.self, from: Data(
            #"{"configured":false,"cloud_enabled":false,"call_push_ready":false,"message_push_ready":false}"#.utf8))
        #expect(!unconfigured.preservesLocalPairing)
        let cloud = try JSONDecoder().decode(AgentPushStatus.self, from: Data(
            #"{"local_mode":false,"configured":true,"cloud_enabled":false,"relay_url":"https://relay.example","call_push_ready":false,"message_push_ready":false}"#.utf8))
        #expect(!cloud.preservesLocalPairing)
    }

    @Test func `Local pairing payload omits relay and push credentials`() throws {
        let registration = AgentPushRegistration.local(vowlanSecret: "local-vowlan-secret")
        let data = try JSONEncoder().encode(registration)
        let payload = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(payload["local_mode"] as? Bool == true)
        #expect(payload["cloud_enabled"] as? Bool == false)
        #expect(payload["vowlan_secret"] as? String == "local-vowlan-secret")
        #expect(payload["relay_url"] == nil)
        #expect(payload["device_id"] == nil)
        #expect(payload["device_secret"] == nil)
        #expect(payload["voip_token"] == nil)
        #expect(payload["alert_token"] == nil)
    }
}

struct RecentCallTimeFormatterTests {
    private let calendar = Calendar(identifier: .gregorian)

    private func date(hour: Int, minute: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 3, day: 15, hour: hour, minute: minute))!
    }

    // 12-hour regions (en_US) must retain AM/PM; the system may insert a narrow no-break space (U+202F) before PM.
    @Test func `Today shows meridiem in twelve hour locale`() {
        let text = RecentCallTimeFormatter.string(
            for: date(hour: 14, minute: 30), now: date(hour: 16, minute: 0),
            calendar: calendar, locale: Locale(identifier: "en_US"))
        #expect(text.replacingOccurrences(of: "\u{202F}", with: " ") == "2:30 PM")
    }

    @Test func `Today keeps twenty four hour in 24 hour locale`() {
        let text = RecentCallTimeFormatter.string(
            for: date(hour: 14, minute: 30), now: date(hour: 16, minute: 0),
            calendar: calendar, locale: Locale(identifier: "en_GB"))
        #expect(text == "14:30")
    }
}
