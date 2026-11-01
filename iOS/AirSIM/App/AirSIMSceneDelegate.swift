import UIKit

/// Owns the window for the app's single scene. A background-only PushKit launch connects the scene
/// without building UI; RootViewController and AppModel start on the first foreground transition.
///
/// The class name is referenced by `UISceneDelegateClassName` in Info.plist and by persisted scene
/// sessions, so keep it stable. Sessions saved by the SwiftUI app lifecycle of earlier builds are
/// restored with SwiftUI's scene delegate, which builds no window; `adoptRestoredScene(_:)` replaces it.
@MainActor
final class AirSIMSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private var root: RootViewController?
    private var pendingURLs: [URL] = []

    /// iOS keeps a scene session across app updates and restores it with the configuration it was created with. A
    /// session from a build that used the SwiftUI `App` lifecycle comes back with SwiftUI's scene delegate and no
    /// configuration name, so `scene(_:willConnectTo:options:)` here never runs and the screen stays black. Called for
    /// every scene connection; a scene that already has this delegate is left alone.
    static func adoptRestoredScene(_ scene: UIWindowScene) {
        guard !(scene.delegate is AirSIMSceneDelegate) else { return }
        let delegate = AirSIMSceneDelegate()
        // UIScene holds its delegate strongly.
        scene.delegate = delegate
        delegate.attach(to: scene, urls: [])
    }

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        attach(to: scene, urls: options.urlContexts.map(\.url))
    }

    /// Idempotent: an adopted scene may still receive `scene(_:willConnectTo:options:)` afterwards.
    private func attach(to scene: UIWindowScene, urls: [URL]) {
        if window == nil { window = UIWindow(windowScene: scene) }
        if let root {
            urls.forEach(root.handleSystemCommunicationURL)
            return
        }
        pendingURLs.append(contentsOf: urls)
        // A background-only PushKit launch must not construct contact caches or audio sessions.
        if UIApplication.shared.applicationState != .background { connectUI() }
    }

    private func connectUI() {
        #if DEBUG
        guard !AirSIMPreviewEnvironment.isActive else { return }
        #endif
        guard root == nil, let window else { return }
        let model = AirSIMUIModel.shared
        let store = AirSIMFeature.liveStore(model: model, settings: AirSIMUIModel.settings)
        let controller = RootViewController(store: store)
        root = controller
        window.rootViewController = controller
        window.makeKeyAndVisible()
        WatchCallCoordinator.shared.configure(model: model)
        WatchCallCoordinator.shared.start()
        model.start(sceneIsActive: window.windowScene?.activationState == .foregroundActive)
        pendingURLs.forEach(controller.handleSystemCommunicationURL)
        pendingURLs.removeAll()
    }

    func sceneWillEnterForeground(_ scene: UIScene) {
        connectUI()
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        #if DEBUG
        guard !AirSIMPreviewEnvironment.isActive else { return }
        #endif
        connectUI()
        // Scene-based apps no longer receive applicationDidBecomeActive on the app delegate.
        (UIApplication.shared.delegate as? AirSIMAppDelegate)?.applicationDidBecomeActive(UIApplication.shared)
        if root != nil {
            AirSIMUIModel.shared.didBecomeActive()
        }
        root?.consumePendingSMS()
    }

    func sceneWillResignActive(_ scene: UIScene) {
        guard root != nil, !anotherScene(than: scene, isIn: [.foregroundActive]) else { return }
        AirSIMUIModel.shared.willResignActive()
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        guard root != nil, !anotherScene(than: scene, isIn: [.foregroundActive, .foregroundInactive]) else { return }
        AirSIMUIModel.shared.didEnterBackground()
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        root?.store.send(.stop)
        root = nil
        window = nil
    }

    func scene(_ scene: UIScene, openURLContexts contexts: Set<UIOpenURLContext>) {
        guard let root else {
            pendingURLs.append(contentsOf: contexts.map(\.url))
            return
        }
        contexts.forEach { root.handleSystemCommunicationURL($0.url) }
    }

    private func anotherScene(than scene: UIScene, isIn states: Set<UIScene.ActivationState>) -> Bool {
        UIApplication.shared.connectedScenes.contains { $0 !== scene && states.contains($0.activationState) }
    }
}
