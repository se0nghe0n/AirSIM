import Foundation
import UIKit

enum AppRefreshPolicy {
    static func shouldRefreshSupplementalState(appIsActive: Bool) -> Bool { appIsActive }

    static func shouldQueryCloudStatus(
        cloudModeEnabled: Bool,
        lastAttempt: Date,
        appIsForeground: Bool,
        beforeLiveActivityCall: Bool = false
    ) -> Bool {
        guard cloudModeEnabled, appIsForeground || beforeLiveActivityCall else { return false }
        // Foreground entry explicitly re-arms this sentinel. Elapsed time alone never polls Relay.
        return lastAttempt == .distantPast
    }
}

/// Serializes first-launch permission prompts so the microphone request cannot be
/// displaced by notification or local-network authorization.
@MainActor
final class InitialPermissionCoordinator {
    private(set) var didStartDiscovery = false
    private var didRequestNotifications = false

    func requestIfNeeded(
        isForeground: () -> Bool,
        microphoneIsUndetermined: () -> Bool,
        requestMicrophone: () async -> Void,
        startDiscovery: () -> Void,
        requestNotifications: () -> Void
    ) async {
        guard isForeground() else { return }
        if microphoneIsUndetermined() { await requestMicrophone() }
        // If iOS deferred the prompt while the app was inactive, the next foreground
        // transition retries it instead of recording a request that never happened.
        guard isForeground(), !microphoneIsUndetermined() else { return }
        if !didStartDiscovery {
            didStartDiscovery = true
            startDiscovery()
        }
        if !didRequestNotifications {
            didRequestNotifications = true
            requestNotifications()
        }
    }
}

enum CallPresentationSurface: Equatable, Sendable {
    case system
    case app
}

enum CallAudioStatusPresentation {
    static func text(transport: CallTransport?, localAudioActive: Bool,
                     cloudState: CloudCallAudioState) -> String {
        switch cloudState {
        case .idle: return localAudioActive ? "Audio Connected" : "Connecting Audio"
        case let .connecting(attempt, maximum): return "Retrying Cloud Audio \(attempt)/\(maximum)"
        case .connected: return "Cloud Audio Connected"
        case let .failed(message): return message
        }
    }
}

enum CallPresentationPolicy {
    static func inAppCall(
        surface: CallPresentationSurface?,
        local: CallRecord?,
        remote: CallRecord?,
        pending: CallRecord? = nil
    ) -> CallRecord? {
        guard surface == .app else { return nil }
        return [local, remote, pending].compactMap { $0 }.first {
            $0.endedAt == nil && !["ending", "ended", "failed"].contains($0.state)
        }
    }

    static func shouldPresentWhenAppBecomesActive(
        managesSystemCall: Bool,
        hasLocalCall: Bool,
        hasRemoteCall: Bool
    ) -> Bool {
        managesSystemCall || hasLocalCall || hasRemoteCall
    }
}

enum CallAnswerConfirmationPolicy {
    static func shouldMarkActiveImmediately(transport: CallTransport?) -> Bool {
        transport == .moduleLocal || transport == .vowlan
    }
}

enum CallKitEndDecision {
    enum Route: Equatable {
        case cloudReject
        case cloudEnd
        case localReject
        case localHangup
    }

    static func route(
        transport: CallTransport?,
        cloudSessionPrepared: Bool,
        hasIncomingPush: Bool,
        systemCallAnswered: Bool,
        activeIncomingRinging: Bool
    ) -> Route {
        if hasIncomingPush, !systemCallAnswered,
           transport != .vowlan, transport != .moduleLocal {
            return .cloudReject
        }
        if transport == .cloud || cloudSessionPrepared { return .cloudEnd }
        return activeIncomingRinging || (hasIncomingPush && !systemCallAnswered)
            ? .localReject : .localHangup
    }
}

enum LocalCallControlTarget {
    static func select<Service>(
        locked: Service?,
        observed: (callID: String, service: Service)?,
        fallback: Service?,
        targetCallID: String?
    ) -> Service? {
        if let locked { return locked }
        guard let targetCallID, !targetCallID.isEmpty else { return nil }
        if let observed {
            return observed.callID == targetCallID ? observed.service : nil
        }
        return fallback
    }
}

enum CallAnswerCompletionCoordinator {
    @MainActor
    static func complete(
        transport: CallTransport?,
        confirmActive: () -> Void,
        startAudio: () async -> Void
    ) async {
        guard CallAnswerConfirmationPolicy.shouldMarkActiveImmediately(
            transport: transport
        ) else { return }
        confirmActive()
        await startAudio()
    }
}

enum LocalControlReachability {
    static func moduleLocal(
        isOnline: Bool,
        isReconnecting: Bool,
        lastSuccessfulRoute: LocalAgentRoute?
    ) -> Bool {
        guard isOnline, !isReconnecting, let lastSuccessfulRoute else { return false }
        if case .moduleLocal = lastSuccessfulRoute { return true }
        return false
    }
}

enum AgentEventPollingPolicy {
    static func timeout(hasActiveCall: Bool) -> TimeInterval {
        hasActiveCall ? 3 : 15
    }

    static func shouldFetchSMS(pending: Int, eventRevision: UInt64, observedSMSRevision: UInt64) -> Bool {
        // An earlier fetch or local save may have failed after this revision was observed.
        // The Agent's unacknowledged queue is authoritative, including after a restart.
        pending > 0
    }
}

protocol AgentSMSInboxServicing: Sendable {
    func messages() async throws -> [SMSMessage]
}

extension AirSIMAPI: AgentSMSInboxServicing {}

enum AgentSMSInboxFetch {
    static func fetch<Service: AgentSMSInboxServicing>(
        reportingAgent: Service?, discoveredAgent: Service
    ) async throws -> (agent: Service, messages: [SMSMessage]) {
        let agent = reportingAgent ?? discoveredAgent
        return (agent, try await agent.messages())
    }
}

protocol LegacyAgentPolling: Sendable {
    func callStatus() async throws -> CallStatus
    func smsStatus() async throws -> SMSStatus
}

extension AirSIMAPI: LegacyAgentPolling {}

struct LegacyAgentPollResult: Sendable {
    let call: CallStatus
    let smsChanged: Bool
}

enum LegacyAgentPoller {
    static func next(_ api: some LegacyAgentPolling) async throws -> LegacyAgentPollResult {
        let call = try await api.callStatus()
        let sms = try? await api.smsStatus()
        // Older Agents may not expose /api/sms/status. In that case, fetch the
        // inbox directly instead of silently missing messages.
        return LegacyAgentPollResult(call: call, smsChanged: sms.map { ($0.count ?? 0) > 0 } ?? true)
    }
}

enum AgentEventCursor {
    /// Sentinel value never produced by a normal counter; requests an immediate snapshot from the Agent on initial connect.
    static let initial = UInt64.max

    static func advanced(from _: UInt64, to incoming: UInt64) -> UInt64 {
        // After an Agent restart, revision resets to 0; do not use max, otherwise long-polls would return immediately in a tight loop.
        incoming
    }
}

enum ModuleConnectivityPolicy {
    static let offlineFailureThreshold = 3
    static let callTransitionGraceInterval: TimeInterval = 8

    static func shouldConfirmOffline(
        consecutiveFailures: Int,
        now: Date,
        protectedUntil: Date
    ) -> Bool {
        consecutiveFailures >= offlineFailureThreshold && now >= protectedUntil
    }

    static func shouldMarkOffline(
        consecutiveFailures: Int,
        healthRequestSucceeded: Bool,
        now: Date,
        protectedUntil: Date
    ) -> Bool {
        shouldConfirmOffline(
            consecutiveFailures: consecutiveFailures,
            now: now,
            protectedUntil: protectedUntil
        ) && !healthRequestSucceeded
    }
}

/// Primary state model for the mobile app: polls the module Agent in the foreground and drives the five main tabs.
@MainActor
@Observable
final class AppModel {
    var activeCall: CallRecord?
    var callHistory: [CallRecord] = []
    private(set) var isRefreshingCallHistory = false
    private(set) var callHistoryMessage: String?
    var messages: [SMSMessage] = [] {
        didSet { rebuildConversations() }
    }
    /// foreach.md: thread grouping and sorting live in the model and recompute only when messages change (review round 2 #4);
    /// MessagesView reads final data on the first frame without flashing the "No Messages" empty state.
    private(set) var conversations: [(sender: String, messages: [SMSMessage])] = []
    var numberInput = ""
    var isOnline = false
    private(set) var isReconnecting = false
    var connectionMessage: String?
    var isBusy = false
    var isMuted = false
    /// CallRecordingStore is the source of truth for recording state; read it directly instead of forwarding via Combine.
    var isRecording: Bool { recordings.isRecording }
    var isRecordingBusy: Bool { recordings.isBusy }
    var errorMessage: String?
    private(set) var modemStatus: ModemStatus?
    private(set) var agentVersion: String?
    private(set) var connectionSummary: ModuleConnectionSummary = .offline
    private(set) var cloudAgentStatus: CloudAgentStatus?
    private(set) var cloudAgentDirectory: CloudAgentStatus?
    private(set) var remoteCall: CallRecord?
    private(set) var pendingOutgoingCall: CallRecord?
    private(set) var callPresentationSurface: CallPresentationSurface?
    private(set) var cloudCallAudioState: CloudCallAudioState = .idle
    /// VirtualCallTTSController is not @Observable; mirror isPrepared into tracked state on virtual call prepare/stop
    /// so callAudioIsActive can drive the call view audio badge.
    private(set) var isVirtualCallTTSPrepared = false
    private(set) var callLifecycleSnapshot: CallLifecycleSnapshot = .idle
    /// UserDefaults preferences are outside observation tracking; preference setters increment this counter
    /// so computed presentation properties re-establish dependencies (replacing objectWillChange.send()).
    private var preferenceRevision = 0
    private(set) var pairedDeviceRecords = PairedAndroidDeviceStore.records()
    let api: AirSIMAPI
    let contacts = ContactStore()
    let audio = AudioSessionController()
    let recordings = CallRecordingStore.shared
    let callKit = CallKitController.shared
    let backgroundStandby = BackgroundStandbyController()
    let vowlan = VoWLANController()
    let incomingNotifier = IncomingCallNotifier()
    let incomingSMSNotifier = IncomingSMSNotifier()
    let liveActivity = LiveActivityController()

    @ObservationIgnored private let historyStore = LocalHistoryStore()
    @ObservationIgnored private var outgoingAttemptID = UUID()
    // Polling and call-route bookkeeping below; not UI state and excluded from observation.
    @ObservationIgnored private var pollingTask: Task<Void, Never>?
    @ObservationIgnored private var moduleMetadataTask: Task<Void, Never>?
    @ObservationIgnored private var callHistoryRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var scheduledCallHistoryRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var activeOperationCount = 0
    @ObservationIgnored private var startingCallAudio = false
    @ObservationIgnored private var currentCallTransport: CallTransport?
    @ObservationIgnored private var lockedCallTransport: LockedCallTransport?
    @ObservationIgnored private var currentLocalAPI: AirSIMAPI?
    @ObservationIgnored private var currentPCMRoute: PCMRoute?
    @ObservationIgnored private var lastSuccessfulLocalAPI: AirSIMAPI?
    @ObservationIgnored private var observedCallLocalAPI: (callID: String, service: AirSIMAPI)?
    @ObservationIgnored private var callLifecycleStore = CallLifecycleStore()
    @ObservationIgnored private var appIsActive = true
    @ObservationIgnored private let initialPermissionCoordinator = InitialPermissionCoordinator()
    @ObservationIgnored private var initialPermissionTask: Task<Void, Never>?
    @ObservationIgnored private var eventRevision: UInt64 = AgentEventCursor.initial
    @ObservationIgnored private var smsRevision: UInt64 = 0
    @ObservationIgnored private var eventStreamSupported: Bool?
    @ObservationIgnored private var pollingGeneration = 0
    @ObservationIgnored private var hasStarted = false
    @ObservationIgnored private var consecutivePollFailures = 0
    @ObservationIgnored private var callTransitionProtectedUntil = Date.distantPast
    @ObservationIgnored private var nextAudioDiagnosticRefresh = Date.distantPast
    @ObservationIgnored private var nextModuleMetadataRefresh = Date.distantPast
    // Read by pairedAndroidAgents within a 90s window; must participate in observation tracking,
    // otherwise dependent views will not recompute after refresh/reset (@Observable no longer triggers full-view updates on arbitrary writes like objectWillChange).
    private var lastCloudStatusRefresh = Date.distantPast
    @ObservationIgnored private var cloudStatusRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var cloudStatusRefreshGeneration = 0
    @ObservationIgnored private var audioWarmupCallID: String?
    @ObservationIgnored private var lowPowerModeEnabled = true
    @ObservationIgnored private let backgroundStandbyKey = "airsim.background-standby-enabled"
    @ObservationIgnored private let lowPowerModeKey = "airsim.low-power-mode-enabled"
    @ObservationIgnored private let maxCallHistoryCount = 500
    @ObservationIgnored private let maxMessageCount = 2_000

    var inAppPresentedCall: CallRecord? {
        return CallPresentationPolicy.inAppCall(
            surface: callPresentationSurface,
            local: lifecycleRecord(from: activeCall),
            remote: lifecycleRecord(from: remoteCall),
            pending: pendingOutgoingCall
        )
    }

    var callAudioIsActive: Bool {
        audio.active || cloudCallAudioState.isConnected || isVirtualCallTTSPrepared
    }

