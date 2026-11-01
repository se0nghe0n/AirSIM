import UIKit

@MainActor
final class AirSIMSettingsViewController: PhoneTableController {
    let model: AirSIMPresentation
    let settings: SettingsPresentation
    private var modeControl: MenuValueButton!
    private var appearanceControl: MenuValueButton!
    private let activitySwitch = UISwitch()
    let relayURL = UITextField()
    private var message: String? { model.store.settings.message }
    private var selfTestReport: CloudSelfTestReport? { model.store.settings.report }
    private var selfTestRunning: Bool { model.store.settings.selfTestRunning }
    private var selfTestCompleted: Bool { model.store.settings.selfTestCompleted }
    private var deviceDeletionInProgress: Bool { model.store.settings.deletingDevice }
    init(model: AirSIMPresentation, settings: SettingsPresentation) { self.model = model; self.settings = settings; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() {
        super.viewDidLoad(); title = "Settings"
        modeControl = MenuValueButton(); modeControl.showsMenuAsPrimaryAction = true
        appearanceControl = MenuValueButton(); appearanceControl.showsMenuAsPrimaryAction = true
        activitySwitch.accessibilityLabel = "Show Dynamic Island"
        activitySwitch.addAction(UIAction { [weak self] _ in guard let self else { return }; self.model.setLiveActivityEnabled(self.activitySwitch.isOn) }, for: .valueChanged)
        relayURL.text = model.store.settings.relayURL
        relayURL.addAction(UIAction { [weak self] _ in guard let self else { return }; self.model.store.send(.settings(.relayChanged(self.relayURL.text ?? ""))) }, for: .editingChanged)
        relayURL.placeholder = "https://relay.example.com"; relayURL.keyboardType = .URL; relayURL.autocapitalizationType = .none; relayURL.autocorrectionType = .no; relayURL.borderStyle = .roundedRect; relayURL.frame.size = CGSize(width: 250, height: 44); relayURL.accessibilityLabel = "Cloud Relay URL"
    }
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        Task { await model.refreshPairedDeviceInformation() }
    }
    override func viewWillDisappear(_ animated: Bool) { super.viewWillDisappear(animated); cancelTest() }
    private func cancelTest() { model.store.send(.settings(.disappeared)) }
    override func render() {
        let mode = model.store.settings.mode; let cloud = ConnectionModeRuntimePolicy(mode: mode).startsCloud
        modeControl.update(title: String(localized: mode.title), icon: mode == .vowlan ? "wifi" : (mode == .cloud ? "cloud" : "arrow.triangle.branch"))
        modeControl.menu = UIMenu(children: AirSIMConnectionMode.allCases.map { choice in UIAction(title: String(localized: choice.title), state: choice == mode ? .on : .off) { [weak self] _ in self?.model.store.send(.settings(.modeChanged(choice))) } })
        appearanceControl.update(title: settings.appearance.title, icon: nil)
        appearanceControl.menu = UIMenu(children: AppAppearance.allCases.map { choice in UIAction(title: choice.title, state: choice == settings.appearance ? .on : .off) { [weak self] _ in self?.model.store.send(.settings(.appearanceChanged(choice))) } })
        activitySwitch.isOn = model.store.settings.liveActivityEnabled
        relayURL.isEnabled = cloud
        if !relayURL.isFirstResponder, relayURL.text != model.store.settings.relayURL { relayURL.text = model.store.settings.relayURL }
        var current = [PhoneRow(id: "currentMode", title: "Current Mode", detail: model.connectionModePresentation.title), PhoneRow(id: "connectionStatus", title: "Connection Status", detail: model.connectionModePresentation.status), PhoneRow(id: "vowlan", title: "VoWLAN", detail: VoWLANStatusCopy.text(for: model.vowlan.availability)), PhoneRow(id: "cloud", title: "Cloud Relay", detail: cloud ? (model.cloudAgentStatus?.cloudOnline == true ? "Agent Online" : "Unreachable") : "Disabled in current mode"), PhoneRow(id: "detail", title: model.connectionModePresentation.detail, color: .secondaryLabel, textStyle: .footnote)]
        if let connectionMessage = model.connectionMessage, !connectionMessage.isEmpty { current.append(PhoneRow(id: "connectionMessage", title: connectionMessage, color: .secondaryLabel, textStyle: .footnote)) }
        var devices = [PhoneRow(id: "vowlan", title: "VoWLAN", detail: VoWLANStatusCopy.text(for: model.vowlan.availability)), PhoneRow(id: "pair", title: "Pair Android Phone", image: "personalhotspot", disclosure: true, action: { [weak self] in guard let self else { return }; self.navigationController?.pushViewController(SamsungPairingViewController(model: self.model), animated: true) }), PhoneRow(id: "pairedTitle", title: "Paired Devices")]
        if model.pairedDeviceHistory.isEmpty { devices.append(PhoneRow(id: "empty", title: "No paired devices")) }
        devices += model.pairedDeviceHistory.map { device in
            let routes = [device.vowlanOnline ? "VoWLAN Online" : nil, device.cloudOnline ? "Cloud Online" : nil].compactMap { $0 }
            return PhoneRow(id: device.id, title: device.deviceName, detail: "\(device.phoneNumber ?? "Number unavailable")\n\(routes.isEmpty ? "Offline · Refreshes on reconnection" : routes.joined(separator: " · "))", image: "smartphone", enabled: !deviceDeletionInProgress, action: { [weak self] in self?.delete(device) }, accessibilityHint: "Delete \(device.deviceName) pairing record")
        }
        devices.append(PhoneRow(id: "discover", title: "Discover Again", image: "arrow.clockwise", color: .systemBlue, action: { [weak self] in guard let self else { return }; self.model.store.send(.command(.discover)) }))
        var relayRows = [PhoneRow(id: "enabled", title: "Remote Calls and Messages", detail: cloud ? "Enabled" : "Disabled"), PhoneRow(id: "url", title: "", accessory: relayURL), PhoneRow(id: "save", title: "Save Relay URL", color: .systemBlue, enabled: cloud, action: { [weak self] in self?.saveRelay() })]
        if let message { relayRows.append(PhoneRow(id: "message", title: message)) }
        var testRows = [PhoneRow(id: "run", title: selfTestRunning ? "Run Cloud Self-Test · Running…" : "Run Cloud Self-Test", image: "stethoscope", color: .systemBlue, enabled: cloud && !selfTestRunning, action: { [weak self] in self?.runTest() })]
        if let report = selfTestReport {
            testRows += report.steps.map { step in
                let icon: String; let color: UIColor
                switch step.state { case .pending: icon = "circle"; color = .secondaryLabel; case .running: icon = "arrow.triangle.2.circlepath"; color = .systemBlue; case .passed: icon = "checkmark.circle.fill"; color = .systemGreen; case .failed: icon = "xmark.circle.fill"; color = .systemRed }
                return PhoneRow(id: String(describing: step.id), title: step.title, detail: step.detail, image: icon, color: color)
            }
            if selfTestCompleted { testRows.append(PhoneRow(id: "result", title: report.allPassed ? "Cloud self-test passed" : "Self-test failed. Resolve the failed steps and try again.", color: report.allPassed ? .systemGreen : .systemOrange)) }
        }
        var content = [
            PhoneSection(title: "Connection Mode", footer: String(localized: mode.detail), rows: [PhoneRow(id: "mode", title: "Connection Mode", accessory: modeControl, accessoryInline: true)]),
            PhoneSection(title: "Current Connection", rows: current),
            PhoneSection(title: "Android Connection", footer: "Current information is refreshed on reconnection. Offline records do not store phone numbers.", rows: devices),
            PhoneSection(title: "Dynamic Island and Live Activities", footer: "Turning this off ends AirSIM Dynamic Island and Lock Screen Live Activities. Calls and messages remain available.", rows: [PhoneRow(id: "activity", title: "Show Dynamic Island", image: "platter.filled.top.iphone", accessory: activitySwitch, accessoryInline: true)]),
            PhoneSection(title: "Cloud Relay", footer: "Local VoWLAN remains available when cloud mode is off. Remote calls and messages require a cloud Relay and valid device registration.", rows: relayRows),
            PhoneSection(title: "Cloud Self-Test", footer: cloud ? "Checks local push credentials, AirSIM Relay identity, device registration, and an Agent heartbeat within the last 90 seconds. No calls or messages are sent." : "Cloud self-test is unavailable in the current connection mode.", rows: testRows),
            PhoneSection(title: "About", rows: [PhoneRow(id: "project", title: "Project", detail: "AirSIM · Samsung"), PhoneRow(id: "appearance", title: "Appearance", accessory: appearanceControl, accessoryInline: true)])
        ]
        for section in content.indices {
            for row in content[section].rows.indices {
                if ["currentMode", "connectionStatus", "vowlan", "cloud", "enabled", "project"].contains(content[section].rows[row].id) { content[section].rows[row].isValue = true }
            }
        }
        setSections(content)
    }
    private func delete(_ device: AndroidAgentPresentation) {
        confirmPhoneAction("Delete this device's local pairing record?", message: "Clears this device's local record, binding, and cache. Calls, messages, and other devices are unaffected. Pair again to enable automatic connection. Remote credentials on an offline device are not automatically revoked.", actionTitle: "Delete \(device.deviceName)") { [weak self] in self?.model.store.send(.settings(.forgetDevice(device.id))) }
    }
    private func saveRelay() { model.store.send(.settings(.saveRelay)) }
    private func runTest() { model.store.send(.settings(.runSelfTest)) }
}

#if DEBUG
#Preview("Settings · Connected and Self-Test") {
    let model = AirSIMPreviewFixtures.presentation(tab: .settings)
    return AirSIMPreviewFixtures.navigation(AirSIMSettingsViewController(model: model, settings: model.settings))
}
#endif
