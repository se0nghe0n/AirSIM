import UIKit
import Observation
import ComposableArchitecture

enum SystemCommunicationDestination: Equatable {
    case call(String)
    case message(String)
    case liveActivity(AirSIMLiveActivityAction, callID: String)
}

enum SystemCommunicationURL {
    static func destination(for url: URL) -> SystemCommunicationDestination? {
        if let action = AirSIMLiveActivityActionURL.parse(url) {
            return .liveActivity(action.action, callID: action.callID)
        }
        guard let scheme = url.scheme?.lowercased(), scheme == "tel" || scheme == "im" else {
            return nil
        }
        let prefixLength = scheme.count + 1
        guard url.absoluteString.count > prefixLength else { return nil }
        var target = String(url.absoluteString.dropFirst(prefixLength))
        while target.hasPrefix("//") { target.removeFirst(2) }
        target = String(target.split(separator: "?", maxSplits: 1).first ?? "")
        target = target.removingPercentEncoding ?? target
        target = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return nil }
        return scheme == "tel" ? .call(target) : .message(target)
    }
}

enum PhoneTab: String, CaseIterable {
    case dial = "Dial"
    case recents = "Recents"
    case messages = "Messages"
    case contacts = "Contacts"
    case settings = "Settings"

    var icon: String {
        switch self {
        case .dial: return "circle.grid.3x3.fill"
        case .recents: return "clock.fill"
        case .messages: return "message.fill"
        case .contacts: return "person.crop.circle.fill"
        case .settings: return "gearshape.fill"
        }
    }
}


/// Explicit observation also works on iOS 17, before UIKit's automatic observation support.
/// Re-arm after the mutation completes; keep controls and navigation controllers alive.
@MainActor
class ObservingViewController: UIViewController {
    var observesWhileHidden: Bool { false }
    private var observing = false
    private var generation = 0
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        observing = true
        observeChanges()
    }
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if !observesWhileHidden { observing = false; generation += 1 }
    }
    func render() {}
    func observeChanges() {
        guard observing, isViewLoaded else { return }
        generation += 1
        let token = generation
        withObservationTracking { render() } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.observing, self.generation == token else { return }
                self.observeChanges()
            }
        }
    }
}

@MainActor
struct PhoneRow {
    let id: String
    var title: String
    var detail: String = ""
    var image: String? = nil
    var color: UIColor = .label
    var accessory: UIView? = nil
    var disclosure = false
    var enabled = true
    var action: (() -> Void)? = nil
    var context: (() -> UIMenu)? = nil
    var accessibilityHint: String? = nil
    var photo: Data? = nil
    var avatarName: String? = nil
    var bodyView: UIView? = nil
    var bodyViewProvider: (() -> UIView)? = nil
    var bodyVersion: String? = nil
    var insets = UIEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)
    var isValue = false
    var accessoryInline = false
    var transparent = false
    var textStyle: UIFont.TextStyle = .body

    struct BodyIdentity: Equatable {
        var id: String
        var title: String
        var detail: String
        var image: String?
        var color: UIColor
        var enabled: Bool
        var photo: Data?
        var avatarName: String?
        var version: String?
    }
    var bodyIdentity: BodyIdentity {
        BodyIdentity(id: id, title: title, detail: detail, image: image, color: color,
                     enabled: enabled, photo: photo, avatarName: avatarName, version: bodyVersion)
    }
}

@MainActor
private final class PhoneTableCell: UITableViewCell {
    var controlHost: UIStackView?
    var bodyIdentity: PhoneRow.BodyIdentity?
}

struct PhoneSection {
    var title: String = ""
    var footer: String = ""
    var rows: [PhoneRow]
}

