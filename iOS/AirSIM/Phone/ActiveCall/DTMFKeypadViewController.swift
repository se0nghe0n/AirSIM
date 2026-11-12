import ComposableArchitecture
import UIKit

@MainActor
@ViewAction(for: KeypadFeature.self)
final class DTMFKeypadViewController: ObservingViewController {
    // MARK: Store

    let store: StoreOf<KeypadFeature>

    /// Caller name or phone number displayed before the first DTMF digit is entered.
    var callerFallbackText = "" {
        didSet {
            guard callerFallbackText != oldValue, isViewLoaded else { return }
            render()
        }
    }

    // MARK: Views

    private let stack = UIStackView(axis: .vertical, spacing: Metrics.initialSectionSpacing, alignment: .center)
    private let digitsLabel = phoneLabel()
    private let keypadGlassContainer = UIVisualEffectView(effect: nil)
    private let keypadStack = UIStackView(axis: .vertical, spacing: Metrics.initialRowSpacing, alignment: .center)
    private var keys: [(key: DTMFKey, button: UIButton)] = []
    private var keypadRows: [UIStackView] = []
    private var keypadRowWidths: [NSLayoutConstraint] = []
    private var keyHeightConstraint: NSLayoutConstraint?
    private lazy var headerMaxWidthConstraint = digitsLabel.widthAnchor.constraint(
        lessThanOrEqualToConstant: Metrics.initialHeaderMaxWidth
    )

    private lazy var endButton = CallCircleControl(
        title: "End",
        icon: "phone.down.fill",
        size: Metrics.initialKeySize,
        color: .systemRed,
        showsCaption: false
    ) { [weak self] in
        self?.send(.endButtonTapped)
    }

    private lazy var hideButton = buildHideButton()
    private var lastBasis: DTMFKeypadLayout.Basis?

    // MARK: Lifecycle

