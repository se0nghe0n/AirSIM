import Foundation

struct ConversationRow: Equatable, Identifiable {
    let sender: String
    let name: String
    let photo: Data?
    let avatarName: String
    let lastMessage: String
    let time: String

    init(conversation: ConversationSnapshot, contacts: ContactDirectory) {
        let contact = contacts.contact(for: conversation.sender)
        let name = contact?.name ?? contacts.displayName(for: conversation.sender)
        let last = conversation.messages.last
        sender = conversation.sender
        self.name = name
        photo = contact?.photoData
        avatarName = contact == nil ? "" : name
        lastMessage = last?.content ?? ""
        time = (last?.timestamp ?? .now).formatted(date: .omitted, time: .shortened)
    }

    var id: String { sender }
    var detail: String { "\(lastMessage)\n\(time)" }
}
