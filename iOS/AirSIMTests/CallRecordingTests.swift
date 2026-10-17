import XCTest
import AVFoundation
import WebRTC
@testable import AirSIM

final class CallRecordingTests: XCTestCase {
    func testWebRTCModuleActuallyRegistersAndRetainsBothRecordingObservers() throws {
        let audio = CloudWebRTCRecordingAudio()
        // Test the real SDK getters, not a mock initializer: this SDK accepts
        // constructor delegates but does not bind them to the native adapter.
        let capture = try XCTUnwrap(audio.module.capturePostProcessingDelegate)
        let render = try XCTUnwrap(audio.module.renderPreProcessingDelegate)
        XCTAssertFalse(capture === render)
        capture.audioProcessingInitialize(sampleRate: 48_000, channels: 1)
        render.audioProcessingInitialize(sampleRate: 48_000, channels: 1)
        XCTAssertTrue(audio.module.capturePostProcessingDelegate === capture)
        XCTAssertTrue(audio.module.renderPreProcessingDelegate === render)
        withExtendedLifetime(audio) {}
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
        XCTAssertEqual(String(data: wav.prefix(4), encoding: .ascii), "RIFF")
        XCTAssertEqual(String(data: wav[8..<12], encoding: .ascii), "WAVE")
        XCTAssertEqual(Array(wav[22..<24]), [2, 0])
        XCTAssertEqual(Array(wav[24..<28]), [0x40, 0x1f, 0, 0])
        XCTAssertEqual(Array(wav[34..<36]), [16, 0])
        return stride(from: 44, to: wav.count, by: 2).map {
            Int16(bitPattern: UInt16(wav[$0]) | UInt16(wav[$0 + 1]) << 8)
        }
    }

