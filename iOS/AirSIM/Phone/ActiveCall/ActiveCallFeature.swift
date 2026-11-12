import ComposableArchitecture
import Foundation

@Reducer
struct ActiveCallFeature {
    @ObservableState
    struct State: Equatable {
        @SharedReader fileprivate var snapshot: AirSIMSnapshot
        @Presents var keypad: KeypadFeature.State?
        var isShowingMoreMenu = false
        #if DEBUG
        var layoutPreviewCall: CallRecord?
        #endif

        init(snapshot: SharedReader<AirSIMSnapshot>) {
            _snapshot = snapshot
        }

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
            case keypadHideTapped
            case moreButtonTapped
            case moreMenuDismissed
        }
    }

    @Dependency(\.airSIM) var client

    var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .view(.answerButtonTapped):
                state.isShowingMoreMenu = false
                return command(.answer)

            case .view(.declineButtonTapped):
                state.isShowingMoreMenu = false
                return command(.reject)

            case .view(.endButtonTapped):
                state.isShowingMoreMenu = false
                state.keypad = nil
                return command(.hangup)

            case .view(.muteButtonTapped):
                return command(.mute)

            case .view(.speakerButtonTapped):
                return command(.speaker)

            case .view(.recordButtonTapped):
                state.isShowingMoreMenu = false
                return command(.recording)

            case .view(.keypadButtonTapped):
                state.isShowingMoreMenu = false
                // A repeated tap while the keypad is open keeps the digits already sent.
                if state.call != nil, state.keypad == nil {
                    state.keypad = KeypadFeature.State()
                }
                return .none

            case .view(.keypadHideTapped):
                state.keypad = nil
                return .none

            case .view(.moreButtonTapped):
                guard state.call != nil, state.content?.phase == .connected else { return .none }
                state.isShowingMoreMenu.toggle()
                return .none

            case .view(.moreMenuDismissed):
                state.isShowingMoreMenu = false
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
