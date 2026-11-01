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

@MainActor
struct RecentsFeatureTests {
    private func snapshot() -> AirSIMSnapshot {
        var snapshot = AirSIMSnapshot()
        snapshot.contacts = ContactDirectory(all: AirSIMPreviewFixtures.contacts, isAuthorized: true, authorization: .authorized)
        snapshot.callHistory = AirSIMPreviewFixtures.history
        return snapshot
    }

    @Test func `A contact's call shows the contact name, a stranger's call shows the number`() {
        let state = RecentsFeature.State(snapshot: SharedReader(value: snapshot()))
        let mina = state.row(id: "preview-recent-1")
        #expect(mina?.name == "Mina Kim" && mina?.avatarName == "Mina Kim" && mina?.subtitle == "↙ AirSIM Audio")
        let stranger = state.row(id: "preview-recent-3")
        #expect(stranger?.name == "+1 202 555 0199" && stranger?.avatarName == "" && stranger?.subtitle == "↙ Missed")
    }

    @Test func `Calling back or messaging a recent asks the app shell, with the call's number`() async {
        let store = TestStore(initialState: RecentsFeature.State(snapshot: SharedReader(value: snapshot()))) { RecentsFeature() }
        await store.send(.view(.callTapped("preview-recent-2")))
        await store.receive(\.delegate.call, "+1 202 555 0102")
        await store.send(.view(.messageTapped("preview-recent-2")))
        await store.receive(\.delegate.message, "+1 202 555 0102")
    }

    @Test func `A call back from Recents switches to Dial, keeps the number as a draft and dials it`() async {
        let dialed = LockIsolated<[AirSIMCommand]>([])
        var client = AirSIMClient(snapshots: { AsyncStream { $0.finish() } }, command: { _ in }, sendSMS: { _, _ in .init(success: true) }, selfTest: { AsyncStream { $0.finish() } }, pairing: { AsyncStream { $0.finish() } }, pair: { _, _, _ in "" })
        client.command = { command in dialed.withValue { $0.append(command) } }
        let store = TestStore(initialState: AirSIMFeature.State(snapshot: snapshot())) { AirSIMFeature() } withDependencies: { $0.airSIM = client }
        await store.send(.recents(.view(.callTapped("preview-recent-2"))))
        await store.receive(\.recents.delegate.call) {
            $0.dial.number = "+1 202 555 0102"
            $0.dial.hasDraft = true
            $0.selectedTab = .dial
        }
        await store.finish()
        #expect(dialed.value.contains { if case .dialNumber("+1 202 555 0102") = $0 { true } else { false } })
        #expect(dialed.value.contains { if case .persistTab(.dial) = $0 { true } else { false } })
    }
}


@MainActor
struct DialFeatureTests {
    private func state(_ configure: (inout AirSIMSnapshot) -> Void = { _ in }) -> DialFeature.State {
        var snapshot = AirSIMSnapshot()
        configure(&snapshot)
        return DialFeature.State(snapshot: SharedReader(value: snapshot))
    }

    private func client(commands: LockIsolated<[AirSIMCommand]> = .init([])) -> AirSIMClient {
        AirSIMClient(
            snapshots: { AsyncStream { $0.finish() } },
            command: { command in commands.withValue { $0.append(command) } },
            sendSMS: { _, _ in .init(success: false) },
            selfTest: { AsyncStream { $0.finish() } },
            pairing: { AsyncStream { $0.finish() } },
            pair: { _, _, _ in "" }
        )
    }

    private func button(_ label: String, in view: UIView) -> UIButton? {
        if let button = view as? UIButton, button.accessibilityLabel == label { return button }
        return view.subviews.lazy.compactMap { self.button(label, in: $0) }.first
    }

    @Test func `Dial opens on the backend's number, and an edit is a draft only while it differs from it`() async {
        let store = TestStore(initialState: state { $0.numberInput = "12" }) { DialFeature() } withDependencies: {
            $0.airSIM = client()
        }
        #expect(store.state.number == "12" && store.state.lastBackendNumber == "12" && !store.state.hasDraft)
        await store.send(.view(.digitTapped("3"))) {
            $0.number = "123"
            $0.hasDraft = true
        }
        await store.send(.view(.digitTapped("+"))) { $0.number = "123+" }
        await store.send(.view(.deleteActivated)) { $0.number = "123" }
        await store.send(.view(.deleteActivated)) {
            $0.number = "12"
            $0.hasDraft = false
        }
    }

    @Test func `A backend number replaces the field only without a draft, and one equal to the field ends the draft`() {
        var dial = state()
        dial.reconcile(backendNumber: "100")
        #expect(dial.number == "100" && dial.lastBackendNumber == "100" && !dial.hasDraft)
        dial.edit("1001")
        #expect(dial.hasDraft)
        dial.reconcile(backendNumber: "200")
        #expect(dial.number == "1001" && dial.lastBackendNumber == "200" && dial.hasDraft)
        dial.reconcile(backendNumber: "1001")
        #expect(dial.number == "1001" && dial.lastBackendNumber == "1001" && !dial.hasDraft)
        // A tel: link marks its number a draft even when the backend already reports it.
        dial.hasDraft = true
        dial.reconcile(backendNumber: "1001")
        #expect(!dial.hasDraft)
    }

    @Test func `Holding Delete removes a digit at once, the next after 350 ms, then one every 90 ms until released`() async {
        let clock = TestClock()
        let store = TestStore(initialState: state { $0.numberInput = "123456" }) { DialFeature() } withDependencies: {
            $0.airSIM = client()
            $0.continuousClock = clock
        }
        await store.send(.view(.deletePressed)) {
            $0.number = "12345"
            $0.hasDraft = true
        }
        await clock.advance(by: .milliseconds(349))
        await clock.advance(by: .milliseconds(1))
        await store.receive(\.deleteRepeated) { $0.number = "1234" }
        await clock.advance(by: .milliseconds(89))
        await clock.advance(by: .milliseconds(1))
        await store.receive(\.deleteRepeated) { $0.number = "123" }
        await clock.advance(by: .milliseconds(90))
        await store.receive(\.deleteRepeated) { $0.number = "12" }
        await store.send(.view(.deleteReleased))
        await clock.advance(by: .seconds(1))
        await store.finish()
    }

    @Test func `Holding Delete stops once the number is empty`() async {
        let clock = TestClock()
        let store = TestStore(initialState: state { $0.numberInput = "12" }) { DialFeature() } withDependencies: {
            $0.airSIM = client()
            $0.continuousClock = clock
        }
        await store.send(.view(.deletePressed)) {
            $0.number = "1"
            $0.hasDraft = true
        }
        await clock.advance(by: .milliseconds(350))
        await store.receive(\.deleteRepeated) { $0.number = "" }
        await clock.advance(by: .milliseconds(90))
        await store.receive(\.deleteRepeated)
        await clock.advance(by: .seconds(1))
        await store.finish()
    }

    @Test func `Leaving the screen stops a held Delete, and VoiceOver's Delete removes exactly one digit`() async {
        let clock = TestClock()
        let store = TestStore(initialState: state { $0.numberInput = "123" }) { DialFeature() } withDependencies: {
            $0.airSIM = client()
            $0.continuousClock = clock
        }
        await store.send(.view(.deletePressed)) {
            $0.number = "12"
            $0.hasDraft = true
        }
        await store.send(.view(.disappeared))
        await clock.advance(by: .seconds(1))
        await store.send(.view(.deleteActivated)) { $0.number = "1" }
        await clock.advance(by: .seconds(1))
        await store.finish()
    }

    @Test func `Call dials the number shown when tapped, and choosing an agent binds it`() async {
        let commands = LockIsolated<[AirSIMCommand]>([])
        let store = TestStore(initialState: state { $0.numberInput = "12" }) { DialFeature() } withDependencies: {
            $0.airSIM = client(commands: commands)
        }
        await store.send(.view(.digitTapped("3"))) {
            $0.number = "123"
            $0.hasDraft = true
        }
        await store.send(.view(.callTapped))
        await store.send(.view(.agentChosen("preview-pixel")))
        await store.finish()
        #expect(commands.value.count == 2)
        #expect(commands.value.contains { if case .dialNumber("123") = $0 { true } else { false } })
        #expect(commands.value.contains { if case .bindAgent("preview-pixel") = $0 { true } else { false } })
    }

    @Test func `The number shows with its contact, and Call and Delete follow the number and the call route`() {
        let contacts = ContactDirectory(all: AirSIMPreviewFixtures.contacts, isAuthorized: true, authorization: .authorized)
        let empty = state {
            $0.contacts = contacts
            $0.canStartOutgoingCommand = true
        }
        #expect(empty.displayText == "Enter number" && empty.showsPlaceholder && empty.contactName == nil)
        #expect(!empty.canCall && empty.callIsDimmed && !empty.canDelete)
        let ready = state {
            $0.contacts = contacts
            $0.canStartOutgoingCommand = true
            $0.numberInput = "+1 202 555 0102"
        }
        #expect(ready.displayText == "+1 202 555 0102" && !ready.showsPlaceholder && ready.contactName == "Alex Rivera")
        #expect(ready.canCall && !ready.callIsDimmed && ready.canDelete && ready.playsInputClick)
        let busy = state {
            $0.canStartOutgoingCommand = true
            $0.isBusy = true
            $0.numberInput = "123"
        }
        #expect(!busy.canCall && !busy.callIsDimmed)
        let noRoute = state { $0.numberInput = "123" }
        #expect(!noRoute.canCall && noRoute.callIsDimmed)
        #expect(!state { $0.isMuted = true }.playsInputClick)
    }

    @Test func `The agent card and sheet show each agent's routes, with Cloud Off while cloud mode is disabled`() {
        let agents = AirSIMPreviewFixtures.agents
        let enabled = state {
            $0.pairedAndroidAgents = agents
            $0.currentAndroidAgent = agents[0]
            $0.cloudModeEnabled = true
        }
        #expect(enabled.showsAgentCard && enabled.currentAgent == agents[0] && enabled.agentCount == 2)
        #expect(enabled.cloudModeEnabled)
        #expect(enabled.agentRows.map(\.detail) == [
            "+1 202 555 0100\nVoWLAN Online · Cloud Online · Standalone",
            "Number unavailable\nVoWLAN Offline · Cloud Offline · Standalone",
        ])
        #expect(enabled.agentRows.map(\.title) == ["Samsung Galaxy", "Pixel 8 Pro"])
        #expect(enabled.agentRows.map(\.isCurrent) == [true, false])
        let disabled = state {
            $0.pairedAndroidAgents = agents
            $0.currentAndroidAgent = agents[0]
        }
        #expect(!disabled.cloudModeEnabled)
        #expect(disabled.agentRows.map(\.detail) == [
            "+1 202 555 0100\nVoWLAN Online · Cloud Off · Standalone",
            "Number unavailable\nVoWLAN Offline · Cloud Off · Standalone",
        ])
        #expect(!state().showsAgentCard)
        #expect(state { $0.currentAndroidAgent = agents[0] }.showsAgentCard)
    }

    @Test func `Dial's keys, Delete and Call send their actions from the screen`() async throws {
        let commands = LockIsolated<[AirSIMCommand]>([])
        let store = Store(initialState: state { $0.canStartOutgoingCommand = true }) { DialFeature() } withDependencies: {
            $0.airSIM = client(commands: commands)
            $0.continuousClock = TestClock()
        }
        let dial = DialPadViewController(store: store)
        dial.loadViewIfNeeded()
        for label in ["1", "2 ABC", "3 DEF"] {
            try #require(button(label, in: dial.view)).sendActions(for: .touchUpInside)
        }
        let delete = try #require(button("Delete", in: dial.view))
        delete.sendActions(for: .touchDown)
        delete.sendActions(for: .touchUpInside)
        #expect(store.number == "12")
        try #require(button("Dial", in: dial.view)).sendActions(for: .touchUpInside)
        #expect(try await eventually { commands.value.isEmpty ? nil : true } == true)
        #expect(commands.value.contains { if case .dialNumber("12") = $0 { true } else { false } })
    }

    @Test func `Choosing a row in the Paired Android Agents sheet binds that agent`() async throws {
        let commands = LockIsolated<[AirSIMCommand]>([])
        let agents = AirSIMPreviewFixtures.agents
        let store = Store(initialState: state { $0.pairedAndroidAgents = agents }) { DialFeature() } withDependencies: {
            $0.airSIM = client(commands: commands)
        }
        let sheet = PairedAndroidAgentsViewController(store: store)
        sheet.loadViewIfNeeded()
        sheet.render()
        sheet.tableView(sheet.table, didSelectRowAt: IndexPath(row: 1, section: 0))
        #expect(try await eventually { commands.value.isEmpty ? nil : true } == true)
        #expect(commands.value.contains { if case .bindAgent("preview-pixel") = $0 { true } else { false } })
    }
}

@MainActor
struct ContactsFeatureTests {
    /// The preview contacts unless `contacts` says otherwise.
    private func snapshot(
        _ contacts: [ContactStore.Contact]? = nil,
        authorization: ContactAuthorizationState = .authorized
    ) -> SharedReader<AirSIMSnapshot> {
        var snapshot = AirSIMSnapshot()
        snapshot.contacts = ContactDirectory(
            all: contacts ?? AirSIMPreviewFixtures.contacts,
            isAuthorized: authorization == .authorized,
            authorization: authorization
        )
        return SharedReader(value: snapshot)
    }

    private func client(contactRequests: LockIsolated<[Bool]>) -> AirSIMClient {
        AirSIMClient(
            snapshots: { AsyncStream { $0.finish() } },
            command: { command in
                if case .contacts(let request) = command { contactRequests.withValue { $0.append(request) } }
            },
            sendSMS: { _, _ in .init(success: true) },
            selfTest: { AsyncStream { $0.finish() } },
            pairing: { AsyncStream { $0.finish() } },
            pair: { _, _, _ in "" }
        )
    }

