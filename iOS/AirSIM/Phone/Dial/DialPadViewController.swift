import ComposableArchitecture
import UIKit

@MainActor
@ViewAction(for: DialFeature.self)
final class DialPadViewController: ObservingViewController {
    // MARK: Store

    let store: StoreOf<DialFeature>

    // MARK: Views

    private let stack = UIStackView(axis: .vertical, spacing: Metrics.initialSectionSpacing, alignment: .center)
    private let numberLabel = phoneLabel(size: 36)
    private let contactLabel = phoneLabel(size: 16, color: .systemGreen)

    private lazy var agentButton = phoneButton("Paired Android Agents") { [weak self] in
        self?.showPairedAgents()
    }

    private var agentCard: UIView?
    private var keys: [(key: DialKey, button: UIButton)] = []

    private lazy var callButton = phoneButton("Dial", image: "phone.fill", color: .white) { [weak self] in
        self?.send(.callTapped)
    }

    private let deleteButton = phoneButton("Delete", image: "delete.left", color: .secondaryLabel) {}
    private var keypadRows: [UIStackView] = []
    private var keypadRowWidths: [NSLayoutConstraint] = []
    private lazy var contentWidth = stack.widthAnchor.constraint(equalToConstant: Metrics.initialContentWidth)
    private lazy var numberHeight = numberLabel.heightAnchor.constraint(equalToConstant: Metrics.initialNumberHeight)
    private lazy var contactHeight = contactLabel.heightAnchor.constraint(equalToConstant: Metrics.initialContactHeight)
    private lazy var agentHeight = agentButton.heightAnchor.constraint(equalToConstant: Metrics.agentCardHeight)
    private var keyHeight: NSLayoutConstraint?
    private var lastLayoutSize = CGSize.zero

    // MARK: Lifecycle