    init(store: StoreOf<KeypadFeature>, callerFallback: String = "") {
        self.store = store
        self.callerFallbackText = callerFallback
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        overrideUserInterfaceStyle = .dark
        view.backgroundColor = .clear
        buildStack()
        buildKeypad()
        registerForTraitChanges([UITraitHorizontalSizeClass.self, UITraitPreferredContentSizeCategory.self]) {
            (controller: Self, _) in
            controller.lastBasis = nil
            controller.view.setNeedsLayout()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let basis = DTMFKeypadLayout.Basis(
            boundsSize: view.bounds.size,
            safeInsets: view.safeAreaInsets,
            compactWidth: traitCollection.horizontalSizeClass == .compact || view.bounds.width < 520
        )
        guard basis.boundsSize.width > 0, basis.boundsSize.height > 0, basis != lastBasis else { return }
        lastBasis = basis
        applyLayout(DTMFKeypadLayout(basis: basis))
    }

    // MARK: Rendering

    override func render() {
        let fallback = callerFallbackText
        let hasDigits = !store.showsPlaceholder
        let headerText = fallback.isEmpty ? store.displayText : store.state.headerDisplayText(callerFallback: fallback)
        digitsLabel.text = headerText
        digitsLabel.textColor =
            hasDigits
            ? .white
            : (fallback.isEmpty ? UIColor.white.withAlphaComponent(0.62) : UIColor.white.withAlphaComponent(0.86))
        digitsLabel.accessibilityLabel =
            fallback.isEmpty
            ? store.digitsAccessibilityLabel
            : store.state.headerAccessibilityLabel(callerFallback: fallback)
    }

    // MARK: Layout

    private func buildStack() {
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        let safeArea = view.safeAreaLayoutGuide
        // Centered horizontally across the full screen (matching native iOS Phone on folded iPhone Duo), while
        // headerMaxWidthConstraint clamps the top digits display clear of the right-edge Dynamic Island + clock.
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.topAnchor.constraint(greaterThanOrEqualTo: safeArea.topAnchor, constant: Metrics.topMargin),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: safeArea.bottomAnchor, constant: -Metrics.bottomMargin),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: Metrics.sideMargin),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -Metrics.sideMargin),
        ])
        let centerY = stack.centerYAnchor.constraint(equalTo: safeArea.centerYAnchor)
        centerY.priority = .defaultHigh
        centerY.isActive = true

        digitsLabel.font = Self.digitsFont(size: Metrics.initialHeaderFontSize, hasEnteredDigits: false)
        digitsLabel.numberOfLines = 1
        digitsLabel.textAlignment = .center
        digitsLabel.lineBreakMode = .byTruncatingHead
        digitsLabel.adjustsFontSizeToFitWidth = true
        digitsLabel.minimumScaleFactor = 0.52
        digitsLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        headerMaxWidthConstraint.isActive = true

        if #available(iOS 26.0, *) {
            let containerEffect = UIGlassContainerEffect()
            containerEffect.spacing = 12
            keypadGlassContainer.effect = containerEffect
        }
        keypadGlassContainer.contentView.addPinnedSubview(keypadStack)

        stack.addArrangedSubview(digitsLabel)
        stack.addArrangedSubview(keypadGlassContainer)
    }

    private func buildKeypad() {
        for rowKeys in DTMFKey.rows {
            let row = UIStackView(
                axis: .horizontal,
                spacing: Metrics.initialColumnSpacing,
                distribution: .fillEqually
            )
            for key in rowKeys {
                let button = keyButton(key)
                row.addArrangedSubview(button)
                keys.append((key, button))
            }
            addKeypadRow(row)
        }

        endButton.controlIdentifier = "dtmfEndCall"
        let leftSpacer = UIView()
        let rightCell = UIView()
        hideButton.translatesAutoresizingMaskIntoConstraints = false
        rightCell.addSubview(hideButton)
        NSLayoutConstraint.activate([
            hideButton.centerXAnchor.constraint(equalTo: rightCell.centerXAnchor),
            hideButton.centerYAnchor.constraint(equalTo: rightCell.centerYAnchor),
            hideButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 56),
            hideButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 56),
        ])

        let bottomRow = UIStackView(
            [leftSpacer, endButton, rightCell],
            axis: .horizontal,
            spacing: Metrics.initialColumnSpacing,
            alignment: .fill,
            distribution: .fillEqually
        )
        addKeypadRow(bottomRow)

        if let firstButton = keys.first?.button {
            let height = firstButton.heightAnchor.constraint(equalToConstant: Metrics.initialKeySize)
            NSLayoutConstraint.activate([
                height,
                bottomRow.heightAnchor.constraint(equalTo: firstButton.heightAnchor),
            ])
            keyHeightConstraint = height
        }
    }

    private func addKeypadRow(_ row: UIStackView) {
        keypadStack.addArrangedSubview(row)
        let width = row.widthAnchor.constraint(equalToConstant: Metrics.initialKeypadWidth)
        width.isActive = true
        keypadRows.append(row)
        keypadRowWidths.append(width)
    }

    private func keyButton(_ key: DTMFKey) -> UIButton {
        let button = UIButton(type: .system)
        button.configuration = keyConfiguration(key)
        button.accessibilityLabel = key.accessibilityLabel
        button.accessibilityIdentifier = "dtmfKey_\(key.digit)"
        button.widthAnchor.constraint(equalTo: button.heightAnchor).isActive = true
        button.addAction(UIAction { [weak self] _ in self?.keyTapped(key.digit) }, for: .touchUpInside)
        return button
    }

    private func keyConfiguration(_ key: DTMFKey) -> UIButton.Configuration {
        var configuration: UIButton.Configuration
        if #available(iOS 26.0, *) {
            configuration = .glass()
        } else {
            configuration = .gray()
            configuration.background.backgroundColor = UIColor.white.withAlphaComponent(0.16)
        }
        configuration.baseForegroundColor = .white
        configuration.cornerStyle = .capsule
        configuration.titleAlignment = .center
        configuration.titlePadding = 0
        configuration.contentInsets = .zero

        var digitAttributes = AttributeContainer()
        digitAttributes.font = UIFont.systemFont(ofSize: 34, weight: .regular).rounded()
        configuration.attributedTitle = AttributedString(key.digit, attributes: digitAttributes)

        var letterAttributes = AttributeContainer()
        letterAttributes.font = UIFont.systemFont(ofSize: 10, weight: .bold)
        letterAttributes.kern = Metrics.letterKern
        configuration.attributedSubtitle = AttributedString(key.letters, attributes: letterAttributes)
        return configuration
    }

    private func buildHideButton() -> UIButton {
        let button = UIButton(type: .system)
        var configuration = UIButton.Configuration.plain()
        configuration.baseForegroundColor = .white
        button.configuration = configuration
        button.accessibilityLabel = "Hide Keypad"
        button.accessibilityIdentifier = "dtmfHideKeypad"

        let grid = UIImageView(image: UIImage(systemName: "circle.grid.3x3.fill"))
        grid.tintColor = .white
        grid.contentMode = .scaleAspectFit
        grid.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 22, weight: .semibold)

        let chevron = UIImageView(image: UIImage(systemName: "chevron.down"))
        chevron.tintColor = .white
        chevron.contentMode = .scaleAspectFit
        chevron.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 11, weight: .bold)

        let iconStack = UIStackView([grid, chevron], axis: .vertical, spacing: 2, alignment: .center)
        iconStack.isUserInteractionEnabled = false
        button.addPinnedSubview(iconStack, insets: UIEdgeInsets(top: 10, left: 14, bottom: 10, right: 14))
        button.addAction(UIAction { [weak self] _ in self?.send(.hideButtonTapped) }, for: .touchUpInside)
        return button
    }

    private func applyLayout(_ layout: DTMFKeypadLayout) {
        keyHeightConstraint?.constant = layout.keySize
        endButton.setSize(layout.keySize)
        stack.spacing = layout.headerToKeypadSpacing
        keypadStack.spacing = layout.rowSpacing
        for row in keypadRows {
            row.spacing = layout.columnSpacing
        }
        for width in keypadRowWidths {
            width.constant = layout.keypadWidth
        }
        headerMaxWidthConstraint.constant = layout.headerMaxWidth
        digitsLabel.font = UIFontMetrics(forTextStyle: .largeTitle)
            .scaledFont(for: Self.digitsFont(size: layout.headerFontSize, hasEnteredDigits: !store.showsPlaceholder))

        var digitAttributes = AttributeContainer()
        digitAttributes.font = UIFont.systemFont(ofSize: layout.digitFontSize, weight: .regular).rounded()
        var letterAttributes = AttributeContainer()
        letterAttributes.font = UIFont.systemFont(ofSize: layout.letterFontSize, weight: .bold)
        letterAttributes.kern = Metrics.letterKern
        let letterTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var attributes = incoming
            attributes.font = .systemFont(ofSize: layout.letterFontSize, weight: .bold)
            attributes.kern = Metrics.letterKern
            return attributes
        }
        for (key, button) in keys {
            button.configuration?.attributedTitle = AttributedString(key.digit, attributes: digitAttributes)
            button.configuration?.attributedSubtitle = AttributedString(key.letters, attributes: letterAttributes)
            button.configuration?.subtitleTextAttributesTransformer = letterTransformer
        }
    }

    private static func digitsFont(size: CGFloat, hasEnteredDigits: Bool) -> UIFont {
        let base = UIFont.systemFont(ofSize: size, weight: hasEnteredDigits ? .semibold : .medium).rounded()
        let monospacedDigits = base.fontDescriptor.addingAttributes([
            .featureSettings: [
                [
                    UIFontDescriptor.FeatureKey.type: kNumberSpacingType,
                    UIFontDescriptor.FeatureKey.selector: kMonospacedNumbersSelector,
                ]
            ]
        ])
        return UIFont(descriptor: monospacedDigits, size: size)
    }

    // MARK: Actions

    private func keyTapped(_ digit: String) {
        send(.digitTapped(digit))
        UIDevice.current.playInputClick()
    }
}

