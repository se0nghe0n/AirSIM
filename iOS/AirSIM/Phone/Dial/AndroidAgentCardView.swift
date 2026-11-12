import UIKit

@MainActor
final class AndroidAgentCardView: UIView {
    /// Everything the card shows; the Dial screen rebuilds the card only when this changes.
    struct Content: Equatable {
        let agent: AndroidAgentPresentation?
        let count: Int
        let cloudEnabled: Bool

        /// The card is one button, so VoiceOver hears what it shows in a single label.
        var accessibilityLabel: String {
            guard let agent else {
                return "Paired Android Agents, \(count), No call route is currently available"
            }
            var parts = [
                agent.deviceName,
                "Current",
                agent.phoneNumber ?? "Number unavailable",
                agent.vowlanStatus,
                agent.cloudStatus(cloudModeEnabled: cloudEnabled),
                String(localized: agent.agentKindTitle),
            ]
            if count > 1 {
                parts.append("All \(count)")
            }
            return parts.joined(separator: ", ")
        }
    }

    convenience init(agent: AndroidAgentPresentation?, count: Int, cloudEnabled: Bool) {
        self.init(content: Content(agent: agent, count: count, cloudEnabled: cloudEnabled))
    }

    init(content: Content) {
        super.init(frame: .zero)
        let stack = UIStackView(axis: .vertical, spacing: Metrics.sectionSpacing)
        stack.addArrangedSubview(summaryRow(content))
        if let agent = content.agent {
            stack.addArrangedSubview(routesRow(agent: agent, cloudEnabled: content.cloudEnabled))
        }
        let material = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterial))
        material.layer.cornerRadius = Metrics.cornerRadius
        material.clipsToBounds = true
        material.contentView.addPinnedSubview(stack, insets: Metrics.padding)
        addPinnedSubview(material)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func summaryRow(_ content: Content) -> UIStackView {
        let row = UIStackView(
            [icon(for: content.agent), titleAndDetail(agent: content.agent, count: content.count)],
            axis: .horizontal,
            spacing: Metrics.rowSpacing,
            alignment: .center
        )
        if content.agent == nil {
            let chevron = UIImageView(image: UIImage(systemName: "chevron.right"))
            chevron.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .caption1, scale: .default)
                .applying(UIImage.SymbolConfiguration(weight: .semibold))
            chevron.tintColor = .tertiaryLabel
            chevron.setContentHuggingPriority(.required, for: .horizontal)
            row.addArrangedSubview(chevron)
        } else if content.count > 1 {
            let all = Self.label("All \(content.count)", style: .caption1, size: 12, weight: .semibold)
            all.textColor = .systemBlue
            all.setContentHuggingPriority(.required, for: .horizontal)
            row.addArrangedSubview(all)
        }
        return row
    }

    private func icon(for agent: AndroidAgentPresentation?) -> UIImageView {
        let icon = UIImageView(image: UIImage(systemName: agent == nil ? "smartphone.slash" : "smartphone"))
        icon.tintColor = agent == nil ? .secondaryLabel : .systemGreen
        icon.contentMode = .center
        icon.backgroundColor = UIColor.systemGreen.withAlphaComponent(agent == nil ? 0 : 0.12)
        icon.layer.cornerRadius = Metrics.iconSize / 2
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: Metrics.iconSize),
            icon.heightAnchor.constraint(equalToConstant: Metrics.iconSize),
        ])
        return icon
    }

    private func titleAndDetail(agent: AndroidAgentPresentation?, count: Int) -> UIStackView {
        let title = Self.label(
            agent?.deviceName ?? "Paired Android Agents · \(count)",
            style: .subheadline,
            size: 15,
            weight: .semibold
        )
        let titleRow = UIStackView([title], axis: .horizontal, spacing: Metrics.titleSpacing)
        if agent != nil {
            titleRow.addArrangedSubview(Self.pill("Current", color: .systemGreen, weight: .bold))
        }
        titleRow.addArrangedSubview(UIView())
        let detailText =
            if let agent {
                agent.phoneNumber ?? "Number unavailable"
            } else {
                "No call route is currently available"
            }
        let detail = Self.label(detailText, style: .caption1, size: 12)
        detail.textColor = .secondaryLabel
        return UIStackView([titleRow, detail], axis: .vertical, spacing: Metrics.titleToDetailSpacing)
    }

    private func routesRow(agent: AndroidAgentPresentation, cloudEnabled: Bool) -> UIStackView {
        let kind = Self.label(String(localized: agent.agentKindTitle), style: .caption2, size: 10)
        kind.textColor = .secondaryLabel
        return UIStackView(
            Self.transportPills(agent: agent, cloudEnabled: cloudEnabled) + [UIView(), kind],
            axis: .horizontal,
            spacing: Metrics.routeSpacing,
            alignment: .center
        )
    }

    // MARK: Shared parts

    /// The VoWLAN and Cloud pills, green while the route is online and enabled, as on the SwiftUI card and sheet.
    static func transportPills(agent: AndroidAgentPresentation, cloudEnabled: Bool) -> [UIView] {
        [
            transportPill(agent.vowlanStatus, online: agent.vowlanOnline, enabled: true),
            transportPill(
                agent.cloudStatus(cloudModeEnabled: cloudEnabled),
                online: agent.cloudOnline,
                enabled: cloudEnabled
            ),
        ]
    }

    private static func transportPill(_ title: String, online: Bool, enabled: Bool) -> UIView {
        let color: UIColor = enabled && online ? .systemGreen : .secondaryLabel
        let dot = UIView()
        dot.backgroundColor = color
        dot.layer.cornerRadius = Metrics.dotSize / 2
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: Metrics.dotSize),
            dot.heightAnchor.constraint(equalToConstant: Metrics.dotSize),
        ])
        let text = label(title, style: .caption2, size: 10, weight: .medium)
        text.textColor = color
        let box = UIStackView([dot, text], axis: .horizontal, spacing: Metrics.dotSpacing, alignment: .center)
        return capsule(box, color: color)
    }

    private static func pill(_ title: String, color: UIColor, weight: UIFont.Weight = .medium) -> UIView {
        let text = label(title, style: .caption2, size: 10, weight: weight)
        text.textColor = color
        return capsule(UIStackView([text], axis: .horizontal), color: color)
    }

    private static func capsule(_ box: UIStackView, color: UIColor) -> UIView {
        box.isLayoutMarginsRelativeArrangement = true
        box.layoutMargins = Metrics.pillPadding
        box.backgroundColor = color.withAlphaComponent(0.1)
        box.layer.cornerRadius = Metrics.pillCornerRadius
        box.setContentHuggingPriority(.required, for: .horizontal)
        return box
    }

    /// One line in a Dynamic Type font: the card grows with the text size instead of truncating it.
    private static func label(
        _ text: String,
        style: UIFont.TextStyle,
        size: CGFloat,
        weight: UIFont.Weight = .regular
    ) -> UILabel {
        let label = phoneLabel(text)
        label.font = UIFontMetrics(forTextStyle: style).scaledFont(for: .systemFont(ofSize: size, weight: weight))
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 1
        return label
    }
}

private enum Metrics {
    static let cornerRadius: CGFloat = 16
    static let padding = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
    static let sectionSpacing: CGFloat = 10
    static let rowSpacing: CGFloat = 10
    static let iconSize: CGFloat = 34
    static let titleSpacing: CGFloat = 6
    static let titleToDetailSpacing: CGFloat = 2
    static let routeSpacing: CGFloat = 8
    static let dotSize: CGFloat = 6
    static let dotSpacing: CGFloat = 4
    static let pillPadding = UIEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
    static let pillCornerRadius: CGFloat = 10
}

#if DEBUG
#Preview("Component · Android Agent Card") {
    AirSIMPreviewFixtures.canvas(
        AndroidAgentCardView(agent: AirSIMPreviewFixtures.agents[0], count: 2, cloudEnabled: true),
        height: 94
    )
}

#Preview("Component · Android Agent Card · No Route") {
    AirSIMPreviewFixtures.canvas(
        AndroidAgentCardView(agent: nil, count: 2, cloudEnabled: true),
        height: 74
    )
}
#endif