/// Retains the native form controls across observation updates, including keyboard focus.
@MainActor
class PhoneTableController: ObservingViewController, UITableViewDataSource, UITableViewDelegate {
    var tableStyle: UITableView.Style { .insetGrouped }
    lazy var table = UITableView(frame: .zero, style: tableStyle)
    var sections: [PhoneSection] = []
    var onRefresh: (() async -> Void)?
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        table.translatesAutoresizingMaskIntoConstraints = false
        table.dataSource = self; table.delegate = self
        table.keyboardDismissMode = .interactive
        if tableStyle == .plain {
            table.backgroundColor = .clear
            table.backgroundView = PhoneBackdropView()
            table.separatorInset = UIEdgeInsets(top: 0, left: 93, bottom: 0, right: 16)
        }
        table.estimatedRowHeight = 74
        table.rowHeight = UITableView.automaticDimension
        view.addSubview(table)
        let groupExpansion: CGFloat = tableStyle == .insetGrouped && traitCollection.horizontalSizeClass == .compact ? 4 : 0
        NSLayoutConstraint.activate([table.topAnchor.constraint(equalTo: view.topAnchor), table.bottomAnchor.constraint(equalTo: view.bottomAnchor), table.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: -groupExpansion), table.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: groupExpansion)])
    }
    func setSections(_ updated: [PhoneSection]) {
        let previous = sections.map { $0.rows.map(\.id) }
        let next = updated.map { $0.rows.map(\.id) }
        // A hidden/new table may not have consumed its last reload yet. Resolve
        // UIKit's old counts before replacing the data source used by the batch.
        let canApplyUpdates = table.window != nil && table.numberOfSections == previous.count
            && previous.indices.allSatisfy { table.numberOfRows(inSection: $0) == previous[$0].count }
        sections = updated
        let hasDuplicateIDs = (previous + next).contains { Set($0).count != $0.count }
        if !canApplyUpdates || previous.count != next.count || hasDuplicateIDs {
            table.reloadData()
        } else if previous != next {
            // Insert/delete only changed identities. Stable text fields never leave their cells,
            // so asynchronous discovery, traces and self-tests cannot dismiss the keyboard.
            var deleted: [IndexPath] = []
            var inserted: [IndexPath] = []
            var reordered = false
            for section in next.indices {
                let oldSet = Set(previous[section]), newSet = Set(next[section])
                reordered = reordered || previous[section].filter(newSet.contains) != next[section].filter(oldSet.contains)
                deleted += previous[section].enumerated().compactMap { newSet.contains($0.element) ? nil : IndexPath(row: $0.offset, section: section) }
                inserted += next[section].enumerated().compactMap { oldSet.contains($0.element) ? nil : IndexPath(row: $0.offset, section: section) }
            }
            if reordered { table.reloadData() }
            else {
                UIView.performWithoutAnimation {
                    table.performBatchUpdates {
                        table.deleteRows(at: deleted, with: .none)
                        table.insertRows(at: inserted, with: .none)
                    }
                }
            }
        }
        for path in table.indexPathsForVisibleRows ?? [] {
            if sections.indices.contains(path.section), sections[path.section].rows.indices.contains(path.row), let cell = table.cellForRow(at: path) { configure(cell, at: path) }
        }
        for section in sections.indices {
            if let header = table.headerView(forSection: section) {
                configureSectionLabel(header, text: sections[section].title, header: true)
            }
            if let footer = table.footerView(forSection: section) {
                configureSectionLabel(footer, text: sections[section].footer, header: false)
            }
        }
    }

    func enableRefresh(_ action: @escaping () async -> Void) {
        onRefresh = action
        let refresh = UIRefreshControl()
        refresh.addAction(UIAction { [weak self] _ in
            Task { @MainActor in
                await self?.onRefresh?()
                self?.table.refreshControl?.endRefreshing()
            }
        }, for: .valueChanged)
        table.refreshControl = refresh
    }
    func numberOfSections(in tableView: UITableView) -> Int { sections.count }
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { sections[section].rows.count }
    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? { sections[section].title.isEmpty ? nil : sections[section].title }
    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? { sections[section].footer.isEmpty ? nil : sections[section].footer }
    func tableView(_ tableView: UITableView, willDisplayHeaderView view: UIView, forSection section: Int) {
        configureSectionLabel(view, text: sections[section].title, header: true)
    }
    func tableView(_ tableView: UITableView, willDisplayFooterView view: UIView, forSection section: Int) {
        configureSectionLabel(view, text: sections[section].footer, header: false)
    }
    private func configureSectionLabel(_ view: UIView, text: String, header: Bool) {
        guard tableStyle == .insetGrouped, let section = view as? UITableViewHeaderFooterView else { return }
        var content = section.defaultContentConfiguration()
        content.text = text; content.textProperties.color = .secondaryLabel
        content.textProperties.font = UIFontMetrics(forTextStyle: header ? .body : .footnote).scaledFont(for: .systemFont(ofSize: header ? 17 : 13, weight: header ? .semibold : .regular))
        content.textProperties.numberOfLines = 0
        content.axesPreservingSuperviewLayoutMargins = []
        content.directionalLayoutMargins.leading = 16; content.directionalLayoutMargins.trailing = 16
        section.contentConfiguration = content
    }
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "row") ?? PhoneTableCell(style: .subtitle, reuseIdentifier: "row")
        configure(cell, at: indexPath)
        return cell
    }
    func configure(_ cell: UITableViewCell, at path: IndexPath) {
        let row = sections[path.section].rows[path.row]
        let phoneCell = cell as? PhoneTableCell
        let unchangedBody = row.bodyViewProvider != nil && phoneCell?.bodyIdentity == row.bodyIdentity
        let bodyView = unchangedBody ? phoneCell?.controlHost?.arrangedSubviews.last : row.bodyView ?? row.bodyViewProvider?()
        phoneCell?.bodyIdentity = row.bodyViewProvider == nil ? nil : row.bodyIdentity
        cell.backgroundColor = tableStyle == .plain || row.transparent ? .clear : .secondarySystemGroupedBackground
        var content = row.isValue ? UIListContentConfiguration.valueCell() : cell.defaultContentConfiguration()
        content.textProperties.font = .preferredFont(forTextStyle: row.textStyle)
        if tableStyle == .insetGrouped { content.axesPreservingSuperviewLayoutMargins = []; content.directionalLayoutMargins.leading = 16; content.directionalLayoutMargins.trailing = 16 }
        content.text = row.title; content.secondaryText = row.detail.isEmpty ? nil : row.detail
        content.textProperties.color = row.enabled ? row.color : .secondaryLabel
        content.textProperties.numberOfLines = 0
        content.secondaryTextProperties.numberOfLines = 0
        content.image = row.image.flatMap(UIImage.init(systemName:))
        if bodyView == nil, let name = row.avatarName { content.image = phoneAvatar(name: name, photo: row.photo) }
        content.imageProperties.maximumSize = CGSize(width: 44, height: 44)
        if let control = bodyView ?? row.accessory, let cell = cell as? PhoneTableCell {
            cell.contentConfiguration = nil
            cell.accessoryView = nil
            if cell.controlHost?.arrangedSubviews.last !== control {
                cell.controlHost?.removeFromSuperview()
                let host = UIStackView(); host.axis = row.accessoryInline ? .horizontal : .vertical; host.spacing = 10; host.alignment = row.accessoryInline ? .center : .fill
                host.translatesAutoresizingMaskIntoConstraints = false
                if bodyView == nil && !row.title.isEmpty { host.addArrangedSubview(phoneLabel(row.title)); if row.accessoryInline { host.addArrangedSubview(UIView()); control.setContentHuggingPriority(.required, for: .horizontal) } }
                control.translatesAutoresizingMaskIntoConstraints = false
                host.addArrangedSubview(control)
                cell.contentView.addSubview(host); cell.controlHost = host
                NSLayoutConstraint.activate([host.leadingAnchor.constraint(equalTo: cell.contentView.leadingAnchor, constant: row.insets.left), host.trailingAnchor.constraint(equalTo: cell.contentView.trailingAnchor, constant: -row.insets.right), host.topAnchor.constraint(equalTo: cell.contentView.topAnchor, constant: row.insets.top), host.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor, constant: -row.insets.bottom)])
                if control is UITextView { control.heightAnchor.constraint(equalToConstant: 120).isActive = true }
                else if bodyView == nil { control.heightAnchor.constraint(greaterThanOrEqualToConstant: 32).isActive = true }
            }
        } else {
            (cell as? PhoneTableCell)?.controlHost?.removeFromSuperview()
            (cell as? PhoneTableCell)?.controlHost = nil
            cell.contentConfiguration = content
            cell.accessoryView = nil
        }
        cell.accessoryType = row.disclosure ? .disclosureIndicator : .none
        cell.selectionStyle = row.action != nil && row.enabled ? .default : .none
        cell.accessibilityHint = row.accessibilityHint
    }
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let row = sections[indexPath.section].rows[indexPath.row]
        if row.enabled { row.action?() }
    }
    func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
        guard let menu = sections[indexPath.section].rows[indexPath.row].context else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in menu() }
    }
    func row(at path: IndexPath) -> PhoneRow? {
        guard sections.indices.contains(path.section), sections[path.section].rows.indices.contains(path.row) else { return nil }
        return sections[path.section].rows[path.row]
    }
}

