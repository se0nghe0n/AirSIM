import CryptoKit
import AVFoundation
import Testing
import AppIntents
import Foundation
import UIKit
import ComposableArchitecture
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
        #expect(AgentEventPollingPolicy.shouldFetchSMS(pending: 1))
        #expect(!AgentEventPollingPolicy.shouldFetchSMS(pending: 0))
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

    @Test func `VoWLAN audio uses host-only WebRTC, not PCM`() throws {
        #expect(VoWLANAudioPlan.usesHostICE)
        #expect(!VoWLANAudioPlan.opensNetworkPCM)
        let callUUID = UUID()
        let sessionID = UUID()
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
        #expect(!AirSIMRoutePolicy.permits(.unavailable))
    }

    @Test func `Unavailable local connection is rejected before network access`() async {
        // An offline API has no endpoint and cannot issue a network request.
        let error = await #expect(throws: APIError.self) {
            _ = try await AirSIMAPI().health()
        }
        guard case APIError.localConnectionUnavailable? = error else {
            Issue.record("Expected unavailable local connection error, got \(String(describing: error))")
            return
        }
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


    @Test func `Android agent binding persists and clears`() {
        let suite = "AirSIMTests.agent-binding.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(AndroidAgentBindingPreference.selected(defaults: defaults) == nil)
        AndroidAgentBindingPreference.set("vivo-x60", defaults: defaults)
        #expect(AndroidAgentBindingPreference.selected(defaults: defaults) == "vivo-x60")
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
        #expect(RelayHealthValidation.version(statusCode: 200, data: airSIM) == "0.2.1")
        #expect(RelayHealthValidation.version(statusCode: 200, data: djonehub) == nil)
        #expect(RelayHealthValidation.version(statusCode: 503, data: airSIM) == nil)
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


@Suite(.serialized)
struct LiveActivityCallActionTests {
    @Test @MainActor
    func `Live Activity intents dispatch all actions without a URL handoff`() async throws {
        let dispatcher = LiveActivityCallActionDispatcher.shared
        let previous = dispatcher.handler
        defer { dispatcher.handler = previous }
        var actions: [AirSIMLiveActivityAction] = []
        var targets: [String] = []
        dispatcher.handler = { action, callID in
            actions.append(action)
            targets.append(callID)
        }
        _ = try await AnswerAirSIMCallIntent(callID: "current-call").perform()
        _ = try await RejectAirSIMCallIntent(callID: "current-call").perform()
        _ = try await HangUpAirSIMCallIntent(callID: "current-call").perform()
        #expect(actions == [.answer, .reject, .hangup])
        #expect(targets == ["current-call", "current-call", "current-call"])
    }

    @Test @MainActor
    func `Empty and unavailable intent targets fail without sending a command`() async {
        let dispatcher = LiveActivityCallActionDispatcher()
        var sent = false
        dispatcher.handler = { _, _ in sent = true }
        await #expect(throws: LiveActivityCallError.self) {
            try await dispatcher.perform(.answer, callID: "")
        }
        #expect(!sent)
        dispatcher.handler = nil
        await #expect(throws: LiveActivityCallError.self) {
            try await dispatcher.perform(.hangup, callID: "current")
        }
    }

    @Test @MainActor
    func `Intent backend failures remain failures`() async {
        let dispatcher = LiveActivityCallActionDispatcher()
        dispatcher.handler = { _, _ in throw URLError(.notConnectedToInternet) }
        await #expect(throws: LiveActivityCallError.self) {
            try await dispatcher.perform(.reject, callID: "current")
        }
    }

    @Test func `Live Activity cannot control a replacement or ended call`() {
        for action in [AirSIMLiveActivityAction.answer, .reject, .hangup] {
            for target: String? in [nil, "replacement"] {
                #expect(throws: LiveActivityCallError.self) {
                    try LiveActivityCallActionPolicy.shouldPerform(action, callID: "old",
                        currentCallID: target, state: "incoming", direction: "incoming")
                }
            }
            #expect(throws: LiveActivityCallError.self) {
                try LiveActivityCallActionPolicy.shouldPerform(action, callID: "old",
                    currentCallID: "old", state: "ended", direction: "incoming")
            }
        }
    }

    @Test func `Incoming buttons cannot answer outgoing calls or reject answered calls`() throws {
        #expect(try LiveActivityCallActionPolicy.shouldPerform(.answer, callID: "current",
            currentCallID: "current", state: "incoming", direction: "incoming"))
        #expect(try LiveActivityCallActionPolicy.shouldPerform(.reject, callID: "current",
            currentCallID: "current", state: "waiting", direction: "incoming"))
        #expect(throws: LiveActivityCallError.self) {
            try LiveActivityCallActionPolicy.shouldPerform(.answer, callID: "current",
                currentCallID: "current", state: "dialing", direction: "outgoing")
        }
        #expect(throws: LiveActivityCallError.self) {
            try LiveActivityCallActionPolicy.shouldPerform(.reject, callID: "current",
                currentCallID: "current", state: "active", direction: "incoming")
        }
        for state in ["connecting", "active", "held"] {
            #expect(try !LiveActivityCallActionPolicy.shouldPerform(.answer, callID: "current",
                currentCallID: "current", state: state, direction: "incoming"))
        }
        #expect(try LiveActivityCallActionPolicy.shouldPerform(.hangup, callID: "current",
            currentCallID: "current", state: "active", direction: "outgoing"))
    }
}

