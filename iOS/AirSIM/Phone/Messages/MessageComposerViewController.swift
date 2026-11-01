import ComposableArchitecture
import UIKit

@MainActor
@ViewAction(for: ComposerFeature.self)
final class MessageComposerViewController: ObservingViewController, UITextViewDelegate {
    // MARK: Store

    let store: StoreOf<ComposerFeature>

    // MARK: Views

    let recipient = UITextField()
    let content = UITextView()
    private let recognized = phoneLabel(size: 14)
    private let suggestions = UIStackView(axis: .horizontal, spacing: Metrics.suggestionSpacing)
    private let messagePlaceholder = phoneLabel("Message", color: .placeholderText)
    private lazy var contentHeight = content.heightAnchor.constraint(equalToConstant: Metrics.minimumContentHeight)

    private lazy var sendButton = phoneButton("Send", image: "arrow.up") { [weak self] in
        self?.send(.sendButtonTapped)
    }

    // MARK: Lifecycle

    init(store: StoreOf<ComposerFeature>) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "New Message"
        view.backgroundColor = .systemBackground
        navigationItem.largeTitleDisplayMode = .never
        buildNavigationItems()
        let recipientBar = buildRecipientBar()
        let suggestionScroll = buildSuggestionScroll()
        let entry = buildEntry()
        buildLayout(recipientBar: recipientBar, suggestionScroll: suggestionScroll, entry: entry)
        bindPresentations()
        send(.opened)
    }

    // MARK: Rendering

    override func render() {
        renderText()
        renderSendControls()
        renderRecognizedContact()
        renderSuggestions()
    }

    private func renderText() {
        if recipient.text != store.recipient {
            recipient.text = store.recipient
        }
        if content.text != store.body {
            content.text = store.body
        }
        let fittingWidth = max(Metrics.minimumContentFittingWidth, content.bounds.width)
        let fitting = content.sizeThatFits(CGSize(width: fittingWidth, height: .greatestFiniteMagnitude))
        contentHeight.constant = min(Metrics.maximumContentHeight, max(Metrics.minimumContentHeight, fitting.height))
        messagePlaceholder.isHidden = !store.body.isEmpty
    }

    private func renderSendControls() {
        let canSend = store.canSend
        sendButton.isEnabled = canSend
        sendButton.alpha = 1
        sendButton.configuration?.background.backgroundColor =
            canSend
            ? .systemBlue
            : UIColor { $0.userInterfaceStyle == .dark ? .systemGray5 : UIColor(white: 232.0 / 255.0, alpha: 1) }
        sendButton.configuration?.image = UIImage(systemName: "arrow.up")?
            .withTintColor(.white, renderingMode: .alwaysOriginal)
        navigationItem.rightBarButtonItem?.isEnabled = canSend
    }

    private func renderRecognizedContact() {
        let name = store.recognizedName
        recognized.text = name
        recognized.isHidden = name == nil
        recognized.accessibilityLabel = name.map { "Recognized contact: \($0)" }
    }

    private func renderSuggestions() {
        for button in suggestions.arrangedSubviews {
            suggestions.removeArrangedSubview(button)
            button.removeFromSuperview()
        }
        for suggestion in store.suggestions {
            let button = phoneButton(suggestion.name) { [weak self] in
                self?.send(.recipientChanged(suggestion.recipient))
            }
            button.configuration?.subtitle = suggestion.phone
            suggestions.addArrangedSubview(button)
        }
    }

    // MARK: Layout

    private func buildNavigationItems() {
        let cancelItem = UIBarButtonItem(
            title: "Cancel",
            primaryAction: UIAction { [weak self] _ in self?.send(.cancelButtonTapped) }
        )
        cancelItem.tintColor = .systemBlue
        let sendItem = UIBarButtonItem(
            title: "Send",
            primaryAction: UIAction { [weak self] _ in self?.send(.sendButtonTapped) }
        )
        let disabledTitle = UIColor { traits in
            traits.userInterfaceStyle == .dark ? .secondaryLabel : UIColor(white: 176.0 / 255.0, alpha: 1)
        }
        sendItem.setTitleTextAttributes([.foregroundColor: disabledTitle], for: .disabled)
        navigationItem.leftBarButtonItem = cancelItem
        navigationItem.rightBarButtonItem = sendItem
    }

    private func buildRecipientBar() -> UIStackView {
        recipient.placeholder = "Enter number or name"
        recipient.keyboardType = .phonePad
        recipient.textContentType = .telephoneNumber
        recipient.font = .preferredFont(forTextStyle: .body)
        recipient.addAction(
            UIAction { [weak self] _ in
                guard let self else { return }
                send(.recipientChanged(recipient.text ?? ""))
            },
            for: .editingChanged
        )
        let choose = phoneButton("Choose from Contacts", image: "plus.circle.fill", color: .label) { [weak self] in
            self?.send(.chooseContactTapped)
        }
        choose.configuration?.title = nil
        choose.configuration?.background.backgroundColor = .clear
        choose.widthAnchor.constraint(equalToConstant: Metrics.chooseButtonWidth).isActive = true
        let to = phoneLabel("To:", color: .secondaryLabel)
        to.setContentHuggingPriority(.required, for: .horizontal)
        recognized.setContentHuggingPriority(.required, for: .horizontal)
        recognized.font = .preferredFont(forTextStyle: .subheadline)
        recognized.numberOfLines = 1
        return UIStackView(
            [choose, to, recipient, recognized],
            axis: .horizontal,
            spacing: Metrics.itemSpacing,
            alignment: .center
        )
    }

    private func buildSuggestionScroll() -> UIScrollView {
        let scroll = UIScrollView()
        scroll.showsHorizontalScrollIndicator = false
        suggestions.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(suggestions)
        let guide = scroll.contentLayoutGuide
        NSLayoutConstraint.activate([
            suggestions.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: Metrics.horizontalMargin),
            suggestions.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -Metrics.horizontalMargin),
            suggestions.topAnchor.constraint(equalTo: guide.topAnchor, constant: Metrics.suggestionPadding),
            suggestions.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -Metrics.suggestionPadding),
            suggestions.heightAnchor.constraint(
                equalTo: scroll.frameLayoutGuide.heightAnchor,
                constant: -2 * Metrics.suggestionPadding
            ),
        ])
        return scroll
    }

    private func buildEntry() -> UIStackView {
        content.font = .preferredFont(forTextStyle: .body)
        content.delegate = self
        content.backgroundColor = UIColor {
            $0.userInterfaceStyle == .dark ? .secondarySystemGroupedBackground : .white
        }
        content.layer.cornerRadius = 18
        content.textContainerInset = Metrics.textInsets
        content.accessibilityLabel = "Message"
        messagePlaceholder.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(messagePlaceholder)
        NSLayoutConstraint.activate([
            messagePlaceholder.leadingAnchor.constraint(
                equalTo: content.leadingAnchor,
                constant: Metrics.textInsets.left
            ),
            messagePlaceholder.topAnchor.constraint(equalTo: content.topAnchor, constant: Metrics.textInsets.top),
        ])
        contentHeight.isActive = true
        sendButton.configuration?.title = nil
        sendButton.configuration?.baseForegroundColor = .white
        sendButton.configuration?.background.backgroundColor = .systemBlue
        NSLayoutConstraint.activate([
            sendButton.widthAnchor.constraint(equalToConstant: Metrics.sendButtonSize),
            sendButton.heightAnchor.constraint(equalToConstant: Metrics.sendButtonSize),
        ])
        let field = UIStackView(
            [content, sendButton],
            axis: .horizontal,
            spacing: Metrics.itemSpacing,
            alignment: .bottom
        )
        let caption = phoneLabel("Messages are sent through the 4G module", size: 11, color: .tertiaryLabel)
        caption.textAlignment = .center
        return UIStackView([field, caption], axis: .vertical, spacing: Metrics.captionSpacing)
    }

    private func buildLayout(recipientBar: UIView, suggestionScroll: UIView, entry: UIView) {
        for part in [recipientBar, suggestionScroll, entry] {
            part.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(part)
        }
        addSeparator(top: recipientBar.bottomAnchor, offset: 0)
        addSeparator(top: entry.topAnchor, offset: -Metrics.entryMargin)
        NSLayoutConstraint.activate([
            recipientBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Metrics.horizontalMargin),
            recipientBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -Metrics.horizontalMargin),
            recipientBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            recipientBar.heightAnchor.constraint(equalToConstant: Metrics.recipientBarHeight),
        ])
        NSLayoutConstraint.activate([
            suggestionScroll.topAnchor.constraint(equalTo: recipientBar.bottomAnchor),
            suggestionScroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            suggestionScroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            suggestionScroll.heightAnchor.constraint(equalToConstant: Metrics.suggestionScrollHeight),
        ])
        NSLayoutConstraint.activate([
            entry.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Metrics.horizontalMargin),
            entry.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -Metrics.horizontalMargin),
            entry.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -Metrics.entryMargin),
        ])
    }

    private func addSeparator(top anchor: NSLayoutYAxisAnchor, offset: CGFloat) {
        let separator = UIView()
        separator.backgroundColor = UIColor.separator.withAlphaComponent(0.10)
        separator.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(separator)
        NSLayoutConstraint.activate([
            separator.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            separator.heightAnchor.constraint(equalToConstant: Metrics.separatorHeight),
            separator.topAnchor.constraint(equalTo: anchor, constant: offset),
        ])
    }

    // MARK: Navigation

    private func bindPresentations() {
        let bindable = UIBindable(store)
        present(item: bindable.scope(\.$alert, action: \.alert)) { UIAlertController(store: $0) }
        present(item: bindable.scope(\.$contactPicker, action: \.contactPicker)) {
            phoneSheet(ContactsViewController(store: $0))
        }
    }

    // MARK: UITextViewDelegate

    func textViewDidChange(_ textView: UITextView) {
        send(.bodyChanged(content.text ?? ""))
    }
}

