import UIKit

enum AgentVerboseTraceFilter: String, CaseIterable {
    case all = "All"
    case failures = "Errors"
    case calls = "Calls"
    case relay = "Relay"
    case at = "AT"
    case usb = "USB"

    /// localization.md: filter labels are user-visible copy and use LocalizedStringResource for deferred resolution.
    var title: LocalizedStringResource {
        switch self {
        case .all: return "All"
        case .failures: return "Errors"
        case .calls: return "Calls"
        case .relay: return "Relay"
        case .at: return "AT"
        case .usb: return "USB"
        }
    }
}

struct AgentVerboseTimelineItem: Identifiable, Equatable, Sendable {
    let id: String
    let timestamp: Date
    let source: String
    let category: String
    let traceID: String?
    let title: String
    let detail: String
    let isFailure: Bool

    var systemImage: String {
        if isFailure { return "exclamationmark.triangle.fill" }
        switch category.lowercased() {
        case "at": return "terminal.fill"
        case "usb": return "cable.connector"
        case "http": return "arrow.left.arrow.right"
        case "voice", "cloud-call", "cloud-call-control": return "waveform"
        case "relay": return "network"
        default: return source == "APP" ? "iphone" : "cpu"
        }
    }

    var tint: UIColor {
        if isFailure { return .red }
        switch category.lowercased() {
        case "at": return .green
        case "usb": return .cyan
        case "voice", "cloud-call", "cloud-call-control": return .purple
        case "relay": return .systemIndigo
        case "http": return .blue
        default: return .secondaryLabel
        }
    }
}

struct AgentVerboseTraceData: Equatable, Sendable {
    var enabled = false
    var localEntries: [AgentVerboseTraceEntry] = []
    var agentEvents: [ModuleDebugEvent] = []
    var agentState = "Not Connected"
    var errorMessage: String?
    var exportText = "AirSIM Agent Verbose Trace\n"
    // foreach.md: timeline is a derived collection rebuilt only when localEntries/agentEvents change,
    // rather than remapping and sorting on every view read (up to 2,000 entries).
    private(set) var timeline: [AgentVerboseTimelineItem] = []

    private var lastSequence: UInt64 = 0

    mutating func refresh(api: AirSIMAPI) async {
        localEntries = await AgentVerboseTraceRecorder.shared.snapshot()
        if enabled {
            do {
                let snapshot = try await api.moduleDebug(after: lastSequence, limit: 600)
                merge(snapshot.events)
                lastSequence = max(lastSequence, snapshot.debug.latestSequence)
                agentState = "Agent \(snapshot.agent.version) · seq \(snapshot.debug.latestSequence)"
                errorMessage = nil
            } catch is CancellationError {
                return
            } catch {
                agentState = "Agent Unreachable"
                errorMessage = error.localizedDescription
            }
        }
        rebuildTimeline()
        await rebuildExport()
    }

