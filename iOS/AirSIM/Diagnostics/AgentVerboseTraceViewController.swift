import UIKit

@MainActor
final class AgentVerboseTraceViewController: PhoneTableController {
    let model: AirSIMPresentation
    private var trace: AgentVerboseTraceData { model.store.trace.data }
    private var filter: AgentVerboseTraceFilter { model.store.trace.filter }
    private let enabled = UISwitch()
    private var filterControl: UISegmentedControl!
    init(model: AirSIMPresentation) { self.model = model; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() {
        super.viewDidLoad(); title = "Agent Verbose"; navigationItem.largeTitleDisplayMode = .never
        enabled.accessibilityLabel = "Verbose Trace Mode"; enabled.addAction(UIAction { [weak self] _ in guard let self else { return }; self.model.store.send(.trace(.enabledChanged(self.enabled.isOn))) }, for: .valueChanged)
        filterControl = UISegmentedControl(items: AgentVerboseTraceFilter.allCases.map { String(localized: $0.title) }); filterControl.selectedSegmentIndex = 0; filterControl.accessibilityLabel = "Filter"
        filterControl.addAction(UIAction { [weak self] _ in guard let self else { return }; self.model.store.send(.trace(.filterChanged(AgentVerboseTraceFilter.allCases[self.filterControl.selectedSegmentIndex]))) }, for: .valueChanged)
        navigationItem.rightBarButtonItems = [UIBarButtonItem(image: UIImage(systemName: "trash"), primaryAction: UIAction { [weak self] _ in self?.confirmPhoneAction("Clear App and Agent Debug Logs?", actionTitle: "Clear All") { [weak self] in self?.model.store.send(.trace(.clear)) } }), UIBarButtonItem(image: UIImage(systemName: "square.and.arrow.up"), primaryAction: UIAction { [weak self] _ in self?.share() })]
        enableRefresh { [weak self] in await self?.model.store.send(.trace(.refresh)).finish() }
    }
    override func viewWillAppear(_ animated: Bool) { super.viewWillAppear(animated); model.store.send(.trace(.appeared)) }
    override func viewWillDisappear(_ animated: Bool) { super.viewWillDisappear(animated); model.store.send(.trace(.disappeared)) }
    override func render() {
        enabled.isOn = trace.enabled
        let items = trace.timeline.filter { item in
            switch filter { case .all: return true; case .failures: return item.isFailure; case .calls: return ["voice", "cloud-call", "cloud-call-control"].contains(item.category.lowercased()); case .relay: return item.source == "RELAY" || item.category.lowercased() == "relay"; case .at: return item.category.lowercased() == "at"; case .usb: return item.category.lowercased() == "usb" }
        }
        let rows = items.map { item in PhoneRow(id: item.id, title: item.title, detail: "\(item.source) · \(Self.timeFormatter.string(from: item.timestamp))\(item.traceID.map { " · #\($0)" } ?? "")\n\(item.detail)", image: item.systemImage, color: item.tint, action: { [weak self] in self?.showPhoneSheet(AgentVerboseTraceDetailViewController(item: item)) }, context: { UIMenu(children: [UIAction(title: "Copy Entry", image: UIImage(systemName: "doc.on.doc")) { _ in UIPasteboard.general.string = "\(item.title)\n\(item.detail)" }]) }, bodyViewProvider: { Self.timelineView(item) }) }
        setSections([
            PhoneSection(title: "Request Tracing", footer: "Logs may include phone numbers, message text, AT responses, and device identifiers. Turn off Verbose mode after troubleshooting and review logs before sharing.", rows: [PhoneRow(id: "enabled", title: "Verbose Trace Mode", detail: trace.enabled ? "Capturing app, USB, HTTP, AT, and Agent events" : "New app requests are not recorded while off", image: "point.3.connected.trianglepath.dotted", accessory: enabled, accessoryInline: true), PhoneRow(id: "agent", title: "Agent Connection", detail: trace.agentState, isValue: true), PhoneRow(id: "local", title: "Local Trace", detail: "\(trace.localEntries.count) entries", isValue: true), PhoneRow(id: "events", title: "Agent Events", detail: "\(trace.agentEvents.count) entries", isValue: true)]),
            PhoneSection(rows: [PhoneRow(id: "filter", title: "", accessory: filterControl)]),
            PhoneSection(rows: trace.errorMessage.map { [PhoneRow(id: "error", title: $0, image: "exclamationmark.triangle.fill", color: .systemOrange)] } ?? []),
            PhoneSection(title: "Live Request Trace", rows: rows.isEmpty ? [PhoneRow(id: "empty", title: "No Trace Events", detail: trace.enabled ? "Events appear as you make calls, send messages, change settings, or send AT commands." : "Enable Verbose Trace Mode first.", image: "waveform.path.ecg")] : rows)
        ])
    }
    private static func timelineView(_ item: AgentVerboseTimelineItem) -> UIView {
        let icon = UIImageView(image: UIImage(systemName: item.systemImage)); icon.tintColor = item.tint; icon.contentMode = .center; icon.backgroundColor = item.tint.withAlphaComponent(0.12); icon.layer.cornerRadius = 14; icon.widthAnchor.constraint(equalToConstant: 28).isActive = true; icon.heightAnchor.constraint(equalToConstant: 28).isActive = true
        let source = phoneLabel(item.source, size: 10, color: item.source == "APP" ? .systemBlue : .systemPurple); source.font = .systemFont(ofSize: 10, weight: .bold)
        let timestamp = phoneLabel(Self.timeFormatter.string(from: item.timestamp), size: 10, color: .secondaryLabel); timestamp.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        let metadata = UIStackView(arrangedSubviews: [source, timestamp]); metadata.axis = .horizontal; metadata.spacing = 6
        if let traceID = item.traceID { let trace = phoneLabel("#\(traceID)", size: 10, color: .secondaryLabel); trace.font = .monospacedSystemFont(ofSize: 10, weight: .regular); metadata.addArrangedSubview(trace) }; metadata.addArrangedSubview(UIView())
        let title = phoneLabel(item.title, size: 15, color: item.isFailure ? .systemRed : .label); title.font = .systemFont(ofSize: 15, weight: .semibold); title.numberOfLines = 2
        let text = UIStackView(arrangedSubviews: [metadata, title]); text.axis = .vertical; text.spacing = 5
        if !item.detail.isEmpty { let detail = phoneLabel(item.detail, size: 12, color: .secondaryLabel); detail.font = .monospacedSystemFont(ofSize: 12, weight: .regular); detail.numberOfLines = 3; text.addArrangedSubview(detail) }
        let row = UIStackView(arrangedSubviews: [icon, text]); row.axis = .horizontal; row.spacing = 12; row.alignment = .top; return row
    }
    private static let timeFormatter: DateFormatter = { let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "HH:mm:ss.SSS"; return f }()
    private func share() { let sheet = UIActivityViewController(activityItems: [trace.exportText], applicationActivities: nil); sheet.popoverPresentationController?.barButtonItem = navigationItem.rightBarButtonItems?.last; present(sheet, animated: true) }
}

#if DEBUG
#Preview("Agent Verbose · Timeline") {
    let model = AirSIMPreviewFixtures.presentation(tab: .settings)
    return AirSIMPreviewFixtures.navigation(AgentVerboseTraceViewController(model: model))
}
#endif
