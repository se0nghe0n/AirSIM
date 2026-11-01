import ComposableArchitecture
import Foundation

/// The in-call keypad sheet: the digits sent so far, and one DTMF tone per tap.
@Reducer
struct KeypadFeature {
    @ObservableState
    struct State: Equatable {
        var digits = ""

        var displayText: String { digits.isEmpty ? "Tap keys to send DTMF tones" : digits }
        var digitsAccessibilityLabel: String { digits.isEmpty ? "No digits entered" : digits }
    }

    enum Action: ViewAction {
        case view(View)

        enum View {
            case digitTapped(String)
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
            }
        }
    }
}
