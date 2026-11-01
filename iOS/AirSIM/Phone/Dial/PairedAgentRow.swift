import Foundation

struct PairedAgentRow: Equatable, Identifiable {
    let id: String
    let title: String
    let detail: String
    let isCurrent: Bool

    init(agent: AndroidAgentPresentation, cloudModeEnabled: Bool) {
        id = agent.id
        title = agent.deviceName
        let number = agent.phoneNumber ?? "Number unavailable"
        let routes = "\(agent.vowlanStatus) · \(agent.cloudStatus(cloudModeEnabled: cloudModeEnabled))"
        detail = "\(number)\n\(routes) · \(String(localized: agent.agentKindTitle))"
        isCurrent = agent.isCurrent
    }
}

extension AndroidAgentPresentation {
    var vowlanStatus: String { "VoWLAN \(vowlanOnline ? "Online" : "Offline")" }

    func cloudStatus(cloudModeEnabled: Bool) -> String {
        "Cloud \(!cloudModeEnabled ? "Off" : (cloudOnline ? "Online" : "Offline"))"
    }
}