@MainActor
final class PhoneActionButton: UIButton {
    var accessibilityAction: (() -> Void)?
    override func accessibilityActivate() -> Bool {
        guard let accessibilityAction else { return super.accessibilityActivate() }
        accessibilityAction()
        return true
    }
}

@MainActor
func phoneButton(_ title: String, image: String? = nil, color: UIColor = .systemBlue, action: @escaping () -> Void) -> UIButton {
    let button = PhoneActionButton(type: .system)
    var config = UIButton.Configuration.tinted()
    config.title = title; config.image = image.flatMap(UIImage.init(systemName:)); config.imagePadding = 8
    config.baseForegroundColor = color; config.cornerStyle = .capsule
    button.configuration = config
    button.accessibilityLabel = title
    button.addAction(UIAction { _ in action() }, for: .touchUpInside)
    return button
}

@MainActor
func phoneLabel(_ text: String = "", size: CGFloat = 17, color: UIColor = .label) -> UILabel {
    let label = UILabel(); label.text = text; label.font = UIFontMetrics(forTextStyle: .body).scaledFont(for: .systemFont(ofSize: size))
    label.textColor = color; label.numberOfLines = 0; label.adjustsFontForContentSizeCategory = true
    return label
}

@MainActor
func phoneAvatar(name: String, photo: Data?, size: CGFloat = 44) -> UIImage {
    let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size))
    return renderer.image { context in
        let rect = CGRect(x: 0, y: 0, width: size, height: size)
        UIBezierPath(ovalIn: rect).addClip()
        if let photo, let image = UIImage(data: photo) {
            let scale = max(size / image.size.width, size / image.size.height)
            image.draw(in: CGRect(x: (size - image.size.width * scale) / 2, y: (size - image.size.height * scale) / 2, width: image.size.width * scale, height: image.size.height * scale)); return
        }
        let colors = name.isEmpty ? [UIColor(red: 0.64, green: 0.76, blue: 0.91, alpha: 1).cgColor, UIColor(red: 0.43, green: 0.48, blue: 0.78, alpha: 1).cgColor] as CFArray : [UIColor(red: 0.66, green: 0.78, blue: 0.92, alpha: 1).cgColor, UIColor(red: 0.43, green: 0.49, blue: 0.79, alpha: 1).cgColor] as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) { context.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size, y: size), options: []) }
        let initial = name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1)
        if initial.isEmpty {
            if let person = UIImage(systemName: "person.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: size * 0.52, weight: .semibold))?.withTintColor(.white, renderingMode: .alwaysOriginal) {
                person.draw(at: CGPoint(x: (size - person.size.width) / 2, y: (size - person.size.height) / 2 + size * 0.08))
            }
        } else {
            let shadow = NSShadow(); shadow.shadowColor = UIColor.systemIndigo.withAlphaComponent(0.55); shadow.shadowBlurRadius = 1.4; shadow.shadowOffset = CGSize(width: 0, height: 1.2)
            let attributes: [NSAttributedString.Key: Any] = [.shadow: shadow, .font: UIFont.systemFont(ofSize: size * 0.46, weight: .bold).rounded(), .foregroundColor: UIColor.white]
            let text = String(initial) as NSString; let measured = text.size(withAttributes: attributes)
            text.draw(at: CGPoint(x: (size - measured.width) / 2, y: (size - measured.height) / 2), withAttributes: attributes)
        }
    }
}

