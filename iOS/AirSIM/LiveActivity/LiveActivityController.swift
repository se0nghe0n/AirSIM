import ActivityKit
import UIKit

enum LiveActivityCreationPolicy {
    static func pushType(localModeEnabled: Bool) -> PushType? {
        localModeEnabled ? nil : .token
    }

    static func shouldCreate(appIsActive: Bool, hasActivity: Bool) -> Bool {
        !hasActivity && appIsActive
    }
}

struct LiveActivityAgentSnapshot: Equatable {
    let deviceName: String?
    let phoneNumber: String?
    let agentKind: String?
    let pairedAgentCount: Int
    let vowlanOnline: Bool
    let cloudOnline: Bool

    init(agent: AndroidAgentPresentation?, pairedAgentCount: Int) {
        deviceName = agent?.deviceName
        phoneNumber = agent?.phoneNumber
        agentKind = agent?.agentKind
        self.pairedAgentCount = pairedAgentCount
        vowlanOnline = agent?.vowlanOnline == true
        cloudOnline = agent?.cloudOnline == true
    }
}

enum LiveActivityStateBuilder {
    static func make(
        call: CallRecord?,
        callerName: String?,
        moduleOnline: Bool,
        cloudOnline: Bool = false,
        transport: AirSIMCallActivityAttributes.ContentState.Transport? = nil,
        radio: ModemStatus?,
        agent: LiveActivityAgentSnapshot? = nil,
        idleStartedAt: Date
    ) -> AirSIMCallActivityAttributes.ContentState {
        // Show offline only when both local control and Relay heartbeat are unreachable; use a dedicated
        // cloud standby state while the cloud heartbeat is fresh to avoid misreporting a VoWLAN disconnect as full module offline.
        guard moduleOnline || cloudOnline else {
            return .init(
                callID: "",
                number: "",
                displayName: "Module Offline",
                phase: .offline,
                startedAt: idleStartedAt,
                agentDeviceName: agent?.deviceName,
                agentPhoneNumber: agent?.phoneNumber,
                agentKind: agent?.agentKind,
                pairedAgentCount: agent?.pairedAgentCount,
                vowlanOnline: agent?.vowlanOnline,
                cloudOnline: agent?.cloudOnline
            )
        }
        guard let call else {
            let cloudOnly = cloudOnline && !moduleOnline
            return .init(
                callID: "",
                number: "",
                displayName: cloudOnly ? "Internet Relay Connected" : "Waiting for Incoming Calls",
                phase: cloudOnly ? .cloudStandby : .standby,
                startedAt: idleStartedAt,
                transport: cloudOnly ? .cloud : transport,
                signalDBM: radio?.signalDBM,
                operatorName: radio?.operatorName,
                networkMode: radio?.networkMode,
                radioBand: radio?.radioBand,
                agentDeviceName: agent?.deviceName,
                agentPhoneNumber: agent?.phoneNumber,
                agentKind: agent?.agentKind,
                pairedAgentCount: agent?.pairedAgentCount,
                vowlanOnline: agent?.vowlanOnline,
                cloudOnline: agent?.cloudOnline
            )
        }

        let phase: AirSIMCallActivityAttributes.ContentState.Phase
        if call.direction == "incoming", ["incoming", "waiting"].contains(call.state) {
            phase = .incoming
        } else if call.state == "held" {
            phase = .held
        } else {
            phase = .active
        }
        let number = call.number?.isEmpty == false ? call.number! : "Unknown Number"
        return .init(
            callID: call.id,
            number: number,
            displayName: callerName?.isEmpty == false ? callerName! : number,
            phase: phase,
            startedAt: call.startedAt,
            transport: transport,
            agentDeviceName: agent?.deviceName,
            agentPhoneNumber: agent?.phoneNumber,
            agentKind: agent?.agentKind,
            pairedAgentCount: agent?.pairedAgentCount,
            vowlanOnline: agent?.vowlanOnline,
            cloudOnline: agent?.cloudOnline
        )
    }
}

/// The main app pre-starts and continuously syncs the Dynamic Island; background execution can only update an existing Live Activity.
@MainActor
final class LiveActivityController {
    private var activity: Activity<AirSIMCallActivityAttributes>?
    private var lastState: AirSIMCallActivityAttributes.ContentState?
    private let idleStartedAt = Date()
    private var enabled = true
    private var visibilityRevision = 0

