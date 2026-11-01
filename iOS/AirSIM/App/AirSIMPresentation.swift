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
#if DEBUG
        state.activeCall.layoutPreviewCall = .layoutPreview(arguments: ProcessInfo.processInfo.arguments)
#endif
        store = Store(initialState: state) { AirSIMFeature() } withDependencies: { $0.airSIM = .live(model: model, settings: settings, playback: playback) }
        store.send(.start)
    }
    init(store: StoreOf<AirSIMFeature>) { self.store = store }
    var snapshot: AirSIMSnapshot { store.snapshot }
    func reloadMessagesFromLocalStore() { store.send(.command(.reloadLocalMessages)) }
    func presentCurrentCallInApp() { store.send(.command(.presentCall)) }
}
