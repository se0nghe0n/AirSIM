import ComposableArchitecture
import Foundation

/// The New Message sheet: a recipient with contact suggestions, a body, and Send. MessagesFeature runs the send.
@Reducer
struct ComposerFeature {
    /// A contact offered under the recipient field.
    struct Suggestion: Equatable {
        let name: String
        /// The contact's first number, shown under its name.
        let phone: String?
        /// What choosing it addresses: the contact's first number, else the typed text.
        let recipient: String
    }

    @ObservableState
    struct State: Equatable {
        @SharedReader fileprivate var snapshot: AirSIMSnapshot
        var recipient: String
        var body = ""
        var sendID: UUID?
        @Presents var alert: AlertState<Action.Alert>?
        @Presents var contactPicker: ContactsFeature.State?

        init(recipient: String, body: String = "", sendID: UUID? = nil, snapshot: SharedReader<AirSIMSnapshot>) {
            _snapshot = snapshot
            self.recipient = recipient
            self.body = body
            self.sendID = sendID
        }

        var sending: Bool { sendID != nil }

        var canSend: Bool {
            !sending
                && !recipient.trimmingCharacters(in: .whitespaces).isEmpty
                && !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        /// The name of the contact the recipient already names.
        var recognizedName: String? {
            snapshot.contacts.contact(for: recipient)?.name
        }

        var suggestions: [Suggestion] {
            let typed = recipient.trimmingCharacters(in: .whitespaces)
            return snapshot.contacts.suggestions(for: recipient).map { contact in
                Suggestion(name: contact.name, phone: contact.phones.first, recipient: contact.phones.first ?? typed)
            }
        }
    }

    enum Action: ViewAction {
        case view(View)
        case contactPicker(PresentationAction<ContactsFeature.Action>)
        case alert(PresentationAction<Alert>)
        case delegate(Delegate)

        enum View {
            case opened
            case recipientChanged(String)
            case bodyChanged(String)
            case sendButtonTapped
            case cancelButtonTapped
            case chooseContactTapped
        }

        enum Alert: Equatable {
            case ok
        }

        /// MessagesFeature runs the send so closing the sheet cannot cancel an SMS the module may already have sent.
        enum Delegate {
            case send(id: UUID, to: String, body: String)
        }
    }

    @Dependency(\.airSIM) var client
    @Dependency(\.dismiss) var dismiss
    @Dependency(\.uuid) var uuid

    var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .view(.opened):
                return .run { [client] _ in try await client.command(.contacts(false)) }

            case .view(.recipientChanged(let value)):
                state.recipient = value
                return .none

            case .view(.bodyChanged(let value)):
                state.body = value
                return .none

            case .view(.sendButtonTapped):
                guard state.canSend else { return .none }
                let id = uuid()
                state.sendID = id
                return .send(.delegate(.send(id: id, to: state.recipient, body: state.body)))

            case .view(.cancelButtonTapped):
                return .run { _ in await dismiss() }

            case .view(.chooseContactTapped):
                state.contactPicker = ContactsFeature.State(mode: .pick, snapshot: state.$snapshot)
                return .none

            case .contactPicker(.presented(.delegate(.picked(let phone)))):
                state.recipient = phone
                state.contactPicker = nil
                return .none

            case .contactPicker, .alert, .delegate:
                return .none
            }
        }
        .ifLet(\.$alert, action: \.alert)
        .ifLet(\.$contactPicker, action: \.contactPicker) { ContactsFeature() }
    }
}

extension AlertState where Action == ComposerFeature.Action.Alert {
    static func sendFailed(_ message: String) -> Self { .error(message, ok: .ok) }
}
