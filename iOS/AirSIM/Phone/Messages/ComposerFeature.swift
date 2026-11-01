import ComposableArchitecture
import Foundation

@Reducer
struct ComposerFeature {
    @ObservableState struct State: Equatable {
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
        var canSend: Bool { !sending && !recipient.trimmingCharacters(in: .whitespaces).isEmpty && !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
    enum Action {
        case recipientChanged(String), bodyChanged(String), sendButtonTapped, cancelButtonTapped
        case chooseContactTapped
        case contactPicker(PresentationAction<ContactsFeature.Action>)
        case alert(PresentationAction<Alert>), delegate(Delegate)
        enum Alert: Equatable { case ok }
        /// MessagesFeature runs the send so closing the sheet cannot cancel an SMS the module may already have sent.
        enum Delegate { case send(id: UUID, to: String, body: String) }
    }
    @Dependency(\.dismiss) var dismiss
    @Dependency(\.uuid) var uuid
    var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .recipientChanged(let value): state.recipient = value; return .none
            case .bodyChanged(let value): state.body = value; return .none
            case .sendButtonTapped:
                guard state.canSend else { return .none }
                let id = uuid(); state.sendID = id
                return .send(.delegate(.send(id: id, to: state.recipient, body: state.body)))
            case .cancelButtonTapped: return .run { _ in await dismiss() }
            case .chooseContactTapped:
                state.contactPicker = ContactsFeature.State(mode: .pick, snapshot: state.$snapshot)
                return .none
            case .contactPicker(.presented(.delegate(.picked(let phone)))):
                state.recipient = phone
                state.contactPicker = nil
                return .none
            case .contactPicker, .alert, .delegate: return .none
            }
        }
        .ifLet(\.$alert, action: \.alert)
        .ifLet(\.$contactPicker, action: \.contactPicker) { ContactsFeature() }
    }
}

extension AlertState where Action == ComposerFeature.Action.Alert {
    static func sendFailed(_ message: String) -> Self { .error(message, ok: .ok) }
}