extension UIViewController {
    @discardableResult
    func showPhoneSheet(_ controller: UIViewController, animated: Bool = true, completion: (() -> Void)? = nil) -> UINavigationController {
        controller.loadViewIfNeeded()
        let nav = UINavigationController(rootViewController: controller)
        if controller.navigationItem.rightBarButtonItem == nil {
            controller.navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak nav] _ in nav?.dismiss(animated: true) })
        }
        if let sheet = nav.sheetPresentationController { sheet.detents = [.medium(), .large()]; sheet.prefersGrabberVisible = true }
        present(nav, animated: animated, completion: completion)
        return nav
    }
    func confirmPhoneAction(_ title: String, message: String? = nil, actionTitle: String = "Delete", action: @escaping () -> Void) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .actionSheet)
        alert.addAction(UIAlertAction(title: actionTitle, style: .destructive) { _ in action() })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.popoverPresentationController?.sourceView = view
        alert.popoverPresentationController?.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
        present(alert, animated: true)
    }
}

@MainActor
final class RootViewController: ObservingViewController, UITabBarControllerDelegate {
    override var observesWhileHidden: Bool { true }
    let model: AirSIMPresentation
    let settings: SettingsPresentation
    let tabs = UITabBarController()
    override var childForStatusBarStyle: UIViewController? { activeCall ?? tabs }
    private var messages: MessagesViewController!
    private var activeCall: ActiveCallViewController?
    private var notificationTokens: [NSObjectProtocol] = []
    private var firstConnection: UINavigationController?
    private var pendingComposer: String?
    private var appliedConversation: String?
#if DEBUG
    private var isPreview = false
    init(previewPresentation: AirSIMPresentation) {
        model = previewPresentation
        settings = previewPresentation.settings
        isPreview = true
        super.init(nibName: nil, bundle: nil)
    }
#endif
    init(model: AppModel, settings: AppSettings) { let presentation = AirSIMPresentation(model: model, settings: settings); self.model = presentation; self.settings = presentation.settings; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        messages = MessagesViewController(model: model)
        let callAction: (String) -> Void = { [weak self] in self?.dial($0) }
        let messageAction: (String) -> Void = { [weak self] in self?.composeMessage($0) }
        let controllers: [UIViewController] = [DialPadViewController(model: model), RecentsViewController(model: model, onCall: callAction, onMessage: messageAction), messages, ContactsViewController(model: model, onCall: callAction, onMessage: messageAction), AirSIMSettingsViewController(model: model, settings: settings)]
        tabs.viewControllers = zip(PhoneTab.allCases, controllers).map { tab, controller in
            let nav = UINavigationController(rootViewController: controller)
            nav.navigationBar.prefersLargeTitles = true
            nav.tabBarItem = UITabBarItem(title: tab.rawValue, image: UIImage(systemName: tab.icon), tag: 0)
            return nav
        }
        tabs.delegate = self
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
        if !model.store.firstConnectionComplete, firstConnection == nil, presentedViewController == nil {
            let setup = AirSIMFirstConnectionViewController(model: model)
            let nav = UINavigationController(rootViewController: setup); nav.modalPresentationStyle = .fullScreen
            firstConnection = nav
            setup.onComplete = { [weak self, weak nav] in
                nav?.dismiss(animated: true) {
                    guard let self else { return }
                    self.firstConnection = nil
                    if let recipient = self.pendingComposer { self.pendingComposer = nil; self.composeMessage(recipient) }
                    self.observeChanges()
                }
            }
            present(nav, animated: true)
        }
    }
    override func render() {
        view.window?.overrideUserInterfaceStyle = settings.appearance.interfaceStyle
        if model.store.firstConnectionComplete, let setup = firstConnection, !setup.isBeingDismissed {
            firstConnection = nil; setup.dismiss(animated: true)
        }
        let selection = PhoneTab.allCases.firstIndex(of: model.store.selectedTab) ?? 0
        if tabs.selectedIndex != selection { tabs.selectedIndex = selection }
        if model.store.messages.conversation == nil { appliedConversation = nil }
        if model.store.messages.composerPresented, model.store.firstConnectionComplete, firstConnection == nil { messages.presentComposerIfNeeded() }
        else if let sender = model.store.messages.conversation, sender != appliedConversation, selection == PhoneTab.allCases.firstIndex(of: .messages) {
            appliedConversation = sender
            messages.showConversationIfNeeded(sender)
        }
        var call = model.inAppPresentedCall
#if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "--airsim-layout-call"), args.indices.contains(i + 1), ["incoming", "active"].contains(args[i + 1]) {
            call = CallRecord(id: "layout-preview", index: 0, direction: "incoming", state: args[i + 1], number: "+1 202 555 0100", startedAt: Date().addingTimeInterval(-65), updatedAt: Date(), endedAt: nil, missed: false)
        }
#endif
        if let call {
            if call.id == "layout-preview" { UIDevice.current.isProximityMonitoringEnabled = false }
            if let activeCall { activeCall.update(call: call) }
            else {
                let controller = ActiveCallViewController(model: model, call: call)
                controller.isPresentationPreview = call.id == "layout-preview"
#if DEBUG
                controller.isPresentationPreview = controller.isPresentationPreview || isPreview
#endif
                activeCall = controller; addChild(controller); controller.view.frame = view.bounds
                controller.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                view.addSubview(controller.view); controller.didMove(toParent: self); setNeedsStatusBarAppearanceUpdate()
            }
        } else if let controller = activeCall {
            controller.dismissKeypad(); controller.willMove(toParent: nil); controller.view.removeFromSuperview(); controller.removeFromParent(); activeCall = nil
            UIDevice.current.isProximityMonitoringEnabled = false; setNeedsStatusBarAppearanceUpdate()
        }
        if let error = model.errorMessage, !error.isEmpty, !model.store.messages.sending, model.store.messages.error != error, presentedViewController == nil {
            let alert = UIAlertController(title: "Error", message: error, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak self] _ in self?.model.errorMessage = nil })
            present(alert, animated: true)
        }
    }
    func select(_ tab: PhoneTab) {
        tabs.selectedIndex = PhoneTab.allCases.firstIndex(of: tab) ?? 0
        model.store.send(.selectTab(tab))
    }
    func tabBarController(_ tabBarController: UITabBarController, didSelect viewController: UIViewController) {
        model.store.send(.selectTab(PhoneTab.allCases[tabs.selectedIndex]))
        UISelectionFeedbackGenerator().selectionChanged()
    }
    func dial(_ number: String) { model.numberInput = number; select(.dial); Task { await model.dial() } }
    func composeMessage(_ number: String) {
        loadViewIfNeeded()
        select(.messages)
        guard model.store.firstConnectionComplete, firstConnection == nil else { pendingComposer = number; return }
        messages.compose(recipient: number)
    }
    func openSMSConversation(_ sender: String) {
        loadViewIfNeeded(); model.store.send(.openSMS(sender))
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

@MainActor
final class PhoneBackdropView: UIView {
    private let gradient = CAGradientLayer()
    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.addSublayer(gradient)
        updateColors()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() {
        super.layoutSubviews()
        gradient.frame = bounds
    }
    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if previousTraitCollection?.hasDifferentColorAppearance(comparedTo: traitCollection) != false {
            updateColors()
        }
    }
    private func updateColors() {
        if traitCollection.userInterfaceStyle == .dark {
            backgroundColor = UIColor(red: 0.008, green: 0.016, blue: 0.035, alpha: 1)
            gradient.colors = [UIColor.clear.cgColor, UIColor(red: 0.018, green: 0.075, blue: 0.16, alpha: 0.72).cgColor, UIColor(red: 0.025, green: 0.2, blue: 0.48, alpha: 0.62).cgColor]
        } else { backgroundColor = .white; gradient.colors = [UIColor.clear.cgColor, UIColor.clear.cgColor] }
    }
}

