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

    private var lastBasis: DTMFKeypadLayout.Basis?
    private var controlSize: CGFloat = 76
    private var controlSpacing: CGFloat = 32

    func updateControlLayout(size: CGFloat, spacing: CGFloat) {
        guard controlSize != size || controlSpacing != spacing else { return }
        controlSize = size
        controlSpacing = spacing
        lastBasis = nil
        viewIfLoaded?.setNeedsLayout()
    }

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
            safeInsets: view.safeAreaInsets
        )
        guard basis.boundsSize.width > 0, basis.boundsSize.height > 0, basis != lastBasis else { return }
        lastBasis = basis
        applyLayout(DTMFKeypadLayout(basis: basis, controlSize: controlSize, controlSpacing: controlSpacing))
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
        let bottom = stack.bottomAnchor.constraint(equalTo: safeArea.bottomAnchor, constant: -Metrics.bottomMargin)
        bottom.priority = .defaultHigh
        bottom.isActive = true

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

        if let firstButton = keys.first?.button {
            let height = firstButton.heightAnchor.constraint(equalToConstant: Metrics.initialKeySize)
            height.isActive = true
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

    private func applyLayout(_ layout: DTMFKeypadLayout) {
        keyHeightConstraint?.constant = layout.keySize
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

    init(basis: Basis, controlSize: CGFloat, controlSpacing: CGFloat) {
        let width = basis.boundsSize.width
        let height = basis.safeHeight
        keySize = controlSize
        columnSpacing = controlSpacing
        // The parent owns button geometry. Fit the header and gaps to the remaining content region.
        headerFontSize = height < 420 ? 32 : 44
        headerToKeypadSpacing = height < 420 ? 12 : 24
        let availableForGaps = height - 32 - headerFontSize - headerToKeypadSpacing - keySize * 4
        rowSpacing = min(16, max(6, floor(availableForGaps / 3)))
        let sideObstruction = max(basis.safeInsets.left, basis.safeInsets.right)
        headerMaxWidth = max(160, min(460, width - max(68, sideObstruction + 16) * 2))
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
    return AirSIMPreviewFixtures.activeCall(store)
}
#endif
