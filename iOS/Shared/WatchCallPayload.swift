import Foundation

enum WatchCallPhase: String, Codable, Sendable {
    case idle
    case incoming
    case connecting
    case active
    case ended
}

struct WatchCallPayload: Equatable, Sendable {
    let callID: String
    let callUUID: UUID?
    let phase: WatchCallPhase
    let number: String?
    let callerName: String?
    let transport: String?
    let updatedAt: Date

    var dictionary: [String: Any] {
        var value: [String: Any] = [
            "event": "watch_call_state",
            "call_id": callID,
            "call_uuid": callUUID?.uuidString ?? "",
            "phase": phase.rawValue,
            "updated_at": updatedAt.timeIntervalSince1970,
        ]
        if let number, !number.isEmpty { value["number"] = number }
        if let callerName, !callerName.isEmpty { value["caller_name"] = callerName }
        if let transport, !transport.isEmpty { value["transport"] = transport }
        return value
    }

    init(
        callID: String,
        callUUID: UUID?,
        phase: WatchCallPhase,
        number: String?,
        callerName: String?,
        transport: String? = nil,
        updatedAt: Date
    ) {
        self.callID = callID
        self.callUUID = callUUID
        self.phase = phase
        self.number = number
        self.callerName = callerName
        self.transport = transport
        self.updatedAt = updatedAt
    }

    init?(dictionary: [String: Any]) {
        guard dictionary["event"] as? String == "watch_call_state",
              let phaseValue = dictionary["phase"] as? String,
              let phase = WatchCallPhase(rawValue: phaseValue),
              let updatedAt = dictionary["updated_at"] as? TimeInterval else { return nil }
        let callID = dictionary["call_id"] as? String ?? ""
        let uuidValue = dictionary["call_uuid"] as? String
        self.init(
            callID: callID,
            callUUID: uuidValue.flatMap(UUID.init(uuidString:)),
            phase: phase,
            number: dictionary["number"] as? String,
            callerName: dictionary["caller_name"] as? String,
            transport: dictionary["transport"] as? String,
            updatedAt: Date(timeIntervalSince1970: updatedAt)
        )
    }
}

enum WatchVoIPPayloadError: LocalizedError, Equatable {
    case unsupportedEvent
    case missingCallID
    case invalidCallUUID
    case missingSecret
    case invalidMediaURL
    case expired
    case invalidLocalMedia
    case legacyPCMNotCarrier

    var errorDescription: String? {
        switch self {
        case .unsupportedEvent: return "Invalid watch call notification"
        case .missingCallID: return "The watch call notification is missing call_id"
        case .invalidCallUUID: return "The watch call notification is missing a valid call_uuid"
        case .missingSecret: return "The watch call notification is missing a media key"
        case .invalidMediaURL: return "The watch call notification is missing a secure media address"
        case .expired: return "The watch call notification has expired"
        case .invalidLocalMedia: return "Invalid watch local audio parameters"
        case .legacyPCMNotCarrier: return "The watch cannot use legacy PCM as its audio carrier"
        }
    }
}

struct WatchLocalPCMEndpoint: Equatable, Sendable {
    let host: String
    let port: UInt16
    let secret: Data

    init?(dictionary: [String: Any]) {
        guard let host = dictionary["pcm_host"] as? String,
              let rawPort = dictionary["pcm_port"] as? Int,
              (1024...65535).contains(rawPort),
              let encoded = dictionary["pcm_secret"] as? String else { return nil }
        let octets = host.split(separator: ".").compactMap { UInt8($0) }
        guard octets.count == 4,
              octets[0] == 10 || (octets[0] == 172 && (16...31).contains(octets[1]))
                || (octets[0] == 192 && octets[1] == 168) else { return nil }
        let base64 = encoded.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padded = base64 + String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let secret = Data(base64Encoded: padded), secret.count >= 32 else { return nil }
        self.host = host
        port = UInt16(rawPort)
        self.secret = secret
    }
}

