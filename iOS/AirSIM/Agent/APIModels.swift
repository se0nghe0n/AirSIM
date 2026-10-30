import Foundation

// MARK: - Calls & SMS

/// Single call record returned by the module.
struct CallRecord: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let index: Int
    let direction: String
    let state: String
    let number: String?
    let startedAt: Date
    let updatedAt: Date
    let endedAt: Date?
    let missed: Bool

    enum CodingKeys: String, CodingKey {
        case id, index, direction, state, number, missed
        case startedAt = "started_at"
        case updatedAt = "updated_at"
        case endedAt = "ended_at"
    }
}

/// Call polling result; additional audio diagnostic fields are fetched via dedicated endpoints.
struct CallStatus: Codable, Sendable {
    let active: CallRecord?
    let history: [CallRecord]?
    let polling: Bool
    let eventDriven: Bool?
    let pollIntervalSeconds: Int
    let lastPollError: String
    let revision: UInt64?

    enum CodingKeys: String, CodingKey {
        case active, history, polling
        case eventDriven = "event_driven"
        case pollIntervalSeconds = "poll_interval_s"
        case lastPollError = "last_poll_error"
        case revision
    }
}

/// Unified Agent event snapshot; calls and SMS share a single long-poll to avoid keeping two concurrent background USB requests.
struct AgentEventStatus: Codable, Sendable {
    let revision: UInt64
    let smsRevision: UInt64
    let smsPending: Int
    let call: CallStatus

    enum CodingKeys: String, CodingKey {
        case revision, call
        case smsRevision = "sms_revision"
        case smsPending = "sms_pending"
    }
}

struct AgentHealth: Codable, Sendable {
    let ok: Bool
    let version: String
    let controlPlane: String?
    let cellularState: String?
    let cellularRegistration: String?
    let cellularRecovery: String?

    enum CodingKeys: String, CodingKey {
        case ok, version
        case controlPlane = "control_plane"
        case cellularState = "cellular_state"
        case cellularRegistration = "cellular_registration"
        case cellularRecovery = "cellular_recovery"
    }
}

/// Latest Agent heartbeat received by the Relay. Contains displayable status only, without device secrets.
struct CloudAndroidAgent: Codable, Equatable, Sendable, Identifiable {
    let agentID: String
    let agentKind: String?
    let deviceName: String?
    let manufacturer: String?
    let model: String?
    let phoneNumber: String?
    let agentVersion: String?
    let cloudOnline: Bool

    var id: String { agentID }

    enum CodingKeys: String, CodingKey {
        case agentID = "agent_id"
        case agentKind = "agent_kind"
        case deviceName = "device_name"
        case manufacturer, model
        case phoneNumber = "phone_number"
        case agentVersion = "agent_version"
        case cloudOnline = "cloud_online"
    }
}

struct CloudAgentStatus: Decodable, Equatable, Sendable {
    let cloudOnline: Bool
    let agentVersion: String?
    let atOK: Bool?
    let cellularState: String?
    let cellularRegistration: String?
    let cellularRecovery: String?
    let ecmCarrier: String?
    let signalDBM: Int?
    let activeAgentID: String?
    let agents: [CloudAndroidAgent]

    enum CodingKeys: String, CodingKey {
        case cloudOnline = "cloud_online"
        case agentVersion = "agent_version"
        case atOK = "at_ok"
        case cellularState = "cellular_state"
        case cellularRegistration = "cellular_registration"
        case cellularRecovery = "cellular_recovery"
        case ecmCarrier = "ecm_carrier"
        case signalDBM = "signal_dbm"
        case activeAgentID = "active_agent_id"
        case agents
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        cloudOnline = try values.decode(Bool.self, forKey: .cloudOnline)
        agentVersion = try values.decodeIfPresent(String.self, forKey: .agentVersion)
        atOK = try values.decodeIfPresent(Bool.self, forKey: .atOK)
        cellularState = try values.decodeIfPresent(String.self, forKey: .cellularState)
        cellularRegistration = try values.decodeIfPresent(String.self, forKey: .cellularRegistration)
        cellularRecovery = try values.decodeIfPresent(String.self, forKey: .cellularRecovery)
        ecmCarrier = try values.decodeIfPresent(String.self, forKey: .ecmCarrier)
        signalDBM = try values.decodeIfPresent(Int.self, forKey: .signalDBM)
        activeAgentID = try values.decodeIfPresent(String.self, forKey: .activeAgentID)
        agents = try values.decodeIfPresent([CloudAndroidAgent].self, forKey: .agents) ?? []
    }
}

struct AndroidAgentPresentation: Equatable, Identifiable, Sendable {
    let id: String
    let deviceName: String
    let phoneNumber: String?
    let agentKind: String?
    let cloudOnline: Bool
    let vowlanOnline: Bool
    let isCurrent: Bool

