import ActivityKit
import CryptoKit
import Foundation
import PushKit
import Security
import UIKit

enum VoIPPushPayloadError: LocalizedError {
    case unsupportedEvent
    case missingCallID
    case invalidCallUUID
    case invalidVirtualCall
    case expired

    var errorDescription: String? {
        switch self {
        case .unsupportedEvent: return "Invalid incoming call push"
        case .missingCallID: return "Incoming call push is missing call_id"
        case .invalidCallUUID: return "Incoming call push is missing a valid call_uuid"
        case .invalidVirtualCall: return "Virtual call has no valid local speech content"
        case .expired: return "Incoming call push expired"
        }
    }
}

struct IncomingVoIPCall: Equatable, Sendable {
    let callID: String
    let uuid: UUID
    let generation: UInt64
    let number: String?
    let callerName: String?
    let expiresAt: Date?
    /// Dashboard virtual incoming calls use local TTS only and do not trigger module AT commands or cloud PCM.
    let isVirtual: Bool
    let isOutgoing: Bool
    let ttsText: String?
    /// Cloud media uses an in-memory bearer secret, never a URL query parameter.
    let authenticatedMediaURL: URL?
    let mediaSecret: String?
    let requestedMediaTransport: CloudMediaTransport

    init(userInfo: [AnyHashable: Any], now: Date = Date()) throws {
        guard userInfo["event"] as? String == "incoming_call" else {
            throw VoIPPushPayloadError.unsupportedEvent
        }
        guard let rawCallID = userInfo["call_id"] as? String,
              !rawCallID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw VoIPPushPayloadError.missingCallID
        }
        guard let rawUUID = userInfo["call_uuid"] as? String,
              let uuid = UUID(uuidString: rawUUID) else {
            throw VoIPPushPayloadError.invalidCallUUID
        }

        let expiresAt = Self.date(from: userInfo["expires_at"])
        if let expiresAt, expiresAt <= now { throw VoIPPushPayloadError.expired }

        callID = rawCallID
        self.uuid = uuid
        generation = Self.positiveUInt64(from: userInfo["generation"]) ?? 1
        number = Self.nonEmpty(userInfo["number"] as? String)
        callerName = Self.nonEmpty(userInfo["caller_name"] as? String)
        self.expiresAt = expiresAt
        isVirtual = userInfo["virtual_call"] as? Bool == true
        isOutgoing = false
        let candidateTTS = Self.nonEmpty(userInfo["tts_text"] as? String)
        if isVirtual {
            guard let candidateTTS, candidateTTS.count <= 280 else {
                throw VoIPPushPayloadError.invalidVirtualCall
            }
            ttsText = candidateTTS
        } else {
            // Regular incoming calls never speak text carried in push payloads, preventing accidental TTS on real calls.
            ttsText = nil
        }
        authenticatedMediaURL = Self.authenticatedMediaURL(from: userInfo)
        mediaSecret = authenticatedMediaURL != nil ? Self.nonEmpty(userInfo["call_secret"] as? String) : nil
        let advertised = CloudMediaTransport(
            rawValue: Self.nonEmpty(userInfo["media_transport"] as? String) ?? ""
        ) ?? .webRTC
        requestedMediaTransport = Self.cloudMediaTransport(advertised)
    }

    init(
        outgoingCallID: String,
        uuid: UUID,
        number: String,
        secret: String,
        mediaURL: URL,
        generation: UInt64 = 1,
        mediaTransport: CloudMediaTransport = .webRTC
    ) throws {
        guard !outgoingCallID.isEmpty, secret.count >= 24,
              var components = URLComponents(url: mediaURL, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "wss", components.host?.isEmpty == false,
              components.user == nil, components.password == nil else {
            throw VoIPPushPayloadError.invalidCallUUID
        }
        components.queryItems = [
            URLQueryItem(name: "role", value: "iphone"),
        ]
        guard let authenticatedURL = components.url else {
            throw VoIPPushPayloadError.invalidCallUUID
        }
        callID = outgoingCallID
        self.uuid = uuid
        self.generation = max(1, generation)
        self.number = number
        callerName = nil
        expiresAt = Date().addingTimeInterval(5 * 60 * 60)
        isVirtual = false
        isOutgoing = true
        ttsText = nil
        authenticatedMediaURL = authenticatedURL
        mediaSecret = secret
        requestedMediaTransport = Self.cloudMediaTransport(mediaTransport)
    }

    /// New cloud calls stay on WebRTC. A `legacy_pcm` advertisement or the
    /// force-legacy preference does not select the PCM engine.
    private static func cloudMediaTransport(_ requested: CloudMediaTransport) -> CloudMediaTransport {
        switch CloudMediaTransportNegotiator.resolve(
            requested: requested,
            appSupported: [.webRTC],
            agentSupported: [.webRTC],
            forceLegacy: requested != .webRTC || CloudMediaTransportPreference.forceLegacy()
        ) {
        case .success(let transport):
            return transport
        case .failure:
            return .webRTC
        }
    }

    init(
        bluetoothCallID: String,
        uuid: UUID,
        generation: UInt64,
        number: String?
    ) {
        callID = bluetoothCallID
        self.uuid = uuid
        self.generation = max(1, generation)
        self.number = number
        callerName = nil
        expiresAt = Date().addingTimeInterval(5 * 60 * 60)
        isVirtual = false
        isOutgoing = false
        ttsText = nil
        authenticatedMediaURL = nil
        mediaSecret = nil
        requestedMediaTransport = .legacyPCM
    }

    func matches(backendID: String?, uuid: UUID?) -> Bool {
        backendID == callID || uuid == self.uuid
    }

    private static func date(from value: Any?) -> Date? {
        if let seconds = value as? TimeInterval {
            return Date(timeIntervalSince1970: seconds)
        }
        if let number = value as? NSNumber {
            return Date(timeIntervalSince1970: number.doubleValue)
        }
        guard let text = value as? String else { return nil }
        return ISO8601DateFormatter().date(from: text)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private static func positiveUInt64(from value: Any?) -> UInt64? {
        if let number = value as? NSNumber, number.uint64Value > 0 {
            return number.uint64Value
        }
        if let text = value as? String, let number = UInt64(text), number > 0 {
            return number
        }
        return nil
    }

    private static func authenticatedMediaURL(from userInfo: [AnyHashable: Any]) -> URL? {
        guard let secret = nonEmpty(userInfo["call_secret"] as? String), secret.count >= 24,
              let rawURL = nonEmpty(userInfo["media_url"] as? String),
              var components = URLComponents(string: rawURL),
              components.scheme?.lowercased() == "wss",
              components.host?.isEmpty == false,
              components.user == nil, components.password == nil else { return nil }
        components.queryItems = [
            URLQueryItem(name: "role", value: "iphone"),
        ]
        return components.url
    }
}

enum CallTransport: Equatable, Sendable {
    case vowlan
    case moduleLocal
    case cloud
}

enum CallTransportPathLossAction: Equatable, Sendable {
    case endCurrentCall
}

struct LockedCallTransport: Equatable, Sendable {
    let transport: CallTransport
    let generation: UInt64

    func onPathLoss() -> CallTransportPathLossAction { .endCurrentCall }
}

enum CloudModePreference {
    static let key = "airsim.cloud-audio-relay-enabled"

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: ConnectionModePreference.key) != nil {
            return ConnectionModeRuntimePolicy(
                mode: ConnectionModePreference.selected(defaults: defaults)
            ).startsCloud
        }
        guard !LocalModePreference.isEnabled(defaults: defaults) else { return false }
        guard defaults.object(forKey: key) != nil else { return true }
        return defaults.bool(forKey: key)
    }
}

