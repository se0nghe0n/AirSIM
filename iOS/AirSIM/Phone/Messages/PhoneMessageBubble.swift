import UIKit

/// Draws its text inside the bubble padding and includes the padding in its size.
@MainActor
private final class BubbleLabel: UILabel {
    let padding = UIEdgeInsets(top: 9, left: 14, bottom: 9, right: 14)

    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.inset(by: padding))
    }

    override func textRect(forBounds bounds: CGRect, limitedToNumberOfLines numberOfLines: Int) -> CGRect {
        let rect = super.textRect(forBounds: bounds.inset(by: padding), limitedToNumberOfLines: numberOfLines)
        let outset = UIEdgeInsets(
            top: -padding.top,
            left: -padding.left,
            bottom: -padding.bottom,
            right: -padding.right
        )
        return rect.inset(by: outset)
    }
}

/// One message in a thread: a blue outgoing bubble with "Sent" under it, or a gray incoming one.
@MainActor
final class PhoneMessageBubble: UIView {
    init(message: SMSMessage) {
        super.init(frame: .zero)
        let label = bubbleLabel(message)
        let stack = UIStackView(
            [label],
            axis: .vertical,
            spacing: Metrics.captionSpacing,
            alignment: message.isOutgoing ? .trailing : .leading
        )
        if message.isOutgoing {
            stack.addArrangedSubview(phoneLabel("Sent", size: 11, color: .secondaryLabel))
        }
        addPinnedSubview(stack)
        label.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -Metrics.oppositeSideGap).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func bubbleLabel(_ message: SMSMessage) -> UILabel {
        let label = BubbleLabel()
        label.text = message.content
        label.font = .preferredFont(forTextStyle: .body)
        label.numberOfLines = 0
        label.textColor = message.isOutgoing ? .white : .label
        label.backgroundColor = message.isOutgoing ? .systemBlue : .secondarySystemBackground
        label.layer.cornerRadius = Metrics.cornerRadius
        label.clipsToBounds = true
        return label
    }
}

private enum Metrics {
    static let captionSpacing: CGFloat = 3
    static let cornerRadius: CGFloat = 18
    /// The narrowest gap a bubble leaves on the side it does not hug.
    static let oppositeSideGap: CGFloat = 48
}

#if DEBUG
#Preview("Component · Bubble Label") {
    let label = BubbleLabel()
    label.text = "The label preserves multiline text and its message padding."
    label.font = .preferredFont(forTextStyle: .body)
    label.numberOfLines = 0
    label.textColor = .white
    label.backgroundColor = .systemBlue
    label.layer.cornerRadius = Metrics.cornerRadius
    label.clipsToBounds = true
    return AirSIMPreviewFixtures.canvas(label, width: 300, height: 80)
}

#Preview("Component · Message Bubble") {
    AirSIMPreviewFixtures.canvas(PhoneMessageBubble(message: AirSIMPreviewFixtures.messages[1]), height: 90)
}
#endif
