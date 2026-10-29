import UIKit
import Observation

@MainActor
final class SamsungPairingViewController: PhoneTableController {
    let model: AirSIMPresentation
    var onDismiss: (() -> Void)?
    private let localSwitch = UISwitch()
    private var fields: [String: UITextField] = [:]
    private var pairingServiceID: String? { model.store.pairing.pairingID }
    private var message: String { model.store.pairing.message }
    init(model: AirSIMPresentation) { self.model = model; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() {
        super.viewDidLoad(); title = "Pair Android Phone"; navigationItem.largeTitleDisplayMode = .never
        localSwitch.isOn = model.store.pairing.localOnly; localSwitch.accessibilityIdentifier = "localPairingOnly"; localSwitch.accessibilityLabel = "Local-Only Pairing"
        localSwitch.addAction(UIAction { [weak self] _ in guard let self else { return }; self.model.store.send(.pairing(.localChanged(self.localSwitch.isOn))) }, for: .valueChanged)

    }
    override func viewWillAppear(_ animated: Bool) { super.viewWillAppear(animated); model.store.send(.pairing(.appeared)) }
    override func viewDidDisappear(_ animated: Bool) { super.viewDidDisappear(animated); model.store.send(.pairing(.disappeared)); onDismiss?() }
    override func render() {
        localSwitch.isOn = model.store.pairing.localOnly
        for field in fields.values where field.text != model.store.pairing.code { field.text = model.store.pairing.code }
        localSwitch.isEnabled = pairingServiceID == nil
        var rows: [PhoneRow] = []
        if model.store.pairing.services.isEmpty {
            let spinner = UIActivityIndicatorView(style: .medium); spinner.startAnimating()
            let row = UIStackView(arrangedSubviews: [spinner, phoneLabel(model.store.pairing.status, color: .secondaryLabel)]); row.axis = .horizontal; row.spacing = 10
            rows.append(PhoneRow(id: "searching", title: "", bodyView: row))
        }
        for service in model.store.pairing.services {
            let field: UITextField
            if let existing = fields[service.id] { field = existing }
            else {
                field = UITextField(); field.placeholder = "Six-digit code shown on Android"; field.keyboardType = .numberPad; field.textContentType = .oneTimeCode
                field.addAction(UIAction { [weak self, weak field] _ in self?.model.store.send(.pairing(.codeChanged(field?.text ?? ""))) }, for: .editingChanged)
                fields[service.id] = field
            }
            field.text = model.store.pairing.code
            rows.append(PhoneRow(id: service.id + "name", title: service.displayName, image: "iphone.radiowaves.left.and.right"))
            rows.append(PhoneRow(id: service.id + "code", title: "", accessory: field))
            rows.append(PhoneRow(id: service.id + "pair", title: "Pair Securely", image: "lock.shield", color: .systemBlue, enabled: model.store.pairing.code.count == 6 && pairingServiceID == nil, action: { [weak self] in self?.model.store.send(.pairing(.pair(service))) }))
        }
        setSections([
            PhoneSection(rows: [PhoneRow(id: "local", title: "Local-Only Pairing", image: "wifi", accessory: localSwitch, accessoryInline: true), PhoneRow(id: "localDetail", title: localSwitch.isOn ? "This pairing saves only the VoWLAN key, without checking or saving Relay and push settings. Your connection mode stays unchanged." : "This pairing saves the VoWLAN key and Relay/push configuration. Cloud credentials must be ready. Your connection mode stays unchanged.", color: .secondaryLabel, textStyle: .footnote)]),
            PhoneSection(title: "Connection Steps", rows: [PhoneRow(id: "wifi", title: "Connect both devices to the same Wi-Fi", image: "wifi"), PhoneRow(id: "hotspot", title: "Or connect this device to the Android hotspot", image: "personalhotspot"), PhoneRow(id: "start", title: "Tap Start One-Time Pairing in the Android app", image: "key")]),
            PhoneSection(title: "Discovered Devices", rows: rows),
            PhoneSection(title: message.isEmpty ? "" : "Result", rows: message.isEmpty ? [] : [PhoneRow(id: "result", title: message)])
        ])
    }
}

#if DEBUG
#Preview("Pair Android Phone · Discovered") {
    AirSIMPreviewFixtures.navigation(SamsungPairingViewController(model: AirSIMPreviewFixtures.presentation(tab: .settings)))
}

#Preview("Pair Android Phone · Searching") {
    AirSIMPreviewFixtures.navigation(SamsungPairingViewController(model: AirSIMPreviewFixtures.presentation(tab: .settings, empty: true)))
}
#endif
