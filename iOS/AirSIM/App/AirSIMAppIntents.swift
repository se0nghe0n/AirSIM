import AppIntents
import Foundation

enum AirSIMIntentError: Error, Equatable, CustomLocalizedStringResourceConvertible {
    case noCall, notRunning, invalidDigits, recordingUnavailable
    case muteFailed, digitsFailed, recordingFailed, syncFailed

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .noCall: "There is no AirSIM call right now. Start or answer an AirSIM call first."
        case .notRunning: "AirSIM is not running. Open AirSIM to connect to your Android phone."
        case .invalidDigits: "Send 1 to 32 keypad digits using only 0-9, * and #"
        case .recordingUnavailable: "Recording is available once the call is connected"
        case .muteFailed: "The microphone could not be changed. Try again from the call screen."
        case .digitsFailed: "The digits could not be sent. Check the connection to your Android phone."
        case .recordingFailed: "The recording could not be changed. Try again from the call screen."
        case .syncFailed:
            "Messages could not be synced. AirSIM syncs SMS over VoWLAN on the same Wi-Fi as your Android phone."
        }
    }
}

enum AirSIMCallControl {
    static let maxDigits = 32

    /// The call that answer, decline and end act on; a CallKit push the model has not adopted yet still counts.
    static func currentCallID(snapshot: CallLifecycleSnapshot, pushedCallID: String?) throws -> String {
        if snapshot.state.representsCall, snapshot.state != .ending, let callID = snapshot.callID, !callID.isEmpty {
            return callID
        }
        if let pushedCallID, !pushedCallID.isEmpty { return pushedCallID }
        throw AirSIMIntentError.noCall
    }

    /// Mute, speaker and keypad digits apply only while a call is connecting or connected.
    static func requireLiveCall(_ state: CallLifecycleState) throws {
        guard state == .connecting || state == .active else { throw AirSIMIntentError.noCall }
    }

    /// Whether a toggle must run to reach `requested`; a switch already in that state is left alone.
    static func needsToggle(current: Bool, requested: Bool) -> Bool {
        current != requested
    }

    static func digits(_ raw: String) throws -> [String] {
        let digits = raw.filter { !$0.isWhitespace }
        guard !digits.isEmpty, digits.count <= maxDigits, digits.allSatisfy({ "0123456789*#".contains($0) })
        else { throw AirSIMIntentError.invalidDigits }
        return digits.map(String.init)
    }
}

enum AirSIMConnectionStatus {
    /// Spoken status; never names a device, phone number or token.
    static func sentence(isRunning: Bool, summary: ModuleConnectionSummary) -> String {
        guard isRunning else { return "AirSIM is not running. Open AirSIM to connect to your Android phone." }
        switch summary {
        case .localOnline:
            return "AirSIM is connected to your Android phone on the local network, and the phone has cellular service."
        case .localOnlineNoService:
            return
                "AirSIM is connected to your Android phone on the local network, but the phone has no cellular service."
        case .cloudOnly:
            return "AirSIM reaches your Android phone through the cloud Relay."
        case .offline:
            return "AirSIM cannot reach your Android phone. Check that it is powered on and online."
        }
    }
}

enum AirSIMConnectionModeAppEnum: String, AppEnum {
    case vowlan, cloud, automatic

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Connection Mode"
    static let caseDisplayRepresentations: [AirSIMConnectionModeAppEnum: DisplayRepresentation] = [
        .vowlan: "VoWLAN",
        .cloud: "Cloud",
        .automatic: "Automatic",
    ]

    init(_ mode: AirSIMConnectionMode) {
        switch mode {
        case .vowlan: self = .vowlan
        case .cloud: self = .cloud
        case .automatic: self = .automatic
        }
    }

    var mode: AirSIMConnectionMode {
        switch self {
        case .vowlan: .vowlan
        case .cloud: .cloud
        case .automatic: .automatic
        }
    }
}

enum AirSIMTabAppEnum: String, AppEnum {
    case dial, recents, messages, contacts, settings

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "AirSIM Tab"
    static let caseDisplayRepresentations: [AirSIMTabAppEnum: DisplayRepresentation] = [
        .dial: "Dial",
        .recents: "Recents",
        .messages: "Messages",
        .contacts: "Contacts",
        .settings: "Settings",
    ]

    init(_ tab: PhoneTab) {
        switch tab {
        case .dial: self = .dial
        case .recents: self = .recents
        case .messages: self = .messages
        case .contacts: self = .contacts
        case .settings: self = .settings
        }
    }