    var connectionModePresentation: ConnectionModePresentation {
        _ = preferenceRevision
        return ConnectionModePresentation.make(
            selectedMode: ConnectionModePreference.selected(),
            vowlanOnline: permitsVoWLANEndpoint(vowlan.availability.endpoint)
                && vowlan.availability.isOnlineForDisplay,
            cloudModeEnabled: CloudModePreference.isEnabled(),
            cloudOnline: boundCloudReady
        )
    }

    var pairedAndroidAgents: [AndroidAgentPresentation] {
        _ = preferenceRevision
        let cloudStatus = cloudAgentDirectory ?? cloudAgentStatus
        let cloudStatusIsFresh = Date().timeIntervalSince(lastCloudStatusRefresh) <= 90
        var values: [String: AndroidAgentPresentation] = [:]

        for agent in cloudStatus?.agents ?? [] {
            guard PairedAndroidDeviceStore.permits(agent.id) else { continue }
            let name = agent.deviceName?.isEmpty == false
                ? agent.deviceName!
                : [agent.manufacturer, agent.model].compactMap { $0 }.joined(separator: " ")
            values[agent.id] = AndroidAgentPresentation(
                id: agent.id,
                deviceName: name.isEmpty ? "Android Phone" : name,
                phoneNumber: cloudStatusIsFresh && agent.cloudOnline && agent.phoneNumber?.isEmpty == false
                    ? agent.phoneNumber : nil,
                agentKind: agent.agentKind,
                cloudOnline: cloudStatusIsFresh && agent.cloudOnline,
                vowlanOnline: false,
                bluetoothOnline: false,
                isCurrent: false
            )
        }

        for local in vowlan.discoveredAgents {
            guard PairedAndroidDeviceStore.permits(local.id) else { continue }
            let previous = values[local.id]
            values[local.id] = AndroidAgentPresentation(
                id: local.id,
                deviceName: local.deviceName,
                phoneNumber: local.phoneNumber?.isEmpty == false ? local.phoneNumber : nil,
                agentKind: local.agentKind ?? previous?.agentKind,
                cloudOnline: previous?.cloudOnline ?? false,
                vowlanOnline: vowlan.availability.isOnlineForDisplay && vowlan.availability.endpoint == local.endpoint,
                bluetoothOnline: false,
                isCurrent: false
            )
        }

        if values.isEmpty, let cloudStatus, cloudStatusIsFresh, cloudStatus.cloudOnline,
           cloudStatus.activeAgentID.map({ PairedAndroidDeviceStore.permits($0) }) != false {
            let fallbackID = cloudStatus.activeAgentID ?? "cloud-agent"
            values[fallbackID] = AndroidAgentPresentation(
                id: fallbackID,
                deviceName: "Android Phone",
                phoneNumber: nil,
                agentKind: nil,
                cloudOnline: true,
                vowlanOnline: false,
                bluetoothOnline: false,
                isCurrent: false
            )
        }

        let currentID: String? = {
            if let bound = AndroidAgentBindingPreference.selected(), values[bound] != nil {
                return bound
            }
            let route = DialRouteSelector.preferred(
                mode: ConnectionModePreference.selected(),
                vowlanReady: vowlan.availability.isOnlineForDisplay,
                cloudReady: CloudModePreference.isEnabled()
                    && cloudStatusIsFresh && cloudStatus?.cloudOnline == true
            )
            if route == .vowlan, let endpoint = vowlan.availability.endpoint {
                return vowlan.discoveredAgents.first(where: { $0.endpoint == endpoint })?.id
            }
            if route == .cloud {
                return cloudStatus?.activeAgentID
                    ?? cloudStatus?.agents.first(where: \.cloudOnline)?.id
            }
            return nil
        }()

        return values.values.map { item in
            AndroidAgentPresentation(
                id: item.id,
                deviceName: item.deviceName,
                phoneNumber: item.phoneNumber,
                agentKind: item.agentKind,
                cloudOnline: item.cloudOnline,
                vowlanOnline: item.vowlanOnline,
                bluetoothOnline: item.bluetoothOnline,
                isCurrent: item.id == currentID
            )
        }.sorted {
            if $0.isCurrent != $1.isCurrent { return $0.isCurrent }
            let leftOnline = $0.vowlanOnline || $0.bluetoothOnline || $0.cloudOnline
            let rightOnline = $1.vowlanOnline || $1.bluetoothOnline || $1.cloudOnline
            if leftOnline != rightOnline { return leftOnline }
            return $0.deviceName.localizedCaseInsensitiveCompare($1.deviceName) == .orderedAscending
        }
    }

    var currentAndroidAgent: AndroidAgentPresentation? {
        pairedAndroidAgents.first(where: \.isCurrent)
    }

    /// History retains identity/name only; numbers and online state come from the live session.
    var pairedDeviceHistory: [AndroidAgentPresentation] {
        _ = preferenceRevision
        var values = Dictionary(uniqueKeysWithValues: pairedDeviceRecords.map {
            ($0.id, AndroidAgentPresentation(id: $0.id, deviceName: $0.deviceName, phoneNumber: nil,
                agentKind: $0.agentKind, cloudOnline: false, vowlanOnline: false, isCurrent: false))
        })
        let registeredCloudIDs = Set((cloudAgentDirectory ?? cloudAgentStatus)?.agents.map(\.id) ?? [])
        for agent in pairedAndroidAgents where values[agent.id] != nil || registeredCloudIDs.contains(agent.id)
                || agent.cloudOnline || agent.bluetoothOnline || agent.vowlanOnline {
            values[agent.id] = agent
        }
        return values.values.filter { PairedAndroidDeviceStore.permits($0.id) }
            .sorted { $0.deviceName.localizedCaseInsensitiveCompare($1.deviceName) == .orderedAscending }
    }

    private func rememberVerifiedDevices() {
        let registeredCloudIDs = Set((cloudAgentDirectory ?? cloudAgentStatus)?.agents.map(\.id) ?? [])
        for agent in pairedAndroidAgents where registeredCloudIDs.contains(agent.id)
                || agent.cloudOnline || agent.bluetoothOnline
                || (agent.vowlanOnline && vowlan.availability.isOnlineForDisplay
                    && vowlan.discoveredAgents.contains { $0.id == agent.id && $0.endpoint == vowlan.availability.endpoint }) {
            PairedAndroidDeviceStore.remember(.init(id: agent.id, deviceName: agent.deviceName, agentKind: agent.agentKind))
        }
        let records = PairedAndroidDeviceStore.records()
        if records != pairedDeviceRecords { pairedDeviceRecords = records }
    }

