import UIKit

@MainActor
final class AndroidAgentCardView: UIView {
    init(agent: AndroidAgentPresentation?, count: Int, cloudEnabled: Bool) {
        super.init(frame: .zero)
        let material = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterial)); material.layer.cornerRadius = 16; material.clipsToBounds = true; material.translatesAutoresizingMaskIntoConstraints = false; addSubview(material)
        let stack = UIStackView(); stack.axis = .vertical; stack.spacing = 10; stack.translatesAutoresizingMaskIntoConstraints = false; material.contentView.addSubview(stack)
        let icon = UIImageView(image: UIImage(systemName: agent == nil ? "smartphone.slash" : "smartphone")); icon.tintColor = agent == nil ? .secondaryLabel : .systemGreen; icon.contentMode = .center; icon.widthAnchor.constraint(equalToConstant: 34).isActive = true; icon.heightAnchor.constraint(equalToConstant: 34).isActive = true; icon.backgroundColor = UIColor.systemGreen.withAlphaComponent(agent == nil ? 0 : 0.12); icon.layer.cornerRadius = 17
        let title = phoneLabel(agent?.deviceName ?? "Paired Android Agents · \(count)", size: 15); title.font = .systemFont(ofSize: 15, weight: .semibold); title.numberOfLines = 1
        let titleRow = UIStackView(arrangedSubviews: [title]); titleRow.axis = .horizontal; titleRow.spacing = 6
        if agent != nil { let current = pill("Current", color: .systemGreen); titleRow.addArrangedSubview(current) }
        titleRow.addArrangedSubview(UIView())
        let detail = phoneLabel(agent?.phoneNumber ?? (agent == nil ? "No call route is currently available" : "Number unavailable"), size: 12, color: .secondaryLabel); detail.numberOfLines = 1
        let text = UIStackView(arrangedSubviews: [titleRow, detail]); text.axis = .vertical; text.spacing = 2
        let row = UIStackView(arrangedSubviews: [icon, text]); row.axis = .horizontal; row.spacing = 10; row.alignment = .center
        if count > 1 { let all = phoneLabel("All \(count)", size: 12, color: .systemBlue); all.setContentHuggingPriority(.required, for: .horizontal); row.addArrangedSubview(all) }
        stack.addArrangedSubview(row)
        if let agent {
            let routes = UIStackView(arrangedSubviews: [pill("VoWLAN \(agent.vowlanOnline ? "Online" : "Offline")", color: agent.vowlanOnline ? .systemGreen : .secondaryLabel), pill("Cloud \(!cloudEnabled ? "Off" : (agent.cloudOnline ? "Online" : "Offline"))", color: cloudEnabled && agent.cloudOnline ? .systemGreen : .secondaryLabel), UIView(), phoneLabel(String(localized: agent.agentKindTitle), size: 10, color: .secondaryLabel)]); routes.axis = .horizontal; routes.spacing = 8; routes.alignment = .center; stack.addArrangedSubview(routes)
        }
        NSLayoutConstraint.activate([material.leadingAnchor.constraint(equalTo: leadingAnchor), material.trailingAnchor.constraint(equalTo: trailingAnchor), material.topAnchor.constraint(equalTo: topAnchor), material.bottomAnchor.constraint(equalTo: bottomAnchor), stack.leadingAnchor.constraint(equalTo: material.contentView.leadingAnchor, constant: 12), stack.trailingAnchor.constraint(equalTo: material.contentView.trailingAnchor, constant: -12), stack.topAnchor.constraint(equalTo: material.contentView.topAnchor, constant: 12), stack.bottomAnchor.constraint(equalTo: material.contentView.bottomAnchor, constant: -12)])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private func pill(_ title: String, color: UIColor) -> UIView {
        let text = phoneLabel(title, size: 10, color: color); text.font = .systemFont(ofSize: 10, weight: .medium); text.numberOfLines = 1
        let box = UIStackView(arrangedSubviews: [text]); box.isLayoutMarginsRelativeArrangement = true; box.layoutMargins = UIEdgeInsets(top: 4, left: 8, bottom: 4, right: 8); box.backgroundColor = color.withAlphaComponent(0.1); box.layer.cornerRadius = 10; return box
    }
}

#if DEBUG
#Preview("Component · Android Agent Card") {
    AirSIMPreviewFixtures.canvas(AndroidAgentCardView(agent: AirSIMPreviewFixtures.agents[0], count: 2, cloudEnabled: true), height: 94)
}
#endif