struct StandaloneCleanupTests {
    @Test func `Old activity transport decodes without reviving USB routing`() throws {
        let transport = try JSONDecoder().decode(
            AirSIMCallActivityAttributes.ContentState.Transport.self,
            from: Data(#""module_local""#.utf8))
        #expect(transport == .unavailable)
    }

    @Test func `Live Activity handoff preserves the call identity and rejects stale targets`() throws {
        for action in [AirSIMLiveActivityAction.answer, .reject, .hangup] {
            let url = try #require(AirSIMLiveActivityActionURL.make(action: action, callID: "call-A"))
            let request = try #require(AirSIMLiveActivityActionURL.parse(url))
            #expect(request.action == action)
            #expect(LiveActivityActionGate.accepts(callID: request.callID, currentCallID: "call-A", callIsLive: true))
            #expect(!LiveActivityActionGate.accepts(callID: request.callID, currentCallID: "call-B", callIsLive: true))
            #expect(!LiveActivityActionGate.accepts(callID: request.callID, currentCallID: nil, callIsLive: true))
        }
        #expect(!LiveActivityActionGate.accepts(callID: "", currentCallID: "", callIsLive: true))
        #expect(!LiveActivityActionGate.accepts(callID: "call-A", currentCallID: "call-A", callIsLive: false))
    }
}

@MainActor
struct UIKitPresentationTests {
    @Test func `Large lists construct bodies only for displayed cells`() {
        let controller = PhoneTableController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = controller; window.makeKeyAndVisible()
        defer { window.isHidden = true }
        var constructed = 0
        let rows = (0..<1_000).map { index in
            PhoneRow(id: String(index), title: "", bodyViewProvider: { constructed += 1; return phoneLabel("Row \(index)") })
        }
        controller.setSections([PhoneSection(rows: rows)])
        controller.table.layoutIfNeeded()
        #expect(constructed > 0)
        #expect(constructed < 100)
        let beforeUpdate = constructed
        let visibleBody = controller.table.visibleCells.first?.contentView.subviews.last
        controller.setSections([PhoneSection(rows: rows)])
        controller.table.layoutIfNeeded()
        #expect(constructed == beforeUpdate)
        #expect(controller.table.visibleCells.first?.contentView.subviews.last === visibleBody)
        controller.table.scrollToRow(at: IndexPath(row: 999, section: 0), at: .bottom, animated: false)
        controller.table.layoutIfNeeded()
        #expect(controller.table.cellForRow(at: IndexPath(row: 999, section: 0)) != nil)
        #expect(constructed < 200)
    }

    @Test func `Duplicate row identities can shrink without an invalid batch update`() {
        let controller = PhoneTableController(); controller.loadViewIfNeeded()
        controller.setSections([PhoneSection(rows: [PhoneRow(id: "same", title: "First"), PhoneRow(id: "same", title: "Second")])])
        controller.table.layoutIfNeeded()
        controller.setSections([PhoneSection(rows: [PhoneRow(id: "same", title: "Remaining")])])
        #expect(controller.table.numberOfRows(inSection: 0) == 1)
    }

    @Test func `Section copy updates without replacing the focused field`() throws {
        let controller = PhoneTableController()
        let field = UITextField()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = controller; window.makeKeyAndVisible()
        defer { window.isHidden = true }
        controller.setSections([PhoneSection(title: "Old title", footer: "Old footer", rows: [PhoneRow(id: "url", title: "", accessory: field)])])
        controller.table.layoutIfNeeded()
        field.becomeFirstResponder()
        controller.setSections([PhoneSection(title: "New title", footer: "New footer", rows: [PhoneRow(id: "url", title: "", accessory: field)])])
        controller.table.layoutIfNeeded()
        let header = try #require(controller.table.headerView(forSection: 0)?.contentConfiguration as? UIListContentConfiguration)
        let footer = try #require(controller.table.footerView(forSection: 0)?.contentConfiguration as? UIListContentConfiguration)
        #expect(header.text == "New title")
        #expect(footer.text == "New footer")
        #expect(field.isFirstResponder)
    }

    @Test func `Native form keeps focused text and selection when another section changes`() {
        let controller = PhoneTableController()
        controller.loadViewIfNeeded()
        let field = UITextField()
        field.text = "https://relay.example.com"
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.setSections([
            PhoneSection(rows: [PhoneRow(id: "url", title: "", accessory: field)]),
            PhoneSection(rows: [PhoneRow(id: "status", title: "Connecting")])
        ])
        controller.table.layoutIfNeeded()
        field.becomeFirstResponder()
        let start = field.position(from: field.beginningOfDocument, offset: 8)!
        field.selectedTextRange = field.textRange(from: start, to: start)
        controller.setSections([
            PhoneSection(rows: [PhoneRow(id: "url", title: "", accessory: field)]),
            PhoneSection(rows: [PhoneRow(id: "status", title: "Online"), PhoneRow(id: "new", title: "Agent ready")])
        ])
        controller.table.layoutIfNeeded()
        #expect(field.isFirstResponder)
        #expect(field.text == "https://relay.example.com")
        #expect(field.offset(from: field.beginningOfDocument, to: field.selectedTextRange!.start) == 8)
        window.isHidden = true
    }

    @Test func `Native message editor row fits its control height`() {
        let controller = PhoneTableController()
        controller.loadViewIfNeeded()
        let editor = UITextView()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 568))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.setSections([PhoneSection(rows: [PhoneRow(id: "editor", title: "", accessory: editor)])])
        controller.table.layoutIfNeeded()
        let rect = controller.table.rectForRow(at: IndexPath(row: 0, section: 0))
        #expect(rect.height >= 144)
        #expect(editor.bounds.width > 0)
        #expect(editor.bounds.width <= 320)
        window.isHidden = true
    }

