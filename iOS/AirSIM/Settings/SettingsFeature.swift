import ComposableArchitecture

@Reducer
struct SettingsFeature {
    @ObservableState struct State: Equatable {
        var mode = AirSIMConnectionMode.automatic
        var appearance = AppAppearance.system
        var relayURL = ""
        var lastObservedMode = AirSIMConnectionMode.automatic
        var lastObservedAppearance = AppAppearance.system
        var lastObservedRelayURL = ""
        var lastObservedLiveActivity = true
        var relayHasDraft = false
        var liveActivityEnabled = true
        var report: CloudSelfTestReport?
        var selfTestRunning = false
        var selfTestCompleted = false
        var message: String?
        var deletingDevice = false
    }
    enum Action {
        case modeChanged(AirSIMConnectionMode), appearanceChanged(AppAppearance), relayChanged(String), liveActivityChanged(Bool)
        case saveRelay, runSelfTest, selfTestUpdated(CloudSelfTestReport), selfTestFinished, disappeared
        case forgetDevice(String), deletionFinished(String?)
    }
    @Dependency(\.airSIM) var client
    enum CancelID { case selfTest }
    var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .modeChanged(let mode): state.mode = mode; state.report = nil; state.selfTestRunning = false; state.selfTestCompleted = false; return .merge(.cancel(id: CancelID.selfTest), .run { [client] _ in try await client.command(.mode(mode)) })
            case .appearanceChanged(let value): state.appearance = value; return .run { [client] _ in try await client.command(.appearance(value)) }
            case .relayChanged(let value): state.relayURL = value; state.relayHasDraft = value != state.lastObservedRelayURL; return .none
            case .liveActivityChanged(let value): state.liveActivityEnabled = value; return .run { [client] _ in try await client.command(.liveActivity(value)) }
            case .saveRelay:
                state.report = nil; state.selfTestRunning = false; state.selfTestCompleted = false; state.message = "URL saved. Registration will complete automatically after pairing."
                return .merge(.cancel(id: CancelID.selfTest), .run { [client, url = state.relayURL] _ in try await client.command(.saveRelay(url)) })
            case .runSelfTest:
                guard !state.selfTestRunning, ConnectionModeRuntimePolicy(mode: state.mode).startsCloud else { return .none }
                state.selfTestRunning = true; state.selfTestCompleted = false; state.report = .initial
                return .run { [client] send in
                    for await report in await client.selfTest() { try Task.checkCancellation(); await send(.selfTestUpdated(report)) }
                    try Task.checkCancellation()
                    await send(.selfTestFinished)
                }.cancellable(id: CancelID.selfTest, cancelInFlight: true)
            case .selfTestUpdated(let report): state.report = report; return .none
            case .selfTestFinished: state.selfTestRunning = false; state.selfTestCompleted = true; return .none
            case .disappeared: state.selfTestRunning = false; return .cancel(id: CancelID.selfTest)
            case .forgetDevice(let id):
                guard !state.deletingDevice else { return .none }; state.deletingDevice = true
                return .run { [client] send in do { try await client.command(.forgetDevice(id)); await send(.deletionFinished(nil)) } catch { await send(.deletionFinished(error.localizedDescription)) } }
            case .deletionFinished(let error): state.deletingDevice = false; state.message = error; return .none
            }
        }
    }
}
