import Foundation

struct PairedAgentRow: Equatable, Identifiable {
    let id: String
    let agent: AndroidAgentPresentation
    let cloudModeEnabled: Bool
    let title: String
    let number: String
    let detail: String
    let isCurrent: Bool

    init(agent: AndroidAgentPresentation, cloudModeEnabled: Bool) {
        id = agent.id
        self.agent = agent
        self.cloudModeEnabled = cloudModeEnabled
        title = agent.deviceName
        number = agent.phoneNumber ?? "Number unavailable"
        let routes = "\(agent.vowlanStatus) · \(agent.cloudStatus(cloudModeEnabled: cloudModeEnabled))"
        detail = "\(number)\n\(routes) · \(String(localized: agent.agentKindTitle))"
        isCurrent = agent.isCurrent
    }

    var kind: String { String(localized: agent.agentKindTitle) }

    var accessibilityLabel: String {
        [title, number, agent.vowlanStatus, agent.cloudStatus(cloudModeEnabled: cloudModeEnabled), kind]
            .joined(separator: ", ")
    }
}

extension AndroidAgentPresentation {
    var vowlanStatus: String { "VoWLAN \(vowlanOnline ? "Online" : "Offline")" }

    func cloudStatus(cloudModeEnabled: Bool) -> String {
        "Cloud \(!cloudModeEnabled ? "Off" : (cloudOnline ? "Online" : "Offline"))"
    }
}