    @Test func `Search trims the query and matches a name or any number, ignoring case`() {
        let directory = ContactDirectory(all: AirSIMPreviewFixtures.contacts, isAuthorized: true, authorization: .authorized)
        #expect(directory.contacts(matching: "   ").map(\.name) == ["Mina Kim", "Alex Rivera"])
        #expect(directory.contacts(matching: "  alex").map(\.name) == ["Alex Rivera"])
        // Only Mina's second number contains 0101.
        #expect(directory.contacts(matching: "0101 ").map(\.name) == ["Mina Kim"])
        #expect(directory.contacts(matching: "+1202555").map(\.name) == ["Mina Kim", "Alex Rivera"])
        #expect(directory.contacts(matching: "Sam").isEmpty)
    }

    @Test func `The tab lists each contact once, the picker each of its numbers once`() {
        let sam = ContactStore.Contact(
            id: "sam", name: "Sam Lee", phones: ["+12025550110", "+12025550110", "+12025550111"], emails: [], photoData: nil
        )
        let tab = ContactsFeature.State(mode: .browse, snapshot: snapshot([sam]))
        #expect(tab.rows.map(\.id) == ["sam"])
        #expect(tab.rows.map(\.phone) == ["+12025550110"])
        #expect(tab.rows.first?.phones == ["+12025550110", "+12025550111"])
        let picker = ContactsFeature.State(mode: .pick, snapshot: snapshot([sam]))
        #expect(picker.rows.map(\.id) == ["sam+12025550110", "sam+12025550111"])
        #expect(picker.rows.map(\.phone) == ["+12025550110", "+12025550111"])
    }

    @Test func `Without contacts access the screen asks for it, or for Settings once denied`() {
        #expect(ContactsFeature.State(mode: .browse, snapshot: snapshot()).accessPrompt == nil)
        #expect(ContactsFeature.State(mode: .browse, snapshot: snapshot(authorization: .notDetermined)).accessPrompt == .allowAccess)
        #expect(ContactsFeature.State(mode: .pick, snapshot: snapshot(authorization: .denied)).accessPrompt == .openSettings)
    }

    @Test func `Appearing loads contacts only if allowed; refresh and Allow Access ask for access`() async {
        let requests = LockIsolated<[Bool]>([])
        let store = TestStore(initialState: ContactsFeature.State(mode: .browse, snapshot: snapshot())) {
            ContactsFeature()
        } withDependencies: {
            $0.airSIM = client(contactRequests: requests)
        }
        await store.send(.view(.appeared)).finish()
        await store.send(.view(.refreshPulled)).finish()
        await store.send(.view(.allowAccessTapped)).finish()
        #expect(requests.value == [false, true, true])
    }

    @Test func `Detail calls and messages, and picker choices, go to the parent with the number`() async {
        let store = TestStore(initialState: ContactsFeature.State(mode: .pick, snapshot: snapshot())) { ContactsFeature() }
        await store.send(.view(.phoneChosen("+12025550101")))
        await store.receive(\.delegate.picked, "+12025550101")
        await store.send(.view(.callTapped("+12025550102")))
        await store.receive(\.delegate.call, "+12025550102")
        await store.send(.view(.messageTapped("+12025550102")))
        await store.receive(\.delegate.message, "+12025550102")
    }

    @Test func `Each picker opens with an empty search, and a choice addresses the composer and closes it`() async {
        let reader = snapshot()
        let store = TestStore(initialState: ComposerFeature.State(recipient: "", snapshot: reader)) { ComposerFeature() }
        await store.send(.view(.chooseContactTapped)) { $0.contactPicker = ContactsFeature.State(mode: .pick, snapshot: reader) }
        await store.send(.contactPicker(.presented(.view(.searchChanged("Alex"))))) { $0.contactPicker?.search = "Alex" }
        await store.send(.contactPicker(.presented(.view(.phoneChosen("+12025550102")))))
        await store.receive(\.contactPicker.presented.delegate.picked) {
            $0.recipient = "+12025550102"
            $0.contactPicker = nil
        }
        await store.send(.view(.chooseContactTapped)) { $0.contactPicker = ContactsFeature.State(mode: .pick, snapshot: reader) }
    }

    @Test func `A call from Contacts dials on the Dial tab, and a message opens the composer`() async {
        let commands = LockIsolated<[AirSIMCommand]>([])
        var dependency = client(contactRequests: LockIsolated([]))
        dependency.command = { command in commands.withValue { $0.append(command) } }
        var state = AirSIMFeature.State(snapshot: snapshot().wrappedValue)
        state.firstConnectionComplete = true
        let store = TestStore(initialState: state) { AirSIMFeature() } withDependencies: { $0.airSIM = dependency }
        await store.send(.contacts(.view(.callTapped("+12025550102"))))
        await store.receive(\.contacts.delegate.call) {
            $0.dial.number = "+12025550102"
            $0.dial.hasDraft = true
            $0.selectedTab = .dial
        }
        await store.send(.contacts(.view(.messageTapped("+12025550101"))))
        await store.receive(\.contacts.delegate.message) {
            $0.selectedTab = .messages
            $0.messages.composer = ComposerFeature.State(recipient: "+12025550101", snapshot: SharedReader($0.$snapshot))
        }
        await store.finish()
        #expect(commands.value.contains { if case .dialNumber("+12025550102") = $0 { true } else { false } })
        #expect(commands.value.contains { if case .persistTab(.dial) = $0 { true } else { false } })
        #expect(commands.value.contains { if case .persistTab(.messages) = $0 { true } else { false } })
    }
}

@MainActor
struct MessagesFeatureTests {
    private let stranger = "+1 202 555 0199"

    /// The preview contacts unless `contacts` says otherwise.
    private func snapshot(
        contacts: [ContactStore.Contact]? = nil,
        messages: [SMSMessage] = [],
        conversations: [ConversationSnapshot] = []
    ) -> AirSIMSnapshot {
        var snapshot = AirSIMSnapshot()
        snapshot.contacts = ContactDirectory(
            all: contacts ?? AirSIMPreviewFixtures.contacts,
            isAuthorized: true,
            authorization: .authorized
        )
        snapshot.messages = messages
        snapshot.conversations = conversations
        return snapshot
    }

    private func client(commands: LockIsolated<[AirSIMCommand]>) -> AirSIMClient {
        AirSIMClient(
            snapshots: { AsyncStream { $0.finish() } },
            command: { command in commands.withValue { $0.append(command) } },
            sendSMS: { _, _ in .init(success: true) },
            selfTest: { AsyncStream { $0.finish() } },
            pairing: { AsyncStream { $0.finish() } },
            pair: { _, _, _ in "" }
        )
    }

    @Test func `A contact's conversation shows the contact, a stranger's the number, each with its last message and time`() {
        let late = SMSMessage(
            sender: stranger, content: "Who is this?", code: nil,
            timestamp: AirSIMPreviewFixtures.date, deliveryID: "stranger-1", direction: .incoming
        )
        let state = MessagesFeature.State(snapshot: SharedReader(value: snapshot(conversations: [
            ConversationSnapshot(sender: AirSIMPreviewFixtures.phone, messages: AirSIMPreviewFixtures.messages),
            ConversationSnapshot(sender: stranger, messages: [late]),
        ])))
        let rows = state.conversationRows
        #expect(rows.map(\.id) == [AirSIMPreviewFixtures.phone, stranger])
        let lastFromMina = AirSIMPreviewFixtures.messages[2]
        let minaTime = lastFromMina.timestamp.formatted(date: .omitted, time: .shortened)
        #expect(rows[0].name == "Mina Kim" && rows[0].avatarName == "Mina Kim")
        #expect(rows[0].lastMessage == "Perfect, see you there." && rows[0].time == minaTime)
        #expect(rows[0].detail == "Perfect, see you there.\n\(minaTime)")
        #expect(rows[1].name == stranger && rows[1].avatarName == "" && rows[1].photo == nil)
        #expect(rows[1].lastMessage == "Who is this?")
    }

    @Test func `A thread shows only its sender's messages, oldest first, under the contact's name`() {
        let other = SMSMessage(
            sender: stranger, content: "Not for Mina", code: nil,
            timestamp: AirSIMPreviewFixtures.date, deliveryID: "stranger-1", direction: .incoming
        )
        let messages = [other] + AirSIMPreviewFixtures.messages.reversed()
        let state = MessagesFeature.State(snapshot: SharedReader(value: snapshot(messages: messages)))
        #expect(state.messages(from: AirSIMPreviewFixtures.phone) == AirSIMPreviewFixtures.messages)
        #expect(state.threadTitle(for: AirSIMPreviewFixtures.phone) == "Mina Kim")
        #expect(state.threadTitle(for: stranger) == stranger)
    }

    @Test func `Send is enabled for a reply with text while no reply is sending`() {
        var state = MessagesFeature.State(snapshot: SharedReader(value: snapshot()))
        state.reply = " \n "
        #expect(!state.canSendReply)
        state.reply = "On my way"
        #expect(state.canSendReply)
        state.sending = true
        #expect(!state.canSendReply)
    }

    @Test func `The list loads messages when it appears, and Refresh and Clear all SMS run their commands`() async {
        let commands = LockIsolated<[AirSIMCommand]>([])
        let store = TestStore(initialState: MessagesFeature.State(snapshot: SharedReader(value: snapshot()))) {
            MessagesFeature()
        } withDependencies: {
            $0.airSIM = client(commands: commands)
        }
        await store.send(.view(.appeared)).finish()
        await store.send(.view(.refreshTapped)).finish()
        await store.send(.view(.clearConfirmed)).finish()
        #expect(commands.value.map { "\($0)" } == ["loadMessages", "refreshMessages", "clearMessages"])
    }

    @Test func `Tapping the open conversation keeps the composer, and closing an old thread keeps the open one`() async {
        let reader = SharedReader(value: snapshot())
        var state = MessagesFeature.State(snapshot: reader)
        state.conversation = "X"
        state.reply = "draft"
        state.composer = ComposerFeature.State(recipient: "Y", body: "Composer draft", snapshot: reader)
        let store = TestStore(initialState: state) { MessagesFeature() }
        await store.send(.view(.conversationTapped("X")))
        await store.send(.view(.threadLoaded("X")))
        await store.send(.view(.conversationTapped("Z"))) {
            $0.conversation = "Z"
            $0.reply = ""
            $0.composer = nil
        }
        await store.send(.view(.threadClosed("X")))
        await store.send(.view(.threadLoaded("W"))) { $0.conversation = "W" }
    }

    @Test func `The compose button opens an empty composer on the Messages tab once onboarding is done`() async {
        let commands = LockIsolated<[AirSIMCommand]>([])
        var state = AirSIMFeature.State()
        state.firstConnectionComplete = true
        let store = TestStore(initialState: state) { AirSIMFeature() } withDependencies: {
            $0.airSIM = client(commands: commands)
        }
        await store.send(.messages(.view(.composeTapped)))
        await store.receive(\.messages.delegate.compose, "") {
            $0.selectedTab = .messages
            $0.messages.composer = ComposerFeature.State(recipient: "", snapshot: SharedReader($0.$snapshot))
        }
        await store.finish()
        #expect(commands.value.count == 1)
        #expect(commands.value.contains { if case .persistTab(.messages) = $0 { true } else { false } })

        let onboarding = TestStore(initialState: AirSIMFeature.State()) { AirSIMFeature() } withDependencies: {
            $0.airSIM = client(commands: LockIsolated([]))
        }
        await onboarding.send(.messages(.view(.composeTapped)))
        await onboarding.receive(\.messages.delegate.compose, "") {
            $0.selectedTab = .messages
            $0.pendingComposeRecipient = ""
        }
        await onboarding.finish()
    }

    @Test func `Suggestions match the trimmed recipient by name or number, at most five, until it names a contact`() {
        let people = (1...7).map { index in
            ContactStore.Contact(
                id: "lee-\(index)", name: "Lee \(index)", phones: ["+1202555090\(index)"], emails: [], photoData: nil
            )
        }
        let directory = ContactDirectory(
            all: AirSIMPreviewFixtures.contacts + people,
            isAuthorized: true,
            authorization: .authorized
        )
        #expect(directory.suggestions(for: "   ").isEmpty)
        #expect(directory.suggestions(for: " alex ").map(\.name) == ["Alex Rivera"])
        #expect(directory.suggestions(for: "0102").map(\.name) == ["Alex Rivera"])
        #expect(directory.suggestions(for: "lee").map(\.name) == ["Lee 1", "Lee 2", "Lee 3", "Lee 4", "Lee 5"])
        // A recipient that already names a contact needs no suggestions, even when others match it.
        #expect(directory.suggestions(for: "+12025550102").isEmpty)
        #expect(directory.suggestions(for: "+1202555").map(\.name) == ["Mina Kim", "Alex Rivera", "Lee 1", "Lee 2", "Lee 3"])
    }

    @Test func `The composer names a recognized contact, and a suggestion addresses its first number or the typed text`() {
        let noNumber = ContactStore.Contact(id: "sam", name: "Sam Lee", phones: [], emails: [], photoData: nil)
        let reader = SharedReader(value: snapshot(contacts: AirSIMPreviewFixtures.contacts + [noNumber]))
        let recognized = ComposerFeature.State(recipient: "+1 202 555 0102", snapshot: reader)
        #expect(recognized.recognizedName == "Alex Rivera" && recognized.suggestions.isEmpty)
        let typing = ComposerFeature.State(recipient: " mi ", snapshot: reader)
        #expect(typing.recognizedName == nil)
        #expect(typing.suggestions == [.init(name: "Mina Kim", phone: "+12025550100", recipient: "+12025550100")])
        let unnumbered = ComposerFeature.State(recipient: " Sam ", snapshot: reader)
        #expect(unnumbered.suggestions == [.init(name: "Sam Lee", phone: nil, recipient: "Sam")])
    }

