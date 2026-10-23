import SwiftUI

/// AirSIM iPhone/iPad entry point: Samsung VoWLAN and standalone cloud Relay.
@main
struct AirSIMIPadApp: App {
    @UIApplicationDelegateAdaptor(AirSIMNotificationDelegate.self) private var appDelegate
    @State private var settings = AppSettings()
    @Environment(\.scenePhase) private var scenePhase

    /// Preserves the lazy timing of @StateObject: AppModel is created only on first body evaluation,
    /// so didFinishLaunching can still install the CallKit cold-launch handler when handler is nil,
    /// and lock-screen PushKit wakeups do not eagerly build contact caches or audio sessions.
    @MainActor private enum AppModelHolder {
        static let shared = AppModel()
    }
    private var model: AppModel { AppModelHolder.shared }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .environment(model.contacts)
                .environment(model.audio)
                .environment(settings)
                .onAppear {
                    WatchCallCoordinator.shared.configure(model: model)
                    WatchCallCoordinator.shared.start()
                    model.start(sceneIsActive: scenePhase == .active)
                }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                model.didBecomeActive()
            case .inactive:
                // Start the audio session before actually entering the background; waiting until
                // .background may allow iOS to freeze the process so incoming calls and SMS cannot be awaited.
                model.willResignActive()
            case .background:
                model.didEnterBackground()
            default:
                break
            }
        }
    }
}
