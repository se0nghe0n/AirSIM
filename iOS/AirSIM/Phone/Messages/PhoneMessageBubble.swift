import UIKit

@MainActor
private final class BubbleLabel: UILabel {
    let padding = UIEdgeInsets(top: 9, left: 14, bottom: 9, right: 14)
    override func drawText(in rect: CGRect) { super.drawText(in: rect.inset(by: padding)) }
    override func textRect(forBounds bounds: CGRect, limitedToNumberOfLines numberOfLines: Int) -> CGRect {
        let rect = super.textRect(forBounds: bounds.inset(by: padding), limitedToNumberOfLines: numberOfLines)
        return rect.inset(by: UIEdgeInsets(top: -padding.top, left: -padding.left, bottom: -padding.bottom, right: -padding.right))
    }
}

@MainActor
final class PhoneMessageBubble: UIView {
    init(message: SMSMessage) {
        super.init(frame: .zero)
        let label = BubbleLabel(); label.text = message.content; label.font = .preferredFont(forTextStyle: .body); label.numberOfLines = 0
        label.textColor = message.isOutgoing ? .white : .label; label.backgroundColor = message.isOutgoing ? .systemBlue : .secondarySystemBackground
        label.layer.cornerRadius = 18; label.clipsToBounds = true
        let stack = UIStackView(arrangedSubviews: [label]); stack.axis = .vertical; stack.spacing = 3; stack.alignment = message.isOutgoing ? .trailing : .leading
        if message.isOutgoing { stack.addArrangedSubview(phoneLabel("Sent", size: 11, color: .secondaryLabel)) }
        stack.translatesAutoresizingMaskIntoConstraints = false; addSubview(stack)
        NSLayoutConstraint.activate([stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor), stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor), label.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -48)])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

#if DEBUG
#Preview("Component · Bubble Label") {
    let label = BubbleLabel()
    label.text = "The label preserves multiline text and its message padding."
    label.font = .preferredFont(forTextStyle: .body)
    label.numberOfLines = 0
    label.textColor = .white
    label.backgroundColor = .systemBlue
    label.layer.cornerRadius = 18
    label.clipsToBounds = true
    return AirSIMPreviewFixtures.canvas(label, width: 300, height: 80)
}

#Preview("Component · Message Bubble") {
    AirSIMPreviewFixtures.canvas(PhoneMessageBubble(message: AirSIMPreviewFixtures.messages[1]), height: 90)
}
#endif