    @Test func `Opening the composer loads contacts only if allowed`() async {
        let commands = LockIsolated<[AirSIMCommand]>([])
        let store = TestStore(initialState: ComposerFeature.State(recipient: "", snapshot: SharedReader(value: snapshot()))) {
            ComposerFeature()
        } withDependencies: {
            $0.airSIM = client(commands: commands)
        }
        await store.send(.view(.opened)).finish()
        #expect(commands.value.map { "\($0)" } == ["contacts(false)"])
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
    /// Shared readers compare by value, so states built with this equal the ones reducers build from an empty snapshot.
    private let snapshot = SharedReader(value: AirSIMSnapshot())
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

    private func composing(_ recipient: String, body: String = "", sendID: UUID? = nil) -> MessagesFeature.State {
        var state = MessagesFeature.State(snapshot: snapshot); state.composer = ComposerFeature.State(recipient: recipient, body: body, sendID: sendID, snapshot: snapshot); return state
    }

    @Test func `Failed SMS send preserves draft and releases sending state`() async {
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let store = TestStore(initialState: composing("+12025550100", body: "Keep this draft")) { MessagesFeature() } withDependencies: {
            $0.airSIM = client(); $0.uuid = .constant(id)
        }
        await store.send(.composer(.presented(.view(.sendButtonTapped)))) { $0.composer?.sendID = id }
        await store.receive(\.composer.presented.delegate)
        await store.receive(\.composerSendFinished) {
            $0.composer?.sendID = nil
            $0.composer?.alert = .sendFailed("Unable to send message. Your draft has been kept.")
        }
        #expect(store.state.composer?.body == "Keep this draft")
        #expect(store.state.composer?.recipient == "+12025550100")
        #expect(store.state.composer?.sending == false)
    }

    @Test func `SMS failure retains the backend reason and draft`() async {
        let id = UUID()
        var dependency = client()
        dependency.sendSMS = { _, _ in .init(success: false, error: "Cloud mode is disabled") }
        let store = TestStore(initialState: composing("123", body: "Keep me")) { MessagesFeature() } withDependencies: { $0.airSIM = dependency; $0.uuid = .constant(id) }
        await store.send(.composer(.presented(.view(.sendButtonTapped)))) { $0.composer?.sendID = id }
        await store.receive(\.composer.presented.delegate)
        await store.receive(\.composerSendFinished) { $0.composer?.sendID = nil; $0.composer?.alert = .sendFailed("Cloud mode is disabled") }
        #expect(store.state.composer?.body == "Keep me")
    }

    @Test func `Composer send closes it on success and its alert OK only closes the alert`() async {
        let commands = LockIsolated<[String]>([])
        var dependency = client(sendResult: true)
        dependency.command = { command in commands.withValue { $0.append("\(command)") } }
        let store = TestStore(initialState: composing("123", body: "Hi")) { MessagesFeature() } withDependencies: { $0.airSIM = dependency; $0.uuid = .incrementing }
        await store.send(.composer(.presented(.view(.sendButtonTapped)))) { $0.composer?.sendID = UUID(0) }
        await store.receive(\.composer.presented.delegate)
        await store.receive(\.composerSendFinished) { $0.composer = nil }
        var failed = composing("123", body: "Hi"); failed.composer?.alert = .sendFailed("Offline")
        let alerting = TestStore(initialState: failed) { MessagesFeature() } withDependencies: { $0.airSIM = dependency }
        await alerting.send(.composer(.presented(.alert(.presented(.ok))))) { $0.composer?.alert = nil }
        await alerting.finish()
        // The send's failure never reached the shared backend error, so there is nothing to clear.
        #expect(commands.value.isEmpty)
    }

    @Test func `Updating the recipient of an open composer preserves its body`() async {
        let store = TestStore(initialState: composing("old", body: "Keep this text")) { MessagesFeature() } withDependencies: { $0.airSIM = client() }
        await store.send(.compose("new")) { $0.composer?.recipient = "new" }
        #expect(store.state.composer?.body == "Keep this text")
    }

    @Test func `Closing the composer mid-send neither cancels the SMS nor applies it to a later composer`() async {
        let release = AsyncStream<Void>.makeStream()
        let sent = LockIsolated<[String]>([])
        var dependency = client(sendResult: false)
        dependency.sendSMS = { to, body in
            for await _ in release.stream { break }
            sent.withValue { $0.append("\(to):\(body):\(Task.isCancelled ? "cancelled" : "delivered")") }
            return .init(success: false, error: "Late failure")
        }
        let store = TestStore(initialState: composing("123", body: "On my way")) { MessagesFeature() } withDependencies: { $0.airSIM = dependency; $0.uuid = .incrementing }
        await store.send(.composer(.presented(.view(.sendButtonTapped)))) { $0.composer?.sendID = UUID(0) }
        await store.receive(\.composer.presented.delegate)
        await store.send(.composer(.presented(.view(.cancelButtonTapped))))
        await store.receive(\.composer.dismiss) { $0.composer = nil }
        await store.send(.compose("456")) { $0.composer = ComposerFeature.State(recipient: "456", snapshot: snapshot) }
        release.continuation.yield()
        await store.receive(\.composerSendFinished)
        // Its screen is gone, so the root alert reports it without promising a kept draft.
        await store.receive(\.delegate.unreportedSendFailure, "Late failure")
        #expect(sent.value == ["123:On my way:delivered"])
        #expect(store.state.composer == ComposerFeature.State(recipient: "456", snapshot: snapshot))
    }

    @Test func `Readdressing a composer mid-send detaches that send from it`() async {
        let release = AsyncStream<Void>.makeStream()
        let result = LockIsolated(AirSIMMessageResult(success: true))
        var dependency = client()
        dependency.sendSMS = { _, _ in for await _ in release.stream { break }; return result.value }
        let store = TestStore(initialState: composing("A", body: "On my way")) { MessagesFeature() } withDependencies: { $0.airSIM = dependency; $0.uuid = .incrementing }
        await store.send(.composer(.presented(.view(.sendButtonTapped)))) { $0.composer?.sendID = UUID(0) }
        await store.receive(\.composer.presented.delegate)
        // A's success must not close the composer the user just addressed to B.
        await store.send(.compose("B")) { $0.composer?.recipient = "B"; $0.composer?.sendID = nil }
        release.continuation.yield()
        await store.receive(\.composerSendFinished)
        // Nor may a failure alert there with B's address; the root alert reports it.
        await store.send(.composer(.presented(.view(.sendButtonTapped)))) { $0.composer?.sendID = UUID(1) }
        await store.receive(\.composer.presented.delegate)
        await store.send(.compose("C")) { $0.composer?.recipient = "C"; $0.composer?.sendID = nil }
        result.setValue(.init(success: false, error: "Offline"))
        release.continuation.yield()
        await store.receive(\.composerSendFinished)
        await store.receive(\.delegate.unreportedSendFailure, "Offline")
        #expect(store.state.composer == ComposerFeature.State(recipient: "C", body: "On my way", snapshot: snapshot))
        // Composing to the same recipient keeps the send attached, so its success still closes the composer.
        result.setValue(.init(success: true))
        await store.send(.composer(.presented(.view(.sendButtonTapped)))) { $0.composer?.sendID = UUID(2) }
        await store.receive(\.composer.presented.delegate)
        await store.send(.compose("C"))
        release.continuation.yield()
        await store.receive(\.composerSendFinished) { $0.composer = nil }
    }

    @Test func `Visible thread reply retains its recipient if route state was cleared`() async {
        let id = UUID(); let recipients = LockIsolated<[String]>([])
        var state = MessagesFeature.State(snapshot: snapshot); state.reply = "Still addressed"
        var dependency = client()
        dependency.sendSMS = { to, _ in recipients.withValue { $0.append(to) }; return .init(success: true) }
        let store = TestStore(initialState: state) { MessagesFeature() } withDependencies: { $0.airSIM = dependency; $0.uuid = .constant(id) }
        await store.send(.view(.sendTapped(to: "123"))) { $0.sending = true; $0.sendID = id }
        await store.receive(\.sendResponse) { $0.reply = ""; $0.sending = false; $0.sendID = nil }
        #expect(recipients.value == ["123"])
    }

    @Test func `Old SMS completion cannot close a newly opened composer`() async {
        let oldID = UUID()
        let store = TestStore(initialState: composing("old", body: "old body", sendID: oldID)) { MessagesFeature() } withDependencies: { $0.airSIM = client() }
        await store.send(.composer(.dismiss)) { $0.composer = nil }
        await store.send(.compose("new")) { $0.composer = ComposerFeature.State(recipient: "new", snapshot: snapshot) }
        await store.send(.composer(.presented(.view(.bodyChanged("new draft"))))) { $0.composer?.body = "new draft" }
        await store.send(.composerSendFinished(id: oldID, result: .init(success: true)))
        await store.send(.composerSendFinished(id: oldID, result: .init(success: false, error: "Old failure")))
        await store.receive(\.delegate.unreportedSendFailure, "Old failure")
        #expect(store.state.composer?.body == "new draft")
        #expect(store.state.composer?.alert == nil)
    }

    @Test func `Old reply completion cannot clear another conversation draft`() async {
        let oldID = UUID()
        var state = MessagesFeature.State(snapshot: snapshot)
        state.conversation = "old"; state.reply = "same text"; state.sending = true; state.sendID = oldID
        let store = TestStore(initialState: state) { MessagesFeature() } withDependencies: { $0.airSIM = client() }
        await store.send(.openConversation("new")) { $0.conversation = "new"; $0.reply = ""; $0.sending = false; $0.sendID = nil }
        await store.send(.view(.replyChanged("same text"))) { $0.reply = "same text" }
        await store.send(.sendResponse(id: oldID, success: true, body: "same text"))
        #expect(store.state.reply == "same text")
    }

    @Test func `Composing elsewhere keeps a thread reply in flight`() async {
        let replyID = UUID()
        var state = MessagesFeature.State(snapshot: snapshot)
        state.conversation = "X"; state.reply = "On my way"; state.sending = true; state.sendID = replyID
        let store = TestStore(initialState: state) { MessagesFeature() } withDependencies: { $0.airSIM = client() }
        await store.send(.compose("Y")) { $0.composer = ComposerFeature.State(recipient: "Y", snapshot: snapshot) }
        // The delivered reply must not stay in the field with Send enabled.
        await store.send(.sendResponse(id: replyID, success: true, body: "On my way")) {
            $0.reply = ""; $0.sending = false; $0.sendID = nil
        }
    }

    @Test func `Reopening the visible conversation closes the composer and keeps the thread draft`() async {
        var state = composing("Y", body: "Composer draft", sendID: UUID())
        state.conversation = "X"; state.reply = "draft"; state.composer?.alert = .sendFailed("Composer failure")
        let store = TestStore(initialState: state) { MessagesFeature() } withDependencies: { $0.airSIM = client() }
        await store.send(.openConversation("X")) { $0.composer = nil }
        #expect(store.state.reply == "draft")
        #expect(store.state.alert == nil)
    }

    @Test func `Reopening the visible conversation keeps its draft and send`() async {
        let replyID = UUID()
        var state = MessagesFeature.State(snapshot: snapshot)
        state.conversation = "X"; state.reply = "draft"; state.sending = true; state.sendID = replyID
        let store = TestStore(initialState: state) { MessagesFeature() } withDependencies: { $0.airSIM = client() }
        await store.send(.openConversation("X"))
        await store.send(.sendResponse(id: replyID, success: false, body: "draft", error: "Offline")) {
            $0.sending = false; $0.sendID = nil; $0.alert = .sendFailed("Offline")
        }
        #expect(store.state.reply == "draft")
    }

    @Test func `Thread failure alerts in its thread, and above an open composer or from root once the thread is gone`() async {
        let result = LockIsolated(AirSIMMessageResult(success: false, error: "Cloud mode is disabled"))
        let release = AsyncStream<Void>.makeStream()
        var dependency = client()
        dependency.sendSMS = { _, body in if body == "late" { for await _ in release.stream { break } }; return result.value }
        var state = MessagesFeature.State(snapshot: snapshot); state.conversation = "X"; state.reply = "draft"
        let store = TestStore(initialState: state) { MessagesFeature() } withDependencies: { $0.airSIM = dependency; $0.uuid = .incrementing }
        await store.send(.view(.sendTapped(to: "X"))) { $0.sending = true; $0.sendID = UUID(0) }
        await store.receive(\.sendResponse) { $0.sending = false; $0.sendID = nil; $0.alert = .sendFailed("Cloud mode is disabled") }
        await store.send(.alert(.presented(.ok))) { $0.alert = nil }
        // The thread would present from beneath the composer sheet and replace it.
        await store.send(.compose("Y")) { $0.composer = ComposerFeature.State(recipient: "Y", snapshot: snapshot) }
        result.setValue(.init(success: false))
        await store.send(.view(.sendTapped(to: "X"))) { $0.sending = true; $0.sendID = UUID(1) }
        await store.receive(\.sendResponse) { $0.sending = false; $0.sendID = nil }
        await store.receive(\.delegate.unreportedSendFailure, "Unable to send message. Your draft has been kept.")
        #expect(store.state.reply == "draft" && store.state.alert == nil)
        await store.send(.composer(.dismiss)) { $0.composer = nil }
        // A thread alert closes with its conversation.
        await store.send(.view(.sendTapped(to: "X"))) { $0.sending = true; $0.sendID = UUID(2) }
        await store.receive(\.sendResponse) { $0.sending = false; $0.sendID = nil; $0.alert = .sendFailed("Unable to send message. Your draft has been kept.") }
        await store.send(.openConversation("Z")) { $0.conversation = "Z"; $0.reply = ""; $0.alert = nil }
        // A reply still sending when its thread closes reports to the root alert.
        await store.send(.view(.replyChanged("late"))) { $0.reply = "late" }
        result.setValue(.init(success: false, error: "Offline"))
        await store.send(.view(.sendTapped(to: "Z"))) { $0.sending = true; $0.sendID = UUID(3) }
        await store.send(.view(.threadClosed("Z"))) { $0.conversation = nil; $0.sending = false; $0.sendID = nil }
        release.continuation.yield()
        await store.receive(\.sendResponse)
        await store.receive(\.delegate.unreportedSendFailure, "Offline")
    }

    @Test func `Recording failure alerts once and OK closes it`() async {
        var dependency = client()
        dependency.command = { _ in throw CocoaError(.fileReadCorruptFile) }
        let store = TestStore(initialState: RecordingsFeature.State(snapshot: SharedReader(value: AirSIMSnapshot()))) { RecordingsFeature() } withDependencies: { $0.airSIM = dependency }
        await store.send(.view(.refreshPulled))
        await store.receive(\.failed) { $0.alert = .error(CocoaError(.fileReadCorruptFile).localizedDescription, title: "Recording Error", ok: .ok) }
        await store.send(.alert(.presented(.ok))) { $0.alert = nil }
    }

    @Test func `Changing mode cancels streaming self test without completing it`() async {
        let store = TestStore(initialState: SettingsFeature.State(snapshot: snapshot)) { SettingsFeature() } withDependencies: { $0.airSIM = client() }
        await store.send(.view(.runSelfTestTapped)) { $0.selfTestRunning = true; $0.report = .initial }
        await store.send(.view(.modeChanged(.vowlan))) { $0.mode = .vowlan; $0.selfTestRunning = false; $0.report = nil }
        await store.finish()
        #expect(!store.state.selfTestCompleted)
    }

    @Test func `Open conversation selects destination without sharing composer state`() async {
        let store = TestStore(initialState: MessagesFeature.State(snapshot: snapshot)) { MessagesFeature() } withDependencies: { $0.airSIM = client() }
        await store.send(.openConversation("+12025550100")) { $0.conversation = "+12025550100" }
        #expect(store.state.composer == nil)
    }
}

@MainActor
struct TCARootNavigationTests {
    /// Shared readers compare by value, so states built with this equal the ones reducers build from an empty snapshot.
    private let snapshot = SharedReader(value: AirSIMSnapshot())
    private var client: AirSIMClient {
        AirSIMClient(snapshots: { AsyncStream { _ in } }, command: { _ in }, sendSMS: { _, _ in .init(success: false) }, selfTest: { AsyncStream { $0.finish() } }, pairing: { AsyncStream { $0.finish() } }, pair: { _, _, _ in "" })
    }
    @Test func `Cold im link selects Messages and presents composer from state`() async {
        var state = AirSIMFeature.State(); state.firstConnectionComplete = true
        let store = TestStore(initialState: state) { AirSIMFeature() } withDependencies: { $0.airSIM = client }
        await store.send(.openURL(URL(string: "im:+12025550100")!)) {
            $0.selectedTab = .messages; $0.messages.composer = ComposerFeature.State(recipient: "+12025550100", snapshot: snapshot)
        }
        await store.finish()
    }
    @Test func `Compose during onboarding waits until onboarding completes`() async {
        let store = TestStore(initialState: AirSIMFeature.State()) { AirSIMFeature() } withDependencies: { $0.airSIM = client }
        // The onboarding screen covers the tabs; presenting the composer now would dismiss it.
        await store.send(.composeMessage("+12025550100")) { $0.selectedTab = .messages; $0.pendingComposeRecipient = "+12025550100" }
        await store.send(.openURL(URL(string: "im:+12025550101")!)) { $0.pendingComposeRecipient = "+12025550101" }
        await store.send(.settings(.view(.pairLaterTapped)))
        await store.receive(\.settings.delegate.onboardingCompleted) {
            $0.firstConnectionComplete = true; $0.pendingComposeRecipient = nil
            $0.messages.composer = ComposerFeature.State(recipient: "+12025550101", snapshot: snapshot)
        }
        await store.finish()
    }
    @Test func `Compose readdresses an open composer and keeps its draft`() async {
        var state = AirSIMFeature.State(); state.firstConnectionComplete = true
        state.messages.composer = ComposerFeature.State(recipient: "old", body: "Keep this text", snapshot: snapshot)
        let store = TestStore(initialState: state) { AirSIMFeature() } withDependencies: { $0.airSIM = client }
        await store.send(.composeMessage("new")) { $0.selectedTab = .messages; $0.messages.composer?.recipient = "new" }
        await store.finish()
    }
    @Test func `OK on an older backend alert cannot clear a newer backend error`() async {
        // Like AppModel, the fake backend clears an error only while it is still the current one.
        let backend = LockIsolated<String?>("Old failure")
        let cleared = LockIsolated<[String]>([])
        var dependency = client
        dependency.command = { command in
            guard case .clearError(let error) = command else { return }
            cleared.withValue { $0.append(error) }; backend.withValue { if $0 == error { $0 = nil } }
        }
        let store = TestStore(initialState: AirSIMFeature.State()) { AirSIMFeature() } withDependencies: { $0.airSIM = dependency }
        var old = AirSIMSnapshot(); old.errorMessage = "Old failure"
        await store.send(.snapshot(old)) { $0.$snapshot.withLock { $0 = old }; $0.lastBackendError = "Old failure"; $0.alert = .error("Old failure", ok: .clearBackendError("Old failure")) }
        // Later snapshots carrying the same error do not alert again.
        var muted = old; muted.isMuted = true
        await store.send(.snapshot(muted)) { $0.$snapshot.withLock { $0 = muted } }
        // A newer error is recorded before OK on the older alert reaches the backend.
        backend.setValue("New failure")
        await store.send(.alert(.presented(.clearBackendError("Old failure")))) { $0.alert = nil }
        await store.finish()
        #expect(cleared.value == ["Old failure"] && backend.value == "New failure")
        var new = muted; new.errorMessage = "New failure"
        await store.send(.snapshot(new)) { $0.$snapshot.withLock { $0 = new }; $0.lastBackendError = "New failure"; $0.alert = .error("New failure", ok: .clearBackendError("New failure")) }
        await store.send(.alert(.presented(.clearBackendError("New failure")))) { $0.alert = nil }
        await store.finish()
        #expect(backend.value == nil)
        var cleaned = new; cleaned.errorMessage = nil
        await store.send(.snapshot(cleaned)) { $0.$snapshot.withLock { $0 = cleaned }; $0.lastBackendError = nil }
    }
    @Test func `Command failure alerts without clearing the backend error`() async {
        let cleared = LockIsolated(0)
        var dependency = client
        dependency.command = { command in
            if case .clearError = command { cleared.withValue { $0 += 1 } }
            if case .forgetDevice = command { throw CocoaError(.featureUnsupported) }
        }
        var snapshot = AirSIMSnapshot(); snapshot.errorMessage = "Backend failure"; var state = AirSIMFeature.State(snapshot: snapshot); state.lastBackendError = "Backend failure"
        let store = TestStore(initialState: state) { AirSIMFeature() } withDependencies: { $0.airSIM = dependency }
        await store.send(.command(.forgetDevice("agent")))
        await store.receive(\.commandFailed) { $0.alert = .error(CocoaError(.featureUnsupported).localizedDescription) }
        // Its OK carries no action; the root controller reports the close as a dismissal.
        await store.send(.alert(.dismiss)) { $0.alert = nil }
        await store.finish()
        #expect(cleared.value == 0 && store.state.snapshot.errorMessage == "Backend failure")
    }
    @Test func `A send failure whose composer closed reaches the root alert`() async {
        let release = AsyncStream<Void>.makeStream()
        var dependency = client
        dependency.sendSMS = { _, _ in for await _ in release.stream { break }; return .init(success: false, error: "Cloud mode is disabled") }
        var state = AirSIMFeature.State(); state.firstConnectionComplete = true; state.messages.composer = ComposerFeature.State(recipient: "123", body: "On my way", snapshot: snapshot)
        let store = TestStore(initialState: state) { AirSIMFeature() } withDependencies: { $0.airSIM = dependency; $0.uuid = .incrementing }
        await store.send(.messages(.composer(.presented(.view(.sendButtonTapped))))) { $0.messages.composer?.sendID = UUID(0) }
        await store.receive(\.messages.composer.presented.delegate)
        await store.send(.messages(.composer(.dismiss))) { $0.messages.composer = nil }
        release.continuation.yield()
        await store.receive(\.messages.composerSendFinished)
        await store.receive(\.messages.delegate.unreportedSendFailure) { $0.alert = .error("Cloud mode is disabled") }
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
        await store.finish()
        #expect(performed.value == ["answer:call-A"])
    }
    @Test func `Service snapshot cannot overwrite newer dial input`() async {
        let store = TestStore(initialState: AirSIMFeature.State()) { AirSIMFeature() } withDependencies: { $0.airSIM = client }
        await store.send(.dial(.view(.digitTapped("1")))) { $0.dial.number = "1"; $0.dial.hasDraft = true }
        await store.send(.dial(.view(.digitTapped("2")))) { $0.dial.number = "12" }
        await store.send(.dial(.view(.digitTapped("3")))) { $0.dial.number = "123" }
        var old = AirSIMSnapshot(); old.numberInput = "12"
        await store.send(.snapshot(old)) { $0.$snapshot.withLock { $0 = old }; $0.dial.lastBackendNumber = "12" }
        #expect(store.state.dial.number == "123")
    }
    @Test func `Each pairing screen starts from the current mode without the last code`() async {
        var state = AirSIMFeature.State()
        state.settings.mode = .vowlan
        state.settings.pairing.code = "123456"; state.settings.pairing.message = "Pairing failed: code expired"
        let store = TestStore(initialState: state) { AirSIMFeature() } withDependencies: { $0.airSIM = client }
        // A result that finished after the last screen closed is still shown once.
        await store.send(.settings(.pairing(.view(.opened)))) { $0.settings.pairing.code = "" }
        await store.receive(\.settings.pairing.delegate.opened) { $0.settings.pairing.localOnly = true }
        await store.send(.settings(.pairing(.view(.disappeared)))) { $0.settings.pairing.message = "" }
        await store.receive(\.settings.pairing.delegate.closed)
        await store.send(.settings(.view(.modeChanged(.automatic)))) { $0.settings.mode = .automatic }
        await store.send(.settings(.pairing(.view(.opened)))) { $0.settings.pairing.localOnly = false }
        await store.receive(\.settings.pairing.delegate.opened)
        await store.finish()
    }
    @Test func `Reopening pairing during a pairing keeps its code and mode`() async {
        var state = AirSIMFeature.State()
        state.settings.pairing.code = "123456"; state.settings.pairing.pairingID = "service"; state.settings.pairing.localOnly = true
        let store = TestStore(initialState: state) { AirSIMFeature() } withDependencies: { $0.airSIM = client }
        await store.send(.settings(.pairing(.view(.opened))))
        await store.receive(\.settings.pairing.delegate.opened)
    }
    @Test func `Scene teardown cancels service observation`() async {
        let store = TestStore(initialState: AirSIMFeature.State()) { AirSIMFeature() } withDependencies: { $0.airSIM = client }
        await store.send(.start)
        await store.send(.stop)
        await store.finish()
    }
}

@MainActor
struct TCACallKeypadTests {
    private func client(dtmf: LockIsolated<[String]> = .init([])) -> AirSIMClient {
        AirSIMClient(snapshots: { AsyncStream { _ in } }, command: { command in if case .dtmf(let digit) = command { dtmf.withValue { $0.append(digit) } } }, sendSMS: { _, _ in .init(success: false) }, selfTest: { AsyncStream { $0.finish() } }, pairing: { AsyncStream { $0.finish() } }, pair: { _, _, _ in "" })
    }
    private var inCall: AirSIMFeature.State { var snapshot = AirSIMSnapshot(); snapshot.inAppPresentedCall = AirSIMPreviewFixtures.call("active"); return AirSIMFeature.State(snapshot: snapshot) }
    @Test func `Keypad button opens an empty keypad only during an in-app call`() async {
        let idle = TestStore(initialState: AirSIMFeature.State()) { AirSIMFeature() } withDependencies: { $0.airSIM = client() }
        await idle.send(.activeCall(.view(.keypadButtonTapped)))
        let store = TestStore(initialState: inCall) { AirSIMFeature() } withDependencies: { $0.airSIM = client() }
        await store.send(.activeCall(.view(.keypadButtonTapped))) { $0.activeCall.keypad = KeypadFeature.State() }
        await store.send(.activeCall(.keypad(.presented(.view(.digitTapped("5")))))) { $0.activeCall.keypad?.digits = "5" }
        // A repeated tap while the sheet is still presenting keeps the digits already sent.
        await store.send(.activeCall(.view(.keypadButtonTapped)))
        await store.send(.activeCall(.keypad(.dismiss))) { $0.activeCall.keypad = nil }
        await store.send(.activeCall(.view(.keypadButtonTapped))) { $0.activeCall.keypad = KeypadFeature.State() }
        await store.finish()
    }
    @Test func `Keypad shows the last 18 digits and sends each tap as DTMF`() async {
        let dtmf = LockIsolated<[String]>([])
        var state = inCall; state.activeCall.keypad = KeypadFeature.State(digits: String(repeating: "1", count: 18))
        let store = TestStore(initialState: state) { AirSIMFeature() } withDependencies: { $0.airSIM = client(dtmf: dtmf) }
        await store.send(.activeCall(.keypad(.presented(.view(.digitTapped("#")))))) {
            $0.activeCall.keypad?.digits = String(repeating: "1", count: 17) + "#"
        }
        await store.send(.activeCall(.keypad(.presented(.view(.digitTapped("0")))))) {
            $0.activeCall.keypad?.digits = String(repeating: "1", count: 16) + "#0"
        }
        await store.finish()
        #expect(dtmf.value == ["#", "0"])
    }
    @Test func `Keypad stays through call updates and closes when the call leaves the app`() async {
        var state = inCall; state.activeCall.keypad = KeypadFeature.State(digits: "12")
        let store = TestStore(initialState: state) { AirSIMFeature() } withDependencies: { $0.airSIM = client() }
        var muted = state.snapshot; muted.isMuted = true
        await store.send(.snapshot(muted)) { $0.$snapshot.withLock { $0 = muted } }
        var ended = muted; ended.inAppPresentedCall = nil
        await store.send(.snapshot(ended)) { $0.$snapshot.withLock { $0 = ended }; $0.activeCall.keypad = nil }
    }
}

@MainActor
struct ActiveCallFeatureTests {
    private let start = AirSIMPreviewFixtures.date

