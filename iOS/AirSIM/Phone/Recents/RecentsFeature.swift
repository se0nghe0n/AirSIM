import ComposableArchitecture
import Foundation

@Reducer
struct RecentsFeature {
    @ObservableState
    struct State: Equatable {
        @SharedReader fileprivate var snapshot: AirSIMSnapshot
        var recordings: RecordingsFeature.State

        init(snapshot: SharedReader<AirSIMSnapshot>) {
            _snapshot = snapshot
            recordings = RecordingsFeature.State(snapshot: snapshot)
        }

        var rows: [RecentCallRow] {
            snapshot.callHistory.map { RecentCallRow(call: $0, contacts: snapshot.contacts) }
        }

        var statusMessage: String? { snapshot.callHistoryMessage }
        var isRefreshing: Bool { snapshot.isRefreshingCallHistory }

        func row(id: RecentCallRow.ID) -> RecentCallRow? {
            snapshot.callHistory
                .first { $0.id == id }
                .map { RecentCallRow(call: $0, contacts: snapshot.contacts) }
        }
    }

    enum Action: ViewAction {
        case view(View)
        case recordings(RecordingsFeature.Action)
        case delegate(Delegate)

        enum View {
            case appeared
            case refreshTapped
            case callTapped(RecentCallRow)
            case messageTapped(RecentCallRow)
            case deleteTapped(RecentCallRow.ID)
        }

        @CasePathable
        enum Delegate: Equatable {
            case call(String)
            case message(String)
        }
    }

    @Dependency(\.airSIM) var client

    var body: some ReducerOf<Self> {
        Scope(state: \.recordings, action: \.recordings) { RecordingsFeature() }
        Reduce { state, action in
            switch action {
            case .view(.appeared), .view(.refreshTapped):
                return .run { [client] _ in try await client.command(.refreshHistory) }

            case .view(.callTapped(let row)):
                guard let number = row.dialNumber else { return .none }
                return .send(.delegate(.call(number)))

            case .view(.messageTapped(let row)):
                guard let number = row.dialNumber else { return .none }
                return .send(.delegate(.message(number)))

            case .view(.deleteTapped(let id)):
                return .run { [client] _ in try await client.command(.deleteHistory([id])) }

            case .recordings, .delegate:
                return .none
            }
        }
    }
}