private struct DTMFKey {
    let digit: String
    let letters: String

    init(_ digit: String, _ letters: String = "") {
        self.digit = digit
        self.letters = letters
    }

    var accessibilityLabel: String {
        letters.isEmpty ? "Send DTMF \(digit)" : "Send DTMF \(digit) \(letters)"
    }

    static let rows: [[DTMFKey]] = [
        [DTMFKey("1", " "), DTMFKey("2", "ABC"), DTMFKey("3", "DEF")],
        [DTMFKey("4", "GHI"), DTMFKey("5", "JKL"), DTMFKey("6", "MNO")],
        [DTMFKey("7", "PQRS"), DTMFKey("8", "TUV"), DTMFKey("9", "WXYZ")],
        [DTMFKey("*"), DTMFKey("0", "+"), DTMFKey("#")],
    ]
}

private struct DTMFKeypadLayout {
    struct Basis: Equatable {
        let boundsSize: CGSize
        let safeInsets: UIEdgeInsets
        let compactWidth: Bool

        var safeHeight: CGFloat {
            max(0, boundsSize.height - safeInsets.top - safeInsets.bottom)
        }
    }

    let keySize: CGFloat
    let columnSpacing: CGFloat
    let rowSpacing: CGFloat
    let headerToKeypadSpacing: CGFloat
    let headerFontSize: CGFloat
    let headerMaxWidth: CGFloat

