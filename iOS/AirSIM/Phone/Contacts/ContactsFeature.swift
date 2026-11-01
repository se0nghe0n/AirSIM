import ComposableArchitecture
import Foundation

/// The address book, shown as the Contacts tab and as the composer's contact picker. Each screen keeps its
/// own search, so the picker's never filters the tab.
@Reducer
struct ContactsFeature {
    enum Mode: Equatable {
        /// The Contacts tab: a row per contact, opening its details.
        case browse
        /// The composer's picker: a row per number, choosing it.
        case pick
    }

    /// What shows instead of the list while contacts cannot be read.
    enum AccessPrompt: Equatable {
        case allowAccess
        case openSettings
    }

    @ObservableState
    struct State: Equatable {
        @SharedReader fileprivate var snapshot: AirSIMSnapshot
        let mode: Mode
        var search = ""

        init(mode: Mode, snapshot: SharedReader<AirSIMSnapshot>) {
            self.mode = mode
            _snapshot = snapshot
        }

        var title: String {
            switch mode {
            case .browse: "Contacts"
            case .pick: "Choose Contact"
            }
        }

        var navigationTitle: String {
            switch mode {
            case .browse: "Contacts · \(snapshot.contacts.all.count)"
            case .pick: "Choose Contact"
            }
        }

        /// Nil once the address book can be read.
        var accessPrompt: AccessPrompt? {
            guard !snapshot.contacts.isAuthorized else { return nil }
            return snapshot.contacts.authorization == .denied ? .openSettings : .allowAccess
        }

        var rows: [ContactRow] {
            let contacts = snapshot.contacts.contacts(matching: search)
            switch mode {
            case .browse:
                return contacts.map { ContactRow(contact: $0) }
            case .pick:
                return contacts.flatMap { contact in
                    ContactPhoneListPolicy.displayPhones(for: contact.phones)
                        .map { ContactRow(contact: contact, phone: $0) }
                }
            }
        }
    }

    enum Action: ViewAction {
        case view(View)
        case delegate(Delegate)

        enum View {
            case appeared
            case refreshPulled
            case allowAccessTapped
            case searchChanged(String)
            case phoneChosen(String)
            case callTapped(String)
            case messageTapped(String)
        }

        @CasePathable
        enum Delegate: Equatable {
            case call(String)
            case message(String)
            case picked(String)
        }
    }

    @Dependency(\.airSIM) var client

    var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .view(.appeared):
                return .run { [client] _ in try await client.command(.contacts(false)) }

            case .view(.refreshPulled), .view(.allowAccessTapped):
                return .run { [client] _ in try await client.command(.contacts(true)) }

            case .view(.searchChanged(let text)):
                state.search = text
                return .none

            case .view(.phoneChosen(let phone)):
                return .send(.delegate(.picked(phone)))

            case .view(.callTapped(let phone)):
                return .send(.delegate(.call(phone)))

            case .view(.messageTapped(let phone)):
                return .send(.delegate(.message(phone)))

            case .delegate:
                return .none
            }
        }
    }
}
