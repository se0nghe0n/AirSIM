import UIKit

@MainActor
final class CallBackdropView: UIView {
    private let topGlow = CAGradientLayer()
    private let bottomGlow = CAGradientLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(red: 0.008, green: 0.012, blue: 0.025, alpha: 1)
        configureGlow(topGlow, color: UIColor.systemBlue.withAlphaComponent(0.24))
        configureGlow(bottomGlow, color: UIColor.cyan.withAlphaComponent(0.12))
        layer.addSublayer(topGlow)
        layer.addSublayer(bottomGlow)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        topGlow.frame = CGRect(x: bounds.width - 420, y: -420, width: 840, height: 840)
        bottomGlow.frame = CGRect(x: -360, y: bounds.height - 360, width: 720, height: 720)
    }

    private func configureGlow(_ glow: CAGradientLayer, color: UIColor) {
        glow.type = .radial
        glow.colors = [color.cgColor, UIColor.clear.cgColor]
        glow.startPoint = CGPoint(x: 0.5, y: 0.5)
        glow.endPoint = CGPoint(x: 1, y: 1)
    }
}

@MainActor
final class CallCircleControl: UIButton {
    private let caption = phoneLabel(size: 12, color: UIColor.white.withAlphaComponent(0.88))
    private let iconView = UIImageView()
    private let circle = UIView()
    private var sizeConstraints: [NSLayoutConstraint] = []
    private let material = UIVisualEffectView(effect: nil)
    private let gradient = CAGradientLayer()
    private let isDecision: Bool

    init(title: String, icon: String, size: CGFloat, color: UIColor? = nil, action: @escaping () -> Void) {
        isDecision = color != nil
        super.init(frame: .zero)
        let isLarge = size == Metrics.largeSize
        buildCircle(size: size, color: color, isLarge: isLarge)
        buildStack(size: size, isLarge: isLarge)
        update(title: title, icon: icon, tint: color)
        addAction(UIAction { _ in action() }, for: .touchUpInside)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setSize(_ size: CGFloat) {
        for constraint in sizeConstraints {
            constraint.constant = size
        }
        circle.layer.cornerRadius = size / 2
        material.layer.cornerRadius = size / 2
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        gradient.frame = circle.bounds
        gradient.cornerRadius = circle.bounds.width / 2
        material.layer.cornerRadius = circle.bounds.width / 2
    }

    func update(title: String, icon: String, tint: UIColor?) {
        caption.text = title
        iconView.image = UIImage(systemName: icon)
        accessibilityLabel = title
        if isDecision, let tint {
            gradient.colors = [Self.highlight(tint).cgColor, tint.cgColor]
            circle.backgroundColor = tint
        } else {
            circle.backgroundColor = .clear
            if #available(iOS 26.0, *) {
                let glass = UIGlassEffect(style: .regular)
                glass.isInteractive = true
                glass.tintColor = tint?.withAlphaComponent(Metrics.glassTintAlpha)
                material.effect = glass
            } else {
                material.effect = UIBlurEffect(style: .systemUltraThinMaterialDark)
                material.contentView.backgroundColor = tint?.withAlphaComponent(Metrics.glassTintAlpha)
            }
        }
    }

    private func buildCircle(size: CGFloat, color: UIColor?, isLarge: Bool) {
        if isDecision {
            circle.layer.insertSublayer(gradient, at: 0)
        } else {
            material.frame = circle.bounds
            material.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            material.clipsToBounds = true
            circle.addSubview(material)
        }
        circle.layer.cornerRadius = size / 2
        circle.backgroundColor = color ?? UIColor.white.withAlphaComponent(0.12)
        circle.layer.borderColor = UIColor.white.withAlphaComponent(0.12).cgColor
        circle.layer.borderWidth = 0.5
        if isLarge {
            circle.layer.shadowColor = (color ?? .clear).cgColor
            circle.layer.shadowOpacity = 0.28
            circle.layer.shadowRadius = 16
            circle.layer.shadowOffset = CGSize(width: 0, height: 8)
        }
        iconView.tintColor = .white
        iconView.contentMode = .center
        iconView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(
            pointSize: isLarge ? Metrics.largeIconSize : Metrics.iconSize,
            weight: .semibold
        )
        iconView.translatesAutoresizingMaskIntoConstraints = false
        circle.addSubview(iconView)
        sizeConstraints = [
            circle.widthAnchor.constraint(equalToConstant: size),
            circle.heightAnchor.constraint(equalToConstant: size),
        ]
        NSLayoutConstraint.activate(sizeConstraints)
        NSLayoutConstraint.activate([
            iconView.centerXAnchor.constraint(equalTo: circle.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: circle.centerYAnchor),
        ])
    }

    private func buildStack(size: CGFloat, isLarge: Bool) {
        caption.textAlignment = .center
        if isLarge {
            caption.font = .systemFont(ofSize: 15, weight: .medium)
        }
        let stack = UIStackView(
            [circle, caption],
            axis: .vertical,
            spacing: isLarge ? Metrics.largeCaptionSpacing : Metrics.captionSpacing,
            alignment: .center
        )
        stack.isUserInteractionEnabled = false
        addPinnedSubview(stack)
        widthAnchor.constraint(greaterThanOrEqualToConstant: isLarge ? Metrics.largeMinimumWidth : size).isActive = true
        if isDecision {
            heightAnchor.constraint(greaterThanOrEqualToConstant: Metrics.decisionMinimumHeight).isActive = true
        }
    }

    private static func highlight(_ color: UIColor) -> UIColor {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return UIColor(
            red: red + (1 - red) * 0.12,
            green: green + (1 - green) * 0.12,
            blue: blue + (1 - blue) * 0.12,
            alpha: 1
        )
    }
}

private enum Metrics {
    static let largeSize: CGFloat = 76
    static let iconSize: CGFloat = 24
    static let largeIconSize: CGFloat = 28
    static let captionSpacing: CGFloat = 7
    static let largeCaptionSpacing: CGFloat = 10
    static let largeMinimumWidth: CGFloat = 96
    static let decisionMinimumHeight: CGFloat = 108
    static let glassTintAlpha: CGFloat = 0.24
}

#if DEBUG
#Preview("Component · Call Backdrop") {
    AirSIMPreviewFixtures.canvas(CallBackdropView(), height: 600, dark: true)
}

#Preview("Component · Call Circle Control") {
    AirSIMPreviewFixtures.canvas(
        CallCircleControl(title: "End", icon: "phone.down.fill", size: 76, color: .systemRed) {},
        width: 110,
        height: 108,
        dark: true
    )
}
#endif
