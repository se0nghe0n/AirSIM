import UIKit

@MainActor
final class PairedAndroidAgentsViewController: PhoneTableController {
    let model: AirSIMPresentation
    init(model: AirSIMPresentation) { self.model = model; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() { super.viewDidLoad(); title = "Paired Android Agents" }
    override func render() {
        let rows = model.pairedAndroidAgents.map { agent in
            PhoneRow(id: agent.id, title: agent.deviceName, detail: "\(agent.phoneNumber ?? "Number unavailable")\nVoWLAN \(agent.vowlanOnline ? "Online" : "Offline") · Cloud \(!CloudModePreference.isEnabled() ? "Off" : (agent.cloudOnline ? "Online" : "Offline")) · \(String(localized: agent.agentKindTitle))", image: agent.isCurrent ? "checkmark.circle.fill" : "circle", color: agent.isCurrent ? .systemGreen : .label, action: { [weak self] in self?.model.bindAndroidAgent(agent.id) })
        }
        setSections([PhoneSection(rows: rows.isEmpty ? [PhoneRow(id: "empty", title: "No paired Android Agents", image: "smartphone.slash")] : rows)])
    }
}

#if DEBUG
#Preview("Paired Android Agents") {
    AirSIMPreviewFixtures.navigation(PairedAndroidAgentsViewController(model: AirSIMPreviewFixtures.presentation()))
}
#endif
