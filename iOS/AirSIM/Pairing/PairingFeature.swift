import ComposableArchitecture

@Reducer
struct PairingFeature {
    struct Discovery: Sendable {
        var services: [SamsungPairingService]
        var status: String
    }

    @ObservableState
    struct State: Equatable {
        var services: [SamsungPairingService] = []
        var status = "Scanning the local network for VoWLAN…"
        var localOnly = false
        var code = ""
        var pairingID: String?
        var message = ""

        var canChangeLocalOnly: Bool { pairingID == nil }
        var canPair: Bool { code.count == 6 && pairingID == nil }

        var localOnlyDetail: String {
            localOnly
                ? "This pairing saves only the VoWLAN key, without checking or saving Relay and push settings. Your connection mode stays unchanged."
                : "This pairing saves the VoWLAN key and Relay/push configuration. Cloud credentials must be ready. Your connection mode stays unchanged."
        }

        var resultMessage: String? { message.isEmpty ? nil : message }
    }

    enum Action: ViewAction {
        case view(View)
        case discovery(Discovery)
        case result(String)
        case delegate(Delegate)

        enum View {
            case opened
            case appeared
            case disappeared
            case localOnlyChanged(Bool)
            case codeChanged(String)
            case pairTapped(SamsungPairingService)
        }

        @CasePathable
        enum Delegate: Equatable {
            case opened
            case disappeared
        }
    }

    enum CancelID {
        case discovery
        case pair
    }

    @Dependency(\.airSIM) var client

    var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .view(.opened):
                // Each screen starts without the last one-time code. A result that arrived after
                // the previous screen closed is kept so it is still seen; an in-flight pairing keeps everything.
                if state.pairingID == nil {
                    state = State(message: state.message)
                }
                return .send(.delegate(.opened))

            case .view(.appeared):
                return .run { [client] send in
                    for await value in await client.pairing() {
                        await send(.discovery(value))
                    }
                }
                .cancellable(id: CancelID.discovery, cancelInFlight: true)

            case .view(.disappeared):
                if state.pairingID == nil {
                    state.message = ""
                }
                return .merge(
                    .cancel(id: CancelID.discovery),
                    .send(.delegate(.disappeared))
                )

            case .discovery(let value):
                state.services = value.services
                state.status = value.status
                return .none

            case .view(.localOnlyChanged(let value)):
                guard state.canChangeLocalOnly else { return .none }
                state.localOnly = value
                return .none

            case .view(.codeChanged(let value)):
                state.code = String(value.filter(\.isNumber).prefix(6))
                return .none

            case .view(.pairTapped(let service)):
                guard state.canPair else { return .none }
                state.pairingID = service.id
                state.message = state.localOnly
                    ? "Encrypting and saving the local VoWLAN key…"
                    : "Encrypting and saving to the Android Agent…"
                return .run { [client, code = state.code, localOnly = state.localOnly] send in
                    do {
                        await send(.result(try await client.pair(service, code, localOnly)))
                    } catch {
                        await send(.result("Pairing failed: \(error.localizedDescription)"))
                    }
                }
                .cancellable(id: CancelID.pair)

            case .result(let message):
                state.pairingID = nil
                state.message = message
                return .none

            case .delegate:
                return .none
            }
        }
    }
}
