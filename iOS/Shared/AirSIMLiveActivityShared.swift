import ActivityKit
import AppIntents
import Foundation

/// Shared Live Activity payload between the main app and the Dynamic Island extension; fields must stay compact and Codable.
struct AirSIMCallActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        enum Transport: String, Codable, Hashable {
            case vowlan
            case cloud
            case moduleLocal = "module_local"

            var title: String {
                switch self {
                case .vowlan: return "VoWLAN"
                case .cloud: return "Cloud"
                case .moduleLocal: return "Local Module"
                }
            }

            var systemImage: String {
                switch self {
                case .vowlan: return "wifi"
                case .cloud: return "icloud.fill"
                case .moduleLocal: return "cable.connector"
                }
            }
        }

        let callID: String
        let number: String
        let displayName: String
        let phase: Phase
        let startedAt: Date
        let transport: Transport?
        /// Cellular state of the module SIM; shown only in standby so offline and call states do not carry stale snapshots.
        let signalDBM: Int?
        let operatorName: String?
        let networkMode: String?
        let radioBand: String?
        let downloadBytesPerSecond: Double?
        let uploadBytesPerSecond: Double?
        /// Android Agent currently used for dialing and media routing. Kept optional for backward compatibility with
        /// ContentState payloads pushed by older Relays and to prevent existing Live Activities from failing to decode across upgrades.
        let agentDeviceName: String?
        let agentPhoneNumber: String?
        let agentKind: String?
        let pairedAgentCount: Int?
        let vowlanOnline: Bool?
        let bluetoothOnline: Bool?
        let cloudOnline: Bool?

        init(
            callID: String,
            number: String,
            displayName: String,
            phase: Phase,
            startedAt: Date,
            transport: Transport? = nil,
            signalDBM: Int? = nil,
            operatorName: String? = nil,
            networkMode: String? = nil,
            radioBand: String? = nil,
            downloadBytesPerSecond: Double? = nil,
            uploadBytesPerSecond: Double? = nil,
            agentDeviceName: String? = nil,
            agentPhoneNumber: String? = nil,
            agentKind: String? = nil,
            pairedAgentCount: Int? = nil,
            vowlanOnline: Bool? = nil,
            bluetoothOnline: Bool? = nil,
            cloudOnline: Bool? = nil
        ) {
            self.callID = callID
            self.number = number
            self.displayName = displayName
            self.phase = phase
            self.startedAt = startedAt
            self.transport = transport
            self.signalDBM = signalDBM
            self.operatorName = operatorName
            self.networkMode = networkMode
            self.radioBand = radioBand
            self.downloadBytesPerSecond = downloadBytesPerSecond
            self.uploadBytesPerSecond = uploadBytesPerSecond
            self.agentDeviceName = agentDeviceName
            self.agentPhoneNumber = agentPhoneNumber
            self.agentKind = agentKind
            self.pairedAgentCount = pairedAgentCount
            self.vowlanOnline = vowlanOnline
            self.bluetoothOnline = bluetoothOnline
            self.cloudOnline = cloudOnline
        }

        enum Phase: String, Codable, Hashable {
            case standby
            case cloudStandby = "cloud_standby"
            case incoming
            case active
            case held
            case offline

            var title: String {
                switch self {
                case .standby: return "Module Standby"
                case .cloudStandby: return "Cloud Online"
                case .incoming: return "Incoming Call"
                case .active: return "On Call"
                case .held: return "Call on Hold"
                case .offline: return "Module Offline"
                }
            }
        }
    }

    let moduleName: String
}

extension AirSIMCallActivityAttributes.ContentState {
    /// ActivityKit staleness only means the main app has not submitted new content recently; it does not prove the USB module is offline.
    /// Module offline state is explicitly written as `.offline` by the main app after actual HTTP probe failures.
    func liveActivityDisplayState(isStale: Bool) -> Self {
        self
    }
}

enum LiveActivityVisualPolicy {
    static func usesGlass(
        for phase: AirSIMCallActivityAttributes.ContentState.Phase
    ) -> Bool {
        switch phase {
        case .standby, .cloudStandby, .incoming, .active, .held, .offline:
            return true
        }
    }
}

enum LiveActivityVisibilityPreference {
    static let key = "airsim.live-activity-enabled"

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: key) as? Bool ?? true
    }

    static func registrationToken(
        _ storedToken: String,
        defaults: UserDefaults = .standard
    ) -> String {
        isEnabled(defaults: defaults) ? storedToken : ""
    }
}

enum IslandActionLayout {
    static let buttonSide: CGFloat = 44
    static let buttonSpacing: CGFloat = 8

