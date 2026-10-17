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

/// 负责保存手机本地的通话记录和短信，不依赖模块是否在线。
final class LocalHistoryStore {
    private let fileManager: FileManager
    private let directoryURL: URL
    private let callHistoryURL: URL
    private let messagesURL: URL
    private let deletedCallIDsURL: URL

    init(fileManager: FileManager = .default, directoryURL: URL? = nil) {
        self.fileManager = fileManager
        let durableRoot = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first
            ?? fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent("Documents", isDirectory: true)
        let resolvedDirectoryURL = directoryURL
            ?? durableRoot.appendingPathComponent("AirSIM", isDirectory: true)
        self.directoryURL = resolvedDirectoryURL
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
            // 本地缓存不能阻塞通话和短信；后续写入失败时仍会继续记录日志。
            Self.log("创建本地历史目录失败：\(error.localizedDescription)")
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
            Self.log("读取本地历史失败（\(url.lastPathComponent)）：\(error.localizedDescription)")
            return nil
        }
    }

    private func save<Element: Encodable>(_ records: [Element], to url: URL) -> Bool {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(records)
            // 原子写入先生成临时文件再替换目标，避免断电留下半个 JSON 文件。
            try data.write(to: url, options: [.atomic])
            return true
        } catch {
            Self.log("写入本地历史失败（\(url.lastPathComponent)）：\(error.localizedDescription)")
            return false
        }
    }

    private static func log(_ message: String) {
#if DEBUG
        print("[AirSIM LocalHistory] \(message)")
#endif
    }
}
