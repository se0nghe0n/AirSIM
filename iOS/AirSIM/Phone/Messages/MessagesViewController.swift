import UIKit

@MainActor
final class MessagesViewController: PhoneTableController, UINavigationControllerDelegate {
    private var applyingNavigation = false
    private var renderedThreadID: String?
    override var tableStyle: UITableView.Style { .plain }
    let model: AirSIMPresentation
    init(model: AirSIMPresentation) { self.model = model; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() {
        super.viewDidLoad(); title = "Messages"
        navigationController?.delegate = self
        let refresh = UIAction(title: "Refresh", image: UIImage(systemName: "arrow.clockwise")) { [weak self] _ in Task { await self?.model.refreshMessages() } }
        let clear = UIAction(title: "Clear all SMS", image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
            self?.confirmPhoneAction("Clear all SMS", message: "This permanently deletes local messages and undelivered module messages.") { [weak self] in
                self?.model.store.send(.command(.clearMessages))
            }
        }
        navigationItem.leftBarButtonItem = UIBarButtonItem(image: UIImage(systemName: "ellipsis"), menu: UIMenu(children: [refresh, clear]))
        navigationItem.leftBarButtonItem?.accessibilityLabel = "Message Actions"
        navigationItem.leftBarButtonItem?.tintColor = .systemBlue
        navigationItem.rightBarButtonItem = UIBarButtonItem(image: UIImage(systemName: "square.and.pencil"), primaryAction: UIAction { [weak self] _ in self?.compose(recipient: "") })
        navigationItem.rightBarButtonItem?.accessibilityLabel = "New Message"
    }
    override func render() {
        let rows = model.conversations.map { conversation -> PhoneRow in
            let contact = model.contacts.contact(for: conversation.sender)
            let name = contact?.name ?? model.contacts.displayName(for: conversation.sender)
            return PhoneRow(id: conversation.sender, title: name, detail: "\(conversation.messages.last?.content ?? "")\n\((conversation.messages.last?.timestamp ?? .now).formatted(date: .omitted, time: .shortened))", disclosure: true, action: { [weak self] in self?.openConversation(conversation.sender) }, photo: contact?.photoData, avatarName: contact == nil ? "" : name, bodyViewProvider: { PhoneListContentView(name: name, subtitle: conversation.messages.last?.content ?? "", photo: contact?.photoData, avatarName: contact == nil ? "" : name, time: (conversation.messages.last?.timestamp ?? .now).formatted(date: .omitted, time: .shortened)) }, insets: UIEdgeInsets(top: 0, left: 16, bottom: 0, right: 16))
        }
        setSections([PhoneSection(rows: rows.isEmpty ? [PhoneRow(id: "empty", title: "", bodyView: nativePhoneEmptyState("No Messages", image: "message", detail: "Received messages appear here.", minimumHeight: 180))] : rows)])
    }
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated); navigationController?.delegate = self
        Task { await model.loadMessagesFromAgent() }
    }
    /// The root presents the composer from state, above whatever sheet it currently shows.
    func compose(recipient: String) { model.store.send(.composeMessage(recipient)) }
    func openConversation(_ sender: String) {
        if model.store.messages.conversation != sender { model.store.send(.messages(.openConversation(sender))) }
        showConversationIfNeeded(sender)
    }
    func showConversationIfNeeded(_ sender: String) {
        guard model.store.messages.conversation == sender else { return }
        loadViewIfNeeded()
        guard let nav = navigationController else { return }
        guard !applyingNavigation else { return }
        // A pop exposes the destination stack before its transition completes.
        // Reapplying the same route here would replace the departing controller.
        guard renderedThreadID != sender else { return }
        if let current = nav.topViewController as? MessageThreadViewController, current.sender == sender { return }
        if let transition = nav.transitionCoordinator {
            transition.animate(alongsideTransition: nil) { [weak self] _ in
                Task { @MainActor [weak self] in self?.showConversationIfNeeded(sender) }
            }
            return
        }
        applyingNavigation = true
        renderedThreadID = sender
        nav.setViewControllers([self, MessageThreadViewController(model: model, sender: sender)], animated: false)
        applyingNavigation = false
    }
    func navigationController(_ navigationController: UINavigationController, didShow viewController: UIViewController, animated: Bool) {
        if viewController === self, !applyingNavigation, let previous = renderedThreadID {
            renderedThreadID = nil
            if model.store.messages.conversation == previous { model.store.send(.messages(.closeConversation)) }
        }
    }
}

#if DEBUG
#Preview("Messages · Conversations") {
    AirSIMPreviewFixtures.navigation(MessagesViewController(model: AirSIMPreviewFixtures.presentation(tab: .messages)))
}
#endif
