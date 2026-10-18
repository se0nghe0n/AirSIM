import SwiftUI
import UIKit

private enum AgentVerboseTraceFilter: String, CaseIterable, Identifiable {
    case all = "全部"
    case failures = "错误"
    case calls = "通话"
    case relay = "Relay"
    case at = "AT"
    case usb = "USB"

    var id: String { rawValue }

    /// localization.md：筛选标签属于用户可见文案，用 LocalizedStringResource 延迟解析。
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

private struct AgentVerboseTimelineItem: Identifiable, Equatable {
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

    var tint: Color {
        if isFailure { return .red }
        switch category.lowercased() {
        case "at": return .green
        case "usb": return .cyan
        case "voice", "cloud-call", "cloud-call-control": return .purple
        case "relay": return .indigo
        case "http": return .blue
        default: return .secondary
        }
    }
}

@MainActor
@Observable
private final class AgentVerboseTraceViewModel {
    var enabled = false
    var localEntries: [AgentVerboseTraceEntry] = []
    var agentEvents: [ModuleDebugEvent] = []
    var agentState = "Not Connected"
    var errorMessage: String?
    var exportText = "AirSIM Agent Verbose Trace\n"
    // foreach.md：时间线是派生集合，只在 localEntries/agentEvents 变化时重建，
    // 不随视图每次读取重新映射排序（最多 2000 条）。
    private(set) var timeline: [AgentVerboseTimelineItem] = []

    @ObservationIgnored private let api: AirSIMAPI
    @ObservationIgnored private var lastSequence: UInt64 = 0

    init(api: AirSIMAPI) { self.api = api }

    func run() async {
        enabled = await AgentVerboseTraceRecorder.shared.isEnabled()
        await refresh()
        while !Task.isCancelled {
            do { try await Task.sleep(for: .seconds(enabled ? 1 : 2)) }
            catch { return }
            guard !Task.isCancelled else { return }
            await refresh()
        }
    }

    func setEnabled(_ value: Bool) {
        enabled = value
        Task {
            await AgentVerboseTraceRecorder.shared.setEnabled(value)
            await refresh()
        }
    }

