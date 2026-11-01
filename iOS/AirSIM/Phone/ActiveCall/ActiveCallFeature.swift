import ComposableArchitecture
import Foundation

/// The in-app call screen and its DTMF keypad: Accept and Decline while a call rings, then mute, speaker, recording,
/// the keypad and End.
@Reducer
struct ActiveCallFeature {
    @ObservableState
    struct State: Equatable {
        @SharedReader fileprivate var snapshot: AirSIMSnapshot
        @Presents var keypad: KeypadFeature.State?
#if DEBUG
        /// Shown instead of the backend's call for layout screenshots; see `CallRecord.layoutPreview(arguments:)`.
        var layoutPreviewCall: CallRecord?
#endif

        init(snapshot: SharedReader<AirSIMSnapshot>) {
            _snapshot = snapshot
        }

        /// The call presented in app; the root shows the call window while there is one.
        var call: CallRecord? {
#if DEBUG
            if let layoutPreviewCall {
                return layoutPreviewCall
            }
#endif
            return snapshot.inAppPresentedCall
        }

        var content: ActiveCallContent? {
            call.map { ActiveCallContent(call: $0, snapshot: snapshot) }
        }

#if DEBUG
        var isLayoutPreview: Bool { layoutPreviewCall != nil }
#endif
    }

    enum Action: ViewAction {
        case view(View)
        case keypad(PresentationAction<KeypadFeature.Action>)

        enum View {
            case answerButtonTapped
            case declineButtonTapped
            case endButtonTapped
            case muteButtonTapped
            case speakerButtonTapped
            case recordButtonTapped
            case keypadButtonTapped
        }
    }

    @Dependency(\.airSIM) var client

    var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .view(.answerButtonTapped):
                return command(.answer)

            case .view(.declineButtonTapped):
                return command(.reject)

            case .view(.endButtonTapped):
                return command(.hangup)

            case .view(.muteButtonTapped):
                return command(.mute)

            case .view(.speakerButtonTapped):
                return command(.speaker)

            case .view(.recordButtonTapped):
                return command(.recording)

            case .view(.keypadButtonTapped):
                // A repeated tap while the sheet is presenting keeps the digits already sent.
                if state.snapshot.inAppPresentedCall != nil, state.keypad == nil {
                    state.keypad = KeypadFeature.State()
                }
                return .none

            case .keypad:
                return .none
            }
        }
        .ifLet(\.$keypad, action: \.keypad) { KeypadFeature() }
    }

    private func command(_ command: AirSIMCommand) -> Effect<Action> {
        .run { [client] _ in try await client.command(command) }
    }
}

#if DEBUG
extension CallRecord {
    /// The call `--airsim-layout-call incoming|active` shows for layout screenshots. The backend never reports it.
    static func layoutPreview(arguments: [String]) -> CallRecord? {
        guard let flag = arguments.firstIndex(of: "--airsim-layout-call"),
              arguments.indices.contains(flag + 1),
              ["incoming", "active"].contains(arguments[flag + 1])
        else { return nil }
        return CallRecord(
            id: "layout-preview",
            index: 0,
            direction: "incoming",
            state: arguments[flag + 1],
            number: "+1 202 555 0100",
            startedAt: Date().addingTimeInterval(-65),
            updatedAt: Date(),
            endedAt: nil,
            missed: false
        )
    }
}
#endif
