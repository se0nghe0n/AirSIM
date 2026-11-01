import ComposableArchitecture

@Reducer
struct TraceFeature {
    @ObservableState
    struct State: Equatable {
        var data = AgentVerboseTraceData()
        var filter = AgentVerboseTraceFilter.all
        var refreshing = false
        var refreshID = 0
        var pendingClear = false
        var pendingEnabled: Bool?
    }
    enum Action {
        case appeared, disappeared, refresh, clear
        case refreshed(id: Int, AgentVerboseTraceData)
        case filterChanged(AgentVerboseTraceFilter), enabledChanged(Bool)
    }
    enum CancelID { case timer, refresh }
    @Dependency(\.airSIM) var client
    @Dependency(\.continuousClock) var clock
    var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .appeared:
                return .merge(.send(.refresh), .run { [clock] send in
                    while !Task.isCancelled { try await clock.sleep(for: .seconds(1)); await send(.refresh) }
                }.cancellable(id: CancelID.timer, cancelInFlight: true))
            case .disappeared:
                state.refreshing = false
                state.refreshID += 1
                return .merge(.cancel(id: CancelID.timer), .cancel(id: CancelID.refresh))
            case .clear:
                state.pendingClear = true
                return state.refreshing ? .none : .send(.refresh)
            case .enabledChanged(let enabled):
                state.data.enabled = enabled
                state.pendingEnabled = enabled
                return state.refreshing ? .none : .send(.refresh)
            case .refresh:
                guard !state.refreshing else { return .none }
                state.refreshing = true
                state.refreshID += 1
                let clear = state.pendingClear
                let enabled = state.pendingEnabled
                state.pendingClear = false
                state.pendingEnabled = nil
                // Serialize reads, clears and preference writes. A user command during a
                // slow poll is queued, rather than discarded or overwritten by that poll.
                return .run { [client, data = state.data, id = state.refreshID] send in
                    if let enabled { await client.traceEnabled(enabled) }
                    try Task.checkCancellation()
                    let refreshed = await client.traceRefresh(data, clear)
                    try Task.checkCancellation()
                    await send(.refreshed(id: id, refreshed))
                }.cancellable(id: CancelID.refresh)
            case let .refreshed(id, data):
                guard state.refreshing, id == state.refreshID else { return .none }
                state.data = data
                if let enabled = state.pendingEnabled { state.data.enabled = enabled }
                state.refreshing = false
                return state.pendingClear || state.pendingEnabled != nil ? .send(.refresh) : .none
            case .filterChanged(let filter):
                state.filter = filter
                return .none
            }
        }
    }
}
