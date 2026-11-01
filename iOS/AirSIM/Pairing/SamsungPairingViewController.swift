import ComposableArchitecture
import UIKit

/// Pairs with an Android phone on the local network: the local-only choice, connection steps, each discovered phone
/// with its code field, and the result.
@MainActor
@ViewAction(for: PairingFeature.self)
final class SamsungPairingViewController: PhoneTableController {
    // MARK: Store

    let store: StoreOf<PairingFeature>

    // MARK: Views

    private let localSwitch = UISwitch()
    /// One code field per discovered phone, kept across renders so typing keeps its focus.
    private var codeFields: [String: UITextField] = [:]

    // MARK: Lifecycle

    init(store: StoreOf<PairingFeature>) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Pair Android Phone"
        navigationItem.largeTitleDisplayMode = .never
        send(.opened)
        buildLocalSwitch()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        send(.appeared)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        send(.disappeared)
    }

    // MARK: Rendering

    override func render() {
        localSwitch.isOn = store.localOnly
        localSwitch.isEnabled = store.canChangeLocalOnly
        setSections([
            localOnlySection(),
            stepsSection(),
            discoveredSection(),
            resultSection(),
        ])
    }

    // MARK: Rows

    private func localOnlySection() -> PhoneSection {
        PhoneSection(rows: [
            PhoneRow(
                id: "local",
                title: "Local-Only Pairing",
                image: "wifi",
                accessory: localSwitch,
                accessoryInline: true
            ),
            PhoneRow(
                id: "localDetail",
                title: store.localOnlyDetail,
                color: .secondaryLabel,
                textStyle: .footnote
            ),
        ])
    }

    private func stepsSection() -> PhoneSection {
        PhoneSection(title: "Connection Steps", rows: [
            PhoneRow(
                id: "wifi",
                title: "Connect both devices to the same Wi-Fi",
                image: "wifi"
            ),
            PhoneRow(
                id: "hotspot",
                title: "Or connect this device to the Android hotspot",
                image: "personalhotspot"
            ),
            PhoneRow(
                id: "start",
                title: "Tap Start One-Time Pairing in the Android app",
                image: "key"
            ),
        ])
    }

    private func discoveredSection() -> PhoneSection {
        let services = store.services
        let rows = services.isEmpty ? [searchingRow()] : services.flatMap(serviceRows)
        return PhoneSection(title: "Discovered Devices", rows: rows)
    }

    private func searchingRow() -> PhoneRow {
        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.startAnimating()
        let status = phoneLabel(store.status, color: .secondaryLabel)
        return PhoneRow(
            id: "searching",
            title: "",
            bodyView: UIStackView([spinner, status], axis: .horizontal, spacing: 10)
        )
    }

    private func serviceRows(_ service: SamsungPairingService) -> [PhoneRow] {
        [
            PhoneRow(
                id: service.id + "name",
                title: service.displayName,
                image: "iphone.radiowaves.left.and.right"
            ),
            PhoneRow(
                id: service.id + "code",
                title: "",
                accessory: codeField(for: service)
            ),
            PhoneRow(
                id: service.id + "pair",
                title: "Pair Securely",
                image: "lock.shield",
                color: .systemBlue,
                enabled: store.canPair,
                action: { [weak self] in self?.send(.pairTapped(service)) }
            ),
        ]
    }

    private func resultSection() -> PhoneSection {
        guard let message = store.resultMessage else { return PhoneSection(rows: []) }
        return PhoneSection(title: "Result", rows: [
            PhoneRow(
                id: "result",
                title: message
            ),
        ])
    }

    // MARK: Layout

    private func buildLocalSwitch() {
        localSwitch.accessibilityIdentifier = "localPairingOnly"
        localSwitch.accessibilityLabel = "Local-Only Pairing"
        localSwitch.addAction(UIAction { [weak self] _ in self?.localSwitchChanged() }, for: .valueChanged)
    }

    private func codeField(for service: SamsungPairingService) -> UITextField {
        let field = codeFields[service.id] ?? makeCodeField()
        codeFields[service.id] = field
        field.text = store.code
        return field
    }

    private func makeCodeField() -> UITextField {
        let field = UITextField()
        field.placeholder = "Six-digit code shown on Android"
        field.keyboardType = .numberPad
        field.textContentType = .oneTimeCode
        field.addAction(
            UIAction { [weak self, weak field] _ in self?.send(.codeChanged(field?.text ?? "")) },
            for: .editingChanged
        )
        return field
    }

    // MARK: Actions

    private func localSwitchChanged() {
        send(.localOnlyChanged(localSwitch.isOn))
    }
}

#if DEBUG
#Preview("Pair Android Phone · Discovered") {
    let store = AirSIMPreviewFixtures.presentation(tab: .settings).store
    let pairing = store.scope(state: \.settings.pairing, action: \.settings.pairing)
    let controller = SamsungPairingViewController(store: pairing)
    controller.loadViewIfNeeded()
    store.send(.settings(.pairing(.view(.codeChanged("123456")))))
    return AirSIMPreviewFixtures.navigation(controller)
}

#Preview("Pair Android Phone · Searching") {
    let store = AirSIMPreviewFixtures.presentation(tab: .settings, empty: true).store
    return AirSIMPreviewFixtures.navigation(
        SamsungPairingViewController(store: store.scope(state: \.settings.pairing, action: \.settings.pairing))
    )
}
#endif