    @Test func `Sheet preserves existing Send action`() {
        let presenter = UIViewController()
        let composer = UIViewController()
        let send = UIBarButtonItem(title: "Send", primaryAction: UIAction { _ in })
        composer.navigationItem.rightBarButtonItem = send
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = presenter
        window.makeKeyAndVisible()
        presenter.showPhoneSheet(composer)
        #expect(composer.navigationItem.rightBarButtonItem === send)
        presenter.dismiss(animated: false)
        window.isHidden = true
    }
}

@MainActor
struct TCAUIKitFeatureTests {
    private func client(sendResult: Bool = false) -> AirSIMClient {
        AirSIMClient(
            snapshots: { AsyncStream { $0.finish() } },
            command: { _ in },
            sendSMS: { _, _ in .init(success: sendResult) },
            selfTest: { AsyncStream { _ in } },
            pairing: { AsyncStream { $0.finish() } },
            pair: { _, _, _ in "Paired" }
        )
    }

    @Test func `Failed SMS send preserves draft and releases sending state`() async {
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        var state = MessagesFeature.State()
        state.recipient = "+12025550100"; state.body = "Keep this draft"; state.composerPresented = true
        let store = TestStore(initialState: state) { MessagesFeature() } withDependencies: {
            $0.airSIM = client(); $0.uuid = .constant(id)
        }
        await store.send(.sendComposer) { $0.sending = true; $0.sendID = id }
        await store.receive(\.sendResponse) {
            $0.sending = false; $0.sendID = nil
            $0.error = "Unable to send message. Your draft has been kept."
        }
        #expect(store.state.body == "Keep this draft")
        #expect(store.state.composerPresented)
    }