@MainActor
func phoneEmptyState(_ title: String, image: String, detail: String, minimumHeight: CGFloat = 300, iconSize: CGFloat = 44, detailSize: CGFloat = 20, spacing: CGFloat = 8, verticalPadding: CGFloat = 24, headingSize: CGFloat = 20) -> UIView {
    let container = UIView()
    let symbol = UIImageView(image: UIImage(systemName: image)); symbol.tintColor = .secondaryLabel; symbol.contentMode = .scaleAspectFit
    symbol.heightAnchor.constraint(equalToConstant: iconSize).isActive = true
    let heading = phoneLabel(title, size: headingSize); heading.font = UIFontMetrics(forTextStyle: .headline).scaledFont(for: .systemFont(ofSize: headingSize, weight: headingSize == 17 ? .semibold : .bold)); heading.textAlignment = .center
    let subtitle = phoneLabel(detail, size: detailSize, color: .secondaryLabel); subtitle.textAlignment = .center
    let stack = UIStackView(arrangedSubviews: [symbol, heading, subtitle]); stack.axis = .vertical; stack.spacing = spacing; stack.alignment = .center
    heading.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true; subtitle.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    stack.translatesAutoresizingMaskIntoConstraints = false; container.addSubview(stack)
    NSLayoutConstraint.activate([container.heightAnchor.constraint(greaterThanOrEqualToConstant: minimumHeight), stack.centerYAnchor.constraint(equalTo: container.centerYAnchor), stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16), stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16), stack.topAnchor.constraint(greaterThanOrEqualTo: container.topAnchor, constant: verticalPadding), stack.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -verticalPadding)])
    return container
}

