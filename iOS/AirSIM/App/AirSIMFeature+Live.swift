import ComposableArchitecture
import Foundation

extension AirSIMFeature {
    /// The app's store, already receiving snapshots. The client and the snapshots share one playback, so snapshots
    /// report the recording the client plays.
    @MainActor
    static func liveStore(model: AppModel, settings: AppSettings) -> StoreOf<AirSIMFeature> {
        let playback = CallRecordingPlayback()
        let snapshot = AirSIMSnapshot(model: model, settings: settings, playback: playback)
        var state = State(snapshot: snapshot)
        state.firstConnectionComplete = snapshot.preferenceOnboardingComplete
        let savedTab = UserDefaults.standard.string(forKey: "airsim.selected-tab") ?? ""
        state.selectedTab = PhoneTab(rawValue: savedTab) ?? .dial
#if DEBUG
        state.activeCall.layoutPreviewCall = .layoutPreview(arguments: ProcessInfo.processInfo.arguments)
#endif
        let store = Store(initialState: state) {
            AirSIMFeature()
        } withDependencies: {
            $0.airSIM = .live(model: model, settings: settings, playback: playback)
        }
        store.send(.start)
        return store
    }
}
