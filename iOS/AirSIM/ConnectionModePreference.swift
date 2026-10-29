import Foundation

/// User-selected connection mode. Only `automatic` is allowed to fall back across transports.
enum AirSIMConnectionMode: String, CaseIterable, Codable, Sendable {
    case vowlan
    case cloud
    case automatic

    /// localization.md: user-facing option labels use LocalizedStringResource for deferred resolution.
    var title: LocalizedStringResource {
        switch self {
        case .vowlan: return "VoWLAN"
        case .cloud: return "Cloud"
        case .automatic: return "Automatic"
        }
    }

    var detail: LocalizedStringResource {
        switch self {
        case .vowlan: return "Uses only the same Wi-Fi or phone hotspot, without Relay"
        case .cloud: return "Uses only Relay, PushKit, and CallKit"
        case .automatic: return "Automatically chooses VoWLAN, then cloud based on availability"
        }
    }
}

enum ConnectionModePreference {
    static let key = "airsim.connection-mode"

    static func selected(defaults: UserDefaults = .standard) -> AirSIMConnectionMode {
        if let rawValue = defaults.string(forKey: key) {
            if rawValue == "bluetooth" { return .automatic }
            if let mode = AirSIMConnectionMode(rawValue: rawValue) { return mode }
        }
        // Compatible with the two pre-upgrade boolean toggles; do not rewrite on read to avoid side effects in tests and extensions.
        if defaults.bool(forKey: LocalModePreference.key) { return .vowlan }
        if defaults.object(forKey: CloudModePreference.key) != nil,
           !defaults.bool(forKey: CloudModePreference.key) {
            return .vowlan
        }
        return .automatic
    }

    static func set(
        _ mode: AirSIMConnectionMode,
        defaults: UserDefaults = .standard
    ) {
        defaults.set(mode.rawValue, forKey: key)
        defaults.set(mode == .vowlan, forKey: LocalModePreference.key)
        defaults.set(
            mode == .cloud || mode == .automatic,
            forKey: CloudModePreference.key
        )
    }
}

/// The user-selected Android agent is a routing constraint, not just UI state.
/// Keeping it independent from the connection mode lets automatic mode choose
/// VoWLAN or cloud for one phone without silently jumping to another phone.
enum AndroidAgentBindingPreference {
    static let key = "airsim.bound-android-agent-id"

    static func selected(defaults: UserDefaults = .standard) -> String? {
        guard let value = defaults.string(forKey: key)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }

    static func set(_ agentID: String?, defaults: UserDefaults = .standard) {
        let value = agentID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if value.isEmpty { defaults.removeObject(forKey: key) }
        else { defaults.set(value, forKey: key) }
    }
}

struct PairedAndroidDeviceRecord: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let deviceName: String
    let agentKind: String?
}

enum PairedAndroidDeviceStore {
    private static let recordsKey = "airsim.paired-android-devices.v1"
    private static let forgottenKey = "airsim.forgotten-android-devices.v1"

    static func records(defaults: UserDefaults = .standard) -> [PairedAndroidDeviceRecord] {
        guard let data = defaults.data(forKey: recordsKey),
              let values = try? JSONDecoder().decode([PairedAndroidDeviceRecord].self, from: data) else { return [] }
        return values.filter { permits($0.id, defaults: defaults) }
    }
    static func remember(_ record: PairedAndroidDeviceRecord, defaults: UserDefaults = .standard) {
        guard !record.id.isEmpty, permits(record.id, defaults: defaults) else { return }
        var values = records(defaults: defaults).filter { $0.id != record.id }
        values.append(record)
        defaults.set(try? JSONEncoder().encode(values), forKey: recordsKey)
    }
    static func forget(_ id: String, defaults: UserDefaults = .standard) {
        var forgotten = Set(defaults.stringArray(forKey: forgottenKey) ?? [])
        forgotten.insert(id)
        defaults.set(Array(forgotten), forKey: forgottenKey)
        defaults.set(try? JSONEncoder().encode(records(defaults: defaults)), forKey: recordsKey)
        if AndroidAgentBindingPreference.selected(defaults: defaults) == id {
            AndroidAgentBindingPreference.set(nil, defaults: defaults)
        }
    }
    static func permits(_ id: String, defaults: UserDefaults = .standard) -> Bool {
        !(defaults.stringArray(forKey: forgottenKey) ?? []).contains(id)
    }
    static func hasForgottenDevices(defaults: UserDefaults = .standard) -> Bool {
        !(defaults.stringArray(forKey: forgottenKey) ?? []).isEmpty
    }
    static func allowPairing(_ id: String, defaults: UserDefaults = .standard) {
        defaults.set((defaults.stringArray(forKey: forgottenKey) ?? []).filter { $0 != id }, forKey: forgottenKey)
    }
}

struct ConnectionModeRuntimePolicy: Equatable, Sendable {
    let mode: AirSIMConnectionMode

    var startsVoWLAN: Bool { mode == .vowlan || mode == .automatic }
    var startsCloud: Bool { mode == .cloud || mode == .automatic }

    /// Bluetooth incoming calls also rely on the system call UI; CallKit is disabled only in legacy local VoWLAN mode.
    var usesCallKit: Bool { mode != .vowlan }
}

/// Unified dial route selection. Explicit modes never borrow another transport;
/// automatic mode chooses between VoWLAN and cloud in order before call setup.
enum DialRouteSelector {
    static func preferred(
        mode: AirSIMConnectionMode,
        vowlanReady: Bool,
        cloudReady: Bool
    ) -> CallTransport? {
        switch mode {
        case .vowlan:
            return vowlanReady ? .vowlan : nil
        case .cloud:
            return cloudReady ? .cloud : nil
        case .automatic:
            if vowlanReady { return .vowlan }
            if cloudReady { return .cloud }
            return nil
        }
    }
}
