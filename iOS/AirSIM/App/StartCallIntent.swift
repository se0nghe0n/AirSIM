import AppIntents

@available(iOS 27.0, *)
@AppEntity(schema: .phone.phonePerson)
struct AirSIMCallPerson: TransientAppEntity {
    var person: IntentPerson

    var displayRepresentation: DisplayRepresentation { person.displayRepresentation }
}

@available(iOS 27.0, *)
@UnionValue
enum AirSIMCallDestination {
    case person(AirSIMCallPerson)
}

@available(iOS 27.0, *)
@AppEnum(schema: .phone.audioVisualMode)
enum AirSIMCallMode: String {
    case audio, video

    static let caseDisplayRepresentations: [AirSIMCallMode: DisplayRepresentation] = [
        .audio: "Audio",
        .video: "Video",
    ]
}

@available(iOS 27.0, *)
enum StartCallPolicy {
    static func number(for person: IntentPerson, mode: AirSIMCallMode) throws -> String {
        guard mode == .audio else { throw StartCallError.videoUnsupported }
        let number = AppModel.validatedNumber(firstPhoneNumber(of: person) ?? "")
        guard !number.isEmpty else { throw StartCallError.noPhoneNumber }
        return number
    }

    private static func firstPhoneNumber(of person: IntentPerson) -> String? {
        for handle in [person.handle].compactMap({ $0 }) + person.aliases {
            if case .phoneNumber(let value) = handle.value { return value }
        }
        return nil
    }
}

@available(iOS 27.0, *)
enum StartCallError: Error, CustomLocalizedStringResourceConvertible {
    case videoUnsupported, noPhoneNumber, notPlaced

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .videoUnsupported: "AirSIM supports audio calls only"
        case .noPhoneNumber: "This contact has no phone number AirSIM can dial"
        case .notPlaced: "The call could not be placed. Check the connection to your Android phone."
        }
    }
}

@available(iOS 27.0, *)
@AppIntent(schema: .phone.startCall)
struct StartAirSIMCallIntent {
    var destination: AirSIMCallDestination
    var audioVisualMode: AirSIMCallMode

    static var supportedModes: IntentModes { .foreground }

    @MainActor
    func perform() async throws -> some IntentResult {
        let person: IntentPerson
        switch destination {
        case .person(let callPerson): person = callPerson.person
        }
        let model = AirSIMUIModel.shared
        model.numberInput = try StartCallPolicy.number(for: person, mode: audioVisualMode)
        guard await model.dial() else { throw StartCallError.notPlaced }
        return .result()
    }
}
