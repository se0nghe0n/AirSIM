import ComposableArchitecture
import Foundation

/// The app shell: backend snapshot intake, tab selection, the onboarding gate, URL routing and the
/// root error alert.
@Reducer
struct AirSIMFeature {
    @ObservableState
    struct State: Equatable {
        /// The backend projection. `receive(_:into:)` is its only writer.
        @Shared var snapshot: AirSIMSnapshot
        var dial: DialFeature.State
        var selectedTab = PhoneTab.dial
        var firstConnectionComplete = false
        var messages: MessagesFeature.State
        var settings: SettingsFeature.State
        var recents: RecentsFeature.State
        var contacts: ContactsFeature.State
        var activeCall: ActiveCallFeature.State
        @Presents var alert: AlertState<Action.Alert>?
        /// The backend error last seen in a snapshot, so each new one raises a single alert.
        var lastBackendError: String?
        /// Onboarding covers the tabs, so a composer requested before it finishes waits for it.
        var pendingComposeRecipient: String?

        init(snapshot: AirSIMSnapshot = AirSIMSnapshot()) {
            let shared = Shared(value: snapshot)
            _snapshot = shared
            dial = DialFeature.State(snapshot: SharedReader(shared))
            recents = RecentsFeature.State(snapshot: SharedReader(shared))
            messages = MessagesFeature.State(snapshot: SharedReader(shared))
            contacts = ContactsFeature.State(mode: .browse, snapshot: SharedReader(shared))
            settings = SettingsFeature.State(snapshot: SharedReader(shared))
            activeCall = ActiveCallFeature.State(snapshot: SharedReader(shared))
        }

        mutating func composeMessage(to recipient: String) {
            selectedTab = .messages
            if firstConnectionComplete {
                messages.compose(to: recipient)
            } else {
                pendingComposeRecipient = recipient
            }
        }

        mutating func finishOnboarding() {
            firstConnectionComplete = true
            if let recipient = pendingComposeRecipient {
                pendingComposeRecipient = nil
                messages.compose(to: recipient)
            }
        }
    }

    enum Action {
        case start
        case stop
        case snapshot(AirSIMSnapshot)
        case selectTab(PhoneTab)
        case openURL(URL)
        case openSMS(String)
        case composeMessage(String)
        case remoteSMSReceived
        case openIncomingCall
        case dial(DialFeature.Action)
        case messages(MessagesFeature.Action)
        case settings(SettingsFeature.Action)
        case recents(RecentsFeature.Action)
        case contacts(ContactsFeature.Action)
        case activeCall(ActiveCallFeature.Action)
        case alert(PresentationAction<Alert>)

        enum Alert: Equatable {
            case clearBackendError(String)
        }
    }

    enum CancelID {
        case snapshot
    }

    @Dependency(\.airSIM) var client

    var body: some ReducerOf<Self> {
        Scope(state: \.dial, action: \.dial) { DialFeature() }
        Scope(state: \.messages, action: \.messages) { MessagesFeature() }
        Scope(state: \.settings, action: \.settings) { SettingsFeature() }
        Scope(state: \.recents, action: \.recents) { RecentsFeature() }
        Scope(state: \.contacts, action: \.contacts) { ContactsFeature() }
        Scope(state: \.activeCall, action: \.activeCall) { ActiveCallFeature() }
        Reduce { state, action in
            switch action {
            case .start:
                return .run { [client] send in
                    for await value in await client.snapshots() {
                        await send(.snapshot(value))
                    }
                }
                .cancellable(id: CancelID.snapshot, cancelInFlight: true)

            case .stop:
                return .cancel(id: CancelID.snapshot)

            case .snapshot(let value):
                return receive(value, into: &state)

            case .selectTab(let tab):
                state.selectedTab = tab
                return command(.persistTab(tab))

            case .openURL(let url):
                return open(url, state: &state)

            case .openSMS(let sender):
                state.selectedTab = .messages
                return .merge(
                    .send(.messages(.openConversation(sender))),
                    command(.reloadLocalMessages)
                )

            case .remoteSMSReceived:
                return command(.reloadLocalMessages)

            case .openIncomingCall:
                return command(.presentCall)

            case .recents(.delegate(.call(let number))),
                 .contacts(.delegate(.call(let number))):
                return dial(number, state: &state)

            case .composeMessage(let recipient),
                 .recents(.delegate(.message(let recipient))),
                 .contacts(.delegate(.message(let recipient))),
                 .messages(.delegate(.compose(let recipient))):
                return compose(to: recipient, state: &state)

            case .messages(.delegate(.unreportedSendFailure(let error))):
                state.alert = .error(error)
                return .none

            case .settings(.delegate(.onboardingCompleted)):
                state.finishOnboarding()
                return command(.completeOnboarding)

            case .alert(.presented(.clearBackendError(let error))):
                return command(.clearError(error))

            case .dial, .messages, .settings, .recents, .contacts, .activeCall, .alert:
                return .none
            }
        }
        .ifLet(\.$alert, action: \.alert)
    }