    init(store: StoreOf<DialFeature>) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.title = "Dial"
        navigationItem.largeTitleDisplayMode = .never
        buildBackdrop()
        buildStack()
        buildNumber()
        buildAgentButton()
        buildKeypad()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(true, animated: false)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        send(.disappeared)
        navigationController?.setNavigationBarHidden(false, animated: false)
    }

    // MARK: Rendering

    override func render() {
        renderNumber()
        renderButtons()
        renderAgentCard()
    }

    private func renderNumber() {
        numberLabel.text = store.displayText
        numberLabel.textColor = store.showsPlaceholder ? .secondaryLabel : .label
        contactLabel.text = store.contactName ?? " "
    }

    private func renderButtons() {
        callButton.isEnabled = store.canCall
        let opacity = store.callIsDimmed ? Metrics.dimmedCallOpacity : 1
        callButton.alpha = callButton.isEnabled ? opacity : opacity * Metrics.disabledCallOpacityFactor
        deleteButton.isEnabled = store.canDelete
    }

    private func renderAgentCard() {
        agentButton.isHidden = !store.showsAgentCard
        agentButton.configuration = nil
        agentCard?.removeFromSuperview()
        let card = AndroidAgentCardView(
            agent: store.currentAgent,
            count: store.agentCount,
            cloudEnabled: store.cloudModeEnabled
        )
        card.isUserInteractionEnabled = false
        agentButton.addPinnedSubview(card)
        agentCard = card
        agentHeight.constant =
            store.currentAgent == nil
            ? Metrics.agentCardHeightWithoutCurrent
            : Metrics.agentCardHeight
    }

    // MARK: Layout

    private func buildBackdrop() {
        let backdrop = PhoneBackdropView()
        backdrop.isUserInteractionEnabled = false
        backdrop.accessibilityElementsHidden = true
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        view.insertSubview(backdrop, at: 0)
        NSLayoutConstraint.activate([
            backdrop.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            backdrop.topAnchor.constraint(equalTo: view.topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func buildStack() {
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        let safeArea = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            contentWidth,
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: Metrics.maximumContentWidth),
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: safeArea.centerYAnchor),
        ])
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: Metrics.sideMargin),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -Metrics.sideMargin),
            stack.topAnchor.constraint(greaterThanOrEqualTo: safeArea.topAnchor, constant: Metrics.verticalMargin),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: safeArea.bottomAnchor, constant: -Metrics.verticalMargin),
        ])
    }

    private func buildNumber() {
        numberLabel.font = UIFont.systemFont(ofSize: 36, weight: .light).rounded()
        numberLabel.adjustsFontSizeToFitWidth = true
        numberLabel.minimumScaleFactor = 0.45
        numberLabel.numberOfLines = 1
        numberLabel.textAlignment = .center
        stack.addArrangedSubview(numberLabel)
        stack.setCustomSpacing(Metrics.numberToContactSpacing, after: numberLabel)
        stack.addArrangedSubview(contactLabel)
        NSLayoutConstraint.activate([
            numberHeight,
            contactHeight,
        ])
    }

    private func buildAgentButton() {
        agentButton.titleLabel?.numberOfLines = 3
        stack.addArrangedSubview(agentButton)
        NSLayoutConstraint.activate([
            agentButton.widthAnchor.constraint(equalTo: stack.widthAnchor),
            agentHeight,
        ])
    }

    private func buildKeypad() {
        for keyRow in DialKey.rows {
            let row = UIStackView(axis: .horizontal, spacing: Metrics.initialKeySpacing, distribution: .fillEqually)
            for key in keyRow {
                let button = keyButton(key)
                row.addArrangedSubview(button)
                keys.append((key, button))
            }
            addKeypadRow(row)
        }
        configureCallButton()
        configureDeleteButton()
        let actions = UIStackView(
            [UIView(), callButton, deleteButton],
            axis: .horizontal,
            spacing: Metrics.initialKeySpacing,
            distribution: .fillEqually
        )
        addKeypadRow(actions)
        let firstKey = keys[0].button
        let keyHeight = firstKey.heightAnchor.constraint(equalToConstant: Metrics.initialKeySize)
        NSLayoutConstraint.activate([
            actions.heightAnchor.constraint(equalTo: firstKey.heightAnchor),
            keyHeight,
        ])
        self.keyHeight = keyHeight
    }

    private func addKeypadRow(_ row: UIStackView) {
        stack.addArrangedSubview(row)
        let width = row.widthAnchor.constraint(equalToConstant: Metrics.initialKeypadWidth)
        width.isActive = true
        keypadRows.append(row)
        keypadRowWidths.append(width)
    }

    private func keyButton(_ key: DialKey) -> UIButton {
        let button = phoneButton(key.digit, color: .label) { [weak self] in
            self?.digitTapped(key.digit)
        }
        button.configuration = keyConfiguration(key)
        button.accessibilityLabel = key.accessibilityLabel
        button.widthAnchor.constraint(equalTo: button.heightAnchor).isActive = true
        if key.digit == "0" {
            let longPress = UILongPressGestureRecognizer(target: self, action: #selector(zeroLongPressed(_:)))
            button.addGestureRecognizer(longPress)
        }
        return button
    }

    private func keyConfiguration(_ key: DialKey) -> UIButton.Configuration {
        var configuration: UIButton.Configuration
        if #available(iOS 26.0, *) {
            configuration = .glass()
        } else {
            configuration = .gray()
        }
        configuration.baseForegroundColor = .label
        configuration.cornerStyle = .capsule
        var digitAttributes = AttributeContainer()
        digitAttributes.font = UIFontMetrics(forTextStyle: .title1)
            .scaledFont(for: .systemFont(ofSize: 31, weight: .regular))
        var letterAttributes = AttributeContainer()
        letterAttributes.font = UIFontMetrics(forTextStyle: .caption2)
            .scaledFont(for: .systemFont(ofSize: 10, weight: .semibold))
        configuration.attributedTitle = AttributedString(key.digit, attributes: digitAttributes)
        configuration.attributedSubtitle = AttributedString(key.letters, attributes: letterAttributes)
        configuration.titleAlignment = .center
        configuration.titlePadding = 0
        if #unavailable(iOS 26.0) {
            configuration.background.backgroundColor = .tertiarySystemFill
            configuration.background.strokeColor = UIColor.label.withAlphaComponent(0.12)
            configuration.background.strokeWidth = 0.5
        }
        configuration.contentInsets = .zero
        return configuration
    }

    private func configureCallButton() {
        let phone = UIImage(systemName: "phone.fill")?.withTintColor(.white, renderingMode: .alwaysOriginal)
        callButton.configuration?.title = nil
        callButton.configuration?.background.backgroundColor = .systemGreen
        callButton.configuration?.image = phone
        callButton.configurationUpdateHandler = { button in
            button.configuration?.background.backgroundColor = .systemGreen
            button.configuration?.image = phone
        }
        callButton.accessibilityIdentifier = "dialCall"
    }

    private func configureDeleteButton() {
        deleteButton.configuration?.title = nil
        deleteButton.configuration?.background.backgroundColor = .clear
        deleteButton.configuration?.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 18)
        deleteButton.accessibilityHint = "Tap to delete one digit; hold to keep deleting"
        (deleteButton as? PhoneActionButton)?.accessibilityAction = { [weak self] in
            self?.send(.deleteActivated)
        }
        deleteButton.addAction(UIAction { [weak self] _ in self?.send(.deletePressed) }, for: .touchDown)
        deleteButton.addAction(
            UIAction { [weak self] _ in self?.send(.deleteReleased) },
            for: [.touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit]
        )
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let area = view.safeAreaLayoutGuide.layoutFrame
        guard area.size != lastLayoutSize else { return }
        lastLayoutSize = area.size
        applyLayout(
            DialPadLayoutMetrics(
                availableHeight: area.height,
                availableWidth: area.width,
                compactWidth: traitCollection.horizontalSizeClass == .compact
            )
        )
    }

    private func applyLayout(_ metrics: DialPadLayoutMetrics) {
        keyHeight?.constant = metrics.keySize
        contentWidth.constant = metrics.contentWidth
        numberHeight.constant = metrics.numberHeight
        contactHeight.constant = metrics.contactHeight
        numberLabel.font = UIFont.systemFont(ofSize: metrics.numberFontSize, weight: .light).rounded()
        stack.spacing = metrics.sectionSpacing
        stack.setCustomSpacing(Metrics.numberToContactSpacing, after: numberLabel)
        for row in keypadRows {
            row.spacing = metrics.keySpacing
        }
        for width in keypadRowWidths {
            width.constant = metrics.keypadWidth
        }
        applyKeyFonts(metrics)
        callButton.configuration?.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(
            pointSize: metrics.callIconSize,
            weight: .semibold
        )
    }

    private func applyKeyFonts(_ metrics: DialPadLayoutMetrics) {
        var digitAttributes = AttributeContainer()
        digitAttributes.font = UIFont.systemFont(ofSize: metrics.digitFontSize).rounded()
        var letterAttributes = AttributeContainer()
        letterAttributes.font = UIFont.systemFont(ofSize: metrics.letterFontSize, weight: .semibold)
        letterAttributes.kern = Metrics.letterKern
        let letterTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var attributes = incoming
            attributes.font = .systemFont(ofSize: metrics.letterFontSize, weight: .semibold)
            attributes.kern = Metrics.letterKern
            return attributes
        }
        for (key, button) in keys {
            button.configuration?.attributedTitle = AttributedString(key.digit, attributes: digitAttributes)
            button.configuration?.attributedSubtitle = AttributedString(key.letters, attributes: letterAttributes)
            button.configuration?.subtitleTextAttributesTransformer = letterTransformer
        }
    }

    // MARK: Navigation

    private func showPairedAgents() {
        showPhoneSheet(PairedAndroidAgentsViewController(store: store))
    }

    // MARK: Actions

    private func digitTapped(_ digit: String) {
        send(.digitTapped(digit))
        if store.playsInputClick {
            UIDevice.current.playInputClick()
        }
    }

    @objc private func zeroLongPressed(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }
        digitTapped("+")
    }
}

