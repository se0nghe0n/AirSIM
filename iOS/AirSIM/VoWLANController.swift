import Foundation
import Network

struct VoWLANEndpoint: Equatable, Hashable, Sendable {
    let host: String
    let controlPort: UInt16

    init(host: String, controlPort: UInt16) throws {
        guard Self.isPrivateIPv4(host), controlPort >= 1024 else {
            throw VoWLANControllerError.invalidAdvertisement
        }
        self.host = host
        self.controlPort = controlPort
    }

    var controlBaseURL: URL { URL(string: "http://\(host):\(controlPort)/")! }

    private static func isPrivateIPv4(_ host: String) -> Bool {
        let fields = host.split(separator: ".").compactMap { UInt8($0) }
        guard fields.count == 4 else { return false }
        return fields[0] == 10 || (fields[0] == 172 && (16...31).contains(fields[1]))
            || (fields[0] == 192 && fields[1] == 168)
    }
}

struct VoWLANDiscoveredAgent: Equatable, Identifiable, Sendable {
    let id: String
    let endpoint: VoWLANEndpoint
    let deviceName: String
    let manufacturer: String?
    let model: String?
    let phoneNumber: String?
    let agentKind: String?

    func refreshed(with identity: VoWLANHealthIdentity) -> Self {
        Self(id: identity.agentID?.isEmpty == false ? identity.agentID! : id,
             endpoint: endpoint,
             deviceName: identity.deviceName?.isEmpty == false ? identity.deviceName! : deviceName,
             manufacturer: identity.manufacturer ?? manufacturer, model: identity.model ?? model,
             phoneNumber: identity.phoneNumber?.isEmpty == false ? identity.phoneNumber : nil,
             agentKind: identity.agentKind ?? agentKind)
    }
}

struct VoWLANHealthIdentity: Decodable {
    let ok: Bool
    let agentID: String?
    let agentKind: String?
    let deviceName: String?
    let manufacturer: String?
    let model: String?
    let phoneNumber: String?

    enum CodingKeys: String, CodingKey {
        case ok
        case agentID = "agent_id"
        case agentKind = "agent_kind"
        case deviceName = "device_name"
        case manufacturer, model
        case phoneNumber = "phone_number"
    }
}

enum VoWLANAvailability: Equatable, Sendable {
    case unpaired
    case discovering
    case discovered(VoWLANEndpoint, at: Date)
    case verified(VoWLANEndpoint, at: Date)
    case unavailable(String)

    var endpoint: VoWLANEndpoint? {
        switch self {
        case let .discovered(value, _), let .verified(value, _): return value
        default: return nil
        }
    }

    func isReady(at now: Date = Date()) -> Bool {
        guard case let .verified(_, verifiedAt) = self else { return false }
        return now.timeIntervalSince(verifiedAt) >= 0 && now.timeIntervalSince(verifiedAt) <= 10
    }

    var isOnlineForDisplay: Bool {
        if case .verified = self { return true }
        return false
    }

    /// Dial actions re-run a signed health check right before dialing, so the UI only needs to confirm
    /// the endpoint was previously verified; do not permanently disable the dial button using a strict 10s window.
    var allowsCallAttempt: Bool { isOnlineForDisplay }
}

enum ConnectionStatusHeadline {
    static func title(summary: ModuleConnectionSummary, vowlanOnline: Bool) -> String {
        if vowlanOnline { return "VoWLAN Online" }
        switch summary {
        case .localOnline: return L10n.t("Online")
        case .localOnlineNoService: return "Online · No Cellular Service"
        case .cloudOnly: return "Cloud Online · Reconnecting USB"
        case .offline: return L10n.t("Offline")
        }
    }
}

enum ModuleConnectionPresentationLevel: Equatable {
    case online
    case warning
    case cloud
    case offline
}

struct ModuleConnectionPresentation: Equatable {
    let title: String
    let routeTitle: String
    let description: String
    let level: ModuleConnectionPresentationLevel
    let systemImage: String

