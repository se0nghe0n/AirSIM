import ActivityKit
import AppIntents
import Foundation

/// 主 App 与灵动岛扩展共享的活动数据，字段必须保持精简且可编码。
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
        /// 模块 SIM 的蜂窝状态；只在待机状态显示，离线与通话状态不携带旧快照。
        let signalDBM: Int?
        let operatorName: String?
        let networkMode: String?
        let radioBand: String?
        let downloadBytesPerSecond: Double?
        let uploadBytesPerSecond: Double?
        /// 当前用于拨号和媒体路由的 Android Agent。字段保持可选，以兼容旧版 Relay
        /// 推送的 ContentState，并避免升级时让已存在的 Live Activity 解码失败。
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
    /// ActivityKit 的 stale 只表示主 App 暂时没有提交新内容，不能证明 USB 模块离线。
    /// 模块离线由主 App 的真实 HTTP 探测失败显式写入 `.offline`。
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

/// 灵动岛动作使用最小化模块客户端，确保扩展无需启动主 App 也能走 USB ECM 控制通话。
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

        // perform() 可能被系统从头重跑（App Intents execution-model）：POST 是唯一
        // 不可逆副作用，放在状态检查之后，让重放幂等。POST body 保持 `{}`，
        // 通话身份由这里的客户端检查保证，旧活动的重试不会作用于新通话。
        // 已接通的 answer 与已结束（或已被新通话取代）的 reject/hangup 直接成功，
        // 不再重复 POST，也不再报令人困惑的状态错误。
        guard let active = status.active, active.id == callID else {
            guard action != .answer else { throw LiveActivityCallError.staleCall }
            await synchronizeActivities(after: action, callID: callID)
            return
        }

        switch action {
        case .answer:
            // 已接通的重试不重复 POST，避免双答。
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

        let response = try await transport.send(request(method: "POST", path: action.endpoint))
        guard (200..<300).contains(response.statusCode) else {
            throw LiveActivityCallError.httpStatus(response.statusCode)
        }
        await synchronizeActivities(after: action, callID: callID)
    }

    private static func request(method: String, path: String) -> URLRequest {
        var request = URLRequest(url: URL(string: "http://192.168.225.1:7575/\(path)")!)
        request.httpMethod = method
        request.timeoutInterval = 8
        if method == "POST" {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data("{}".utf8)
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
                    // 重试同步不应重置通话计时：已处于 active 就沿用原起始时间。
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
    static var title: LocalizedStringResource = "Answer Module Call"
    // openAppWhenRun 在 iOS 26.0 废弃。supportedModes 仅 26.0 可用，按部署目标
    // 17.0 做可用性门控；iOS 17–25 沿用框架默认（等价 openAppWhenRun = false）。
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
    static var title: LocalizedStringResource = "Decline Module Call"
    // 与 AnswerAirSIMCallIntent 相同的 supportedModes 门控。
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
    static var title: LocalizedStringResource = "End Module Call"
    // 与 AnswerAirSIMCallIntent 相同的 supportedModes 门控。
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

/// 只有 CustomLocalizedStringResourceConvertible 错误才会把真实消息呈现给
/// Siri/Shortcuts；LocalizedError 不被 App Intents 框架读取。
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