    @Test func `SMS failure retains the backend reason and draft`() async {
        let id = UUID()
        var state = MessagesFeature.State(); state.recipient = "123"; state.body = "Keep me"; state.composerPresented = true
        var dependency = client()
        dependency.sendSMS = { _, _ in .init(success: false, error: "Cloud mode is disabled") }
        let store = TestStore(initialState: state) { MessagesFeature() } withDependencies: { $0.airSIM = dependency; $0.uuid = .constant(id) }
        await store.send(.sendComposer) { $0.sending = true; $0.sendID = id }
        await store.receive(\.sendResponse) { $0.sending = false; $0.sendID = nil; $0.error = "Cloud mode is disabled" }
        #expect(store.state.body == "Keep me")
    }

    @Test func `Updating the recipient of an open composer preserves its body`() async {
        var state = MessagesFeature.State(); state.recipient = "old"; state.body = "Keep this text"; state.composerPresented = true
        let store = TestStore(initialState: state) { MessagesFeature() } withDependencies: { $0.airSIM = client() }
        await store.send(.compose("new")) { $0.recipient = "new" }
        #expect(store.state.body == "Keep this text")
    }

    @Test func `Visible thread reply retains its recipient if route state was cleared`() async {
        let id = UUID(); let recipients = LockIsolated<[String]>([])
        var state = MessagesFeature.State(); state.reply = "Still addressed"
        var dependency = client()
        dependency.sendSMS = { to, _ in recipients.withValue { $0.append(to) }; return .init(success: true) }
        let store = TestStore(initialState: state) { MessagesFeature() } withDependencies: { $0.airSIM = dependency; $0.uuid = .constant(id) }
        await store.send(.sendReply(to: "123")) { $0.sending = true; $0.sendID = id }
        await store.receive(\.sendResponse) { $0.reply = ""; $0.sending = false; $0.sendID = nil }
        #expect(recipients.value == ["123"])
    }

    @Test func `Old SMS completion cannot close a newly opened composer`() async {
        let oldID = UUID()
        var state = MessagesFeature.State()
        state.recipient = "old"; state.body = "old body"; state.composerPresented = true; state.sending = true; state.sendID = oldID
        let store = TestStore(initialState: state) { MessagesFeature() } withDependencies: { $0.airSIM = client() }
        await store.send(.dismissComposer) { $0.composerPresented = false; $0.sendID = nil; $0.sending = false }
        await store.send(.compose("new")) { $0.recipient = "new"; $0.body = ""; $0.composerPresented = true }
        await store.send(.bodyChanged("new draft")) { $0.body = "new draft" }
        await store.send(.sendResponse(id: oldID, success: true, body: "old body", composer: true))
        #expect(store.state.body == "new draft")
        #expect(store.state.composerPresented)
    }

    @Test func `Old reply completion cannot clear another conversation draft`() async {
        let oldID = UUID()
        var state = MessagesFeature.State()
        state.conversation = "old"; state.reply = "same text"; state.sending = true; state.sendID = oldID
        let store = TestStore(initialState: state) { MessagesFeature() } withDependencies: { $0.airSIM = client() }
        await store.send(.openConversation("new")) { $0.conversation = "new"; $0.reply = ""; $0.sending = false; $0.sendID = nil }
        await store.send(.replyChanged("same text")) { $0.reply = "same text" }
        await store.send(.sendResponse(id: oldID, success: true, body: "same text", composer: false))
        #expect(store.state.reply == "same text")
    }

    @Test func `Changing mode cancels streaming self test without completing it`() async {
        let store = TestStore(initialState: SettingsFeature.State()) { SettingsFeature() } withDependencies: { $0.airSIM = client() }
        await store.send(.runSelfTest) { $0.selfTestRunning = true; $0.report = .initial }
        await store.send(.modeChanged(.vowlan)) { $0.mode = .vowlan; $0.selfTestRunning = false; $0.report = nil }
        await store.finish()
        #expect(!store.state.selfTestCompleted)
    }