    static func reservedWidth(for phase: AirSIMCallActivityAttributes.ContentState.Phase) -> CGFloat {
        switch phase {
        case .incoming: return buttonSide * 2 + buttonSpacing
        case .active, .held: return buttonSide
        case .standby, .cloudStandby, .offline: return 0
        }
    }
}

enum AirSIMLiveActivityAction: String, Equatable, Sendable {
    case answer
    case reject
    case hangup
}

enum AirSIMLiveActivityActionURL {
    static func make(action: AirSIMLiveActivityAction, callID: String) -> URL? {
        guard !callID.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = "airsim"
        components.host = "call"
        components.path = "/\(action.rawValue)"
        components.queryItems = [URLQueryItem(name: "call_id", value: callID)]
        return components.url
    }

    static func parse(_ url: URL) -> (action: AirSIMLiveActivityAction, callID: String)? {
        guard url.scheme?.lowercased() == "airsim",
              url.host?.lowercased() == "call",
              let action = AirSIMLiveActivityAction(
                rawValue: url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
              ),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let callID = components.queryItems?.first(where: { $0.name == "call_id" })?.value,
              !callID.isEmpty else { return nil }
        return (action, callID)
    }
}

/// Dynamic Island actions use a minimal module client so the extension can control calls over USB ECM without launching the main app.
private enum LiveActivityCallClient {
    enum Action {
        case answer
        case reject
        case hangup

        var endpoint: String {
            switch self {
            case .answer: return "api/calls/answer"
            case .reject: return "api/calls/reject"
            case .hangup: return "api/calls/hangup"
            }
        }
    }

    private struct Status: Decodable {
        let active: ActiveCall?
    }

    private struct ActiveCall: Decodable {
        let id: String
        let direction: String
        let state: String
    }

    static func perform(_ action: Action, callID: String) async throws {
        // An empty call ID (default parameter from Shortcuts/Siri) must never match the "" callID of a standby/offline island,
        // otherwise running the intent with no active call would end the persistent standby activity.
        guard !callID.isEmpty else { throw LiveActivityCallError.staleCall }
        let transport = WiredHTTPTransport()
        let statusResponse = try await transport.send(request(method: "GET", path: "api/calls/status"))
        guard (200..<300).contains(statusResponse.statusCode) else {
            throw LiveActivityCallError.httpStatus(statusResponse.statusCode)
        }
        let status: Status
        do {
            status = try JSONDecoder().decode(Status.self, from: statusResponse.body)
        } catch {
            throw LiveActivityCallError.invalidResponse
        }

        // perform() may be re-run from the beginning by the system (App Intents execution model): POST is the only
        // irreversible side effect and is placed after the state check to keep replays idempotent. The POST body carries call_id,
        // which the Agent validates atomically (requireActiveCallID); the client GET check is only a fast path
        // and cannot guarantee the call does not change between check and execution.
        // An already-active answer or an already-ended (or superseded) reject/hangup succeeds immediately
        // without repeating the POST or reporting confusing state errors.
        guard let active = status.active, active.id == callID else {
            try await finishStaleCall(action, callID: callID)
            return
        }

        switch action {
        case .answer:
            // Do not repeat POST on retry when already active to avoid double-answering.
            guard active.state != "active" else {
                await synchronizeActivities(after: action, callID: callID)
                return
            }
            guard active.direction == "incoming",
                  ["incoming", "waiting"].contains(active.state) else {
                throw LiveActivityCallError.invalidState
            }
        case .reject:
            guard active.direction == "incoming",
                  ["incoming", "waiting"].contains(active.state) else {
                throw LiveActivityCallError.invalidState
            }
        case .hangup:
            break
        }

        let response = try await transport.send(request(method: "POST", path: action.endpoint, callID: callID))
        if response.statusCode == 502, isStaleCallRejection(response.body) {
            // If the call is superseded after the GET check, the Agent call_id check rejects with 502 without executing
            // the action; finish via the stale branch rather than reporting an HTTP error. Genuine action failures also return
            // 502 with a different error message and are still reported as failures.
            try await finishStaleCall(action, callID: callID)
            return
        }
        guard (200..<300).contains(response.statusCode) else {
            throw LiveActivityCallError.httpStatus(response.statusCode)
        }
        await synchronizeActivities(after: action, callID: callID)
    }

