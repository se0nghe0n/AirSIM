import ComposableArchitecture
import Foundation

@Reducer
struct SettingsFeature {
    @ObservableState
    struct State: Equatable {
        @SharedReader fileprivate var snapshot: AirSIMSnapshot
        var pairing = PairingFeature.State()
        var mode: AirSIMConnectionMode
        var appearance: AppAppearance
        var relayURL: String
        var lastObservedMode: AirSIMConnectionMode
        var lastObservedAppearance: AppAppearance
        var lastObservedRelayURL: String
        var lastObservedLiveActivity: Bool
        var relayHasDraft = false
        var liveActivityEnabled: Bool
        var report: CloudSelfTestReport?
        var selfTestRunning = false
        var selfTestCompleted = false
        var message: String?
        var deletingDevice = false
        var pairingFromOnboarding = false

        init(snapshot: SharedReader<AirSIMSnapshot>) {
            _snapshot = snapshot
            let saved = snapshot.wrappedValue
            mode = saved.preferenceMode
            appearance = saved.preferenceAppearance
            relayURL = saved.preferenceRelayURL
            liveActivityEnabled = saved.preferenceLiveActivity
            lastObservedMode = saved.preferenceMode
            lastObservedAppearance = saved.preferenceAppearance
            lastObservedRelayURL = saved.preferenceRelayURL
            lastObservedLiveActivity = saved.preferenceLiveActivity
        }

        mutating func reconcile(with value: AirSIMSnapshot) {
            if value.preferenceMode != lastObservedMode {
                mode = value.preferenceMode
                lastObservedMode = value.preferenceMode
            }
            if value.preferenceAppearance != lastObservedAppearance {
                appearance = value.preferenceAppearance
                lastObservedAppearance = value.preferenceAppearance
            }
            if value.preferenceLiveActivity != lastObservedLiveActivity {
                liveActivityEnabled = value.preferenceLiveActivity
                lastObservedLiveActivity = value.preferenceLiveActivity
            }
            if value.preferenceRelayURL != lastObservedRelayURL {
                if !relayHasDraft {
                    relayURL = value.preferenceRelayURL
                }
                lastObservedRelayURL = value.preferenceRelayURL
            }
            if value.preferenceRelayURL == relayURL {
                relayHasDraft = false
            }
        }

        var modeUsesCloud: Bool { ConnectionModeRuntimePolicy(mode: mode).startsCloud }
        var modeTitle: String { String(localized: mode.title) }
        var modeDetail: String { String(localized: mode.detail) }

        var modeIcon: String {
            switch mode {
            case .vowlan:
                "wifi"
            case .cloud:
                "cloud"
            case .automatic:
                "arrow.triangle.branch"
            }
        }

        var connection: ConnectionModePresentation { snapshot.connectionModePresentation }
        var vowlanStatus: String { VoWLANStatusCopy.text(for: snapshot.vowlan) }

        var cloudRelayStatus: String {
            guard modeUsesCloud else { return "Disabled in current mode" }
            return snapshot.cloudAgentStatus?.cloudOnline == true ? "Agent Online" : "Unreachable"
        }

        var connectionMessage: String? {
            guard let message = snapshot.connectionMessage, !message.isEmpty else { return nil }
            return message
        }

        var devices: [PairedDeviceRow] { snapshot.pairedDeviceHistory.map(PairedDeviceRow.init) }
        var remoteCallsStatus: String { modeUsesCloud ? "Enabled" : "Disabled" }

        var selfTestTitle: String {
            selfTestRunning ? "Run Cloud Self-Test · Running…" : "Run Cloud Self-Test"
        }

        var canRunSelfTest: Bool { modeUsesCloud && !selfTestRunning }

        var selfTestFooter: String {
            modeUsesCloud
                ? "Checks local push credentials, AirSIM Relay identity, device registration, and an Agent heartbeat within the last 90 seconds. No calls or messages are sent."
                : "Cloud self-test is unavailable in the current connection mode."
        }

        var selfTestSteps: [SelfTestStepRow] { report?.steps.map(SelfTestStepRow.init) ?? [] }

        var selfTestResult: SelfTestResult? {
            guard let report, selfTestCompleted else { return nil }
            return SelfTestResult(report: report)
        }

