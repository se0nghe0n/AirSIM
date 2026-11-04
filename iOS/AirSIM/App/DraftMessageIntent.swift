import AppIntents
import Foundation
import GeoToolbox

@available(iOS 27.0, *)
@UnionValue
enum AirSIMMessageDestination {
    case people([IntentPerson])
}

@available(iOS 27.0, *)
enum MessageDraftPolicy {
    static func draft(
        people: [IntentPerson]?,
        content: AttributedString?,
        subject: AttributedString?,
        hasNonTextContent: Bool
    ) throws -> MessageDraft {
        guard !hasNonTextContent, subject.map({ $0.characters.isEmpty }) ?? true else {
            throw MessageDraftError.unsupportedContent
        }
        let body = content.map { String($0.characters) } ?? ""
        let people = people ?? []
        guard people.count <= 1 else { throw MessageDraftError.multipleRecipients }
        guard let person = people.first else { return MessageDraft(recipient: "", body: body) }
        let number = AppModel.validatedNumber(person.firstPhoneNumber ?? "")
        guard !number.isEmpty else { throw MessageDraftError.noPhoneNumber }
        return MessageDraft(recipient: number, body: body)
    }
}

@available(iOS 27.0, *)
enum MessageDraftError: Error, CustomLocalizedStringResourceConvertible {
    case noPhoneNumber, multipleRecipients, unsupportedContent

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .noPhoneNumber: "This contact has no phone number AirSIM can text"
        case .multipleRecipients: "AirSIM sends SMS to one recipient at a time"
        case .unsupportedContent: "AirSIM sends text-only SMS without a subject, attachments or a scheduled time"
        }
    }
}

/// The build warns that the Message Sending use case lacks `messages.sendMessage`. AirSIM leaves it out on purpose:
/// that schema returns stored message bodies to the system.
@available(iOS 27.0, *)
@AppIntent(schema: .messages.draftMessage)
struct DraftAirSIMMessageIntent {
    var destination: AirSIMMessageDestination?
    var subject: AttributedString?
    var content: AttributedString?
    var attachments: [IntentFile]
    var audioMessage: IntentFile?
    var locations: [GeoToolbox.PlaceDescriptor]
    var links: [URL]
    var scheduledDate: Date?

    static var supportedModes: IntentModes { .foreground }

    @MainActor
    func perform() async throws -> some IntentResult {
        let people: [IntentPerson]?
        switch destination {
        case .people(let value): people = value
        case nil: people = nil
        }
        let draft = try MessageDraftPolicy.draft(
            people: people,
            content: content,
            subject: subject,
            hasNonTextContent: !attachments.isEmpty || audioMessage != nil || !locations.isEmpty
                || !links.isEmpty || scheduledDate != nil
        )
        AirSIMSceneDelegate.route(.draft(draft))
        return .result()
    }
}