    func forgetAndroidDevice(_ agentID: String) async throws {
        guard !callLifecycleSnapshot.state.representsCall else {
            throw NSError(domain: "AirSIM.Pairing", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "End the current call before deleting a paired device"])
        }
        // Block before awaiting unpair, so delayed discovery/status callbacks cannot restore it.
        PairedAndroidDeviceStore.forget(agentID)
        pairedDeviceRecords = PairedAndroidDeviceStore.records()
        vowlan.forget(agentID)
        preferenceRevision &+= 1
        if hasStarted { restartPolling() }
    }

    func refreshPairedDeviceInformation() async {
        await vowlan.probeNow()
        // This is a user-triggered one-shot refresh, never a new Relay polling loop.
        if CloudModePreference.isEnabled() { _ = await refreshCloudStatusForDiagnostics() }
        rememberVerifiedDevices()
    }

    func bindAndroidAgent(_ agentID: String) {
        guard PairedAndroidDeviceStore.permits(agentID) else { return }
        AndroidAgentBindingPreference.set(agentID)
        vowlan.bind(to: agentID)
        preferenceRevision &+= 1
        if hasStarted { restartPolling() }
    }

    private var boundAgentID: String? {
        _ = preferenceRevision
        return AndroidAgentBindingPreference.selected()
    }

    private var boundVoWLANAgent: VoWLANDiscoveredAgent? {
        guard let boundAgentID else {
            return vowlan.availability.endpoint.flatMap { endpoint in
                vowlan.discoveredAgents.first(where: { $0.endpoint == endpoint })
            }
        }
        return vowlan.discoveredAgents.first(where: { $0.id == boundAgentID })
    }

    private func permitsVoWLANEndpoint(_ endpoint: VoWLANEndpoint?) -> Bool {
        guard let endpoint else { return false }
        if let agent = vowlan.discoveredAgents.first(where: { $0.endpoint == endpoint }),
           !PairedAndroidDeviceStore.permits(agent.id) { return false }
        guard boundAgentID != nil else { return true }
        return boundVoWLANAgent?.endpoint == endpoint
    }

    private var boundCloudReady: Bool {
        guard CloudModePreference.isEnabled() else { return false }
        if let active = cloudAgentStatus?.activeAgentID, !PairedAndroidDeviceStore.permits(active) { return false }
        guard let boundAgentID else {
            return cloudAgentStatus?.cloudOnline == true
                || (!PairedAndroidDeviceStore.hasForgottenDevices() && connectionSummary == .cloudOnly)
        }
        // The current Relay command channel addresses its active agent. Never show
        // another paired phone as dialable until that phone is the active cloud agent.
        return cloudAgentStatus?.activeAgentID == boundAgentID
            && cloudAgentStatus?.agents.first(where: { $0.id == boundAgentID })?.cloudOnline == true
    }

    private func startCloudStatusQueryIfNeeded(beforeBackgroundCall: Bool = false) {
        let isForeground = appIsActive
        guard AppRefreshPolicy.shouldQueryCloudStatus(
                cloudModeEnabled: CloudModePreference.isEnabled(),
                lastAttempt: lastCloudStatusRefresh,
                appIsForeground: isForeground,
                beforeLiveActivityCall: beforeBackgroundCall
              ) else { return }
        lastCloudStatusRefresh = Date()
        // A previous foreground's online result must not become fresh again while this request is pending.
        cloudAgentDirectory = nil
        cloudAgentStatus = nil
        let generation = cloudStatusRefreshGeneration
        cloudStatusRefreshTask = Task { [weak self] in
            let status = try? await VoIPPushController.shared.fetchCloudAgentStatus()
            guard let self, !Task.isCancelled,
                  generation == self.cloudStatusRefreshGeneration else { return }
            self.cloudAgentDirectory = status
            self.cloudAgentStatus = status
            self.rememberVerifiedDevices()
            if !self.isOnline && !self.vowlan.availability.isOnlineForDisplay {
                self.connectionSummary = ModuleConnectionPolicy.summary(
                    localControlReachable: false,
                    cloudHeartbeatFresh: status?.cloudOnline == true,
                    cellularState: status?.cellularState
                )
            }
        }
    }

    private func awaitCloudStatusForLiveActivity(call: CallRecord?) async {
        // An incoming call can update an existing Live Activity while the App is backgrounded.
        // Query once before that update, but never poll Relay for idle background updates.
        startCloudStatusQueryIfNeeded(beforeBackgroundCall: call != nil)
        await cloudStatusRefreshTask?.value
    }

    @discardableResult
    func refreshCloudStatusForDiagnostics() async -> CloudAgentStatus? {
        guard CloudModePreference.isEnabled() else {
            cloudAgentStatus = nil
            return nil
        }
        do {
            let status = try await VoIPPushController.shared.fetchCloudAgentStatusForDiagnostics()
            cloudAgentStatus = status
            cloudAgentDirectory = status
            rememberVerifiedDevices()
            lastCloudStatusRefresh = Date()
            if !vowlan.availability.isOnlineForDisplay {
                connectionSummary = ModuleConnectionPolicy.summary(
                    localControlReachable: false,
                    cloudHeartbeatFresh: status.cloudOnline,
                    cellularState: status.cellularState
                )
            }
            return status
        } catch {
            cloudAgentStatus = nil
            if !vowlan.availability.isOnlineForDisplay {
                connectionSummary = .offline
            }
            return nil
        }
    }

    var callUsesVoWLAN: Bool { currentCallTransport == .vowlan }

    var dialPadTransportPresentation: DialPadTransportPresentation? {
        _ = preferenceRevision
        return DialPadTransportPresentation.make(
            mode: ConnectionModePreference.selected(),
            vowlanOnline: permitsVoWLANEndpoint(vowlan.availability.endpoint)
                && vowlan.availability.isOnlineForDisplay,
            moduleLocalReachable: false,
            cloudOnline: boundCloudReady
        )
    }

    /// The dial view cannot rely solely on `isOnline`: that property represents the local USB control link and is intentionally
    /// false when the module only maintains a Relay heartbeat. Allow dialing when cloud mode is enabled and the heartbeat is fresh;
    /// actual execution still re-authenticates and verifies state inside the CallKit action.
    var canStartOutgoingCommand: Bool {
        _ = preferenceRevision
        return OutgoingCommandAvailability.isAvailable(
            mode: ConnectionModePreference.selected(),
            localControlReachable: permitsVoWLANEndpoint(vowlan.availability.endpoint)
                && vowlan.availability.allowsCallAttempt,
            cloudModeEnabled: CloudModePreference.isEnabled(),
            cloudHeartbeatFresh: boundCloudReady
        )
    }

    var callAudioStatusText: String {
        CallAudioStatusPresentation.text(
            transport: currentCallTransport, localAudioActive: audio.active,
            cloudState: cloudCallAudioState)
    }

    init(api: AirSIMAPI = AirSIMAPI()) {
        self.api = api
        // Recording state is read directly from the source store via isRecording/isRecordingBusy; errors are forwarded via callback,
        // replacing the legacy $isRecording.assign / $errorMessage.sink Combine pipelines.
        recordings.onErrorMessage = { [weak self] message in
            self?.errorMessage = message
        }
        let runtimePolicy = ConnectionModeRuntimePolicy(mode: ConnectionModePreference.selected())
        callKit.handler = self
        callKit.setEnabled(runtimePolicy.usesCallKit)
        // The cold-launch handler may have prepared TTS for a virtual incoming call before this model was created; sync the mirror when taking over the handler.
        isVirtualCallTTSPrepared = VirtualCallTTSController.shared.isPrepared
        WatchCallCoordinator.shared.configure(model: self)
        WatchCallCoordinator.shared.start()
        IPhoneCloudCallSession.shared.onAudioStateChange = { [weak self] state in
            self?.cloudCallAudioState = state
            if state.isConnected { self?.audio.retryRequestedSpeakerRoute() }
        }
        IPhoneCloudCallSession.shared.onLifecycleEvent = { [weak self] event in
            guard let self else { return }
            guard self.applyCallLifecycle(event) else { return }
            if event.state == .active {
                self.callKit.reportCurrentOutgoingConnected()
                self.updateRemoteCallState("active")
                Task { @MainActor [weak self] in await self?.startCallAudioIfReady() }
            } else if event.state.isTerminal {
                self.callPresentationSurface = nil
                if event.state == .failed { self.errorMessage = event.failure }
                self.scheduleCallHistoryRefresh(delay: .seconds(2))
            }
        }
        vowlan.onAvailabilityChange = { [weak self] availability in
            guard let self else { return }
            // availability and discoveredAgents are already tracked by @Observable; views establish dependencies directly on read
            // without needing objectWillChange forwarding.
            if availability.isOnlineForDisplay {
                Task { @MainActor in self.rememberVerifiedDevices() }
            }
            if case let .verified(endpoint, _) = availability,
               let credential = VoWLANCredentialStore.load() {
                let vowlanAPI = AirSIMAPI(route: .vowlan(
                    endpoint: endpoint,
                    credential: credential
                ))
                Task {
                    await VoIPPushController.shared.syncRegistration(with: vowlanAPI)
                }
            }
            guard self.currentCallTransport == .vowlan,
                  case .unavailable = availability,
                  self.callLifecycleSnapshot.state.representsCall else { return }
            Task { @MainActor [weak self] in await self?.endVoWLANCallAfterPathLoss() }
        }
    }

    func start(sceneIsActive: Bool) {
        guard !hasStarted else { return }
        hasStarted = true
        appIsActive = sceneIsActive
        requestMicrophoneOnForegroundIfNeeded()
        startCloudStatusQueryIfNeeded()
        let storedValue = UserDefaults.standard.object(forKey: backgroundStandbyKey) as? Bool
        let storedLowPowerValue = UserDefaults.standard.object(forKey: lowPowerModeKey) as? Bool
        lowPowerModeEnabled = storedLowPowerValue ?? true
        liveActivity.setEnabled(LiveActivityVisibilityPreference.isEnabled())
        backgroundStandby.setEnabled(storedValue ?? true)
        // Load the local phone cache before starting polling so the UI does not appear empty while the module is temporarily offline.
        restoreLocalHistory()
        scheduleCallHistoryRefresh()
        Task { await contacts.loadIfAuthorized() }
        if IncomingCallPresentationRequest.isPending() { presentCurrentCallInApp() }
        presentManagedCallAfterForegroundTransition()
        restartPolling()
    }

    /// Discard stale connections whenever returning from lock screen or background so pre-sleep timeouts cannot overwrite fresh state.
    func didBecomeActive() {
        appIsActive = true
        let discoveryWasAlreadyStarted = initialPermissionCoordinator.didStartDiscovery
        requestMicrophoneOnForegroundIfNeeded()
        startCloudStatusQueryIfNeeded()
        if discoveryWasAlreadyStarted {
            let runtimePolicy = ConnectionModeRuntimePolicy(mode: ConnectionModePreference.selected())
            if runtimePolicy.startsVoWLAN {
                vowlan.restartBrowsing()
                Task { await vowlan.probeNow() }
            }
        }
        eventStreamSupported = nil
        consecutivePollFailures = 0
        isReconnecting = false
        backgroundStandby.setApplicationIsBackground(false)
        guard hasStarted else {
            start(sceneIsActive: true)
            return
        }
        // The app may be woken by PushKit or background tasks before first unlock, when protected files temporarily read as empty.
        // Re-merge on foreground entry so an early empty read cannot overwrite persisted records on the phone.
        restoreLocalHistory()
        scheduleCallHistoryRefresh()
        Task { await contacts.loadIfAuthorized() }
        if IncomingCallPresentationRequest.isPending() { presentCurrentCallInApp() }
        presentManagedCallAfterForegroundTransition()
        restartPolling()
    }

    func willResignActive() {
        backgroundStandby.prepareForBackground()
    }

    func didEnterBackground() {
        appIsActive = false
        cloudStatusRefreshTask?.cancel()
        cloudStatusRefreshTask = nil
        cloudStatusRefreshGeneration &+= 1
        lastCloudStatusRefresh = .distantPast
        backgroundStandby.setApplicationIsBackground(true)
        moduleMetadataTask?.cancel()
        moduleMetadataTask = nil
        restartPolling()
    }

    private func requestMicrophoneOnForegroundIfNeeded() {
        guard initialPermissionTask == nil,
              appIsActive else { return }
        initialPermissionTask = Task { [weak self] in
            guard let self else { return }
            await self.initialPermissionCoordinator.requestIfNeeded(
                isForeground: { self.appIsActive },
                microphoneIsUndetermined: { self.audio.microphonePermissionIsUndetermined },
                requestMicrophone: { _ = await self.audio.requestMicrophonePermission() },
                startDiscovery: {
                    let policy = ConnectionModeRuntimePolicy(mode: ConnectionModePreference.selected())
                    if policy.startsVoWLAN { self.vowlan.startBrowsing() }
                },
                requestNotifications: { self.incomingNotifier.requestAuthorization() }
            )
            self.initialPermissionTask = nil
        }
    }

    func setBackgroundStandbyEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: backgroundStandbyKey)
        backgroundStandby.setEnabled(enabled)
    }

    func setLowPowerModeEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: lowPowerModeKey)
        lowPowerModeEnabled = enabled
        // Recreate the polling task immediately so user switches do not wait for the previous sleep interval to finish.
        if hasStarted { restartPolling() }
    }

    func setLiveActivityEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: LiveActivityVisibilityPreference.key)
        liveActivity.setEnabled(enabled)
        VoIPPushController.shared.setLiveActivityEnabled(enabled)
        if enabled {
            cloudStatusRefreshTask?.cancel()
            cloudStatusRefreshTask = nil
            cloudStatusRefreshGeneration &+= 1
            lastCloudStatusRefresh = .distantPast
            startCloudStatusQueryIfNeeded()
            Task { [weak self] in
                guard let self else { return }
                await self.cloudStatusRefreshTask?.value
                guard LiveActivityVisibilityPreference.isEnabled() else { return }
                let call = self.lifecycleRecord(from: self.activeCall ?? self.remoteCall)
                await self.liveActivity.update(
                    call: call,
                    callerName: call.map { self.contacts.displayName(for: $0.number) },
                    moduleOnline: self.isOnline,
                    cloudOnline: CloudModePreference.isEnabled()
                        && self.cloudAgentStatus?.cloudOnline == true,
                    transport: self.liveActivityTransport,
                    radio: self.modemStatus,
                    agent: self.liveActivityAgentSnapshot,
                    appIsActive: self.appIsActive
                )
            }
        }
    }

    func setLocalModeEnabled(_ enabled: Bool) {
        setConnectionMode(enabled ? .vowlan : .automatic)
    }

    func setConnectionMode(_ mode: AirSIMConnectionMode) {
        ConnectionModePreference.set(mode)
        let policy = ConnectionModeRuntimePolicy(mode: mode)
        cloudStatusRefreshTask?.cancel()
        cloudStatusRefreshTask = nil
        cloudStatusRefreshGeneration &+= 1
        lastCloudStatusRefresh = .distantPast
        if !policy.startsCloud {
            cloudAgentStatus = nil
            cloudAgentDirectory = nil
        }
        callKit.setEnabled(policy.usesCallKit)
        VoIPPushController.shared.setLocalModeEnabled(!policy.startsCloud)
        WatchCallCoordinator.shared.refreshMediaPolicy()
        if !policy.startsCloud {
            Task { [weak self] in
                guard let self, let (api, _) = await self.readyVoWLANRoute() else { return }
                try? await api.setPushCloudEnabled(false)
            }
        }
        if policy.startsVoWLAN {
            vowlan.restartBrowsing()
            Task { await vowlan.probeNow() }
        } else {
            vowlan.stopBrowsing()
        }
        if policy.startsCloud { startCloudStatusQueryIfNeeded() }
        preferenceRevision &+= 1
        if hasStarted { restartPolling() }
    }

    private func restartPolling() {
        pollingGeneration &+= 1
        let generation = pollingGeneration
        pollingTask?.cancel()
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.poll(generation: generation)
                guard let delay = self?.nextPollingDelay else { return }
                try? await Task.sleep(for: .seconds(delay))
            }
        }
    }

    /// Aligns with the module 1-second AT poll while online and backs off when offline to avoid repeatedly waking the phone and USB stack.
    private var nextPollingDelay: TimeInterval {
        if consecutivePollFailures > 0 {
            let maximumDelay: TimeInterval = appIsActive ? 3 : 30
            return min(maximumDelay, pow(2, Double(consecutivePollFailures - 1)))
        }
        if !appIsActive {
            // The long-poll itself waits up to 15 seconds; yield briefly after it returns before starting the next wait.
            if eventStreamSupported == true { return 0.1 }
            return lowPowerModeEnabled ? 10 : 2
        }
        if eventStreamSupported == true { return 0.1 }
        return 1
    }

    func stop() {
        scheduledCallHistoryRefreshTask?.cancel()
        scheduledCallHistoryRefreshTask = nil
        callHistoryRefreshTask?.cancel()
        pollingGeneration &+= 1
        pollingTask?.cancel()
        pollingTask = nil
        moduleMetadataTask?.cancel()
        moduleMetadataTask = nil
        audio.deactivate()
        backgroundStandby.setEnabled(false)
        Task { await liveActivity.stop() }
        if let samsungAPI = verifiedVoWLANAPI() {
            Task { try? await samsungAPI.setAudioHostEnabled(false) }
        }
    }

    private func poll(generation: Int) async {
        let selectedMode = ConnectionModePreference.selected()
        let preferredRoute = DialRouteSelector.preferred(
            mode: selectedMode,
            vowlanReady: permitsVoWLANEndpoint(vowlan.availability.endpoint)
                && vowlan.availability.isOnlineForDisplay,
            cloudReady: boundCloudReady
        )
        _ = preferredRoute
        do {
            let result = try await nextAgentEvent()
            let status = result.call
            guard !Task.isCancelled, generation == pollingGeneration else { return }
            let previousCall = activeCall
            let history = await mergeCallHistory(status.history ?? [], acknowledgingOn: result.api)
            let confirmedEndedCall = previousCall.flatMap { previous in
                status.history?.first { $0.id == previous.id && $0.endedAt != nil }
            }
            let acceptedActiveLifecycle: Bool
            if let active = status.active {
                acceptedActiveLifecycle = applyAgentCallRecord(active)
            } else if let ended = confirmedEndedCall {
                acceptedActiveLifecycle = false
                _ = applyAgentCallRecord(ended, forcedState: .ended)
            } else {
                acceptedActiveLifecycle = false
            }
            if let active = status.active {
                observedCallLocalAPI = (callID: active.id, service: result.api)
                // Dismiss the provisional outgoing call view only after Agent state converges with the unified call lifecycle,
                // otherwise a late ending event from the previous call would drop the user back to the dial pad after a few seconds.
                if acceptedActiveLifecycle || callLifecycleSnapshot.callID == active.id {
                    pendingOutgoingCall = nil
                }
                if activeCall != active { activeCall = active }
            } else if confirmedEndedCall != nil, activeCall != nil {
                activeCall = nil
                observedCallLocalAPI = nil
            }
            if let active = status.active {
                if remoteCall?.id == active.id { remoteCall = nil }
                if callPresentationSurface == nil,
                   !callLifecycleStore.suppressesPresentation(callID: active.id) {
                    callPresentationSurface = appIsActive ? .app : .system
                }
            } else if previousCall != nil,
                      callLifecycleSnapshot.state.isTerminal,
                      !IPhoneCloudCallSession.shared.hasActiveCall {
                callPresentationSurface = nil
                remoteCall = nil
            }
            if callHistory != history { callHistory = history }
            consecutivePollFailures = 0
            if isReconnecting { isReconnecting = false }
            lastSuccessfulLocalAPI = result.api

            if let call = status.active,
               ["dialing", "alerting", "incoming", "waiting"].contains(call.state),
               audioWarmupCallID != call.id {
                audioWarmupCallID = call.id
                // Prewarming only loads drivers and calibration, moving the slowest cold-start work ahead of call connection.
                Task { [weak self] in
                    guard let self else { return }
                    try? await AgentPollingRouteSelector.select(
                        primary: result.api,
                        lockedLocal: self.currentLocalAPI,
                        transport: self.currentCallTransport
                    ).warmAudioHost()
                }
            } else if status.active == nil, previousCall != nil {
                audioWarmupCallID = nil
            }
            // A successful HTTP response proves the USB module Agent is online. last_poll_error only reflects the latest
            // internal AT+CLCC poll and may be transiently non-empty during call setup, so do not mark the USB link offline from it.
            if !isOnline { isOnline = true }
            cloudAgentStatus = nil
            updateLocalConnectionSummary(cellularState: modemStatus?.cellularState)
            // PushKit tokens must be written to the currently reachable Agent; hotspot mode cannot hardcode the USB address.
            let callSyncSnapshot = callLifecycleSnapshot
            let callSyncAttempt = outgoingAttemptID
            await VoIPPushController.shared.syncRegistration(with: result.api)
            guard !Task.isCancelled, generation == pollingGeneration,
                  callLifecycleSnapshot == callSyncSnapshot, outgoingAttemptID == callSyncAttempt else { return }
            if AppRefreshPolicy.shouldRefreshSupplementalState(appIsActive: appIsActive) {
                scheduleModuleMetadataRefresh(generation: generation, api: result.api)
            }
            var lifecycleCall = lifecycleRecord(from: status.active ?? previousCall)
            let systemCall = status.active.flatMap {
                callLifecycleStore.suppressesPresentation(callID: $0.id) ? nil : $0
            }
            let callerName = (systemCall ?? lifecycleCall).map { contacts.displayName(for: $0.number) }
            // Request CallKit before deciding whether to post a local notification, otherwise background incoming calls would show
            // both the system call UI and a banner with an Answer button; fall back on the next poll if CallKit reporting fails.
            if !WatchCallCoordinator.shared.ownsMedia(callID: systemCall?.id) {
                callKit.synchronize(
                    // Preserve real Agent state except for identities explicitly
                    // ending/ended locally; a late poll must not create a new CXCall.
                    call: systemCall,
                    previous: confirmedEndedCall ?? previousCall,
                    callerName: callerName
                )
            }
            WatchCallCoordinator.shared.publish(
                call: lifecycleCall,
                previous: confirmedEndedCall ?? previousCall,
                callerName: callerName ?? previousCall.map { contacts.displayName(for: $0.number) }
            )
            await awaitCloudStatusForLiveActivity(call: lifecycleCall)
            // The status query may finish after a local hangup/new call.
            lifecycleCall = lifecycleRecord(from: activeCall ?? remoteCall)
            await liveActivity.update(
                call: lifecycleCall,
                callerName: callerName,
                moduleOnline: true,
                transport: liveActivityTransport,
                radio: modemStatus,
                agent: liveActivityAgentSnapshot,
                appIsActive: appIsActive
            )
            // Once CallKit succeeds, the system owns the lock-screen incoming call UI; post a user notification only when CallKit is unavailable or fails.
            if !callKit.suppressesInAppIncomingRingtone {
                incomingNotifier.update(
                    call: lifecycleCall,
                    callerName: callerName,
                    appIsActive: appIsActive
                )
            }
            if lifecycleCall?.direction == "incoming", callKit.suppressesInAppIncomingRingtone {
                // CallKit already plays the system ringtone; do not layer an in-app ringtone on top.
                audio.stopCallTone()
            } else {
                audio.updateCallTone(for: lifecycleCall)
            }

            // Existing users who already completed onboarding should still receive module updates; check in the background only when idle to avoid interrupting baseband media.
            // AirSIM neither bundles nor auto-flashes the QDC507 Agent.

            // Continuously verify that local audio is still running during an active call. After a CallKit or media server reset,
            // the next poll must be able to rebuild network PCM even if module state did not change.
            if status.active?.state == "active" {
                await startCallAudioIfReady()
            } else if status.active == nil, previousCall != nil {
                // Remote hangup bypasses the in-app end button; enable transition protection here too so brief ECM/AT jitter
                // during media teardown is not misreported as full module offline.
                beginCallTransitionProtection()
                // A cloud fallback call may remain active after local module state disappears; do not let local polling
                // clear the shared AVAudioSession speaker override or interrupt cloud PCM.
                if currentCallTransport != .cloud,
                   !IPhoneCloudCallSession.shared.hasActiveCall {
                    audio.deactivate()
                }
                guard !Task.isCancelled, generation == pollingGeneration else { return }
                backgroundStandby.resumeAfterCall()
                isMuted = false
            }
            if appIsActive, status.active?.state == "active",
               Date() >= nextAudioDiagnosticRefresh,
               let audioConfig = try? await AgentPollingRouteSelector.select(
                   primary: result.api,
                   lockedLocal: currentLocalAPI,
                   transport: currentCallTransport
               ).audioHostConfig() {
                // Diagnostic stats do not need to run on every call poll, reducing extra TCP connections and JSON decoding.
                nextAudioDiagnosticRefresh = Date().addingTimeInterval(3)
                audio.updateModuleDiagnostics(audioConfig)
            }
            if result.smsChanged {
                await loadMessagesFromAgent(
                    silently: true, notifyIfBackground: true, reportingAgent: result.api
                )
            }
        } catch {
            guard !Task.isCancelled, generation == pollingGeneration else { return }
#if DEBUG
            print("[AirSIM Poll] module status failed: \(error.localizedDescription)")
#endif
            consecutivePollFailures += 1
            isReconnecting = true
            let failedRouteName: String = {
                guard let route = lastSuccessfulLocalAPI?.route else { return "Local Control Connection" }
                if case .vowlan = route { return "VoWLAN" }
                return "Local Module Connection"
            }()
            connectionMessage = "Reconnecting\(failedRouteName): \(error.localizedDescription)"

            // A single long-poll interruption does not mean USB ECM is offline. Preserve the last online state during the 8s
            // grace window after a call action, and require three consecutive failures plus an independent health check failure afterward.
            guard ModuleConnectivityPolicy.shouldConfirmOffline(
                consecutiveFailures: consecutivePollFailures,
                now: Date(),
                protectedUntil: callTransitionProtectedUntil
            ) else { return }

            // Re-verify health using the last local route that actually succeeded. When a VoWLAN long-poll drops transiently,
            // do not probe the default USB address and misclassify the Samsung Agent as offline.
            let healthAPI = lastSuccessfulLocalAPI ?? verifiedVoWLANAPI()
            let health = try? await healthAPI?.health()
            guard ModuleConnectivityPolicy.shouldMarkOffline(
                consecutiveFailures: consecutivePollFailures,
                healthRequestSucceeded: health != nil,
                now: Date(),
                protectedUntil: callTransitionProtectedUntil
            ) else {
                guard !Task.isCancelled, generation == pollingGeneration else { return }
                consecutivePollFailures = 0
                isReconnecting = health?.ok == false
                if !isOnline { isOnline = true }
                cloudAgentStatus = nil
                updateLocalConnectionSummary(cellularState: health?.cellularState)
                if health?.ok == false {
                    connectionMessage = health?.cellularRecovery?.isEmpty == false
                        ? "Module connected, recovering AT channel · \(health!.cellularRecovery!)"
                        : "Module connected, recovering AT channel automatically"
                }
                return
            }

            guard !Task.isCancelled, generation == pollingGeneration else { return }
            if IPhoneCloudCallSession.shared.hasActiveCall || IPhoneCloudCallSession.shared.isRecovering {
                // An established cloud media session is independent proof that cloud is online. Brief USB/ECM route jitter
                // when answering must neither mark the module offline nor end the Dynamic Island activity.
                consecutivePollFailures = 0
                if isOnline { isOnline = false }
                isReconnecting = true
                connectionSummary = ModuleConnectionPolicy.summary(
                    localControlReachable: false,
                    cloudHeartbeatFresh: true,
                    cellularState: cloudAgentStatus?.cellularState ?? modemStatus?.cellularState
                )
                connectionMessage = IPhoneCloudCallSession.shared.isRecovering
                    ? "Cloud call active, reconnecting internet PCM"
                    : "Cloud call active, reconnecting USB ECM"
                var lifecycleCall = lifecycleRecord(from: activeCall ?? remoteCall)
                await awaitCloudStatusForLiveActivity(call: lifecycleCall)
                lifecycleCall = lifecycleRecord(from: activeCall ?? remoteCall)
                await liveActivity.update(
                    call: lifecycleCall,
                    callerName: lifecycleCall.map { contacts.displayName(for: $0.number) },
                    moduleOnline: false,
                    cloudOnline: true,
                    transport: .cloud,
                    radio: modemStatus,
                    agent: liveActivityAgentSnapshot,
                    appIsActive: appIsActive
                )
                return
            }
            if isOnline { isOnline = false }
            lastSuccessfulLocalAPI = nil
            audio.stopCallTone()
            await awaitCloudStatusForLiveActivity(call: nil)
            let cloudStatus = CloudModePreference.isEnabled() &&
                Date().timeIntervalSince(lastCloudStatusRefresh) <= 90
                ? (cloudAgentDirectory ?? cloudAgentStatus) : nil
            guard !Task.isCancelled, generation == pollingGeneration else { return }
            cloudAgentStatus = cloudStatus
            connectionSummary = ModuleConnectionPolicy.summary(
                localControlReachable: false,
                cloudHeartbeatFresh: cloudStatus?.cloudOnline == true,
                cellularState: cloudStatus?.cellularState
            )
            if cloudStatus?.cloudOnline == true {
                isReconnecting = true
                if let version = cloudStatus?.agentVersion, !version.isEmpty { agentVersion = version }
                connectionMessage = cloudConnectionMessage(for: cloudStatus!)
                // Unreachable local USB control does not mean the module is offline. Keep Dynamic Island standby while the Relay heartbeat is fresh;
                // incoming calls can still wake via PushKit and use cloud PCM.
                let lifecycleCall = lifecycleRecord(from: activeCall ?? remoteCall)
                await liveActivity.update(
                    call: lifecycleCall,
                    callerName: lifecycleCall.map { contacts.displayName(for: $0.number) },
                    moduleOnline: false,
                    cloudOnline: true,
                    transport: .cloud,
                    radio: modemStatus,
                    agent: liveActivityAgentSnapshot,
                    appIsActive: appIsActive
                )
            } else {
                isReconnecting = false
                connectionMessage = "Module is unreachable locally and through cloud: \(error.localizedDescription)"
                await liveActivity.markOffline(
                    agent: liveActivityAgentSnapshot,
                    appIsActive: appIsActive
                )
            }
        }

    }

    private struct AgentPollResult {
        let call: CallStatus
        let smsChanged: Bool
        let api: AirSIMAPI
    }

    private func nextAgentEvent() async throws -> AgentPollResult {
        if verifiedVoWLANAPI() == nil {
            await vowlan.recoverIfNeeded()
        }
        guard let samsungAPI = verifiedVoWLANAPI() else {
            throw CallKitBridgeError.noReachableTransport
        }
        let pollingAPI = AgentPollingRouteSelector.select(
            primary: samsungAPI,
            lockedLocal: currentLocalAPI,
            transport: currentCallTransport
        )
        if eventStreamSupported != false {
            do {
                let event = try await pollingAPI.waitForAgentEvent(
                    after: eventRevision,
                    timeout: AgentEventPollingPolicy.timeout(hasActiveCall: callLifecycleSnapshot.state.representsCall)
                )
                eventStreamSupported = true
                eventRevision = AgentEventCursor.advanced(from: eventRevision, to: event.revision)
                let shouldFetchSMS = AgentEventPollingPolicy.shouldFetchSMS(
                    pending: event.smsPending,
                    eventRevision: event.smsRevision,
                    observedSMSRevision: smsRevision
                )
                smsRevision = event.smsRevision
                return AgentPollResult(
                    call: event.call,
                    smsChanged: shouldFetchSMS,
                    api: pollingAPI
                )
            } catch APIError.http(404, _) {
                // Older Agents (such as 0.3.18) lack the unified events endpoint; keep fallback polling until the module is upgraded.
                eventStreamSupported = false
            }
        }
        let legacy = try await LegacyAgentPoller.next(pollingAPI)
        return AgentPollResult(call: legacy.call, smsChanged: legacy.smsChanged, api: pollingAPI)
    }

    private func verifiedVoWLANAPI() -> AirSIMAPI? {
        guard vowlan.availability.isOnlineForDisplay,
              let endpoint = vowlan.availability.endpoint,
              permitsVoWLANEndpoint(endpoint),
              let credential = VoWLANCredentialStore.load() else { return nil }
        return AirSIMAPI(route: .vowlan(endpoint: endpoint, credential: credential))
    }

    private var moduleLocalIsReachable: Bool {
        false
    }

    private var reachableLocalAPI: AirSIMAPI? {
        if let currentLocalAPI, AirSIMRoutePolicy.permits(currentLocalAPI.route) {
            return currentLocalAPI
        }
        guard isOnline, !isReconnecting else { return nil }
        guard let lastSuccessfulLocalAPI,
              AirSIMRoutePolicy.permits(lastSuccessfulLocalAPI.route) else { return nil }
        return lastSuccessfulLocalAPI
    }

    private var localCallControlAPI: AirSIMAPI? {
        LocalCallControlTarget.select(
            locked: currentLocalAPI,
            observed: observedCallLocalAPI,
            fallback: reachableLocalAPI,
            targetCallID: activeCall?.id
        )
    }

    private var liveActivityTransport: AirSIMCallActivityAttributes.ContentState.Transport? {
        switch currentCallTransport {
        case .vowlan: return .vowlan
        case .cloud: return .cloud
        case .moduleLocal: return .moduleLocal
        case nil: break
        }
        switch DialRouteSelector.preferred(
            mode: ConnectionModePreference.selected(),
            vowlanReady: permitsVoWLANEndpoint(vowlan.availability.endpoint)
                && vowlan.availability.isOnlineForDisplay,
            cloudReady: boundCloudReady
        ) {
        case .vowlan: return .vowlan
        case .cloud: return .cloud
        case .moduleLocal: return .moduleLocal
        case nil: return nil
        }
    }

    private var liveActivityAgentSnapshot: LiveActivityAgentSnapshot? {
        let agents = pairedAndroidAgents
        guard !agents.isEmpty else { return nil }
        return LiveActivityAgentSnapshot(
            agent: agents.first(where: \.isCurrent),
            pairedAgentCount: agents.count
        )
    }

    private static func pcmRoute(for route: LocalAgentRoute) -> PCMRoute {
        switch route {
        case .moduleLocal:
            return .moduleLocal
        case let .vowlan(endpoint, credential):
            return .vowlan(endpoint: endpoint, credential: credential)
        }
    }

    /// Cellular status and version do not need to run on every 1s call poll; refreshing them independently prevents slow AT status queries from delaying incoming call detection.
    private func scheduleModuleMetadataRefresh(generation: Int, api: AirSIMAPI) {
        guard moduleMetadataTask == nil, Date() >= nextModuleMetadataRefresh else { return }
        nextModuleMetadataRefresh = Date().addingTimeInterval(10)
        moduleMetadataTask = Task { [weak self] in
            await self?.refreshModuleMetadata(generation: generation, api: api)
        }
    }

    private func refreshModuleMetadata(generation: Int, api: AirSIMAPI) async {
        defer { moduleMetadataTask = nil }
        async let radioRequest = try? api.modemStatus()
        let radio = await radioRequest
        guard !Task.isCancelled, generation == pollingGeneration, isOnline, appIsActive else { return }
        if let radio, modemStatus != radio { modemStatus = radio }
        updateLocalConnectionSummary(cellularState: radio?.cellularState ?? modemStatus?.cellularState)
        var lifecycleCall = lifecycleRecord(from: activeCall ?? remoteCall)
        await awaitCloudStatusForLiveActivity(call: lifecycleCall)
        lifecycleCall = lifecycleRecord(from: activeCall ?? remoteCall)
        await liveActivity.update(
            call: lifecycleCall,
            callerName: lifecycleCall.map { contacts.displayName(for: $0.number) },
            moduleOnline: true,
            transport: liveActivityTransport,
            radio: modemStatus,
            agent: liveActivityAgentSnapshot,
            appIsActive: appIsActive
        )
    }

    private func updateLocalConnectionSummary(cellularState: String?) {
        connectionSummary = ModuleConnectionPolicy.summary(
            localControlReachable: true,
            cloudHeartbeatFresh: false,
            cellularState: cellularState
        )
        switch connectionSummary {
        case .localOnline:
            connectionMessage = nil
        case .localOnlineNoService:
            let detail = modemStatus?.cellularRecovery ?? modemStatus?.registrationText
            connectionMessage = detail?.isEmpty == false
                ? "USB ECM Connected · \(detail!)"
                : "USB ECM connected, cellular network recovering"
        case .cloudOnly, .offline:
            break
        }
    }

    private func cloudConnectionMessage(for status: CloudAgentStatus) -> String {
        let local = "USB ECM disconnected, module online through cloud"
        if status.cellularState == "registered" {
            return local + "; incoming calls will use cloud"
        }
        let detail = status.cellularRecovery?.isEmpty == false
            ? status.cellularRecovery!
            : (status.cellularRegistration?.isEmpty == false ? status.cellularRegistration! : "Cellular network recovering")
        return local + " · " + detail
    }

    func dial() async {
        let number = Self.validatedNumber(numberInput)
        guard !number.isEmpty else { return }
        callPresentationSurface = .app
        let now = Date()
        pendingOutgoingCall = CallRecord(
            id: "pending-\(UUID().uuidString.lowercased())",
            index: 0,
            direction: "outgoing",
            state: "dialing",
            number: number,
            startedAt: now,
            updatedAt: now,
            endedAt: nil,
            missed: false
        )
        debugDialLog(LocalModePreference.isEnabled() ? "Placing direct outgoing call in local mode" : "Submitting CallKit outgoing call transaction")
        await perform {
            if LocalModePreference.isEnabled() {
                try await self.callKitStart(number: number)
                return
            }
            do {
                try await self.callKit.startOutgoingCall(number: number)
                debugDialLog("CallKit outgoing call transaction submitted")
            } catch CallKitBridgeError.unavailable {
                // Still allow dialing when CallKit is restricted or disabled by the system, without fabricating a system UUID.
                // Reuse standard route selection so both control and PCM stay pinned to the hotspot when VoWLAN is online.
                try await self.callKitStart(number: number)
                debugDialLog("CallKit unavailable; dialing directly over current transport route")
            }
        }
    }

    func answer() async {
        beginCallTransitionProtection()
        audio.stopCallTone()
        callPresentationSurface = .app
        applyCurrentCallIntent(.connecting, source: .app)
        if callKit.managesCurrentCall {
            await perform {
                do {
                    try await self.callKit.answerCurrentCall(presentInApp: true)
                } catch CallKitBridgeError.staleSystemCall {
                    // Reuse standard route selection while system UI is rebuilding rather than falling back to the default USB address.
                    try await self.callKitAnswer(origin: .app)
                }
            }
        } else {
            await perform { try await self.callKitAnswer(origin: .app) }
        }
    }

    func presentCurrentCallInApp() {
        if remoteCall == nil, let incoming = callKit.currentIncomingPush {
            remoteCall = Self.remoteCallRecord(from: incoming, state: "incoming")
        }
        guard callLifecycleSnapshot.state.representsCall else { return }
        _ = IncomingCallPresentationRequest.consume()
        callPresentationSurface = .app
    }

    /// Answering from the system normally stays in CallKit. If iOS, a user notification, or a user gesture brings
    /// AirSIM to the foreground, present the same call rather than dropping the user onto the Dial or Settings screen.
    private func presentManagedCallAfterForegroundTransition() {
        guard appIsActive,
              CallPresentationPolicy.shouldPresentWhenAppBecomesActive(
                  managesSystemCall: callKit.managesCurrentCall,
                  hasLocalCall: lifecycleRecord(from: activeCall) != nil,
                  hasRemoteCall: lifecycleRecord(from: remoteCall) != nil
              ) else { return }
        if remoteCall == nil, let incoming = callKit.currentIncomingPush {
            remoteCall = Self.remoteCallRecord(
                from: incoming,
                state: callKit.currentCallIsAnswered ? "active" : "incoming"
            )
        } else if callKit.currentCallIsAnswered {
            updateRemoteCallState("active")
        }
        callPresentationSurface = .app
    }

    func reject() async {
        outgoingAttemptID = UUID()
        beginCallTransitionProtection()
        audio.stopCallTone()
        applyCurrentCallIntent(.ending, source: .app)
        if callKit.managesCurrentCall {
            await perform(allowWhileBusy: true) {
                do {
                    try await self.callKit.endCurrentCall()
                } catch CallKitBridgeError.staleSystemCall {
                    try await self.rejectUsingAvailableTransport()
                }
            }
        } else {
            await perform(allowWhileBusy: true) { try await self.rejectUsingAvailableTransport() }
        }
    }

    func hangup() async {
        outgoingAttemptID = UUID()
        beginCallTransitionProtection()
        audio.stopCallTone()
        applyCurrentCallIntent(.ending, source: .app)
        if callKit.managesCurrentCall {
            await perform(allowWhileBusy: true) {
                do {
                    try await self.callKit.endCurrentCall()
                } catch CallKitBridgeError.staleSystemCall {
                    try await self.hangupUsingAvailableTransport()
                }
            }
        } else {
            await perform(allowWhileBusy: true) { try await self.hangupUsingAvailableTransport() }
        }
    }

    private func rejectUsingAvailableTransport() async throws {
        if currentCallTransport == .cloud || IPhoneCloudCallSession.shared.isPrepared {
            await IPhoneCloudCallSession.shared.end()
            return
        }
        if let localAPI = reachableLocalAPI {
            _ = try await localAPI.rejectCall(callID: activeCall?.id)
            return
        }
        if let pushedCall = callKit.currentIncomingPush,
           pushedCall.authenticatedMediaURL != nil {
            try await IPhoneCloudCallSession.shared.reject(pushedCall)
            return
        }
        throw CallKitBridgeError.noReachableTransport
    }

    private func hangupUsingAvailableTransport() async throws {
        if currentCallTransport == .cloud || IPhoneCloudCallSession.shared.isPrepared {
            await IPhoneCloudCallSession.shared.end()
            return
        }
        guard let localAPI = reachableLocalAPI else {
            throw CallKitBridgeError.noReachableTransport
        }
        try await localAPI.hangupCall(callID: activeCall?.id)
    }

    private func beginCallTransitionProtection() {
        callTransitionProtectedUntil = Date().addingTimeInterval(
            ModuleConnectivityPolicy.callTransitionGraceInterval
        )
    }
    func sendDTMF(_ digit: String) async {
        await perform {
            if self.callKit.managesCurrentCall {
                do {
                    // In-app keypad and system call UI share CallKit transactions so DTMF ordering stays consistent.
                    try await self.callKit.playDTMF(digit)
                } catch CallKitBridgeError.staleSystemCall {
                    try await self.sendDTMFUsingAvailableTransport(digit)
                }
            } else {
                try await self.sendDTMFUsingAvailableTransport(digit)
            }
        }
    }

    private func sendDTMFUsingAvailableTransport(_ digit: String) async throws {
        if currentCallTransport == .cloud {
            try await VoIPPushController.shared.sendCloudDTMF(digit)
            return
        }
        guard let localAPI = reachableLocalAPI else {
            throw CallKitBridgeError.noReachableTransport
        }
        try await localAPI.sendDTMF(digit)
    }

    func toggleMute() async {
        let target = !isMuted
        if callKit.managesCurrentCall {
            do {
                try await callKit.setMuted(target)
                errorMessage = nil
            } catch {
                // The CallKit UUID may become transiently invalid after a system reset; local PCM can still reliably control the microphone.
                if case CallKitBridgeError.staleSystemCall = error {
                    isMuted = target
                    audio.setMuted(target)
                    errorMessage = nil
                } else {
                    errorMessage = "System mute change failed: \(error.localizedDescription)"
                }
            }
            return
        }
        // Mobile uplink voice is generated by the local PCM pipeline; mute locally first without depending on module AT command success.
        isMuted = target
        audio.setMuted(target)
        // Some QDC507 firmware versions do not implement AT+CMUT; local PCM is already the authoritative mute state on mobile,
        // so background sync failures must not interrupt the call or show a misleading mute error.
        if let localAPI = reachableLocalAPI {
            Task { try? await localAPI.setAudioMuted(target) }
        }
        errorMessage = nil
    }

    func toggleSpeaker() {
        // Speaker toggling applies only to the current system audio session; if CallKit has not finished activating yet,
        // AudioSessionController preserves the request and retries briefly without surfacing OSStatus -50.
        audio.toggleSpeakerRoute()
        errorMessage = nil
    }

    var canToggleRecording: Bool {
        !isRecordingBusy && (isRecording || callLifecycleSnapshot.state == .active)
    }

    func toggleRecording() async {
        guard !recordings.isBusy else { return }
        do {
            if recordings.isRecording {
                try await recordings.stop()
            } else {
                guard let callID = callLifecycleSnapshot.callID,
                      callLifecycleSnapshot.state == .active else {
                    errorMessage = "Recording is available once the call is connected"
                    return
                }
                guard !WatchCallCoordinator.shared.ownsMedia(callID: callID) else {
                    errorMessage = "Recording is available when call audio is on this iPhone"
                    return
                }
                let source: CallRecordingSource
                switch currentCallTransport {
                case .cloud: source = IPhoneCloudCallSession.shared.recordingSource
                default: source = .localPCM
                }
                CallAudioRecorder.shared.setMuted(isMuted)
                try await recordings.start(callID: callID, source: source)
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Logs the dial path during device debugging without recording phone numbers; compiled out in Release builds.
    private func debugDialLog(_ message: String) {
#if DEBUG
        print("[AirSIM Dial] \(message)")
#endif
    }

    func sendSMS(to phone: String, content: String) async -> Bool {
        let target = Self.validatedNumber(phone)
        let body = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty, !body.isEmpty, body.count <= 2_000 else { return false }
        do {
            let localAPI = verifiedVoWLANAPI()
            // A signed VoWLAN health check is the reachability authority. The global
            // polling flags can briefly lag during route switches and must not disable SMS.
            let localReachable = localAPI != nil
            let result: SMSSendResult
            if localReachable {
                result = try await localAPI!.sendSMS(to: target, message: body)
            } else if CloudModePreference.isEnabled() {
                let status: CloudAgentStatus
                if let cloudAgentStatus {
                    status = cloudAgentStatus
                } else {
                    status = try await VoIPPushController.shared.fetchCloudAgentStatus()
                }
                guard status.cloudOnline,
                      self.boundAgentID == nil || status.activeAgentID == self.boundAgentID
                else { throw CloudCommandError.unavailable }
                result = try await VoIPPushController.shared.sendCloudSMS(to: target, message: body)
            } else {
                throw CloudCommandError.cloudModeDisabled
            }
            if result.sent {
                saveSentMessage(recipient: target, content: body)
            }
            if localReachable { await refreshMessages(silently: true) }
            return result.sent
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func refreshMessages(silently: Bool = false) async {
        do {
            guard let samsungAPI = verifiedVoWLANAPI() else {
                throw CallKitBridgeError.noReachableTransport
            }
            try await samsungAPI.refreshSMS()
            await loadMessagesFromAgent(silently: silently, reportingAgent: samsungAPI)
            if !silently { errorMessage = nil }
        } catch {
            if !silently { errorMessage = error.localizedDescription }
        }
    }

    /// URC already prompted the Agent to read the single SMS; the event path fetches only the delivery queue without triggering a full CMGL scan.
    func loadMessagesFromAgent(
        silently: Bool = false,
        notifyIfBackground: Bool = false,
        reportingAgent: AirSIMAPI? = nil
    ) async {
        do {
            guard let currentAgent = verifiedVoWLANAPI() ?? reportingAgent else {
                throw CallKitBridgeError.noReachableTransport
            }
            let fetched = try await AgentSMSInboxFetch.fetch(
                reportingAgent: reportingAgent, discoveredAgent: currentAgent
            )
            let remoteMessages = fetched.messages
            let existingIDs = Set(messages.map(\.id))
            let newlyReceived = remoteMessages
                .filter { !existingIDs.contains($0.id) }
                .sorted { $0.timestamp < $1.timestamp }
            let mergedMessages = await mergeMessages(remoteMessages, acknowledgingOn: fetched.agent)
            if messages != mergedMessages { messages = mergedMessages }
            if notifyIfBackground {
                for message in newlyReceived.suffix(3) {
                    incomingSMSNotifier.notify(
                        message: message,
                        displayName: contacts.displayName(for: message.sender),
                        appIsActive: appIsActive
                    )
                }
            }
            if !silently { errorMessage = nil }
        } catch {
            if !silently { errorMessage = error.localizedDescription }
        }
    }

    func clearLocalMessages() {
        guard historyStore.saveMessages([]) else {
            errorMessage = "Unable to clear local messages. Try again later."
            return
        }
        messages = []
        errorMessage = nil
    }

    /// foreach.md: grouping and sorting recompute only when the message collection changes, triggered by messages.didSet.
    private func rebuildConversations() {
        conversations = Dictionary(grouping: messages, by: \.sender)
            .map { ($0.key, $0.value.sorted { $0.timestamp < $1.timestamp }) }
            .sorted { ($0.messages.last?.timestamp ?? .distantPast) > ($1.messages.last?.timestamp ?? .distantPast) }
    }

    func deleteCallHistory(ids: Set<String>) {
        guard !ids.isEmpty else { return }
        let deletedIDs = historyStore.loadDeletedCallIDs().union(ids)
        guard historyStore.saveDeletedCallIDs(deletedIDs) else {
            errorMessage = "Unable to delete local call history. Try again later."
            return
        }
        let remaining = callHistory.filter { !ids.contains($0.id) }
        guard historyStore.saveCallHistory(remaining) else {
            errorMessage = "Unable to delete local call history. Try again later."
            return
        }
        callHistory = remaining
        errorMessage = nil
    }

    func refreshCallHistory() async {
        restoreLocalHistory()
        if let task = callHistoryRefreshTask {
            await task.value
            return
        }
        guard !callLifecycleSnapshot.state.representsCall,
              !IPhoneCloudCallSession.shared.hasActiveCall else {
            callHistoryMessage = "Call history will refresh after the call ends."
            return
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            self.isRefreshingCallHistory = true
            defer {
                self.isRefreshingCallHistory = false
                self.callHistoryRefreshTask = nil
            }
            do {
                let records: [CallRecord]
                let source: AirSIMAPI?
                if let local = self.verifiedVoWLANAPI() {
                    do {
                        records = try await local.callStatus().history ?? []
                        source = local
                    } catch {
                        guard CloudModePreference.isEnabled() else { throw error }
                        records = try await VoIPPushController.shared.fetchCloudCallHistory()
                        source = nil
                    }
                } else if CloudModePreference.isEnabled() {
                    records = try await VoIPPushController.shared.fetchCloudCallHistory()
                    source = nil
                } else {
                    throw CloudCommandError.unavailable
                }
                try Task.checkCancellation()
                self.callHistory = await self.mergeCallHistory(records, acknowledgingOn: source)
                self.callHistoryMessage = nil
            } catch is CancellationError {
                // Keep the durable cache when the view or app stops.
            } catch {
                if !Task.isCancelled {
                    self.callHistoryMessage = "Could not refresh call history. " + error.localizedDescription
                }
            }
        }
        callHistoryRefreshTask = task
        await task.value
    }

    private func scheduleCallHistoryRefresh(delay: Duration = .zero) {
        scheduledCallHistoryRefreshTask?.cancel()
        scheduledCallHistoryRefreshTask = Task { @MainActor [weak self] in
            if delay > .zero {
                do { try await Task.sleep(for: delay) } catch { return }
            }
            guard !Task.isCancelled else { return }
            await self?.refreshCallHistory()
        }
    }

    func reloadMessagesFromLocalStore() {
        restoreLocalHistory()
    }

    /// Merges the disk copy into in-memory state, adding or updating records while never wiping UI data with an empty read.
    private func restoreLocalHistory() {
        let storedCalls = historyStore.loadCallHistory()
        if !storedCalls.isEmpty {
            var callsByID: [String: CallRecord] = [:]
            for record in callHistory { callsByID[record.id] = record }
            for record in storedCalls {
                if let existing = callsByID[record.id], existing.updatedAt >= record.updatedAt {
                    continue
                }
                callsByID[record.id] = record
            }
            callHistory = normalizedCallHistory(Array(callsByID.values))
        }

        let storedMessages = historyStore.loadMessages()
        if !storedMessages.isEmpty {
            var messagesByID: [String: SMSMessage] = [:]
            for message in messages { messagesByID[message.id] = message }
            for message in storedMessages { messagesByID[message.id] = message }
            messages = normalizedMessages(Array(messagesByID.values))
        }
    }

    /// The remote list may shrink after module reboot, auto-cleanup, or offline state, so perform a union merge without deleting local phone records.
    private func mergeCallHistory(
        _ remote: [CallRecord], acknowledgingOn source: AirSIMAPI? = nil
    ) async -> [CallRecord] {
        let merged = CallHistoryPolicy.merged(
            local: callHistory, remote: remote,
            deletedIDs: historyStore.loadDeletedCallIDs(), limit: maxCallHistoryCount
        )
        if !remote.isEmpty, historyStore.saveCallHistory(merged) {
            // Acknowledge to the module only after the local phone copy is saved so the module retains its undelivered queue across disconnects.
            let persistedIDs = Set(merged.map(\.id))
            let acknowledgedIDs = remote.map(\.id).filter { persistedIDs.contains($0) }
            if let source, !acknowledgedIDs.isEmpty {
                try? await source.acknowledgeCallHistory(ids: acknowledgedIDs)
            }
        }
        // The local poll or a deletion can complete while the acknowledgement is in flight.
        return CallHistoryPolicy.merged(
            local: callHistory, remote: merged,
            deletedIDs: historyStore.loadDeletedCallIDs(), limit: maxCallHistoryCount
        )
    }

    private func mergeMessages(
        _ remote: [SMSMessage], acknowledgingOn source: AirSIMAPI
    ) async -> [SMSMessage] {
        var byID: [String: SMSMessage] = [:]
        for message in messages { byID[message.id] = message }
        for var message in remote {
            // Preserve the existing local identifier when an older module omits delivery_id to avoid flip-flopping across versions.
            if message.deliveryID == nil { message.deliveryID = byID[message.id]?.deliveryID }
            byID[message.id] = message
        }
        let merged = normalizedMessages(Array(byID.values))
        if !remote.isEmpty, historyStore.saveMessages(merged) {
            let persistedIDs = Set(merged.map(\.id))
            let acknowledgedIDs = remote
                .filter { persistedIDs.contains($0.id) }
                .compactMap(\.deliveryID)
            try? await source.acknowledgeMessages(ids: acknowledgedIDs)
        }
        return merged
    }

    /// The module inbox endpoint does not echo sent SMS messages, so write them to local phone history immediately after sending.
    private func saveSentMessage(recipient: String, content: String) {
        let updatedMessages = SMSHistoryPolicy.appendingSentMessage(
            recipient: recipient,
            content: content,
            at: .now,
            to: messages,
            limit: maxMessageCount
        )
        messages = updatedMessages
        if !historyStore.saveMessages(updatedMessages) {
            errorMessage = "Message sent, but could not be saved locally. Refresh later to confirm."
        }
    }

    private func normalizedCallHistory(_ records: [CallRecord]) -> [CallRecord] {
        CallHistoryPolicy.merged(
            local: [], remote: records,
            deletedIDs: historyStore.loadDeletedCallIDs(), limit: maxCallHistoryCount
        )
    }

    private func normalizedMessages(_ records: [SMSMessage]) -> [SMSMessage] {
        Array(records
            .sorted { $0.timestamp > $1.timestamp }
            .prefix(maxMessageCount))
    }

    private func perform(
        allowWhileBusy: Bool = false,
        _ operation: () async throws -> Void
    ) async {
        guard allowWhileBusy || !isBusy else { return }
        activeOperationCount += 1
        isBusy = true
        defer {
            activeOperationCount -= 1
            isBusy = activeOperationCount > 0
        }
        do {
            try await operation()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func startCallAudioIfReady() async {
        if WatchCallCoordinator.shared.ownsMedia(callID: activeCall?.id)
            || WatchCallCoordinator.shared.ownsMedia(callID: remoteCall?.id)
            || WatchCallCoordinator.shared.ownsMedia(callID: callLifecycleSnapshot.callID) {
            return
        }
        let managedByCallKit = callKit.managesCurrentCall
        let cloudSession = IPhoneCloudCallSession.shared
        if cloudSession.call != nil, cloudSession.answered {
            if CloudCallAudioStartupPolicy.shouldStart(
                answered: true,
                mediaPrepared: cloudSession.isPrepared,
                lifecycleState: cloudSession.lifecycleState,
                isOutgoing: cloudSession.call?.isOutgoing == true,
                managedByCallKit: managedByCallKit,
                callKitAudioSessionActive: callKit.audioSessionIsActive
            ) {
                backgroundStandby.suspendForCall()
                currentCallTransport = .cloud
                cloudSession.startAudioWithRetry()
            }
            return
        }
        guard !managedByCallKit || callKit.audioSessionIsActive else { return }
        guard callLifecycleSnapshot.state == .active, !audio.active, !startingCallAudio else { return }
        startingCallAudio = true
        defer { startingCallAudio = false }
        backgroundStandby.suspendForCall()

        do {
            guard let localAPI = reachableLocalAPI else {
                backgroundStandby.resumeAfterCall()
                errorMessage = "Local audio route is not locked yet"
                return
            }
            let pcmRoute = currentPCMRoute ?? Self.pcmRoute(for: localAPI.route)
            let vowlanCallUUID = callLifecycleSnapshot.callUUID ?? UUID()
            let vowlanGeneration = max(UInt64(1), callLifecycleSnapshot.generation)
            // Complete microphone authorization and WebRTC startup before registering the audio host.
            let outcome = try await LocalCallAudioStartupCoordinator.start(
                activatePhoneAudio: { [audio] in
                    await audio.activateForCall(
                        route: pcmRoute,
                        sessionAlreadyActive: managedByCallKit,
                        callUUID: vowlanCallUUID,
                        generation: vowlanGeneration
                    )
                },
                registerAgentAudio: {
                    try await CallAudioRegistrationCoordinator.register(service: localAPI)
                },
                rollbackPhoneAudio: { [audio] in
                    audio.deactivate()
                    try? await localAPI.setAudioHostEnabled(false)
                }
            )
            guard outcome == .started else {
                backgroundStandby.resumeAfterCall()
                return
            }
            if currentCallTransport == nil {
                let transport: CallTransport
                switch localAPI.route {
                case .moduleLocal: transport = .moduleLocal
                case .vowlan: transport = .vowlan
                }
                lockLocalTransport(transport, api: localAPI, pcmRoute: pcmRoute)
            }
        } catch {
            audio.deactivate()
            if let localAPI = reachableLocalAPI {
                try? await localAPI.setAudioHostEnabled(false)
            }
            backgroundStandby.resumeAfterCall()
            errorMessage = "Unable to register call audio: \(error.localizedDescription)"
            return
        }
    }

    func readyVoWLANRoute() async -> (AirSIMAPI, PCMRoute)? {
        vowlan.startBrowsing()
        await vowlan.probeNow()
        if vowlan.availability.isReady(),
           let endpoint = vowlan.availability.endpoint,
           permitsVoWLANEndpoint(endpoint),
           let credential = VoWLANCredentialStore.load() {
            return (
                AirSIMAPI(route: .vowlan(endpoint: endpoint, credential: credential)),
                .vowlan(endpoint: endpoint, credential: credential)
            )
        }
        // PushKit may resume in the background before the Bonjour browser. If the latest successful poll came from VoWLAN,
        // reuse that authenticated endpoint; never mistake the generic isOnline flag for USB ECM.
        guard isOnline, !isReconnecting, let cached = lastSuccessfulLocalAPI,
              case let .vowlan(endpoint, credential) = cached.route,
              permitsVoWLANEndpoint(endpoint) else { return nil }
        return (cached, .vowlan(endpoint: endpoint, credential: credential))
    }

    private func lockLocalTransport(
        _ transport: CallTransport,
        api: AirSIMAPI,
        pcmRoute: PCMRoute
    ) {
        currentCallTransport = transport
        currentLocalAPI = api
        currentPCMRoute = pcmRoute
        lockedCallTransport = LockedCallTransport(
            transport: transport,
            generation: callLifecycleSnapshot.generation
        )
        // Cancel any long-poll still bound to the legacy USB route so the active state returns immediately from VoWLAN.
        restartPolling()
        Task {
            await AgentVerboseTraceRecorder.shared.recordEvent(
                source: "ios", category: "call_transport", phase: "locked",
                title: transport == .vowlan ? "This Call Uses VoWLAN" : "This Call Uses Local Module Connection",
                fields: ["generation": String(callLifecycleSnapshot.generation)]
            )
        }
    }

    private func clearLockedTransport() {
        currentCallTransport = nil
        currentLocalAPI = nil
        currentPCMRoute = nil
        lockedCallTransport = nil
    }

    private func endVoWLANCallAfterPathLoss() async {
        guard currentCallTransport == .vowlan else { return }
        let localAPI = currentLocalAPI
        audio.deactivate()
        try? await localAPI?.hangupCall(callID: activeCall?.id)
        errorMessage = "VoWLAN disconnected. This call has ended; the next call will automatically use cloud."
        await AgentVerboseTraceRecorder.shared.recordEvent(
            source: "ios", category: "call_transport", phase: "ended",
            title: "hotspot_lost_no_midcall_handover",
            detail: "VoWLAN network lost. Ended this call without transferring it to cloud.",
            fields: ["generation": String(lockedCallTransport?.generation ?? 0)],
            isFailure: true
        )
        try? await callKit.endCurrentCall()
    }

    /// Allows only standard telephony characters to prevent accidental AT control characters from reaching the module Agent.
    private static func validatedNumber(_ input: String) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = CharacterSet(charactersIn: "+*#0123456789")
        guard trimmed.count <= 82,
              trimmed.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return "" }
        return trimmed
    }

    private static func remoteCallRecord(
        from incoming: IncomingVoIPCall,
        state: String,
        startedAt: Date = Date()
    ) -> CallRecord {
        CallRecord(
            id: incoming.callID,
            index: 0,
            direction: "incoming",
            state: state,
            number: incoming.number,
            startedAt: startedAt,
            updatedAt: Date(),
            endedAt: nil,
            missed: false
        )
    }

    private func updateRemoteCallState(_ state: String) {
        guard let incoming = callKit.currentIncomingPush else { return }
        remoteCall = Self.remoteCallRecord(
            from: incoming,
            state: state,
            startedAt: remoteCall?.startedAt ?? Date()
        )
    }

    @discardableResult
    private func applyCallLifecycle(_ event: CallLifecycleEvent) -> Bool {
        guard callLifecycleStore.apply(event) else { return false }
        callLifecycleSnapshot = callLifecycleStore.snapshot
        if event.state == .ending || event.state.isTerminal {
            recordings.finishCall(event.callID)
            callPresentationSurface = nil
            pendingOutgoingCall = nil
            audio.stopCallTone()
            WatchCallCoordinator.shared.publish(
                call: nil, previous: activeCall ?? remoteCall, callerName: nil
            )
            Task { @MainActor [weak self] in
                guard let self else { return }
                let current = self.lifecycleRecord(from: self.activeCall ?? self.remoteCall)
                await self.liveActivity.update(
                    call: current,
                    callerName: current.map { self.contacts.displayName(for: $0.number) },
                    moduleOnline: self.isOnline,
                    cloudOnline: CloudModePreference.isEnabled() && self.cloudAgentStatus?.cloudOnline == true,
                    transport: self.liveActivityTransport,
                    radio: self.modemStatus,
                    agent: self.liveActivityAgentSnapshot,
                    appIsActive: self.appIsActive
                )
            }
        }
        return true
    }

    private func applyCurrentCallIntent(_ state: CallLifecycleState, source: CallLifecycleSource) {
        guard let callID = callLifecycleSnapshot.callID,
              let callUUID = callLifecycleSnapshot.callUUID,
              callLifecycleSnapshot.generation > 0 else { return }
        _ = applyCallLifecycle(CallLifecycleEvent(
            callID: callID,
            callUUID: callUUID,
            generation: callLifecycleSnapshot.generation,
            state: state,
            source: source,
            timestamp: Date(),
            traceID: "app-\(UUID().uuidString.lowercased())",
            failure: nil
        ))
    }

    @discardableResult
    private func applyAgentCallRecord(
        _ call: CallRecord,
        forcedState: CallLifecycleState? = nil
    ) -> Bool {
        let incoming = callKit.currentIncomingPush
        let sameSnapshot = callLifecycleSnapshot.callID == call.id
        let callUUID = (incoming?.callID == call.id ? incoming?.uuid : nil)
            ?? (sameSnapshot ? callLifecycleSnapshot.callUUID : nil)
            ?? callKit.watchCallUUID(for: call.id)
            ?? UUID()
        let generation = (incoming?.callID == call.id ? incoming?.generation : nil)
            ?? (sameSnapshot ? callLifecycleSnapshot.generation : nil)
            ?? max(1, callLifecycleSnapshot.generation &+ 1)
        let state = forcedState ?? Self.lifecycleState(for: call.state)
        return applyCallLifecycle(CallLifecycleEvent(
            callID: call.id,
            callUUID: callUUID,
            generation: generation,
            state: state,
            source: .agent,
            timestamp: call.updatedAt,
            traceID: "agent-poll-\(call.id)-\(generation)",
            failure: state == .failed ? "Agent reported call failure" : nil
        ))
    }

    private func lifecycleRecord(from record: CallRecord?) -> CallRecord? {
        guard let record,
              callLifecycleSnapshot.callID == record.id,
              callLifecycleSnapshot.state.representsCall,
              !callLifecycleStore.suppressesPresentation(callID: record.id) else { return nil }
        return CallRecord(
            id: record.id,
            index: record.index,
            direction: record.direction,
            state: callLifecycleSnapshot.state.callRecordState,
            number: record.number,
            startedAt: record.startedAt,
            updatedAt: callLifecycleSnapshot.timestamp ?? record.updatedAt,
            endedAt: nil,
            missed: record.missed
        )
    }

    private static func lifecycleState(for agentState: String) -> CallLifecycleState {
        switch agentState {
        case "incoming", "waiting": return .ringing
        case "dialing", "alerting": return .connecting
        case "active", "held": return .active
        case "ending": return .ending
        case "ended": return .ended
        default: return .connecting
        }
    }
}

protocol OutgoingCallServicing: Sendable {
    func warmAudioHost() async throws
    func setAudioHostEnabled(_ enabled: Bool) async throws
    func dial(number: String) async throws
}

extension AirSIMAPI: OutgoingCallServicing {}

protocol CallAudioRegistrationServicing: Sendable {
    func setAudioHostEnabled(_ enabled: Bool) async throws
    func callStatus() async throws -> CallStatus
}

extension AirSIMAPI: CallAudioRegistrationServicing {}

enum CallAudioRegistrationOutcome: Equatable, Sendable {
    case registered
    case callNoLongerActive
    case temporarilyUnavailable
}

enum CallAudioRegistrationCoordinator {
    static func register(
        service: any CallAudioRegistrationServicing,
        retryDelay: Duration = .milliseconds(250)
    ) async throws -> CallAudioRegistrationOutcome {
        do {
            try await service.setAudioHostEnabled(true)
            return .registered
        } catch APIError.http(409, _) {
            // Call events and media registration are separate requests. If an older Agent finishes a CLCC refresh in between,
            // re-read status so a brief race is not treated as a fatal dial error.
            let latest = try await service.callStatus()
            guard latest.active?.state == "active" else {
                return .callNoLongerActive
            }
            if retryDelay > .zero {
                try await Task.sleep(for: retryDelay)
            }
            do {
                try await service.setAudioHostEnabled(true)
                return .registered
            } catch APIError.http(409, _) {
                // In 0.3.39, DSCI and CLCC can briefly interleave at the moment a call connects. Keep the CallKit call alive
                // and let the next event poll retry rather than surfacing unready media as a dial failure.
                return .temporarilyUnavailable
            }
        }
    }
}

enum LocalCallAudioStartupOutcome: Equatable, Sendable {
    case started
    case phoneAudioUnavailable
    case callNoLongerActive
    case temporarilyUnavailable
}

@MainActor
enum LocalCallAudioStartupCoordinator {
    static func start(
        activatePhoneAudio: () async -> Bool,
        registerAgentAudio: () async throws -> CallAudioRegistrationOutcome,
        rollbackPhoneAudio: () async -> Void
    ) async rethrows -> LocalCallAudioStartupOutcome {
        guard await activatePhoneAudio() else { return .phoneAudioUnavailable }
        do {
            switch try await registerAgentAudio() {
            case .registered:
                return .started
            case .callNoLongerActive:
                await rollbackPhoneAudio()
                return .callNoLongerActive
            case .temporarilyUnavailable:
                await rollbackPhoneAudio()
                return .temporarilyUnavailable
            }
        } catch {
            await rollbackPhoneAudio()
            throw error
        }
    }
}

enum OutgoingCommandAvailability {
    static func isAvailable(
        mode: AirSIMConnectionMode = .automatic,
        localControlReachable: Bool,
        cloudModeEnabled: Bool,
        cloudHeartbeatFresh: Bool
    ) -> Bool {
        DialRouteSelector.preferred(
            mode: mode,
            vowlanReady: localControlReachable,
            cloudReady: cloudModeEnabled && cloudHeartbeatFresh
        ) != nil
    }
}

enum OutgoingCallCoordinator {
    static func start(number: String, service: any OutgoingCallServicing) async throws {
        try? await service.warmAudioHost()
        try await service.dial(number: number)
    }
}

enum OutgoingCallRouteResult<CloudResult: Sendable>: Sendable {
    case vowlan
    case cloud(CloudResult)
}

extension OutgoingCallRouteResult: Equatable where CloudResult: Equatable {}

enum OutgoingCallFallbackPolicy {
    static func permitsCloudFallback(after error: Error, cloudModeEnabled: Bool) -> Bool {
        guard cloudModeEnabled, !(error is CancellationError) else { return false }
        // Receiving an Agent HTTP response means the command reached the execution boundary. Dialing is non-idempotent,
        // so explicit rejections or domain errors must never be replayed via the Relay.
        if error is APIError { return false }
        return true
    }
}

@MainActor
enum OutgoingCallRouteCoordinator {
    static func start<CloudResult: Sendable>(
        number: String,
        vowlanService: (any OutgoingCallServicing)?,
        cloudModeEnabled: Bool,
        isCurrent: () -> Bool = { true },
        discardCloud: (CloudResult) async -> Void = { _ in },
        startCloud: () async throws -> CloudResult
    ) async throws -> OutgoingCallRouteResult<CloudResult> {
        guard !Task.isCancelled, isCurrent() else { throw CancellationError() }
        if let vowlanService {
            do {
                try await OutgoingCallCoordinator.start(number: number, service: vowlanService)
                guard !Task.isCancelled, isCurrent() else { throw CancellationError() }
                return .vowlan
            } catch {
                guard !Task.isCancelled, isCurrent() else { throw CancellationError() }
                guard OutgoingCallFallbackPolicy.permitsCloudFallback(
                    after: error,
                    cloudModeEnabled: cloudModeEnabled
                ) else {
                    throw error
                }
            }
        } else if !cloudModeEnabled {
            throw CloudCommandError.cloudModeDisabled
        }

        guard !Task.isCancelled, isCurrent() else { throw CancellationError() }
        let cloud = try await startCloud()
        guard !Task.isCancelled, isCurrent() else {
            await discardCloud(cloud)
            throw CancellationError()
        }
        return .cloud(cloud)
    }
}

enum AgentPollingRouteSelector {
    static func select<Service>(
        primary: Service,
        lockedLocal: Service?,
        transport: CallTransport?
    ) -> Service {
        if transport == .vowlan, let lockedLocal { return lockedLocal }
        return primary
    }
}

enum CallKitAudioPreparationCoordinator {
    static func prepare(
        suspendStandby: () -> Void,
        configureCallAudio: () throws -> Void,
        resumeStandby: () -> Void
    ) throws {
        suspendStandby()
        do {
            try configureCallAudio()
        } catch {
            resumeStandby()
            throw error
        }
    }
}

extension AppModel: CallKitActionHandling {
    func callKitPrepareAudioSession() throws {
        try CallKitAudioPreparationCoordinator.prepare(
            suspendStandby: { backgroundStandby.suspendForCall() },
            configureCallAudio: { try audio.prepareForCallKit() },
            resumeStandby: { backgroundStandby.resumeAfterCall() }
        )
    }

    func callKitStart(number: String) async throws {
        let attempt = UUID()
        outgoingAttemptID = attempt
        beginCallTransitionProtection()
        if callPresentationSurface == nil { callPresentationSurface = .system }
        audio.stopCallTone()
        backgroundStandby.suspendForCall()
        do {
            let selectedMode = ConnectionModePreference.selected()
            let runtimePolicy = ConnectionModeRuntimePolicy(mode: selectedMode)
            let vowlanRoute = runtimePolicy.startsVoWLAN ? await readyVoWLANRoute() : nil
            guard outgoingAttemptID == attempt, !Task.isCancelled else { return }
            let cloudModeEnabled = CloudModePreference.isEnabled()
            let routeResult = try await OutgoingCallRouteCoordinator.start(
                number: number,
                vowlanService: vowlanRoute?.0,
                cloudModeEnabled: cloudModeEnabled,
                isCurrent: { self.outgoingAttemptID == attempt },
                discardCloud: { (outgoing: IncomingVoIPCall) in
                    self.callLifecycleStore.retire(callID: outgoing.callID, uuid: outgoing.uuid)
                    IPhoneCloudCallSession.shared.endUnadoptedOutgoing(outgoing)
                }
            ) {
                // Dialing is an explicit event: check once immediately before cloud routing.
                let status = try await VoIPPushController.shared.fetchCloudAgentStatus()
                guard self.outgoingAttemptID == attempt, !Task.isCancelled else { throw CancellationError() }
                self.cloudAgentStatus = status
                self.cloudAgentDirectory = status
                self.lastCloudStatusRefresh = Date()
                guard status.cloudOnline,
                      self.boundAgentID == nil || status.activeAgentID == self.boundAgentID
                else { throw CloudCommandError.unavailable }
                return try await VoIPPushController.shared.startCloudOutgoingCall(number: number)
            }

            switch routeResult {
            case .vowlan:
                guard let (vowlanAPI, pcmRoute) = vowlanRoute else {
                    throw CloudCommandError.unavailable
                }
                lockLocalTransport(.vowlan, api: vowlanAPI, pcmRoute: pcmRoute)
            case let .cloud(outgoing):
                guard applyCallLifecycle(CallLifecycleEvent(
                    callID: outgoing.callID, callUUID: outgoing.uuid,
                    generation: outgoing.generation, state: .connecting, source: .callKit,
                    timestamp: Date(), traceID: "callkit-start-\(outgoing.uuid.uuidString.lowercased())",
                    failure: nil
                )) else {
                    IPhoneCloudCallSession.shared.endUnadoptedOutgoing(outgoing)
                    return
                }
                try await IPhoneCloudCallSession.shared.answer(outgoing)
                guard outgoingAttemptID == attempt, !Task.isCancelled,
                      !callLifecycleStore.suppressesPresentation(callID: outgoing.callID) else {
                    if IPhoneCloudCallSession.shared.call?.uuid == outgoing.uuid {
                        await IPhoneCloudCallSession.shared.end()
                    }
                    return
                }
                currentCallTransport = .cloud
                lockedCallTransport = LockedCallTransport(
                    transport: .cloud, generation: callLifecycleSnapshot.generation
                )
                remoteCall = CallRecord(
                    id: outgoing.callID, index: 0, direction: "outgoing", state: "dialing",
                    number: number, startedAt: Date(), updatedAt: Date(), endedAt: nil, missed: false
                )
                pendingOutgoingCall = nil
                await startCallAudioIfReady()
            }
        } catch {
            guard outgoingAttemptID == attempt else { return }
            backgroundStandby.resumeAfterCall()
            throw error
        }
    }

    func callKitAnswer(origin: CallAnswerOrigin) async throws {
        beginCallTransitionProtection()
        audio.stopCallTone()
        backgroundStandby.suspendForCall()
        audio.resetSpeakerPreferenceForNewCall()
        callPresentationSurface = origin == .app ? .app : .system
        applyCurrentCallIntent(.connecting, source: origin == .app ? .app : .callKit)
        if origin == .system { _ = IncomingCallPresentationRequest.consume() }
        do {
            let pushedCall = callKit.currentIncomingPush
            if let pushedCall, pushedCall.isVirtual {
                try VirtualCallTTSController.shared.prepare(pushedCall)
                isVirtualCallTTSPrepared = true
                clearLockedTransport()
                updateRemoteCallState("active")
                return
            }
            let cloudMediaEnabled = CloudModePreference.isEnabled()
            let vowlanRoute = await readyVoWLANRoute()
            let moduleLocalReachable = false
            let transport = CallTransportPolicy.preferred(
                vowlanReady: vowlanRoute != nil,
                moduleLocalReachable: moduleLocalReachable,
                cloudMediaAvailable: pushedCall?.authenticatedMediaURL != nil,
                cloudMediaEnabled: cloudMediaEnabled
            )
            switch transport {
            case .vowlan:
                guard let (vowlanAPI, pcmRoute) = vowlanRoute else {
                    throw CallKitBridgeError.noReachableTransport
                }
                try audio.prepareForCallKit()
                try await vowlanAPI.answerCall(callID: activeCall?.id)
                lockLocalTransport(.vowlan, api: vowlanAPI, pcmRoute: pcmRoute)
            case .moduleLocal:
                throw CallKitBridgeError.noReachableTransport
            case .cloud:
                guard let pushedCall else { throw CallKitBridgeError.noReachableTransport }
                try await IPhoneCloudCallSession.shared.answer(pushedCall)
                currentLocalAPI = nil
                currentPCMRoute = nil
                currentCallTransport = .cloud
                lockedCallTransport = LockedCallTransport(
                    transport: .cloud, generation: callLifecycleSnapshot.generation
                )
                await startCallAudioIfReady()
            case nil:
                if !moduleLocalReachable,
                   !cloudMediaEnabled,
                   pushedCall?.authenticatedMediaURL != nil {
                    throw CallKitBridgeError.cloudMediaDisabled
                }
                throw CallKitBridgeError.noReachableTransport
            }
            await CallAnswerCompletionCoordinator.complete(
                transport: currentCallTransport,
                confirmActive: {
                    self.applyCurrentCallIntent(
                        .active,
                        source: origin == .app ? .app : .callKit
                    )
                    self.updateRemoteCallState("active")
                },
                startAudio: { await self.startCallAudioIfReady() }
            )
        } catch {
            backgroundStandby.resumeAfterCall()
            throw error
        }
    }

    func callKitEnd() async throws {
        outgoingAttemptID = UUID()
        beginCallTransitionProtection()
        audio.stopCallTone()
        let pushedCall = callKit.currentIncomingPush
        let endRoute = CallKitEndDecision.route(
            transport: currentCallTransport,
            cloudSessionPrepared: IPhoneCloudCallSession.shared.isPrepared,
            hasIncomingPush: pushedCall != nil,
            systemCallAnswered: callKit.currentCallIsAnswered,
            activeIncomingRinging: activeCall?.direction == "incoming"
                && ["incoming", "waiting"].contains(activeCall?.state ?? "")
        )
        applyCurrentCallIntent(.ending, source: .callKit)
        if VirtualCallTTSController.shared.isPrepared || callKit.currentIncomingPush?.isVirtual == true {
            VirtualCallTTSController.shared.stop()
            isVirtualCallTTSPrepared = false
            clearLockedTransport()
            backgroundStandby.resumeAfterCall()
            return
        }
        if endRoute == .cloudReject, let pushedCall {
            try await IPhoneCloudCallSession.shared.reject(pushedCall)
            clearLockedTransport()
            backgroundStandby.resumeAfterCall()
            return
        }
        if endRoute == .cloudEnd {
            await IPhoneCloudCallSession.shared.end()
            clearLockedTransport()
            backgroundStandby.resumeAfterCall()
            return
        }
        if currentCallTransport == .vowlan,
           case .unavailable = vowlan.availability {
            // The Samsung Agent ends its call directly via Telecom when the hotspot interface disappears; fulfill the
            // CallKit transaction immediately here so a disconnected control socket cannot stall the system UI.
            clearLockedTransport()
            backgroundStandby.resumeAfterCall()
            return
        }
        if endRoute == .localReject {
            do {
                guard let localAPI = localCallControlAPI else {
                    throw CallKitBridgeError.noReachableTransport
                }
                _ = try await localAPI.rejectCall(callID: activeCall?.id)
            } catch {
                guard let pushedCall else { throw error }
                try await IPhoneCloudCallSession.shared.reject(pushedCall)
            }
        } else {
            guard let localAPI = localCallControlAPI else {
                throw CallKitBridgeError.noReachableTransport
            }
            try await localAPI.hangupCall(callID: activeCall?.id)
        }
    }

    func callKitSetMuted(_ muted: Bool) async {
        isMuted = muted
        if VirtualCallTTSController.shared.isPrepared {
            VirtualCallTTSController.shared.setMuted(muted)
            errorMessage = nil
            return
        }
        audio.setMuted(muted)
        IPhoneCloudCallSession.shared.setMuted(muted)
        // CallKit mute actions apply directly to the local PCM encoder; module AT+CMUT failures must not affect bidirectional audio.
        if currentCallTransport != .cloud {
            if let localAPI = reachableLocalAPI {
                Task { try? await localAPI.setAudioMuted(muted) }
            }
        }
        errorMessage = nil
    }

    func callKitPlayDTMF(_ digits: String) async throws {
        if VirtualCallTTSController.shared.isPrepared { return }
        for digit in digits where "0123456789*#".contains(digit) {
            if currentCallTransport == .cloud {
                try await VoIPPushController.shared.sendCloudDTMF(String(digit))
            } else {
                guard let localAPI = reachableLocalAPI else {
                    throw CallKitBridgeError.noReachableTransport
                }
                try await localAPI.sendDTMF(String(digit))
            }
        }
    }

    func callKitAudioSessionDidActivate() async {
        if VirtualCallTTSController.shared.isPrepared {
            VirtualCallTTSController.shared.start()
            return
        }
        await startCallAudioIfReady()
    }

    func callKitAudioSessionDidDeactivate() {
        beginCallTransitionProtection()
        if VirtualCallTTSController.shared.isPrepared {
            VirtualCallTTSController.shared.stop()
            isVirtualCallTTSPrepared = false
            backgroundStandby.resumeAfterCall()
            return
        }
        if currentCallTransport == .cloud || IPhoneCloudCallSession.shared.isPrepared {
            IPhoneCloudCallSession.shared.stopAudio()
            return
        }
        audio.deactivate()
        audioWarmupCallID = nil
        backgroundStandby.resumeAfterCall()
    }

    func callKitProviderDidReset() async {
        beginCallTransitionProtection()
        // CXProvider reset only means the system call UI was invalidated, never that the user hung up the real module call.
        // Clean up local audio and let the next status sync recover automatically in in-app call mode.
        let wasVirtual = VirtualCallTTSController.shared.isPrepared
        if wasVirtual {
            VirtualCallTTSController.shared.stop()
            isVirtualCallTTSPrepared = false
        } else if currentCallTransport == .cloud || IPhoneCloudCallSession.shared.isPrepared {
            IPhoneCloudCallSession.shared.stopAudio()
        } else {
            audio.deactivate()
        }
        if !callLifecycleSnapshot.state.representsCall { backgroundStandby.resumeAfterCall() }
    }

    func callKitDidFail(_ message: String) {
        outgoingAttemptID = UUID()
        errorMessage = message
        pendingOutgoingCall = nil
        guard callLifecycleSnapshot.state == .ending,
              let callID = callLifecycleSnapshot.callID,
              let callUUID = callLifecycleSnapshot.callUUID else { return }
        _ = applyCallLifecycle(CallLifecycleEvent(
            callID: callID, callUUID: callUUID,
            generation: callLifecycleSnapshot.generation,
            state: .failed, source: .callKit, timestamp: Date(),
            traceID: "callkit-failure-\(UUID().uuidString.lowercased())",
            failure: message
        ))
    }

    func callKitDidReceiveIncoming(_ call: IncomingVoIPCall) {
        guard !callLifecycleStore.suppressesPresentation(callID: call.callID) else { return }
        vowlan.startBrowsing()
        Task { await vowlan.probeNow() }
        guard applyCallLifecycle(CallLifecycleEvent(
            callID: call.callID, callUUID: call.uuid, generation: call.generation,
            state: .ringing, source: .relay, timestamp: Date(),
            traceID: "pushkit-\(call.uuid.uuidString.lowercased())", failure: nil
        )) else { return }
        remoteCall = Self.remoteCallRecord(from: call, state: "incoming")
        // Background PushKit incoming calls are handled by the system UI; prepare the in-app incoming call view only when the app is already in the foreground.
        callPresentationSurface = appIsActive ? .app : .system
    }

    func callKitCallDidEnd() {
        recordings.finishCall(callLifecycleSnapshot.callID)
        outgoingAttemptID = UUID()
        // Remote hangup, system call screen hangup, and provider-initiated termination all pass through here.
        // The Agent is the sole owner of call-end media teardown; the app no longer closes the Audio Host redundantly.
        beginCallTransitionProtection()
        // Local CallKit UI dismissal does not mean the module has hung up; final ended/failed state may only advance from Agent/Relay receipts.
        applyCurrentCallIntent(.ending, source: .callKit)
        remoteCall = nil
        pendingOutgoingCall = nil
        callPresentationSurface = nil
        clearLockedTransport()
        cloudCallAudioState = .idle
        IPhoneCloudCallSession.shared.stop()
        VirtualCallTTSController.shared.stop()
        isVirtualCallTTSPrepared = false
        backgroundStandby.resumeAfterCall()
    }
}

private enum ModuleSetupError: LocalizedError {
    case notReady(String)
    case timeout

    var errorDescription: String? {
        switch self {
        case let .notReady(message): return message
        case .timeout: return "Module did not reconnect after restarting. Reconnect the USB cable."
        }
    }
}
