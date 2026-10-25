import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Recording follows the owning call, not its local/cloud transport. Native
/// observers carry an immutable identity, so callbacks from an ended peer can
/// never enter the next call's recording. Renegotiation preserves the call UUID.
struct CallRecordingSource: Equatable, Sendable {
    let callUUID: UUID
}
enum CallRecordingChannel: Sendable { case local, remote }

struct CallRecordingFile: Codable, Identifiable, Sendable, Equatable {
    let id: UUID
    let callID: String
    let startedAt: Date
    let duration: TimeInterval
    let fileName: String
    let bytes: Int?
}

enum CallRecordingError: LocalizedError {
    case busy, empty, overloaded, limit, invalidAudio, storage
    var errorDescription: String? {
        switch self {
        case .busy: return "A recording is already being processed."
        case .empty: return "No call audio was received. The empty recording was removed."
        case .overloaded: return "Recording stopped because audio could not be saved fast enough."
        case .limit: return "Recording stopped at the two-hour storage limit."
        case .invalidAudio: return "Recording stopped because the audio format was invalid."
        case .storage: return "Recording could not be saved. Check available storage."
        }
    }
}

/// A short metadata lock never spans conversion or file I/O. A coalescing dispatch
/// source drains at most 256 KiB per batch, away from the audio processing threads.
final class CallAudioRecorder: @unchecked Sendable {
    static let shared = CallAudioRecorder()
    static let sampleRate = 8_000
    static let maximumFrames = sampleRate * 60 * 60 * 2
    private let queue = DispatchQueue(label: "AirSIM.call-recording", qos: .utility)
    private let lock = NSLock()
    private var muted = false
    private var admission: Admission?
    private var pending: [Packet] = []
    private var pendingBytes = 0
    private var reservedBytes = 0
    private var pendingError: (UUID, CallRecordingError)?
    private var session: Session? // Writer queue only.
    private let directory: URL
    private lazy var signal: DispatchSourceUserDataAdd = {
        let source = DispatchSource.makeUserDataAddSource(queue: queue)
        source.setEventHandler { [weak self] in self?.drain() }
        source.resume()
        return source
    }()

    private struct Admission {
        let id: UUID
        let source: CallRecordingSource
        let uptime: TimeInterval
    }
    private struct Packet {
        let id: UUID
        let channel: CallRecordingChannel
        let frame: Int
        let pcm: Data
    }
    private final class Session {
        let admission: Admission
        let callID: String
        let startedAt: Date
        let local: FileHandle
        let remote: FileHandle
        let localURL: URL
        let remoteURL: URL
        let failure: @Sendable (UUID, Error) -> Void
        var localEnd = 0
        var remoteEnd = 0
        var error: Error?
        init(admission: Admission, callID: String, local: FileHandle, remote: FileHandle,
             localURL: URL, remoteURL: URL, failure: @escaping @Sendable (UUID, Error) -> Void) {
            self.admission = admission; self.callID = callID; startedAt = Date()
            self.local = local; self.remote = remote
            self.localURL = localURL; self.remoteURL = remoteURL; self.failure = failure
        }
    }

    init(directoryURL: URL? = nil) {
        directory = directoryURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CallRecordings", isDirectory: true)
        _ = signal // Initialize before any audio callback.
    }

    func setMuted(_ value: Bool) {
        lock.lock(); muted = value; lock.unlock()
    }

    func appendPCM16(_ pcm: Data, channel: CallRecordingChannel, source: CallRecordingSource,
                     atUptime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        append(channel: channel, source: source, uptime: atUptime, inputCount: pcm.count / 2) { silence in
            guard pcm.count % 2 == 0 else { return nil }
            return silence ? Data(count: pcm.count) : Data(pcm)
        }
    }

    func appendFloat32(_ samples: UnsafeBufferPointer<Float>, sampleRate: Double, normalized: Bool,
                       channel: CallRecordingChannel, source: CallRecordingSource,
                       atUptime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        // Copy/resample synchronously; never retain the caller's buffer.
        guard sampleRate.isFinite, sampleRate >= 8_000, sampleRate <= 192_000,
              samples.count <= 196_608 else { return }
        let outputCount = Int(Double(samples.count) * 8_000 / sampleRate)
        append(channel: channel, source: source, uptime: atUptime, inputCount: outputCount) { silence in
            var data = Data(count: outputCount * 2)
            if silence { return data }
            data.withUnsafeMutableBytes { raw in
                let output = raw.bindMemory(to: Int16.self)
                for index in 0..<outputCount {
                    let lower = Int(Double(index) * sampleRate / 8_000)
                    let upper = min(samples.count, max(lower + 1, Int(Double(index + 1) * sampleRate / 8_000)))
                    var sum: Float = 0
                    for position in lower..<upper { sum += samples[position].isFinite ? samples[position] : 0 }
                    let value = sum / Float(upper - lower) * (normalized ? 32_767 : 1)
                    output[index] = Int16(value.isFinite ? max(-32_768, min(32_767, value)) : 0).littleEndian
                }
            }
            return data
        }
    }

