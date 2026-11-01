import ComposableArchitecture
import Foundation

@Reducer
struct KeypadFeature {
    @ObservableState struct State: Equatable { var digits = "" }
    enum Action { case digitTapped(String) }
    @Dependency(\.airSIM) var client
    var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .digitTapped(let digit):
                state.digits = String((state.digits + digit).suffix(18))
                // sendDTMF reports its own failures through the backend error, which the root alert shows.
                return .run { [client] _ in try? await client.command(.dtmf(digit)) }
            }
        }
    }
}
