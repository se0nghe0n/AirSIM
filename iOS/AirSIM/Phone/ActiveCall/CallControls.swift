import UIKit

/// Full-bleed atmospheric blue-slate / indigo backdrop matching the native iOS Phone call screen.
@MainActor
final class CallBackdropView: UIView {
    private let baseGradient = CAGradientLayer()
    private let upperAtmosphereGlow = CAGradientLayer()
    private let lowerIndigoGlow = CAGradientLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(red: 0.14, green: 0.17, blue: 0.34, alpha: 1)
        baseGradient.colors = [
            UIColor(red: 0.42, green: 0.48, blue: 0.59, alpha: 1).cgColor,
            UIColor(red: 0.31, green: 0.37, blue: 0.55, alpha: 1).cgColor,
            UIColor(red: 0.21, green: 0.25, blue: 0.50, alpha: 1).cgColor,
            UIColor(red: 0.14, green: 0.16, blue: 0.44, alpha: 1).cgColor,
        ]
        baseGradient.locations = [0.0, 0.36, 0.72, 1.0]
        baseGradient.startPoint = CGPoint(x: 0.22, y: 0.0)
        baseGradient.endPoint = CGPoint(x: 0.78, y: 1.0)
        layer.addSublayer(baseGradient)

        configureRadialGlow(
            upperAtmosphereGlow,
            color: UIColor(red: 0.64, green: 0.72, blue: 0.86, alpha: 0.34)
        )
        configureRadialGlow(
            lowerIndigoGlow,
            color: UIColor(red: 0.19, green: 0.18, blue: 0.58, alpha: 0.46)
        )
        layer.addSublayer(upperAtmosphereGlow)
        layer.addSublayer(lowerIndigoGlow)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        baseGradient.frame = bounds
        let span = max(bounds.width, bounds.height)
        upperAtmosphereGlow.frame = CGRect(
            x: -span * 0.25,
            y: -span * 0.32,
            width: span * 1.15,
            height: span * 1.15
        )
        lowerIndigoGlow.frame = CGRect(
            x: bounds.width - span * 0.85,
            y: bounds.height - span * 0.72,
            width: span * 1.1,
            height: span * 1.1
        )
    }

    private func configureRadialGlow(_ glow: CAGradientLayer, color: UIColor) {
        glow.type = .radial
        glow.colors = [color.cgColor, UIColor.clear.cgColor]
        glow.startPoint = CGPoint(x: 0.5, y: 0.5)
        glow.endPoint = CGPoint(x: 1, y: 1)
    }
}

/// Translucent Liquid Glass circular hero avatar showing contact photo, monogram, or native silhouette.
@MainActor
final class CallHeroAvatarView: UIView {
    private let glassView = UIVisualEffectView(effect: nil)
    private let photoView = UIImageView()
    private let monogramLabel = UILabel()
    private let personImageView = UIImageView()
    private var currentSize: CGFloat = 180

    private var personWidthConstraint: NSLayoutConstraint?
    private var personHeightConstraint: NSLayoutConstraint?
    private var personCenterYConstraint: NSLayoutConstraint?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false