    var keypadWidth: CGFloat { keySize * 3 + columnSpacing * 2 }
    var digitFontSize: CGFloat { min(36, max(24, keySize * 0.41)) }
    var letterFontSize: CGFloat { min(10.5, max(8.5, keySize * 0.115)) }

    init(basis: Basis) {
        let width = max(320, basis.boundsSize.width)
        let height = max(440, basis.safeHeight > 0 ? basis.safeHeight : basis.boundsSize.height)
        let shortHeight = height < 580

        let desiredKeySize: CGFloat = shortHeight ? 64 : (basis.compactWidth ? 82 : 88)
        let desiredColumnSpacing: CGFloat = shortHeight ? 20 : (basis.compactWidth ? 26 : 32)
        let desiredRowSpacing: CGFloat = shortHeight ? 12 : 16
        headerToKeypadSpacing = shortHeight ? 18 : 28
        headerFontSize = shortHeight ? 38 : 48

        let sideObstruction = max(basis.safeInsets.left, basis.safeInsets.right)
        let symmetricClearance = max(68, sideObstruction + 16)
        headerMaxWidth = max(160, min(460, width - symmetricClearance * 2))

        // Keep keypad width clear of folded Duo's right-edge Dynamic Island pill (~390pt) near the top row.
        let maxSafeKeypadWidth = sideObstruction > 40 ? max(240, width - (sideObstruction + 8) * 2) : width - 56
        let usableWidth = min(380, max(220, maxSafeKeypadWidth))
        let maxHorizontalKey = (usableWidth - desiredColumnSpacing * 2) / 3
        let reservedVertical = headerFontSize + headerToKeypadSpacing + desiredRowSpacing * 4 + 32
        let maxVerticalKey = (height - reservedVertical) / 5

        keySize = min(desiredKeySize, max(56, floor(min(maxHorizontalKey, maxVerticalKey))))
        columnSpacing = min(desiredColumnSpacing, max(14, floor((usableWidth - keySize * 3) / 2)))
        rowSpacing = keySize < 66 ? 11 : desiredRowSpacing
    }
}

private enum Metrics {
    static let topMargin: CGFloat = 18
    static let bottomMargin: CGFloat = 14
    static let sideMargin: CGFloat = 20
    static let initialSectionSpacing: CGFloat = 28
    static let initialRowSpacing: CGFloat = 16
    static let initialColumnSpacing: CGFloat = 26
    static let initialKeySize: CGFloat = 80
    static let initialKeypadWidth: CGFloat = 292
    static let initialHeaderFontSize: CGFloat = 46
    static let initialHeaderMaxWidth: CGFloat = 266
    static let letterKern: CGFloat = 1.6
}

#if DEBUG
#Preview("Call · DTMF Keypad") {
    let store = AirSIMPreviewFixtures.store(callState: "active")
    store.send(.activeCall(.view(.keypadButtonTapped)))
    let keypad = store.scope(state: \.activeCall.keypad, action: \.activeCall.keypad.presented)!
    let controller = DTMFKeypadViewController(store: keypad, callerFallback: "114")
    let host = UIViewController()
    let backdrop = CallBackdropView()
    host.view.addPinnedSubview(backdrop)
    host.addChild(controller)
    host.view.addPinnedSubview(controller.view)
    controller.didMove(toParent: host)
    return host
}
#endif
