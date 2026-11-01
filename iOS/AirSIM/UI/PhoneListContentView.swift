import UIKit

@MainActor
final class PhoneListContentView: UIView {
    init(
        name: String,
        subtitle: String,
        photo: Data?,
        avatarName: String,
        time: String? = nil,
        missed: Bool = false,
        callAction: (() -> Void)? = nil
    ) {
        super.init(frame: .zero)
        let row = UIStackView(
            [avatarView(name: avatarName, photo: photo), textStack(name: name, subtitle: subtitle, missed: missed)],
            axis: .horizontal,
            spacing: Metrics.avatarSpacing,
            alignment: .center
        )
        if let time {
            row.addArrangedSubview(timeLabel(time))
        }
        if let callAction {
            row.addArrangedSubview(dialButton(callAction))
        }
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(greaterThanOrEqualToConstant: Metrics.minimumHeight),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: Metrics.verticalInset),
            row.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -Metrics.verticalInset),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func avatarView(name: String, photo: Data?) -> UIImageView {
        let avatar = UIImageView(image: phoneAvatar(name: name, photo: photo, size: Metrics.avatarSize))
        avatar.contentMode = .scaleAspectFill
        NSLayoutConstraint.activate([
            avatar.widthAnchor.constraint(equalToConstant: Metrics.avatarSize),
            avatar.heightAnchor.constraint(equalToConstant: Metrics.avatarSize),
        ])
        return avatar
    }

    private func textStack(name: String, subtitle: String, missed: Bool) -> UIStackView {
        let title = phoneLabel(name)
        title.font = UIFontMetrics(forTextStyle: .body).scaledFont(for: .systemFont(ofSize: 17, weight: .semibold))
        title.numberOfLines = 1
        title.textColor = missed ? .systemRed : .label
        let detail = phoneLabel(subtitle, size: 15, color: missed ? .systemRed : .secondaryLabel)
        detail.numberOfLines = 1
        return UIStackView([title, detail], axis: .vertical, spacing: Metrics.textSpacing)
    }

    private func timeLabel(_ time: String) -> UILabel {
        let label = phoneLabel(time, size: 15, color: .secondaryLabel)
        label.numberOfLines = 1
        label.textAlignment = .right
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.78
        label.widthAnchor.constraint(equalToConstant: Metrics.timeWidth).isActive = true
        return label
    }

    private func dialButton(_ action: @escaping () -> Void) -> UIButton {
        let button = phoneButton("Dial", image: "phone.fill", action: action)
        button.configuration?.title = nil
        button.configuration?.background.backgroundColor = .secondarySystemBackground
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: Metrics.dialButtonSize),
            button.heightAnchor.constraint(equalToConstant: Metrics.dialButtonSize),
        ])
        return button
    }
}

private enum Metrics {
    static let minimumHeight: CGFloat = 74
    static let verticalInset: CGFloat = 6
    static let avatarSize: CGFloat = 50
    static let avatarSpacing: CGFloat = 11
    static let textSpacing: CGFloat = 3
    static let timeWidth: CGFloat = 76
    static let dialButtonSize: CGFloat = 44
}

#if DEBUG
#Preview("Component · Phone List Row") {
    AirSIMPreviewFixtures.canvas(
        PhoneListContentView(
            name: "Mina Kim",
            subtitle: "↙ AirSIM Audio",
            photo: nil,
            avatarName: "Mina Kim",
            time: "10:42",
            callAction: {}
        ),
        height: 74
    )
}
#endif