    static func make(
        summary: ModuleConnectionSummary,
        vowlanOnline: Bool,
        reconnecting: Bool,
        message: String?
    ) -> Self {
        if vowlanOnline {
            return Self(
                title: "VoWLAN Online",
                routeTitle: "Same Wi-Fi / Android hotspot",
                description: "VoWLAN connected. Status refreshes automatically.",
                level: .online,
                systemImage: "wifi"
            )
        }
        switch summary {
        case .localOnline:
            return Self(
                title: "Module Online", routeTitle: "Direct USB ECM",
                description: message ?? "USB ECM connected. Status refreshes automatically.",
                level: .online, systemImage: "checkmark.circle.fill"
            )
        case .localOnlineNoService:
            return Self(
                title: "Module Online · No Service", routeTitle: "USB ECM Connected",
                description: message ?? "USB ECM connected. Cellular network is recovering automatically.",
                level: .warning, systemImage: "antenna.radiowaves.left.and.right.slash"
            )
        case .cloudOnly:
            return Self(
                title: "Cloud Online", routeTitle: "Internet Relay",
                description: message ?? "Local USB ECM disconnected. The module can still receive calls and messages over the internet.",
                level: .cloud, systemImage: "icloud.fill"
            )
        case .offline:
            return Self(
                title: reconnecting ? "Reconnecting" : "Module Offline",
                routeTitle: reconnecting ? "Restoring Connection" : "Connection Unavailable",
                description: message ?? "Check module power, cellular service, and the USB ECM connection",
                level: reconnecting ? .warning : .offline,
                systemImage: reconnecting ? "arrow.triangle.2.circlepath" : "exclamationmark.triangle.fill"
            )
        }
    }
}

enum PushRegistrationRouteSelector {
    static func select<Route>(primary: Route, verifiedVoWLAN: Route?) -> Route {
        verifiedVoWLAN ?? primary
    }
}

enum VoWLANStatusCopy {
    static func text(for availability: VoWLANAvailability, activeCall: Bool = false) -> String {
        if activeCall { return "On Call (VoWLAN)" }
        switch availability {
        case .unpaired: return "Not Paired"
        case .discovering: return "Discovering"
        case .discovered: return "Discovered, verifying"
        case .verified: return "VoWLAN Ready"
        case let .unavailable(reason):
            return reason.contains("VoWLAN disconnected") ? "LAN Disconnected · Cloud for Next Call" : reason
        }
    }
}

enum VoWLANControllerError: LocalizedError {
    case invalidAdvertisement
    case notDiscovered
    case notPaired
    case authenticationFailed

    var errorDescription: String? {
        switch self {
        case .invalidAdvertisement: return "Invalid VoWLAN broadcast"
        case .notDiscovered: return "Android VoWLAN has not been found"
        case .notPaired: return "VoWLAN is not paired"
        case .authenticationFailed: return "VoWLAN authentication failed"
        }
    }
}

@MainActor
enum VoWLANProbeRecovery {
    static func run<Value>(_ operation: () async throws -> Value) async throws -> Value {
        do {
            return try await operation()
        } catch {
            guard isDefunctConnection(error) else { throw error }
            try? await Task.sleep(for: .milliseconds(200))
            return try await operation()
        }
    }

    static func userFacingMessage(for error: Error) -> String {
        if isDefunctConnection(error) {
            return "VoWLAN connection expired. Keep iPhone and Android on the same local network."
        }
        return error.localizedDescription
    }

    private static func isDefunctConnection(_ error: Error) -> Bool {
        let message = error.localizedDescription.lowercased()
        return message.contains("defunctconnection")
            || message.contains("defunct connection")
            || message.contains("65569")
    }
}

struct VoWLANBrowserLifecycle {
    private(set) var generation: UInt64 = 0
    private(set) var isRunning = false

    mutating func startIfNeeded() -> UInt64? {
        guard !isRunning else { return nil }
        return begin()
    }

    mutating func restart() -> UInt64 { begin() }

    mutating func stop() {
        generation &+= 1
        isRunning = false
    }

    mutating func markFailed(_ candidate: UInt64) -> Bool {
        guard accepts(candidate) else { return false }
        isRunning = false
        return true
    }