    @Test func `Open conversation selects destination without sharing composer state`() async {
        let store = TestStore(initialState: MessagesFeature.State()) { MessagesFeature() } withDependencies: { $0.airSIM = client() }
        await store.send(.openConversation("+12025550100")) { $0.conversation = "+12025550100" }
        #expect(!store.state.composerPresented)
    }
}

@MainActor
struct TCATraceCommandTests {
    private func client(clears: LockIsolated<[Bool]>, toggles: LockIsolated<[Bool]>) -> AirSIMClient {
        AirSIMClient(
            snapshots: { AsyncStream { $0.finish() } }, command: { _ in },
            sendSMS: { _, _ in .init(success: false) }, selfTest: { AsyncStream { $0.finish() } },
            pairing: { AsyncStream { $0.finish() } },
            traceRefresh: { data, clear in clears.withValue { $0.append(clear) }; return data },
            traceEnabled: { enabled in toggles.withValue { $0.append(enabled) } },
            pair: { _, _, _ in "" }
        )
    }

    @Test func `Clear requested during a poll runs after the poll`() async {
        let clears = LockIsolated<[Bool]>([])
        var state = TraceFeature.State(); state.refreshing = true; state.refreshID = 1
        let store = TestStore(initialState: state) { TraceFeature() } withDependencies: {
            $0.airSIM = client(clears: clears, toggles: LockIsolated([]))
        }
        await store.send(.clear) { $0.pendingClear = true }
        await store.send(.refreshed(id: 1, AgentVerboseTraceData())) { $0.refreshing = false }
        await store.receive(\.refresh) { $0.refreshing = true; $0.refreshID = 2; $0.pendingClear = false }
        await store.receive(\.refreshed) { $0.refreshing = false }
        #expect(clears.value == [true])
    }

    @Test func `An old poll cannot overwrite a pending verbose preference`() async {
        let toggles = LockIsolated<[Bool]>([])
        var state = TraceFeature.State(); state.refreshing = true; state.refreshID = 1
        let store = TestStore(initialState: state) { TraceFeature() } withDependencies: {
            $0.airSIM = client(clears: LockIsolated([]), toggles: toggles)
        }
        await store.send(.enabledChanged(true)) { $0.data.enabled = true; $0.pendingEnabled = true }
        await store.send(.refreshed(id: 1, AgentVerboseTraceData())) { $0.refreshing = false }
        await store.receive(\.refresh) { $0.refreshing = true; $0.refreshID = 2; $0.pendingEnabled = nil }
        await store.receive(\.refreshed) { $0.refreshing = false }
        #expect(store.state.data.enabled)
        #expect(toggles.value == [true])
    }

    @Test func `Trace completion from a disappeared screen is ignored`() async {
        var state = TraceFeature.State(); state.refreshing = true; state.refreshID = 1
        let store = TestStore(initialState: state) { TraceFeature() } withDependencies: {
            $0.airSIM = client(clears: LockIsolated([]), toggles: LockIsolated([]))
        }
        await store.send(.disappeared) { $0.refreshing = false; $0.refreshID = 2 }
        var stale = AgentVerboseTraceData(); stale.enabled = true
        await store.send(.refreshed(id: 1, stale))
        #expect(!store.state.data.enabled)
    }
}