        if #available(iOS 26.0, *) {
            let glass = UIGlassEffect(style: .regular)
            glass.tintColor = UIColor.white.withAlphaComponent(0.06)
            glassView.effect = glass
            glassView.cornerConfiguration = .capsule()
        } else {
            glassView.effect = UIBlurEffect(style: .systemUltraThinMaterialLight)
            glassView.contentView.backgroundColor = UIColor.white.withAlphaComponent(0.14)
            glassView.clipsToBounds = true
            glassView.layer.borderWidth = 1
            glassView.layer.borderColor = UIColor.white.withAlphaComponent(0.28).cgColor
        }
        addPinnedSubview(glassView)

        photoView.contentMode = .scaleAspectFill
        photoView.clipsToBounds = true
        photoView.isHidden = true
        glassView.contentView.addPinnedSubview(photoView)

        monogramLabel.textColor = .white
        monogramLabel.textAlignment = .center
        monogramLabel.isHidden = true
        glassView.contentView.addPinnedSubview(monogramLabel)

        personImageView.image = UIImage(systemName: "person.fill")
        personImageView.tintColor = UIColor.white.withAlphaComponent(0.94)
        personImageView.contentMode = .scaleAspectFit
        personImageView.translatesAutoresizingMaskIntoConstraints = false
        glassView.contentView.addSubview(personImageView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let radius = min(bounds.width, bounds.height) / 2
        photoView.layer.cornerRadius = radius
        if #unavailable(iOS 26.0) {
            glassView.layer.cornerRadius = radius
        }
    }

    func update(contactName: String?, photo: Data?, size: CGFloat) {
        currentSize = size
        ensurePersonConstraints()
        personWidthConstraint?.constant = size * 0.66
        personHeightConstraint?.constant = size * 0.66
        personCenterYConstraint?.constant = size * 0.06

        if let photo, let image = UIImage(data: photo) {
            photoView.image = image
            photoView.isHidden = false
            monogramLabel.isHidden = true
            personImageView.isHidden = true
            return
        }

        photoView.image = nil
        photoView.isHidden = true

        let initial = contactName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .first
            .flatMap { $0.isLetter ? String($0).uppercased() : nil }

        if let initial {
            monogramLabel.text = initial
            monogramLabel.font = UIFont.systemFont(ofSize: size * 0.42, weight: .semibold).rounded()
            monogramLabel.isHidden = false
            personImageView.isHidden = true
        } else {
            monogramLabel.isHidden = true
            personImageView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(
                pointSize: size * 0.56,
                weight: .regular
            )
            personImageView.isHidden = false
        }
    }

    private func ensurePersonConstraints() {
        guard personWidthConstraint == nil else { return }
        let width = personImageView.widthAnchor.constraint(equalToConstant: currentSize * 0.66)
        let height = personImageView.heightAnchor.constraint(equalToConstant: currentSize * 0.66)
        let centerY = personImageView.centerYAnchor.constraint(
            equalTo: glassView.contentView.centerYAnchor,
            constant: currentSize * 0.06
        )
        personWidthConstraint = width
        personHeightConstraint = height
        personCenterYConstraint = centerY
        NSLayoutConstraint.activate([
            personImageView.centerXAnchor.constraint(equalTo: glassView.contentView.centerXAnchor),
            centerY,
            width,
            height,
        ])
    }
}

/// Circular control in the 2×3 call grid backed directly by a native `UIButton` using `.glass()` / `.prominentGlass()`.
@MainActor
final class CallCircleControl: UIView {
    private let button = UIButton(type: .system)
    private let caption = phoneLabel(size: 13, color: UIColor.white.withAlphaComponent(0.95))
    private var sizeConstraints: [NSLayoutConstraint] = []
    private var minWidthConstraint: NSLayoutConstraint?
    private let decisionTint: UIColor?
    private let showsCaption: Bool

    private var currentTitle: String
    private var currentIcon: String
    private var currentTint: UIColor?
    private var currentIsActive = false
    private var currentSize: CGFloat

    var isEnabled: Bool {
        get { button.isEnabled }
        set {
            button.isEnabled = newValue
            caption.alpha = newValue ? 1.0 : Metrics.disabledCaptionAlpha
        }
    }

    var controlIdentifier: String? {
        get { button.accessibilityIdentifier }
        set { button.accessibilityIdentifier = newValue }
    }

    var controlAccessibilityValue: String? {
        get { button.accessibilityValue }
        set { button.accessibilityValue = newValue }
    }

    var controlAccessibilityHint: String? {
        get { button.accessibilityHint }
        set { button.accessibilityHint = newValue }
    }

