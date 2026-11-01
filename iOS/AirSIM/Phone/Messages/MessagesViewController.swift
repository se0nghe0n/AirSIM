import ComposableArchitecture
import UIKit

/// The Messages tab's conversation list. It pushes the open conversation's thread and reconciles a native Back
/// with the feature.
@MainActor
@ViewAction(for: MessagesFeature.self)
final class MessagesViewController: PhoneTableController, UINavigationControllerDelegate {
    // MARK: Store

    let store: StoreOf<MessagesFeature>

    // MARK: Views

    override var tableStyle: UITableView.Style { .plain }

    // MARK: Lifecycle

    init(store: StoreOf<MessagesFeature>) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Messages"
        navigationController?.delegate = self
        buildNavigationItems()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.delegate = self
        send(.appeared)
    }

    // MARK: Rendering

    override func render() {
        let rows = store.conversationRows
        setSections([PhoneSection(rows: rows.isEmpty ? [emptyRow()] : rows.map(conversationRow))])
    }

    // MARK: Rows

    private func conversationRow(_ row: ConversationRow) -> PhoneRow {
        PhoneRow(
            id: row.id,
            title: row.name,
            detail: row.detail,
            disclosure: true,
            action: { [weak self] in self?.openConversation(row.sender) },
            photo: row.photo,
            avatarName: row.avatarName,
            bodyViewProvider: {
                PhoneListContentView(
                    name: row.name,
                    subtitle: row.lastMessage,
                    photo: row.photo,
                    avatarName: row.avatarName,
                    time: row.time
                )
            },
            insets: Metrics.rowInsets
        )
    }

    private func emptyRow() -> PhoneRow {
        PhoneRow(
            id: "empty",
            title: "",
            bodyView: nativePhoneEmptyState(
                "No Messages",
                image: "message",
                detail: "Received messages appear here.",
                minimumHeight: 180
            )
        )
    }

    // MARK: Layout

    private func buildNavigationItems() {
        let refresh = UIAction(title: "Refresh", image: UIImage(systemName: "arrow.clockwise")) { [weak self] _ in
            self?.send(.refreshTapped)
        }
        let clear = UIAction(
            title: "Clear all SMS",
            image: UIImage(systemName: "trash"),
            attributes: .destructive
        ) { [weak self] _ in
            self?.confirmClear()
        }
        let actions = UIBarButtonItem(image: UIImage(systemName: "ellipsis"), menu: UIMenu(children: [refresh, clear]))
        actions.accessibilityLabel = "Message Actions"
        actions.tintColor = .systemBlue
        let compose = UIBarButtonItem(
            image: UIImage(systemName: "square.and.pencil"),
            primaryAction: UIAction { [weak self] _ in self?.send(.composeTapped) }
        )
        compose.accessibilityLabel = "New Message"
        navigationItem.leftBarButtonItem = actions
        navigationItem.rightBarButtonItem = compose
    }

    // MARK: Navigation

    private var applyingNavigation = false
    private var renderedThreadID: String?

    func openConversation(_ sender: String) {
        send(.conversationTapped(sender))
        showConversationIfNeeded(sender)
    }

    /// Pushes the open conversation's thread unless it is already on top or on its way out.
    func showConversationIfNeeded(_ sender: String) {
        guard store.conversation == sender else { return }
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
        nav.setViewControllers([self, MessageThreadViewController(store: store, sender: sender)], animated: false)
        applyingNavigation = false
    }

    // MARK: Actions

    private func confirmClear() {
        confirmPhoneAction(
            "Clear all SMS",
            message: "This permanently deletes local messages and undelivered module messages."
        ) { [weak self] in
            self?.send(.clearConfirmed)
        }
    }

    // MARK: UINavigationControllerDelegate

    /// A native Back to this list closes the thread it last pushed.
    func navigationController(
        _ navigationController: UINavigationController,
        didShow viewController: UIViewController,
        animated: Bool
    ) {
        guard viewController === self, !applyingNavigation, let previous = renderedThreadID else { return }
        renderedThreadID = nil
        send(.threadClosed(previous))
    }
}

private enum Metrics {
    static let rowInsets = UIEdgeInsets(top: 0, left: 16, bottom: 0, right: 16)
}

#if DEBUG
#Preview("Messages · Conversations") {
    let store = AirSIMPreviewFixtures.store(tab: .messages)
    return AirSIMPreviewFixtures.navigation(
        MessagesViewController(store: store.scope(state: \.messages, action: \.messages))
    )
}
#endif