    private func append(channel: CallRecordingChannel, source: CallRecordingSource, uptime: TimeInterval,
                        inputCount: Int, copy: (Bool) -> Data?) {
        lock.lock()
        guard let active = admission, active.source == source else { lock.unlock(); return }
        guard uptime.isFinite, inputCount > 0 else { lock.unlock(); return }
        let elapsed = max(0, uptime - active.uptime)
        let failure: CallRecordingError?
        if elapsed >= Double(Self.maximumFrames) / 8_000 { failure = .limit }
        else if inputCount > 8_192 { failure = .invalidAudio }
        else if pendingBytes + reservedBytes + inputCount * 2 > 262_144 { failure = .overloaded }
        else { failure = nil }
        if let failure {
            pendingError = (active.id, failure); admission = nil; lock.unlock()
            signal.add(data: 1); return
        }
        let silence = channel == .local && muted
        reservedBytes += inputCount * 2
        lock.unlock()
        // Conversion and copying run outside the very short admission critical section.
        var data = copy(silence)
        lock.lock()
        guard admission?.id == active.id else { lock.unlock(); return }
        reservedBytes -= inputCount * 2
        guard data != nil else {
            pendingError = (active.id, .invalidAudio); admission = nil; lock.unlock()
            signal.add(data: 1); return
        }
        // A mute transition during conversion must also erase that in-flight local buffer.
        if channel == .local && muted && !silence { data = Data(count: inputCount * 2) }
        pending.append(Packet(id: active.id, channel: channel, frame: Int((elapsed * 8_000).rounded()), pcm: data!))
        pendingBytes += inputCount * 2
        lock.unlock()
        signal.add(data: 1)
    }

    func start(callID: String, source: CallRecordingSource,
               atUptime: TimeInterval = ProcessInfo.processInfo.systemUptime,
               onFailure: @escaping @Sendable (UUID, Error) -> Void = { _, _ in }) async throws -> UUID {
        try await perform {
            guard self.session == nil else { throw CallRecordingError.busy }
            try self.prepareDirectory()
            let id = UUID()
            let localURL = self.directory.appendingPathComponent(id.uuidString + ".local.raw")
            let remoteURL = self.directory.appendingPathComponent(id.uuidString + ".remote.raw")
            do {
                try Data().write(to: localURL); try Data().write(to: remoteURL)
                try self.protect(localURL); try self.protect(remoteURL)
                let local = try FileHandle(forUpdating: localURL)
                let remote: FileHandle
                do { remote = try FileHandle(forUpdating: remoteURL) }
                catch { try? local.close(); throw error }
                self.lock.lock()
                let active = Admission(id: id, source: source, uptime: atUptime)
                self.pending.removeAll(keepingCapacity: true); self.pendingBytes = 0; self.reservedBytes = 0; self.pendingError = nil
                self.session = Session(admission: active, callID: callID, local: local, remote: remote,
                                       localURL: localURL, remoteURL: remoteURL, failure: onFailure)
                self.admission = active
                self.lock.unlock()
                return id
            } catch {
                try? FileManager.default.removeItem(at: localURL)
                try? FileManager.default.removeItem(at: remoteURL)
                throw CallRecordingError.storage
            }
        }
    }

    func stop() async throws -> CallRecordingFile {
        try await perform {
            guard let active = self.session else { throw CallRecordingError.empty }
            self.lock.lock(); self.admission = nil; self.lock.unlock()
            self.drain()
            defer {
                try? active.local.close(); try? active.remote.close()
                try? FileManager.default.removeItem(at: active.localURL)
                try? FileManager.default.removeItem(at: active.remoteURL)
                self.session = nil
            }
            let frames = max(active.localEnd, active.remoteEnd)
            guard frames > 0 else { throw active.error ?? CallRecordingError.empty }
            let name = active.admission.id.uuidString + ".wav"
            let outputURL = self.directory.appendingPathComponent(name)
            let metadataURL = outputURL.deletingPathExtension().appendingPathExtension("json")
            do {
                try self.finalize(active, frames: frames, outputURL: outputURL)
                let file = CallRecordingFile(id: active.admission.id, callID: active.callID,
                    startedAt: active.startedAt, duration: Double(frames) / 8_000, fileName: name, bytes: 44 + frames * 4)
                try JSONEncoder().encode(file).write(to: metadataURL, options: .atomic)
                try self.protect(metadataURL)
                return file
            } catch {
                try? FileManager.default.removeItem(at: outputURL)
                try? FileManager.default.removeItem(at: metadataURL)
                throw CallRecordingError.storage
            }
        }
    }

