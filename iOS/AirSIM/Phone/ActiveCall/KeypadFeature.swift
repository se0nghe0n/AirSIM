import ComposableArchitecture
import Foundation

@Reducer
struct KeypadFeature {
    @ObservableState
    struct State: Equatable {
        var digits = ""

        var showsPlaceholder: Bool { digits.isEmpty }
        var displayText: String { showsPlaceholder ? "Tap keys to send DTMF tones" : digits }
        var digitsAccessibilityLabel: String { showsPlaceholder ? "No digits entered" : digits }

        func headerDisplayText(callerFallback: String) -> String {
            digits.isEmpty ? callerFallback : digits
        }

        func headerAccessibilityLabel(callerFallback: String) -> String {
            digits.isEmpty ? "Caller \(callerFallback), no keypad digits entered" : "Keypad digits \(digits)"
        }
    }

    enum Action: ViewAction {
        case view(View)
        case delegate(Delegate)

        enum View {
            case digitTapped(String)
            case endButtonTapped
            case hideButtonTapped
        }

        @CasePathable
        enum Delegate: Equatable {
            case endCallTapped
            case hideKeypadTapped
        }
    }

    @Dependency(\.airSIM) var client

    var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .view(.digitTapped(let digit)):
                state.digits = String((state.digits + digit).suffix(18))
                // sendDTMF reports its own failures through the backend error, which the root alert shows.
                return .run { [client] _ in try? await client.command(.dtmf(digit)) }

            case .view(.endButtonTapped):
                return .send(.delegate(.endCallTapped))

            case .view(.hideButtonTapped):
                return .send(.delegate(.hideKeypadTapped))

            case .delegate:
                return .none
            }
        }
    }
}