@MainActor
final class PhoneListContentView: UIView {
    init(name: String, subtitle: String, photo: Data?, avatarName: String, time: String? = nil, missed: Bool = false, callAction: (() -> Void)? = nil) {
        super.init(frame: .zero)
        let avatar = UIImageView(image: phoneAvatar(name: avatarName, photo: photo, size: 50)); avatar.contentMode = .scaleAspectFill
        avatar.widthAnchor.constraint(equalToConstant: 50).isActive = true; avatar.heightAnchor.constraint(equalToConstant: 50).isActive = true
        let title = phoneLabel(name); title.font = UIFontMetrics(forTextStyle: .body).scaledFont(for: .systemFont(ofSize: 17, weight: .semibold)); title.numberOfLines = 1; title.textColor = missed ? .systemRed : .label
        let detail = phoneLabel(subtitle, size: 15, color: missed ? .systemRed : .secondaryLabel); detail.numberOfLines = 1
        let text = UIStackView(arrangedSubviews: [title, detail]); text.axis = .vertical; text.spacing = 3
        let row = UIStackView(arrangedSubviews: [avatar, text]); row.axis = .horizontal; row.spacing = 11; row.alignment = .center
        if let time { let label = phoneLabel(time, size: 15, color: .secondaryLabel); label.numberOfLines = 1; label.textAlignment = .right; label.adjustsFontSizeToFitWidth = true; label.minimumScaleFactor = 0.78; label.widthAnchor.constraint(equalToConstant: 76).isActive = true; row.addArrangedSubview(label) }
        if let callAction { let button = phoneButton("Dial", image: "phone.fill", action: callAction); button.configuration?.title = nil; button.configuration?.background.backgroundColor = .secondarySystemBackground; button.widthAnchor.constraint(equalToConstant: 44).isActive = true; button.heightAnchor.constraint(equalToConstant: 44).isActive = true; row.addArrangedSubview(button) }
        row.translatesAutoresizingMaskIntoConstraints = false; addSubview(row)
        NSLayoutConstraint.activate([heightAnchor.constraint(greaterThanOrEqualToConstant: 74), row.leadingAnchor.constraint(equalTo: leadingAnchor), row.trailingAnchor.constraint(equalTo: trailingAnchor), row.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 6), row.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -6), row.centerYAnchor.constraint(equalTo: centerYAnchor)])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

extension UIFont {
    func rounded() -> UIFont { UIFont(descriptor: fontDescriptor.withDesign(.rounded) ?? fontDescriptor, size: pointSize) }
}

@MainActor
private final class BubbleLabel: UILabel {
    let padding = UIEdgeInsets(top: 9, left: 14, bottom: 9, right: 14)
    override func drawText(in rect: CGRect) { super.drawText(in: rect.inset(by: padding)) }
    override func textRect(forBounds bounds: CGRect, limitedToNumberOfLines numberOfLines: Int) -> CGRect {
        let rect = super.textRect(forBounds: bounds.inset(by: padding), limitedToNumberOfLines: numberOfLines)
        return rect.inset(by: UIEdgeInsets(top: -padding.top, left: -padding.left, bottom: -padding.bottom, right: -padding.right))
    }
}

@MainActor
final class PhoneMessageBubble: UIView {
    init(message: SMSMessage) {
        super.init(frame: .zero)
        let label = BubbleLabel(); label.text = message.content; label.font = .preferredFont(forTextStyle: .body); label.numberOfLines = 0
        label.textColor = message.isOutgoing ? .white : .label; label.backgroundColor = message.isOutgoing ? .systemBlue : .secondarySystemBackground
        label.layer.cornerRadius = 18; label.clipsToBounds = true
        let stack = UIStackView(arrangedSubviews: [label]); stack.axis = .vertical; stack.spacing = 3; stack.alignment = message.isOutgoing ? .trailing : .leading
        if message.isOutgoing { stack.addArrangedSubview(phoneLabel("Sent", size: 11, color: .secondaryLabel)) }
        stack.translatesAutoresizingMaskIntoConstraints = false; addSubview(stack)
        NSLayoutConstraint.activate([stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor), stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor), label.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -48)])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