enum LocalModePreference {
    static let key = "airsim.local-only-mode-enabled"

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: ConnectionModePreference.key) != nil {
            return ConnectionModePreference.selected(defaults: defaults) == .vowlan
        }
        return defaults.bool(forKey: key)
    }
}

enum RelayConfiguration {
    static let maintainerBundleID = "com.eric3u.airsim"
    static let maintainerRelayURL = "https://airsim-push.remotepilot.site"
    private static let legacyDJOneHubRelayURL = "https://push.remotepilot.site"

    static func effectiveURL(
        stored: String?,
        buildSetting: String?,
        bundleID: String?
    ) -> String {
        let stored = stored?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !stored.isEmpty {
            let canonicalStored = stored.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if bundleID == maintainerBundleID, canonicalStored == legacyDJOneHubRelayURL {
                return maintainerRelayURL
            }
            return stored
        }
        let buildSetting = buildSetting?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !buildSetting.isEmpty { return buildSetting }
        return bundleID == maintainerBundleID ? maintainerRelayURL : ""
    }
}

enum RelayHealthValidation {
    private struct Payload: Decodable {
        let ok: Bool
        let service: String
        let version: String
    }

    static func accepts(statusCode: Int, data: Data) -> Bool {
        version(statusCode: statusCode, data: data) != nil
    }

    static func version(statusCode: Int, data: Data) -> String? {
        guard statusCode == 200,
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.ok,
              payload.service == "airsim-push-relay",
              !payload.version.isEmpty else { return nil }
        return payload.version
    }
}

enum ConnectionPresentationMode: Equatable, Sendable {
    case vowlan
    case cloud
    case offline
}

struct ConnectionModePresentation: Equatable, Sendable {
    let mode: ConnectionPresentationMode
    let title: String
    let status: String
    let detail: String

    static func make(
        selectedMode: AirSIMConnectionMode = .automatic,
        vowlanOnline: Bool,
        cloudModeEnabled: Bool,
        cloudOnline: Bool
    ) -> ConnectionModePresentation {
        let selected = DialRouteSelector.preferred(
            mode: selectedMode,
            vowlanReady: vowlanOnline,
            cloudReady: cloudModeEnabled && cloudOnline
        )
        if selected == .vowlan {
            return ConnectionModePresentation(
                mode: .vowlan,
                title: "VoWLAN",
                status: "Connected",
                detail: cloudOnline
                    ? "Automatic mode prefers the same Wi-Fi / Android hotspot"
                    : "Same Wi-Fi / Android hotspot"
            )
        }
        if selected == .cloud {
            return ConnectionModePresentation(
                mode: .cloud,
                title: "Cloud",
                status: cloudOnline ? "Connected" : "Unreachable",
                detail: cloudOnline ? "Relay and Agent heartbeat are healthy" : "Run the cloud self-test to diagnose the issue"
            )
        }
        switch selectedMode {
        case .vowlan:
            return .init(mode: .vowlan, title: "VoWLAN", status: "Unreachable",
                         detail: "No paired and authenticated VoWLAN Agent found")
        case .cloud:
            return .init(mode: .cloud, title: "Cloud", status: "Unreachable",
                         detail: "Run the cloud self-test to diagnose the issue")
        case .automatic:
            return .init(mode: .offline, title: "Automatic", status: "No Available Route",
                         detail: "Checking VoWLAN, then cloud for a call route")
        }
    }
}

enum CloudSelfTestStepID: String, CaseIterable, Sendable {
    case configuration
    case relayIdentity
    case deviceRegistration
    case agentHeartbeat
}

enum CloudSelfTestStepState: Equatable, Sendable {
    case pending
    case running
    case passed
    case failed
}

struct CloudSelfTestStep: Identifiable, Equatable, Sendable {
    let id: CloudSelfTestStepID
    let title: String
    var state: CloudSelfTestStepState
    var detail: String
}

struct CloudSelfTestReport: Equatable, Sendable {
    var steps: [CloudSelfTestStep]
    var completedAt: Date?

    static let initial = CloudSelfTestReport(
        steps: [
            CloudSelfTestStep(id: .configuration, title: "Local Configuration", state: .pending, detail: "Waiting"),
            CloudSelfTestStep(id: .relayIdentity, title: "Relay Identity", state: .pending, detail: "Waiting"),
            CloudSelfTestStep(id: .deviceRegistration, title: "Device Registration", state: .pending, detail: "Waiting"),
            CloudSelfTestStep(id: .agentHeartbeat, title: "Agent Heartbeat", state: .pending, detail: "Waiting"),
        ],
        completedAt: nil
    )

    var allPassed: Bool {
        completedAt != nil && steps.allSatisfy { $0.state == .passed }
    }

    mutating func update(_ id: CloudSelfTestStepID, state: CloudSelfTestStepState, detail: String) {
        guard let index = steps.firstIndex(where: { $0.id == id }) else { return }
        steps[index].state = state
        steps[index].detail = detail
    }

    mutating func fail(_ id: CloudSelfTestStepID, detail: String) {
        update(id, state: .failed, detail: detail)
        for index in steps.indices where steps[index].state == .pending {
            steps[index].detail = "Skipped: a previous check failed"
        }
        completedAt = Date()
    }
}

struct CloudModeCapabilities: Equatable, Sendable {
    let usbCallingAndSMS = true
    let pushKitAndCallKit = true
    let apnsSMSNotifications = true
    let notificationRelay = true
    let publicPCM: Bool
    let remoteModuleAccess: Bool

    init(isEnabled: Bool) {
        publicPCM = isEnabled
        remoteModuleAccess = isEnabled
    }
}

enum PushRegistrationRetryPolicy {
    static func needsRetry(agentRegistered: Bool, relayRegistered: Bool) -> Bool {
        !agentRegistered || !relayRegistered
    }

    static func shouldAttemptRelay(now: Date, retryAfter: Date) -> Bool {
        now >= retryAfter
    }

    static func quotaRetryDate(now: Date) -> Date {
        // Worker free-tier requests reset at midnight UTC. Recheck sooner if the
        // account is upgraded before then, without retrying every 30 seconds.
        let nextMidnightUTC = Date(timeIntervalSince1970:
            (floor(now.timeIntervalSince1970 / 86_400) + 1) * 86_400 + 10)
        return min(now.addingTimeInterval(300), nextMidnightUTC)
    }
}

enum PushRegistrationAttemptPolicy {
    static func shouldRegisterAgent<Route: Equatable>(
        fingerprint: String,
        route: Route,
        lastFingerprint: String?,
        lastRoute: Route?
    ) -> Bool {
        fingerprint != lastFingerprint || route != lastRoute
    }

    static func shouldResetBackoff<Route: Equatable>(
        previousRoute: Route,
        currentRoute: Route
    ) -> Bool {
        previousRoute != currentRoute
    }
}

