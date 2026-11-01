import ComposableArchitecture
import UIKit

@MainActor
@ViewAction(for: MessagesFeature.self)
final class MessageThreadViewController: PhoneTableController, UITextViewDelegate {
    // MARK: Store

    let store: StoreOf<MessagesFeature>
    let sender: String

    // MARK: Views

    override var tableStyle: UITableView.Style { .plain }
    let reply = UITextView()
    private let replyPlaceholder = phoneLabel("Message", color: .placeholderText)
    private lazy var replyHeight = reply.heightAnchor.constraint(equalToConstant: Metrics.minimumReplyHeight)

    private lazy var sendButton = phoneButton("Send", image: "arrow.up.circle.fill") { [weak self] in
        guard let self else { return }
        send(.sendTapped(to: sender))
    }

    private var lastIDs: [String] = []
    private var firstLoad = true

    // MARK: Lifecycle

    init(store: StoreOf<MessagesFeature>, sender: String) {
        self.store = store
        self.sender = sender
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.largeTitleDisplayMode = .never
        buildTable()
        buildReplyField()
        buildSendButton()
        buildLayout()
        send(.threadLoaded(sender))
        presentAlert(from: store, state: \.alert, action: \.alert)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateReplyHeight()
        alignShortConversation()
    }

    override func didMove(toParent parent: UIViewController?) {
        super.didMove(toParent: parent)
        if parent == nil {
            send(.threadClosed(sender))
        }
    }

    // MARK: Rendering

    override func render() {
        title = store.state.threadTitle(for: sender)
        renderReply()
        renderMessages(store.state.messages(from: sender))
        alignShortConversation()
    }

    private func renderReply() {
        if reply.text != store.reply {
            reply.text = store.reply
        }
        updateReplyHeight()
        replyPlaceholder.isHidden = !store.reply.isEmpty
        sendButton.isEnabled = store.canSendReply
    }

    private func renderMessages(_ messages: [SMSMessage]) {
        let threshold = table.contentSize.height - Metrics.followNewMessagesSlack
        let wasAtBottom = firstLoad || table.contentOffset.y + table.bounds.height >= threshold
        let rows = messages.map(messageRow)
        let ids = rows.map(\.id)
        setSections([PhoneSection(rows: rows)])
        if ids != lastIDs, wasAtBottom, !rows.isEmpty {
            table.layoutIfNeeded()
            table.scrollToRow(at: IndexPath(row: rows.count - 1, section: 0), at: .bottom, animated: !firstLoad)
        }
        lastIDs = ids
        firstLoad = false
    }

    private func updateReplyHeight() {
        guard reply.bounds.width > 0 else { return }
        let keyboard = view.keyboardLayoutGuide.layoutFrame
        let safeArea = view.safeAreaLayoutGuide.layoutFrame
        let available = (keyboard.width > 0 ? keyboard.minY : safeArea.maxY) - safeArea.minY
        let maximum = max(Metrics.minimumReplyHeight, available / 2)
        let fitting = reply.sizeThatFits(CGSize(width: reply.bounds.width, height: .greatestFiniteMagnitude))
        let desired = max(Metrics.minimumReplyHeight, fitting.height)
        let height = min(desired, maximum)
        if abs(replyHeight.constant - height) > 0.5 {
            replyHeight.constant = height
        }
        reply.isScrollEnabled = desired > maximum
    }

    private func alignShortConversation() {
        let inset = max(0, table.bounds.height - table.contentSize.height - table.contentInset.bottom)
        if abs(table.contentInset.top - inset) > 1 {
            table.contentInset.top = inset
        }
        if inset > 0, abs(table.contentOffset.y + inset) > 1 {
            table.setContentOffset(CGPoint(x: 0, y: -inset), animated: false)
        }
    }

    // MARK: Rows