    /// No matching call remains on the module endpoint: answer throws stale; reject/hangup cleans up the corresponding activity.
    /// However, the module endpoint does not govern VoWLAN/cloud calls, so an absent call on the endpoint does not prove the call ended;
    /// keep the island and throw stale in that case.
    private static func finishStaleCall(_ action: Action, callID: String) async throws {
        guard action != .answer else { throw LiveActivityCallError.staleCall }
        for activity in Activity<AirSIMCallActivityAttributes>.activities
        where activity.content.state.callID == callID {
            switch activity.content.state.transport {
            case .vowlan, .cloud:
                throw LiveActivityCallError.staleCall
            case .moduleLocal, nil:
                break
            }
        }
        await synchronizeActivities(after: action, callID: callID)
    }

    /// The Agent returns this fixed error string when rejecting a stale call_id (module-agent
    /// requireActiveCallID / answerCallForID / executeAndroidCallCommandForID),
    /// distinguishing a superseded call from a genuine action failure that also returns HTTP 502.
    private static func isStaleCallRejection(_ body: Data) -> Bool {
        struct Payload: Decodable { let error: String? }
        return (try? JSONDecoder().decode(Payload.self, from: body))?.error == "Call ID is no longer valid"
    }

    private static func request(method: String, path: String, callID: String = "") -> URLRequest {
        var request = URLRequest(url: URL(string: "http://192.168.225.1:7575/\(path)")!)
        request.httpMethod = method
        request.timeoutInterval = 8
        if method == "POST" {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            // Same call_id field as the main app LocalCallControlBody.
            request.httpBody = try? JSONEncoder().encode(["call_id": callID])
        }
        return request
    }

    private static func synchronizeActivities(after action: Action, callID: String) async {
        for activity in Activity<AirSIMCallActivityAttributes>.activities
        where activity.content.state.callID == callID {
            switch action {
            case .answer:
                let previous = activity.content.state
                let state = AirSIMCallActivityAttributes.ContentState(
                    callID: previous.callID,
                    number: previous.number,
                    displayName: previous.displayName,
                    phase: .active,
                    // Retry synchronization must not reset the call timer: keep the original start time if already active.
                    startedAt: previous.phase == .active ? previous.startedAt : Date(),
                    transport: previous.transport,
                    agentDeviceName: previous.agentDeviceName,
                    agentPhoneNumber: previous.agentPhoneNumber,
                    agentKind: previous.agentKind,
                    pairedAgentCount: previous.pairedAgentCount,
                    vowlanOnline: previous.vowlanOnline,
                    bluetoothOnline: previous.bluetoothOnline,
                    cloudOnline: previous.cloudOnline
                )
                await activity.update(ActivityContent(state: state, staleDate: nil))
            case .reject, .hangup:
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
    }
}

struct AnswerAirSIMCallIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Answer Module Call"
    // openAppWhenRun is deprecated in iOS 26.0. Gate supportedModes on iOS 26.0+ for the iOS 17.0
    // deployment target; iOS 17-25 uses the framework default (equivalent to openAppWhenRun = false).
    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { .background }

    @Parameter(title: "Call ID") var callID: String

    init() { callID = "" }
    init(callID: String) { self.callID = callID }

    func perform() async throws -> some IntentResult {
        try await LiveActivityCallClient.perform(.answer, callID: callID)
        return .result()
    }
}

struct RejectAirSIMCallIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Decline Module Call"
    // Same supportedModes availability gating as AnswerAirSIMCallIntent.
    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { .background }

    @Parameter(title: "Call ID") var callID: String

    init() { callID = "" }
    init(callID: String) { self.callID = callID }

    func perform() async throws -> some IntentResult {
        try await LiveActivityCallClient.perform(.reject, callID: callID)
        return .result()
    }
}

struct HangUpAirSIMCallIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "End Module Call"
    // Same supportedModes availability gating as AnswerAirSIMCallIntent.
    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { .background }

    @Parameter(title: "Call ID") var callID: String

    init() { callID = "" }
    init(callID: String) { self.callID = callID }

    func perform() async throws -> some IntentResult {
        try await LiveActivityCallClient.perform(.hangup, callID: callID)
        return .result()
    }
}

/// Only CustomLocalizedStringResourceConvertible errors surface their actual message to
/// Siri/Shortcuts; LocalizedError is not read by the App Intents framework.
private enum LiveActivityCallError: Error, CustomLocalizedStringResourceConvertible {
    case staleCall
    case invalidState
    case invalidResponse
    case httpStatus(Int)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .staleCall: "This call has ended or was replaced by another call"
        case .invalidState: "This action is unavailable in the current call state"
        case .invalidResponse: "The module returned an unreadable response"
        case let .httpStatus(code): "Module call endpoint returned HTTP \(code)"
        }
    }
}
