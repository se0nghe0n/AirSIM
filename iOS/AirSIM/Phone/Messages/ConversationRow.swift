import Foundation

/// One conversation in the Messages list, ready to draw.
struct ConversationRow: Equatable, Identifiable {
    let sender: String
    /// The contact's name, else the number, else "Unknown Number".
    let name: String
    let photo: Data?
    /// Empty when the sender is not a contact, so the avatar shows the generic person glyph.
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
    /// The plain-cell text: the last message over its time.
    var detail: String { "\(lastMessage)\n\(time)" }
}
