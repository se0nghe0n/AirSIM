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
#endif
