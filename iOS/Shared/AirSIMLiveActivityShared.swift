import ActivityKit
import AppIntents
import Foundation

/// Shared Live Activity payload between the main app and the Dynamic Island extension; fields must stay compact and Codable.
struct AirSIMCallActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        enum Transport: String, Codable, Hashable {
            case vowlan
            case cloud
            case unavailable

            init(from decoder: Decoder) throws {
                let container = try decoder.singleValueContainer()
                let value = try container.decode(String.self)
                // Existing activities may carry a retired transport; retain their other fields.
                self = Self(rawValue: value) ?? .unavailable
            }

            var title: String {
                switch self {
                case .vowlan: return "VoWLAN"
                case .cloud: return "Cloud"
                case .unavailable: return "Unavailable"
                }
            }

            var systemImage: String {
                switch self {
                case .vowlan: return "wifi"
                case .cloud: return "icloud.fill"
                case .unavailable: return "exclamationmark.triangle"
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

/// App-only dispatch is installed during App initialization; the widget contains no credentials.
@MainActor
final class LiveActivityCallActionDispatcher {
    static let shared = LiveActivityCallActionDispatcher()
    var handler: ((AirSIMLiveActivityAction, String) async throws -> Void)?

    func perform(_ action: AirSIMLiveActivityAction, callID: String) async throws {
        guard !callID.isEmpty else { throw LiveActivityCallError.staleCall }
        guard let handler else { throw LiveActivityCallError.unavailable }
        do { try await handler(action, callID) }
        catch let error as LiveActivityCallError { throw error }
        catch { throw LiveActivityCallError.unavailable }
    }
}

enum LiveActivityCallActionPolicy {
    static func shouldPerform(_ action: AirSIMLiveActivityAction, callID: String,
                              currentCallID: String?, state: String?, direction: String?) throws -> Bool {
        guard !callID.isEmpty, callID == currentCallID else { throw LiveActivityCallError.staleCall }
        guard let state, ["incoming", "waiting", "connecting", "dialing", "alerting", "active", "held"].contains(state)
        else { throw LiveActivityCallError.staleCall }
        switch action {
        case .answer:
            if ["connecting", "active", "held"].contains(state) { return false }
            guard direction == "incoming", ["incoming", "waiting"].contains(state)
            else { throw LiveActivityCallError.invalidState }
        case .reject:
            guard direction == "incoming", ["incoming", "waiting"].contains(state)
            else { throw LiveActivityCallError.invalidState }
        case .hangup:
            break
        }
        return true
    }
}

enum LiveActivityCallError: Error, CustomLocalizedStringResourceConvertible {
    case staleCall, invalidState, unavailable
    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .staleCall: "This call has ended or was replaced by another call"
        case .invalidState: "This action is unavailable in the current call state"
        case .unavailable: "The call could not be controlled. Check the connection to your Android phone."
        }
    }
}

struct AnswerAirSIMCallIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Answer AirSIM Call"
    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { .background }
    static var authenticationPolicy: IntentAuthenticationPolicy { .alwaysAllowed }
    @Parameter(title: "Call ID") var callID: String
    init() { callID = "" }
    init(callID: String) { self.callID = callID }
    @MainActor
    func perform() async throws -> some IntentResult {
        try await LiveActivityCallActionDispatcher.shared.perform(.answer, callID: callID)
        return .result()
    }
}

struct RejectAirSIMCallIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Decline AirSIM Call"
    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { .background }
    static var authenticationPolicy: IntentAuthenticationPolicy { .alwaysAllowed }
    @Parameter(title: "Call ID") var callID: String
    init() { callID = "" }
    init(callID: String) { self.callID = callID }
    @MainActor
    func perform() async throws -> some IntentResult {
        try await LiveActivityCallActionDispatcher.shared.perform(.reject, callID: callID)
        return .result()
    }
}

struct HangUpAirSIMCallIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "End AirSIM Call"
    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { .background }
    static var authenticationPolicy: IntentAuthenticationPolicy { .alwaysAllowed }
    @Parameter(title: "Call ID") var callID: String
    init() { callID = "" }
    init(callID: String) { self.callID = callID }
    @MainActor
    func perform() async throws -> some IntentResult {
        try await LiveActivityCallActionDispatcher.shared.perform(.hangup, callID: callID)
        return .result()
    }
}

/// A stale island must never control a newer call after the app opens.
enum LiveActivityActionGate {
    static func accepts(callID: String, currentCallID: String?, callIsLive: Bool) -> Bool {
        callIsLive && !callID.isEmpty && currentCallID == callID
    }
}
