import Testing
import Foundation
import AVFoundation
import WebRTC
@testable import AirSIM

struct CallRecordingTests {
    private let source = CallRecordingSource(callUUID: UUID())
    private let otherSource = CallRecordingSource(callUUID: UUID())
    @Test func `WebRTC module actually registers and retains both recording observers`() throws {
        let audio = CloudWebRTCRecordingAudio(source: source)
        // Test the real SDK getters, not a mock initializer: this SDK accepts
        // constructor delegates but does not bind them to the native adapter.
        let capture = try #require(audio.module.capturePostProcessingDelegate)
        let render = try #require(audio.module.renderPreProcessingDelegate)
        #expect(capture !== render)
        capture.audioProcessingInitialize(sampleRate: 48_000, channels: 1)
        render.audioProcessingInitialize(sampleRate: 48_000, channels: 1)
        #expect(audio.module.capturePostProcessingDelegate === capture)
        #expect(audio.module.renderPreProcessingDelegate === render)
        withExtendedLifetime(audio) {}
    }

    @Test func `WebRTC recordings follow call identity across local and cloud peers`() async throws {
        let (recorder, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let callUUID = UUID()
        let recording = CallRecordingSource(callUUID: callUUID)
        let localPeer = CallRecordingSource(callUUID: callUUID)
        let renegotiatedPeer = CallRecordingSource(callUUID: callUUID)
        let endedPeer = CallRecordingSource(callUUID: UUID())
        _ = try await recorder.start(callID: "webrtc", source: recording, atUptime: 10)
        recorder.appendPCM16(pcm([999]), channel: .local, source: endedPeer, atUptime: 10)
        recorder.appendPCM16(pcm([123]), channel: .local, source: localPeer, atUptime: 10)
        recorder.appendPCM16(pcm([456]), channel: .remote, source: renegotiatedPeer, atUptime: 10)
        let file = try await recorder.stop()
        #expect(try samples(recorder.url(for: file)) == [123, 456])
    }

    private func fixture() throws -> (CallAudioRecorder, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        return (CallAudioRecorder(directoryURL: directory), directory)
    }
    private func pcm(_ values: [Int16]) -> Data {
        values.withUnsafeBufferPointer { Data(buffer: $0) }
    }
    private func samples(_ url: URL) throws -> [Int16] {
        let wav = try Data(contentsOf: url)
        #expect(String(data: wav.prefix(4), encoding: .ascii) == "RIFF")
        #expect(String(data: wav[8..<12], encoding: .ascii) == "WAVE")
        #expect(Array(wav[22..<24]) == [2, 0])
        #expect(Array(wav[24..<28]) == [0x40, 0x1f, 0, 0])
        #expect(Array(wav[34..<36]) == [16, 0])
        return stride(from: 44, to: wav.count, by: 2).map {
            Int16(bitPattern: UInt16(wav[$0]) | UInt16(wav[$0 + 1]) << 8)
        }
    }

    @Test func `Stereo WAV preserves both directions and timeline silence`() async throws {
        let (recorder, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try await recorder.start(callID: "synthetic", source: source, atUptime: 100)
        recorder.appendPCM16(pcm([100, -200]), channel: .local, source: source, atUptime: 100)
        recorder.appendPCM16(pcm([300, -400]), channel: .remote, source: source, atUptime: 100 + 2.0 / 8_000)
        let file = try await recorder.stop()
        #expect(abs(file.duration - 4.0 / 8_000) <= 0.000001)
        #expect(try samples(recorder.url(for: file)) == [100, 0, -200, 0, 0, 300, 0, -400])
        #expect(file.bytes == 60)
        let persisted = try await recorder.recordings()
        #expect(persisted.map(\.id) == [file.id])
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(Set(files) == [file.id.uuidString + ".wav", file.id.uuidString + ".json"])
        #expect(!file.fileName.contains("synthetic"))
        #expect(try directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
    }

    @Test func `Mute persists across start and never mutes remote`() async throws {
        let (recorder, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        recorder.setMuted(true)
        _ = try await recorder.start(callID: "mute", source: source, atUptime: 10)
        let local: [Float] = [32_000, -32_000]
        local.withUnsafeBufferPointer {
            recorder.appendFloat32($0, sampleRate: 8_000, normalized: false, channel: .local, source: source, atUptime: 10)
        }
        recorder.appendPCM16(pcm([123, -456]), channel: .remote, source: source, atUptime: 10)
        let file = try await recorder.stop()
        #expect(try samples(recorder.url(for: file)) == [0, 123, 0, -456])
    }

    @Test func `Float S16 and normalized downsampling copies caller buffer`() async throws {
        let (recorder, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try await recorder.start(callID: "float", source: source, atUptime: 10)
        var floats: [Float] = [1_000, 1_000, -2_000, -2_000]
        floats.withUnsafeBufferPointer {
            recorder.appendFloat32($0, sampleRate: 16_000, normalized: false, channel: .local, source: source, atUptime: 10)
        }
        floats = [0, 0, 0, 0]
        let normalized: [Float] = [1, -1]
        normalized.withUnsafeBufferPointer {
            recorder.appendFloat32($0, sampleRate: 8_000, normalized: true, channel: .remote, source: source, atUptime: 10)
        }
        let file = try await recorder.stop()
        #expect(try samples(recorder.url(for: file)) == [1_000, 32_767, -2_000, -32_767])
    }

    @Test func `Empty wrong source and failed session cannot pollute next recording`() async throws {
        let (recorder, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try await recorder.start(callID: "empty", source: source, atUptime: 1)
        recorder.appendPCM16(pcm([999]), channel: .local, source: otherSource, atUptime: 1)
        await #expect(throws: CallRecordingError.self) {
            _ = try await recorder.stop()
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
        _ = try await recorder.start(callID: "limit", source: otherSource, atUptime: 1)
        recorder.appendPCM16(pcm([999]), channel: .local, source: otherSource, atUptime: 7_202)
        let limitError = await #expect(throws: (any Error).self) {
            _ = try await recorder.stop()
        }
        #expect(limitError?.localizedDescription == CallRecordingError.limit.localizedDescription)
        _ = try await recorder.start(callID: "fresh", source: otherSource, atUptime: 10)
        recorder.appendPCM16(pcm([42]), channel: .remote, source: otherSource, atUptime: 10)
        let file = try await recorder.stop()
        #expect(try samples(recorder.url(for: file)) == [0, 42])
        try await recorder.delete(file)
        let files = try await recorder.recordings()
        #expect(files.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    @Test @MainActor
    func `Call ending while start suspends finalizes and reports empty`() async throws {
        let (recorder, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CallRecordingStore(recorder: recorder)
        let starting = Task { try await store.start(callID: "ended", source: source) }
        // start reserves the call ID before its first suspension.
        while store.currentCallID == nil { await Task.yield() }
        store.finishCall("another-call")
        #expect(store.currentCallID == "ended")
        store.finishCall("ended")
        _ = try? await starting.value
        while store.isBusy || store.isRecording { await Task.yield() }
        #expect(store.currentCallID == nil)
        #expect(store.errorMessage != nil)
        #expect(store.recordings.isEmpty)
    }

    @Test func `Disk failure does not publish recording`() async throws {
        let (recorder, directory) = try fixture()
        try Data([1]).write(to: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let error = await #expect(throws: (any Error).self) {
            _ = try await recorder.start(callID: "disk", source: source)
        }
        #expect(error?.localizedDescription.isEmpty == false)
    }

    @Test func `Callback jitter preserves every speech sample`() async throws {
        let (recorder, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try await recorder.start(callID: "jitter", source: source, atUptime: 10)
        recorder.appendPCM16(pcm([1, 2]), channel: .local, source: source, atUptime: 10)
        recorder.appendPCM16(pcm([3, 4]), channel: .local, source: source, atUptime: 10 + 1.0 / 8_000)
        let file = try await recorder.stop()
        #expect(try samples(recorder.url(for: file)) == [1, 0, 2, 0, 3, 0, 4, 0])
    }

    @Test func `Storage limit preserves completed audio`() async throws {
        let (recorder, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try await recorder.start(callID: "limit", source: source, atUptime: 1)
        recorder.appendPCM16(pcm([100, 200]), channel: .local, source: source, atUptime: 1)
        recorder.appendPCM16(pcm([999]), channel: .local, source: source, atUptime: 7_202)
        let file = try await recorder.stop()
        #expect(try samples(recorder.url(for: file)) == [100, 0, 200, 0])
    }

    @Test func `Concurrent directions save playable stereo file`() async throws {
        let (recorder, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try await recorder.start(callID: "concurrent", source: source, atUptime: 100)
        let chunk = pcm([Int16](repeating: 5_000, count: 160))
        DispatchQueue.concurrentPerform(iterations: 2) { direction in
            for frame in 0..<100 {
                recorder.appendPCM16(chunk, channel: direction == 0 ? .local : .remote,
                    source: source, atUptime: 100 + Double(frame) * 0.02)
            }
        }
        let file = try await recorder.stop()
        let audio = try AVAudioFile(forReading: recorder.url(for: file))
        #expect(audio.length == 16_000)
        #expect(audio.processingFormat.channelCount == 2)
        #expect(audio.processingFormat.sampleRate == 8_000)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: 16_000))
        try audio.read(into: buffer)
        let channels = try #require(buffer.floatChannelData)
        #expect(abs(channels[0][8_000] - 5_000.0 / 32_768) <= 0.0001)
        #expect(abs(channels[1][8_000] - 5_000.0 / 32_768) <= 0.0001)
    }
}