    var phoneTab: PhoneTab {
        switch self {
        case .dial: .dial
        case .recents: .recents
        case .messages: .messages
        case .contacts: .contacts
        case .settings: .settings
        }
    }
}

@MainActor
private func dispatchToCurrentCall(_ action: AirSIMLiveActivityAction) async throws {
    let callID = try AirSIMCallControl.currentCallID(
        snapshot: AirSIMUIModel.shared.callLifecycleSnapshot,
        pushedCallID: CallKitController.shared.currentIncomingPush?.callID
    )
    try await LiveActivityCallActionDispatcher.shared.perform(action, callID: callID)
}

/// The model reports these failures through `errorMessage`; the intent throws a fixed message instead, because the
/// stored text can name a local address, and clears it so the app does not alert the same failure again.
@MainActor
private func throwIfFailed(_ model: AppModel, as error: AirSIMIntentError) throws {
    guard model.errorMessage != nil else { return }
    model.errorMessage = nil
    throw error
}

struct AnswerCurrentAirSIMCallIntent: AppIntent {
    static let title: LocalizedStringResource = "Answer AirSIM Call"
    static let description = IntentDescription(
        "Picks up the incoming AirSIM call that is ringing now and connects it to this device. AirSIM carries calls for the SIM in the paired Android phone, separate from this device's own phone line.",
        searchKeywords: ["pick up", "accept call", "Android phone", "SIM"]
    )

    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { .background }

    @MainActor
    func perform() async throws -> some IntentResult {
        try await dispatchToCurrentCall(.answer)
        return .result()
    }
}

struct DeclineCurrentAirSIMCallIntent: AppIntent {
    static let title: LocalizedStringResource = "Decline AirSIM Call"
    static let description = IntentDescription(
        "Rejects the incoming AirSIM call that is ringing now without picking it up, so the call to the SIM in the paired Android phone stops ringing.",
        searchKeywords: ["reject call", "ignore call", "Android phone", "SIM"]
    )

    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { .background }

    @MainActor
    func perform() async throws -> some IntentResult {
        try await dispatchToCurrentCall(.reject)
        return .result()
    }
}

struct EndCurrentAirSIMCallIntent: AppIntent {
    static let title: LocalizedStringResource = "End AirSIM Call"
    static let description = IntentDescription(
        "Hangs up the current AirSIM call on the SIM in the paired Android phone, whether it is ringing, dialing or connected.",
        searchKeywords: ["hang up", "end call", "Android phone", "SIM"]
    )

    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { .background }

    @MainActor
    func perform() async throws -> some IntentResult {
        try await dispatchToCurrentCall(.hangup)
        return .result()
    }
}

struct SetAirSIMMuteIntent: AppIntent {
    static let title: LocalizedStringResource = "Mute AirSIM Microphone"
    static let description = IntentDescription(
        "Silences or restores this device's microphone during an AirSIM call on the SIM in the paired Android phone. While muted, the other party cannot hear you.",
        searchKeywords: ["mute", "unmute", "microphone", "mic"]
    )

    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { .background }

    @Parameter(title: "Muted", description: "On mutes the microphone. Off unmutes it.")
    var muted: Bool

    init() {}
    init(muted: Bool) { self.muted = muted }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let model = AirSIMUIModel.shared
        try AirSIMCallControl.requireLiveCall(model.callLifecycleSnapshot.state)
        if AirSIMCallControl.needsToggle(current: model.isMuted, requested: muted) {
            model.errorMessage = nil
            await model.toggleMute()
            try throwIfFailed(model, as: .muteFailed)
        }
        return .result(dialog: muted ? "AirSIM call muted" : "AirSIM call unmuted")
    }
}

struct SetAirSIMSpeakerIntent: AppIntent {
    static let title: LocalizedStringResource = "Set AirSIM Speaker"
    static let description = IntentDescription(
        "Turns this device's loudspeaker on or off for the current AirSIM call, which runs on the SIM in the paired Android phone. Off returns audio to the receiver or a connected headset.",
        searchKeywords: ["speakerphone", "loudspeaker", "hands-free"]
    )

    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { .background }

    @Parameter(
        title: "Speaker On",
        description: "On plays the call through the loudspeaker. Off turns the loudspeaker off."
    )
    var enabled: Bool