    func refresh() async {
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

    private func rebuildTimeline() {
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

    func clear() async {
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
        await refresh()
    }

    private func merge(_ newEvents: [ModuleDebugEvent]) {
        let known = Set(agentEvents.map(\.sequence))
        agentEvents.append(contentsOf: newEvents.filter { !known.contains($0.sequence) })
        if agentEvents.count > 2_000 { agentEvents.removeFirst(agentEvents.count - 2_000) }
    }

    private func rebuildExport() async {
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

struct AgentVerboseTraceView: View {
    @State private var model: AgentVerboseTraceViewModel
    @State private var filter: AgentVerboseTraceFilter = .all
    @State private var selectedItem: AgentVerboseTimelineItem?
    @State private var showingClearConfirmation = false

    init(api: AirSIMAPI) {
        model = AgentVerboseTraceViewModel(api: api)
    }

    var body: some View {
        List {
                Section {
                    Toggle(isOn: Binding(get: { model.enabled }, set: model.setEnabled)) {
                        Label {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Verbose Trace Mode")
                                Text(model.enabled ? "Capturing app, USB, HTTP, AT, and Agent events" : "New app requests are not recorded while off")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "point.3.connected.trianglepath.dotted")
                                .foregroundStyle(model.enabled ? .orange : .secondary)
                        }
                    }

                    LabeledContent("Agent Connection", value: model.agentState)
                    LabeledContent("Local Trace", value: "\(model.localEntries.count) entries")
                    LabeledContent("Agent Events", value: "\(model.agentEvents.count) entries")
                } header: {
                    Text("Request Tracing")
                } footer: {
                    Text("Logs may include phone numbers, message text, AT responses, and device identifiers. Turn off Verbose mode after troubleshooting and review logs before sharing.")
                }

                Section {
                    Picker("Filter", selection: $filter) {
                        ForEach(AgentVerboseTraceFilter.allCases) { item in
                            Text(item.title).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                if let error = model.errorMessage {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                }

                Section("Live Request Trace") {
                    if filteredTimeline.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "waveform.path.ecg")
                                .font(.title2)
                                .foregroundStyle(.secondary)
                            Text("No Trace Events").font(.headline)
                            Text(model.enabled ? "Events appear as you make calls, send messages, change settings, or send AT commands." : "Enable Verbose Trace Mode first.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                    } else {
                        ForEach(filteredTimeline) { item in
                            Button {
                                selectedItem = item
                            } label: {
                                AgentVerboseTimelineRow(item: item)
                            }
                            .buttonStyle(.plain)
                            .id(item.id)
                            .contextMenu {
                                Button("Copy Entry", systemImage: "doc.on.doc") {
                                    UIPasteboard.general.string = "\(item.title)\n\(item.detail)"
                                }
                            }
                        }
                    }
                }
        }
        .navigationTitle("Agent Verbose")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                ShareLink(item: model.exportText) {
                    Image(systemName: "square.and.arrow.up")
                }
                Button(role: .destructive) { showingClearConfirmation = true } label: {
                    Image(systemName: "trash")
                }
            }
        }
        .task { await model.run() }
        .refreshable { await model.refresh() }
        .sheet(item: $selectedItem) { item in
            AgentVerboseTraceDetailView(item: item)
        }
        .confirmationDialog("Clear App and Agent Debug Logs?", isPresented: $showingClearConfirmation) {
            Button("Clear All", role: .destructive) { Task { await model.clear() } }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var filteredTimeline: [AgentVerboseTimelineItem] {
        model.timeline.filter { item in
            switch filter {
            case .all: return true
            case .failures: return item.isFailure
            case .calls:
                return ["voice", "cloud-call", "cloud-call-control"].contains(item.category.lowercased())
            case .relay: return item.source == "RELAY" || item.category.lowercased() == "relay"
            case .at: return item.category.lowercased() == "at"
            case .usb: return item.category.lowercased() == "usb"
            }
        }
    }
}

/// 时间线行独立成子视图：条目内容不变时，刷新循环不再重建行内容
/// （structure.md 失效边界；AgentVerboseTimelineItem 是 Equatable）。
private struct AgentVerboseTimelineRow: View {
    let item: AgentVerboseTimelineItem

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: item.systemImage)
                .font(.callout.weight(.semibold))
                .foregroundStyle(item.tint)
                .frame(width: 28, height: 28)
                .background(item.tint.opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(item.source)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(item.source == "APP" ? .blue : .purple)
                    // 诊断时间戳是调试输出，保持固定 24 小时制 HH:mm:ss.SSS：
                    // 不随语言环境变化，避免 12 小时制地区 03:15 与 15:15 同显歧义。
                    Text(
                        item.timestamp,
                        format: Date.VerbatimFormatStyle(
                            format: "\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits):\(second: .twoDigits).\(secondFraction: .fractional(3))",
                            timeZone: .current,
                            calendar: .current
                        )
                    )
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    if let traceID = item.traceID {
                        Text("#\(traceID)")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
                Text(item.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(item.isFailure ? .red : .primary)
                    .lineLimit(2)
                if !item.detail.isEmpty {
                    Text(item.detail)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }
        }
        .padding(.vertical, 3)
    }
}

private struct AgentVerboseTraceDetailView: View {
    @Environment(\.dismiss) private var dismiss
    let item: AgentVerboseTimelineItem

    var body: some View {
        NavigationStack {
            List {
                Section("Event") {
                    LabeledContent("Source", value: item.source)
                    LabeledContent("Category", value: item.category)
                    if let traceID = item.traceID { LabeledContent("Trace ID", value: traceID) }
                    LabeledContent("Time", value: item.timestamp.formatted(.iso8601))
                }
                Section("Command") {
                    Text(item.title).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                }
                if !item.detail.isEmpty {
                    Section("Full Content") {
                        Text(item.detail).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    }
                }
            }
            .navigationTitle("Trace Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Copy", systemImage: "doc.on.doc") {
                        UIPasteboard.general.string = "\(item.title)\n\(item.detail)"
                    }
                }
            }
        }
    }
}