enum PushDeviceIdentity {
    static func deviceID(deviceSecret: String) -> String {
        var bytes = Array(SHA256.hash(data: Data(deviceSecret.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x40
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        let uuid = UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
        return uuid.uuidString.lowercased()
    }
}

enum CallTransportPolicy {
    static func preferred(
        vowlanReady: Bool,
        moduleLocalReachable: Bool,
        cloudMediaAvailable: Bool,
        cloudMediaEnabled: Bool = true
    ) -> CallTransport? {
        if vowlanReady { return .vowlan }
        if moduleLocalReachable { return .moduleLocal }
        if cloudMediaEnabled && cloudMediaAvailable { return .cloud }
        return nil
    }
}

enum CloudAgentStatusError: LocalizedError {
    case unavailable
    case invalidRelayURL
    case invalidResponse
    case requestLimitExceeded
    case relayHTTP(Int)

    static func relayFailure(statusCode: Int, data: Data) -> Self {
        if statusCode == 429,
           String(data: data, encoding: .utf8)?.contains("1027") == true {
            return .requestLimitExceeded
        }
        return .relayHTTP(statusCode)
    }

    var errorDescription: String? {
        switch self {
        case .unavailable: return "Cloud status is not configured"
        case .invalidRelayURL: return "Relay requires HTTPS"
        case .invalidResponse: return "Invalid Relay status response"
        case .requestLimitExceeded: return "Relay daily request quota exhausted (Cloudflare 1027). Wait for the quota to reset or upgrade the Workers plan."
        case let .relayHTTP(statusCode): return "Relay request failed (HTTP \(statusCode))"
        }
    }
}

enum CloudCommandError: LocalizedError {
    case cloudModeDisabled
    case unavailable
    case invalidResponse
    case failed(String)
    case timeout

    var errorDescription: String? {
        switch self {
        case .cloudModeDisabled: return "Cloud mode is disabled"
        case .unavailable: return "Module cloud control channel is not connected"
        case .invalidResponse: return "Relay returned an invalid cloud control response"
        case let .failed(message): return message
        case .timeout: return "Timed out waiting for the module to execute a cloud command"
        }
    }
}

private struct CloudCommandEnqueueResponse: Decodable {
    struct Call: Decodable {
        let callID: String
        let callUUID: String
        let generation: UInt64?
        let callSecret: String
        let mediaURL: String
        let mediaTransport: CloudMediaTransport?
        enum CodingKeys: String, CodingKey {
            case callID = "call_id"
            case callUUID = "call_uuid"
            case generation
            case callSecret = "call_secret"
            case mediaURL = "media_url"
            case mediaTransport = "media_transport"
        }
    }
    let accepted: Bool
    let commandID: String
    let status: String
    let agentConnected: Bool
    let call: Call?
    enum CodingKeys: String, CodingKey {
        case accepted
        case commandID = "command_id"
        case status
        case agentConnected = "agent_connected"
        case call
    }
}

struct CloudCommandResultResponse: Decodable {
    struct Result: Decodable {
        let dialing: Bool?
        let sent: Bool?
        let segments: Int?
        let history: [CallRecord]?
    }
    let commandID: String
    let status: String
    let result: Result?
    let error: String?
    enum CodingKeys: String, CodingKey {
        case commandID = "command_id"
        case status, result, error
    }
}

enum RelayEndpoint {
    static func url(base: String, path: String) -> URL? {
        guard var components = URLComponents(string: base.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.scheme?.lowercased() == "https",
              components.host?.isEmpty == false,
              components.user == nil, components.password == nil else { return nil }
        let basePath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let requestedPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = "/" + [basePath, requestedPath]
            .filter { !$0.isEmpty }
            .joined(separator: "/")
        components.query = nil
        components.fragment = nil
        return components.url
    }
}

enum VoIPPushToken {
    static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}

enum APNsEnvironment {
    static func relayValue(entitlement: String?) -> String {
        entitlement == "production" ? "production" : "sandbox"
    }

    static var current: String {
        let configured = Bundle.main.object(forInfoDictionaryKey: "AirSIMAPNSEnvironment") as? String
        return configured == "production" ? "production" : "sandbox"
    }
}

struct AgentPushRegistration: Encodable, Equatable, Sendable {
    let cloudModeEnabled: Bool
    var localMode: Bool = false
    let deviceID: String
    let deviceSecret: String
    let token: String
    let alertToken: String
    let watchVoIPToken: String
    let watchBundleID: String
    let liveActivityPushToStartToken: String
    let bundleID: String
    let environment: String
    let relayURL: String
    var mediaTransport: String = CloudMediaTransport.webRTC.rawValue
    var appMediaCapabilities: [String] = [CloudMediaTransport.webRTC.rawValue]
    var forceLegacyPCM: Bool = false
    var vowlanSecret: String? = nil

    enum CodingKeys: String, CodingKey {
        case cloudModeEnabled = "cloud_enabled"
        case localMode = "local_mode"
        case deviceID = "device_id"
        case deviceSecret = "device_secret"
        case token = "voip_token"
        case alertToken = "alert_token"
        case watchVoIPToken = "watch_voip_token"
        case watchBundleID = "watch_bundle_id"
        case liveActivityPushToStartToken = "live_activity_push_to_start_token"
        case bundleID = "bundle_id"
        case environment
        case relayURL = "relay_url"
        case mediaTransport = "media_transport"
        case appMediaCapabilities = "app_media_capabilities"
        case forceLegacyPCM = "force_legacy_pcm"
        case vowlanSecret = "vowlan_secret"
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(cloudModeEnabled, forKey: .cloudModeEnabled)
        try values.encode(localMode, forKey: .localMode)
        try values.encodeIfPresent(vowlanSecret, forKey: .vowlanSecret)
        guard !localMode else { return }

        try values.encode(deviceID, forKey: .deviceID)
        try values.encode(deviceSecret, forKey: .deviceSecret)
        try values.encode(token, forKey: .token)
        try values.encode(alertToken, forKey: .alertToken)
        try values.encode(watchVoIPToken, forKey: .watchVoIPToken)
        try values.encode(watchBundleID, forKey: .watchBundleID)
        try values.encode(liveActivityPushToStartToken, forKey: .liveActivityPushToStartToken)
        try values.encode(bundleID, forKey: .bundleID)
        try values.encode(environment, forKey: .environment)
        try values.encode(relayURL, forKey: .relayURL)
        try values.encode(mediaTransport, forKey: .mediaTransport)
        try values.encode(appMediaCapabilities, forKey: .appMediaCapabilities)
        try values.encode(forceLegacyPCM, forKey: .forceLegacyPCM)
    }

    static func local(vowlanSecret: String) -> Self {
        .init(
            cloudModeEnabled: false,
            localMode: true,
            deviceID: "",
            deviceSecret: "",
            token: "",
            alertToken: "",
            watchVoIPToken: "",
            watchBundleID: "",
            liveActivityPushToStartToken: "",
            bundleID: "",
            environment: "",
            relayURL: "",
            vowlanSecret: vowlanSecret
        )
    }
}

struct AgentPushStatus: Decodable, Sendable {
    let localMode: Bool?
    let cloudModeEnabled: Bool?
    let configured: Bool
    let callPushReady: Bool
    let messagePushReady: Bool
    let environment: String?
    let relayURL: String?
    let lastError: String?

    var preservesLocalPairing: Bool {
        if let localMode { return localMode }
        // Older AVF Agents omit local_mode but only report configured without
        // cloud credentials for a local pairing. Never infer from HTTP 200 alone.
        return configured && cloudModeEnabled == false && !callPushReady && !messagePushReady
            && (relayURL ?? "").isEmpty
    }

    enum CodingKeys: String, CodingKey {
        case localMode = "local_mode"
        case cloudModeEnabled = "cloud_enabled"
        case configured
        case callPushReady = "call_push_ready"
        case messagePushReady = "message_push_ready"
        case environment
        case relayURL = "relay_url"
        case lastError = "last_error"
    }
}

/// Exposes only diagnosable credential status to Settings without leaking device secrets or full push tokens.
struct PushRegistrationReadiness: Equatable, Sendable {
    let deviceIdentityReady: Bool
    let voIPTokenReady: Bool
    let alertTokenReady: Bool
    let relayURLReady: Bool
    let deviceIDHint: String?
    let environment: String
}

enum RemoteSMSPushError: LocalizedError {
    case unsupportedEvent
    case incomplete
    case invalidTimestamp

    var errorDescription: String? {
        switch self {
        case .unsupportedEvent: return "Invalid new message push"
        case .incomplete: return "Message push is missing required fields"
        case .invalidTimestamp: return "Invalid message push timestamp"
        }
    }
}

struct IncomingRemoteSMS: Equatable, Sendable {
    let deliveryID: String
    let sender: String
    let content: String
    let code: String?
    let timestamp: Date
    let contentTruncated: Bool

    init(userInfo: [AnyHashable: Any]) throws {
        guard userInfo["event"] as? String == "incoming_sms" else {
            throw RemoteSMSPushError.unsupportedEvent
        }
        guard let deliveryID = Self.nonEmpty(userInfo["delivery_id"] as? String),
              let sender = Self.nonEmpty(userInfo["sender"] as? String),
              let content = Self.nonEmpty(userInfo["content"] as? String) else {
            throw RemoteSMSPushError.incomplete
        }
        guard let rawTimestamp = userInfo["timestamp"] as? String,
              let timestamp = Self.parseTimestamp(rawTimestamp) else {
            throw RemoteSMSPushError.invalidTimestamp
        }
        self.deliveryID = deliveryID
        self.sender = sender
        self.content = content
        code = Self.nonEmpty(userInfo["code"] as? String)
        self.timestamp = timestamp
        contentTruncated = userInfo["content_truncated"] as? Bool ?? false
    }

    private static func parseTimestamp(_ value: String) -> Date? {
        // Agent uses RFC3339Nano; Foundation default ISO8601 formatting does not accept fractional seconds.
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        let wholeSeconds = ISO8601DateFormatter()
        wholeSeconds.formatOptions = [.withInternetDateTime]
        return wholeSeconds.date(from: value)
    }

    var message: SMSMessage {
        SMSMessage(
            sender: sender,
            content: content,
            code: code,
            timestamp: timestamp,
            deliveryID: deliveryID,
            direction: .incoming
        )
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }
}

/// PushKit is the entry point for waking CallKit after the app is suspended or terminated; module USB long-polling remains the foreground fallback.
@MainActor
final class VoIPPushController: NSObject {
    static let shared = VoIPPushController()

    private enum Keys {
        static let token = "airsim.voip-push-token"
        static let alertToken = "airsim.alert-push-token"
        static let watchVoIPToken = "airsim.watch-voip-push-token"
        static let watchBundleID = "airsim.watch-bundle-id"
        static let liveActivityPushToStartToken = "airsim.live-activity-push-to-start-token"
        static let deviceID = "airsim.push-device-id"
        static let relayURL = "airsim.push-relay-url"
        static let keychainService = "com.example.airsim.push"
        static let keychainAccount = "device-secret"
    }

    private var registry: PKPushRegistry?
    private var lastRegisteredFingerprint: String?
    private var lastRegisteredRoute: LocalAgentRoute?
    private var lastRelayRegisteredFingerprint: String?
    private var registrationInFlight = false
    private let pairingGate = SamsungPairingRegistrationGate()
    private var registrationPending = false
    private var nextRegistrationAttempt = Date.distantPast
    private var nextRelayRegistrationAttempt = Date.distantPast
    private var registrationRetryTask: Task<Void, Never>?
    private var latestRegistrationAPI = AirSIMAPI()
    private var activityKitRegistrationStarted = false
    private var activityKitRegistrationTasks: [Task<Void, Never>] = []
    private var observedActivityIDs = Set<String>()

    func start() {
        guard !LocalModePreference.isEnabled() else { return }
        startActivityKitRegistration()
        if let registry {
            // Reassigning prompts the system to re-verify existing credentials after authorization or network changes.
            registry.desiredPushTypes = [.voIP]
#if DEBUG
            print("[AirSIM PushKit] Refreshed VoIP token registration")
#endif
            return
        }
        let registry = PKPushRegistry(queue: .main)
        registry.delegate = self
        registry.desiredPushTypes = [.voIP]
        self.registry = registry
#if DEBUG
        print("[AirSIM PushKit] Created VoIP token registration")
#endif
    }

    func setLocalModeEnabled(_ enabled: Bool) {
        resetRegistrationBackoff()
        registrationRetryTask?.cancel()
        registrationRetryTask = nil
        registrationPending = false

        if enabled {
            registry?.desiredPushTypes = []
            registry?.delegate = nil
            registry = nil
            activityKitRegistrationTasks.forEach { $0.cancel() }
            activityKitRegistrationTasks.removeAll()
            activityKitRegistrationStarted = false
            observedActivityIDs.removeAll()
            UIApplication.shared.unregisterForRemoteNotifications()
            Task { await IPhoneCloudCallSession.shared.end() }
#if DEBUG
            print("[AirSIM Local] Disabled PushKit, APNs, and Relay registration")
#endif
        } else {
            start()
            UIApplication.shared.registerForRemoteNotifications()
        }
    }

    func setLiveActivityEnabled(_ enabled: Bool) {
        if enabled, #available(iOS 17.2, *),
           let token = Activity<AirSIMCallActivityAttributes>.pushToStartToken {
            UserDefaults.standard.set(
                VoIPPushToken.hex(token),
                forKey: Keys.liveActivityPushToStartToken
            )
        }
        resetRegistrationBackoff()
        Task { await syncRegistration() }
    }

    private func startActivityKitRegistration() {
        guard !LocalModePreference.isEnabled(), !activityKitRegistrationStarted else { return }
        if #available(iOS 17.2, *) {
            activityKitRegistrationStarted = true
            let pushToStartTask = Task { @MainActor [weak self] in
                for await token in Activity<AirSIMCallActivityAttributes>.pushToStartTokenUpdates {
                    guard let self, !Task.isCancelled else { return }
                    guard !LocalModePreference.isEnabled(),
                          LiveActivityVisibilityPreference.isEnabled() else { continue }
                    UserDefaults.standard.set(
                        VoIPPushToken.hex(token),
                        forKey: Keys.liveActivityPushToStartToken
                    )
                    resetRegistrationBackoff()
                    await syncRegistration()
                }
            }
            let activityUpdateTask = Task { @MainActor [weak self] in
                guard let self else { return }
                for activity in Activity<AirSIMCallActivityAttributes>.activities {
                    observeLiveActivity(activity)
                }
                for await activity in Activity<AirSIMCallActivityAttributes>.activityUpdates {
                    guard !Task.isCancelled else { return }
                    observeLiveActivity(activity)
                }
            }
            activityKitRegistrationTasks = [pushToStartTask, activityUpdateTask]
        }
    }

    func observeLiveActivity(_ activity: Activity<AirSIMCallActivityAttributes>) {
        guard LiveActivityVisibilityPreference.isEnabled() else {
            Task { await activity.end(nil, dismissalPolicy: .immediate) }
            return
        }
        guard !LocalModePreference.isEnabled() else { return }
        guard observedActivityIDs.insert(activity.id).inserted else { return }
        Task { @MainActor [weak self] in
            for await token in activity.pushTokenUpdates {
                guard let self else { return }
                await registerLiveActivityUpdateToken(
                    VoIPPushToken.hex(token),
                    activityID: activity.id,
                    callID: activity.content.state.callID
                )
            }
        }
    }

    private func registerLiveActivityUpdateToken(
        _ token: String,
        activityID: String,
        callID: String
    ) async {
        guard !LocalModePreference.isEnabled(),
              LiveActivityVisibilityPreference.isEnabled() else { return }
        guard let registration = currentRegistration(),
              let url = RelayEndpoint.url(
                base: registration.relayURL,
                path: "v1/live-activities/register"
              ) else { return }
        struct Body: Encodable {
            let deviceID: String
            let deviceSecret: String
            let activityID: String
            let callID: String
            let updateToken: String
            enum CodingKeys: String, CodingKey {
                case deviceID = "device_id"
                case deviceSecret = "device_secret"
                case activityID = "activity_id"
                case callID = "call_id"
                case updateToken = "update_token"
            }
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 8
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(Body(
            deviceID: registration.deviceID,
            deviceSecret: registration.deviceSecret,
            activityID: activityID,
            callID: callID,
            updateToken: token
        ))
        let configuration = URLSessionConfiguration.ephemeral
        _ = try? await URLSession(configuration: configuration).data(for: request)
    }

    func storeAlertToken(_ token: Data) {
        UserDefaults.standard.set(VoIPPushToken.hex(token), forKey: Keys.alertToken)
        resetRegistrationBackoff()
        Task { await syncRegistration() }
    }

    func clearAlertToken() {
        UserDefaults.standard.removeObject(forKey: Keys.alertToken)
        resetRegistrationBackoff()
    }

    func storeWatchVoIPRegistration(token: String, bundleID: String) {
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let bundleID = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, !bundleID.isEmpty else { return }
        UserDefaults.standard.set(token, forKey: Keys.watchVoIPToken)
        UserDefaults.standard.set(bundleID, forKey: Keys.watchBundleID)
        resetRegistrationBackoff()
        Task { await syncRegistration() }
    }

    func updateRelayURL(_ value: String) {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.isEmpty {
            UserDefaults.standard.removeObject(forKey: Keys.relayURL)
        } else {
            UserDefaults.standard.set(normalized, forKey: Keys.relayURL)
        }
        resetRegistrationBackoff()
        Task { await syncRegistration() }
    }

    func configuredRelayURL() -> String {
        RelayConfiguration.effectiveURL(
            stored: UserDefaults.standard.string(forKey: Keys.relayURL),
            buildSetting: Bundle.main.object(forInfoDictionaryKey: "AirSIMPushRelayURL") as? String,
            bundleID: Bundle.main.bundleIdentifier
        )
    }

    func syncRegistration(with requestedAPI: AirSIMAPI? = nil) async {
        guard !LocalModePreference.isEnabled() else { return }
        let api = requestedAPI ?? latestRegistrationAPI
        if PushRegistrationAttemptPolicy.shouldResetBackoff(
            previousRoute: latestRegistrationAPI.route,
            currentRoute: api.route
        ) {
            nextRegistrationAttempt = .distantPast
            registrationRetryTask?.cancel()
            registrationRetryTask = nil
        }
        latestRegistrationAPI = api
        let attemptedRoute = api.route
        if registrationInFlight {
            registrationPending = true
            return
        }
        guard Date() >= nextRegistrationAttempt,
              let registration = currentRegistration() else { return }
        let fingerprint = [
            registration.token, registration.alertToken, registration.watchVoIPToken,
            registration.watchBundleID, registration.liveActivityPushToStartToken,
            registration.bundleID, registration.environment,
            registration.relayURL, registration.deviceID
        ].joined(separator: "|")
        var agentRegistered = !PushRegistrationAttemptPolicy.shouldRegisterAgent(
            fingerprint: fingerprint,
            route: api.route,
            lastFingerprint: lastRegisteredFingerprint,
            lastRoute: lastRegisteredRoute
        )
        var relayRegistered = lastRelayRegisteredFingerprint == fingerprint
        guard !agentRegistered || !relayRegistered else { return }

        registrationInFlight = true
        defer {
            registrationInFlight = false
            if registrationPending {
                registrationPending = false
                Task { await syncRegistration(with: latestRegistrationAPI) }
            }
        }
#if DEBUG
        print(
            "[AirSIM PushKit] Synchronizing with Agent; VoIP=present, alert=\(registration.alertToken.isEmpty ? "none" : "present"), " +
            "env=\(registration.environment), Relay=\(registration.relayURL.isEmpty ? "unconfigured" : "configured")"
        )
#endif
        if !agentRegistered, pairingGate.beginAgentWrite() {
            defer { pairingGate.endAgentWrite() }
            do {
                guard case .vowlan = api.route else { throw CallKitBridgeError.noReachableTransport }
                if try await api.pushStatus().preservesLocalPairing {
                    // Preserve only this Agent's local choice; global Relay token
                    // refresh for other paired devices remains independent below.
                    agentRegistered = true
                } else {
                try await api.registerVoIPPush(registration)
                lastRegisteredFingerprint = fingerprint
                lastRegisteredRoute = api.route
                agentRegistered = true
#if DEBUG
                print("[AirSIM PushKit] Agent accepted device registration")
                Task {
                    try? await Task.sleep(for: .seconds(8))
                    do {
                        let status = try await api.pushStatus()
                        print(
                            "[AirSIM PushKit] Agent status; configured=\(status.configured), " +
                            "callPush=\(status.callPushReady), smsPush=\(status.messagePushReady), " +
                            "error=\(status.lastError?.isEmpty == false ? status.lastError! : "none")"
                        )
                    } catch {
                        print("[AirSIM PushKit] Failed to read Agent push status: \(error.localizedDescription)")
                    }
                }
#endif
                }
            } catch {
#if DEBUG
                print("[AirSIM PushKit] Failed to register token with module: \(error.localizedDescription)")
#endif
            }
        }

        if !relayRegistered, PushRegistrationRetryPolicy.shouldAttemptRelay(
            now: Date(), retryAfter: nextRelayRegistrationAttempt
        ) {
            do {
                try await registerDirectlyWithRelay(registration)
                lastRelayRegisteredFingerprint = fingerprint
                relayRegistered = true
                nextRelayRegistrationAttempt = .distantPast
#if DEBUG
                print("[AirSIM PushKit] Relay accepted direct device registration")
#endif
            } catch {
                if case CloudAgentStatusError.requestLimitExceeded = error {
                    nextRelayRegistrationAttempt = PushRegistrationRetryPolicy.quotaRetryDate(now: Date())
                }
#if DEBUG
                print("[AirSIM PushKit] Direct Relay sync failed: \(error.localizedDescription)")
#endif
            }
        }
        // Continue low-frequency retries when Relay succeeds but local Agent is unreachable so the module receives the same credentials once back online.
        let needsRetry = PushRegistrationRetryPolicy.needsRetry(
            agentRegistered: agentRegistered,
            relayRegistered: relayRegistered
        )
        let routeWasSuperseded = PushRegistrationAttemptPolicy.shouldResetBackoff(
            previousRoute: attemptedRoute,
            currentRoute: latestRegistrationAPI.route
        )
        let retryDelay = agentRegistered
            ? max(30, nextRelayRegistrationAttempt.timeIntervalSinceNow) : 30
        nextRegistrationAttempt = agentRegistered && relayRegistered || routeWasSuperseded
            ? .distantPast
            : Date().addingTimeInterval(retryDelay)
        if needsRetry, !routeWasSuperseded {
            scheduleRegistrationRetry(after: retryDelay)
        } else {
            registrationRetryTask?.cancel()
            registrationRetryTask = nil
        }
    }

    /// Ignores the in-process registration fingerprint cache when the user manually triggers cloud repair.
    func forceRegistrationSync(with api: AirSIMAPI = AirSIMAPI()) async {
        resetRegistrationBackoff()
        await syncRegistration(with: api)
    }

    func registrationReadiness() -> PushRegistrationReadiness {
        let defaults = UserDefaults.standard
        let secret = Self.loadOrCreateDeviceSecret()
        let deviceID = secret.map(PushDeviceIdentity.deviceID(deviceSecret:))
        let relayURL = configuredRelayURL()
        let hint = deviceID?.suffix(8).uppercased()
        return PushRegistrationReadiness(
            deviceIdentityReady: deviceID?.isEmpty == false,
            voIPTokenReady: defaults.string(forKey: Keys.token)?.isEmpty == false,
            alertTokenReady: defaults.string(forKey: Keys.alertToken)?.isEmpty == false,
            relayURLReady: RelayEndpoint.url(base: relayURL, path: "healthz") != nil,
            deviceIDHint: hint.map { "…\($0)" },
            environment: APNsEnvironment.current
        )
    }

    /// Verifies the control plane only without placing calls or sending SMS: local credentials -> Relay identity -> registration auth -> Agent heartbeat.
    func runCloudSelfTest(
        onUpdate: @MainActor @escaping (CloudSelfTestReport) -> Void = { _ in }
    ) async -> CloudSelfTestReport {
        var report = CloudSelfTestReport.initial

        report.update(.configuration, state: .running, detail: "Checking Relay, PushKit, and notification credentials")
        onUpdate(report)
        let readiness = registrationReadiness()
        var missing: [String] = []
        if !CloudModePreference.isEnabled() { missing.append("Cloud mode is not enabled") }
        if !readiness.relayURLReady { missing.append("Invalid Relay HTTPS URL") }
        if !readiness.deviceIdentityReady { missing.append("Device identity has not been generated") }
        if !readiness.voIPTokenReady { missing.append("PushKit token is not ready") }
        if !readiness.alertTokenReady { missing.append("Notification token is not ready") }
        guard missing.isEmpty, let registration = currentRegistration() else {
            report.fail(.configuration, detail: missing.isEmpty ? "Device registration information is incomplete" : missing.joined(separator: "; "))
            onUpdate(report)
            return report
        }
        report.update(
            .configuration,
            state: .passed,
            detail: "Device \(readiness.deviceIDHint ?? "Generated") · APNs \(readiness.environment)"
        )
        onUpdate(report)

        report.update(.relayIdentity, state: .running, detail: "Verifying AirSIM Relay identity")
        onUpdate(report)
        do {
            let version = try await fetchRelayHealthVersion(registration: registration)
            report.update(.relayIdentity, state: .passed, detail: "airsim-push-relay · v\(version)")
            onUpdate(report)
        } catch {
            report.fail(.relayIdentity, detail: "Relay is unreachable or its identity does not match: \(error.localizedDescription)")
            onUpdate(report)
            return report
        }

        report.update(.deviceRegistration, state: .running, detail: "Verifying device key and registration endpoint")
        onUpdate(report)
        do {
            try await registerDirectlyWithRelay(registration)
            report.update(.deviceRegistration, state: .passed, detail: "Relay accepted device registration")
            onUpdate(report)
        } catch {
            report.fail(.deviceRegistration, detail: "Registration rejected: \(error.localizedDescription)")
            onUpdate(report)
            return report
        }

        report.update(.agentHeartbeat, state: .running, detail: "Checking for an AVF Agent heartbeat in the last 90 seconds")
        onUpdate(report)
        do {
            let status = try await fetchCloudAgentStatusForDiagnostics()
            guard status.cloudOnline else {
                report.fail(.agentHeartbeat, detail: "Relay connected, but no AVF Agent heartbeat in the last 90 seconds")
                onUpdate(report)
                return report
            }
            let version = status.agentVersion?.isEmpty == false ? status.agentVersion! : "Unknown Version"
            let cellular = status.cellularState?.isEmpty == false ? " · Cellular \(status.cellularState!)" : ""
            report.update(.agentHeartbeat, state: .passed, detail: "Agent \(version) Online\(cellular)")
            report.completedAt = Date()
            onUpdate(report)
            return report
        } catch {
            report.fail(.agentHeartbeat, detail: "Heartbeat check failed: \(error.localizedDescription)")
            onUpdate(report)
            return report
        }
    }

    private func scheduleRegistrationRetry(after delay: TimeInterval) {
        guard !LocalModePreference.isEnabled() else { return }
        registrationRetryTask?.cancel()
        registrationRetryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            registrationRetryTask = nil
            await syncRegistration(with: latestRegistrationAPI)
        }
    }

    func setCloudModeEnabled(_ enabled: Bool, with api: AirSIMAPI = AirSIMAPI()) async {
        guard !LocalModePreference.isEnabled() else { return }
        resetRegistrationBackoff()
        WatchCallCoordinator.shared.refreshMediaPolicy()
        // PushKit, CallKit, and APNs form the notification control plane for local USB mode and must not be turned off
        // with the cloud PCM toggle. The Agent stays registered with the notification relay; the preference controls only
        // cloud status polling and network PCM media channels.
        try? await api.setPushCloudEnabled(true)
        if !enabled {
            await IPhoneCloudCallSession.shared.end()
        }
        await syncRegistration(with: api)
    }

    /// Checks whether the Agent is still online via the latest Relay heartbeat when local USB/ECM is unreachable.
    /// Device secrets in the request body are encoded in memory only using an ephemeral URLSession that never writes to disk.
    func fetchCloudAgentStatus() async throws -> CloudAgentStatus {
        guard CloudModePreference.isEnabled() else {
            throw CloudAgentStatusError.unavailable
        }
        return try await fetchCloudAgentStatusForDiagnostics()
    }

    /// The self-check reads the heartbeat even when cloud PCM is disabled so the user can still evaluate readiness.
    func fetchCloudAgentStatusForDiagnostics() async throws -> CloudAgentStatus {
        guard let registration = currentRegistration() else {
            throw CloudAgentStatusError.unavailable
        }
        guard let url = RelayEndpoint.url(
            base: registration.relayURL,
            path: "v1/devices/status"
        ) else { throw CloudAgentStatusError.invalidRelayURL }

        struct RequestBody: Encodable {
            let deviceID: String
            let deviceSecret: String

            enum CodingKeys: String, CodingKey {
                case deviceID = "device_id"
                case deviceSecret = "device_secret"
            }
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 5
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(RequestBody(
            deviceID: registration.deviceID,
            deviceSecret: registration.deviceSecret
        ))

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 6
        let (data, response) = try await URLSession(configuration: configuration).data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw CloudAgentStatusError.invalidResponse
        }
        return try JSONDecoder().decode(CloudAgentStatus.self, from: data)
    }

    func startCloudOutgoingCall(
        number: String,
        mediaTransport: CloudMediaTransport? = nil,
        timeout: TimeInterval = 25
    ) async throws -> IncomingVoIPCall {
        let commandID = UUID()
        let enqueue = try await enqueueCloudCommand(
            commandID: commandID,
            type: "dial",
            number: number,
            message: nil,
            mediaTransport: mediaTransport
        )
        guard enqueue.accepted, let call = enqueue.call,
              let uuid = UUID(uuidString: call.callUUID),
              let mediaURL = URL(string: call.mediaURL) else {
            throw CloudCommandError.invalidResponse
        }
        let outcome = try await waitForCloudCommand(commandID: commandID, timeout: timeout)
        guard outcome.status == "completed", outcome.result?.dialing == true else {
            throw CloudCommandError.failed(outcome.error ?? "Module could not start dialing")
        }
        return try IncomingVoIPCall(
            outgoingCallID: call.callID,
            uuid: uuid,
            number: number,
            secret: call.callSecret,
            mediaURL: mediaURL,
            generation: call.generation ?? 1,
            mediaTransport: call.mediaTransport ?? .webRTC
        )
    }

    func sendCloudSMS(to number: String, message: String) async throws -> SMSSendResult {
        let commandID = UUID()
        let enqueue = try await enqueueCloudCommand(
            commandID: commandID,
            type: "send_sms",
            number: number,
            message: message
        )
        guard enqueue.accepted else { throw CloudCommandError.invalidResponse }
        let outcome = try await waitForCloudCommand(commandID: commandID, timeout: 5 * 60)
        guard outcome.status == "completed", outcome.result?.sent == true else {
            throw CloudCommandError.failed(outcome.error ?? "Module failed to send the message")
        }
        return SMSSendResult(sent: true, segments: outcome.result?.segments)
    }

    func fetchCloudCallHistory() async throws -> [CallRecord] {
        let commandID = UUID()
        let enqueue = try await enqueueCloudCommand(
            commandID: commandID, type: "call_history", number: "", message: nil
        )
        guard enqueue.accepted else { throw CloudCommandError.invalidResponse }
        let outcome = try await waitForCloudCommand(commandID: commandID, timeout: 20)
        guard outcome.status == "completed", let history = outcome.result?.history else {
            throw CloudCommandError.failed(outcome.error ?? "Could not load call history from the Android phone")
        }
        return history
    }

    func sendCloudDTMF(_ digit: String) async throws {
        let commandID = UUID()
        let enqueue = try await enqueueCloudCommand(
            commandID: commandID,
            type: "dtmf",
            number: digit,
            message: nil
        )
        guard enqueue.accepted else { throw CloudCommandError.invalidResponse }
        let outcome = try await waitForCloudCommand(commandID: commandID, timeout: 15)
        guard outcome.status == "completed", outcome.result?.sent == true else {
            throw CloudCommandError.failed(outcome.error ?? "Module failed to send DTMF")
        }
    }

    private func enqueueCloudCommand(
        commandID: UUID,
        type: String,
        number: String,
        message: String?,
        mediaTransport: CloudMediaTransport? = nil
    ) async throws -> CloudCommandEnqueueResponse {
        guard CloudModePreference.isEnabled() else { throw CloudCommandError.cloudModeDisabled }
        guard let registration = currentRegistration(),
              let url = RelayEndpoint.url(base: registration.relayURL, path: "v1/commands/enqueue") else {
            throw CloudCommandError.unavailable
        }
        var body: [String: String] = [
            "device_id": registration.deviceID,
            "device_secret": registration.deviceSecret,
            "command_id": commandID.uuidString.lowercased(),
            "type": type,
        ]
        if type != "call_history" { body["number"] = number }
        if let message { body["message"] = message }
        if let mediaTransport { body["media_transport"] = mediaTransport.rawValue }
        return try await relayRequest(url: url, body: body, as: CloudCommandEnqueueResponse.self)
    }

    private func waitForCloudCommand(commandID: UUID, timeout: TimeInterval) async throws -> CloudCommandResultResponse {
        guard let registration = currentRegistration(),
              let url = RelayEndpoint.url(base: registration.relayURL, path: "v1/commands/result") else {
            throw CloudCommandError.unavailable
        }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let response = try await relayRequest(
                url: url,
                body: [
                    "device_id": registration.deviceID,
                    "device_secret": registration.deviceSecret,
                    "command_id": commandID.uuidString.lowercased(),
                ],
                as: CloudCommandResultResponse.self
            )
            if response.status == "completed" || response.status == "failed" { return response }
            try await Task.sleep(for: .milliseconds(500))
        }
        throw CloudCommandError.timeout
    }

    private func relayRequest<Response: Decodable>(
        url: URL,
        body: [String: String],
        as type: Response.Type
    ) async throws -> Response {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 12
        let (data, response) = try await URLSession(configuration: configuration).data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CloudCommandError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode(RelayErrorResponse.self, from: data).error)
            throw CloudCommandError.failed(message ?? "Relay HTTP \(http.statusCode)")
        }
        guard let decoded = try? AirSIMAPI.makeDecoder().decode(type, from: data) else {
            throw CloudCommandError.invalidResponse
        }
        return decoded
    }