    init(
        title: String,
        icon: String,
        size: CGFloat,
        color: UIColor? = nil,
        showsCaption: Bool = true,
        action: @escaping () -> Void
    ) {
        self.decisionTint = color
        self.showsCaption = showsCaption
        self.currentTitle = title
        self.currentIcon = icon
        self.currentTint = color
        self.currentSize = size
        super.init(frame: .zero)
        let isLarge = size >= Metrics.largeSize && color != nil && showsCaption
        buildViews(size: size, isLarge: isLarge, action: action)
        applyButtonConfiguration()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setSize(_ size: CGFloat) {
        guard currentSize != size else { return }
        currentSize = size
        for constraint in sizeConstraints {
            constraint.constant = size
        }
        minWidthConstraint?.constant = showsCaption ? max(size + 6, 72) : size
        applyButtonConfiguration()
    }

    func update(
        title: String,
        icon: String,
        tint: UIColor? = nil,
        isActive: Bool = false,
        accessibilityTitle: String? = nil
    ) {
        currentTitle = title
        currentIcon = icon
        currentTint = tint ?? decisionTint
        currentIsActive = isActive
        caption.text = title
        caption.isHidden = !showsCaption
        button.accessibilityLabel = accessibilityTitle ?? title
        if decisionTint != nil {
            button.accessibilityValue = nil
        }
        applyButtonConfiguration()
    }

    private func buildViews(size: CGFloat, isLarge: Bool, action: @escaping () -> Void) {
        button.translatesAutoresizingMaskIntoConstraints = false
        button.accessibilityLabel = currentTitle
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
        sizeConstraints = [
            button.widthAnchor.constraint(equalToConstant: size),
            button.heightAnchor.constraint(equalToConstant: size),
        ]
        NSLayoutConstraint.activate(sizeConstraints)

        caption.text = currentTitle
        caption.textAlignment = .center
        caption.numberOfLines = 1
        caption.isAccessibilityElement = false
        caption.font = UIFontMetrics(forTextStyle: .footnote)
            .scaledFont(for: .systemFont(ofSize: isLarge ? 14 : 13, weight: .medium))
        caption.isHidden = !showsCaption

        let arranged: [UIView] = showsCaption ? [button, caption] : [button]
        let stack = UIStackView(
            arranged,
            axis: .vertical,
            spacing: isLarge ? Metrics.largeCaptionSpacing : Metrics.captionSpacing,
            alignment: .center
        )
        addPinnedSubview(stack)

        let width = widthAnchor.constraint(
            greaterThanOrEqualToConstant: showsCaption
                ? (isLarge ? Metrics.largeMinimumWidth : max(size + 6, 72)) : size
        )
        width.isActive = true
        minWidthConstraint = width
    }

    private func applyButtonConfiguration() {
        let isDecision = decisionTint != nil
        let symbolSize = isDecision ? max(22, currentSize * 0.36) : max(20, currentSize * 0.33)
        let symbolConfig = UIImage.SymbolConfiguration(pointSize: symbolSize, weight: .semibold)
        var config: UIButton.Configuration

        if let tint = currentTint, isDecision {
            if #available(iOS 26.0, *) {
                config = .prominentGlass()
            } else {
                config = .filled()
            }
            config.baseBackgroundColor = tint
            config.baseForegroundColor = .white
        } else if currentIsActive {
            if #available(iOS 26.0, *) {
                config = .prominentGlass()
            } else {
                config = .filled()
            }
            config.baseBackgroundColor = .white
            config.baseForegroundColor = UIColor(red: 0.12, green: 0.15, blue: 0.28, alpha: 1)
        } else {
            if #available(iOS 26.0, *) {
                config = .glass()
                if let tint = currentTint {
                    config.baseBackgroundColor = tint.withAlphaComponent(Metrics.glassTintAlpha)
                }
            } else {
                config = .gray()
                config.background.backgroundColor =
                    (currentTint ?? .white).withAlphaComponent(currentTint == nil ? 0.16 : Metrics.glassTintAlpha)
            }
            config.baseForegroundColor = .white
        }

        config.cornerStyle = .capsule
        config.image = UIImage(systemName: currentIcon)
        config.preferredSymbolConfigurationForImage = symbolConfig
        config.contentInsets = .zero
        button.configuration = config
    }
}