    init() {}
    init(enabled: Bool) { self.enabled = enabled }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let model = AirSIMUIModel.shared
        try AirSIMCallControl.requireLiveCall(model.callLifecycleSnapshot.state)
        // Idempotent, and it also settles a route change still pending from an earlier toggle.
        model.audio.setSpeakerEnabled(enabled)
        return .result(dialog: enabled ? "Speaker on" : "Speaker off")
    }
}

struct SetAirSIMCallRecordingIntent: AppIntent {
    static let title: LocalizedStringResource = "Record AirSIM Conversation"
    static let description = IntentDescription(
        "Starts or stops saving an audio recording of an AirSIM call in progress on the SIM in the paired Android phone. Recordings are saved on this device and listed in AirSIM's Recents.",
        searchKeywords: ["record", "recording", "call recorder"]
    )

    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { .background }

    /// Recording a call or rerouting it must not be possible from a locked phone.
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresAuthentication }

    @Parameter(title: "Recording", description: "On starts recording the call. Off stops the recording.")
    var recording: Bool

    init() {}
    init(recording: Bool) { self.recording = recording }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let model = AirSIMUIModel.shared
        guard model.canToggleRecording else { throw AirSIMIntentError.recordingUnavailable }
        if AirSIMCallControl.needsToggle(current: model.isRecording, requested: recording) {
            model.errorMessage = nil
            await model.toggleRecording()
            try throwIfFailed(model, as: .recordingFailed)
        }
        return .result(dialog: recording ? "Recording the AirSIM call" : "AirSIM call recording stopped")
    }
}

struct SendAirSIMCallDigitsIntent: AppIntent {
    static let title: LocalizedStringResource = "Send AirSIM Keypad Digits"
    static let description = IntentDescription(
        "Sends keypad tones on the current AirSIM call, which runs on the SIM in the paired Android phone, as when pressing keys for a phone menu or a conference PIN.",
        searchKeywords: ["DTMF", "touch tones", "press", "extension", "PIN"]
    )

    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { .background }

    @Parameter(
        title: "Digits",
        description: "Keypad keys to press in order, using only 0-9, * and #, up to 32 keys. For example 1234#."
    )
    var digits: String

    init() {}
    init(digits: String) { self.digits = digits }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let model = AirSIMUIModel.shared
        let keys = try AirSIMCallControl.digits(digits)
        try AirSIMCallControl.requireLiveCall(model.callLifecycleSnapshot.state)
        model.errorMessage = nil
        for key in keys {
            await model.sendDTMF(key)
            try throwIfFailed(model, as: .digitsFailed)
        }
        return .result(dialog: "Digits sent")
    }
}

struct SetAirSIMConnectionModeIntent: AppIntent {
    static let title: LocalizedStringResource = "Set AirSIM Connection Mode"
    static let description = IntentDescription(
        "Chooses how AirSIM reaches the paired Android phone. VoWLAN uses only the same Wi-Fi or hotspot, Cloud uses only the internet Relay, and Automatic tries VoWLAN first, then Cloud.",
        searchKeywords: ["VoWLAN", "Wi-Fi", "hotspot", "cloud relay", "network"]
    )

    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { .background }

    /// Recording a call or rerouting it must not be possible from a locked phone.
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresAuthentication }

    @Parameter(title: "Mode", description: "VoWLAN, Cloud or Automatic.")
    var mode: AirSIMConnectionModeAppEnum

    init() {}
    init(mode: AirSIMConnectionModeAppEnum) { self.mode = mode }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        AirSIMUIModel.shared.setConnectionMode(mode.mode)
        return .result(dialog: "AirSIM connection mode set to \(mode.mode.title)")
    }
}

struct CheckAirSIMConnectionIntent: AppIntent {
    static let title: LocalizedStringResource = "Check AirSIM Connection"
    static let description = IntentDescription(
        "Tells whether AirSIM can reach the paired Android phone right now, over the local network or the cloud Relay, and whether the phone has cellular service.",
        searchKeywords: ["status", "connected", "online", "Android phone", "cellular"]
    )

    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { .background }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let model = AirSIMUIModel.shared
        let sentence = AirSIMConnectionStatus.sentence(isRunning: model.hasStarted, summary: model.connectionSummary)
        return .result(value: sentence, dialog: "\(sentence)")
    }
}