        fileprivate mutating func clearSelfTest() {
            report = nil
            selfTestRunning = false
            selfTestCompleted = false
        }
    }

    enum Action: ViewAction {
        case view(View)
        case pairing(PairingFeature.Action)
        case selfTestUpdated(CloudSelfTestReport)
        case selfTestFinished
        case deletionFinished(String?)
        case delegate(Delegate)

        enum View {
            case appeared
            case disappeared
            case modeChanged(AirSIMConnectionMode)
            case appearanceChanged(AppAppearance)
            case liveActivityChanged(Bool)
            case relayChanged(String)
            case saveRelayTapped
            case runSelfTestTapped
            case forgetDeviceConfirmed(String)
            case discoverTapped
            case startPairingTapped
            case pairLaterTapped
        }

        @CasePathable
        enum Delegate: Equatable {
            case onboardingCompleted
        }
    }

    enum CancelID {
        case selfTest
    }

    @Dependency(\.airSIM) var client

    var body: some ReducerOf<Self> {
        Scope(state: \.pairing, action: \.pairing) { PairingFeature() }
        Reduce { state, action in
            switch action {
            case .view(.appeared):
                return command(.refreshDevices)

            case .view(.disappeared):
                state.selfTestRunning = false
                return .cancel(id: CancelID.selfTest)

            case .view(.modeChanged(let mode)):
                state.mode = mode
                state.clearSelfTest()
                return .merge(
                    .cancel(id: CancelID.selfTest),
                    command(.mode(mode))
                )

            case .view(.appearanceChanged(let value)):
                state.appearance = value
                return command(.appearance(value))

            case .view(.liveActivityChanged(let value)):
                state.liveActivityEnabled = value
                return command(.liveActivity(value))

            case .view(.relayChanged(let value)):
                state.relayURL = value
                state.relayHasDraft = value != state.lastObservedRelayURL
                return .none

            case .view(.saveRelayTapped):
                state.clearSelfTest()
                state.message = "URL saved. Registration will complete automatically after pairing."
                return .merge(
                    .cancel(id: CancelID.selfTest),
                    command(.saveRelay(state.relayURL))
                )

            case .view(.runSelfTestTapped):
                guard !state.selfTestRunning, state.modeUsesCloud else { return .none }
                state.selfTestRunning = true
                state.selfTestCompleted = false
                state.report = .initial
                return .run { [client] send in
                    for await report in await client.selfTest() {
                        try Task.checkCancellation()
                        await send(.selfTestUpdated(report))
                    }
                    try Task.checkCancellation()
                    await send(.selfTestFinished)
                }
                .cancellable(id: CancelID.selfTest, cancelInFlight: true)

            case .selfTestUpdated(let report):
                state.report = report
                return .none

            case .selfTestFinished:
                state.selfTestRunning = false
                state.selfTestCompleted = true
                return .none

            case .view(.forgetDeviceConfirmed(let id)):
                guard !state.deletingDevice else { return .none }
                state.deletingDevice = true
                return .run { [client] send in
                    do {
                        try await client.command(.forgetDevice(id))
                        await send(.deletionFinished(nil))
                    } catch {
                        await send(.deletionFinished(error.localizedDescription))
                    }
                }

            case .deletionFinished(let error):
                state.deletingDevice = false
                state.message = error
                return .none

            case .view(.discoverTapped):
                return command(.discover)

            case .view(.startPairingTapped):
                state.pairingFromOnboarding = true
                return .none

            case .view(.pairLaterTapped):
                return .send(.delegate(.onboardingCompleted))

            case .pairing(.delegate(.opened)):
                // Local-only pairing defaults to the current mode, as it did for each presentation before TCA.
                if state.pairing.pairingID == nil {
                    state.pairing.localOnly = state.mode == .vowlan
                }
                return .none

            case .pairing(.delegate(.disappeared)):
                guard state.pairingFromOnboarding else { return .none }
                state.pairingFromOnboarding = false
                guard state.snapshot.vowlan.isOnlineForDisplay else { return .none }
                return .send(.delegate(.onboardingCompleted))

            case .pairing, .delegate:
                return .none
            }
        }
    }

    private func command(_ command: AirSIMCommand) -> Effect<Action> {
        .run { [client] _ in try await client.command(command) }
    }
}