/// Structured Liquid Glass `More` menu anchored above the bottom-left `More` button, matching iOS Phone.
@MainActor
final class CallMoreMenuView: UIView {
    private let card = UIVisualEffectView(effect: nil)
    private let stack = UIStackView(axis: .vertical, spacing: 4)
    private let recordingRowButton = CallMoreMenuRowButton()
    private let divider = UIView()
    private let contactRowButton = CallMoreMenuRowButton()

    var onToggleRecording: (() -> Void)?
    var onOpenContactCard: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        accessibilityViewIsModal = true
        buildCard()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(content: ActiveCallContent) {
        recordingRowButton.configureRecording(
            title: content.recordingMenuTitle,
            subtitle: content.recordingMenuSubtitle,
            isRecording: content.isRecording,
            isBusy: content.isRecordingBusy,
            isEnabled: content.canToggleRecording
        )
        recordingRowButton.accessibilityLabel = content.isRecording ? "Stop Recording" : "Record"
        recordingRowButton.accessibilityValue = content.recordingMenuSubtitle
        recordingRowButton.accessibilityIdentifier = "callMoreRecordRow"

        if let contact = content.contact {
            divider.isHidden = false
            contactRowButton.isHidden = false
            contactRowButton.configureSymbol(
                title: "Contact Card",
                subtitle: contact.name,
                symbol: "person.crop.circle.fill",
                badgeColor: UIColor(white: 0.22, alpha: 0.85)
            )
            contactRowButton.accessibilityLabel = "Contact Card"
            contactRowButton.accessibilityValue = contact.name
            contactRowButton.accessibilityIdentifier = "callMoreContactRow"
        } else {
            divider.isHidden = true
            contactRowButton.isHidden = true
        }
    }

    private func buildCard() {
        if #available(iOS 26.0, *) {
            let glass = UIGlassEffect(style: .regular)
            glass.isInteractive = true
            glass.tintColor = UIColor(red: 0.34, green: 0.39, blue: 0.62, alpha: 0.22)
            card.effect = glass
            card.cornerConfiguration = .uniformCorners(radius: .fixed(28))
        } else {
            card.effect = UIBlurEffect(style: .systemUltraThinMaterialDark)
            card.contentView.backgroundColor = UIColor(red: 0.22, green: 0.26, blue: 0.45, alpha: 0.56)
            card.layer.cornerRadius = 28
            card.clipsToBounds = true
            card.layer.borderWidth = 1
            card.layer.borderColor = UIColor.white.withAlphaComponent(0.28).cgColor
        }
        addPinnedSubview(card)

        recordingRowButton.addAction(UIAction { [weak self] _ in self?.onToggleRecording?() }, for: .touchUpInside)
        contactRowButton.addAction(UIAction { [weak self] _ in self?.onOpenContactCard?() }, for: .touchUpInside)

        divider.backgroundColor = UIColor.white.withAlphaComponent(0.16)
        divider.heightAnchor.constraint(equalToConstant: 0.5).isActive = true

        stack.addArrangedSubview(recordingRowButton)
        stack.addArrangedSubview(divider)
        stack.addArrangedSubview(contactRowButton)
        card.contentView.addPinnedSubview(stack, insets: UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12))
    }
}

@MainActor
private final class CallMoreMenuRowButton: UIButton {
    private let badgeContainer = UIView()
    private let recordOuterRing = UIView()
    private let recordInnerDot = UIView()
    private let symbolView = UIImageView()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let titleLabelView = phoneLabel(size: 17, color: .white)
    private let subtitleLabelView = phoneLabel(size: 13, color: UIColor.white.withAlphaComponent(0.74))