@MainActor
struct TCARootNavigationTests {
    private var client: AirSIMClient {
        AirSIMClient(snapshots: { AsyncStream { _ in } }, command: { _ in }, sendSMS: { _, _ in .init(success: false) }, selfTest: { AsyncStream { $0.finish() } }, pairing: { AsyncStream { $0.finish() } }, pair: { _, _, _ in "" })
    }
    @Test func `Cold im link selects Messages and presents composer from state`() async {
        let store = TestStore(initialState: AirSIMFeature.State()) { AirSIMFeature() } withDependencies: { $0.airSIM = client }
        await store.send(.openURL(URL(string: "im:+12025550100")!)) { $0.selectedTab = .messages }
        await store.receive(\.messages.compose) { $0.messages.recipient = "+12025550100"; $0.messages.composerPresented = true }
    }
    @Test func `Cold Live Activity URL carries call identity past a stale UI snapshot`() async throws {
        let performed = LockIsolated<[String]>([])
        var dependency = client
        dependency.command = { command in
            if case let .liveActivityAction(action, callID) = command { performed.withValue { $0.append("\(action.rawValue):\(callID)") } }
        }
        let store = TestStore(initialState: AirSIMFeature.State()) { AirSIMFeature() } withDependencies: { $0.airSIM = dependency }
        let url = try #require(AirSIMLiveActivityActionURL.make(action: .answer, callID: "call-A"))
        await store.send(.openURL(url))
        await store.receive(\.command)
        await store.finish()
        #expect(performed.value == ["answer:call-A"])
    }
    @Test func `Service snapshot cannot overwrite newer dial input`() async {
        let store = TestStore(initialState: AirSIMFeature.State()) { AirSIMFeature() } withDependencies: { $0.airSIM = client }
        await store.send(.numberChanged("123")) { $0.dialNumber = "123"; $0.hasDialDraft = true }
        var old = AirSIMSnapshot(); old.numberInput = "12"
        await store.send(.snapshot(old)) { $0.snapshot = old; $0.lastBackendNumber = "12" }
        #expect(store.state.dialNumber == "123")
    }
    @Test func `Scene teardown cancels service observation`() async {
        let store = TestStore(initialState: AirSIMFeature.State()) { AirSIMFeature() } withDependencies: { $0.airSIM = client }
        await store.send(.start)
        await store.send(.stop)
        await store.finish()
    }
}

@MainActor
struct TCANavigationDismissalTests {
    @Test func `Back clears thread destination so later snapshots cannot reopen it`() async {
        var state = MessagesFeature.State(); state.conversation = "+12025550100"
        let store = TestStore(initialState: state) { MessagesFeature() }
        await store.send(.closeConversation) { $0.conversation = nil }
        #expect(store.state.conversation == nil)
    }
    @Test func `Opening notification conversation dismisses current composer state`() async {
        var state = MessagesFeature.State(); state.composerPresented = true; state.recipient = "other"; state.body = "draft"
        let store = TestStore(initialState: state) { MessagesFeature() }
        await store.send(.openConversation("+12025550100")) { $0.conversation = "+12025550100"; $0.composerPresented = false }
        #expect(!store.state.composerPresented)
    }
}

@MainActor
struct UIKitNavigationBridgeTests {
    private func presentation() -> AirSIMPresentation {
        var state = AirSIMFeature.State(); state.firstConnectionComplete = true; state.selectedTab = .messages
        let client = AirSIMClient(snapshots: { AsyncStream { $0.finish() } }, command: { _ in }, sendSMS: { _, _ in .init(success: false) }, selfTest: { AsyncStream { $0.finish() } }, pairing: { AsyncStream { $0.finish() } }, pair: { _, _, _ in "" })
        let store = Store(initialState: state) { AirSIMFeature() } withDependencies: { $0.airSIM = client }
        return AirSIMPresentation(store: store)
    }
    @Test func `Native Back reconciles Store before another render can reopen thread`() {
        let model = presentation()
        let controller = MessagesViewController(model: model)
        let nav = UINavigationController(rootViewController: controller)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844)); window.rootViewController = nav; window.makeKeyAndVisible()
        controller.openConversation("+12025550100")
        #expect(nav.topViewController is MessageThreadViewController)
        nav.popViewController(animated: false)
        #expect(model.store.messages.conversation == nil)
        controller.render()
        #expect(nav.topViewController === controller)
        window.isHidden = true
    }
    @Test func `Composer can present while conversation controller is visible`() async throws {
        let model = presentation()
        let controller = MessagesViewController(model: model)
        let nav = UINavigationController(rootViewController: controller)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844)); window.rootViewController = nav; window.makeKeyAndVisible()
        controller.openConversation("+12025550100")
        controller.compose(recipient: "+12025550101")
        #expect((nav.presentedViewController as? UINavigationController)?.topViewController is MessageComposerViewController)
        #expect(model.store.messages.recipient == "+12025550101")
        nav.dismiss(animated: false); window.isHidden = true
    }
}