@MainActor
final class CallBackdropView: UIView {
    private let top = CAGradientLayer()
    private let bottom = CAGradientLayer()
    override init(frame: CGRect) {
        super.init(frame: frame); backgroundColor = UIColor(red: 0.008, green: 0.012, blue: 0.025, alpha: 1)
        top.type = .radial; top.colors = [UIColor.systemBlue.withAlphaComponent(0.24).cgColor, UIColor.clear.cgColor]; top.startPoint = CGPoint(x: 0.5, y: 0.5); top.endPoint = CGPoint(x: 1, y: 1)
        bottom.type = .radial; bottom.colors = [UIColor.cyan.withAlphaComponent(0.12).cgColor, UIColor.clear.cgColor]; bottom.startPoint = CGPoint(x: 0.5, y: 0.5); bottom.endPoint = CGPoint(x: 1, y: 1)
        layer.addSublayer(top); layer.addSublayer(bottom)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() { super.layoutSubviews(); top.frame = CGRect(x: bounds.width - 420, y: -420, width: 840, height: 840); bottom.frame = CGRect(x: -360, y: bounds.height - 360, width: 720, height: 720) }
}

@MainActor
final class CallCircleControl: UIButton {
    private let caption = phoneLabel(size: 12, color: UIColor.white.withAlphaComponent(0.88))
    private let iconView = UIImageView()
    private let circle = UIView()
    private var sizeConstraints: [NSLayoutConstraint] = []
    private let material = UIVisualEffectView(effect: nil)
    private let gradient = CAGradientLayer()
    private let isDecision: Bool
    init(title: String, icon: String, size: CGFloat, color: UIColor? = nil, action: @escaping () -> Void) {
        isDecision = color != nil
        super.init(frame: .zero)
        if isDecision { circle.layer.insertSublayer(gradient, at: 0); heightAnchor.constraint(greaterThanOrEqualToConstant: 108).isActive = true }
        else { material.frame = circle.bounds; material.autoresizingMask = [.flexibleWidth, .flexibleHeight]; material.clipsToBounds = true; circle.addSubview(material) }
        circle.layer.cornerRadius = size / 2; circle.backgroundColor = color ?? UIColor.white.withAlphaComponent(0.12)
        circle.layer.borderColor = UIColor.white.withAlphaComponent(0.12).cgColor; circle.layer.borderWidth = 0.5
        iconView.tintColor = .white; iconView.contentMode = .center; iconView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: size == 76 ? 28 : 24, weight: .semibold)
        iconView.translatesAutoresizingMaskIntoConstraints = false; circle.addSubview(iconView)
        sizeConstraints = [circle.widthAnchor.constraint(equalToConstant: size), circle.heightAnchor.constraint(equalToConstant: size)]; NSLayoutConstraint.activate(sizeConstraints)
        NSLayoutConstraint.activate([iconView.centerXAnchor.constraint(equalTo: circle.centerXAnchor), iconView.centerYAnchor.constraint(equalTo: circle.centerYAnchor)])
        caption.textAlignment = .center; if size == 76 { caption.font = .systemFont(ofSize: 15, weight: .medium); circle.layer.shadowColor = (color ?? .clear).cgColor; circle.layer.shadowOpacity = 0.28; circle.layer.shadowRadius = 16; circle.layer.shadowOffset = CGSize(width: 0, height: 8) }
        let stack = UIStackView(arrangedSubviews: [circle, caption]); stack.axis = .vertical; stack.spacing = size == 76 ? 10 : 7; stack.alignment = .center; stack.isUserInteractionEnabled = false; stack.translatesAutoresizingMaskIntoConstraints = false; addSubview(stack)
        NSLayoutConstraint.activate([stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor), stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor), widthAnchor.constraint(greaterThanOrEqualToConstant: size == 76 ? 96 : size)])
        update(title: title, icon: icon, tint: color); addAction(UIAction { _ in action() }, for: .touchUpInside)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func setSize(_ size: CGFloat) { sizeConstraints.forEach { $0.constant = size }; circle.layer.cornerRadius = size / 2; material.layer.cornerRadius = size / 2 }
    override func layoutSubviews() { super.layoutSubviews(); gradient.frame = circle.bounds; gradient.cornerRadius = circle.bounds.width / 2; material.layer.cornerRadius = circle.bounds.width / 2 }
    func update(title: String, icon: String, tint: UIColor?) {
        caption.text = title; iconView.image = UIImage(systemName: icon); accessibilityLabel = title
        if isDecision, let tint {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0; tint.getRed(&r, green: &g, blue: &b, alpha: &a)
            gradient.colors = [UIColor(red: r + (1-r)*0.12, green: g + (1-g)*0.12, blue: b + (1-b)*0.12, alpha: 1).cgColor, tint.cgColor]
            circle.backgroundColor = tint
        } else {
            circle.backgroundColor = .clear
            if #available(iOS 26.0, *) { let glass = UIGlassEffect(style: .regular); glass.isInteractive = true; glass.tintColor = tint?.withAlphaComponent(0.24); material.effect = glass }
            else { material.effect = UIBlurEffect(style: .systemUltraThinMaterialDark); material.contentView.backgroundColor = tint?.withAlphaComponent(0.24) }
        }
    }
}