enum WatchCallMedia: Equatable, Sendable {
    /// The iPhone `CloudWebRTCPeer` is the microphone and speaker. The watch does not open a PCM socket.
    case iphoneWebRTC
    case local(WatchLocalPCMEndpoint)
    /// APNs does not carry the paired VoWLAN secret; fetch it from the paired iPhone on answer.
    case pendingLocal
}

/// Watch cloud audio is always the iPhone WebRTC peer. A missing transport defaults to
/// `webrtc`. `legacy_pcm` is not a watch audio carrier.
enum WatchCloudAudioPlan {
    static let requestedTransport = "webrtc"
    static let iphoneRoute = "iphone"

    static func accepts(transport: String?) -> Bool {
        let trimmed = transport?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty || trimmed == requestedTransport
    }

    static func dialReply(
        requestID: UUID, callID: String, callUUID: UUID, number: String, expiresAt: Date
    ) -> [String: Any] {
        [
            "ok": true,
            "request_id": requestID.uuidString,
            "call_id": callID,
            "call_uuid": callUUID.uuidString,
            "number": number,
            "media_transport": requestedTransport,
            "media_route": iphoneRoute,
            "expires_at": expiresAt.timeIntervalSince1970,
        ]
    }

    static func companionControl(action: String, callID: String, callUUID: UUID) -> [String: Any] {
        [
            "action": action,
            "call_id": callID,
            "call_uuid": callUUID.uuidString,
        ]
    }
}

/// Complete VoIP session required for direct answering on Apple Watch. Media keys are kept in memory only
/// and never included in WatchConnectivity state mirroring or notification bodies.
struct WatchVoIPCall: Equatable, Sendable {
    let callID: String
    let uuid: UUID
    let number: String?
    let callerName: String?
    let expiresAt: Date?
    let media: WatchCallMedia
    let isOutgoing: Bool
    /// Local VoWLAN control still ends on the hotspot. Audio is the iPhone WebRTC peer.
    let endsOnVoWLAN: Bool

    /// Cloud media stays on the iPhone. The watch payload never carries a PCM WebSocket.
    var authenticatedMediaURL: URL? { nil }

    var opensBinaryPCMWebSocket: Bool {
        switch media {
        case .iphoneWebRTC, .local, .pendingLocal:
            return false
        }
    }

    var displayName: String { callerName ?? number ?? "AirSIM" }

    init(userInfo: [AnyHashable: Any], now: Date = Date()) throws {
        guard userInfo["event"] as? String == "incoming_call" else {
            throw WatchVoIPPayloadError.unsupportedEvent
        }
        guard let callID = Self.nonEmpty(userInfo["call_id"] as? String) else {
            throw WatchVoIPPayloadError.missingCallID
        }
        guard let rawUUID = userInfo["call_uuid"] as? String,
              let uuid = UUID(uuidString: rawUUID) else {
            throw WatchVoIPPayloadError.invalidCallUUID
        }
        let expiresAt = Self.date(from: userInfo["expires_at"])
        if let expiresAt, expiresAt <= now { throw WatchVoIPPayloadError.expired }
        let media: WatchCallMedia
        var endsOnVoWLAN = false
        if userInfo["media_route"] as? String == "vowlan" {
            endsOnVoWLAN = true
            let dictionary = Dictionary(uniqueKeysWithValues: userInfo.compactMap { key, value in
                (key as? String).map { ($0, value) }
            })
            if let endpoint = WatchLocalPCMEndpoint(dictionary: dictionary) {
                media = .local(endpoint)
            } else if WatchCloudAudioPlan.accepts(transport: userInfo["media_transport"] as? String) {
                media = .iphoneWebRTC
            } else {
                throw WatchVoIPPayloadError.invalidLocalMedia
            }
        } else if userInfo["media_route"] as? String == WatchCloudAudioPlan.iphoneRoute
            || userInfo["call_secret"] != nil
            || userInfo["media_url"] != nil
            || userInfo["media_transport"] != nil {
            let rawTransport = userInfo["media_transport"] as? String
            guard WatchCloudAudioPlan.accepts(transport: rawTransport) else {
                throw WatchVoIPPayloadError.legacyPCMNotCarrier
            }
            media = .iphoneWebRTC
        } else {
            media = .pendingLocal
        }
        self.callID = callID
        self.uuid = uuid
        number = Self.nonEmpty(userInfo["number"] as? String)
        callerName = Self.nonEmpty(userInfo["caller_name"] as? String)
        self.expiresAt = expiresAt
        self.media = media
        isOutgoing = false
        self.endsOnVoWLAN = endsOnVoWLAN
    }