    private func call(_ state: String, number: String? = AirSIMPreviewFixtures.phone) -> CallRecord {
        CallRecord(id: "call", index: 0, direction: "incoming", state: state, number: number,
                   startedAt: start, updatedAt: start, endedAt: nil, missed: false)
    }

    private func content(
        _ state: String,
        number: String? = AirSIMPreviewFixtures.phone,
        _ configure: (inout AirSIMSnapshot) -> Void = { _ in }
    ) -> ActiveCallContent {
        var snapshot = AirSIMSnapshot()
        snapshot.contacts = ContactDirectory(all: AirSIMPreviewFixtures.contacts, isAuthorized: true, authorization: .authorized)
        configure(&snapshot)
        return ActiveCallContent(call: call(state, number: number), snapshot: snapshot)
    }

    private func client(commands: LockIsolated<[String]>) -> AirSIMClient {
        AirSIMClient(
            snapshots: { AsyncStream { $0.finish() } },
            command: { command in commands.withValue { $0.append(String(describing: command)) } },
            sendSMS: { _, _ in .init(success: false) },
            selfTest: { AsyncStream { $0.finish() } },
            pairing: { AsyncStream { $0.finish() } },
            pair: { _, _, _ in "" }
        )
    }

    private func button(_ label: String, in view: UIView) -> UIButton? {
        if let button = view as? UIButton, button.accessibilityLabel == label { return button }
        return view.subviews.lazy.compactMap { self.button(label, in: $0) }.first
    }