private enum Metrics {
    static let horizontalMargin: CGFloat = 16
    static let itemSpacing: CGFloat = 9
    static let recipientBarHeight: CGFloat = 52
    static let chooseButtonWidth: CGFloat = 26
    static let suggestionScrollHeight: CGFloat = 60
    static let suggestionSpacing: CGFloat = 8
    static let suggestionPadding: CGFloat = 8
    static let textInsets = UIEdgeInsets(top: 9, left: 13, bottom: 9, right: 13)
    static let minimumContentHeight: CGFloat = 40
    static let maximumContentHeight: CGFloat = 130
    static let minimumContentFittingWidth: CGFloat = 180
    static let sendButtonSize: CGFloat = 36
    static let captionSpacing: CGFloat = 5
    static let entryMargin: CGFloat = 10
    static let separatorHeight: CGFloat = 0.5
}

#if DEBUG
#Preview("Messages · Composer") {
    let store = AirSIMPreviewFixtures.store(tab: .messages)
    store.send(.composeMessage(AirSIMPreviewFixtures.phone))
    let composer = store.scope(\.messages.composer, action: \.messages.composer.presented)!
    composer.send(.view(.bodyChanged("I will be there in five minutes.")))
    return AirSIMPreviewFixtures.navigation(MessageComposerViewController(store: composer))
}
#endif
