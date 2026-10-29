import Foundation

enum CallHistoryPolicy {
    static func merged(
        local: [CallRecord], remote: [CallRecord],
        deletedIDs: Set<String>, limit: Int
    ) -> [CallRecord] {
        var byID: [String: CallRecord] = [:]
        for record in local + remote where !deletedIDs.contains(record.id) {
            if let existing = byID[record.id], existing.updatedAt > record.updatedAt { continue }
            byID[record.id] = record
        }
        return Array(byID.values.sorted {
            if $0.startedAt == $1.startedAt { return $0.id < $1.id }
            return $0.startedAt > $1.startedAt
        }.prefix(max(0, limit)))
    }
}

/// Persists local call history and SMS on the phone independent of whether the module is online.
final class LocalHistoryStore {
    private let callHistoryURL: URL
    private let messagesURL: URL
    private let deletedCallIDsURL: URL

    init(fileManager: FileManager = .default, directoryURL: URL? = nil) {
        let durableRoot = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first
            ?? fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent("Documents", isDirectory: true)
        let resolvedDirectoryURL = directoryURL
            ?? durableRoot.appendingPathComponent("AirSIM", isDirectory: true)
        callHistoryURL = resolvedDirectoryURL.appendingPathComponent("call-history.json")
        messagesURL = resolvedDirectoryURL.appendingPathComponent("messages.json")
        deletedCallIDsURL = resolvedDirectoryURL.appendingPathComponent("deleted-call-ids.json")

        do {
            try fileManager.createDirectory(
                at: resolvedDirectoryURL,
                withIntermediateDirectories: true,
                attributes: nil
            )
        } catch {
            // Local caching must not block calls or SMS; subsequent write failures will still be logged.
            Self.log("Failed to create local history directory: \(error.localizedDescription)")
        }
    }

    func loadCallHistory() -> [CallRecord] {
        load(CallRecord.self, from: callHistoryURL) ?? []
    }

    func loadDeletedCallIDs() -> Set<String> {
        Set(load(String.self, from: deletedCallIDsURL) ?? [])
    }

    @discardableResult
    func saveDeletedCallIDs(_ ids: Set<String>) -> Bool {
        save(ids.sorted(), to: deletedCallIDsURL)
    }

    func loadMessages() -> [SMSMessage] {
        load(SMSMessage.self, from: messagesURL) ?? []
    }

    @discardableResult
    func saveCallHistory(_ records: [CallRecord]) -> Bool {
        save(records, to: callHistoryURL)
    }

    @discardableResult
    func saveMessages(_ records: [SMSMessage]) -> Bool {
        save(records, to: messagesURL)
    }

    private func load<Element: Decodable>(_ type: Element.Type, from url: URL) -> [Element]? {
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode([Element].self, from: data)
        } catch CocoaError.fileReadNoSuchFile {
            return nil
        } catch {
            Self.log("Failed to read local history (\(url.lastPathComponent)): \(error.localizedDescription)")
            return nil
        }
    }

    private func save<Element: Encodable>(_ records: [Element], to url: URL) -> Bool {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(records)
            // Atomic write creates a temporary file before replacing the target to avoid partial JSON on power loss.
            try data.write(to: url, options: [.atomic])
            return true
        } catch {
            Self.log("Failed to write local history (\(url.lastPathComponent)): \(error.localizedDescription)")
            return false
        }
    }

    private static func log(_ message: String) {
#if DEBUG
        print("[AirSIM LocalHistory] \(message)")
#endif
    }
}
