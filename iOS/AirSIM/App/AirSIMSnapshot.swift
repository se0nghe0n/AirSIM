import Foundation

struct ConversationSnapshot: Equatable, Sendable {
    var sender: String
    var messages: [SMSMessage]
}

struct AirSIMSnapshot: Equatable, Sendable {
    var callHistory: [CallRecord] = []
    var isRefreshingCallHistory = false
    var callHistoryMessage: String?
    var messages: [SMSMessage] = []
    var conversations: [ConversationSnapshot] = []
    var numberInput = ""
    var isOnline = false
    var connectionMessage: String?
    var isBusy = false
    var isMuted = false
    var isRecording = false
    var isRecordingBusy = false
    var errorMessage: String?
    var modemStatus: ModemStatus?
    var cloudAgentStatus: CloudAgentStatus?
    var cloudCallAudioState: CloudCallAudioState = .idle
    var callLifecycleSnapshot: CallLifecycleSnapshot = .idle
    var inAppPresentedCall: CallRecord?
    var callAudioIsActive = false
    var callAudioStatusText = ""
    var canStartOutgoingCommand = false
    var canToggleRecording = false

    var connectionModePresentation = ConnectionModePresentation.make(
        vowlanOnline: false,
        cloudModeEnabled: false,
        cloudOnline: false
    )

    var pairedAndroidAgents: [AndroidAgentPresentation] = []
    var currentAndroidAgent: AndroidAgentPresentation?
    var pairedDeviceHistory: [AndroidAgentPresentation] = []
    var contacts = ContactDirectory()
    var audioActive = false
    var speakerEnabled = false
    var audioRoute = ""
    var audioError: String?
    var vowlan: VoWLANAvailability = .unpaired
    var recordings: [CallRecordingFile] = []
    var recordingsBusy = false
    var recordingURLs: [UUID: URL] = [:]
    var preferenceMode = AirSIMConnectionMode.automatic
    var preferenceAppearance = AppAppearance.system
    var preferenceLiveActivity = true
    var preferenceRelayURL = ""
    var preferenceOnboardingComplete = false
    var cloudModeEnabled = true
    var playingRecordingID: UUID?

    init() {}

    @MainActor
    init(model: AppModel, settings: AppSettings, playback: CallRecordingPlayback) {
        let defaults = UserDefaults.standard
        preferenceMode = ConnectionModePreference.selected()
        preferenceAppearance = settings.appearance
        preferenceLiveActivity = LiveActivityVisibilityPreference.isEnabled()
        preferenceOnboardingComplete = defaults.bool(forKey: "airsim.first-connection-complete")
        preferenceRelayURL = RelayConfiguration.effectiveURL(
            stored: defaults.string(forKey: "airsim.push-relay-url"),
            buildSetting: Bundle.main.object(forInfoDictionaryKey: "AirSIMPushRelayURL") as? String,
            bundleID: Bundle.main.bundleIdentifier
        )
        cloudModeEnabled = CloudModePreference.isEnabled()

        callHistory = model.callHistory
        isRefreshingCallHistory = model.isRefreshingCallHistory
        callHistoryMessage = model.callHistoryMessage
        messages = model.messages
        conversations = model.conversations.map { ConversationSnapshot(sender: $0.sender, messages: $0.messages) }
        numberInput = model.numberInput
        isOnline = model.isOnline
        connectionMessage = model.connectionMessage
        isBusy = model.isBusy
        isMuted = model.isMuted
        isRecording = model.isRecording
        isRecordingBusy = model.isRecordingBusy
        errorMessage = model.errorMessage
        modemStatus = model.modemStatus
        cloudAgentStatus = model.cloudAgentStatus
        cloudCallAudioState = model.cloudCallAudioState
        callLifecycleSnapshot = model.callLifecycleSnapshot
        inAppPresentedCall = model.inAppPresentedCall
        callAudioIsActive = model.callAudioIsActive
        callAudioStatusText = model.callAudioStatusText
        canStartOutgoingCommand = model.canStartOutgoingCommand
        canToggleRecording = model.canToggleRecording
        connectionModePresentation = model.connectionModePresentation
        pairedAndroidAgents = model.pairedAndroidAgents
        currentAndroidAgent = model.currentAndroidAgent
        pairedDeviceHistory = model.pairedDeviceHistory

        contacts = ContactDirectory(
            all: model.contacts.contacts,
            isAuthorized: model.contacts.isAuthorized,
            authorization: model.contacts.authorizationState
        )

        audioActive = model.audio.active
        speakerEnabled = model.audio.speakerEnabled
        audioRoute = model.audio.routeDescription
        audioError = model.audio.errorMessage
        vowlan = model.vowlan.availability

        recordings = model.recordings.recordings
        recordingsBusy = model.recordings.isBusy
        recordingURLs = Dictionary(uniqueKeysWithValues: recordings.map { ($0.id, model.recordings.url(for: $0)) })
        playingRecordingID = playback.playingID
    }
}