    private mutating func rebuildTimeline() {
        let local = localEntries.map { entry in
            let fields = (entry.fields ?? [:])
                .filter { $0.key != "trace_id" }
                .sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: " · ")
            let detail = [fields, entry.detail]
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            return AgentVerboseTimelineItem(
                id: "app-\(entry.id.uuidString)",
                timestamp: entry.timestamp,
                source: entry.source ?? "APP",
                category: entry.category ?? (entry.stage == .route ? "usb" : "http"),
                traceID: entry.traceID == "--------" ? nil : entry.traceID,
                title: "\(entry.method) \(entry.path)",
                detail: entry.elapsedMilliseconds.map { "\(detail) · \($0) ms" } ?? detail,
                isFailure: entry.stage == .failure
            )
        }
        let remote = agentEvents.compactMap { event -> AgentVerboseTimelineItem? in
            if event.category == "http", event.summary.hasPrefix("GET /api/debug") { return nil }
            let fields = event.fields ?? [:]
            let fieldText = fields
                .filter { $0.key != "trace_id" }
                .sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: " · ")
            let parts = [event.direction, fieldText, event.payload]
                .compactMap { value -> String? in
                    guard let value, !value.isEmpty else { return nil }
                    return value
                }
            let statusFailure = Int(fields["status"] ?? "").map { $0 >= 400 } ?? false
            return AgentVerboseTimelineItem(
                id: "agent-\(event.sequence)",
                timestamp: Self.parse(event.timestamp),
                source: "AGENT",
                category: event.category,
                traceID: fields["trace_id"],
                title: event.summary,
                detail: parts.joined(separator: "\n"),
                isFailure: event.direction == "error" || statusFailure
            )
        }
        timeline = (local + remote).sorted {
            if $0.timestamp == $1.timestamp { return $0.id < $1.id }
            return $0.timestamp < $1.timestamp
        }
    }

    mutating func clear(api: AirSIMAPI) async {
        await AgentVerboseTraceRecorder.shared.clear()
        localEntries = []
        agentEvents = []
        lastSequence = 0
        rebuildTimeline()
        do {
            try await api.clearModuleDebug()
            agentState = "Agent Logs Cleared"
            errorMessage = nil
        } catch {
            errorMessage = "Local logs cleared; failed to clear Agent logs: \(error.localizedDescription)"
        }
        await refresh(api: api)
    }

    private mutating func merge(_ newEvents: [ModuleDebugEvent]) {
        let known = Set(agentEvents.map(\.sequence))
        agentEvents.append(contentsOf: newEvents.filter { !known.contains($0.sequence) })
        if agentEvents.count > 2_000 { agentEvents.removeFirst(agentEvents.count - 2_000) }
    }

    private mutating func rebuildExport() async {
        let remote = agentEvents.map {
            AgentVerboseRemoteEvent(
                sequence: $0.sequence,
                timestamp: $0.timestamp,
                category: $0.category,
                direction: $0.direction ?? "",
                summary: $0.summary,
                payload: $0.payload ?? "",
                fields: $0.fields ?? [:]
            )
        }
        exportText = await AgentVerboseTraceRecorder.shared.exportText(agentEvents: remote)
    }

    private static func parse(_ value: String) -> Date {
        if let date = fractionalFormatter.date(from: value) { return date }
        return wholeFormatter.date(from: value) ?? .distantPast
    }

    private static let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let wholeFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}


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

@MainActor
private final class AgentVerboseTraceDetailViewController: PhoneTableController {
    let item: AgentVerboseTimelineItem
    init(item: AgentVerboseTimelineItem) { self.item = item; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() {
        super.viewDidLoad(); title = "Trace Details"; navigationItem.largeTitleDisplayMode = .never
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: "Copy", primaryAction: UIAction { [weak self] _ in guard let self else { return }; UIPasteboard.general.string = "\(self.item.title)\n\(self.item.detail)" })
    }
    override func render() {
        let item = item
        var metadata = [PhoneRow(id: "source", title: "Source", detail: item.source, isValue: true), PhoneRow(id: "category", title: "Category", detail: item.category, isValue: true), PhoneRow(id: "time", title: "Time", detail: item.timestamp.formatted(.iso8601), isValue: true)]
        if let traceID = item.traceID { metadata.append(PhoneRow(id: "trace", title: "Trace ID", detail: traceID, isValue: true)) }
        setSections([PhoneSection(title: "Event", rows: metadata), PhoneSection(title: "Command", rows: [PhoneRow(id: "command", title: item.title, context: { UIMenu(children: [UIAction(title: "Copy") { [item] _ in UIPasteboard.general.string = item.title }]) })]), PhoneSection(title: "Full Content", rows: [PhoneRow(id: "detail", title: item.detail, context: { UIMenu(children: [UIAction(title: "Copy") { [item] _ in UIPasteboard.general.string = item.detail }]) })])])
    }
}

#if DEBUG
extension AgentVerboseTraceData {
    static func previewData() -> Self {
        var value = Self()
        value.enabled = true
        value.localEntries = AirSIMPreviewFixtures.traceEntries
        value.agentState = "Preview Agent 1.0 · seq 3"
        value.rebuildTimeline()
        value.exportText = value.timeline.map { "\($0.title)\n\($0.detail)" }.joined(separator: "\n\n")
        return value
    }
}

#Preview("Agent Verbose · Timeline") {
    let model = AirSIMPreviewFixtures.presentation(tab: .settings)
    return AirSIMPreviewFixtures.navigation(AgentVerboseTraceViewController(model: model))
}

#Preview("Agent Verbose · Trace Details") {
    let item = AgentVerboseTraceData.previewData().timeline[0]
    return AirSIMPreviewFixtures.navigation(AgentVerboseTraceDetailViewController(item: item))
}
#endif
