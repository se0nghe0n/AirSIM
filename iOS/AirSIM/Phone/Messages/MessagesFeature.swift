import ComposableArchitecture
import Foundation

@Reducer
struct MessagesFeature {
    @ObservableState struct State: Equatable {
        var conversation: String?
        var reply = ""
        var sending = false
        var sendID: UUID?
        /// Belongs to the open conversation; it closes with it.
        @Presents var alert: AlertState<Action.Alert>?
        @Presents var composer: ComposerFeature.State?
        /// An open composer keeps its draft and is only readdressed.
        mutating func compose(to recipient: String) {
            guard composer != nil else { composer = ComposerFeature.State(recipient: recipient); return }
            // A send to the old recipient no longer belongs to this composer; a failure goes to the root alert.
            if composer?.recipient != recipient { composer?.sendID = nil }
            composer?.recipient = recipient
        }
    }
    enum Action {
        case compose(String), openConversation(String), closeConversation
        case replyChanged(String), sendReply(to: String), sendResponse(id: UUID, success: Bool, body: String, error: String? = nil)
        case composer(PresentationAction<ComposerFeature.Action>), composerSendFinished(id: UUID, result: AirSIMMessageResult)
        case alert(PresentationAction<Alert>), delegate(Delegate)
        enum Alert: Equatable { case ok }
        /// A failed send whose composer or thread can no longer show it; the root alert reports it instead.
        @CasePathable enum Delegate { case unreportedSendFailure(String) }
    }
    @Dependency(\.airSIM) var client
    @Dependency(\.uuid) var uuid
    enum CancelID { case send }
    var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .compose(let recipient): state.compose(to: recipient); return .none
            case .openConversation(let sender):
                // The composer's send keeps running; its result is dropped once the composer is gone.
                state.composer = nil
                // Re-opening the visible thread, e.g. from its SMS banner, keeps its draft and reply in flight.
                guard state.conversation != sender else { return .none }
                state.conversation = sender; state.reply = ""; state.alert = nil; state.sendID = nil; state.sending = false; return .none
            case .closeConversation: state.conversation = nil; state.alert = nil; state.sendID = nil; state.sending = false; return .none
            case .replyChanged(let value): state.reply = value; return .none
            case .sendReply(let to):
                let body = state.reply
                guard !state.sending, !to.trimmingCharacters(in: .whitespaces).isEmpty, !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .none }
                let id = uuid(); state.sendID = id; state.sending = true; state.alert = nil
                return .run { [client] send in
                    let result = await client.sendSMS(to, body)
                    await send(.sendResponse(id: id, success: result.success, body: body, error: result.error))
                }.cancellable(id: CancelID.send)
            case let .sendResponse(id, success, body, error):
                guard state.sendID == id else { return success ? .none : unreported(error) }
                state.sendID = nil; state.sending = false
                if success { if state.reply == body { state.reply = "" }; return .none }
                let message = error ?? "Unable to send message. Your draft has been kept."
                // Presenting from the thread would dismiss the composer sheet above it; the root alert shows above the sheet.
                if state.composer != nil { return .send(.delegate(.unreportedSendFailure(message))) }
                state.alert = .sendFailed(message); return .none
            case let .composer(.presented(.delegate(.send(id, to, body)))):
                // Not tied to the composer's presentation: closing the sheet must not cancel or forget an SMS in flight.
                return .run { [client] send in await send(.composerSendFinished(id: id, result: await client.sendSMS(to, body))) }
            case let .composerSendFinished(id, result):
                guard state.composer?.sendID == id else { return result.success ? .none : unreported(result.error) }
                if result.success { state.composer = nil; return .none }
                state.composer?.sendID = nil; state.composer?.alert = .sendFailed(result.error ?? "Unable to send message. Your draft has been kept.")
                return .none
            case .composer, .alert, .delegate: return .none
            }
        }
        .ifLet(\.$alert, action: \.alert)
        .ifLet(\.$composer, action: \.composer) { ComposerFeature() }
    }
    /// The screen that kept the draft is gone, so the copy does not promise one.
    private func unreported(_ error: String?) -> Effect<Action> { .send(.delegate(.unreportedSendFailure(error ?? "Unable to send message."))) }
}

extension AlertState where Action == MessagesFeature.Action.Alert {
    static func sendFailed(_ message: String) -> Self { .error(message, ok: .ok) }
}