    private func texts(in view: UIView) -> [String] {
        ((view as? UILabel)?.text.map { [$0] } ?? []) + view.subviews.flatMap { texts(in: $0) }
    }

    @Test func `Incoming and waiting calls ring with Waiting; every other state is connected with a running duration`() {
        for state in ["incoming", "waiting"] {
            let ringing = content(state)
            #expect(ringing.phase == .incoming && ringing.header == "AirSIM Incoming Call")
            #expect(!ringing.showsDuration && ringing.duration(at: start.addingTimeInterval(65)) == "Waiting")
        }
        for state in ["dialing", "alerting", "active", "held", "ending"] {
            let connected = content(state)
            #expect(connected.phase == .connected && connected.header == "AirSIM Call")
            #expect(connected.showsDuration && connected.duration(at: start.addingTimeInterval(65)) == "01:05")
        }
        #expect(content("active").duration(at: start.addingTimeInterval(-5)) == "00:00")
    }

    @Test func `A ringing call's status names the module and its signal`() throws {
        let modem = try JSONDecoder().decode(ModemStatus.self, from: Data(#"{"signal_dbm": -71}"#.utf8))
        let cloud = try JSONDecoder().decode(CloudAgentStatus.self, from: Data(#"{"cloud_online": true, "signal_dbm": -80}"#.utf8))
        let offline = content("incoming")
        #expect(offline.status == "Connecting to Module" && offline.badgeTone == .orange && offline.dotTone == .orange)
        let online = content("incoming") {
            $0.isOnline = true
            $0.modemStatus = modem
        }
        #expect(online.status == "Module Online · Signal -71 dBm" && online.badgeTone == .green && online.dotTone == .green)
        let cloudOnline = content("incoming") { $0.cloudAgentStatus = cloud }
        #expect(cloudOnline.status == "Module Online · Signal -80 dBm" && cloudOnline.badgeTone == .green)
        let both = content("incoming") {
            $0.cloudAgentStatus = cloud
            $0.modemStatus = modem
        }
        #expect(both.status == "Module Online · Signal -71 dBm")
    }

    @Test func `A connected call's status shows the audio state, the active route and the audio error`() {
        let routed = content("active") {
            $0.callAudioStatusText = "Audio Connected"
            $0.audioActive = true
            $0.audioRoute = "iPhone"
        }
        #expect(routed.status == "Audio Connected · iPhone")
        let inactive = content("active") {
            $0.callAudioStatusText = "Connecting Audio"
            $0.audioRoute = "iPhone"
        }
        #expect(inactive.status == "Connecting Audio")
        let failed = content("active") {
            $0.callAudioStatusText = "Audio Failed"
            $0.audioError = "Microphone unavailable"
        }
        #expect(failed.status == "Audio Failed\nMicrophone unavailable")
    }

    @Test func `A connected call's badge follows the call audio and its dot turns green once audio is active`() {
        let tones = { (configure: (inout AirSIMSnapshot) -> Void) -> [ActiveCallContent.Tone] in
            let value = content("active", configure)
            return [value.badgeTone, value.dotTone]
        }
        #expect(tones { $0.cloudCallAudioState = .failed("timeout") } == [.red, .red])
        #expect(tones {
            $0.cloudCallAudioState = .failed("timeout")
            $0.callAudioIsActive = true
        } == [.red, .green])
        #expect(tones { $0.cloudCallAudioState = .connected } == [.green, .green])
        #expect(tones { $0.cloudCallAudioState = .starting } == [.orange, .orange])
        #expect(tones { $0.cloudCallAudioState = .connecting(attempt: 1, maximumAttempts: 3) } == [.orange, .orange])
        #expect(tones { _ in } == [.orange, .orange])
        #expect(tones { $0.audioActive = true } == [.green, .green])
    }

    @Test func `The number shows under a contact's name and hides when the name is the number`() {
        let contact = content("active")
        #expect(contact.name == "Mina Kim" && contact.number == AirSIMPreviewFixtures.phone && contact.showsNumber)
        let unknown = content("active", number: "+1 202 555 0199")
        #expect(unknown.name == "+1 202 555 0199" && !unknown.showsNumber)
        let hidden = content("active", number: nil)
        #expect(hidden.name == "Unknown Number" && !hidden.showsNumber)
    }

    @Test func `Record shows the recording state and is enabled only while recording can toggle and is not busy`() {
        let ready = content("active") { $0.canToggleRecording = true }
        #expect(ready.canToggleRecording && !ready.isRecording)
        let recording = content("active") {
            $0.canToggleRecording = true
            $0.isRecording = true
        }
        #expect(recording.canToggleRecording && recording.isRecording)
        let busy = content("active") {
            $0.canToggleRecording = true
            $0.isRecordingBusy = true
        }
        #expect(!busy.canToggleRecording)
        #expect(!content("active").canToggleRecording)
    }

    @Test func `The proximity sensor is used for placed and live calls while the speaker is off`() {
        for state in ["dialing", "alerting", "connecting", "active", "held", "ending"] {
            #expect(content(state).monitorsProximity)
            #expect(!content(state) { $0.speakerEnabled = true }.monitorsProximity)
        }
        for state in ["incoming", "waiting", "ended"] {
            #expect(!content(state).monitorsProximity)
        }
    }

    @Test func `Call buttons send answer, reject, hangup, mute, speaker and recording`() async {
        let commands = LockIsolated<[String]>([])
        var snapshot = AirSIMSnapshot()
        snapshot.inAppPresentedCall = call("active")
        let store = TestStore(initialState: ActiveCallFeature.State(snapshot: SharedReader(value: snapshot))) {
            ActiveCallFeature()
        } withDependencies: {
            $0.airSIM = client(commands: commands)
        }
        await store.send(.view(.answerButtonTapped))
        await store.send(.view(.declineButtonTapped))
        await store.send(.view(.endButtonTapped))
        await store.send(.view(.muteButtonTapped))
        await store.send(.view(.speakerButtonTapped))
        await store.send(.view(.recordButtonTapped))
        await store.finish()
        #expect(commands.value.sorted() == ["answer", "hangup", "mute", "recording", "reject", "speaker"])
    }

    @Test func `The layout argument shows a fabricated incoming or active call in place of the backend's`() {
        #expect(CallRecord.layoutPreview(arguments: ["AirSIM"]) == nil)
        #expect(CallRecord.layoutPreview(arguments: ["AirSIM", "--airsim-layout-call"]) == nil)
        #expect(CallRecord.layoutPreview(arguments: ["AirSIM", "--airsim-layout-call", "ringing"]) == nil)
        let preview = CallRecord.layoutPreview(arguments: ["AirSIM", "--airsim-layout-call", "incoming"])
        #expect(preview?.id == "layout-preview" && preview?.state == "incoming" && preview?.number == "+1 202 555 0100")
        #expect(CallRecord.layoutPreview(arguments: ["AirSIM", "--airsim-layout-call", "active"])?.state == "active")
        var snapshot = AirSIMSnapshot()
        snapshot.inAppPresentedCall = call("active")
        var state = ActiveCallFeature.State(snapshot: SharedReader(value: snapshot))
        #expect(state.call?.id == "call" && !state.isLayoutPreview)
        state.layoutPreviewCall = preview
        #expect(state.call?.id == "layout-preview" && state.isLayoutPreview && state.content?.phase == .incoming)
    }

    @Test func `The call screen draws its store's call and sends each button's action`() async throws {
        let commands = LockIsolated<[String]>([])
        var snapshot = AirSIMSnapshot()
        snapshot.contacts = ContactDirectory(all: AirSIMPreviewFixtures.contacts, isAuthorized: true, authorization: .authorized)
        snapshot.inAppPresentedCall = call("incoming")
        snapshot.canToggleRecording = true
        let shared = Shared(value: snapshot)
        let store = Store(initialState: ActiveCallFeature.State(snapshot: SharedReader(shared))) {
            ActiveCallFeature()
        } withDependencies: {
            $0.airSIM = client(commands: commands)
        }
        let screen = ActiveCallViewController(store: store)
        screen.isPresentationPreview = true
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = screen
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        #expect(texts(in: screen.view).contains("AirSIM Incoming Call") && texts(in: screen.view).contains("Mina Kim"))
        #expect(button("End", in: screen.view) == nil)
        for label in ["Decline", "Accept"] {
            try #require(button(label, in: screen.view)).sendActions(for: .touchUpInside)
        }
        shared.withLock { $0.inAppPresentedCall = call("active") }
        _ = try #require(await eventually { button("End", in: screen.view) })
        #expect(texts(in: screen.view).contains("AirSIM Call") && button("Accept", in: screen.view) == nil)
        for label in ["Mute", "Speaker", "Record", "End"] {
            try #require(button(label, in: screen.view)).sendActions(for: .touchUpInside)
        }
        #expect(try await eventually { commands.value.count == 6 ? true : nil } == true)
        #expect(commands.value.sorted() == ["answer", "hangup", "mute", "recording", "reject", "speaker"])
        try #require(button("Keypad", in: screen.view)).sendActions(for: .touchUpInside)
        #expect(store.keypad == KeypadFeature.State())
    }

    @Test func `A layout preview call opens the call window while the backend presents no call`() throws {
        var state = AirSIMFeature.State()
        state.firstConnectionComplete = true
        state.activeCall.layoutPreviewCall = CallRecord.layoutPreview(arguments: ["AirSIM", "--airsim-layout-call", "active"])
        let store = Store(initialState: state) { AirSIMFeature() } withDependencies: {
            $0.airSIM = client(commands: LockIsolated([]))
        }
        let root = RootViewController(previewPresentation: AirSIMPresentation(store: store))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = root
        window.makeKeyAndVisible()
        defer {
            root.dismiss(animated: false)
            window.isHidden = true
        }
        root.render()
        let callWindow = try #require(root.callWindow)
        #expect(store.snapshot.inAppPresentedCall == nil)
        #expect(root.activeCallController?.call?.id == "layout-preview" && root.activeCallController?.view.window === callWindow)
    }
}

struct TelephoneNumberValidationTests {
    @Test func `Visual separators from tel and im links are accepted`() {
        #expect(AppModel.validatedNumber(" +1 (202) 555-0100 ") == "+12025550100")
        #expect(AppModel.validatedNumber("202.555.0100") == "2025550100")
        #expect(AppModel.validatedNumber("*#06#") == "*#06#")
    }
    @Test func `Anything that could reach the modem as a command is rejected`() {
        #expect(AppModel.validatedNumber("123;ATH") == "")
        #expect(AppModel.validatedNumber("123\r\nAT") == "")
        #expect(AppModel.validatedNumber(String(repeating: "1", count: 83)) == "")
        #expect(AppModel.validatedNumber("1 2;ATH") == "")
        // Lookalikes and non-ASCII digits are not separators or digits.
        for input in ["\u{FF11}\u{FF12}", "1\u{00A0}2", "1\u{2011}2", "1-\u{0301}2", "\u{0661}\u{0662}"] {
            #expect(AppModel.validatedNumber(input) == "", "\(input.unicodeScalars.map(\.value))")
        }
    }
    @Test func `Length limit applies after separators are removed`() {
        let digits82 = String(repeating: "1", count: 82)
        #expect(AppModel.validatedNumber(digits82.map { "\($0)-" }.joined()) == digits82)
        #expect(AppModel.validatedNumber(String(repeating: "1-", count: 83)) == "")
        #expect(AppModel.validatedNumber(" ( ) - . ") == "")
    }
    @Test @MainActor func `SMS failure reports only its own error`() async {
        let model = AppModel()
        model.errorMessage = "Unable to delete local call history. Try again later."
        let result = await model.sendSMS(to: "not a number", content: "Hi")
        #expect(!result.sent)
        #expect(result.error == nil)
        #expect(model.errorMessage == "Unable to delete local call history. Try again later.")
    }
    @Test @MainActor func `Acknowledging an older error keeps a newer backend error`() async throws {
        let model = AppModel()
        let client = AirSIMClient.live(model: model, settings: AppSettings(), playback: CallRecordingPlayback())
        model.errorMessage = "Newer failure"
        try await client.command(.clearError("Older failure"))
        #expect(model.errorMessage == "Newer failure")
        try await client.command(.clearError("Newer failure"))
        #expect(model.errorMessage == nil)
    }
}

@MainActor
struct TCANavigationDismissalTests {
    /// Shared readers compare by value, so states built with this equal the ones reducers build from an empty snapshot.
    private let snapshot = SharedReader(value: AirSIMSnapshot())
    @Test func `Back clears thread destination so later snapshots cannot reopen it`() async {
        var state = MessagesFeature.State(snapshot: snapshot); state.conversation = "+12025550100"
        let store = TestStore(initialState: state) { MessagesFeature() }
        await store.send(.view(.threadClosed("+12025550100"))) { $0.conversation = nil }
        #expect(store.state.conversation == nil)
    }
    @Test func `Opening notification conversation dismisses current composer state`() async {
        var state = MessagesFeature.State(snapshot: snapshot); state.composer = ComposerFeature.State(recipient: "other", body: "draft", snapshot: snapshot)
        let store = TestStore(initialState: state) { MessagesFeature() }
        await store.send(.openConversation("+12025550100")) { $0.conversation = "+12025550100"; $0.composer = nil }
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
        let controller = MessagesViewController(store: model.store.scope(state: \.messages, action: \.messages))
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
        let root = RootViewController(previewPresentation: model)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844)); window.rootViewController = root; window.makeKeyAndVisible()
        defer { root.dismiss(animated: false); window.isHidden = true }
        root.openSMSConversation("+12025550100")
        let tab = try #require(root.tabs.selectedViewController as? UINavigationController)
        #expect(tab.topViewController is MessageThreadViewController)
        withUITransaction(\.uiKit.disablesAnimations, true) { root.composeMessage("+12025550101") }
        let composer = try #require(await presentedSheet(root)?.topViewController as? MessageComposerViewController)
        #expect(composer.store.recipient == "+12025550101" && composer.recipient.text == "+12025550101")
        #expect(model.store.messages.conversation == "+12025550100" && tab.topViewController is MessageThreadViewController)
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
            $0.$snapshot.withLock { $0 = snapshot }
            $0.settings.mode = .cloud; $0.settings.lastObservedMode = .cloud
            $0.settings.appearance = .dark; $0.settings.lastObservedAppearance = .dark
            $0.settings.lastObservedRelayURL = "https://other.example"
        }
        #expect(store.state.settings.relayURL == "https://draft.example")
    }
}

