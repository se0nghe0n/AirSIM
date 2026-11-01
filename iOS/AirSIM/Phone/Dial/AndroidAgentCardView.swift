import UIKit

/// The Dial screen's Android Agent summary: the current agent with its call routes, or the paired count while none is
/// current. It draws the values it is given.
@MainActor
final class AndroidAgentCardView: UIView {
    init(agent: AndroidAgentPresentation?, count: Int, cloudEnabled: Bool) {
        super.init(frame: .zero)
        let stack = UIStackView(axis: .vertical, spacing: Metrics.sectionSpacing)
        stack.addArrangedSubview(summaryRow(agent: agent, count: count))
        if let agent {
            stack.addArrangedSubview(routesRow(agent: agent, cloudEnabled: cloudEnabled))
        }
        let material = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterial))
        material.layer.cornerRadius = Metrics.cornerRadius
        material.clipsToBounds = true
        material.contentView.addPinnedSubview(stack, insets: Metrics.padding)
        addPinnedSubview(material)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// The icon, the title over the number, and "All n" when more than one agent is paired.
    private func summaryRow(agent: AndroidAgentPresentation?, count: Int) -> UIStackView {
        let row = UIStackView(
            [icon(for: agent), titleAndDetail(agent: agent, count: count)],
            axis: .horizontal,
            spacing: Metrics.rowSpacing,
            alignment: .center
        )
        if count > 1 {
            let all = phoneLabel("All \(count)", size: 12, color: .systemBlue)
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
        let title = phoneLabel(agent?.deviceName ?? "Paired Android Agents · \(count)", size: 15)
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.numberOfLines = 1
        let titleRow = UIStackView([title], axis: .horizontal, spacing: Metrics.titleSpacing)
        if agent != nil {
            titleRow.addArrangedSubview(pill("Current", color: .systemGreen))
        }
        titleRow.addArrangedSubview(UIView())
        let detailText = if let agent {
            agent.phoneNumber ?? "Number unavailable"
        } else {
            "No call route is currently available"
        }
        let detail = phoneLabel(detailText, size: 12, color: .secondaryLabel)
        detail.numberOfLines = 1
        return UIStackView([titleRow, detail], axis: .vertical, spacing: Metrics.titleToDetailSpacing)
    }

    /// The VoWLAN and Cloud route pills, and the agent kind.
    private func routesRow(agent: AndroidAgentPresentation, cloudEnabled: Bool) -> UIStackView {
        let vowlan = pill(agent.vowlanStatus, color: agent.vowlanOnline ? .systemGreen : .secondaryLabel)
        let cloud = pill(
            agent.cloudStatus(cloudModeEnabled: cloudEnabled),
            color: cloudEnabled && agent.cloudOnline ? .systemGreen : .secondaryLabel
        )
        let kind = phoneLabel(String(localized: agent.agentKindTitle), size: 10, color: .secondaryLabel)
        return UIStackView(
            [vowlan, cloud, UIView(), kind],
            axis: .horizontal,
            spacing: Metrics.routeSpacing,
            alignment: .center
        )
    }

    private func pill(_ title: String, color: UIColor) -> UIView {
        let text = phoneLabel(title, size: 10, color: color)
        text.font = .systemFont(ofSize: 10, weight: .medium)
        text.numberOfLines = 1
        let box = UIStackView([text], axis: .horizontal)
        box.isLayoutMarginsRelativeArrangement = true
        box.layoutMargins = Metrics.pillPadding
        box.backgroundColor = color.withAlphaComponent(0.1)
        box.layer.cornerRadius = Metrics.pillCornerRadius
        return box
    }
}

private enum Metrics {
    static let cornerRadius: CGFloat = 16
    static let padding = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
    /// Between the summary row and the routes row.
    static let sectionSpacing: CGFloat = 10
    static let rowSpacing: CGFloat = 10
    static let iconSize: CGFloat = 34
    static let titleSpacing: CGFloat = 6
    static let titleToDetailSpacing: CGFloat = 2
    static let routeSpacing: CGFloat = 8
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
#endif