    /// Verifies the HTTPS control plane from this iPhone to the Relay without sending device secrets.
    func relayHealthReachable() async -> Bool {
        guard let registration = currentRegistration(),
              (try? await fetchRelayHealthVersion(registration: registration)) != nil else { return false }
        return true
    }

    private func fetchRelayHealthVersion(registration: AgentPushRegistration) async throws -> String {
        guard let url = RelayEndpoint.url(base: registration.relayURL, path: "healthz") else {
            throw CloudAgentStatusError.invalidRelayURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 5
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 6
        let (data, response) = try await URLSession(configuration: configuration).data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CloudAgentStatusError.invalidResponse
        }
        guard http.statusCode == 200 else {
            throw CloudAgentStatusError.relayFailure(statusCode: http.statusCode, data: data)
        }
        guard let version = RelayHealthValidation.version(statusCode: http.statusCode, data: data) else {
            throw CloudAgentStatusError.invalidResponse
        }
        return version
    }

    private func registerDirectlyWithRelay(_ registration: AgentPushRegistration) async throws {
        guard let url = RelayEndpoint.url(
            base: registration.relayURL,
            path: "v1/devices/register"
        ) else { throw CloudAgentStatusError.invalidRelayURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 8
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(registration)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 10
        let (data, response) = try await URLSession(configuration: configuration).data(for: request)
#if DEBUG
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            print("[AirSIM PushKit] Relay registration rejected; HTTP=\(http.statusCode)")
        }
#endif
        guard let http = response as? HTTPURLResponse else {
            throw CloudAgentStatusError.invalidResponse
        }
        guard http.statusCode == 200 else {
            throw CloudAgentStatusError.relayFailure(statusCode: http.statusCode, data: data)
        }
        struct ResponseBody: Decodable { let registered: Bool }
        guard let result = try? JSONDecoder().decode(ResponseBody.self, from: data),
              result.registered else { throw CloudAgentStatusError.invalidResponse }
    }