    override init(frame: CGRect) {
        super.init(frame: frame)
        buildRow()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configureRecording(
        title: String,
        subtitle: String,
        isRecording: Bool,
        isBusy: Bool,
        isEnabled: Bool
    ) {
        self.isEnabled = isEnabled
        alpha = isEnabled || isBusy ? 1.0 : 0.55
        titleLabelView.text = title
        subtitleLabelView.text = subtitle
        subtitleLabelView.isHidden = subtitle.isEmpty

        symbolView.isHidden = true
        badgeContainer.backgroundColor = .clear
        recordOuterRing.isHidden = isBusy
        recordInnerDot.isHidden = isBusy
        recordInnerDot.layer.cornerRadius = isRecording ? 6 : 14.5
        recordInnerDot.transform = isRecording ? CGAffineTransform(scaleX: 0.56, y: 0.56) : .identity
        if isBusy {
            spinner.startAnimating()
        } else {
            spinner.stopAnimating()
        }
    }

    func configureSymbol(title: String, subtitle: String, symbol: String, badgeColor: UIColor) {
        isEnabled = true
        alpha = 1.0
        titleLabelView.text = title
        subtitleLabelView.text = subtitle
        subtitleLabelView.isHidden = subtitle.isEmpty

        spinner.stopAnimating()
        recordOuterRing.isHidden = true
        recordInnerDot.isHidden = true
        badgeContainer.backgroundColor = badgeColor
        symbolView.isHidden = false
        symbolView.image = UIImage(systemName: symbol)
    }

    private func buildRow() {
        var rowConfig: UIButton.Configuration
        if #available(iOS 26.0, *) {
            rowConfig = .clearGlass()
        } else {
            rowConfig = .plain()
        }
        rowConfig.cornerStyle = .large
        rowConfig.contentInsets = .zero
        configuration = rowConfig

        badgeContainer.isUserInteractionEnabled = false
        badgeContainer.layer.cornerRadius = 21
        badgeContainer.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            badgeContainer.widthAnchor.constraint(equalToConstant: 42),
            badgeContainer.heightAnchor.constraint(equalToConstant: 42),
        ])

        recordOuterRing.isUserInteractionEnabled = false
        recordOuterRing.layer.cornerRadius = 21
        recordOuterRing.layer.borderWidth = 3
        recordOuterRing.layer.borderColor = UIColor.white.cgColor
        badgeContainer.addPinnedSubview(recordOuterRing)

        recordInnerDot.isUserInteractionEnabled = false
        recordInnerDot.backgroundColor = .systemRed
        recordInnerDot.layer.cornerRadius = 14.5
        recordInnerDot.translatesAutoresizingMaskIntoConstraints = false
        badgeContainer.addSubview(recordInnerDot)
        NSLayoutConstraint.activate([
            recordInnerDot.centerXAnchor.constraint(equalTo: badgeContainer.centerXAnchor),
            recordInnerDot.centerYAnchor.constraint(equalTo: badgeContainer.centerYAnchor),
            recordInnerDot.widthAnchor.constraint(equalToConstant: 29),
            recordInnerDot.heightAnchor.constraint(equalToConstant: 29),
        ])

        symbolView.isUserInteractionEnabled = false
        symbolView.tintColor = .white
        symbolView.contentMode = .scaleAspectFit
        symbolView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 22, weight: .medium)
        symbolView.translatesAutoresizingMaskIntoConstraints = false
        badgeContainer.addSubview(symbolView)
        NSLayoutConstraint.activate([
            symbolView.centerXAnchor.constraint(equalTo: badgeContainer.centerXAnchor),
            symbolView.centerYAnchor.constraint(equalTo: badgeContainer.centerYAnchor),
        ])

        spinner.color = .white
        spinner.hidesWhenStopped = true
        spinner.translatesAutoresizingMaskIntoConstraints = false
        badgeContainer.addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: badgeContainer.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: badgeContainer.centerYAnchor),
        ])

        titleLabelView.font = UIFontMetrics(forTextStyle: .body)
            .scaledFont(for: .systemFont(ofSize: 17, weight: .semibold))
        titleLabelView.numberOfLines = 1
        titleLabelView.isAccessibilityElement = false
        subtitleLabelView.font = UIFontMetrics(forTextStyle: .footnote)
            .scaledFont(for: .systemFont(ofSize: 13, weight: .regular))
        subtitleLabelView.numberOfLines = 2
        subtitleLabelView.isAccessibilityElement = false

        let textStack = UIStackView(
            [titleLabelView, subtitleLabelView],
            axis: .vertical,
            spacing: 2,
            alignment: .leading
        )
        textStack.isUserInteractionEnabled = false

        let rowStack = UIStackView(
            [badgeContainer, textStack],
            axis: .horizontal,
            spacing: 14,
            alignment: .center
        )
        rowStack.isUserInteractionEnabled = false
        addPinnedSubview(rowStack, insets: UIEdgeInsets(top: 10, left: 10, bottom: 10, right: 12))
    }
}

