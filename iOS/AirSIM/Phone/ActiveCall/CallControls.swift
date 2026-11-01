import UIKit

@MainActor
final class CallBackdropView: UIView {
    private let top = CAGradientLayer()
    private let bottom = CAGradientLayer()
    override init(frame: CGRect) {
        super.init(frame: frame); backgroundColor = UIColor(red: 0.008, green: 0.012, blue: 0.025, alpha: 1)
        top.type = .radial; top.colors = [UIColor.systemBlue.withAlphaComponent(0.24).cgColor, UIColor.clear.cgColor]; top.startPoint = CGPoint(x: 0.5, y: 0.5); top.endPoint = CGPoint(x: 1, y: 1)
        bottom.type = .radial; bottom.colors = [UIColor.cyan.withAlphaComponent(0.12).cgColor, UIColor.clear.cgColor]; bottom.startPoint = CGPoint(x: 0.5, y: 0.5); bottom.endPoint = CGPoint(x: 1, y: 1)
        layer.addSublayer(top); layer.addSublayer(bottom)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() { super.layoutSubviews(); top.frame = CGRect(x: bounds.width - 420, y: -420, width: 840, height: 840); bottom.frame = CGRect(x: -360, y: bounds.height - 360, width: 720, height: 720) }
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
        if isDecision { circle.layer.insertSublayer(gradient, at: 0); heightAnchor.constraint(greaterThanOrEqualToConstant: 108).isActive = true }
        else { material.frame = circle.bounds; material.autoresizingMask = [.flexibleWidth, .flexibleHeight]; material.clipsToBounds = true; circle.addSubview(material) }
        circle.layer.cornerRadius = size / 2; circle.backgroundColor = color ?? UIColor.white.withAlphaComponent(0.12)
        circle.layer.borderColor = UIColor.white.withAlphaComponent(0.12).cgColor; circle.layer.borderWidth = 0.5
        iconView.tintColor = .white; iconView.contentMode = .center; iconView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: size == 76 ? 28 : 24, weight: .semibold)
        iconView.translatesAutoresizingMaskIntoConstraints = false; circle.addSubview(iconView)
        sizeConstraints = [circle.widthAnchor.constraint(equalToConstant: size), circle.heightAnchor.constraint(equalToConstant: size)]; NSLayoutConstraint.activate(sizeConstraints)
        NSLayoutConstraint.activate([iconView.centerXAnchor.constraint(equalTo: circle.centerXAnchor), iconView.centerYAnchor.constraint(equalTo: circle.centerYAnchor)])
        caption.textAlignment = .center; if size == 76 { caption.font = .systemFont(ofSize: 15, weight: .medium); circle.layer.shadowColor = (color ?? .clear).cgColor; circle.layer.shadowOpacity = 0.28; circle.layer.shadowRadius = 16; circle.layer.shadowOffset = CGSize(width: 0, height: 8) }
        let stack = UIStackView(arrangedSubviews: [circle, caption]); stack.axis = .vertical; stack.spacing = size == 76 ? 10 : 7; stack.alignment = .center; stack.isUserInteractionEnabled = false; stack.translatesAutoresizingMaskIntoConstraints = false; addSubview(stack)
        NSLayoutConstraint.activate([stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor), stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor), widthAnchor.constraint(greaterThanOrEqualToConstant: size == 76 ? 96 : size)])
        update(title: title, icon: icon, tint: color); addAction(UIAction { _ in action() }, for: .touchUpInside)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func setSize(_ size: CGFloat) { sizeConstraints.forEach { $0.constant = size }; circle.layer.cornerRadius = size / 2; material.layer.cornerRadius = size / 2 }
    override func layoutSubviews() { super.layoutSubviews(); gradient.frame = circle.bounds; gradient.cornerRadius = circle.bounds.width / 2; material.layer.cornerRadius = circle.bounds.width / 2 }
    func update(title: String, icon: String, tint: UIColor?) {
        caption.text = title; iconView.image = UIImage(systemName: icon); accessibilityLabel = title
        if isDecision, let tint {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0; tint.getRed(&r, green: &g, blue: &b, alpha: &a)
            gradient.colors = [UIColor(red: r + (1-r)*0.12, green: g + (1-g)*0.12, blue: b + (1-b)*0.12, alpha: 1).cgColor, tint.cgColor]
            circle.backgroundColor = tint
        } else {
            circle.backgroundColor = .clear
            if #available(iOS 26.0, *) { let glass = UIGlassEffect(style: .regular); glass.isInteractive = true; glass.tintColor = tint?.withAlphaComponent(0.24); material.effect = glass }
            else { material.effect = UIBlurEffect(style: .systemUltraThinMaterialDark); material.contentView.backgroundColor = tint?.withAlphaComponent(0.24) }
        }
    }
}

#if DEBUG
#Preview("Component · Call Backdrop") {
    AirSIMPreviewFixtures.canvas(CallBackdropView(), height: 600, dark: true)
}

#Preview("Component · Call Circle Control") {
    AirSIMPreviewFixtures.canvas(CallCircleControl(title: "End", icon: "phone.down.fill", size: 76, color: .systemRed) {}, width: 110, height: 108, dark: true)
}
#endif