private struct DialKey {
    let digit: String
    let letters: String

    init(_ digit: String, _ letters: String = "") {
        self.digit = digit
        self.letters = letters
    }

    var accessibilityLabel: String { letters.isEmpty ? digit : "\(digit) \(letters)" }

    static let rows: [[DialKey]] = [
        [DialKey("1"), DialKey("2", "ABC"), DialKey("3", "DEF")],
        [DialKey("4", "GHI"), DialKey("5", "JKL"), DialKey("6", "MNO")],
        [DialKey("7", "PQRS"), DialKey("8", "TUV"), DialKey("9", "WXYZ")],
        [DialKey("*"), DialKey("0", "+"), DialKey("#")],
    ]
}

private struct DialPadLayoutMetrics {
    let contentWidth: CGFloat
    let keySize: CGFloat
    let keySpacing: CGFloat
    let sectionSpacing: CGFloat
    let numberFontSize: CGFloat
    let numberHeight: CGFloat
    let contactHeight: CGFloat

    var keypadWidth: CGFloat { keySize * 3 + keySpacing * 2 }
    var digitFontSize: CGFloat { min(31, max(23, keySize * 0.34)) }
    var letterFontSize: CGFloat { min(10, max(8, keySize * 0.115)) }
    var callIconSize: CGFloat { min(30, max(23, keySize * 0.33)) }