@MainActor
struct SettingsFeatureTests {
    private func state(mode: AirSIMConnectionMode = .automatic, _ change: (inout AirSIMSnapshot) -> Void = { _ in }) -> SettingsFeature.State {
        var snapshot = AirSIMSnapshot()
        change(&snapshot)
        var state = SettingsFeature.State(snapshot: SharedReader(value: snapshot))
        state.mode = mode
        return state
    }

    private func client(commands: LockIsolated<[String]>) -> AirSIMClient {
        AirSIMClient(
            snapshots: { AsyncStream { $0.finish() } },
            command: { command in commands.withValue { $0.append(String(describing: command)) } },
            sendSMS: { _, _ in .init(success: false) },
            selfTest: { AsyncStream { $0.finish() } },
            pairing: { AsyncStream { $0.finish() } },
            pair: { _, _, _ in "" }
        )
    }

    private func onlineSnapshot() throws -> AirSIMSnapshot {
        var snapshot = AirSIMSnapshot()
        snapshot.vowlan = .verified(try VoWLANEndpoint(host: "192.168.43.1", controlPort: 7575), at: AirSIMPreviewFixtures.date)
        return snapshot
    }

    @Test func `Footers, cloud rows and the mode icon follow the connection mode`() throws {
        let vowlan = state(mode: .vowlan)
        #expect(vowlan.modeIcon == "wifi" && vowlan.modeDetail == "Uses only the same Wi-Fi or phone hotspot, without Relay")
        #expect(vowlan.cloudRelayStatus == "Disabled in current mode" && vowlan.remoteCallsStatus == "Disabled")
        #expect(vowlan.selfTestFooter == "Cloud self-test is unavailable in the current connection mode.")
        #expect(!vowlan.modeUsesCloud && !vowlan.canRunSelfTest)
        let cloud = state(mode: .cloud)
        #expect(cloud.modeIcon == "cloud" && cloud.modeDetail == "Uses only Relay, PushKit, and CallKit")
        #expect(cloud.cloudRelayStatus == "Unreachable" && cloud.remoteCallsStatus == "Enabled")
        #expect(cloud.selfTestFooter.hasPrefix("Checks local push credentials, AirSIM Relay identity"))
        #expect(cloud.modeUsesCloud && cloud.canRunSelfTest)
        let status = try JSONDecoder().decode(CloudAgentStatus.self, from: Data(#"{"cloud_online": true}"#.utf8))
        let automatic = state(mode: .automatic) { $0.cloudAgentStatus = status }
        #expect(automatic.modeIcon == "arrow.triangle.branch" && automatic.cloudRelayStatus == "Agent Online")
        var running = automatic
        running.selfTestRunning = true
        #expect(!running.canRunSelfTest && running.selfTestTitle == "Run Cloud Self-Test · Running…")
        #expect(automatic.selfTestTitle == "Run Cloud Self-Test")
        #expect(state { $0.connectionMessage = "" }.connectionMessage == nil)
        #expect(state { $0.connectionMessage = "Reconnecting" }.connectionMessage == "Reconnecting")
        #expect(state { $0.vowlan = .unavailable("VoWLAN disconnected") }.vowlanStatus == "LAN Disconnected · Cloud for Next Call")
        #expect(state().vowlanStatus == "Not Paired")
    }

    @Test func `Self-test steps show an icon and tone for their state, and the result once the test finishes`() {
        var report = CloudSelfTestReport.initial
        report.steps[1].state = .running
        report.steps[2].state = .passed
        report.steps[3].state = .failed
        var settings = state()
        settings.report = report
        #expect(settings.selfTestSteps.map(\.id) == ["configuration", "relayIdentity", "deviceRegistration", "agentHeartbeat"])
        #expect(settings.selfTestSteps.map(\.icon) == ["circle", "arrow.triangle.2.circlepath", "checkmark.circle.fill", "xmark.circle.fill"])
        #expect(settings.selfTestSteps.map(\.tone) == [.secondary, .blue, .green, .red])
        #expect(settings.selfTestResult == nil)
        settings.selfTestCompleted = true
        #expect(settings.selfTestResult?.text == "Self-test failed. Resolve the failed steps and try again.")
        #expect(settings.selfTestResult?.tone == .orange)
        settings.report = AirSIMPreviewFixtures.selfTestReport
        #expect(settings.selfTestResult?.text == "Cloud self-test passed" && settings.selfTestResult?.tone == .green)
        settings.report = nil
        #expect(settings.selfTestSteps.isEmpty && settings.selfTestResult == nil)
    }

    @Test func `Paired device rows show the number over the online routes or the offline note`() {
        func row(number: String?, vowlan: Bool, cloud: Bool) -> PairedDeviceRow {
            PairedDeviceRow(device: AndroidAgentPresentation(
                id: "agent", deviceName: "Galaxy", phoneNumber: number, agentKind: nil,
                cloudOnline: cloud, vowlanOnline: vowlan, isCurrent: false
            ))
        }
        #expect(row(number: "+1 202 555 0100", vowlan: true, cloud: true).detail == "+1 202 555 0100\nVoWLAN Online · Cloud Online")
        #expect(row(number: "+1 202 555 0100", vowlan: true, cloud: false).route == "VoWLAN Online")
        #expect(row(number: "+1 202 555 0100", vowlan: false, cloud: true).route == "Cloud Online")
        #expect(row(number: nil, vowlan: false, cloud: false).detail == "Number unavailable\nOffline · Refreshes on reconnection")
    }

    @Test func `Settings shows connection values, device rows and self-test tones`() throws {
        let store = AirSIMPreviewFixtures.presentation(tab: .settings).store
        var report = AirSIMPreviewFixtures.selfTestReport
        report.steps[0].state = .failed
        report.steps[1].state = .running
        report.steps[2].state = .pending
        store.send(.settings(.selfTestUpdated(report)))
        let controller = AirSIMSettingsViewController(store: store.scope(state: \.settings, action: \.settings))
        controller.loadViewIfNeeded()
        controller.render()
        let rows = controller.sections.flatMap(\.rows)
        let values = rows.filter(\.isValue).map { "\($0.id)=\($0.detail)" }
        #expect(values == [
            "currentMode=VoWLAN", "connectionStatus=Connected", "vowlan=VoWLAN Ready", "cloud=Unreachable",
            "vowlan=VoWLAN Ready", "enabled=Enabled", "project=AirSIM · Samsung",
        ])
        let device = try #require(rows.first { $0.id == "preview-samsung" })
        #expect(device.detail == "\(AirSIMPreviewFixtures.phone)\nVoWLAN Online · Cloud Online" && !device.isValue)
        #expect(device.accessibilityHint == "Delete Samsung Galaxy pairing record" && device.enabled)
        let steps = ["configuration", "relayIdentity", "deviceRegistration", "agentHeartbeat"].compactMap { id in rows.first { $0.id == id } }
        #expect(steps.map(\.image) == ["xmark.circle.fill", "arrow.triangle.2.circlepath", "circle", "checkmark.circle.fill"])
        #expect(steps.map(\.color) == [.systemRed, .systemBlue, .secondaryLabel, .systemGreen])
        #expect(rows.first { $0.id == "result" }?.color == .systemOrange)
        #expect(controller.sections.map(\.footer)[0] == "Automatically chooses VoWLAN, then cloud based on availability")
    }

    @Test func `Settings refreshes devices on appear and sends Discover Again, Live Activity and Save Relay URL`() async throws {
        let commands = LockIsolated<[String]>([])
        let store = Store(initialState: SettingsFeature.State(snapshot: SharedReader(value: AirSIMSnapshot()))) {
            SettingsFeature()
        } withDependencies: {
            $0.airSIM = client(commands: commands)
        }
        let controller = AirSIMSettingsViewController(store: store)
        controller.loadViewIfNeeded()
        controller.viewWillAppear(false)
        controller.sections.flatMap(\.rows).first { $0.id == "discover" }?.action?()
        controller.sections.flatMap(\.rows).first { $0.id == "save" }?.action?()
        let activity = try #require(controller.sections.flatMap(\.rows).first { $0.id == "activity" }?.accessory as? UISwitch)
        activity.isOn = false
        activity.sendActions(for: .valueChanged)
        let sent = try await eventually { commands.value.count == 4 ? commands.value : nil }
        #expect(sent?.sorted() == ["discover", "liveActivity(false)", "refreshDevices", "saveRelay(\"\")"])
        #expect(!store.liveActivityEnabled && store.message == "URL saved. Registration will complete automatically after pairing.")
    }

    @Test func `Pair Later finishes onboarding and saves it`() async {
        let commands = LockIsolated<[String]>([])
        let store = TestStore(initialState: AirSIMFeature.State()) { AirSIMFeature() } withDependencies: {
            $0.airSIM = client(commands: commands)
        }
        await store.send(.settings(.view(.pairLaterTapped)))
        await store.receive(\.settings.delegate.onboardingCompleted) { $0.firstConnectionComplete = true }
        await store.finish()
        #expect(commands.value == ["completeOnboarding"])
    }

    @Test func `Closing the first-connection pairing finishes onboarding only while VoWLAN is online`() async throws {
        let commands = LockIsolated<[String]>([])
        let store = TestStore(initialState: AirSIMFeature.State()) { AirSIMFeature() } withDependencies: {
            $0.airSIM = client(commands: commands)
        }
        await store.send(.settings(.view(.startPairingTapped))) { $0.settings.pairingFromOnboarding = true }
        await store.send(.settings(.pairing(.view(.disappeared))))
        await store.receive(\.settings.pairing.delegate.closed) { $0.settings.pairingFromOnboarding = false }
        let online = try onlineSnapshot()
        await store.send(.snapshot(online)) { $0.$snapshot.withLock { $0 = online } }
        await store.send(.settings(.view(.startPairingTapped))) { $0.settings.pairingFromOnboarding = true }
        await store.send(.settings(.pairing(.view(.disappeared))))
        await store.receive(\.settings.pairing.delegate.closed) { $0.settings.pairingFromOnboarding = false }
        await store.receive(\.settings.delegate.onboardingCompleted) { $0.firstConnectionComplete = true }
        await store.finish()
        #expect(commands.value == ["completeOnboarding"])
    }