@MainActor
struct TCASharedPreferenceTests {
    @Test func `Other scene preferences update without replacing the active relay draft`() async {
        var state = AirSIMFeature.State()
        state.settings.relayURL = "https://draft.example"
        state.settings.lastObservedRelayURL = "https://saved.example"
        state.settings.relayHasDraft = true
        var snapshot = AirSIMSnapshot()
        snapshot.preferenceMode = .cloud
        snapshot.preferenceAppearance = .dark
        snapshot.preferenceRelayURL = "https://other.example"
        let store = TestStore(initialState: state) { AirSIMFeature() }
        await store.send(.snapshot(snapshot)) {
            $0.snapshot = snapshot
            $0.settings.mode = .cloud; $0.settings.lastObservedMode = .cloud
            $0.settings.appearance = .dark; $0.settings.lastObservedAppearance = .dark
            $0.settings.lastObservedRelayURL = "https://other.example"
        }
        #expect(store.state.settings.relayURL == "https://draft.example")
    }
}

@MainActor
struct UIKitConversationReplacementTests {
    @Test func `Finishing Back for A cannot clear a newly requested B`() {
        let model = AirSIMPreviewFixtures.presentation(tab: .messages)
        let list = MessagesViewController(model: model)
        let nav = UINavigationController(rootViewController: list)
        list.loadViewIfNeeded(); list.openConversation("A")
        model.store.send(.messages(.openConversation("B")))
        list.navigationController(nav, didShow: list, animated: true)
        #expect(model.store.messages.conversation == "B")
        list.showConversationIfNeeded("B")
        #expect((nav.topViewController as? MessageThreadViewController)?.sender == "B")
    }

    @Test func `Replacing conversation A with B does not clear B when A is removed`() {
        var state = AirSIMFeature.State(); state.firstConnectionComplete = true; state.selectedTab = .messages
        let client = AirSIMClient(snapshots: { AsyncStream { $0.finish() } }, command: { _ in }, sendSMS: { _, _ in .init(success: false) }, selfTest: { AsyncStream { $0.finish() } }, pairing: { AsyncStream { $0.finish() } }, pair: { _, _, _ in "" })
        let model = AirSIMPresentation(store: Store(initialState: state) { AirSIMFeature() } withDependencies: { $0.airSIM = client })
        let controller = MessagesViewController(model: model)
        let nav = UINavigationController(rootViewController: controller)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844)); window.rootViewController = nav; window.makeKeyAndVisible()
        controller.openConversation("A")
        controller.openConversation("B")
        #expect(model.store.messages.conversation == "B")
        #expect((nav.topViewController as? MessageThreadViewController)?.sender == "B")
        window.isHidden = true
    }
}

@MainActor
private final class SpeculativeNavigationController: UINavigationController {
    var pendingStack: [UIViewController]?
    override var topViewController: UIViewController? { pendingStack?.last ?? super.topViewController }
    override var viewControllers: [UIViewController] {
        get { pendingStack ?? super.viewControllers }
        set { super.viewControllers = newValue }
    }
}

@MainActor
@Suite(.serialized)
struct UIKitAdversarialRegressionTests {
    @Test func `Reapplying a conversation preserves unrelated presented sheets`() throws {
        let model = AirSIMPreviewFixtures.presentation(tab: .messages)
        let root = RootViewController(previewPresentation: model)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = root; window.makeKeyAndVisible()
        defer { root.dismiss(animated: false); window.isHidden = true }
        root.openSMSConversation(AirSIMPreviewFixtures.phone)
        root.render()
        let sheet = UIViewController()
        root.present(sheet, animated: false)
        #expect(root.presentedViewController === sheet)
        root.render()
        #expect(root.presentedViewController === sheet)
        #expect(!sheet.isBeingDismissed)
        root.openSMSConversation("different conversation")
        #expect(root.presentedViewController === sheet)
        #expect(!sheet.isBeingDismissed)
    }

    @Test func `Call teardown leaves an unrelated root sheet intact`() {
        let model = AirSIMPreviewFixtures.presentation(callState: "active")
        let root = RootViewController(previewPresentation: model)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = root; window.makeKeyAndVisible(); root.render()
        defer { root.dismiss(animated: false); window.isHidden = true }
        #expect(root.children.contains { $0 is ActiveCallViewController })
        let sheet = UIViewController(); root.present(sheet, animated: false)
        var ended = model.snapshot; ended.inAppPresentedCall = nil; ended.callLifecycleSnapshot = .idle
        model.store.send(.snapshot(ended)); root.render()
        #expect(!root.children.contains { $0 is ActiveCallViewController })
        #expect(root.presentedViewController === sheet)
        #expect(!sheet.isBeingDismissed)
    }

