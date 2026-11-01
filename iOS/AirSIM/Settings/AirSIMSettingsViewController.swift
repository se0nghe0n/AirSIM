import ComposableArchitecture
import UIKit

/// The Settings tab: connection mode and status, Android pairing, Live Activities, the cloud Relay and its
/// self-test, and appearance.
@MainActor
@ViewAction(for: SettingsFeature.self)
final class AirSIMSettingsViewController: PhoneTableController {
    // MARK: Store

    let store: StoreOf<SettingsFeature>

    // MARK: Views

    /// Built in viewDidLoad, so their symbol images resolve with the screen's traits.
    private lazy var modeControl = MenuValueButton()
    private lazy var appearanceControl = MenuValueButton()
    private let activitySwitch = UISwitch()
    private let relayURL = UITextField()

    // MARK: Lifecycle

    init(store: StoreOf<SettingsFeature>) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Settings"
        buildControls()
        buildRelayField()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        send(.appeared)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        send(.disappeared)
    }

    // MARK: Rendering

    override func render() {
        renderControls()
        setSections([
            modeSection(),
            currentConnectionSection(),
            androidConnectionSection(),
            liveActivitySection(),
            relaySection(),
            selfTestSection(),
            aboutSection(),
        ])
    }

    private func renderControls() {
        modeControl.update(title: store.modeTitle, icon: store.modeIcon)
        modeControl.menu = UIMenu(children: AirSIMConnectionMode.allCases.map(modeChoice))
        appearanceControl.update(title: store.appearance.title, icon: nil)
        appearanceControl.menu = UIMenu(children: AppAppearance.allCases.map(appearanceChoice))
        activitySwitch.isOn = store.liveActivityEnabled
        relayURL.isEnabled = store.modeUsesCloud
        if !relayURL.isFirstResponder, relayURL.text != store.relayURL {
            relayURL.text = store.relayURL
        }
    }

    // MARK: Rows

    private func modeSection() -> PhoneSection {
        PhoneSection(title: "Connection Mode", footer: store.modeDetail, rows: [
            PhoneRow(
                id: "mode",
                title: "Connection Mode",
                accessory: modeControl,
                accessoryInline: true
            ),
        ])
    }

    private func currentConnectionSection() -> PhoneSection {
        var rows = [
            valueRow(id: "currentMode", title: "Current Mode", detail: store.connection.title),
            valueRow(id: "connectionStatus", title: "Connection Status", detail: store.connection.status),
            valueRow(id: "vowlan", title: "VoWLAN", detail: store.vowlanStatus),
            valueRow(id: "cloud", title: "Cloud Relay", detail: store.cloudRelayStatus),
            footnoteRow(id: "detail", title: store.connection.detail),
        ]
        if let message = store.connectionMessage {
            rows.append(footnoteRow(id: "connectionMessage", title: message))
        }
        return PhoneSection(title: "Current Connection", rows: rows)
    }

    private func androidConnectionSection() -> PhoneSection {
        let devices = store.devices
        var rows = [
            valueRow(id: "vowlan", title: "VoWLAN", detail: store.vowlanStatus),
            PhoneRow(
                id: "pair",
                title: "Pair Android Phone",
                image: "personalhotspot",
                disclosure: true,
                action: { [weak self] in self?.showPairing() }
            ),
            PhoneRow(
                id: "pairedTitle",
                title: "Paired Devices"
            ),
        ]
        if devices.isEmpty {
            rows.append(
                PhoneRow(
                    id: "empty",
                    title: "No paired devices"
                )
            )
        }
        rows += devices.map(deviceRow)
        rows.append(
            PhoneRow(
                id: "discover",
                title: "Discover Again",
                image: "arrow.clockwise",
                color: .systemBlue,
                action: { [weak self] in self?.send(.discoverTapped) }
            )
        )
        return PhoneSection(
            title: "Android Connection",
            footer: "Current information is refreshed on reconnection. Offline records do not store phone numbers.",
            rows: rows
        )
    }

    private func deviceRow(_ device: PairedDeviceRow) -> PhoneRow {
        PhoneRow(
            id: device.id,
            title: device.name,
            detail: device.detail,
            image: "smartphone",
            enabled: !store.deletingDevice,
            action: { [weak self] in self?.confirmForget(device) },
            accessibilityHint: "Delete \(device.name) pairing record"
        )
    }

    private func liveActivitySection() -> PhoneSection {
        PhoneSection(
            title: "Dynamic Island and Live Activities",
            footer: "Turning this off ends AirSIM Dynamic Island and Lock Screen Live Activities. Calls and messages remain available.",
            rows: [
                PhoneRow(
                    id: "activity",
                    title: "Show Dynamic Island",
                    image: "platter.filled.top.iphone",
                    accessory: activitySwitch,
                    accessoryInline: true
                ),
            ]
        )
    }

    private func relaySection() -> PhoneSection {
        var rows = [
            valueRow(id: "enabled", title: "Remote Calls and Messages", detail: store.remoteCallsStatus),
            PhoneRow(
                id: "url",
                title: "",
                accessory: relayURL
            ),
            PhoneRow(
                id: "save",
                title: "Save Relay URL",
                color: .systemBlue,
                enabled: store.modeUsesCloud,
                action: { [weak self] in self?.send(.saveRelayTapped) }
            ),
        ]
        if let message = store.message {
            rows.append(
                PhoneRow(
                    id: "message",
                    title: message
                )
            )
        }
        return PhoneSection(
            title: "Cloud Relay",
            footer: "Local VoWLAN remains available when cloud mode is off. Remote calls and messages require a cloud Relay and valid device registration.",
            rows: rows
        )
    }

    private func selfTestSection() -> PhoneSection {
        var rows = [
            PhoneRow(
                id: "run",
                title: store.selfTestTitle,
                image: "stethoscope",
                color: .systemBlue,
                enabled: store.canRunSelfTest,
                action: { [weak self] in self?.send(.runSelfTestTapped) }
            ),
        ]
        rows += store.selfTestSteps.map(selfTestStepRow)
        if let result = store.selfTestResult {
            rows.append(
                PhoneRow(
                    id: "result",
                    title: result.text,
                    color: result.tone.color
                )
            )
        }
        return PhoneSection(title: "Cloud Self-Test", footer: store.selfTestFooter, rows: rows)
    }

    private func selfTestStepRow(_ step: SelfTestStepRow) -> PhoneRow {
        PhoneRow(
            id: step.id,
            title: step.title,
            detail: step.detail,
            image: step.icon,
            color: step.tone.color
        )
    }

    private func aboutSection() -> PhoneSection {
        PhoneSection(title: "About", rows: [
            valueRow(id: "project", title: "Project", detail: "AirSIM · Samsung"),
            PhoneRow(
                id: "appearance",
                title: "Appearance",
                accessory: appearanceControl,
                accessoryInline: true
            ),
        ])
    }

    /// A title with its value on the trailing side.
    private func valueRow(id: String, title: String, detail: String) -> PhoneRow {
        PhoneRow(
            id: id,
            title: title,
            detail: detail,
            isValue: true
        )
    }

    private func footnoteRow(id: String, title: String) -> PhoneRow {
        PhoneRow(
            id: id,
            title: title,
            color: .secondaryLabel,
            textStyle: .footnote
        )
    }

    // MARK: Layout

    private func buildControls() {
        modeControl.showsMenuAsPrimaryAction = true
        appearanceControl.showsMenuAsPrimaryAction = true
        activitySwitch.accessibilityLabel = "Show Dynamic Island"
        activitySwitch.addAction(UIAction { [weak self] _ in self?.activitySwitchChanged() }, for: .valueChanged)
    }

    private func buildRelayField() {
        relayURL.addAction(UIAction { [weak self] _ in self?.relayURLEdited() }, for: .editingChanged)
        relayURL.placeholder = "https://relay.example.com"
        relayURL.keyboardType = .URL
        relayURL.autocapitalizationType = .none
        relayURL.autocorrectionType = .no
        relayURL.borderStyle = .roundedRect
        relayURL.frame.size = CGSize(width: 250, height: 44)
        relayURL.accessibilityLabel = "Cloud Relay URL"
    }

    // MARK: Navigation

    private func showPairing() {
        let pairing = SamsungPairingViewController(store: store.scope(state: \.pairing, action: \.pairing))
        navigationController?.pushViewController(pairing, animated: true)
    }

    private func confirmForget(_ device: PairedDeviceRow) {
        confirmPhoneAction(
            "Delete this device's local pairing record?",
            message: "Clears this device's local record, binding, and cache. Calls, messages, and other devices are unaffected. Pair again to enable automatic connection. Remote credentials on an offline device are not automatically revoked.",
            actionTitle: "Delete \(device.name)"
        ) { [weak self] in
            self?.send(.forgetDeviceConfirmed(device.id))
        }
    }

    // MARK: Actions

    private func modeChoice(_ mode: AirSIMConnectionMode) -> UIAction {
        UIAction(title: String(localized: mode.title), state: mode == store.mode ? .on : .off) { [weak self] _ in
            self?.send(.modeChanged(mode))
        }
    }

    private func appearanceChoice(_ appearance: AppAppearance) -> UIAction {
        UIAction(title: appearance.title, state: appearance == store.appearance ? .on : .off) { [weak self] _ in
            self?.send(.appearanceChanged(appearance))
        }
    }

    private func activitySwitchChanged() {
        send(.liveActivityChanged(activitySwitch.isOn))
    }

    private func relayURLEdited() {
        send(.relayChanged(relayURL.text ?? ""))
    }
}

private extension SettingsTone {
    var color: UIColor {
        switch self {
        case .secondary:
            .secondaryLabel
        case .blue:
            .systemBlue
        case .green:
            .systemGreen
        case .orange:
            .systemOrange
        case .red:
            .systemRed
        }
    }
}

#if DEBUG
#Preview("Settings · Connected and Self-Test") {
    let store = AirSIMPreviewFixtures.store(tab: .settings)
    return AirSIMPreviewFixtures.navigation(
        AirSIMSettingsViewController(store: store.scope(state: \.settings, action: \.settings))
    )
}
#endif
