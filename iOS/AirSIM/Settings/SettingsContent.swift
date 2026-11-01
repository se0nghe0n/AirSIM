import Foundation

enum SettingsTone: Equatable {
    case secondary
    case blue
    case green
    case orange
    case red
}

struct PairedDeviceRow: Equatable, Identifiable {
    let id: String
    let name: String
    let number: String
    let route: String

    init(device: AndroidAgentPresentation) {
        id = device.id
        name = device.deviceName
        number = device.phoneNumber ?? "Number unavailable"
        let routes = [
            device.vowlanOnline ? "VoWLAN Online" : nil,
            device.cloudOnline ? "Cloud Online" : nil,
        ]
        .compactMap { $0 }
        route = routes.isEmpty ? "Offline · Refreshes on reconnection" : routes.joined(separator: " · ")
    }

    var detail: String { "\(number)\n\(route)" }
}

struct SelfTestStepRow: Equatable, Identifiable {
    let id: String
    let title: String
    let detail: String
    let icon: String
    let tone: SettingsTone

    init(step: CloudSelfTestStep) {
        id = String(describing: step.id)
        title = step.title
        detail = step.detail
        switch step.state {
        case .pending:
            icon = "circle"
            tone = .secondary
        case .running:
            icon = "arrow.triangle.2.circlepath"
            tone = .blue
        case .passed:
            icon = "checkmark.circle.fill"
            tone = .green
        case .failed:
            icon = "xmark.circle.fill"
            tone = .red
        }
    }
}

struct SelfTestResult: Equatable {
    let text: String
    let tone: SettingsTone

    init(report: CloudSelfTestReport) {
        text = report.allPassed ? "Cloud self-test passed" : "Self-test failed. Resolve the failed steps and try again."
        tone = report.allPassed ? .green : .orange
    }
}
