import ComposableArchitecture

@Reducer
struct PairingFeature {
    struct Discovery: Sendable { var services: [SamsungPairingService]; var status: String }
    @ObservableState struct State: Equatable {
        var services: [SamsungPairingService] = []
        var status = "Scanning the local network for VoWLAN…"
        var localOnly = false
        var code = ""
        var pairingID: String?
        var message = ""
    }
    enum Action { case opened, appeared, disappeared, discovery(Discovery), localChanged(Bool), codeChanged(String), pair(SamsungPairingService), result(String) }
    enum CancelID { case discovery, pair }
    @Dependency(\.airSIM) var client
    var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .opened:
                // Each screen starts without the last one-time code. A result that arrived after
                // the previous screen closed is kept so it is still seen; an in-flight pairing keeps everything.
                guard state.pairingID == nil else { return .none }
                state = State(message: state.message); return .none
            case .appeared: return .run { [client] send in for await value in await client.pairing() { await send(.discovery(value)) } }.cancellable(id: CancelID.discovery, cancelInFlight: true)
            case .disappeared:
                if state.pairingID == nil { state.message = "" }
                return .cancel(id: CancelID.discovery)
            case .discovery(let value): state.services = value.services; state.status = value.status; return .none
            case .localChanged(let value): guard state.pairingID == nil else { return .none }; state.localOnly = value; return .none
            case .codeChanged(let value): state.code = String(value.filter(\.isNumber).prefix(6)); return .none
            case .pair(let service):
                guard state.code.count == 6, state.pairingID == nil else { return .none }; state.pairingID = service.id
                state.message = state.localOnly ? "Encrypting and saving the local VoWLAN key…" : "Encrypting and saving to the Android Agent…"
                return .run { [client, code = state.code, local = state.localOnly] send in
                    do { await send(.result(try await client.pair(service, code, local))) } catch { await send(.result("Pairing failed: \(error.localizedDescription)")) }
                }.cancellable(id: CancelID.pair)
            case .result(let message): state.pairingID = nil; state.message = message; return .none
            }
        }
    }
}
