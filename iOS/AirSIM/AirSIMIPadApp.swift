import UIKit

/// Notification infrastructure is installed before any foreground UI or AppModel is created.
@main
@MainActor
final class AirSIMIPadApp: AirSIMNotificationDelegate {
    override func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
#if DEBUG
        guard !AirSIMPreviewEnvironment.isActive else { return true }
#endif
        LiveActivityCallActionDispatcher.shared.handler = { action, callID in
            if CallKitController.shared.managesCurrentCall {
                try await CallKitController.shared.performLiveActivityAction(action, callID: callID)
            } else {
                try await AirSIMUIModel.shared.performLiveActivityAction(action, callID: callID)
            }
        }
        return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }
}

@MainActor
enum AirSIMUIModel {
    static let shared = AppModel()
    static let settings = AppSettings()
}

@MainActor
final class AirSIMSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private var root: RootViewController?
    private var pendingURLs: [URL] = []

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        window = UIWindow(windowScene: scene)
        pendingURLs = options.urlContexts.map(\.url)
        // A background-only PushKit launch must not construct contact caches or audio sessions.
        if UIApplication.shared.applicationState != .background { connectUI() }
    }

    private func connectUI() {
#if DEBUG
        guard !AirSIMPreviewEnvironment.isActive else { return }
#endif
        guard root == nil, let window else { return }
        let model = AirSIMUIModel.shared
        let controller = RootViewController(model: model, settings: AirSIMUIModel.settings)
        root = controller
        window.rootViewController = controller
        window.makeKeyAndVisible()
        WatchCallCoordinator.shared.configure(model: model)
        WatchCallCoordinator.shared.start()
        model.start(sceneIsActive: window.windowScene?.activationState == .foregroundActive)
        pendingURLs.forEach(controller.handleSystemCommunicationURL)
        pendingURLs.removeAll()
    }

    func sceneWillEnterForeground(_ scene: UIScene) { connectUI() }
    func sceneDidBecomeActive(_ scene: UIScene) {
#if DEBUG
        guard !AirSIMPreviewEnvironment.isActive else { return }
#endif
        connectUI()
        (UIApplication.shared.delegate as? AirSIMNotificationDelegate)?.applicationDidBecomeActive(UIApplication.shared)
        if root != nil { AirSIMUIModel.shared.didBecomeActive() }
        root?.consumePendingSMS()
    }
    func sceneWillResignActive(_ scene: UIScene) {
        if !UIApplication.shared.connectedScenes.contains(where: { $0 !== scene && $0.activationState == .foregroundActive }) { if root != nil { AirSIMUIModel.shared.willResignActive() } }
    }
    func sceneDidEnterBackground(_ scene: UIScene) {
        if !UIApplication.shared.connectedScenes.contains(where: { $0 !== scene && ($0.activationState == .foregroundActive || $0.activationState == .foregroundInactive) }) { if root != nil { AirSIMUIModel.shared.didEnterBackground() } }
    }
    func sceneDidDisconnect(_ scene: UIScene) { root?.model.store.send(.stop); root = nil; window = nil }
    func scene(_ scene: UIScene, openURLContexts contexts: Set<UIOpenURLContext>) {
        if let root { contexts.forEach { root.handleSystemCommunicationURL($0.url) } }
        else { pendingURLs.append(contentsOf: contexts.map(\.url)) }
    }
}