    @Test func `Closing pairing opened from Settings leaves onboarding alone`() async throws {
        let commands = LockIsolated<[String]>([])
        let online = try onlineSnapshot()
        let store = TestStore(initialState: AirSIMFeature.State(snapshot: online)) { AirSIMFeature() } withDependencies: {
            $0.airSIM = client(commands: commands)
        }
        await store.send(.settings(.pairing(.view(.disappeared))))
        await store.receive(\.settings.pairing.delegate.closed)
        await store.finish()
        #expect(commands.value.isEmpty && !store.state.firstConnectionComplete)
    }

    @Test func `The first-connection screen's Pair Later and mode control reach the store`() throws {
        let commands = LockIsolated<[String]>([])
        let store = Store(initialState: AirSIMFeature.State()) { AirSIMFeature() } withDependencies: {
            $0.airSIM = client(commands: commands)
        }
        let controller = AirSIMFirstConnectionViewController(store: store.scope(state: \.settings, action: \.settings))
        controller.loadViewIfNeeded()
        controller.render()
        func find<T: UIView>(_ type: T.Type, in view: UIView, where match: (T) -> Bool = { _ in true }) -> T? {
            if let view = view as? T, match(view) { return view }
            for subview in view.subviews {
                if let found = find(type, in: subview, where: match) { return found }
            }
            return nil
        }
        let mode = try #require(find(UISegmentedControl.self, in: controller.view))
        #expect(mode.selectedSegmentIndex == AirSIMConnectionMode.allCases.firstIndex(of: .automatic))
        mode.selectedSegmentIndex = AirSIMConnectionMode.allCases.firstIndex(of: .vowlan)!
        mode.sendActions(for: .valueChanged)
        #expect(store.settings.mode == .vowlan)
        let later = try #require(find(UIButton.self, in: controller.view) { $0.accessibilityLabel == "Pair Later in Settings" })
        later.sendActions(for: .touchUpInside)
        #expect(store.firstConnectionComplete)
    }
}

@MainActor
struct UIKitConversationReplacementTests {
    @Test func `Finishing Back for A cannot clear a newly requested B`() {
        let model = AirSIMPreviewFixtures.presentation(tab: .messages)
        let list = MessagesViewController(store: model.store.scope(state: \.messages, action: \.messages))
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
        let controller = MessagesViewController(store: model.store.scope(state: \.messages, action: \.messages))
        let nav = UINavigationController(rootViewController: controller)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844)); window.rootViewController = nav; window.makeKeyAndVisible()
        controller.openConversation("A")
        controller.openConversation("B")
        #expect(model.store.messages.conversation == "B")
        #expect((nav.topViewController as? MessageThreadViewController)?.sender == "B")
        window.isHidden = true
    }
}

/// present(item:) applies state on a later main-queue turn, once its presenter has appeared.
@MainActor
private func eventually<T>(_ value: () -> T?) async throws -> T? {
    for _ in 0..<300 { if let value = value() { return value }; try await Task.sleep(for: .milliseconds(10)) }
    return value()
}