    /// The one place backend state enters the tree.
    private func receive(_ value: AirSIMSnapshot, into state: inout State) -> Effect<Action> {
        if state.snapshot != value {
            state.$snapshot.withLock { $0 = value }
        }
        state.settings.reconcile(with: value)
        // Onboarding finished in another scene also releases a waiting composer.
        if value.preferenceOnboardingComplete {
            state.finishOnboarding()
        }
        state.dial.reconcile(backendNumber: value.numberInput)
        if value.inAppPresentedCall == nil {
            state.activeCall.keypad = nil
        }
        if value.errorMessage != state.lastBackendError {
            state.lastBackendError = value.errorMessage
            // OK clears only this error; the backend may have recorded a newer one by then.
            if let error = value.errorMessage, !error.isEmpty {
                state.alert = .error(error, ok: .clearBackendError(error))
            }
        }
        if value.callLifecycleSnapshot.state.representsCall, value.playingRecordingID != nil {
            return .send(.recents(.recordings(.stopPlayback(deactivateSession: false))))
        }
        return .none
    }

    /// A call back from another tab: show the number on Dial, persist that tab, and dial.
    private func dial(_ number: String, state: inout State) -> Effect<Action> {
        state.dial.edit(number)
        state.selectedTab = .dial
        return .merge(
            command(.persistTab(.dial)),
            command(.dialNumber(number))
        )
    }

    /// A message from any tab or link: show Messages, persist that tab, and compose once onboarding allows it.
    private func compose(to recipient: String, state: inout State) -> Effect<Action> {
        state.composeMessage(to: recipient)
        return command(.persistTab(.messages))
    }

    private func open(_ url: URL, state: inout State) -> Effect<Action> {
        switch SystemCommunicationURL.destination(for: url) {
        case .message(let recipient):
            return compose(to: recipient, state: &state)

        case .call(let number):
            // Unlike a call back from Recents or Contacts, a tel: link does not persist the Dial tab.
            state.selectedTab = .dial
            state.dial.number = number
            state.dial.hasDraft = true
            return command(.dialNumber(number))

        case let .liveActivity(action, callID):
            // The backend gate runs immediately before execution. The UI
            // projection can lag cold-launch adoption or a new call.
            return command(.liveActivityAction(action, callID: callID))

        case nil:
            return .none
        }
    }

    private func command(_ command: AirSIMCommand) -> Effect<Action> {
        .run { [client] _ in try await client.command(command) }
    }
}

extension AlertState {
    /// One OK button. Alerts shown with present(item:) need an OK action: that binding is created before any
    /// alert exists, so its nil write-back cannot match an AlertState id, while an action clears the state.
    static func error(_ message: String, title: String = "Error", ok: Action? = nil) -> Self {
        AlertState {
            TextState(title)
        } actions: {
            if let ok {
                ButtonState(role: .cancel, action: ok) { TextState("OK") }
            } else {
                ButtonState(role: .cancel) { TextState("OK") }
            }
        } message: {
            TextState(message)
        }
    }
}