    func testStereoWAVPreservesBothDirectionsAndTimelineSilence() async throws {
        let (recorder, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try await recorder.start(callID: "synthetic", source: .cloudPCM, atUptime: 100)
        recorder.appendPCM16(pcm([100, -200]), channel: .local, source: .cloudPCM, atUptime: 100)
        recorder.appendPCM16(pcm([300, -400]), channel: .remote, source: .cloudPCM, atUptime: 100 + 2.0 / 8_000)
        let file = try await recorder.stop()
        XCTAssertEqual(file.duration, 4.0 / 8_000, accuracy: 0.000001)
        XCTAssertEqual(try samples(recorder.url(for: file)), [100, 0, -200, 0, 0, 300, 0, -400])
        XCTAssertEqual(file.bytes, 60)
        let persisted = try await recorder.recordings()
        XCTAssertEqual(persisted.map(\.id), [file.id])
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(Set(files), [file.id.uuidString + ".wav", file.id.uuidString + ".json"])
        XCTAssertFalse(file.fileName.contains("synthetic"))
        XCTAssertEqual(try directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
    }

    func testMutePersistsAcrossStartAndNeverMutesRemote() async throws {
        let (recorder, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        recorder.setMuted(true)
        _ = try await recorder.start(callID: "mute", source: .cloudWebRTC, atUptime: 10)
        let local: [Float] = [32_000, -32_000]
        local.withUnsafeBufferPointer {
            recorder.appendFloat32($0, sampleRate: 8_000, normalized: false, channel: .local, source: .cloudWebRTC, atUptime: 10)
        }
        recorder.appendPCM16(pcm([123, -456]), channel: .remote, source: .cloudWebRTC, atUptime: 10)
        let file = try await recorder.stop()
        XCTAssertEqual(try samples(recorder.url(for: file)), [0, 123, 0, -456])
    }

    func testFloatS16AndNormalizedDownsamplingCopiesCallerBuffer() async throws {
        let (recorder, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try await recorder.start(callID: "float", source: .cloudWebRTC, atUptime: 10)
        var floats: [Float] = [1_000, 1_000, -2_000, -2_000]
        floats.withUnsafeBufferPointer {
            recorder.appendFloat32($0, sampleRate: 16_000, normalized: false, channel: .local, source: .cloudWebRTC, atUptime: 10)
        }
        floats = [0, 0, 0, 0]
        let normalized: [Float] = [1, -1]
        normalized.withUnsafeBufferPointer {
            recorder.appendFloat32($0, sampleRate: 8_000, normalized: true, channel: .remote, source: .cloudWebRTC, atUptime: 10)
        }
        let file = try await recorder.stop()
        XCTAssertEqual(try samples(recorder.url(for: file)), [1_000, 32_767, -2_000, -32_767])
    }

    func testEmptyWrongSourceAndFailedSessionCannotPolluteNextRecording() async throws {
        let (recorder, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try await recorder.start(callID: "empty", source: .bluetooth, atUptime: 1)
        recorder.appendPCM16(pcm([999]), channel: .local, source: .localPCM, atUptime: 1)
        do { _ = try await recorder.stop(); XCTFail("Empty recording must fail") }
        catch { XCTAssertTrue(error is CallRecordingError) }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
        _ = try await recorder.start(callID: "limit", source: .localPCM, atUptime: 1)
        recorder.appendPCM16(pcm([999]), channel: .local, source: .localPCM, atUptime: 7_202)
        do { _ = try await recorder.stop(); XCTFail("Recording must stop at its limit") }
        catch { XCTAssertEqual(error.localizedDescription, CallRecordingError.limit.localizedDescription) }
        _ = try await recorder.start(callID: "fresh", source: .localPCM, atUptime: 10)
        recorder.appendPCM16(pcm([42]), channel: .remote, source: .localPCM, atUptime: 10)
        let file = try await recorder.stop()
        XCTAssertEqual(try samples(recorder.url(for: file)), [0, 42])
        try await recorder.delete(file)
        let files = try await recorder.recordings()
        XCTAssertTrue(files.isEmpty)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
    }

    @MainActor
    func testCallEndingWhileStartSuspendsFinalizesAndReportsEmpty() async throws {
        let (recorder, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CallRecordingStore(recorder: recorder)
        let starting = Task { try await store.start(callID: "ended", source: .cloudPCM) }
        // start reserves the call ID before its first suspension.
        while store.currentCallID == nil { await Task.yield() }
        store.finishCall("another-call")
        XCTAssertEqual(store.currentCallID, "ended")
        store.finishCall("ended")
        _ = try? await starting.value
        while store.isBusy || store.isRecording { await Task.yield() }
        XCTAssertNil(store.currentCallID)
        XCTAssertNotNil(store.errorMessage)
        XCTAssertTrue(store.recordings.isEmpty)
    }

    func testDiskFailureDoesNotPublishRecording() async throws {
        let (recorder, directory) = try fixture()
        try Data([1]).write(to: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        do { _ = try await recorder.start(callID: "disk", source: .cloudPCM); XCTFail("File cannot be a directory") }
        catch { XCTAssertFalse(error.localizedDescription.isEmpty) }
    }

    func testCallbackJitterPreservesEverySpeechSample() async throws {
        let (recorder, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try await recorder.start(callID: "jitter", source: .cloudPCM, atUptime: 10)
        recorder.appendPCM16(pcm([1, 2]), channel: .local, source: .cloudPCM, atUptime: 10)
        recorder.appendPCM16(pcm([3, 4]), channel: .local, source: .cloudPCM, atUptime: 10 + 1.0 / 8_000)
        let file = try await recorder.stop()
        XCTAssertEqual(try samples(recorder.url(for: file)), [1, 0, 2, 0, 3, 0, 4, 0])
    }

    func testStorageLimitPreservesCompletedAudio() async throws {
        let (recorder, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try await recorder.start(callID: "limit", source: .cloudPCM, atUptime: 1)
        recorder.appendPCM16(pcm([100, 200]), channel: .local, source: .cloudPCM, atUptime: 1)
        recorder.appendPCM16(pcm([999]), channel: .local, source: .cloudPCM, atUptime: 7_202)
        let file = try await recorder.stop()
        XCTAssertEqual(try samples(recorder.url(for: file)), [100, 0, 200, 0])
    }

    func testConcurrentDirectionsSavePlayableStereoFile() async throws {
        let (recorder, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try await recorder.start(callID: "concurrent", source: .cloudPCM, atUptime: 100)
        let chunk = pcm([Int16](repeating: 5_000, count: 160))
        DispatchQueue.concurrentPerform(iterations: 2) { direction in
            for frame in 0..<100 {
                recorder.appendPCM16(chunk, channel: direction == 0 ? .local : .remote,
                    source: .cloudPCM, atUptime: 100 + Double(frame) * 0.02)
            }
        }
        let file = try await recorder.stop()
        let audio = try AVAudioFile(forReading: recorder.url(for: file))
        XCTAssertEqual(audio.length, 16_000)
        XCTAssertEqual(audio.processingFormat.channelCount, 2)
        XCTAssertEqual(audio.processingFormat.sampleRate, 8_000)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: 16_000))
        try audio.read(into: buffer)
        let channels = try XCTUnwrap(buffer.floatChannelData)
        XCTAssertEqual(channels[0][8_000], 5_000.0 / 32_768, accuracy: 0.0001)
        XCTAssertEqual(channels[1][8_000], 5_000.0 / 32_768, accuracy: 0.0001)
    }
}