    @Test func `Call keypad survives thread renders and closes with its call`() async throws {
        let model = AirSIMPreviewFixtures.presentation(tab: .messages, callState: "active")
        let root = RootViewController(previewPresentation: model)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = root; window.makeKeyAndVisible()
        defer { root.dismiss(animated: false); window.isHidden = true }
        root.openSMSConversation(AirSIMPreviewFixtures.phone); root.render()
        let call = try #require(root.children.compactMap { $0 as? ActiveCallViewController }.first)
        call.presentKeypad(animated: false)
        let keypad = try #require(root.presentedViewController as? UINavigationController)
        #expect(keypad.topViewController is DTMFKeypadViewController)
        root.render()
        #expect(!keypad.isBeingDismissed)
        var ended = model.snapshot; ended.inAppPresentedCall = nil; ended.callLifecycleSnapshot = .idle
        model.store.send(.snapshot(ended)); root.render()
        #expect(!model.store.keypadPresented)
        for _ in 0..<100 {
            if keypad.presentingViewController == nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(keypad.presentingViewController == nil)
    }

    @Test func `Speculative Back appearance does not discard a live reply destination`() async {
        let model = AirSIMPreviewFixtures.presentation(tab: .messages)
        let list = MessagesViewController(model: model)
        let nav = SpeculativeNavigationController(rootViewController: list)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = nav; window.makeKeyAndVisible()
        defer { window.isHidden = true }
        list.openConversation("123")
        model.store.send(.messages(.replyChanged("Reply after cancelled Back")))
        // During an interactive pop UIKit exposes the proposed stack before didShow.
        let departingThread = nav.topViewController
        nav.pendingStack = [list]; list.viewWillAppear(true)
        // A backend update during a held Back gesture re-applies the same route.
        list.showConversationIfNeeded("123")
        nav.pendingStack = nil
        #expect(nav.topViewController === departingThread)
        #expect(model.store.messages.conversation == "123")
        #expect(nav.topViewController is MessageThreadViewController)
        await model.store.send(.messages(.sendReply(to: "123"))).finish()
        #expect(model.store.messages.reply.isEmpty)
    }

    @Test func `Contact picker search cannot filter the Contacts tab`() {
        let model = AirSIMPreviewFixtures.presentation(tab: .contacts)
        model.store.send(.contactSearchChanged("Mina"))
        let tab = ContactsViewController(model: model, onCall: { _ in }, onMessage: { _ in })
        tab.loadViewIfNeeded(); tab.render()
        let picker = ContactsViewController(model: model, onCall: { _ in }, onMessage: { _ in })
        picker.onSelect = { _ in }; picker.loadViewIfNeeded(); picker.render()
        #expect(picker.sections.first?.rows.count == 3)
        picker.navigationItem.searchController?.searchBar.text = "Alex"
        picker.updateSearchResults(for: picker.navigationItem.searchController!)
        picker.render(); tab.render()
        #expect(model.store.contactSearch == "Mina")
        #expect(tab.navigationItem.searchController?.searchBar.text == "Mina")
        #expect(tab.sections.first?.rows.map(\.title) == ["Mina Kim"])
        #expect(picker.sections.first?.rows.map(\.title) == ["Alex Rivera"])
    }

    @Test func `Multiline reply grows and contracts without replacing its text view`() {
        let model = AirSIMPreviewFixtures.presentation(tab: .messages)
        let thread = MessageThreadViewController(model: model, sender: "123")
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = UINavigationController(rootViewController: thread); window.makeKeyAndVisible()
        defer { window.isHidden = true }
        thread.loadViewIfNeeded(); thread.view.layoutIfNeeded()
        model.store.send(.messages(.replyChanged("First line\nSecond line\nThird line")))
        thread.render(); thread.view.layoutIfNeeded()
        #expect(thread.reply.bounds.height > 60)
        model.store.send(.messages(.replyChanged("")))
        thread.render(); thread.view.layoutIfNeeded()
        #expect(thread.reply.bounds.height == 32)
    }
}