    /// Immediately ends system activities when turned off by the user; recreated on demand by the next module status sync when re-enabled.
    func setEnabled(_ enabled: Bool) {
        self.enabled = enabled
        visibilityRevision &+= 1
        if !enabled {
            let revision = visibilityRevision
            Task { @MainActor [weak self] in
                guard let self, !self.enabled,
                      self.visibilityRevision == revision else { return }
                await self.stop()
            }
        }
    }

    func update(
        call: CallRecord?,
        callerName: String?,
        moduleOnline: Bool,
        cloudOnline: Bool = false,
        transport: AirSIMCallActivityAttributes.ContentState.Transport? = nil,
        radio: ModemStatus?,
        agent: LiveActivityAgentSnapshot? = nil,
        appIsActive: Bool
    ) async {
        guard enabled, UIDevice.current.userInterfaceIdiom == .phone else { return }
        resolveExistingActivity()
#if DEBUG
        let requestedPhase = call != nil ? "call" : (moduleOnline ? "standby" : (cloudOnline ? "cloud_standby" : "offline"))
        print("[AirSIM LiveActivity] requestedPhase=\(requestedPhase) appActive=\(appIsActive) authorized=\(ActivityAuthorizationInfo().areActivitiesEnabled) existingCount=\(Activity<AirSIMCallActivityAttributes>.activities.count) selected=\(activity?.id ?? "none")")
#endif

        if activity == nil {
            // iOS does not guarantee local activity creation in the background. Allow creation while offline in the foreground
            // to replace orphaned activities still displayed by the system after an app upgrade when Activity.activities no longer returns handles.
            guard LiveActivityCreationPolicy.shouldCreate(appIsActive: appIsActive, hasActivity: false),
                  ActivityAuthorizationInfo().areActivitiesEnabled else { return }
            do {
                let initialState = LiveActivityStateBuilder.make(
                    call: call,
                    callerName: callerName,
                    moduleOnline: moduleOnline,
                    cloudOnline: cloudOnline,
                    transport: transport,
                    radio: radio,
                    agent: agent,
                    idleStartedAt: idleStartedAt
                )
                activity = try Activity.request(
                    attributes: AirSIMCallActivityAttributes(moduleName: "AirSIM"),
                    content: ActivityContent(
                        state: initialState,
                        staleDate: nil
                    ),
                    pushType: LiveActivityCreationPolicy.pushType(
                        localModeEnabled: LocalModePreference.isEnabled()
                    )
                )
                if let activity {
                    VoIPPushController.shared.observeLiveActivity(activity)
                }
#if DEBUG
                print("[AirSIM LiveActivity] created id=\(activity?.id ?? "none") phase=\(initialState.phase.rawValue)")
#endif
                lastState = initialState
            } catch {
#if DEBUG
                print("[AirSIM LiveActivity] create_failed error=\(String(describing: error))")
#endif
                return
            }
        } else if let activity {
            let nextState = LiveActivityStateBuilder.make(
                call: call,
                callerName: callerName,
                moduleOnline: moduleOnline,
                cloudOnline: cloudOnline,
                transport: transport,
                radio: radio,
                agent: agent,
                idleStartedAt: idleStartedAt
            )
            // Online/offline state is determined by actual module requests; do not use ActivityKit stale as a connectivity probe.
            guard nextState != lastState else { return }
            await activity.update(
                ActivityContent(
                    state: nextState,
                    staleDate: nil
                )
            )
#if DEBUG
            print("[AirSIM LiveActivity] updated id=\(activity.id) phase=\(nextState.phase.rawValue)")
#endif
            lastState = nextState
        }
    }

    func markOffline(agent: LiveActivityAgentSnapshot? = nil, appIsActive: Bool) async {
        await update(
            call: nil,
            callerName: nil,
            moduleOnline: false,
            radio: nil,
            agent: agent,
            appIsActive: appIsActive
        )
    }

    func stop() async {
        for activity in Activity<AirSIMCallActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        activity = nil
        lastState = nil
    }

    private func resolveExistingActivity() {
        guard activity == nil else { return }
        let existing = Activity<AirSIMCallActivityAttributes>.activities
        activity = existing.first
        if let activity {
            VoIPPushController.shared.observeLiveActivity(activity)
        }
#if DEBUG
        let summary = existing.map { "\($0.id):\($0.content.state.phase.rawValue)" }.joined(separator: ",")
        print("[AirSIM LiveActivity] resolved count=\(existing.count) activities=[\(summary)]")
#endif
        lastState = activity?.content.state
    }

}