    private func drain() {
        lock.lock()
        let packets = pending
        let ingressError = pendingError
        pending = []; pendingBytes = 0; pendingError = nil
        lock.unlock()
        guard let active = session, active.error == nil else { return }
        do {
            for packet in packets where packet.id == active.admission.id {
                let previous = packet.channel == .local ? active.localEnd : active.remoteEnd
                // The sample clock is authoritative within a continuous stream.
                // Scheduling jitter must not trim speech or insert a hole each callback.
                // Larger interruptions retain their wall-clock gap as silence.
                let frame = previous > 0 && abs(packet.frame - previous) <= 800
                    ? previous : packet.frame
                let skip = max(0, previous - frame)
                let count = packet.pcm.count / 2 - skip
                guard count > 0 else { continue }
                let offset = max(previous, frame)
                guard offset + count <= Self.maximumFrames else { throw CallRecordingError.limit }
                let handle = packet.channel == .local ? active.local : active.remote
                try handle.seek(toOffset: UInt64(offset * 2)) // Sparse holes read back as silence.
                try handle.write(contentsOf: packet.pcm.dropFirst(skip * 2))
                if packet.channel == .local { active.localEnd = offset + count }
                else { active.remoteEnd = offset + count }
            }
            if let (id, error) = ingressError, id == active.admission.id { fail(active, error: error) }
        } catch { fail(active, error: (error as? CallRecordingError) ?? .storage) }
    }

    private func fail(_ active: Session, error: Error) {
        guard active.error == nil else { return }
        active.error = error
        lock.lock()
        if admission?.id == active.admission.id { admission = nil }
        lock.unlock()
        active.failure(active.admission.id, error)
    }

    private func finalize(_ active: Session, frames: Int, outputURL: URL) throws {
        try Data().write(to: outputURL)
        try protect(outputURL)
        let output = try FileHandle(forWritingTo: outputURL)
        defer { try? output.close() }
        var header = Data("RIFF".utf8)
        func u32(_ n: Int) { var value = UInt32(n).littleEndian; withUnsafeBytes(of: &value) { header.append(contentsOf: $0) } }
        func u16(_ n: Int) { var value = UInt16(n).littleEndian; withUnsafeBytes(of: &value) { header.append(contentsOf: $0) } }
        u32(36 + frames * 4); header.append(Data("WAVEfmt ".utf8)); u32(16)
        u16(1); u16(2); u32(8_000); u32(32_000); u16(4); u16(16)
        header.append(Data("data".utf8)); u32(frames * 4)
        try output.write(contentsOf: header)
        try active.local.seek(toOffset: 0); try active.remote.seek(toOffset: 0)
        for start in stride(from: 0, to: frames, by: 8_192) {
            let count = min(8_192, frames - start)
            let left = try active.local.read(upToCount: count * 2) ?? Data()
            let right = try active.remote.read(upToCount: count * 2) ?? Data()
            var stereo = Data(count: count * 4)
            stereo.withUnsafeMutableBytes { (out: UnsafeMutableRawBufferPointer) in
                left.withUnsafeBytes { (l: UnsafeRawBufferPointer) in
                    right.withUnsafeBytes { (r: UnsafeRawBufferPointer) in
                        for i in 0..<count {
                            if i * 2 + 1 < l.count { out[i * 4] = l[i * 2]; out[i * 4 + 1] = l[i * 2 + 1] }
                            if i * 2 + 1 < r.count { out[i * 4 + 2] = r[i * 2]; out[i * 4 + 3] = r[i * 2 + 1] }
                        }
                    }
                }
            }
            try output.write(contentsOf: stereo)
        }
        try output.synchronize()
    }

    func recordings() async throws -> [CallRecordingFile] {
        try await perform {
            try self.prepareDirectory()
            return try FileManager.default.contentsOfDirectory(at: self.directory, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "json" }.compactMap { url in
                    guard let data = try? Data(contentsOf: url),
                          let file = try? JSONDecoder().decode(CallRecordingFile.self, from: data),
                          file.fileName == file.id.uuidString + ".wav",
                          FileManager.default.fileExists(atPath: self.url(for: file).path) else { return nil }
                    return file
                }.sorted { $0.startedAt > $1.startedAt }
        }
    }