    /// localization.md: user-visible copy carried by models uses LocalizedStringResource
    /// so locale resolution is deferred until presentation.
    var agentKindTitle: LocalizedStringResource {
        switch agentKind {
        case "standalone": return "Standalone"
        case "avf": return "Retired Android Agent"
        default: return "Android Agent"
        }
    }
}

enum ModuleConnectionSummary: Equatable, Sendable {
    case localOnline
    case localOnlineNoService
    case cloudOnly
    case offline
}

enum ModuleConnectionPolicy {
    static func summary(
        localControlReachable: Bool,
        cloudHeartbeatFresh: Bool,
        cellularState: String?
    ) -> ModuleConnectionSummary {
        if localControlReachable {
            return ["searching", "denied", "unregistered"].contains(cellularState ?? "")
                ? .localOnlineNoService : .localOnline
        }
        return cloudHeartbeatFresh ? .cloudOnly : .offline
    }
}

enum SMSDirection: String, Codable, Equatable, Sendable {
    case incoming
    case outgoing
}

struct SMSMessage: Codable, Equatable, Sendable, Identifiable {
    let sender: String
    let content: String
    let code: String?
    let timestamp: Date
    /// Stable identifier in the module delivery queue; also used for deduplication between push and local sync.
    var deliveryID: String?
    /// Legacy modules lack a direction field and default to incoming SMS; marked as outgoing by the app after successful send.
    var direction: SMSDirection? = nil

    var isOutgoing: Bool { direction == .outgoing }

    /// Newer Agents align APNs and local sync via delivery_id; legacy versions fall back to content fingerprints.
    var id: String {
        if let deliveryID, !deliveryID.isEmpty { return "delivery:\(deliveryID)" }
        return "\(sender)\u{0}\(timestamp.timeIntervalSince1970)\u{0}\(content)\u{0}\(direction?.rawValue ?? SMSDirection.incoming.rawValue)"
    }

    enum CodingKeys: String, CodingKey {
        case sender, content, code, timestamp, direction
        case deliveryID = "delivery_id"
    }
}

enum SMSHistoryPolicy {
    static func appendingSentMessage(
        recipient: String,
        content: String,
        at timestamp: Date,
        to messages: [SMSMessage],
        limit: Int
    ) -> [SMSMessage] {
        let sentMessage = SMSMessage(
            sender: recipient,
            content: content,
            code: nil,
            timestamp: timestamp,
            deliveryID: nil,
            direction: .outgoing
        )
        return Array((messages + [sentMessage])
            .sorted { $0.timestamp > $1.timestamp }
            .prefix(max(0, limit)))
    }
}

struct SMSStatus: Codable, Sendable {
    let autoCleanupME: Bool
    let count: Int?
    let lastPollError: String?

    enum CodingKeys: String, CodingKey {
        case count
        case autoCleanupME = "auto_cleanup_me"
        case lastPollError = "last_poll_error"
    }
}

struct RejectResponse: Codable, Sendable { let rejected: Bool }
struct SMSSendResult: Codable, Sendable {
    let sent: Bool
    let segments: Int?

    init(sent: Bool, segments: Int?) {
        self.sent = sent
        self.segments = segments
    }
}

struct RelayErrorResponse: Decodable, Sendable { let error: String }

// MARK: - Module

struct ModemStatus: Codable, Equatable, Sendable {
    let imei: String?
    let firmware: String?
    let iccid: String?
    let imsi: String?
    let operatorName: String?
    let simInserted: Bool?
    let signalDBM: Int?
    let networkMode: String?
    let radioBand: String?
    let registrationText: String?
    let cellularState: String?
    let cellularRecovery: String?
    let lastRegisteredAt: Date?

    enum CodingKeys: String, CodingKey {
        case imei, firmware, iccid, imsi
        case operatorName = "operator"
        case simInserted = "sim_inserted"
        case signalDBM = "signal_dbm"
        case networkMode = "network_mode"
        case radioBand = "radio_band"
        case registrationText = "reg_status_text"
        case cellularState = "cellular_state"
        case cellularRecovery = "cellular_recovery"
        case lastRegisteredAt = "last_registered_at"
    }
}

// MARK: - Diagnostics & Voice Runtime

struct ModuleDebugSnapshot: Codable, Sendable {
    let debug: ModuleDebugBufferStatus
    let agent: ModuleDebugAgentStatus
    let at: ModuleDebugATStatus
    let usb: [String: String]
    let traffic: ModuleDebugTrafficStatus
    let modem: ModemStatus
    let calls: ModuleDebugCallStatus
    let sms: ModuleDebugSMSStatus
    let voice: VoiceRuntimeStatus
    let events: [ModuleDebugEvent]
}

