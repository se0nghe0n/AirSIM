import ComposableArchitecture
import Foundation

@Reducer
struct AirSIMFeature {
    @ObservableState struct State: Equatable {
        var snapshot = AirSIMSnapshot()
        var dialNumber = ""
        var lastBackendNumber = ""
        var hasDialDraft = false
        var selectedTab = PhoneTab.dial
        var firstConnectionComplete = false
        var messages = MessagesFeature.State()
        var settings = SettingsFeature.State()
        var pairing = PairingFeature.State()
        var recordings = RecordingsFeature.State()
        var trace = TraceFeature.State()
        var contactSearch = ""
        var contactPickerSearch = ""
        @Presents var keypad: KeypadFeature.State?
        @Presents var alert: AlertState<Action.Alert>?
        /// The backend error last seen in a snapshot, so each new one raises a single alert.
        var lastBackendError: String?
        /// Onboarding covers the tabs, so a composer requested before it finishes waits for it.
        var pendingComposeRecipient: String?
        mutating func composeMessage(to recipient: String) {
            selectedTab = .messages
            if firstConnectionComplete { messages.compose(to: recipient) } else { pendingComposeRecipient = recipient }
        }
        mutating func finishOnboarding() {
            firstConnectionComplete = true
            if let recipient = pendingComposeRecipient { pendingComposeRecipient = nil; messages.compose(to: recipient) }
        }
    }
    enum Action {
        case start, stop, snapshot(AirSIMSnapshot), selectTab(PhoneTab), completeOnboarding
        case numberChanged(String), command(AirSIMCommand), commandFailed(String)
        case openURL(URL), openSMS(String), composeMessage(String), contactSearchChanged(String), keypadButtonTapped
        case contactPickerSearchChanged(String), keypad(PresentationAction<KeypadFeature.Action>)
        case messages(MessagesFeature.Action), settings(SettingsFeature.Action), pairing(PairingFeature.Action)
        case recordings(RecordingsFeature.Action), trace(TraceFeature.Action), alert(PresentationAction<Alert>)
        enum Alert: Equatable { case clearBackendError(String) }
    }
    enum CancelID { case snapshot }
    @Dependency(\.airSIM) var client
    var body: some ReducerOf<Self> {
        Scope(state: \.messages, action: \.messages) { MessagesFeature() }
        Scope(state: \.settings, action: \.settings) { SettingsFeature() }
        Scope(state: \.pairing, action: \.pairing) { PairingFeature() }
        Scope(state: \.recordings, action: \.recordings) { RecordingsFeature() }
        Scope(state: \.trace, action: \.trace) { TraceFeature() }
        Reduce { state, action in
            switch action {
            case .start: return .run { [client] send in for await value in await client.snapshots() { await send(.snapshot(value)) } }.cancellable(id: CancelID.snapshot, cancelInFlight: true)
            case .stop: return .cancel(id: CancelID.snapshot)
            case .snapshot(let value):
                state.snapshot = value; state.recordings.playingID = value.playingRecordingID
                if value.preferenceMode != state.settings.lastObservedMode { state.settings.mode = value.preferenceMode; state.settings.lastObservedMode = value.preferenceMode }
                if value.preferenceAppearance != state.settings.lastObservedAppearance { state.settings.appearance = value.preferenceAppearance; state.settings.lastObservedAppearance = value.preferenceAppearance }
                if value.preferenceLiveActivity != state.settings.lastObservedLiveActivity { state.settings.liveActivityEnabled = value.preferenceLiveActivity; state.settings.lastObservedLiveActivity = value.preferenceLiveActivity }
                if value.preferenceRelayURL != state.settings.lastObservedRelayURL {
                    if !state.settings.relayHasDraft { state.settings.relayURL = value.preferenceRelayURL }
                    state.settings.lastObservedRelayURL = value.preferenceRelayURL
                }
                if value.preferenceRelayURL == state.settings.relayURL { state.settings.relayHasDraft = false }
                // Onboarding finished in another scene also releases a waiting composer.
                if value.preferenceOnboardingComplete { state.finishOnboarding() }
                if value.numberInput != state.lastBackendNumber {
                    state.lastBackendNumber = value.numberInput
                    if !state.hasDialDraft { state.dialNumber = value.numberInput }
                }
                if value.numberInput == state.dialNumber { state.hasDialDraft = false }
                if value.inAppPresentedCall == nil { state.keypad = nil }
                if value.errorMessage != state.lastBackendError {
                    state.lastBackendError = value.errorMessage
                    // OK clears only this error; the backend may have recorded a newer one by then.
                    if let error = value.errorMessage, !error.isEmpty { state.alert = .error(error, ok: .clearBackendError(error)) }
                }
                if value.callLifecycleSnapshot.state.representsCall, value.playingRecordingID != nil { return .send(.recordings(.stop(false))) }
                return .none
            case .selectTab(let tab): state.selectedTab = tab; return .run { [client] _ in try await client.command(.persistTab(tab)) }
            case .completeOnboarding: state.finishOnboarding(); return perform(.completeOnboarding)
            case .numberChanged(let value): state.dialNumber = value; state.hasDialDraft = value != state.lastBackendNumber; return .none
            case .command(let command): return perform(command)
            case .commandFailed(let error): state.alert = .error(error); return .none
            case .openSMS(let sender): state.selectedTab = .messages; return .merge(.send(.messages(.openConversation(sender))), .send(.command(.reloadLocalMessages)))
            case .composeMessage(let recipient): state.composeMessage(to: recipient); return perform(.persistTab(.messages))
            case .openURL(let url):
                switch SystemCommunicationURL.destination(for: url) {
                case .message(let recipient): state.composeMessage(to: recipient); return perform(.persistTab(.messages))
                case .call(let number): state.selectedTab = .dial; state.dialNumber = number; state.hasDialDraft = true; return .run { [client] _ in try await client.command(.dialNumber(number)) }
                case let .liveActivity(action, callID):
                    // The backend gate runs immediately before execution. The UI
                    // projection can lag cold-launch adoption or a new call.
                    return perform(.liveActivityAction(action, callID: callID))
                case nil: return .none
                }
            case .contactSearchChanged(let value): state.contactSearch = value; return .none
            case .contactPickerSearchChanged(let value): state.contactPickerSearch = value; return .none
            case .keypadButtonTapped:
                // A repeated tap while the sheet is presenting keeps the digits already sent.
                if state.snapshot.inAppPresentedCall != nil, state.keypad == nil { state.keypad = KeypadFeature.State() }
                return .none
            case .messages(.delegate(.unreportedSendFailure(let error))): state.alert = .error(error); return .none
            case .alert(.presented(.clearBackendError(let error))): return perform(.clearError(error))
            case .pairing(.opened):
                // Local-only pairing defaults to the current mode, as it did for each presentation before TCA.
                if state.pairing.pairingID == nil { state.pairing.localOnly = state.settings.mode == .vowlan }
                return .none
            case .messages, .settings, .pairing, .recordings, .trace, .keypad, .alert: return .none
            }
        }
        .ifLet(\.$keypad, action: \.keypad) { KeypadFeature() }
        .ifLet(\.$alert, action: \.alert)
    }
    private func perform(_ command: AirSIMCommand) -> Effect<Action> {
        .run { [client] send in do { try await client.command(command) } catch { await send(.commandFailed(error.localizedDescription)) } }
    }
}

extension AlertState {
    /// One OK button. Alerts shown with present(item:) need an OK action: that binding is created before any
    /// alert exists, so its nil write-back cannot match an AlertState id, while an action clears the state.
    static func error(_ message: String, title: String = "Error", ok: Action? = nil) -> Self {
        AlertState { TextState(title) } actions: {
            if let ok { ButtonState(role: .cancel, action: ok) { TextState("OK") } } else { ButtonState(role: .cancel) { TextState("OK") } }
        } message: { TextState(message) }
    }
}