    func url(for file: CallRecordingFile) -> URL { directory.appendingPathComponent(file.id.uuidString + ".wav") }

    func delete(_ file: CallRecordingFile) async throws {
        try await perform {
            let url = self.url(for: file)
            let metadata = url.deletingPathExtension().appendingPathExtension("json")
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            if FileManager.default.fileExists(atPath: metadata.path) { try FileManager.default.removeItem(at: metadata) }
        }
    }

    private func prepareDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try protect(directory)
        // No session owns scratch files during first use after process launch.
        if session == nil {
            for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                where file.pathExtension == "raw" { try? FileManager.default.removeItem(at: file) }
        }
    }

    private func protect(_ url: URL) throws {
        var target = url
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try target.setResourceValues(values)
        var attributes: [FileAttributeKey: Any] = [.posixPermissions: url.hasDirectoryPath ? 0o700 : 0o600]
#if os(iOS)
        attributes[.protectionKey] = FileProtectionType.completeUntilFirstUserAuthentication
#endif
        try FileManager.default.setAttributes(attributes, ofItemAtPath: url.path)
    }

    private func perform<T>(_ operation: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try operation() }) }
        }
    }
}

@MainActor
@Observable
final class CallRecordingStore {
    static let shared = CallRecordingStore()
    private(set) var isRecording = false
    private(set) var isBusy = false
    private(set) var recordings: [CallRecordingFile] = []
    private(set) var errorMessage: String? {
        didSet { if let errorMessage { onErrorMessage?(errorMessage) } }
    }
    /// AppModel forwards recording errors to its own global banner; the callback is part of the bridging pipeline and does not participate in observation.
    @ObservationIgnored var onErrorMessage: ((String) -> Void)?
    @ObservationIgnored private(set) var currentCallID: String?
    @ObservationIgnored private let recorder: CallAudioRecorder
    @ObservationIgnored private var sessionID: UUID?
    @ObservationIgnored private var finishAfterStart = false
    @ObservationIgnored private var failureDuringStart: (UUID, Error)?
#if canImport(UIKit)
    @ObservationIgnored private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
#endif

    init(recorder: CallAudioRecorder = .shared) { self.recorder = recorder }

    func start(callID: String, source: CallRecordingSource) async throws {
        guard !isBusy, !isRecording else { throw CallRecordingError.busy }
        isBusy = true; currentCallID = callID; finishAfterStart = false; failureDuringStart = nil; errorMessage = nil
        do {
            let id = try await recorder.start(callID: callID, source: source) { [weak self] id, error in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if self.sessionID == nil, self.isBusy, self.currentCallID != nil {
                        self.failureDuringStart = (id, error)
                        return
                    }
                    guard self.sessionID == id else { return }
                    self.errorMessage = error.localizedDescription
                    try? await self.stop()
                }
            }
            sessionID = id; isRecording = true; isBusy = false
            if let (failedID, error) = failureDuringStart, failedID == id {
                errorMessage = error.localizedDescription
                try await stop()
            } else if finishAfterStart { try await stop() }
        } catch {
            isBusy = false; isRecording = false; currentCallID = nil; sessionID = nil
            errorMessage = error.localizedDescription
            endBackgroundTask()
            throw error
        }
    }

    func stop() async throws {
        guard isRecording, !isBusy else { return }
        isBusy = true; isRecording = false
        beginBackgroundTask()
        defer { isBusy = false; currentCallID = nil; sessionID = nil; endBackgroundTask() }
        do {
            let file = try await recorder.stop()
            recordings.insert(file, at: 0)
        } catch { errorMessage = error.localizedDescription; throw error }
    }

    func finishCall(_ callID: String?) {
        guard let callID, currentCallID == callID else { return }
        beginBackgroundTask()
        if isBusy { finishAfterStart = true; return }
        Task { try? await stop() }
    }

    func reload() async {
        do { recordings = try await recorder.recordings() }
        catch { errorMessage = CallRecordingError.storage.localizedDescription }
    }
    func url(for recording: CallRecordingFile) -> URL { recorder.url(for: recording) }
    func delete(_ recording: CallRecordingFile) async throws {
        do { try await recorder.delete(recording); recordings.removeAll { $0.id == recording.id } }
        catch { errorMessage = CallRecordingError.storage.localizedDescription; throw error }
    }

    private func beginBackgroundTask() {
#if canImport(UIKit)
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Save call recording") { [weak self] in
            self?.errorMessage = "Recording save was interrupted by the system."
            self?.endBackgroundTask()
        }
#endif
    }
    private func endBackgroundTask() {
#if canImport(UIKit)
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask); backgroundTask = .invalid
#endif
    }
}