@MainActor
private func presentedSheet(_ presenter: UIViewController, other: UIViewController? = nil) async throws -> UINavigationController? {
    try await eventually {
        guard let sheet = presenter.presentedViewController as? UINavigationController, sheet !== other, !sheet.isBeingPresented else { return nil }
        return sheet
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

    @Test func `Call teardown leaves an unrelated root sheet intact`() throws {
        let model = AirSIMPreviewFixtures.presentation(callState: "active")
        let root = RootViewController(previewPresentation: model)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = root; window.makeKeyAndVisible(); root.render()
        defer { root.dismiss(animated: false); window.isHidden = true }
        let callWindow = try #require(root.callWindow)
        #expect(root.activeCallController?.view.window === callWindow)
        let sheet = UIViewController(); root.present(sheet, animated: false)
        var ended = model.snapshot; ended.inAppPresentedCall = nil; ended.callLifecycleSnapshot = .idle
        model.store.send(.snapshot(ended)); root.render()
        #expect(root.callWindow == nil && root.activeCallController == nil)
        #expect(callWindow.isHidden)
        #expect(root.presentedViewController === sheet)
        #expect(!sheet.isBeingDismissed)
    }

    @Test func `Incoming call shows above a root sheet without dismissing it`() throws {
        let model = AirSIMPreviewFixtures.presentation()
        let root = RootViewController(previewPresentation: model)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = root; window.makeKeyAndVisible(); root.render()
        defer { root.dismiss(animated: false); window.isHidden = true }
        let sheet = UINavigationController(rootViewController: UIViewController()); root.present(sheet, animated: false)
        #expect(root.callWindow == nil)
        var incoming = model.snapshot; incoming.inAppPresentedCall = AirSIMPreviewFixtures.call("incoming")
        model.store.send(.snapshot(incoming)); root.render()
        // VoWLAN calls have no CallKit screen, so Accept and Decline must sit above every root sheet.
        let callWindow = try #require(root.callWindow)
        let call = try #require(root.activeCallController)
        #expect(!callWindow.isHidden && callWindow.windowLevel > window.windowLevel)
        #expect(callWindow.windowScene === window.windowScene && callWindow.frame == window.frame)
        #expect(call.view.window === callWindow && !root.children.contains { $0 is ActiveCallViewController })
        #expect(callWindow.rootViewController?.childForStatusBarStyle === call && callWindow.rootViewController?.childForStatusBarHidden === call)
        #expect(root.presentedViewController === sheet && !sheet.isBeingDismissed)
        // The call view's modality only hides siblings in its own window; VoiceOver must not reach the covered sheet.
        #expect(window.accessibilityElementsHidden && !callWindow.accessibilityElementsHidden)
        var answered = incoming; answered.inAppPresentedCall = AirSIMPreviewFixtures.call("active")
        model.store.send(.snapshot(answered)); root.render()
        #expect(root.callWindow === callWindow && root.activeCallController === call && call.call?.state == "active")
        var ended = answered; ended.inAppPresentedCall = nil
        model.store.send(.snapshot(ended)); root.render()
        #expect(root.callWindow == nil && callWindow.isHidden && !window.accessibilityElementsHidden)
        #expect(root.presentedViewController === sheet && !sheet.isBeingDismissed)
    }

    @Test func `Pair Later saves onboarding and the root closes the first-connection screen`() async throws {
        let commands = LockIsolated<[String]>([])
        let client = AirSIMClient(
            snapshots: { AsyncStream { $0.finish() } },
            command: { command in commands.withValue { $0.append(String(describing: command)) } },
            sendSMS: { _, _ in .init(success: false) },
            selfTest: { AsyncStream { $0.finish() } },
            pairing: { AsyncStream { $0.finish() } },
            pair: { _, _, _ in "" }
        )
        let store = Store(initialState: AirSIMFeature.State()) { AirSIMFeature() } withDependencies: { $0.airSIM = client }
        let root = RootViewController(previewPresentation: AirSIMPresentation(store: store))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = root
        window.makeKeyAndVisible()
        defer { root.dismiss(animated: false); window.isHidden = true }
        let onboarding = try #require(try await eventually {
            (root.presentedViewController as? UINavigationController).flatMap { $0.isBeingPresented ? nil : $0 }
        })
        let setup = try #require(onboarding.topViewController as? AirSIMFirstConnectionViewController)
        func button(_ label: String, in view: UIView) -> UIButton? {
            if let button = view as? UIButton, button.accessibilityLabel == label { return button }
            for subview in view.subviews {
                if let found = button(label, in: subview) { return found }
            }
            return nil
        }
        try #require(button("Pair Later in Settings", in: setup.view)).sendActions(for: .touchUpInside)
        #expect(store.firstConnectionComplete)
        #expect(try await eventually { root.presentedViewController == nil ? true : nil } == true)
        #expect(commands.value == ["completeOnboarding"])
    }

    @Test func `Incoming call shows above full-screen onboarding`() async throws {
        let model = AirSIMPreviewFixtures.presentation()
        let root = RootViewController(previewPresentation: model)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = root; window.makeKeyAndVisible(); root.render()
        defer { root.dismiss(animated: false); window.isHidden = true }
        let onboarding = UINavigationController(rootViewController: UIViewController()); onboarding.modalPresentationStyle = .fullScreen
        root.present(onboarding, animated: false)
        // A completed full-screen presentation takes root's view out of the window; only the onboarding is in it.
        #expect(try await eventually { root.viewIfLoaded?.window == nil && onboarding.viewIfLoaded?.window === window ? true : nil } == true)
        var incoming = model.snapshot; incoming.inAppPresentedCall = AirSIMPreviewFixtures.call("incoming")
        model.store.send(.snapshot(incoming)); root.render()
        let callWindow = try #require(root.callWindow)
        #expect(!callWindow.isHidden && callWindow.windowLevel > window.windowLevel && callWindow.windowScene === window.windowScene)
        #expect(root.activeCallController?.view.window === callWindow && window.accessibilityElementsHidden)
        #expect(root.presentedViewController === onboarding && !onboarding.isBeingDismissed)
        var ended = incoming; ended.inAppPresentedCall = nil
        model.store.send(.snapshot(ended)); root.render()
        #expect(root.callWindow == nil && callWindow.isHidden && !window.accessibilityElementsHidden)
        #expect(root.presentedViewController === onboarding && !onboarding.isBeingDismissed)
    }

    @Test func `Error during a call is shown above the call and moves to root when it ends`() throws {
        let model = AirSIMPreviewFixtures.presentation(callState: "active")
        let root = RootViewController(previewPresentation: model)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = root; window.makeKeyAndVisible(); root.render()
        defer { root.dismiss(animated: false); window.isHidden = true }
        let callWindow = try #require(root.callWindow)
        model.store.send(.commandFailed("Unable to reach the module")); root.render()
        #expect(callWindow.rootViewController?.presentedViewController is UIAlertController)
        #expect(root.presentedViewController == nil)
        var ended = model.snapshot; ended.inAppPresentedCall = nil; ended.callLifecycleSnapshot = .idle
        model.store.send(.snapshot(ended)); root.render()
        #expect(root.callWindow == nil)
        #expect((root.presentedViewController as? UIAlertController)?.message == "Unable to reach the module")
    }

    @Test func `Call keypad survives thread renders and closes with its call`() async throws {
        let model = AirSIMPreviewFixtures.presentation(tab: .messages, callState: "active")
        let root = RootViewController(previewPresentation: model)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = root; window.makeKeyAndVisible()
        defer { root.dismiss(animated: false); window.isHidden = true }
        root.openSMSConversation(AirSIMPreviewFixtures.phone); root.render()
        let callWindow = try #require(root.callWindow)
        let keypad = try #require(await presentKeypad(model, in: callWindow))
        #expect(keypad.topViewController is DTMFKeypadViewController)
        #expect(keypad.sheetPresentationController?.prefersGrabberVisible == true && keypad.topViewController?.navigationItem.rightBarButtonItem != nil)
        #expect(root.presentedViewController == nil)
        root.render()
        try await Task.sleep(for: .milliseconds(50))
        #expect(!keypad.isBeingDismissed && keypad.presentingViewController != nil && model.store.activeCall.keypad != nil)
        var ended = model.snapshot; ended.inAppPresentedCall = nil; ended.callLifecycleSnapshot = .idle
        model.store.send(.snapshot(ended)); root.render()
        #expect(model.store.activeCall.keypad == nil)
        #expect(try await eventually { keypad.presentingViewController == nil ? true : nil } == true)
    }

    @Test func `Closing the call keypad clears its state so the next one starts empty`() async throws {
        let model = AirSIMPreviewFixtures.presentation(callState: "active")
        let root = RootViewController(previewPresentation: model)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = root; window.makeKeyAndVisible(); root.render()
        defer { root.dismiss(animated: false); window.isHidden = true }
        let callWindow = try #require(root.callWindow)
        let keypad = try #require(await presentKeypad(model, in: callWindow))
        let pad = try #require(keypad.topViewController as? DTMFKeypadViewController)
        pad.store.send(.view(.digitTapped("7")))
        #expect(model.store.activeCall.keypad?.digits == "7")
        // Done and swipe-down are UIKit dismissals; the presentation binding writes the closed state back.
        keypad.dismiss(animated: false)
        #expect(try await eventually { model.store.activeCall.keypad == nil ? true : nil } == true)
        // present(item:) applies the closed state on a later main-actor turn; a reopen before then reuses the
        // cached child store and is skipped. A person cannot tap within that turn.
        try await Task.sleep(for: .milliseconds(50))
        let reopened = try #require(await presentKeypad(model, in: callWindow))
        #expect(reopened !== keypad && model.store.activeCall.keypad?.digits == "")
    }

    @Test func `Composing while root shows another sheet replaces it with the composer`() async throws {
        let model = AirSIMPreviewFixtures.presentation(tab: .contacts)
        let root = RootViewController(previewPresentation: model)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = root; window.makeKeyAndVisible(); root.render()
        defer { root.dismiss(animated: false); window.isHidden = true }
        let other = UINavigationController(rootViewController: UIViewController()); root.present(other, animated: false)
        withUITransaction(\.uiKit.disablesAnimations, true) { root.composeMessage(AirSIMPreviewFixtures.phone) }
        let sheet = try #require(await presentedSheet(root, other: other))
        let composer = try #require(sheet.topViewController as? MessageComposerViewController)
        #expect(other.presentingViewController == nil)
        #expect(model.store.selectedTab == .messages && composer.store.recipient == AirSIMPreviewFixtures.phone)
        #expect(sheet.sheetPresentationController?.prefersGrabberVisible == true && composer.navigationItem.leftBarButtonItem?.title == "Cancel")
        // Swipe-down is a UIKit dismissal; the presentation binding writes the closed state back.
        sheet.dismiss(animated: false)
        #expect(try await eventually { model.store.messages.composer == nil ? true : nil } == true)
    }

    @Test func `Failed composer send alerts above the open composer and a later success closes it`() async throws {
        let result = LockIsolated(AirSIMMessageResult(success: false, error: "Cloud mode is disabled"))
        var state = AirSIMFeature.State(); state.firstConnectionComplete = true; state.selectedTab = .messages
        let client = AirSIMClient(snapshots: { AsyncStream { $0.finish() } }, command: { _ in }, sendSMS: { _, _ in result.value }, selfTest: { AsyncStream { $0.finish() } }, pairing: { AsyncStream { $0.finish() } }, pair: { _, _, _ in "" })
        let model = AirSIMPresentation(store: Store(initialState: state) { AirSIMFeature() } withDependencies: { $0.airSIM = client; $0.uuid = .incrementing })
        let root = RootViewController(previewPresentation: model)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = root; window.makeKeyAndVisible(); root.render()
        defer { root.dismiss(animated: false); window.isHidden = true }
        withUITransaction(\.uiKit.disablesAnimations, true) { root.composeMessage("123") }
        let sheet = try #require(await presentedSheet(root))
        let composer = try #require(sheet.topViewController as? MessageComposerViewController)
        composer.store.send(.view(.bodyChanged("Keep me")))
        composer.store.send(.view(.sendButtonTapped))
        let alert = try #require(await eventually { () -> UIAlertController? in
            guard let alert = composer.presentedViewController as? UIAlertController, !alert.isBeingPresented else { return nil }
            return alert
        })
        #expect(alert.message == "Cloud mode is disabled" && alert.actions.map(\.title) == ["OK"])
        #expect(root.presentedViewController === sheet && !sheet.isBeingDismissed && composer.store.body == "Keep me")
        withUITransaction(\.uiKit.disablesAnimations, true) { _ = composer.store.send(.alert(.presented(.ok))) }
        #expect(try await eventually { composer.presentedViewController == nil ? true : nil } == true)
        #expect(composer.store.alert == nil && root.presentedViewController === sheet)
        result.setValue(.init(success: true))
        composer.store.send(.view(.sendButtonTapped))
        #expect(try await eventually { root.presentedViewController == nil ? true : nil } == true)
        #expect(model.store.messages.composer == nil)
    }

    @Test func `Backend error during an open composer alerts above it and outlives the composer`() async throws {
        let model = AirSIMPreviewFixtures.presentation(tab: .messages)
        let root = RootViewController(previewPresentation: model)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = root; window.makeKeyAndVisible(); root.render()
        defer { root.dismiss(animated: false); window.isHidden = true }
        withUITransaction(\.uiKit.disablesAnimations, true) { root.composeMessage(AirSIMPreviewFixtures.phone) }
        let sheet = try #require(await presentedSheet(root))
        model.store.send(.messages(.composer(.presented(.view(.bodyChanged("Keep me"))))))
        let error = "Message sent, but could not be saved locally. Refresh later to confirm."
        var failed = model.snapshot; failed.errorMessage = error
        model.store.send(.snapshot(failed)); root.render()
        let alert = try #require(await eventually { () -> UIAlertController? in
            guard let alert = sheet.presentedViewController as? UIAlertController, !alert.isBeingPresented else { return nil }
            return alert
        })
        #expect(alert.title == "Error" && alert.message == error && alert.actions.map(\.title) == ["OK"])
        #expect(root.presentedViewController === sheet && !sheet.isBeingDismissed && model.store.messages.composer?.body == "Keep me")
        // Closing the composer takes the alert above it along; the unacknowledged alert returns above the tabs.
        withUITransaction(\.uiKit.disablesAnimations, true) { _ = model.store.send(.messages(.composer(.dismiss))) }
        let returned = try #require(await eventually { () -> UIAlertController? in
            guard let alert = root.presentedViewController as? UIAlertController, !alert.isBeingPresented else { return nil }
            return alert
        })
        #expect(returned.message == error && model.store.messages.composer == nil && model.store.alert != nil)
        // OK clears the alert in state, and state closes it.
        model.store.send(.alert(.presented(.clearBackendError(error)))); root.render()
        #expect(try await eventually { root.presentedViewController == nil ? true : nil } == true)
        root.render()
        #expect(root.presentedViewController == nil)
    }

    @Test func `Thread reply failure on another tab alerts above that tab's sheet without dismissing it`() async throws {
        let release = AsyncStream<Void>.makeStream()
        var state = AirSIMFeature.State(); state.firstConnectionComplete = true; state.selectedTab = .messages
        let client = AirSIMClient(snapshots: { AsyncStream { $0.finish() } }, command: { _ in }, sendSMS: { _, _ in for await _ in release.stream { break }; return .init(success: false, error: "Offline") }, selfTest: { AsyncStream { $0.finish() } }, pairing: { AsyncStream { $0.finish() } }, pair: { _, _, _ in "" })
        let model = AirSIMPresentation(store: Store(initialState: state) { AirSIMFeature() } withDependencies: { $0.airSIM = client; $0.uuid = .incrementing })
        let root = RootViewController(previewPresentation: model)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = root; window.makeKeyAndVisible(); root.render()
        defer { root.dismiss(animated: false); window.isHidden = true }
        root.openSMSConversation("123")
        let thread = try #require(await eventually { () -> MessageThreadViewController? in
            window.layoutIfNeeded()
            guard let thread = (root.tabs.selectedViewController as? UINavigationController)?.topViewController as? MessageThreadViewController, thread.viewIfLoaded?.window != nil else { return nil }
            return thread
        })
        model.store.send(.messages(.view(.replyChanged("On my way"))))
        model.store.send(.messages(.view(.sendTapped(to: "123"))))
        // The reply is still sending when the user opens a sheet on another tab.
        root.select(.dial)
        let sheet = UINavigationController(rootViewController: UIViewController()); root.present(sheet, animated: false)
        #expect(thread.viewIfLoaded?.window == nil && model.store.messages.conversation == "123")
        release.continuation.yield()
        let alert = try #require(await eventually { () -> UIAlertController? in
            guard let alert = sheet.presentedViewController as? UIAlertController, !alert.isBeingPresented else { return nil }
            return alert
        })
        #expect(alert.message == "Offline" && root.presentedViewController === sheet && !sheet.isBeingDismissed)
        #expect(model.store.messages.reply == "On my way" && model.store.selectedTab == .dial)
        withUITransaction(\.uiKit.disablesAnimations, true) { _ = model.store.send(.messages(.alert(.presented(.ok)))) }
        #expect(try await eventually { sheet.presentedViewController == nil ? true : nil } == true)
        #expect(root.presentedViewController === sheet && !sheet.isBeingDismissed)
    }

    @Test func `Screen alert closed from beneath clears its state so the next error shows`() async throws {
        let model = AirSIMPreviewFixtures.presentation(tab: .recents)
        let root = RootViewController(previewPresentation: model)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = root; window.makeKeyAndVisible(); root.render()
        defer { root.dismiss(animated: false); window.isHidden = true }
        let recents = try #require(root.tabs.selectedViewController as? UINavigationController)
        let recordings = CallRecordingsViewController(store: model.store.scope(state: \.recents.recordings, action: \.recents.recordings))
        recents.pushViewController(recordings, animated: false); window.layoutIfNeeded()
        #expect(recordings.viewIfLoaded?.window === window)
        withUITransaction(\.uiKit.disablesAnimations, true) { _ = model.store.send(.recents(.recordings(.failed("First failure")))) }
        let first = try #require(await eventually { () -> UIAlertController? in
            guard let alert = root.presentedViewController as? UIAlertController, !alert.isBeingPresented else { return nil }
            return alert
        })
        #expect(first.title == "Recording Error" && first.message == "First failure")
        // Opening the composer, e.g. from an im: link, dismisses whatever root presents, this alert included.
        withUITransaction(\.uiKit.disablesAnimations, true) { root.composeMessage(AirSIMPreviewFixtures.phone) }
        _ = try #require(await presentedSheet(root))
        #expect(try await eventually { model.store.recents.recordings.alert == nil ? true : nil } == true)
        withUITransaction(\.uiKit.disablesAnimations, true) { _ = model.store.send(.messages(.composer(.dismiss))) }
        #expect(try await eventually { root.presentedViewController == nil ? true : nil } == true)
        withUITransaction(\.uiKit.disablesAnimations, true) { _ = model.store.send(.recents(.recordings(.failed("Second failure")))) }
        let second = try #require(await eventually { () -> UIAlertController? in
            guard let alert = root.presentedViewController as? UIAlertController, !alert.isBeingPresented else { return nil }
            return alert
        })
        #expect(second !== first && second.message == "Second failure")
    }

    private func presentKeypad(_ model: AirSIMPresentation, in callWindow: UIWindow) async throws -> UINavigationController? {
        let previous = callWindow.rootViewController?.presentedViewController
        withUITransaction(\.uiKit.disablesAnimations, true) { _ = model.store.send(.activeCall(.view(.keypadButtonTapped))) }
        return try await eventually {
            guard let nav = callWindow.rootViewController?.presentedViewController as? UINavigationController, nav !== previous, !nav.isBeingPresented else { return nil }
            return nav
        }
    }

    @Test func `Speculative Back appearance does not discard a live reply destination`() async {
        let model = AirSIMPreviewFixtures.presentation(tab: .messages)
        let list = MessagesViewController(store: model.store.scope(state: \.messages, action: \.messages))
        let nav = SpeculativeNavigationController(rootViewController: list)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = nav; window.makeKeyAndVisible()
        defer { window.isHidden = true }
        list.openConversation("123")
        model.store.send(.messages(.view(.replyChanged("Reply after cancelled Back"))))
        // During an interactive pop UIKit exposes the proposed stack before didShow.
        let departingThread = nav.topViewController
        nav.pendingStack = [list]; list.viewWillAppear(true)
        // A backend update during a held Back gesture re-applies the same route.
        list.showConversationIfNeeded("123")
        nav.pendingStack = nil
        #expect(nav.topViewController === departingThread)
        #expect(model.store.messages.conversation == "123")
        #expect(nav.topViewController is MessageThreadViewController)
        await model.store.send(.messages(.view(.sendTapped(to: "123")))).finish()
        #expect(model.store.messages.reply.isEmpty)
    }

    @Test func `Contact picker search cannot filter the Contacts tab`() throws {
        let model = AirSIMPreviewFixtures.presentation(tab: .contacts)
        model.store.send(.contacts(.view(.searchChanged("Mina"))))
        let tab = ContactsViewController(store: model.store.scope(state: \.contacts, action: \.contacts))
        tab.loadViewIfNeeded(); tab.render()
        model.store.send(.composeMessage(AirSIMPreviewFixtures.phone))
        model.store.send(.messages(.composer(.presented(.view(.chooseContactTapped)))))
        let composer: StoreOf<ComposerFeature> = try #require(
            model.store.scope(\.messages.composer, action: \.messages.composer.presented)
        )
        let pickerStore: StoreOf<ContactsFeature> = try #require(composer.scope(\.contactPicker, action: \.contactPicker.presented))
        let picker = ContactsViewController(store: pickerStore)
        picker.loadViewIfNeeded(); picker.render()
        #expect(picker.sections.first?.rows.count == 3)
        picker.navigationItem.searchController?.searchBar.text = "Alex"
        picker.updateSearchResults(for: picker.navigationItem.searchController!)
        picker.render(); tab.render()
        #expect(model.store.contacts.search == "Mina")
        #expect(tab.navigationItem.searchController?.searchBar.text == "Mina")
        #expect(tab.sections.first?.rows.map(\.title) == ["Mina Kim"])
        #expect(picker.sections.first?.rows.map(\.title) == ["Alex Rivera"])
    }

    @Test func `The composer's contact picker is a phone sheet whose choice addresses the composer and closes it`() async throws {
        let model = AirSIMPreviewFixtures.presentation(tab: .messages)
        let root = RootViewController(previewPresentation: model)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = root; window.makeKeyAndVisible(); root.render()
        defer { root.dismiss(animated: false); window.isHidden = true }
        withUITransaction(\.uiKit.disablesAnimations, true) { root.composeMessage("") }
        let sheet = try #require(await presentedSheet(root))
        let composer = try #require(sheet.topViewController as? MessageComposerViewController)
        withUITransaction(\.uiKit.disablesAnimations, true) { _ = composer.store.send(.view(.chooseContactTapped)) }
        let pickerSheet = try #require(await presentedSheet(sheet))
        let picker = try #require(pickerSheet.topViewController as? ContactsViewController)
        #expect(pickerSheet.sheetPresentationController?.prefersGrabberVisible == true)
        #expect(pickerSheet.sheetPresentationController?.detents.count == 2)
        #expect(picker.navigationItem.rightBarButtonItem != nil && picker.navigationItem.title == "Choose Contact")
        let alex = try #require(await eventually { picker.sections.first?.rows.first { $0.title == "Alex Rivera" } })
        withUITransaction(\.uiKit.disablesAnimations, true) { alex.action?() }
        #expect(try await eventually { sheet.presentedViewController == nil ? true : nil } == true)
        #expect(composer.store.recipient == "+12025550102" && composer.store.contactPicker == nil)
    }

    @Test func `Multiline reply grows and contracts without replacing its text view`() {
        let model = AirSIMPreviewFixtures.presentation(tab: .messages)
        let thread = MessageThreadViewController(store: model.store.scope(state: \.messages, action: \.messages), sender: "123")
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = UINavigationController(rootViewController: thread); window.makeKeyAndVisible()
        defer { window.isHidden = true }
        thread.loadViewIfNeeded(); thread.view.layoutIfNeeded()
        model.store.send(.messages(.view(.replyChanged("First line\nSecond line\nThird line"))))
        thread.render(); thread.view.layoutIfNeeded()
        #expect(thread.reply.bounds.height > 60)
        model.store.send(.messages(.view(.replyChanged(""))))
        thread.render(); thread.view.layoutIfNeeded()
        #expect(thread.reply.bounds.height == 32)
    }
}
