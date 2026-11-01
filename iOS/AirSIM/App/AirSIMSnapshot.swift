import Foundation

/// Value-only projection: reducers never retain the observable backend or UIKit objects.
struct ConversationSnapshot: Equatable, Sendable { var sender: String; var messages: [SMSMessage] }

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
    var connectionModePresentation = ConnectionModePresentation.make(vowlanOnline: false, cloudModeEnabled: false, cloudOnline: false)
    var pairedAndroidAgents: [AndroidAgentPresentation] = []
    var currentAndroidAgent: AndroidAgentPresentation?
    var pairedDeviceHistory: [AndroidAgentPresentation] = []
    var contacts: [ContactStore.Contact] = []
    var contactsAuthorized = false
    var contactsAuthorization: ContactAuthorizationState = .notDetermined
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
    var playingRecordingID: UUID?

    @MainActor init(model: AppModel, settings: AppSettings, playback: CallRecordingPlayback) {
        preferenceMode = ConnectionModePreference.selected(); preferenceAppearance = settings.appearance
        preferenceLiveActivity = LiveActivityVisibilityPreference.isEnabled(); preferenceOnboardingComplete = UserDefaults.standard.bool(forKey: "airsim.first-connection-complete")
        preferenceRelayURL = RelayConfiguration.effectiveURL(stored: UserDefaults.standard.string(forKey: "airsim.push-relay-url"), buildSetting: Bundle.main.object(forInfoDictionaryKey: "AirSIMPushRelayURL") as? String, bundleID: Bundle.main.bundleIdentifier)
        callHistory = model.callHistory; isRefreshingCallHistory = model.isRefreshingCallHistory
        callHistoryMessage = model.callHistoryMessage; messages = model.messages; conversations = model.conversations.map { ConversationSnapshot(sender: $0.sender, messages: $0.messages) }
        numberInput = model.numberInput; isOnline = model.isOnline; connectionMessage = model.connectionMessage
        isBusy = model.isBusy; isMuted = model.isMuted; isRecording = model.isRecording; isRecordingBusy = model.isRecordingBusy
        errorMessage = model.errorMessage; modemStatus = model.modemStatus; cloudAgentStatus = model.cloudAgentStatus
        cloudCallAudioState = model.cloudCallAudioState; callLifecycleSnapshot = model.callLifecycleSnapshot
        inAppPresentedCall = model.inAppPresentedCall; callAudioIsActive = model.callAudioIsActive; callAudioStatusText = model.callAudioStatusText
        canStartOutgoingCommand = model.canStartOutgoingCommand; canToggleRecording = model.canToggleRecording
        connectionModePresentation = model.connectionModePresentation; pairedAndroidAgents = model.pairedAndroidAgents
        currentAndroidAgent = model.currentAndroidAgent; pairedDeviceHistory = model.pairedDeviceHistory
        contacts = model.contacts.contacts; contactsAuthorized = model.contacts.isAuthorized; contactsAuthorization = model.contacts.authorizationState
        audioActive = model.audio.active; speakerEnabled = model.audio.speakerEnabled; audioRoute = model.audio.routeDescription; audioError = model.audio.errorMessage
        vowlan = model.vowlan.availability; recordings = model.recordings.recordings; recordingsBusy = model.recordings.isBusy; playingRecordingID = playback.playingID; recordingURLs = Dictionary(uniqueKeysWithValues: recordings.map { ($0.id, model.recordings.url(for: $0)) })
    }
    init() {}
}