struct SyncAirSIMMessagesIntent: AppIntent {
    static let title: LocalizedStringResource = "Sync AirSIM Messages"
    static let description = IntentDescription(
        "Fetches new SMS from the SIM in the paired Android phone into AirSIM. It does not read any message aloud.",
        searchKeywords: ["refresh", "fetch", "SMS", "texts", "Android phone"]
    )

    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { .background }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let model = AirSIMUIModel.shared
        guard model.hasStarted else { throw AirSIMIntentError.notRunning }
        model.errorMessage = nil
        await model.refreshMessages()
        try throwIfFailed(model, as: .syncFailed)
        return .result(dialog: "AirSIM messages synced")
    }
}

struct OpenAirSIMTabIntent: AppIntent {
    static let title: LocalizedStringResource = "Go to AirSIM Tab"
    static let description = IntentDescription(
        "Brings the AirSIM app forward on one of its tabs, such as the dial pad, Recents, Contacts or Settings.",
        searchKeywords: ["show", "go to", "switch tab", "screen"]
    )

    static let openAppWhenRun = true

    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { .foreground }

    @Parameter(title: "Tab", description: "The AirSIM screen to show: Dial, Recents, Messages, Contacts or Settings.")
    var tab: AirSIMTabAppEnum

    init() {}
    init(tab: AirSIMTabAppEnum) { self.tab = tab }

    @MainActor
    func perform() async throws -> some IntentResult {
        AirSIMSceneDelegate.route(.tab(tab.phoneTab))
        return .result()
    }
}

struct AirSIMShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AnswerCurrentAirSIMCallIntent(),
            phrases: ["Answer \(.applicationName) call", "Answer with \(.applicationName)"],
            shortTitle: "Answer Call",
            systemImageName: "phone.fill"
        )
        AppShortcut(
            intent: DeclineCurrentAirSIMCallIntent(),
            phrases: ["Decline \(.applicationName) call"],
            shortTitle: "Decline Call",
            systemImageName: "phone.down.fill"
        )
        AppShortcut(
            intent: EndCurrentAirSIMCallIntent(),
            phrases: ["End \(.applicationName) call", "Hang up \(.applicationName)"],
            shortTitle: "End Call",
            systemImageName: "phone.down.fill"
        )
        AppShortcut(
            intent: SetAirSIMMuteIntent(muted: true),
            phrases: ["Mute \(.applicationName) call", "Mute \(.applicationName)"],
            shortTitle: "Mute Call",
            systemImageName: "mic.slash.fill"
        )
        AppShortcut(
            intent: CheckAirSIMConnectionIntent(),
            phrases: ["Check \(.applicationName) connection", "Is \(.applicationName) connected"],
            shortTitle: "Check Connection",
            systemImageName: "antenna.radiowaves.left.and.right"
        )
        AppShortcut(
            intent: SyncAirSIMMessagesIntent(),
            phrases: ["Sync \(.applicationName) messages"],
            shortTitle: "Sync Messages",
            systemImageName: "arrow.triangle.2.circlepath"
        )
        AppShortcut(
            intent: DraftAirSIMMessageIntent(),
            phrases: ["Text with \(.applicationName)", "Draft \(.applicationName) SMS"],
            shortTitle: "Draft SMS",
            systemImageName: "square.and.pencil"
        )
        AppShortcut(
            intent: OpenAirSIMTabIntent(),
            phrases: ["Open \(\.$tab) in \(.applicationName)", "Show \(.applicationName) \(\.$tab)"],
            shortTitle: "Open Tab",
            systemImageName: "square.grid.2x2"
        )
    }
}

// Siri may call these as tools. `@AppIntent(.tool)` is itself iOS 27.3-only and cannot mark an iOS 17 type.
// Check Connection and Sync Messages stay out: they need AirSIM already running, and tools must work whenever called.
@available(iOS 27.3, *) extension AnswerCurrentAirSIMCallIntent: ToolIntent {}
@available(iOS 27.3, *) extension DeclineCurrentAirSIMCallIntent: ToolIntent {}
@available(iOS 27.3, *) extension EndCurrentAirSIMCallIntent: ToolIntent {}
@available(iOS 27.3, *) extension SetAirSIMMuteIntent: ToolIntent {}
@available(iOS 27.3, *) extension SetAirSIMSpeakerIntent: ToolIntent {}
@available(iOS 27.3, *) extension SetAirSIMCallRecordingIntent: ToolIntent {}
@available(iOS 27.3, *) extension SendAirSIMCallDigitsIntent: ToolIntent {}
@available(iOS 27.3, *) extension SetAirSIMConnectionModeIntent: ToolIntent {}
@available(iOS 27.3, *) extension OpenAirSIMTabIntent: ToolIntent {}