    func accepts(_ candidate: UInt64) -> Bool {
        isRunning && generation == candidate
    }

    private mutating func begin() -> UInt64 {
        generation &+= 1
        isRunning = true
        return generation
    }
}

/// A transient VPN route change can invalidate a successful probe without changing
/// Bonjour's result set. Keep retrying the saved endpoint, but bound retries when
/// the phone is genuinely offline.
struct VoWLANRecoveryGate {
    private var nextAttemptAt = Date.distantPast

    mutating func shouldAttempt(for availability: VoWLANAvailability, at now: Date) -> Bool {
        guard availability != .unpaired, !availability.isOnlineForDisplay,
              now >= nextAttemptAt else { return false }
        nextAttemptAt = now.addingTimeInterval(10)
        return true
    }

    mutating func reset() { nextAttemptAt = .distantPast }
}

@MainActor
@Observable
final class VoWLANController {
    private(set) var availability: VoWLANAvailability =
        VoWLANCredentialStore.load() == nil ? .unpaired : .discovering {
        didSet { onAvailabilityChange?(availability) }
    }

    @ObservationIgnored var onAvailabilityChange: ((VoWLANAvailability) -> Void)?

    private(set) var discoveredAgents: [VoWLANDiscoveredAgent] = []

    @ObservationIgnored private let queue = DispatchQueue(label: "com.example.airsim.vowlan.discovery")
    @ObservationIgnored private var browser: NWBrowser?
    @ObservationIgnored private var browserLifecycle = VoWLANBrowserLifecycle()
    @ObservationIgnored private var recoveryGate = VoWLANRecoveryGate()
    @ObservationIgnored private var discoveredEndpoint: VoWLANEndpoint?
    @ObservationIgnored private var disappearanceTask: Task<Void, Never>?
    @ObservationIgnored private var identityEpoch: UInt64 = 0

    func forget(_ agentID: String) {
        identityEpoch &+= 1
        let removingActive = discoveredAgents.contains { $0.id == agentID && $0.endpoint == discoveredEndpoint }
        discoveredAgents.removeAll { $0.id == agentID }
        if removingActive {
            discoveredEndpoint = nil
            availability = .discovering
        }
        restartBrowsing()
    }

    func bind(to agentID: String?) {
        AndroidAgentBindingPreference.set(agentID)
        let selected = agentID.flatMap { id in discoveredAgents.first(where: { $0.id == id }) }
        if let selected {
            disappearanceTask?.cancel()
            discoveredEndpoint = selected.endpoint
            availability = .discovered(selected.endpoint, at: Date())
            Task { await probeNow() }
        } else if agentID != nil {
            discoveredEndpoint = nil
            availability = .discovering
        }
    }

    func startBrowsing() {
        guard VoWLANCredentialStore.load() != nil else {
            stopBrowserSession()
            availability = .unpaired
            return
        }
        guard let generation = browserLifecycle.startIfNeeded() else { return }
        beginBrowsing(generation: generation)
    }

    func restartBrowsing() {
        identityEpoch &+= 1
        guard VoWLANCredentialStore.load() != nil else {
            stopBrowserSession()
            availability = .unpaired
            return
        }
        let generation = browserLifecycle.restart()
        stopCurrentBrowser()
        discoveredEndpoint = nil
        discoveredAgents = []
        beginBrowsing(generation: generation)
        Task {
            await AgentVerboseTraceRecorder.shared.recordEvent(
                source: "ios", category: "vowlan", phase: "browser_restarted",
                title: "VoWLAN Browser Restarted",
                fields: ["generation": String(generation)]
            )
        }
    }

