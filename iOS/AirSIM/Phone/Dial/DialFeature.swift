import ComposableArchitecture
import Foundation

@Reducer
struct DialFeature {
    @ObservableState
    struct State: Equatable {
        @SharedReader fileprivate var snapshot: AirSIMSnapshot
        var number: String
        var lastBackendNumber: String
        var hasDraft = false

        init(snapshot: SharedReader<AirSIMSnapshot>) {
            _snapshot = snapshot
            let backendNumber = snapshot.wrappedValue.numberInput
            number = backendNumber
            lastBackendNumber = backendNumber
        }

        var displayText: String { number.isEmpty ? "Enter number" : number }
        var showsPlaceholder: Bool { number.isEmpty }
        var contactName: String? { snapshot.contacts.contact(for: number)?.name }
        var canCall: Bool { !number.isEmpty && !snapshot.isBusy && snapshot.canStartOutgoingCommand }
        var callIsDimmed: Bool { number.isEmpty || !snapshot.canStartOutgoingCommand }
        var canDelete: Bool { !number.isEmpty }
        var playsInputClick: Bool { !snapshot.isMuted }

        var showsAgentCard: Bool { currentAgent != nil || !snapshot.pairedAndroidAgents.isEmpty }
        var currentAgent: AndroidAgentPresentation? { snapshot.currentAndroidAgent }
        var agentCount: Int { snapshot.pairedAndroidAgents.count }
        var cloudModeEnabled: Bool { snapshot.cloudModeEnabled }
        var agentRows: [PairedAgentRow] {
            snapshot.pairedAndroidAgents.map { PairedAgentRow(agent: $0, cloudModeEnabled: snapshot.cloudModeEnabled) }
        }

        mutating func edit(_ value: String) {
            number = value
            hasDraft = value != lastBackendNumber
        }

        /// Keeps `value` as a draft even when it equals the backend's number.
        mutating func holdDraft(_ value: String) {
            number = value
            hasDraft = true
        }

        mutating func reconcile(backendNumber: String) {
            if backendNumber != lastBackendNumber {
                lastBackendNumber = backendNumber
                if !hasDraft {
                    number = backendNumber
                }
            }
            if backendNumber == number {
                hasDraft = false
            }
        }

        fileprivate mutating func deleteLastDigit() {
            edit(String(number.dropLast()))
        }
    }

    enum Action: ViewAction {
        case view(View)
        case deleteRepeated

        enum View {
            case digitTapped(String)
            case deletePressed
            case deleteReleased
            case deleteActivated
            case callTapped
            case agentChosen(String)
            case disappeared
        }
    }

    enum CancelID {
        case deleteRepeat
    }

    @Dependency(\.airSIM) var client
    @Dependency(\.continuousClock) var clock

    var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .view(.digitTapped(let digit)):
                state.edit(state.number + digit)
                return .none

            case .view(.deletePressed):
                state.deleteLastDigit()
                return .run { [clock] send in
                    try await clock.sleep(for: .milliseconds(350))
                    while !Task.isCancelled {
                        await send(.deleteRepeated)
                        try await clock.sleep(for: .milliseconds(90))
                    }
                }
                .cancellable(id: CancelID.deleteRepeat, cancelInFlight: true)

            case .deleteRepeated:
                guard !state.number.isEmpty else { return .cancel(id: CancelID.deleteRepeat) }
                state.deleteLastDigit()
                return .none

            case .view(.deleteReleased), .view(.disappeared):
                return .cancel(id: CancelID.deleteRepeat)

            case .view(.deleteActivated):
                state.deleteLastDigit()
                return .none

            case .view(.callTapped):
                let number = state.number
                return .run { [client] _ in try await client.command(.dialNumber(number)) }

            case .view(.agentChosen(let id)):
                return .run { [client] _ in try await client.command(.bindAgent(id)) }
            }
        }
    }
}
