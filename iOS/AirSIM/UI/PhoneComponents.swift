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
func phoneButton(
    _ title: String,
    image: String? = nil,
    color: UIColor = .systemBlue,
    action: @escaping () -> Void
) -> UIButton {
    let button = PhoneActionButton(type: .system)
    var configuration = UIButton.Configuration.tinted()
    configuration.title = title
    configuration.image = image.flatMap(UIImage.init(systemName:))
    configuration.imagePadding = 8
    configuration.baseForegroundColor = color
    configuration.cornerStyle = .capsule
    button.configuration = configuration
    button.accessibilityLabel = title
    button.addAction(UIAction { _ in action() }, for: .touchUpInside)
    return button
}

@MainActor
func phoneLabel(_ text: String = "", size: CGFloat = 17, color: UIColor = .label) -> UILabel {
    let label = UILabel()
    label.text = text
    label.font = UIFontMetrics(forTextStyle: .body).scaledFont(for: .systemFont(ofSize: size))
    label.textColor = color
    label.numberOfLines = 0
    label.adjustsFontForContentSizeCategory = true
    return label
}

@MainActor
func phoneAvatar(name: String, photo: Data?, size: CGFloat = 44) -> UIImage {
    let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size))
    return renderer.image { context in
        UIBezierPath(ovalIn: CGRect(x: 0, y: 0, width: size, height: size)).addClip()
        if let photo, let image = UIImage(data: photo) {
            drawAvatarPhoto(image, size: size)
            return
        }
        let gradient = name.isEmpty ? AvatarGradient.unnamed : AvatarGradient.named
        drawAvatarGradient(gradient, in: context.cgContext, size: size)
        let initial = name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1)
        if initial.isEmpty {
            drawAvatarPersonSymbol(size: size)
        } else {
            drawAvatarInitial(String(initial), size: size)
        }
    }
}

@MainActor
private func drawAvatarPhoto(_ image: UIImage, size: CGFloat) {
    let scale = max(size / image.size.width, size / image.size.height)
    let width = image.size.width * scale
    let height = image.size.height * scale
    image.draw(in: CGRect(x: (size - width) / 2, y: (size - height) / 2, width: width, height: height))
}

@MainActor
private func drawAvatarGradient(_ colors: [UIColor], in context: CGContext, size: CGFloat) {
    let cgColors = colors.map(\.cgColor) as CFArray
    let space = CGColorSpaceCreateDeviceRGB()
    guard let gradient = CGGradient(colorsSpace: space, colors: cgColors, locations: [0, 1]) else { return }
    context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size, y: size), options: [])
}

@MainActor
private func drawAvatarPersonSymbol(size: CGFloat) {
    let configuration = UIImage.SymbolConfiguration(pointSize: size * 0.52, weight: .semibold)
    let symbol = UIImage(systemName: "person.fill", withConfiguration: configuration)
    guard let person = symbol?.withTintColor(.white, renderingMode: .alwaysOriginal) else { return }
    person.draw(at: CGPoint(x: (size - person.size.width) / 2, y: (size - person.size.height) / 2 + size * 0.08))
}

@MainActor
private func drawAvatarInitial(_ initial: String, size: CGFloat) {
    let shadow = NSShadow()
    shadow.shadowColor = UIColor.systemIndigo.withAlphaComponent(0.55)
    shadow.shadowBlurRadius = 1.4
    shadow.shadowOffset = CGSize(width: 0, height: 1.2)
    let attributes: [NSAttributedString.Key: Any] = [
        .shadow: shadow,
        .font: UIFont.systemFont(ofSize: size * 0.46, weight: .bold).rounded(),
        .foregroundColor: UIColor.white,
    ]
    let text = initial as NSString
    let measured = text.size(withAttributes: attributes)
    text.draw(at: CGPoint(x: (size - measured.width) / 2, y: (size - measured.height) / 2), withAttributes: attributes)
}

private enum AvatarGradient {
    static let named = [
        UIColor(red: 0.66, green: 0.78, blue: 0.92, alpha: 1),
        UIColor(red: 0.43, green: 0.49, blue: 0.79, alpha: 1),
    ]
    static let unnamed = [
        UIColor(red: 0.64, green: 0.76, blue: 0.91, alpha: 1),
        UIColor(red: 0.43, green: 0.48, blue: 0.78, alpha: 1),
    ]
}

extension UIFont {
    func rounded() -> UIFont {
        UIFont(descriptor: fontDescriptor.withDesign(.rounded) ?? fontDescriptor, size: pointSize)
    }
}

@MainActor
final class MenuValueButton: UIButton {
    private let valueLabel = phoneLabel(color: .systemBlue)
    private let symbol = UIImageView()
    private let chevron = UIImageView(image: UIImage(systemName: "chevron.up.chevron.down"))

    override init(frame: CGRect) {
        super.init(frame: frame)
        symbol.tintColor = .systemBlue
        symbol.contentMode = .scaleAspectFit
        symbol.widthAnchor.constraint(equalToConstant: MenuValueMetrics.symbolWidth).isActive = true
        chevron.tintColor = .systemBlue
        chevron.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: MenuValueMetrics.chevronPointSize)
        valueLabel.setContentHuggingPriority(.required, for: .horizontal)
        chevron.setContentHuggingPriority(.required, for: .horizontal)
        let row = UIStackView(
            [symbol, valueLabel, chevron],
            axis: .horizontal,
            spacing: MenuValueMetrics.spacing,
            alignment: .center
        )
        row.isUserInteractionEnabled = false
        addPinnedSubview(row, insets: MenuValueMetrics.insets)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(title: String, icon: String?) {
        valueLabel.text = title
        symbol.image = icon.flatMap(UIImage.init(systemName:))
        symbol.isHidden = icon == nil
        accessibilityLabel = title
        invalidateIntrinsicContentSize()
    }

    override var intrinsicContentSize: CGSize {
        let symbolWidth = symbol.isHidden ? 0 : MenuValueMetrics.symbolWidth + MenuValueMetrics.spacing
        return CGSize(
            width: valueLabel.intrinsicContentSize.width + symbolWidth + MenuValueMetrics.chevronAllowance,
            height: MenuValueMetrics.height
        )
    }
}

private enum MenuValueMetrics {
    static let spacing: CGFloat = 5
    static let symbolWidth: CGFloat = 20
    static let chevronPointSize: CGFloat = 12
    static let chevronAllowance: CGFloat = 17
    static let insets = UIEdgeInsets(top: 6, left: 0, bottom: 6, right: 0)
    static let height: CGFloat = 32
}

#if DEBUG
#Preview("Component · Action Button") {
    AirSIMPreviewFixtures.canvas(
        phoneButton("Call", image: "phone.fill", color: .systemGreen) {},
        width: 140,
        height: 52
    )
}

#Preview("Component · Menu Value Button") {
    let button = MenuValueButton()
    button.update(title: "Automatic", icon: "arrow.triangle.branch")
    return AirSIMPreviewFixtures.canvas(button, width: 180, height: 44)
}
#endif