    init(availableHeight: CGFloat, availableWidth: CGFloat, compactWidth: Bool) {
        let compactHeight = availableHeight < 700
        let desiredKeySize: CGFloat = compactWidth ? 84 : 90
        let desiredKeySpacing: CGFloat = compactWidth ? 28 : 34
        let reservedHeight: CGFloat = compactHeight ? 205 : 220
        let verticalKeySize = (availableHeight - reservedHeight) / 5
        contentWidth = min(520, max(0, availableWidth - 32))
        let horizontalKeySize = (contentWidth - desiredKeySpacing * 2) / 3

        keySize = min(desiredKeySize, max(56, min(verticalKeySize, horizontalKeySize)))
        keySpacing = min(
            desiredKeySpacing,
            max(14, (contentWidth - keySize * 3) / 2)
        )
        sectionSpacing = compactHeight ? 8 : (compactWidth ? 12 : 16)
        numberFontSize = compactHeight ? 32 : (compactWidth ? 36 : 42)
        numberHeight = compactHeight ? 40 : 46
        contactHeight = compactHeight ? 18 : 20
    }
}

private enum Metrics {
    static let maximumContentWidth: CGFloat = 520
    static let sideMargin: CGFloat = 16
    static let verticalMargin: CGFloat = 4
    static let numberToContactSpacing: CGFloat = 2
    static let agentCardHeight: CGFloat = 94
    static let agentCardHeightWithoutCurrent: CGFloat = 74
    static let letterKern: CGFloat = 1.4
    static let dimmedCallOpacity: CGFloat = 0.4
    static let disabledCallOpacityFactor: CGFloat = 0.5
    static let initialContentWidth: CGFloat = 360
    static let initialSectionSpacing: CGFloat = 12
    static let initialNumberHeight: CGFloat = 46
    static let initialContactHeight: CGFloat = 20
    static let initialKeypadWidth: CGFloat = 308
    static let initialKeySpacing: CGFloat = 28
    static let initialKeySize: CGFloat = 84
}

#if DEBUG
#Preview("Dial · Connected Agent") {
    let store = AirSIMPreviewFixtures.store()
    return AirSIMPreviewFixtures.navigation(
        DialPadViewController(store: store.scope(state: \.dial, action: \.dial))
    )
}
#endif