/// Read-only contact summary sheet presented over the call window when "Contact Card" is tapped in `More`.
@MainActor
final class CallContactCardViewController: UIViewController {
    private let contact: ContactStore.Contact

    init(contact: ContactStore.Contact) {
        self.contact = contact
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Contact Card"
        navigationItem.largeTitleDisplayMode = .never
        view.backgroundColor = .systemGroupedBackground

        let scroll = UIScrollView()
        view.addPinnedSubview(scroll)

        let avatar = UIImageView(image: phoneAvatar(name: contact.name, photo: contact.photoData, size: 84))
        NSLayoutConstraint.activate([
            avatar.widthAnchor.constraint(equalToConstant: 84),
            avatar.heightAnchor.constraint(equalToConstant: 84),
        ])
        let nameLabel = phoneLabel(contact.name, size: 24)
        nameLabel.font = UIFontMetrics(forTextStyle: .title2)
            .scaledFont(for: .systemFont(ofSize: 24, weight: .semibold))
        nameLabel.textAlignment = .center

        let cardStack = UIStackView([avatar, nameLabel], axis: .vertical, spacing: 12, alignment: .center)
        cardStack.setCustomSpacing(20, after: nameLabel)

        let phones = ContactPhoneListPolicy.displayPhones(for: contact.phones)
        for phone in phones {
            cardStack.addArrangedSubview(detailRow(title: "Phone", value: phone, symbol: "phone.fill"))
        }
        for email in contact.emails where !email.isEmpty {
            cardStack.addArrangedSubview(detailRow(title: "Email", value: email, symbol: "envelope.fill"))
        }

        cardStack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(cardStack)
        NSLayoutConstraint.activate([
            cardStack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 24),
            cardStack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -24),
            cardStack.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: 20),
            cardStack.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -20),
        ])
    }

    private func detailRow(title: String, value: String, symbol: String) -> UIView {
        let box = UIView()
        box.backgroundColor = .secondarySystemGroupedBackground
        box.layer.cornerRadius = 14
        let icon = UIImageView(image: UIImage(systemName: symbol))
        icon.tintColor = .secondaryLabel
        icon.setContentHuggingPriority(.required, for: .horizontal)
        let kind = phoneLabel(title, size: 12, color: .secondaryLabel)
        let text = phoneLabel(value, size: 16, color: .label)
        let labels = UIStackView([kind, text], axis: .vertical, spacing: 2, alignment: .leading)
        let row = UIStackView([icon, labels, UIView()], axis: .horizontal, spacing: 12, alignment: .center)
        box.addPinnedSubview(row, insets: UIEdgeInsets(top: 12, left: 16, bottom: 12, right: 16))
        box.widthAnchor.constraint(lessThanOrEqualToConstant: 520).isActive = true
        return box
    }
}

private enum Metrics {
    static let largeSize: CGFloat = 76
    static let captionSpacing: CGFloat = 7
    static let largeCaptionSpacing: CGFloat = 10
    static let largeMinimumWidth: CGFloat = 96
    static let glassTintAlpha: CGFloat = 0.28
    static let disabledCaptionAlpha: CGFloat = 0.48
}

#if DEBUG
#Preview("Component · Call Backdrop") {
    AirSIMPreviewFixtures.canvas(CallBackdropView(), height: 600, dark: true)
}

#Preview("Component · Call Circle Control") {
    AirSIMPreviewFixtures.canvas(
        CallCircleControl(title: "End", icon: "phone.down.fill", size: 72, color: .systemRed) {},
        width: 110,
        height: 108,
        dark: true
    )
}
#endif