    private func beginBrowsing(generation: UInt64) {
        availability = .discovering
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let active = NWBrowser(
            for: .bonjourWithTXTRecord(type: "_airsim-vowlan._tcp", domain: nil),
            using: parameters
        )
        active.browseResultsChangedHandler = { [weak self] results, _ in
            let parsed = results.compactMap(Self.parseAgent)
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.browserLifecycle.accepts(generation) else { return }
                let agents = parsed.filter { PairedAndroidDeviceStore.permits($0.id) }
                let endpoints = Set(agents.map(\.endpoint))
                self.discoveredAgents = agents.sorted {
                    if $0.deviceName == $1.deviceName { return $0.id < $1.id }
                    return $0.deviceName.localizedCaseInsensitiveCompare($1.deviceName) == .orderedAscending
                }
                let bound = AndroidAgentBindingPreference.selected()
                let endpoint = agents.first(where: { $0.id == bound })?.endpoint
                    ?? (bound == nil ? self.discoveredEndpoint.flatMap { endpoints.contains($0) ? $0 : nil } : nil)
                    ?? (bound == nil ? agents.first?.endpoint : nil)
                if let endpoint {
                    self.disappearanceTask?.cancel()
                    self.discoveredEndpoint = endpoint
                    if self.availability.endpoint == endpoint, self.availability.isReady() { return }
                    self.availability = .discovered(endpoint, at: Date())
                    await AgentVerboseTraceRecorder.shared.recordEvent(
                        source: "ios", category: "vowlan", phase: "discovered",
                        title: "VoWLAN Discovered",
                        fields: ["host": endpoint.host, "control_port": String(endpoint.controlPort)]
                    )
                    await self.probeNow()
                } else if self.discoveredEndpoint != nil {
                    // Bonjour frequently publishes an empty intermediate result while VPN,
                    // hotspot, or Wi-Fi routes settle. Preserve the verified endpoint and
                    // verify it after a grace period instead of tearing down an active route.
                    self.scheduleDisappearanceCheck(generation: generation)
                } else if !self.availability.isReady() {
                    self.availability = .discovering
                }
            }
        }
        active.stateUpdateHandler = { [weak self] state in
            if case let .failed(error) = state {
                Task { @MainActor [weak self] in
                    guard let self, self.browserLifecycle.markFailed(generation) else { return }
                    self.stopCurrentBrowser()
                    self.discoveredEndpoint = nil
                    self.availability = .unavailable(
                        VoWLANProbeRecovery.userFacingMessage(for: error)
                    )
                    await AgentVerboseTraceRecorder.shared.recordEvent(
                        source: "ios", category: "vowlan", phase: "browser_failed",
                        title: "VoWLAN Browser Failed", detail: error.localizedDescription,
                        fields: ["generation": String(generation)], isFailure: true
                    )
                }
            }
        }
        browser = active
        active.start(queue: queue)
    }

    func stopBrowsing() {
        stopBrowserSession()
        if VoWLANCredentialStore.load() != nil { availability = .discovering }
    }

    private func stopBrowserSession() {
        identityEpoch &+= 1
        disappearanceTask?.cancel()
        disappearanceTask = nil
        browserLifecycle.stop()
        stopCurrentBrowser()
        discoveredEndpoint = nil
        discoveredAgents = []
    }

    private func scheduleDisappearanceCheck(generation: UInt64) {
        guard disappearanceTask == nil else { return }
        disappearanceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard let self, !Task.isCancelled,
                  self.browserLifecycle.accepts(generation) else { return }
            self.disappearanceTask = nil
            if let endpoint = self.discoveredEndpoint {
                self.availability = .discovered(endpoint, at: Date())
                await self.probeNow()
            }
        }
    }

    private func stopCurrentBrowser() {
        let active = browser
        browser = nil
        active?.browseResultsChangedHandler = nil
        active?.stateUpdateHandler = nil
        active?.cancel()
    }

    func refreshAfterPairing() async {
        restartBrowsing()
        await probeNow()
    }

    /// Called by the existing local status loop when no verified route remains.
    /// A VPN disconnect doesn't necessarily emit a new Bonjour result, so a
    /// failed health probe must not wait for Android to advertise again.
    func recoverIfNeeded() async {
        guard VoWLANCredentialStore.load() != nil,
              recoveryGate.shouldAttempt(for: availability, at: Date()) else { return }
        let browserWasRunning = browserLifecycle.isRunning
        startBrowsing()
        await probeNow()
        if availability.isOnlineForDisplay {
            recoveryGate.reset()
        } else if browserWasRunning {
            restartBrowsing()
        }
    }

    func probeNow() async {
        guard let endpoint = availability.endpoint ?? discoveredEndpoint else { return }
        guard let credential = VoWLANCredentialStore.load() else {
            availability = .unpaired
            return
        }
        let epoch = identityEpoch
        do {
            let (data, response) = try await VoWLANProbeRecovery.run {
                let signed = try VoWLANRequestSigner(secret: credential.secret).sign(
                    method: "GET", path: "/v1/health", body: Data()
                )
                var request = URLRequest(url: endpoint.controlBaseURL.appendingPathComponent("v1/health"))
                request.timeoutInterval = 3
                request.cachePolicy = .reloadIgnoringLocalCacheData
                Self.apply(signed, to: &request)
                let configuration = URLSessionConfiguration.ephemeral
                configuration.waitsForConnectivity = false
                let session = URLSession(configuration: configuration)
                defer { session.finishTasksAndInvalidate() }
                return try await session.data(for: request)
            }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let identity = try? JSONDecoder().decode(VoWLANHealthIdentity.self, from: data),
                  identity.ok else {
                throw VoWLANControllerError.authenticationFailed
            }
            guard epoch == identityEpoch, discoveredEndpoint == endpoint else { return }
            if let id = identity.agentID, !PairedAndroidDeviceStore.permits(id) {
                discoveredAgents.removeAll { $0.endpoint == endpoint }
                discoveredEndpoint = nil
                availability = .discovering
                return
            }
            if let index = discoveredAgents.firstIndex(where: { $0.endpoint == endpoint }) {
                let previous = discoveredAgents[index]
                discoveredAgents[index] = previous.refreshed(with: identity)
            }
            availability = .verified(endpoint, at: Date())
            await AgentVerboseTraceRecorder.shared.recordEvent(
                source: "ios", category: "vowlan", phase: "verified",
                title: "VoWLAN Signed Health Check Passed",
                fields: ["host": endpoint.host, "control_port": String(endpoint.controlPort)]
            )
        } catch {
            guard epoch == identityEpoch else { return }
            availability = .unavailable(VoWLANProbeRecovery.userFacingMessage(for: error))
            await AgentVerboseTraceRecorder.shared.recordEvent(
                source: "ios", category: "vowlan", phase: "failed",
                title: "VoWLAN Health Check Failed", detail: error.localizedDescription,
                isFailure: true
            )
        }
    }

    nonisolated static func apply(_ signed: VoWLANSignedRequest, to request: inout URLRequest) {
        request.setValue("1", forHTTPHeaderField: "X-AirSIM-VoWLAN-Version")
        request.setValue(String(signed.timestamp), forHTTPHeaderField: "X-AirSIM-VoWLAN-Timestamp")
        request.setValue(signed.nonce, forHTTPHeaderField: "X-AirSIM-VoWLAN-Nonce")
        request.setValue(signed.signature, forHTTPHeaderField: "X-AirSIM-VoWLAN-Signature")
    }

    private nonisolated static func parseAgent(_ result: NWBrowser.Result) -> VoWLANDiscoveredAgent? {
        guard case let .bonjour(record) = result.metadata,
              record["v"] == "1", let host = record["host"],
              let controlText = record["control_port"], let control = UInt16(controlText) else { return nil }
        guard let endpoint = try? VoWLANEndpoint(host: host, controlPort: control) else {
            return nil
        }
        let fallbackID = "vowlan-\(host)-\(control)"
        let deviceName = record["device_name"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return VoWLANDiscoveredAgent(
            id: record["agent_id"]?.isEmpty == false ? record["agent_id"]! : fallbackID,
            endpoint: endpoint,
            deviceName: deviceName?.isEmpty == false ? deviceName! : "Android Phone",
            manufacturer: record["manufacturer"],
            model: record["model"],
            phoneNumber: nil,
            agentKind: record["agent_kind"]
        )
    }
}