    private func store(token: String) {
        UserDefaults.standard.set(token, forKey: Keys.token)
        resetRegistrationBackoff()
        Task { await syncRegistration() }
    }

    private func resetRegistrationBackoff() {
        lastRegisteredFingerprint = nil
        lastRegisteredRoute = nil
        lastRelayRegisteredFingerprint = nil
        nextRegistrationAttempt = .distantPast
        nextRelayRegistrationAttempt = .distantPast
    }

    func cloudCallControlCredentials() -> CloudCallControlCredentials? {
        guard let secret = Self.loadOrCreateDeviceSecret() else { return nil }
        let deviceID = PushDeviceIdentity.deviceID(deviceSecret: secret)
        let relayURL = configuredRelayURL()
        guard RelayEndpoint.url(base: relayURL, path: "/") != nil else { return nil }
        return CloudCallControlCredentials(
            relayURL: relayURL,
            deviceID: deviceID,
            deviceSecret: secret
        )
    }

    func performAndroidPairing<T>(
        localOnly: Bool,
        operation: (AgentPushRegistration) async throws -> T
    ) async throws -> T {
        try await pairingGate.withPairing {
            guard let registration = self.pairingRegistration(localOnly: localOnly) else {
                throw SamsungPairingClientError.registrationUnavailable
            }
            return try await operation(registration)
        }
    }

