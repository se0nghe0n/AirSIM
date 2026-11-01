import Foundation

enum AgentVerboseTraceStage: String, Codable, Sendable {
    case request
    case route
    case response
    case event
    case failure
}

struct AgentVerboseTraceContext: Sendable {
    let id: String
    let method: String
    let path: String
    let startedAt: Date
}

struct AgentVerboseTraceEntry: Codable, Identifiable, Sendable, Equatable {
    let id: UUID
    let traceID: String
    let timestamp: Date
    let stage: AgentVerboseTraceStage
    let method: String
    let path: String
    let detail: String
    let elapsedMilliseconds: Int?
    let source: String?
    let category: String?
    let fields: [String: String]?
}

actor AgentVerboseTraceRecorder {
    static let preferenceKey = "agent_verbose_trace_enabled"

    static let shared = AgentVerboseTraceRecorder(
        initiallyEnabled: UserDefaults.standard.bool(forKey: preferenceKey),
        maxEntries: 1_200,
        persistenceURL: defaultPersistenceURL()
    )

    private var enabled: Bool
    private let maxEntries: Int
    private let persistenceURL: URL?
    private var entries: [AgentVerboseTraceEntry]

    init(initiallyEnabled: Bool, maxEntries: Int, persistenceURL: URL?) {
        enabled = initiallyEnabled
        self.maxEntries = max(1, maxEntries)
        self.persistenceURL = persistenceURL
        let loaded = Self.load(from: persistenceURL)
        entries =
            loaded.count > self.maxEntries
            ? Array(loaded.suffix(self.maxEntries))
            : loaded
    }

    func begin(method: String, path: String, bodyBytes: Int) -> AgentVerboseTraceContext? {
        guard enabled else { return nil }
        let context = AgentVerboseTraceContext(
            id: String(UUID().uuidString.prefix(8)).lowercased(),
            method: method.uppercased(),
            path: path,
            startedAt: Date()
        )
        append(
            context,
            stage: .request,
            detail: bodyBytes > 0 ? "Request started · body \(bodyBytes) B" : "Request started"
        )
        return context
    }

    func recordRoute(_ context: AgentVerboseTraceContext, route: String, attempt: Int, error: String? = nil) {
        guard enabled else { return }
        var detail = "Attempt \(attempt) · \(route)"
        if let error, !error.isEmpty { detail += " · \(error)" }
        append(context, stage: .route, detail: detail)
    }

    func finish(_ context: AgentVerboseTraceContext, statusCode: Int, responseBytes: Int) {
        guard enabled else { return }
        append(
            context,
            stage: .response,
            detail: "HTTP \(statusCode) · response \(responseBytes) B",
            elapsedMilliseconds: elapsed(from: context)
        )
        persist()
    }

    func fail(_ context: AgentVerboseTraceContext, error: String) {
        guard enabled else { return }
        append(
            context,
            stage: .failure,
            detail: error,
            elapsedMilliseconds: elapsed(from: context)
        )
        persist()
    }

    func recordEvent(
        source: String,
        category: String,
        phase: String,
        title: String,
        detail: String = "",
        fields: [String: String] = [:],
        isFailure: Bool = false
    ) {
        guard enabled else { return }
        let traceID = fields["trace_id"] ?? fields["command_id"].map { String($0.prefix(8)) }
        entries.append(
            AgentVerboseTraceEntry(
                id: UUID(),
                traceID: traceID ?? "--------",
                timestamp: Date(),
                stage: isFailure ? .failure : .event,
                method: phase.uppercased(),
                path: title,
                detail: detail,
                elapsedMilliseconds: nil,
                source: source.uppercased(),
                category: category,
                fields: fields
            )
        )
        trimIfNeeded()
        persist()
    }

    private func append(
        _ context: AgentVerboseTraceContext,
        stage: AgentVerboseTraceStage,
        detail: String,
        elapsedMilliseconds: Int? = nil
    ) {
        entries.append(
            AgentVerboseTraceEntry(
                id: UUID(),
                traceID: context.id,
                timestamp: Date(),
                stage: stage,
                method: context.method,
                path: context.path,
                detail: detail,
                elapsedMilliseconds: elapsedMilliseconds,
                source: nil,
                category: nil,
                fields: nil
            )
        )
        trimIfNeeded()
    }

    private func elapsed(from context: AgentVerboseTraceContext) -> Int {
        max(0, Int(Date().timeIntervalSince(context.startedAt) * 1_000))
    }

    private func trimIfNeeded() {
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
    }

    private func persist() {
        guard let persistenceURL else { return }
        do {
            try FileManager.default.createDirectory(
                at: persistenceURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try JSONEncoder().encode(entries).write(to: persistenceURL, options: .atomic)
        } catch {
            // Verbose tracing must never block the command it is observing.
        }
    }

    private static func load(from url: URL?) -> [AgentVerboseTraceEntry] {
        guard let url,
            let data = try? Data(contentsOf: url),
            let decoded = try? JSONDecoder().decode([AgentVerboseTraceEntry].self, from: data)
        else {
            return []
        }
        return decoded
    }

    private static func defaultPersistenceURL() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("AirSIM", isDirectory: true)
            .appendingPathComponent("agent-verbose-trace.json")
    }
}