    private func messageRow(_ message: SMSMessage) -> PhoneRow {
        PhoneRow(
            id: String(describing: message.id),
            title: "",
            context: {
                UIMenu(children: [
                    UIAction(title: "Copy", image: UIImage(systemName: "doc.on.doc")) { _ in
                        UIPasteboard.general.string = message.content
                    }
                ])
            },
            bodyViewProvider: { PhoneMessageBubble(message: message) },
            bodyVersion: "\(message.isOutgoing)|\(message.content)",
            insets: Metrics.rowInsets
        )
    }

    // MARK: Layout

    private func buildTable() {
        table.separatorStyle = .none
        table.contentInsetAdjustmentBehavior = .never
        table.contentInset.bottom = Metrics.tableBottomInset
        table.removeFromSuperview()
    }

    private func buildReplyField() {
        reply.font = .preferredFont(forTextStyle: .body)
        reply.delegate = self
        reply.layer.cornerRadius = 4
        reply.backgroundColor = .systemBackground
        reply.accessibilityLabel = "Message"
        reply.layer.borderWidth = 0.5
        reply.layer.borderColor = UIColor.separator.cgColor
        reply.textContainerInset = Metrics.replyInsets
        replyPlaceholder.translatesAutoresizingMaskIntoConstraints = false
        reply.addSubview(replyPlaceholder)
        NSLayoutConstraint.activate([
            replyPlaceholder.leadingAnchor.constraint(equalTo: reply.leadingAnchor, constant: Metrics.replyInsets.left),
            replyPlaceholder.topAnchor.constraint(equalTo: reply.topAnchor, constant: Metrics.replyInsets.top),
        ])
        replyHeight.isActive = true
    }

    private func buildSendButton() {
        sendButton.configuration?.title = nil
        sendButton.configuration?.background.backgroundColor = .clear
        sendButton.widthAnchor.constraint(equalToConstant: Metrics.sendButtonWidth).isActive = true
        sendButton.isEnabled = false
    }

    private func buildLayout() {
        let bar = UIStackView([reply, sendButton], axis: .horizontal, spacing: Metrics.barSpacing, alignment: .center)
        bar.translatesAutoresizingMaskIntoConstraints = false
        let divider = UIView()
        divider.backgroundColor = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(table)
        view.addSubview(bar)
        view.addSubview(divider)
        NSLayoutConstraint.activate([
            divider.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            divider.heightAnchor.constraint(equalToConstant: Metrics.dividerHeight),
            divider.bottomAnchor.constraint(equalTo: bar.topAnchor, constant: -Metrics.barMargin),
        ])
        NSLayoutConstraint.activate([
            table.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            table.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            table.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            table.bottomAnchor.constraint(equalTo: bar.topAnchor, constant: -Metrics.barMargin),
        ])
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: Metrics.barMargin),
            bar.trailingAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.trailingAnchor,
                constant: -Metrics.barMargin
            ),
            bar.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -Metrics.barMargin),
        ])
    }

    // MARK: UITextViewDelegate

    func textViewDidChange(_ textView: UITextView) {
        send(.replyChanged(reply.text ?? ""))
    }
}

private enum Metrics {
    static let rowInsets = UIEdgeInsets(top: 4, left: 16, bottom: 4, right: 16)
    static let tableBottomInset: CGFloat = 12
    static let followNewMessagesSlack: CGFloat = 80
    static let replyInsets = UIEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
    static let minimumReplyHeight: CGFloat = 32
    static let sendButtonWidth: CGFloat = 26
    static let barSpacing: CGFloat = 10
    static let barMargin: CGFloat = 16
    static let dividerHeight: CGFloat = 0.5
}

#if DEBUG
#Preview("Messages · Thread") {
    let store = AirSIMPreviewFixtures.store(tab: .messages)
    return AirSIMPreviewFixtures.navigation(
        MessageThreadViewController(
            store: store.scope(state: \.messages, action: \.messages),
            sender: AirSIMPreviewFixtures.phone
        )
    )
}
#endif
