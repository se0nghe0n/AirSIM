import AppIntents

enum MessageDraftPolicy {
    static func draft(person: IntentPerson?, text: String?) throws -> MessageDraft {
        let body = text ?? ""
        guard let person else { return MessageDraft(recipient: "", body: body) }
        let number = AppModel.validatedNumber(person.firstPhoneNumber ?? "")
        guard !number.isEmpty else { throw MessageDraftError.noPhoneNumber }
        return MessageDraft(recipient: number, body: body)
    }
}

enum MessageDraftError: Error, CustomLocalizedStringResourceConvertible {
    case noPhoneNumber

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .noPhoneNumber: "This contact has no phone number AirSIM can text. Choose a contact with a phone number."
        }
    }
}

struct DraftAirSIMMessageIntent: AppIntent {
    static let title: LocalizedStringResource = "Draft AirSIM SMS"
    static let description = IntentDescription(
        "Opens AirSIM's SMS composer with a recipient and text filled in, to text from the SIM in the paired Android phone. This tool never sends. The person reviews the SMS and taps Send in AirSIM. It does not use the built-in Messages app.",
        searchKeywords: ["SMS", "text", "text message", "Android", "SIM"]
    )

    static let openAppWhenRun = true

    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { .foreground }

    @Parameter(
        title: "Recipient",
        description: "The person to text. AirSIM uses their phone number. Leave empty to choose the recipient in AirSIM.",
        mode: .phone
    )
    var recipient: IntentPerson?

    @Parameter(title: "Text", description: "The plain-text SMS body to fill in. The person can edit it before sending.")
    var text: String?

    @MainActor
    func perform() async throws -> some IntentResult {
        AirSIMSceneDelegate.route(.draft(try MessageDraftPolicy.draft(person: recipient, text: text)))
        return .result()
    }
}

@available(iOS 27.3, *) extension DraftAirSIMMessageIntent: ToolIntent {}
