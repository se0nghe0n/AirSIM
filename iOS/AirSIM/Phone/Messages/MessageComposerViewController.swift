import ComposableArchitecture
import UIKit

/// Its presenter dismisses it from state; a swipe-down writes the closed state back through that presentation.
@MainActor
final class MessageComposerViewController: ObservingViewController, UITextViewDelegate {
    let model: AirSIMPresentation
    @UIBindable var store: StoreOf<ComposerFeature>
    let recipient = UITextField()
    let content = UITextView()
    private let suggestions = UIStackView()
    private let messagePlaceholder = phoneLabel("Message", color: .placeholderText)
    private let recognized = phoneLabel(size: 14)
    private let sendButton = phoneButton("Send", image: "arrow.up") {}
    private var contentHeight: NSLayoutConstraint!
    init(model: AirSIMPresentation, store: StoreOf<ComposerFeature>) { self.model = model; self.store = store; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() {
        super.viewDidLoad(); title = "New Message"; view.backgroundColor = .systemBackground; navigationItem.largeTitleDisplayMode = .never
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: "Cancel", primaryAction: UIAction { [weak self] _ in self?.store.send(.cancelButtonTapped) })
        navigationItem.leftBarButtonItem?.tintColor = .systemBlue
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "Send", primaryAction: UIAction { [weak self] _ in self?.store.send(.sendButtonTapped) })
        recipient.placeholder = "Enter number or name"; recipient.keyboardType = .phonePad; recipient.textContentType = .telephoneNumber; recipient.font = .preferredFont(forTextStyle: .body)
        recipient.addAction(UIAction { [weak self] _ in guard let self else { return }; self.store.send(.recipientChanged(self.recipient.text ?? "")) }, for: .editingChanged)
        let choose = phoneButton("Choose from Contacts", image: "plus.circle.fill", color: .label) { [weak self] in self?.chooseContact() }; choose.configuration?.title = nil; choose.configuration?.background.backgroundColor = .clear
        let to = phoneLabel("To:", color: .secondaryLabel)
        let recipientBar = UIStackView(arrangedSubviews: [choose, to, recipient, recognized]); recipientBar.axis = .horizontal; recipientBar.spacing = 9; recipientBar.alignment = .center
        choose.widthAnchor.constraint(equalToConstant: 26).isActive = true; to.setContentHuggingPriority(.required, for: .horizontal); recognized.setContentHuggingPriority(.required, for: .horizontal)
        recognized.font = .preferredFont(forTextStyle: .subheadline); recognized.numberOfLines = 1
        let suggestionScroll = UIScrollView(); suggestionScroll.showsHorizontalScrollIndicator = false; suggestions.axis = .horizontal; suggestions.spacing = 8; suggestions.translatesAutoresizingMaskIntoConstraints = false; suggestionScroll.addSubview(suggestions)
        NSLayoutConstraint.activate([suggestions.leadingAnchor.constraint(equalTo: suggestionScroll.contentLayoutGuide.leadingAnchor, constant: 16), suggestions.trailingAnchor.constraint(equalTo: suggestionScroll.contentLayoutGuide.trailingAnchor, constant: -16), suggestions.topAnchor.constraint(equalTo: suggestionScroll.contentLayoutGuide.topAnchor, constant: 8), suggestions.bottomAnchor.constraint(equalTo: suggestionScroll.contentLayoutGuide.bottomAnchor, constant: -8), suggestions.heightAnchor.constraint(equalTo: suggestionScroll.frameLayoutGuide.heightAnchor, constant: -16)])
        content.font = .preferredFont(forTextStyle: .body); content.delegate = self; content.backgroundColor = UIColor { $0.userInterfaceStyle == .dark ? .secondarySystemGroupedBackground : .white }; content.layer.cornerRadius = 18; content.textContainerInset = UIEdgeInsets(top: 9, left: 13, bottom: 9, right: 13); content.accessibilityLabel = "Message"
        messagePlaceholder.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(messagePlaceholder)
        NSLayoutConstraint.activate([messagePlaceholder.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 13), messagePlaceholder.topAnchor.constraint(equalTo: content.topAnchor, constant: 9)])
        contentHeight = content.heightAnchor.constraint(equalToConstant: 40); contentHeight.isActive = true
        sendButton.configuration?.title = nil; sendButton.configuration?.baseForegroundColor = .white; sendButton.configuration?.background.backgroundColor = .systemBlue; sendButton.widthAnchor.constraint(equalToConstant: 36).isActive = true; sendButton.heightAnchor.constraint(equalToConstant: 36).isActive = true
        sendButton.addAction(UIAction { [weak self] _ in self?.store.send(.sendButtonTapped) }, for: .touchUpInside)
        let entry = UIStackView(arrangedSubviews: [content, sendButton]); entry.axis = .horizontal; entry.spacing = 9; entry.alignment = .bottom
        let caption = phoneLabel("Messages are sent through the 4G module", size: 11, color: .tertiaryLabel); caption.textAlignment = .center
        let bottom = UIStackView(arrangedSubviews: [entry, caption]); bottom.axis = .vertical; bottom.spacing = 5
        [recipientBar, suggestionScroll, bottom].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; view.addSubview($0) }
        for (anchor, offset) in [(recipientBar.bottomAnchor, CGFloat(0)), (bottom.topAnchor, CGFloat(-10))] {
            let separator = UIView(); separator.backgroundColor = UIColor.separator.withAlphaComponent(0.10); separator.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(separator)
            NSLayoutConstraint.activate([separator.leadingAnchor.constraint(equalTo: view.leadingAnchor), separator.trailingAnchor.constraint(equalTo: view.trailingAnchor), separator.heightAnchor.constraint(equalToConstant: 0.5), separator.topAnchor.constraint(equalTo: anchor, constant: offset)])
        }
        navigationItem.rightBarButtonItem?.setTitleTextAttributes([.foregroundColor: UIColor { $0.userInterfaceStyle == .dark ? .secondaryLabel : UIColor(white: 176.0 / 255.0, alpha: 1) }], for: .disabled)
        NSLayoutConstraint.activate([recipientBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16), recipientBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16), recipientBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor), recipientBar.heightAnchor.constraint(equalToConstant: 52), suggestionScroll.topAnchor.constraint(equalTo: recipientBar.bottomAnchor), suggestionScroll.leadingAnchor.constraint(equalTo: view.leadingAnchor), suggestionScroll.trailingAnchor.constraint(equalTo: view.trailingAnchor), suggestionScroll.heightAnchor.constraint(equalToConstant: 60), bottom.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16), bottom.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16), bottom.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -10)])
        present(item: $store.scope(\.$alert, action: \.alert)) { UIAlertController(store: $0) }
        Task { await model.contacts.loadIfAuthorized() }
    }
    func textViewDidChange(_ textView: UITextView) { store.send(.bodyChanged(content.text ?? "")) }
    override func render() {
        let state = store.state
        if recipient.text != state.recipient { recipient.text = state.recipient }
        if content.text != state.body { content.text = state.body }
        contentHeight.constant = min(130, max(40, content.sizeThatFits(CGSize(width: max(180, content.bounds.width), height: .greatestFiniteMagnitude)).height))
        let canSend = state.canSend
        sendButton.isEnabled = canSend; sendButton.alpha = 1
        sendButton.configuration?.background.backgroundColor = canSend ? .systemBlue : UIColor { $0.userInterfaceStyle == .dark ? .systemGray5 : UIColor(white: 232.0 / 255.0, alpha: 1) }
        sendButton.configuration?.image = UIImage(systemName: "arrow.up")?.withTintColor(.white, renderingMode: .alwaysOriginal)
        messagePlaceholder.isHidden = !state.body.isEmpty
        navigationItem.rightBarButtonItem?.isEnabled = canSend
        let matched = model.contacts.contact(for: state.recipient); recognized.text = matched?.name; recognized.isHidden = matched == nil
        recognized.accessibilityLabel = matched.map { "Recognized contact: \($0.name)" }
        suggestions.arrangedSubviews.forEach { suggestions.removeArrangedSubview($0); $0.removeFromSuperview() }
        let query = state.recipient.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty, matched == nil {
            for contact in model.contacts.contacts.filter({ $0.name.localizedCaseInsensitiveContains(query) || $0.phones.contains { $0.localizedCaseInsensitiveContains(query) || $0.hasSuffix(query) } }).prefix(5) {
                let button = phoneButton(contact.name) { [weak self] in self?.store.send(.recipientChanged(contact.phones.first ?? query)) }
                button.configuration?.subtitle = contact.phones.first; suggestions.addArrangedSubview(button)
            }
        }
    }
    private func chooseContact() {
        let picker = ContactsViewController(model: model, onCall: { _ in }, onMessage: { _ in })
        picker.onSelect = { [weak self] phone in self?.store.send(.recipientChanged(phone)); self?.dismiss(animated: true) }
        showPhoneSheet(picker)
    }
}

#if DEBUG
#Preview("Messages · Composer") {
    let model = AirSIMPreviewFixtures.presentation(tab: .messages)
    model.store.send(.composeMessage(AirSIMPreviewFixtures.phone))
    let composer = model.store.scope(\.messages.composer, action: \.messages.composer.presented)!
    composer.send(.bodyChanged("I will be there in five minutes."))
    return AirSIMPreviewFixtures.navigation(MessageComposerViewController(model: model, store: composer))
}
#endif