@MainActor
final class MenuValueButton: UIButton {
    private let valueLabel = phoneLabel(color: .systemBlue)
    private let symbol = UIImageView()
    private let chevron = UIImageView(image: UIImage(systemName: "chevron.up.chevron.down"))
    private let row = UIStackView()
    override init(frame: CGRect) {
        super.init(frame: frame)
        row.axis = .horizontal; row.spacing = 5; row.alignment = .center; row.isUserInteractionEnabled = false
        symbol.tintColor = .systemBlue; symbol.contentMode = .scaleAspectFit; chevron.tintColor = .systemBlue; chevron.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 12)
        symbol.widthAnchor.constraint(equalToConstant: 20).isActive = true
        valueLabel.setContentHuggingPriority(.required, for: .horizontal)
        chevron.setContentHuggingPriority(.required, for: .horizontal)
        [symbol, valueLabel, chevron].forEach { row.addArrangedSubview($0) }; row.translatesAutoresizingMaskIntoConstraints = false; addSubview(row)
        NSLayoutConstraint.activate([row.leadingAnchor.constraint(equalTo: leadingAnchor), row.trailingAnchor.constraint(equalTo: trailingAnchor), row.topAnchor.constraint(equalTo: topAnchor, constant: 6), row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6)])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func update(title: String, icon: String?) { valueLabel.text = title; symbol.image = icon.flatMap(UIImage.init(systemName:)); symbol.isHidden = icon == nil; accessibilityLabel = title; invalidateIntrinsicContentSize() }
    override var intrinsicContentSize: CGSize { CGSize(width: valueLabel.intrinsicContentSize.width + (symbol.isHidden ? 0 : 25) + 17, height: 32) }
}

@MainActor
func nativePhoneEmptyState(_ title: String, image: String, detail: String, minimumHeight: CGFloat) -> UIView {
    var configuration = UIContentUnavailableConfiguration.empty()
    configuration.text = title; configuration.image = UIImage(systemName: image); configuration.secondaryText = detail
    configuration.textProperties.font = UIFontMetrics(forTextStyle: .title3).scaledFont(for: .boldSystemFont(ofSize: 20))
    configuration.secondaryTextProperties.font = UIFontMetrics(forTextStyle: .title3).scaledFont(for: .systemFont(ofSize: 20))
    configuration.imageProperties.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 44)
    let view = UIContentUnavailableView(configuration: configuration)
    view.heightAnchor.constraint(greaterThanOrEqualToConstant: minimumHeight).isActive = true
    return view
}

#if DEBUG
#Preview("Root · Five Tabs") {
    RootViewController(previewPresentation: AirSIMPreviewFixtures.presentation())
}

#Preview("Root · Dark") {
    RootViewController(previewPresentation: AirSIMPreviewFixtures.presentation(appearance: .dark))
}

#Preview("Component · Table Cell") {
    let cell = PhoneTableCell(style: .subtitle, reuseIdentifier: nil)
    var content = cell.defaultContentConfiguration()
    content.text = "Mina Kim"
    content.secondaryText = "AirSIM Audio · Yesterday"
    content.image = UIImage(systemName: "phone.fill")
    cell.contentConfiguration = content
    return AirSIMPreviewFixtures.canvas(cell, height: 74)
}

#Preview("Component · Action Button") {
    AirSIMPreviewFixtures.canvas(phoneButton("Call", image: "phone.fill", color: .systemGreen) {}, width: 140, height: 52)
}

#Preview("Component · Phone Backdrop") {
    AirSIMPreviewFixtures.canvas(PhoneBackdropView(), height: 560, dark: true)
}

#Preview("Component · Phone List Row") {
    AirSIMPreviewFixtures.canvas(PhoneListContentView(name: "Mina Kim", subtitle: "↙ AirSIM Audio", photo: nil, avatarName: "Mina Kim", time: "10:42", callAction: {}), height: 74)
}

#Preview("Component · Bubble Label") {
    let label = BubbleLabel()
    label.text = "The label preserves multiline text and its message padding."
    label.font = .preferredFont(forTextStyle: .body)
    label.numberOfLines = 0
    label.textColor = .white
    label.backgroundColor = .systemBlue
    label.layer.cornerRadius = 18
    label.clipsToBounds = true
    return AirSIMPreviewFixtures.canvas(label, width: 300, height: 80)
}

#Preview("Component · Message Bubble") {
    AirSIMPreviewFixtures.canvas(PhoneMessageBubble(message: AirSIMPreviewFixtures.messages[1]), height: 90)
}

#Preview("Component · Call Backdrop") {
    AirSIMPreviewFixtures.canvas(CallBackdropView(), height: 600, dark: true)
}

#Preview("Component · Call Circle Control") {
    AirSIMPreviewFixtures.canvas(CallCircleControl(title: "End", icon: "phone.down.fill", size: 76, color: .systemRed) {}, width: 110, height: 108, dark: true)
}

#Preview("Component · Menu Value Button") {
    let button = MenuValueButton()
    button.update(title: "Automatic", icon: "arrow.triangle.branch")
    return AirSIMPreviewFixtures.canvas(button, width: 180, height: 44)
}

#Preview("Component · Custom Empty State") {
    AirSIMPreviewFixtures.canvas(phoneEmptyState("No recordings yet", image: "waveform", detail: "Tap Record during a connected call.", minimumHeight: 0, iconSize: 34, detailSize: 15, spacing: 12, verticalPadding: 40, headingSize: 17), height: 260)
}

#Preview("Component · Native Empty State") {
    AirSIMPreviewFixtures.canvas(nativePhoneEmptyState("No Recents", image: "phone.arrow.up.right", detail: "Your call history appears here after a call.", minimumHeight: 300), height: 320)
}
#endif
