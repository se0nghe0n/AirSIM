import ComposableArchitecture
import Foundation

/// The Messages tab: the conversation list, the open thread with its reply, and the composer sheet. SMS sends
/// run here, so closing the screen that started one cannot cancel it.
@Reducer
struct MessagesFeature {
    @ObservableState
    struct State: Equatable {
        @SharedReader fileprivate var snapshot: AirSIMSnapshot
        var conversation: String?
        var reply = ""
        var sending = false
        var sendID: UUID?
        /// Belongs to the open conversation; it closes with it.
        @Presents var alert: AlertState<Action.Alert>?
        @Presents var composer: ComposerFeature.State?

        init(snapshot: SharedReader<AirSIMSnapshot>) {
            _snapshot = snapshot
        }

        var conversationRows: [ConversationRow] {
            snapshot.conversations.map { ConversationRow(conversation: $0, contacts: snapshot.contacts) }
        }

        var canSendReply: Bool {
            !sending && !reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        func threadTitle(for sender: String) -> String {
            snapshot.contacts.displayName(for: sender)
        }

        /// The sender's messages, oldest first.
        func messages(from sender: String) -> [SMSMessage] {
            snapshot.messages
                .filter { $0.sender == sender }
                .sorted { $0.timestamp < $1.timestamp }
        }

        /// An open composer keeps its draft and is only readdressed.
        mutating func compose(to recipient: String) {
            guard composer != nil else {
                composer = ComposerFeature.State(recipient: recipient, snapshot: $snapshot)
                return
            }
            // A send to the old recipient no longer belongs to this composer; a failure goes to the root alert.
            if composer?.recipient != recipient {
                composer?.sendID = nil
            }
            composer?.recipient = recipient
        }

        mutating func openConversation(_ sender: String) {
            // The composer's send keeps running; its result is dropped once the composer is gone.
            composer = nil
            // Re-opening the visible thread, e.g. from its SMS banner, keeps its draft and reply in flight.
            guard conversation != sender else { return }
            conversation = sender
            reply = ""
            alert = nil
            sendID = nil
            sending = false
        }
    }

    enum Action: ViewAction {
        case view(View)
        /// Sent by the app shell for an SMS banner or notification.
        case openConversation(String)
        /// Opens the composer, or readdresses an open one.
        case compose(String)
        case sendResponse(id: UUID, success: Bool, body: String, error: String? = nil)
        case composer(PresentationAction<ComposerFeature.Action>)
        case composerSendFinished(id: UUID, result: AirSIMMessageResult)
        case alert(PresentationAction<Alert>)
        case delegate(Delegate)

        enum View {
            case appeared
            case refreshTapped
            case clearConfirmed
            case composeTapped
            case conversationTapped(String)
            case threadLoaded(String)
            case threadClosed(String)
            case replyChanged(String)
            case sendTapped(to: String)
        }

        enum Alert: Equatable {
            case ok
        }

        @CasePathable
        enum Delegate {
            /// The compose button; the app shell selects this tab and waits for onboarding before composing.
            case compose(String)
            /// A failed send whose composer or thread can no longer show it; the root alert reports it instead.
            case unreportedSendFailure(String)
        }
    }

    @Dependency(\.airSIM) var client
    @Dependency(\.uuid) var uuid

    enum CancelID {
        case send
    }

    var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .view(.appeared):
                return .run { [client] _ in try await client.command(.loadMessages) }

            case .view(.refreshTapped):
                return .run { [client] _ in try await client.command(.refreshMessages) }

            case .view(.clearConfirmed):
                return .run { [client] _ in try await client.command(.clearMessages) }

            case .view(.composeTapped):
                return .send(.delegate(.compose("")))

            case .view(.conversationTapped(let sender)),
                 .view(.threadLoaded(let sender)):
                guard state.conversation != sender else { return .none }
                state.openConversation(sender)
                return .none

            case .view(.threadClosed(let sender)):
                // A replaced thread reports closing after its successor has opened.
                guard state.conversation == sender else { return .none }
                state.conversation = nil
                state.alert = nil
                state.sendID = nil
                state.sending = false
                return .none

            case .view(.replyChanged(let value)):
                state.reply = value
                return .none

            case .view(.sendTapped(let to)):
                let body = state.reply
                guard !state.sending,
                      !to.trimmingCharacters(in: .whitespaces).isEmpty,
                      !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else { return .none }
                let id = uuid()
                state.sendID = id
                state.sending = true
                state.alert = nil
                return .run { [client] send in
                    let result = await client.sendSMS(to, body)
                    await send(.sendResponse(id: id, success: result.success, body: body, error: result.error))
                }
                .cancellable(id: CancelID.send)

            case .openConversation(let sender):
                state.openConversation(sender)
                return .none

            case .compose(let recipient):
                state.compose(to: recipient)
                return .none

            case let .sendResponse(id, success, body, error):
                guard state.sendID == id else { return success ? .none : unreported(error) }
                state.sendID = nil
                state.sending = false
                if success {
                    if state.reply == body {
                        state.reply = ""
                    }
                    return .none
                }
                let message = error ?? "Unable to send message. Your draft has been kept."
                // Presenting from the thread would dismiss the composer sheet above it; the root alert shows above
                // the sheet.
                if state.composer != nil {
                    return .send(.delegate(.unreportedSendFailure(message)))
                }
                state.alert = .sendFailed(message)
                return .none

            case let .composer(.presented(.delegate(.send(id, to, body)))):
                // Not tied to the composer's presentation: closing the sheet must not cancel or forget an SMS in
                // flight.
                return .run { [client] send in
                    await send(.composerSendFinished(id: id, result: await client.sendSMS(to, body)))
                }

            case let .composerSendFinished(id, result):
                guard state.composer?.sendID == id else { return result.success ? .none : unreported(result.error) }
                if result.success {
                    state.composer = nil
                    return .none
                }
                state.composer?.sendID = nil
                state.composer?.alert = .sendFailed(result.error ?? "Unable to send message. Your draft has been kept.")
                return .none

            case .composer, .alert, .delegate:
                return .none
            }
        }
        .ifLet(\.$alert, action: \.alert)
        .ifLet(\.$composer, action: \.composer) { ComposerFeature() }
    }

    /// The screen that kept the draft is gone, so the copy does not promise one.
    private func unreported(_ error: String?) -> Effect<Action> {
        .send(.delegate(.unreportedSendFailure(error ?? "Unable to send message.")))
    }
}

extension AlertState where Action == MessagesFeature.Action.Alert {
    static func sendFailed(_ message: String) -> Self { .error(message, ok: .ok) }
}