    func pairingRegistration(localOnly: Bool = LocalModePreference.isEnabled()) -> AgentPushRegistration? {
        guard let secret = try? VoWLANCredentialStore.loadOrCreate().encodedSecret else { return nil }
        return try? SamsungPairingRegistrationPolicy.registration(
            localOnly: localOnly, vowlanSecret: secret,
            cloudRegistration: { self.currentRegistration(allowLocalMode: true) }
        )
    }

    private func currentRegistration(allowLocalMode: Bool = false) -> AgentPushRegistration? {
        guard allowLocalMode || !LocalModePreference.isEnabled() else { return nil }
        guard let token = UserDefaults.standard.string(forKey: Keys.token), !token.isEmpty else {
#if DEBUG
            print("[AirSIM PushKit] No VoIP token yet, skipping sync")
#endif
            return nil
        }
        let defaults = UserDefaults.standard
        guard let secret = Self.loadOrCreateDeviceSecret() else {
#if DEBUG
            print("[AirSIM PushKit] Unable to create device secret, skipping sync")
#endif
            return nil
        }
        let deviceID = PushDeviceIdentity.deviceID(deviceSecret: secret)
        defaults.set(deviceID, forKey: Keys.deviceID)
        let relayURL = configuredRelayURL()
        let capabilities = CloudModeCapabilities(isEnabled: CloudModePreference.isEnabled())
        return AgentPushRegistration(
            cloudModeEnabled: capabilities.notificationRelay,
            localMode: false,
            deviceID: deviceID,
            deviceSecret: secret,
            token: token,
            alertToken: defaults.string(forKey: Keys.alertToken) ?? "",
            watchVoIPToken: defaults.string(forKey: Keys.watchVoIPToken) ?? "",
            watchBundleID: defaults.string(forKey: Keys.watchBundleID) ?? "com.example.airsim.watchkitapp",
            liveActivityPushToStartToken: LiveActivityVisibilityPreference.registrationToken(
                defaults.string(forKey: Keys.liveActivityPushToStartToken) ?? "",
                defaults: defaults
            ),
            bundleID: Bundle.main.bundleIdentifier ?? "com.example.airsim",
            environment: APNsEnvironment.current,
            relayURL: relayURL,
            mediaTransport: CloudMediaTransportPreference.requested().rawValue,
            appMediaCapabilities: [CloudMediaTransport.webRTC.rawValue],
            forceLegacyPCM: CloudMediaTransportPreference.forceLegacy(),
            vowlanSecret: nil
        )
    }