    init(outgoingReply: [String: Any]) throws {
        let route = outgoingReply["media_route"] as? String
        if route != "vowlan" {
            guard route == WatchCloudAudioPlan.iphoneRoute,
                  WatchCloudAudioPlan.accepts(transport: outgoingReply["media_transport"] as? String) else {
                throw WatchVoIPPayloadError.legacyPCMNotCarrier
            }
        }
        var payload: [AnyHashable: Any] = outgoingReply
        payload["event"] = "incoming_call"
        let parsed = try WatchVoIPCall(userInfo: payload)
        self = WatchVoIPCall(
            callID: parsed.callID,
            uuid: parsed.uuid,
            number: parsed.number,
            callerName: parsed.callerName,
            expiresAt: parsed.expiresAt,
            media: parsed.media,
            isOutgoing: true,
            endsOnVoWLAN: parsed.endsOnVoWLAN
        )
    }

    func usingIPhoneVoWLANAudio() -> WatchVoIPCall {
        WatchVoIPCall(
            callID: callID, uuid: uuid, number: number, callerName: callerName,
            expiresAt: expiresAt, media: .iphoneWebRTC, isOutgoing: isOutgoing,
            endsOnVoWLAN: true
        )
    }

    func usingLocalMedia(_ endpoint: WatchLocalPCMEndpoint) -> WatchVoIPCall {
        WatchVoIPCall(
            callID: callID, uuid: uuid, number: number, callerName: callerName,
            expiresAt: expiresAt, media: .local(endpoint), isOutgoing: isOutgoing,
            endsOnVoWLAN: true
        )
    }

    private init(
        callID: String, uuid: UUID, number: String?, callerName: String?,
        expiresAt: Date?, media: WatchCallMedia, isOutgoing: Bool,
        endsOnVoWLAN: Bool = false
    ) {
        self.callID = callID
        self.uuid = uuid
        self.number = number
        self.callerName = callerName
        self.expiresAt = expiresAt
        self.media = media
        self.isOutgoing = isOutgoing
        self.endsOnVoWLAN = endsOnVoWLAN
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }

    private static func date(from value: Any?) -> Date? {
        if let value = value as? TimeInterval { return Date(timeIntervalSince1970: value) }
        if let value = value as? NSNumber { return Date(timeIntervalSince1970: value.doubleValue) }
        guard let value = value as? String else { return nil }
        return ISO8601DateFormatter().date(from: value)
    }
}

enum WatchDialNumber {
    static func validated(_ input: String) -> String? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = CharacterSet(charactersIn: "+*#0123456789")
        guard !value.isEmpty, value.count <= 82,
              value.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        return value
    }
}

struct WatchIncomingNotificationPlan: Equatable, Sendable {
    static let maximumDeliveryAge: TimeInterval = 45

    let identifier: String
    let title: String
    let body: String

    init?(payload: WatchCallPayload, now: Date = Date()) {
        guard payload.phase == .incoming, !payload.callID.isEmpty else { return nil }
        let age = now.timeIntervalSince(payload.updatedAt)
        guard age >= -5, age <= Self.maximumDeliveryAge else { return nil }
        let name = payload.callerName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let number = payload.number?.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = [name, number]
            .compactMap { value in value.flatMap { $0.isEmpty ? nil : $0 } }
            .reduce(into: [String]()) { result, value in
                if !result.contains(value) { result.append(value) }
            }
        identifier = "airsim.watch.incoming.\(payload.callID)"
        title = "AirSIM Incoming Call"
        body = parts.isEmpty ? "Incoming call on the module" : parts.joined(separator: " · ")
    }
}
