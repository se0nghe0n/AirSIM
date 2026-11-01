import UIKit

@MainActor
final class MessageThreadViewController: PhoneTableController, UITextViewDelegate {
    override var tableStyle: UITableView.Style { .plain }
    let model: AirSIMPresentation
    let sender: String
    let reply = UITextView()
    private let replyPlaceholder = phoneLabel("Message", color: .placeholderText)
    private var sendButton: UIButton!
    private var replyHeight: NSLayoutConstraint!
    private var lastIDs: [String] = []
    private var firstLoad = true
    init(model: AirSIMPresentation, sender: String) { self.model = model; self.sender = sender; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() {
        super.viewDidLoad(); navigationItem.largeTitleDisplayMode = .never
        table.separatorStyle = .none
        table.contentInsetAdjustmentBehavior = .never
        table.contentInset.bottom = 12
        table.removeFromSuperview()
        let bar = UIStackView(); bar.axis = .horizontal; bar.spacing = 10; bar.alignment = .center
        reply.font = .preferredFont(forTextStyle: .body); reply.delegate = self; reply.layer.cornerRadius = 4; reply.backgroundColor = .systemBackground; reply.accessibilityLabel = "Message"
        reply.layer.borderWidth = 0.5; reply.layer.borderColor = UIColor.separator.cgColor
        reply.textContainerInset = UIEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
        replyPlaceholder.translatesAutoresizingMaskIntoConstraints = false; reply.addSubview(replyPlaceholder)
        NSLayoutConstraint.activate([replyPlaceholder.leadingAnchor.constraint(equalTo: reply.leadingAnchor, constant: 8), replyPlaceholder.topAnchor.constraint(equalTo: reply.topAnchor, constant: 4)])
        replyHeight = reply.heightAnchor.constraint(equalToConstant: 32); replyHeight.isActive = true
        sendButton = phoneButton("Send", image: "arrow.up.circle.fill") { [weak self] in
            guard let self else { return }
            self.model.store.send(.messages(.sendReply(to: self.sender)))
        }
        if model.store.messages.conversation != sender { model.store.send(.messages(.openConversation(sender))) }
        let store = model.store
        presentAlert({ store.messages.alert }, send: { store.send(.messages(.alert($0))) })
        sendButton.configuration?.title = nil; sendButton.configuration?.background.backgroundColor = .clear
        sendButton.widthAnchor.constraint(equalToConstant: 26).isActive = true
        sendButton.isEnabled = false; bar.addArrangedSubview(reply); bar.addArrangedSubview(sendButton)
        view.addSubview(table); view.addSubview(bar); bar.translatesAutoresizingMaskIntoConstraints = false
        let divider = UIView(); divider.backgroundColor = .separator; divider.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(divider)
        NSLayoutConstraint.activate([divider.leadingAnchor.constraint(equalTo: view.leadingAnchor), divider.trailingAnchor.constraint(equalTo: view.trailingAnchor), divider.heightAnchor.constraint(equalToConstant: 0.5), divider.bottomAnchor.constraint(equalTo: bar.topAnchor, constant: -16)])
        NSLayoutConstraint.activate([table.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor), table.leadingAnchor.constraint(equalTo: view.leadingAnchor), table.trailingAnchor.constraint(equalTo: view.trailingAnchor), table.bottomAnchor.constraint(equalTo: bar.topAnchor, constant: -16), bar.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16), bar.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16), bar.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -16)])
    }
    override func didMove(toParent parent: UIViewController?) {
        super.didMove(toParent: parent)
        if parent == nil, model.store.messages.conversation == sender { model.store.send(.messages(.closeConversation)) }
    }
    func textViewDidChange(_ textView: UITextView) { model.store.send(.messages(.replyChanged(reply.text ?? ""))) }
    override func render() {
        title = model.contacts.displayName(for: sender)
        let feature = model.store.messages
        if reply.text != feature.reply { reply.text = feature.reply }
        updateReplyHeight()
        replyPlaceholder.isHidden = !feature.reply.isEmpty
        sendButton.isEnabled = !feature.sending && !feature.reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let messages = model.messages.filter { $0.sender == sender }.sorted { $0.timestamp < $1.timestamp }
        let wasAtBottom = firstLoad || table.contentOffset.y + table.bounds.height >= table.contentSize.height - 80
        let rows = messages.map { message in PhoneRow(id: String(describing: message.id), title: "", context: { UIMenu(children: [UIAction(title: "Copy", image: UIImage(systemName: "doc.on.doc")) { _ in UIPasteboard.general.string = message.content }]) }, bodyViewProvider: { PhoneMessageBubble(message: message) }, bodyVersion: "\(message.isOutgoing)|\(message.content)", insets: UIEdgeInsets(top: 4, left: 16, bottom: 4, right: 16)) }
        let ids = rows.map(\.id); setSections([PhoneSection(rows: rows)])
        if ids != lastIDs, wasAtBottom, !rows.isEmpty { table.layoutIfNeeded(); table.scrollToRow(at: IndexPath(row: rows.count - 1, section: 0), at: .bottom, animated: !firstLoad) }
        lastIDs = ids; firstLoad = false
        alignShortConversation()
    }
    override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); updateReplyHeight(); alignShortConversation() }
    private func updateReplyHeight() {
        guard reply.bounds.width > 0 else { return }
        let keyboard = view.keyboardLayoutGuide.layoutFrame
        let safeArea = view.safeAreaLayoutGuide.layoutFrame
        let available = (keyboard.width > 0 ? keyboard.minY : safeArea.maxY) - safeArea.minY
        let maximum = max(32, available / 2)
        let desired = max(32, reply.sizeThatFits(CGSize(width: reply.bounds.width, height: .greatestFiniteMagnitude)).height)
        let height = min(desired, maximum)
        if abs(replyHeight.constant - height) > 0.5 { replyHeight.constant = height }
        reply.isScrollEnabled = desired > maximum
    }
    private func alignShortConversation() {
        let inset = max(0, table.bounds.height - table.contentSize.height - table.contentInset.bottom)
        if abs(table.contentInset.top - inset) > 1 { table.contentInset.top = inset }
        if inset > 0, abs(table.contentOffset.y + inset) > 1 { table.setContentOffset(CGPoint(x: 0, y: -inset), animated: false) }
    }
}

#if DEBUG
#Preview("Messages · Thread") {
    let model = AirSIMPreviewFixtures.presentation(tab: .messages)
    model.store.send(.messages(.openConversation(AirSIMPreviewFixtures.phone)))
    return AirSIMPreviewFixtures.navigation(MessageThreadViewController(model: model, sender: AirSIMPreviewFixtures.phone))
}
#endif