    private static func loadOrCreateDeviceSecret() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Keys.keychainService,
            kSecAttrAccount as String: Keys.keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
           let data = item as? Data,
           let value = String(data: data, encoding: .utf8) {
            return value
        }

        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            return nil
        }
        let value = Data(bytes).base64EncodedString()
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Keys.keychainService,
            kSecAttrAccount as String: Keys.keychainAccount,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: Data(value.utf8)
        ]
        guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { return nil }
        return value
    }
}

extension VoIPPushController: PKPushRegistryDelegate {
    nonisolated func pushRegistry(
        _ registry: PKPushRegistry,
        didUpdate pushCredentials: PKPushCredentials,
        for type: PKPushType
    ) {
        guard type == .voIP else { return }
        let token = VoIPPushToken.hex(pushCredentials.token)
        Task { @MainActor [weak self] in
#if DEBUG
            print("[AirSIM PushKit] VoIP token updated; bytes=\(pushCredentials.token.count)")
#endif
            self?.store(token: token)
        }
    }

    nonisolated func pushRegistry(
        _ registry: PKPushRegistry,
        didInvalidatePushTokenFor type: PKPushType
    ) {
        guard type == .voIP else { return }
        Task { @MainActor [weak self] in
#if DEBUG
            print("[AirSIM PushKit] VoIP token invalidated")
#endif
            UserDefaults.standard.removeObject(forKey: Keys.token)
            self?.resetRegistrationBackoff()
        }
    }

    nonisolated func pushRegistry(
        _ registry: PKPushRegistry,
        didReceiveIncomingPushWith payload: PKPushPayload,
        for type: PKPushType,
        completion: @escaping () -> Void
    ) {
        guard type == .voIP else {
            completion()
            return
        }
        guard !LocalModePreference.isEnabled() else {
            completion()
            return
        }
        let userInfo = payload.dictionaryPayload
        Task { @MainActor in
            do {
                let call = try IncomingVoIPCall(userInfo: userInfo)
                CallKitController.shared.reportIncomingPush(call) { _ in completion() }
                WatchCallCoordinator.shared.publishIncoming(call)
                if call.callerName == nil, let number = call.number {
                    Task {
                        let resolvedName = await Task.detached(priority: .userInitiated) {
                            try? ContactFetcher().displayName(for: number)
                        }.value
                        if let resolvedName, resolvedName != number {
                            WatchCallCoordinator.shared.publishIncoming(call, callerName: resolvedName)
                        }
                    }
                }
            } catch {
#if DEBUG
                print("[AirSIM PushKit] Dropping invalid incoming call push: \(error.localizedDescription)")
#endif
                completion()
            }
        }
    }
}
