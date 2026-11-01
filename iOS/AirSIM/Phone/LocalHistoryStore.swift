import Foundation

enum CallHistoryPolicy {
    static func merged(
        local: [CallRecord],
        remote: [CallRecord],
        deletedIDs: Set<String>,
        limit: Int
    ) -> [CallRecord] {
        var byID: [String: CallRecord] = [:]
        for record in local + remote where !deletedIDs.contains(record.id) {
            if let existing = byID[record.id], existing.updatedAt > record.updatedAt { continue }
            byID[record.id] = record
        }
        return Array(
            byID.values.sorted {
                if $0.startedAt == $1.startedAt { return $0.id < $1.id }
                return $0.startedAt > $1.startedAt
            }.prefix(max(0, limit))
        )
    }
}

/// Persists local call history and SMS on the phone independent of whether the module is online.
final class LocalHistoryStore {
    private let fileManager: FileManager
    private let callHistoryURL: URL
    private let messagesURL: URL
    private let deletedCallIDsURL: URL

    init(fileManager: FileManager = .default, directoryURL: URL? = nil) {
        self.fileManager = fileManager
        let durableRoot =
            fileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first
            ?? fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Documents", isDirectory: true)
        let resolvedDirectoryURL =
            directoryURL
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
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch CocoaError.fileReadNoSuchFile {
            return nil
        } catch {
            // Protected data unavailable or permission errors leave the file in place for a later read.
            Self.log("Failed to read local history (\(url.lastPathComponent)): \(error.localizedDescription)")
            return nil
        }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode([Element].self, from: data)
        } catch let error as DecodingError {
            Self.log("Failed to decode local history (\(url.lastPathComponent)): \(error.localizedDescription)")
            // Callers treat nil as empty history and save over it, so keep the unreadable copy out of the way.
            moveAsideUnreadableFile(at: url)
            return nil
        } catch {
            Self.log("Failed to read local history (\(url.lastPathComponent)): \(error.localizedDescription)")
            return nil
        }
    }

    /// Renames the file to `<name>.unreadable-<UTC timestamp>.json` in the same directory, which keeps its file
    /// protection class and backup exclusion.
    private func moveAsideUnreadableFile(at url: URL) {
        let timestampFormatter = ISO8601DateFormatter()
        timestampFormatter.formatOptions = [.withYear, .withMonth, .withDay, .withTime, .withTimeZone]
        let directoryURL = url.deletingLastPathComponent()
        let unreadableName =
            "\(url.deletingPathExtension().lastPathComponent).unreadable-"
            + timestampFormatter.string(from: Date())
        var destinationURL = directoryURL.appendingPathComponent("\(unreadableName).json")
        if fileManager.fileExists(atPath: destinationURL.path) {
            destinationURL = directoryURL.appendingPathComponent(
                "\(unreadableName)-\(UUID().uuidString.lowercased()).json"
            )
        }
        do {
            try fileManager.moveItem(at: url, to: destinationURL)
            Self.log("Moved unreadable local history aside: \(destinationURL.lastPathComponent)")
        } catch {
            Self.log(
                "Failed to move unreadable local history aside (\(url.lastPathComponent)): \(error.localizedDescription)"
            )
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
