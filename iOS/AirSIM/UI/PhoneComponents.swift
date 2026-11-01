import UIKit

@MainActor
final class PhoneActionButton: UIButton {
    var accessibilityAction: (() -> Void)?
    override func accessibilityActivate() -> Bool {
        guard let accessibilityAction else { return super.accessibilityActivate() }
        accessibilityAction()
        return true
    }
}

@MainActor
func phoneButton(_ title: String, image: String? = nil, color: UIColor = .systemBlue, action: @escaping () -> Void) -> UIButton {
    let button = PhoneActionButton(type: .system)
    var config = UIButton.Configuration.tinted()
    config.title = title; config.image = image.flatMap(UIImage.init(systemName:)); config.imagePadding = 8
    config.baseForegroundColor = color; config.cornerStyle = .capsule
    button.configuration = config
    button.accessibilityLabel = title
    button.addAction(UIAction { _ in action() }, for: .touchUpInside)
    return button
}

@MainActor
func phoneLabel(_ text: String = "", size: CGFloat = 17, color: UIColor = .label) -> UILabel {
    let label = UILabel(); label.text = text; label.font = UIFontMetrics(forTextStyle: .body).scaledFont(for: .systemFont(ofSize: size))
    label.textColor = color; label.numberOfLines = 0; label.adjustsFontForContentSizeCategory = true
    return label
}

@MainActor
func phoneAvatar(name: String, photo: Data?, size: CGFloat = 44) -> UIImage {
    let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size))
    return renderer.image { context in
        let rect = CGRect(x: 0, y: 0, width: size, height: size)
        UIBezierPath(ovalIn: rect).addClip()
        if let photo, let image = UIImage(data: photo) {
            let scale = max(size / image.size.width, size / image.size.height)
            image.draw(in: CGRect(x: (size - image.size.width * scale) / 2, y: (size - image.size.height * scale) / 2, width: image.size.width * scale, height: image.size.height * scale)); return
        }
        let colors = name.isEmpty ? [UIColor(red: 0.64, green: 0.76, blue: 0.91, alpha: 1).cgColor, UIColor(red: 0.43, green: 0.48, blue: 0.78, alpha: 1).cgColor] as CFArray : [UIColor(red: 0.66, green: 0.78, blue: 0.92, alpha: 1).cgColor, UIColor(red: 0.43, green: 0.49, blue: 0.79, alpha: 1).cgColor] as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) { context.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size, y: size), options: []) }
        let initial = name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1)
        if initial.isEmpty {
            if let person = UIImage(systemName: "person.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: size * 0.52, weight: .semibold))?.withTintColor(.white, renderingMode: .alwaysOriginal) {
                person.draw(at: CGPoint(x: (size - person.size.width) / 2, y: (size - person.size.height) / 2 + size * 0.08))
            }
        } else {
            let shadow = NSShadow(); shadow.shadowColor = UIColor.systemIndigo.withAlphaComponent(0.55); shadow.shadowBlurRadius = 1.4; shadow.shadowOffset = CGSize(width: 0, height: 1.2)
            let attributes: [NSAttributedString.Key: Any] = [.shadow: shadow, .font: UIFont.systemFont(ofSize: size * 0.46, weight: .bold).rounded(), .foregroundColor: UIColor.white]
            let text = String(initial) as NSString; let measured = text.size(withAttributes: attributes)
            text.draw(at: CGPoint(x: (size - measured.width) / 2, y: (size - measured.height) / 2), withAttributes: attributes)
        }
    }
}

extension UIFont {
    func rounded() -> UIFont { UIFont(descriptor: fontDescriptor.withDesign(.rounded) ?? fontDescriptor, size: pointSize) }
}

@MainActor
final class MenuValueButton: UIButton {
    private let valueLabel = phoneLabel(color: .systemBlue)
    private let symbol = UIImageView()
    private let chevron = UIImageView(image: UIImage(systemName: "chevron.up.chevron.down"))
    private let row = UIStackView()
    override init(frame: CGRect) {
        super.init(frame: frame)
        row.axis = .horizontal; row.spacing = 5; row.alignment = .center; row.isUserInteractionEnabled = false
        symbol.tintColor = .systemBlue; symbol.contentMode = .scaleAspectFit; chevron.tintColor = .systemBlue; chevron.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 12)
        symbol.widthAnchor.constraint(equalToConstant: 20).isActive = true
        valueLabel.setContentHuggingPriority(.required, for: .horizontal)
        chevron.setContentHuggingPriority(.required, for: .horizontal)
        [symbol, valueLabel, chevron].forEach { row.addArrangedSubview($0) }; row.translatesAutoresizingMaskIntoConstraints = false; addSubview(row)
        NSLayoutConstraint.activate([row.leadingAnchor.constraint(equalTo: leadingAnchor), row.trailingAnchor.constraint(equalTo: trailingAnchor), row.topAnchor.constraint(equalTo: topAnchor, constant: 6), row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6)])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func update(title: String, icon: String?) { valueLabel.text = title; symbol.image = icon.flatMap(UIImage.init(systemName:)); symbol.isHidden = icon == nil; accessibilityLabel = title; invalidateIntrinsicContentSize() }
    override var intrinsicContentSize: CGSize { CGSize(width: valueLabel.intrinsicContentSize.width + (symbol.isHidden ? 0 : 25) + 17, height: 32) }
}

#if DEBUG
#Preview("Component · Action Button") {
    AirSIMPreviewFixtures.canvas(phoneButton("Call", image: "phone.fill", color: .systemGreen) {}, width: 140, height: 52)
}

#Preview("Component · Menu Value Button") {
    let button = MenuValueButton()
    button.update(title: "Automatic", icon: "arrow.triangle.branch")
    return AirSIMPreviewFixtures.canvas(button, width: 180, height: 44)
}
#endif
