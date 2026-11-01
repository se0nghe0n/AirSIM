import ComposableArchitecture
import UIKit

@MainActor
final class RootViewController: ObservingViewController, UITabBarControllerDelegate {
    // MARK: Store

    let store: StoreOf<AirSIMFeature>
    #if DEBUG
    private var isPreview = false
    #endif

    // MARK: Views

    let tabs = UITabBarController()
    override var childForStatusBarStyle: UIViewController? { tabs }
    private lazy var messages = MessagesViewController(store: store.scope(state: \.messages, action: \.messages))
    private var firstConnection: UINavigationController?
    private var appliedConversation: String?
    /// Shows `store.alert`; nil once it leaves the screen, so a dismissal it did not ask for shows it again.
    private var alertController: StateAlertController?
    /// Hosts the in-app call surface above the main window; nil while no call is presented in app.
    private(set) var callWindow: UIWindow?
    /// The window the call window covers; hidden from VoiceOver until the call window closes.
    private weak var callHostWindow: UIWindow?

    var activeCallController: ActiveCallViewController? {
        (callWindow?.rootViewController as? ActiveCallContainerViewController)?.call
    }

    private var notificationTokens: [NSObjectProtocol] = []

    // MARK: Lifecycle

    init(store: StoreOf<AirSIMFeature>) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    #if DEBUG
    convenience init(previewStore: StoreOf<AirSIMFeature>) {
        self.init(store: previewStore)
        isPreview = true
    }
    #endif

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        notificationTokens.forEach(NotificationCenter.default.removeObserver)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        buildTabs()
        bindComposer()
        embedTabs()
        observeNotifications()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        consumePendingSMS()
        renderCall()
        presentOnboardingIfNeeded()
        renderAlert()
    }

    // MARK: Layout

    private func buildTabs() {
        tabs.viewControllers = PhoneTab.allCases.map { tab in
            let navigation = UINavigationController(rootViewController: rootController(for: tab))
            navigation.navigationBar.prefersLargeTitles = true
            navigation.tabBarItem = UITabBarItem(title: tab.rawValue, image: UIImage(systemName: tab.icon), tag: 0)
            return navigation
        }
        tabs.delegate = self
    }

    private func rootController(for tab: PhoneTab) -> UIViewController {
        switch tab {
        case .dial:
            return DialPadViewController(store: store.scope(state: \.dial, action: \.dial))
        case .recents:
            return RecentsViewController(store: store.scope(state: \.recents, action: \.recents))
        case .messages:
            return messages
        case .contacts:
            return ContactsViewController(store: store.scope(state: \.contacts, action: \.contacts))
        case .settings:
            return AirSIMSettingsViewController(store: store.scope(state: \.settings, action: \.settings))
        }
    }

    private func embedTabs() {
        if #available(iOS 26.0, *) {
            tabs.tabBarMinimizeBehavior = .onScrollDown
        }
        tabs.selectedIndex = tabIndex(store.selectedTab)
        addChild(tabs)
        tabs.view.frame = view.bounds
        tabs.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(tabs.view)
        tabs.didMove(toParent: self)
    }

    private func tabIndex(_ tab: PhoneTab) -> Int {
        PhoneTab.allCases.firstIndex(of: tab) ?? 0
    }

    // MARK: Rendering

    override var observesWhileHidden: Bool { true }

    override func render() {
        renderAppearance()
        dismissOnboardingIfFinished()
        renderSelectedTab()
        renderConversation()
        renderCall()
        renderAlert()
    }

    private func renderAppearance() {
        let style = store.settings.appearance.interfaceStyle
        view.window?.overrideUserInterfaceStyle = style
        callWindow?.overrideUserInterfaceStyle = style
    }

    private func renderSelectedTab() {
        let selection = tabIndex(store.selectedTab)
        if tabs.selectedIndex != selection {
            tabs.selectedIndex = selection
        }
    }

    private func renderConversation() {
        guard let sender = store.messages.conversation else {
            appliedConversation = nil
            return
        }
        guard store.selectedTab == .messages, sender != appliedConversation else { return }
        appliedConversation = sender
        messages.showConversationIfNeeded(sender)
    }

    // MARK: Onboarding

    private func presentOnboardingIfNeeded() {
        guard !store.firstConnectionComplete, firstConnection == nil, presentedViewController == nil else { return }
        let setup = AirSIMFirstConnectionViewController(store: store.scope(state: \.settings, action: \.settings))
        let navigation = UINavigationController(rootViewController: setup)
        navigation.modalPresentationStyle = .fullScreen
        firstConnection = navigation
        present(navigation, animated: true)
    }

    private func dismissOnboardingIfFinished() {
        guard store.firstConnectionComplete, let setup = firstConnection, !setup.isBeingDismissed else { return }
        firstConnection = nil
        setup.dismiss(animated: true)
    }

    // MARK: Alert

    /// Presented imperatively from the top-most controller: present(item:) would first dismiss an open composer
    /// or sheet. The call window covers the main window, so errors raised during a call are shown above the call.
    private func renderAlert() {
        let alert = store.alert
        // Replaced, cleared or closed from beneath: forget it, and close it if it is still up.
        if let shown = alertController, shown.alertID != alert?.id || shown.presentingViewController == nil {
            alertController = nil
            if shown.presentingViewController != nil, !shown.isBeingDismissed {
                shown.dismiss(animated: true)
            }
        }
        // Errors wait for onboarding to close: its dismiss call would only close an alert presented above it.
        guard let alert,
            alertController == nil,
            view.window != nil,
            store.firstConnectionComplete,
            firstConnection == nil
        else { return }
        var host = callWindow?.rootViewController ?? self
        while let next = host.presentedViewController, !next.isBeingDismissed {
            host = next
        }
        if let transition = host.presentedViewController?.transitionCoordinator ?? host.transitionCoordinator {
            transition.animate(alongsideTransition: nil) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.renderAlert()
                }
            }
            return
        }
        let controller = StateAlertController(state: alert) { [weak self] action in
            // A button on an alert that state has already replaced must not close its successor.
            guard let self, self.store.alert?.id == alert.id else { return }
            self.store.send(.alert(action.map { .presented($0) } ?? .dismiss))
        }
        controller.alertID = alert.id
        controller.hostWindow = callWindow ?? view.window
        controller.onDisappear = { [weak self, weak controller] in
            // Button handlers run after the alert disappears; decide once they have updated state.
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let controller, self.alertController === controller, controller.presentingViewController == nil {
                    self.alertController = nil
                }
                self.renderAlert()
            }
        }
        alertController = controller
        host.present(controller, animated: true)
    }

    // MARK: Call window

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

    // MARK: Navigation

    /// Replaces any other root sheet; requests made during onboarding wait in state until it completes.
    private func bindComposer() {
        present(item: UIBindable(store).scope(\.messages.$composer, action: \.messages.composer)) {
            phoneSheet(MessageComposerViewController(store: $0))
        }
    }

    func select(_ tab: PhoneTab) {
        tabs.selectedIndex = tabIndex(tab)
        store.send(.selectTab(tab))
    }

    func composeMessage(_ number: String) {
        loadViewIfNeeded()
        store.send(.composeMessage(number))
    }

    func openSMSConversation(_ sender: String) {
        loadViewIfNeeded()
        store.send(.openSMS(sender))
        appliedConversation = sender
        messages.showConversationIfNeeded(sender)
    }

    func consumePendingSMS() {
        #if DEBUG
        guard !isPreview else { return }
        #endif
        if let sender = IncomingSMSPresentationRequest.consume() {
            openSMSConversation(sender)
        }
    }

    func handleSystemCommunicationURL(_ url: URL) {
        loadViewIfNeeded()
        store.send(.openURL(url))
    }

    // MARK: Notifications

    private func observeNotifications() {
        let center = NotificationCenter.default
        for name in [Notification.Name.airsimRemoteSMSReceived, .airsimOpenSMSConversation, .airsimOpenIncomingCall] {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                Task { @MainActor in
                    self?.handle(notification)
                }
            }
            notificationTokens.append(token)
        }
    }

    private func handle(_ notification: Notification) {
        switch notification.name {
        case .airsimRemoteSMSReceived:
            store.send(.remoteSMSReceived)
        case .airsimOpenIncomingCall:
            store.send(.openIncomingCall)
        default:
            if let sender = IncomingSMSPresentationRequest.consume() ?? notification.userInfo?["sender"] as? String {
                openSMSConversation(sender)
            } else {
                select(.messages)
            }
        }
    }

    // MARK: UITabBarControllerDelegate

    func tabBarController(_ tabBarController: UITabBarController, didSelect viewController: UIViewController) {
        store.send(.selectTab(PhoneTab.allCases[tabs.selectedIndex]))
        UISelectionFeedbackGenerator().selectionChanged()
    }
}

#if DEBUG
#Preview("Root · Five Tabs") {
    RootViewController(previewStore: AirSIMPreviewFixtures.store())
}

#Preview("Root · Dark") {
    RootViewController(previewStore: AirSIMPreviewFixtures.store(appearance: .dark))
}
#endif
