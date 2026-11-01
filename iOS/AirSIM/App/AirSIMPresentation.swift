import ComposableArchitecture
import Foundation

/// UIKit's read-only projection of a Store. Mutations send reducer actions; no
/// controller owns or receives the backend AppModel reference.
@MainActor
final class AirSIMPresentation {
    let store: StoreOf<AirSIMFeature>
    init(model: AppModel, settings: AppSettings) {
        let playback = CallRecordingPlayback()
        var state = AirSIMFeature.State(snapshot: AirSIMSnapshot(model: model, settings: settings, playback: playback))
        state.dialNumber = model.numberInput
        state.lastBackendNumber = model.numberInput
        state.settings.mode = ConnectionModePreference.selected()
        state.firstConnectionComplete = UserDefaults.standard.bool(forKey: "airsim.first-connection-complete")
        state.selectedTab = PhoneTab(rawValue: UserDefaults.standard.string(forKey: "airsim.selected-tab") ?? "") ?? .dial
        state.settings.appearance = settings.appearance
        state.settings.relayURL = RelayConfiguration.effectiveURL(stored: UserDefaults.standard.string(forKey: "airsim.push-relay-url"), buildSetting: Bundle.main.object(forInfoDictionaryKey: "AirSIMPushRelayURL") as? String, bundleID: Bundle.main.bundleIdentifier)
        state.settings.liveActivityEnabled = LiveActivityVisibilityPreference.isEnabled()
        state.settings.lastObservedMode = state.settings.mode
        state.settings.lastObservedAppearance = state.settings.appearance
        state.settings.lastObservedRelayURL = state.settings.relayURL
        state.settings.lastObservedLiveActivity = state.settings.liveActivityEnabled
        store = Store(initialState: state) { AirSIMFeature() } withDependencies: { $0.airSIM = .live(model: model, settings: settings, playback: playback) }
        store.send(.start)
    }
    init(store: StoreOf<AirSIMFeature>) { self.store = store }
    var snapshot: AirSIMSnapshot { store.snapshot }
    var numberInput: String { get { store.dialNumber } set { store.send(.numberChanged(newValue)) } }
    var contacts: ContactsPresentation { ContactsPresentation(owner: self) }
    var audio: AudioPresentation { AudioPresentation(owner: self) }
    var vowlan: VoWLANPresentation { VoWLANPresentation(owner: self) }
    var settings: SettingsPresentation { SettingsPresentation(owner: self) }
    var messages: [SMSMessage] { snapshot.messages }
    var conversations: [(sender: String, messages: [SMSMessage])] { snapshot.conversations.map { ($0.sender, $0.messages) } }
    var isOnline: Bool { snapshot.isOnline }
    var connectionMessage: String? { snapshot.connectionMessage }
    var isBusy: Bool { snapshot.isBusy }
    var isMuted: Bool { snapshot.isMuted }
    var isRecording: Bool { snapshot.isRecording }
    var isRecordingBusy: Bool { snapshot.isRecordingBusy }
    var modemStatus: ModemStatus? { snapshot.modemStatus }
    var cloudAgentStatus: CloudAgentStatus? { snapshot.cloudAgentStatus }
    var cloudCallAudioState: CloudCallAudioState { snapshot.cloudCallAudioState }
    var callLifecycleSnapshot: CallLifecycleSnapshot { snapshot.callLifecycleSnapshot }
    var inAppPresentedCall: CallRecord? { snapshot.inAppPresentedCall }
    var callAudioIsActive: Bool { snapshot.callAudioIsActive }
    var callAudioStatusText: String { snapshot.callAudioStatusText }
    var canStartOutgoingCommand: Bool { snapshot.canStartOutgoingCommand }
    var canToggleRecording: Bool { snapshot.canToggleRecording }
    var connectionModePresentation: ConnectionModePresentation { snapshot.connectionModePresentation }
    var pairedAndroidAgents: [AndroidAgentPresentation] { snapshot.pairedAndroidAgents }
    var currentAndroidAgent: AndroidAgentPresentation? { snapshot.currentAndroidAgent }
    var pairedDeviceHistory: [AndroidAgentPresentation] { snapshot.pairedDeviceHistory }
    func perform(_ command: AirSIMCommand) async { await store.send(.command(command)).finish() }
    func dial() async { await perform(.dialNumber(store.dialNumber)) }
    func answer() async { await perform(.answer) }
    func reject() async { await perform(.reject) }
    func hangup() async { await perform(.hangup) }
    func toggleMute() async { await perform(.mute) }
    func toggleSpeaker() { store.send(.command(.speaker)) }
    func toggleRecording() async { await perform(.recording) }
    func bindAndroidAgent(_ id: String) { store.send(.command(.bindAgent(id))) }
    func refreshMessages() async { await perform(.refreshMessages) }
    func loadMessagesFromAgent() async { await perform(.loadMessages) }
    func reloadMessagesFromLocalStore() { store.send(.command(.reloadLocalMessages)) }
    func refreshPairedDeviceInformation() async { await perform(.refreshDevices) }
    func setLiveActivityEnabled(_ enabled: Bool) { store.send(.settings(.liveActivityChanged(enabled))) }
    func presentCurrentCallInApp() { store.send(.command(.presentCall)) }
}

@MainActor
struct ContactsPresentation {
    let owner: AirSIMPresentation
    var contacts: [ContactStore.Contact] { owner.snapshot.contacts.all }
    var isAuthorized: Bool { owner.snapshot.contacts.isAuthorized }
    var authorizationState: ContactAuthorizationState { owner.snapshot.contacts.authorization }
    func contact(for number: String) -> ContactStore.Contact? { owner.snapshot.contacts.contact(for: number) }
    func displayName(for number: String?) -> String { owner.snapshot.contacts.displayName(for: number) }
    func loadIfAuthorized() async { await owner.perform(.contacts(false)) }
    func requestAccessAndLoad() async { await owner.perform(.contacts(true)) }
}
@MainActor
struct AudioPresentation {
    let owner: AirSIMPresentation
    var active: Bool { owner.snapshot.audioActive }
    var speakerEnabled: Bool { owner.snapshot.speakerEnabled }
    var routeDescription: String { owner.snapshot.audioRoute }
    var errorMessage: String? { owner.snapshot.audioError }
}
@MainActor
struct VoWLANPresentation {
    let owner: AirSIMPresentation
    var availability: VoWLANAvailability { owner.snapshot.vowlan }
}
@MainActor
struct SettingsPresentation {
    let owner: AirSIMPresentation
    var appearance: AppAppearance { get { owner.store.settings.appearance } nonmutating set { owner.store.send(.settings(.appearanceChanged(newValue))) } }
}
