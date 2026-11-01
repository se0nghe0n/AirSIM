import Foundation

/// One Paired Android Agents row, ready to draw.
struct PairedAgentRow: Equatable, Identifiable {
    let id: String
    let title: String
    /// "+1 202 555 0100\nVoWLAN Online · Cloud Off · Standalone".
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
    /// "VoWLAN Online" or "VoWLAN Offline".
    var vowlanStatus: String { "VoWLAN \(vowlanOnline ? "Online" : "Offline")" }

    /// "Cloud Off" while cloud mode is disabled, else "Cloud Online" or "Cloud Offline".
    func cloudStatus(cloudModeEnabled: Bool) -> String {
        "Cloud \(!cloudModeEnabled ? "Off" : (cloudOnline ? "Online" : "Offline"))"
    }
}