struct ModuleDebugBufferStatus: Codable, Sendable {
    let latestSequence: UInt64
    let returnedEvents: Int
    let storedBytes: Int
    let maxEvents: Int
    let maxStoredBytes: Int

    enum CodingKeys: String, CodingKey {
        case latestSequence = "latest_sequence"
        case returnedEvents = "returned_events"
        case storedBytes = "stored_bytes"
        case maxEvents = "max_events"
        case maxStoredBytes = "max_stored_bytes"
    }
}

struct ModuleDebugAgentStatus: Codable, Sendable {
    let version: String
    let uptimeSeconds: Int
    let goroutines: Int
    let heapBytes: UInt64

    enum CodingKeys: String, CodingKey {
        case version, goroutines
        case uptimeSeconds = "uptime_seconds"
        case heapBytes = "heap_bytes"
    }
}

struct ModuleDebugATStatus: Codable, Sendable {
    let device: String
    let lastSuccessAt: String?
    let consecutiveFailures: Int
    let reopenCount: Int

    enum CodingKeys: String, CodingKey {
        case device
        case lastSuccessAt = "last_success_at"
        case consecutiveFailures = "consecutive_failures"
        case reopenCount = "reopen_count"
    }
}

struct ModuleDebugTrafficStatus: Codable, Sendable {
    let interface: String?
    let rxBytes: UInt64?
    let txBytes: UInt64?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case interface, error
        case rxBytes = "rx_bytes"
        case txBytes = "tx_bytes"
    }
}

struct ModuleDebugCallStatus: Codable, Sendable {
    let active: CallRecord?
    let historyCount: Int
    let eventDriven: Bool
    let lastError: String

    enum CodingKeys: String, CodingKey {
        case active
        case historyCount = "history_count"
        case eventDriven = "event_driven"
        case lastError = "last_error"
    }
}

struct ModuleDebugSMSStatus: Codable, Sendable {
    let count: Int
    let lastError: String

    enum CodingKeys: String, CodingKey {
        case count
        case lastError = "last_error"
    }
}

struct ModuleDebugEvent: Codable, Sendable, Identifiable, Equatable {
    let sequence: UInt64
    let timestamp: String
    let category: String
    let direction: String?
    let summary: String
    let payload: String?
    let fields: [String: String]?

    var id: UInt64 { sequence }
}

struct VoiceRuntimeStatus: Codable, Sendable {
    let ready: Bool
    let runtimeInstalled: Bool
    let runtimeSource: String?
    let runtimeDetail: String?
    let lastError: String?

    enum CodingKeys: String, CodingKey {
        case ready
        case runtimeInstalled = "runtime_installed"
        case runtimeSource = "runtime_source"
        case runtimeDetail = "runtime_detail"
        case lastError = "last_error"
    }
}

struct MaVoAudioHostConfig: Codable, Sendable {
    let vendorID: UInt16
    let productID: UInt16
    let locationID: UInt32
    let routeReady: Bool
    let routeSessionReady: Bool?
    let routeError: String?
    let routeRunning: Bool?
    let helperPID: Int?
    let sessionStartedAt: String?
    let statisticsAvailable: Bool?
    let statistics: VoicePCMStatistics?
    let diagnosticLog: String?
    let logTail: [String]?

    enum CodingKeys: String, CodingKey {
        case vendorID = "vendor_id"
        case productID = "product_id"
        case locationID = "location_id"
        case routeReady = "route_ready"
        case routeSessionReady = "route_session_ready"
        case routeError = "route_error"
        case routeRunning = "route_running"
        case helperPID = "helper_pid"
        case sessionStartedAt = "session_started_at"
        case statisticsAvailable = "statistics_available"
        case statistics
        case diagnosticLog = "diagnostic_log"
        case logTail = "log_tail"
    }
}

/// Cumulative PCM statistics from the module voice bridge; peak is PCM16 absolute amplitude, where 0 indicates pure silence.
struct VoicePCMStatistics: Codable, Sendable {
    let uplinkBytes: UInt64
    let uplinkFrames: UInt64
    let uplinkPeak: UInt64
    let downlinkBytes: UInt64
    let downlinkFrames: UInt64
    let downlinkPeak: UInt64
    let downlinkDroppedFrames: UInt64

    enum CodingKeys: String, CodingKey {
        case uplinkBytes = "uplink_bytes"
        case uplinkFrames = "uplink_frames"
        case uplinkPeak = "uplink_peak"
        case downlinkBytes = "downlink_bytes"
        case downlinkFrames = "downlink_frames"
        case downlinkPeak = "downlink_peak"
        case downlinkDroppedFrames = "downlink_dropped_frames"
    }
}
