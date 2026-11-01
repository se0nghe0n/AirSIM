import ComposableArchitecture
import UIKit

@MainActor
final class RootViewController: ObservingViewController, UITabBarControllerDelegate {
    override var observesWhileHidden: Bool { true }
    let model: AirSIMPresentation
    @UIBindable private var store: StoreOf<AirSIMFeature>
    let settings: SettingsPresentation
    let tabs = UITabBarController()
    override var childForStatusBarStyle: UIViewController? { tabs }
    private var messages: MessagesViewController!
    /// Hosts the in-app call surface above the main window; nil while no call is presented in app.
    private(set) var callWindow: UIWindow?
    /// The window the call window covers; hidden from VoiceOver until the call window closes.
    private weak var callHostWindow: UIWindow?
    var activeCallController: ActiveCallViewController? { (callWindow?.rootViewController as? ActiveCallContainerViewController)?.call }
    private var notificationTokens: [NSObjectProtocol] = []
    /// Shows `store.alert`; nil once it leaves the screen, so a dismissal it did not ask for shows it again.
    private var alertController: StateAlertController?
    private var firstConnection: UINavigationController?
    private var appliedConversation: String?
#if DEBUG
    private var isPreview = false
    init(previewPresentation: AirSIMPresentation) {
        model = previewPresentation
        store = previewPresentation.store
        settings = previewPresentation.settings
        isPreview = true
        super.init(nibName: nil, bundle: nil)
    }
#endif
    init(model: AppModel, settings: AppSettings) { let presentation = AirSIMPresentation(model: model, settings: settings); self.model = presentation; store = presentation.store; self.settings = presentation.settings; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        messages = MessagesViewController(store: store.scope(state: \.messages, action: \.messages))
        let controllers: [UIViewController] = [
            DialPadViewController(store: store.scope(state: \.dial, action: \.dial)),
            RecentsViewController(store: store.scope(state: \.recents, action: \.recents)),
            messages,
            ContactsViewController(store: store.scope(state: \.contacts, action: \.contacts)),
            AirSIMSettingsViewController(model: model, settings: settings),
        ]
        tabs.viewControllers = zip(PhoneTab.allCases, controllers).map { tab, controller in
            let nav = UINavigationController(rootViewController: controller)
            nav.navigationBar.prefersLargeTitles = true
            nav.tabBarItem = UITabBarItem(title: tab.rawValue, image: UIImage(systemName: tab.icon), tag: 0)
            return nav
        }
        tabs.delegate = self
        // Replaces any other root sheet; requests made during onboarding wait in state until it completes.
        present(item: $store.scope(\.messages.$composer, action: \.messages.composer)) {
            phoneSheet(MessageComposerViewController(store: $0))
        }
        if #available(iOS 26.0, *) { tabs.tabBarMinimizeBehavior = .onScrollDown }
        tabs.selectedIndex = PhoneTab.allCases.firstIndex(of: model.store.selectedTab) ?? 0
        addChild(tabs); tabs.view.frame = view.bounds; tabs.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]; view.addSubview(tabs.view); tabs.didMove(toParent: self)
        let center = NotificationCenter.default
        for name in [Notification.Name.airsimRemoteSMSReceived, .airsimOpenSMSConversation, .airsimOpenIncomingCall] {
            notificationTokens.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                Task { @MainActor in
                    guard let self else { return }
                    if notification.name == .airsimRemoteSMSReceived { self.model.reloadMessagesFromLocalStore() }
                    else if notification.name == .airsimOpenIncomingCall { self.model.presentCurrentCallInApp() }
                    else if let sender = IncomingSMSPresentationRequest.consume() ?? notification.userInfo?["sender"] as? String { self.openSMSConversation(sender) }
                    else { self.select(.messages) }
                }
            })
        }
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        consumePendingSMS()
        renderCall()
        if !model.store.firstConnectionComplete, firstConnection == nil, presentedViewController == nil {
            let setup = AirSIMFirstConnectionViewController(model: model)
            let nav = UINavigationController(rootViewController: setup); nav.modalPresentationStyle = .fullScreen
            firstConnection = nav
            setup.onComplete = { [weak self, weak nav] in
                nav?.dismiss(animated: true) {
                    guard let self else { return }
                    self.firstConnection = nil
                    self.observeChanges()
                }
            }
            present(nav, animated: true)
        }
        renderAlert()
    }
    override func render() {
        let style = settings.appearance.interfaceStyle
        view.window?.overrideUserInterfaceStyle = style; callWindow?.overrideUserInterfaceStyle = style
        if model.store.firstConnectionComplete, let setup = firstConnection, !setup.isBeingDismissed {
            firstConnection = nil; setup.dismiss(animated: true)
        }
        let selection = PhoneTab.allCases.firstIndex(of: model.store.selectedTab) ?? 0
        if tabs.selectedIndex != selection { tabs.selectedIndex = selection }
        renderConversation(onMessagesTab: selection == PhoneTab.allCases.firstIndex(of: .messages))
        renderCall()
        renderAlert()
    }
    /// Shows each newly opened conversation once, while Messages is the selected tab.
    private func renderConversation(onMessagesTab: Bool) {
        guard let sender = model.store.messages.conversation else {
            appliedConversation = nil
            return
        }
        guard onMessagesTab, sender != appliedConversation else { return }
        appliedConversation = sender
        messages.showConversationIfNeeded(sender)
    }
    /// Presented imperatively from the top-most controller: present(item:) would first dismiss an open composer
    /// or sheet. The call window covers the main window, so errors raised during a call are shown above the call.
    private func renderAlert() {
        let alert = model.store.alert
        // Replaced, cleared or closed from beneath: forget it, and close it if it is still up.
        if let shown = alertController, shown.alertID != alert?.id || shown.presentingViewController == nil {
            alertController = nil
            if shown.presentingViewController != nil, !shown.isBeingDismissed { shown.dismiss(animated: true) }
        }
        // Errors wait for onboarding to close: its dismiss call would only close an alert presented above it.
        guard let alert, alertController == nil, view.window != nil, model.store.firstConnectionComplete, firstConnection == nil else { return }
        var host = callWindow?.rootViewController ?? self
        while let next = host.presentedViewController, !next.isBeingDismissed { host = next }
        if let transition = host.presentedViewController?.transitionCoordinator ?? host.transitionCoordinator {
            transition.animate(alongsideTransition: nil) { [weak self] _ in Task { @MainActor [weak self] in self?.renderAlert() } }
            return
        }
        let controller = StateAlertController(state: alert) { [weak self] action in
            // A button on an alert that state has already replaced must not close its successor.
            guard let self, self.model.store.alert?.id == alert.id else { return }
            self.model.store.send(.alert(action.map { .presented($0) } ?? .dismiss))
        }
        controller.alertID = alert.id; controller.hostWindow = callWindow ?? view.window
        controller.onDisappear = { [weak self, weak controller] in
            // Button handlers run after the alert disappears; decide once they have updated state.
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let controller, self.alertController === controller, controller.presentingViewController == nil { self.alertController = nil }
                self.renderAlert()
            }
        }
        alertController = controller
        host.present(controller, animated: true)
    }

    /// Shows the call window while a call is presented in app and removes it once the call leaves.
    private func renderCall() {
        guard store.activeCall.call != nil else {
            closeCallWindow()
            return
        }
#if DEBUG
        if store.activeCall.isLayoutPreview {
            UIDevice.current.isProximityMonitoringEnabled = false
        }
#endif
        if callWindow == nil {
            openCallWindow()
        }
    }

    /// The call window joins the main window's scene; viewDidAppear retries once root is in a window.
    /// Full-screen onboarding takes root's view out of the window, but its own view stays there.
    private func openCallWindow() {
        guard let host = view.window ?? presentedViewController?.viewIfLoaded?.window else { return }
        let controller = ActiveCallViewController(store: store.scope(state: \.activeCall, action: \.activeCall))
#if DEBUG
        controller.isPresentationPreview = store.activeCall.isLayoutPreview || isPreview
#endif
        let window = host.windowScene.map(UIWindow.init(windowScene:)) ?? UIWindow(frame: host.frame)
        window.windowLevel = .normal + 1
        window.overrideUserInterfaceStyle = host.overrideUserInterfaceStyle
        window.rootViewController = ActiveCallContainerViewController(call: controller)
        // A keyboard from a root sheet would otherwise stay above the call window.
        host.endEditing(true)
        callWindow = window
        window.makeKeyAndVisible()
        // VoiceOver reads every visible window; the call view's modality only hides its siblings in the call window.
        host.accessibilityElementsHidden = true
        callHostWindow = host
        UIAccessibility.post(notification: .screenChanged, argument: controller.view)
    }

    private func closeCallWindow() {
        guard let window = callWindow else { return }
        // The keypad's state is already closed, but its presenter leaves with this window; close what it presents now.
        // A root alert shown there moves to the main window in the same render.
        if alertController?.hostWindow === window {
            alertController = nil
        }
        window.rootViewController?.dismiss(animated: false)
        window.isHidden = true
        callWindow = nil
        let host = callHostWindow ?? view.window
        callHostWindow = nil
        host?.accessibilityElementsHidden = false
        host?.makeKey()
        UIAccessibility.post(notification: .screenChanged, argument: nil)
        UIDevice.current.isProximityMonitoringEnabled = false
        setNeedsStatusBarAppearanceUpdate()
    }

    func select(_ tab: PhoneTab) {
        tabs.selectedIndex = PhoneTab.allCases.firstIndex(of: tab) ?? 0
        model.store.send(.selectTab(tab))
    }
    func tabBarController(_ tabBarController: UITabBarController, didSelect viewController: UIViewController) {
        model.store.send(.selectTab(PhoneTab.allCases[tabs.selectedIndex]))
        UISelectionFeedbackGenerator().selectionChanged()
    }
    func composeMessage(_ number: String) {
        loadViewIfNeeded()
        model.store.send(.composeMessage(number))
    }
    func openSMSConversation(_ sender: String) {
        loadViewIfNeeded()
        model.store.send(.openSMS(sender))
        appliedConversation = sender
        messages.showConversationIfNeeded(sender)
    }
    func consumePendingSMS() {
#if DEBUG
        guard !isPreview else { return }
#endif
        if let sender = IncomingSMSPresentationRequest.consume() { openSMSConversation(sender) }
    }
    func handleSystemCommunicationURL(_ url: URL) {
        loadViewIfNeeded()
        model.store.send(.openURL(url))
    }
    deinit { notificationTokens.forEach(NotificationCenter.default.removeObserver) }
}

#if DEBUG
#Preview("Root · Five Tabs") {
    RootViewController(previewPresentation: AirSIMPreviewFixtures.presentation())
}

#Preview("Root · Dark") {
    RootViewController(previewPresentation: AirSIMPreviewFixtures.presentation(appearance: .dark))
}
#endif
