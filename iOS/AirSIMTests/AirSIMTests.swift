import CryptoKit
import CoreBluetooth
import AVFoundation
import XCTest
@testable import AirSIM

// Simulator test runner is unsigned and has no Keychain entitlement (-34018).
// Keep the real controller; replace only the OS credential persistence boundary.
private final class InMemoryVoBLEPairingStore: VoBLEPairingStoring, @unchecked Sendable {
    private var values: [String: VoBLEStoredPeer] = [:]
    func save(_ peer: VoBLEStoredPeer) throws { values[peer.identity] = peer }
    func load(identity: String) throws -> VoBLEStoredPeer? { values[identity] }
    func revoke(identity: String) throws { values.removeValue(forKey: identity) }
}

private actor OutgoingCallServiceProbe: OutgoingCallServicing {
    private let dialError: Error?
    private var actions: [String] = []

    init(dialError: Error? = nil) {
        self.dialError = dialError
    }

    func warmAudioHost() async throws { actions.append("warm") }
    func setAudioHostEnabled(_ enabled: Bool) async throws { actions.append("enable:\(enabled)") }
    func dial(number: String) async throws {
        actions.append("dial:\(number)")
        if let dialError { throw dialError }
    }

    func recordedActions() -> [String] { actions }
}

@MainActor
private final class VoBLEWriterProbe: VoBLEMediaWriting {
    var canSend: Bool
    let maximumLength: Int
    private(set) var writes: [Data] = []

    init(canSend: Bool, maximumLength: Int) {
        self.canSend = canSend
        self.maximumLength = maximumLength
    }

    var canSendWriteWithoutResponse: Bool { canSend }
    var maximumWriteLength: Int { maximumLength }
    func writeWithoutResponse(_ data: Data) { writes.append(data) }
}

private struct LegacyAgentSMSProbe: LegacyAgentPolling {
    let pending: Int?
    let smsStatusAvailable: Bool

    func callStatus() async throws -> CallStatus {
        CallStatus(active: nil, history: [], polling: true, eventDriven: false,
                   pollIntervalSeconds: 1, lastPollError: "", revision: nil)
    }

    func smsStatus() async throws -> SMSStatus {
        if !smsStatusAvailable { throw URLError(.badServerResponse) }
        return SMSStatus(autoCleanupME: true, count: pending, lastPollError: nil)
    }
}

@MainActor
private final class VoBLECallControlProbe: VoBLECallControlling {
    var state: VoBLEConnectionState = .ready
    var onEvent: ((VoBLEAndroidEvent) -> Void)?
    var onAudioDownlinkFragment: ((Data) -> Void)?
    var onReadyToSendAudio: (() -> Void)?
    var onDisconnected: (() -> Void)?
    var onReady: (() -> Void)?
    var sendOperation: (String, String, UInt64) async throws -> VoBLEControlResponse = { _, _, generation in
        .init(requestID: "test-response", generation: generation, success: true, code: "ok", detail: "accepted")
    }
    func send(command: String, callID: String, generation: UInt64,
              number: String) async throws -> VoBLEControlResponse {
        try await sendOperation(command, callID, generation)
    }
    func mediaKey(callID: String, generation: UInt64) throws -> Data {
        Data(repeating: 1, count: 32)
    }
}

private struct AgentSMSInboxProbe: AgentSMSInboxServicing {
    let name: String
    let inbox: [SMSMessage]

    func messages() async throws -> [SMSMessage] { inbox }
}

final class AirSIMTests: XCTestCase {

    private func traceFrame(sequence: UInt32 = 1, source: UInt64 = 1_000,
                            relay: UInt64 = 10_000, queue: UInt32 = 7) -> Data {
        var data = Data([65, 83, 80, 77, 2, 0, 0, 48])
        func append(_ value: UInt64, bytes: Int) {
            for shift in stride(from: (bytes - 1) * 8, through: 0, by: -8) {
                data.append(UInt8(truncatingIfNeeded: value >> shift))
            }
        }
        append(UInt64(sequence), bytes: 4)
        append(UInt64(queue), bytes: 4)
        append(source, bytes: 8)
        append(source + 500_000, bytes: 8)
        append(relay, bytes: 8)
        append(relay, bytes: 8)
        data.append(Data(repeating: 0x7b, count: 320))
        return data
    }

    func testCloudPCMTraceWireDecodeAndLegacyCompatibility() throws {
        let frame = try XCTUnwrap(CloudPCMTransportFrame.decode(
            traceFrame(sequence: 0xfedcba98, source: 9_876, relay: 55_000, queue: 17)))
        XCTAssertEqual(frame.pcm, Data(repeating: 0x7b, count: 320))
        let trace = try XCTUnwrap(frame.trace)
        XCTAssertEqual(trace.sequence, 0xfedcba98)
        XCTAssertEqual(trace.sourceQueueMS, 17)
        XCTAssertEqual(trace.sourceSendMonoMS, 9_876)
        XCTAssertEqual(trace.sourceSendUnixMS, 509_876)
        XCTAssertEqual(trace.relayReceiveUnixMS, 55_000)
        XCTAssertEqual(trace.relayForwardUnixMS, 55_000)
        for size in [320, 640] {
            var raw = Data(repeating: 0, count: size)
            raw.replaceSubrange(0..<4, with: [65, 83, 80, 77])
            XCTAssertEqual(CloudPCMTransportFrame.decode(raw)?.pcm, raw)
            XCTAssertNil(CloudPCMTransportFrame.decode(raw)?.trace)
        }
        var legacy = Data([65, 83, 80, 77, 1, 0, 0, 20])
        legacy.append(Data(repeating: 0, count: 12))
        legacy.append(Data(repeating: 7, count: 320))
        XCTAssertEqual(CloudPCMTransportFrame.decode(legacy)?.pcm, Data(repeating: 7, count: 320))
    }

    func testCloudPCMTraceRejectsMalformedEnvelope() {
        var bad = traceFrame()
        bad[7] = 47
        XCTAssertNil(CloudPCMTransportFrame.decode(bad))
        bad = traceFrame()
        bad[4] = 3
        XCTAssertNil(CloudPCMTransportFrame.decode(bad))
        bad = traceFrame()
        bad[5] = 1
        XCTAssertNil(CloudPCMTransportFrame.decode(bad))
        XCTAssertNil(CloudPCMTransportFrame.decode(Data(traceFrame().dropLast())))
        XCTAssertNil(CloudPCMTransportFrame.decode(Data()))
    }

    func testCloudPCMTraceSeparatesUpstreamAndDownstreamDelayWithoutClockSync() throws {
        func trace(_ sequence: UInt32, _ source: UInt64, _ relay: UInt64) throws -> CloudPCMTransportFrame.Trace {
            try XCTUnwrap(CloudPCMTransportFrame.decode(
                traceFrame(sequence: sequence, source: source, relay: relay))?.trace)
        }
        var upstream = CloudPCMTransportDiagnostics()
        _ = upstream.record(try trace(1, 1_000, 9_000), receivedMonoMS: 10_000, receivedUnixMS: 999_000)
        _ = upstream.record(try trace(2, 1_020, 9_420), receivedMonoMS: 10_420, receivedUnixMS: 999_420)
        let upstreamWindow = upstream.takeWindow()
        XCTAssertEqual(upstreamWindow["rx_source_gap_max_ms"], "20")
        XCTAssertEqual(upstreamWindow["rx_upstream_excess_max_ms"], "400")
        XCTAssertEqual(upstreamWindow["rx_downstream_excess_max_ms"], "0")

        var downstream = CloudPCMTransportDiagnostics()
        _ = downstream.record(try trace(1, 1_000, 9_000), receivedMonoMS: 10_000, receivedUnixMS: 999_000)
        _ = downstream.record(try trace(2, 1_020, 9_020), receivedMonoMS: 10_620, receivedUnixMS: 999_620)
        let downstreamWindow = downstream.takeWindow()
        XCTAssertEqual(downstreamWindow["rx_upstream_excess_max_ms"], "0")
        XCTAssertEqual(downstreamWindow["rx_downstream_excess_max_ms"], "600")
    }

    func testCloudPCMTraceTracksSequenceWrapAndResetsOnlyWindowMaxima() throws {
        func trace(_ sequence: UInt32, _ time: UInt64) throws -> CloudPCMTransportFrame.Trace {
            try XCTUnwrap(CloudPCMTransportFrame.decode(
                traceFrame(sequence: sequence, source: time, relay: time + 8_000))?.trace)
        }
        var stats = CloudPCMTransportDiagnostics()
        XCTAssertNotNil(stats.record(try trace(UInt32.max, 1_000), receivedMonoMS: 5_000, receivedUnixMS: 80_000))
        XCTAssertNil(stats.record(try trace(0, 1_020), receivedMonoMS: 5_020, receivedUnixMS: 80_020))
        _ = stats.record(try trace(3, 1_080), receivedMonoMS: 5_080, receivedUnixMS: 80_080)
        let first = stats.takeWindow()
        XCTAssertEqual(first["rx_wire_seq_missing"], "2")
        XCTAssertEqual(first["rx_wire_seq_reordered"], "0")
        XCTAssertEqual(first["rx_source_gap_max_ms"], "60")
        _ = stats.record(try trace(4, 1_100), receivedMonoMS: 5_100, receivedUnixMS: 80_100)
        let second = stats.takeWindow()
        XCTAssertEqual(second["rx_wire_seq_missing"], "2")
        XCTAssertEqual(second["rx_trace_frames"], "4")
        XCTAssertEqual(second["rx_source_gap_max_ms"], "20")
    }

    func testOldEndedHistoryCannotFinishANewSystemCall() {
        XCTAssertTrue(CallKitSynchronizationPolicy.mayFinishEndedHistory(currentBackendID: "a", endedID: "a"))
        XCTAssertFalse(CallKitSynchronizationPolicy.mayFinishEndedHistory(currentBackendID: "b", endedID: "a"))
        XCTAssertFalse(CallKitSynchronizationPolicy.mayFinishEndedHistory(currentBackendID: nil, endedID: "a"))
    }

    func testRetiredAgentCallCannotBypassEndIntentWithSynthesizedUUID() {
        var store = CallLifecycleStore()
        let original = UUID()
        let now = Date()
        func event(_ id: String, _ uuid: UUID, _ state: CallLifecycleState) -> CallLifecycleEvent {
            .init(callID: id, callUUID: uuid, generation: 1, state: state,
                  source: .agent, timestamp: now, traceID: nil, failure: nil)
        }
        XCTAssertTrue(store.apply(event("a", original, .active)))
        XCTAssertTrue(store.apply(event("a", original, .ended)))
        XCTAssertTrue(store.apply(event("b", UUID(), .ringing)))
        let b = try! XCTUnwrap(store.snapshot.callUUID)
        XCTAssertTrue(store.apply(event("b", b, .ended)))
        XCTAssertFalse(store.apply(event("a", UUID(), .ringing)))
        XCTAssertTrue(store.apply(event("c", UUID(), .ringing)))
    }

    @MainActor
    func testCancelledCloudDialDiscardsLateCallInsteadOfAdoptingIt() async {
        var current = true
        var completion: CheckedContinuation<String, Error>?
        var discarded: [String] = []
        let started = expectation(description: "dial submitted")
        let task = Task { @MainActor in
            do {
                _ = try await OutgoingCallRouteCoordinator.start(
                    number: "test", vowlanService: nil, cloudModeEnabled: true,
                    isCurrent: { current }, discardCloud: { discarded.append($0) }
                ) {
                    try await withCheckedThrowingContinuation { continuation in
                        completion = continuation; started.fulfill()
                    }
                }
                XCTFail("cancelled outgoing call must not be adopted")
            } catch is CancellationError { }
            catch { XCTFail("unexpected error: \(error)") }
        }
        await fulfillment(of: [started], timeout: 2)
        current = false
        completion?.resume(returning: "late-call")
        await task.value
        XCTAssertEqual(discarded, ["late-call"])
    }

    func testCloudPCMResamplerRejectsAliasedHighFrequencyNoise() {
        for rate in [44_100.0, 48_000.0] {
            let speech = cloudPCMTone(frequency: 1_000, sampleRate: rate)
            XCTAssertGreaterThan(cloudPCMRMS(speech), 0.30, "Keep speech energy at \(rate) Hz")
            for frequency in [5_500.0, 7_000.0, 10_000.0] {
                let noise = cloudPCMTone(frequency: frequency, sampleRate: rate)
                XCTAssertLessThan(cloudPCMRMS(noise), cloudPCMRMS(speech) * 0.01,
                                  "Suppress out-of-band noise before downsampling: \(frequency) Hz")
            }
        }
    }

    func testCloudPCMResamplerKeepsFilterContinuousBetweenMicrophoneBuffers() {
        let rate = 48_000.0
        let input = (0..<24_000).map { index in
            Float(0.5 * sin(2 * Double.pi * 1_300 * Double(index) / rate))
        }
        var whole = CloudPCMResampler()
        let expected = whole.encode(samples: input, sampleRate: rate, muted: false)
        var chunked = CloudPCMResampler()
        var actual = Data()
        for offset in stride(from: 0, to: input.count, by: 480) {
            actual.append(chunked.encode(samples: Array(input[offset..<min(offset + 480, input.count)]),
                                         sampleRate: rate, muted: false))
        }
        XCTAssertEqual(actual, expected, "Callback boundaries must not reset the filter or click")
        XCTAssertGreaterThan(actual.count, 7_600, "Conversion must keep pace with captured speech")
    }

    func testCloudPCMResamplerMutesAndClearsFilterWhenInputRouteChanges() {
        var resampler = CloudPCMResampler()
        let tone = (0..<4_800).map { index in
            Float(0.5 * sin(2 * Double.pi * 1_000 * Double(index) / 48_000))
        }
        _ = resampler.encode(samples: tone, sampleRate: 48_000, muted: false)
        let muted = resampler.encode(samples: tone, sampleRate: 48_000, muted: true)
        XCTAssertFalse(muted.isEmpty)
        XCTAssertTrue(muted.allSatisfy { $0 == 0 }, "Mute must silence even filter history")
        let changedRoute = resampler.encode(samples: [Float](repeating: 0, count: 4_410),
                                            sampleRate: 44_100, muted: false)
        XCTAssertFalse(changedRoute.isEmpty)
        XCTAssertTrue(changedRoute.allSatisfy { $0 == 0 }, "No old-route audio may leak after a rate change")
    }

    private func cloudPCMTone(frequency: Double, sampleRate: Double) -> Data {
        var resampler = CloudPCMResampler()
        var result = Data()
        let count = Int(sampleRate)
        let frameSize = Int(sampleRate / 50)
        for offset in stride(from: 0, to: count, by: frameSize) {
            let input = (offset..<min(offset + frameSize, count)).map { index in
                Float(0.5 * sin(2 * Double.pi * frequency * Double(index) / sampleRate))
            }
            result.append(resampler.encode(samples: input, sampleRate: sampleRate, muted: false))
        }
        return result
    }

    private func cloudPCMRMS(_ pcm: Data) -> Double {
        let bytes = [UInt8](pcm)
        // Ignore startup and the final filter tail; measure steady-state PCM.
        let lower = min(800, bytes.count / 2), upper = bytes.count / 2 - 400
        guard upper > lower else { return .infinity }
        var sum = 0.0
        for index in lower..<upper {
            let bits = UInt16(bytes[index * 2]) | UInt16(bytes[index * 2 + 1]) << 8
            let value = Double(Int16(bitPattern: bits)) / 32_768
            sum += value * value
        }
        return sqrt(sum / Double(upper - lower))
    }

    func testCloudNativeTimePitchPreservesPitchWithBoundedCompletionFedBuffers() throws {
        let normal = try renderCloudTone(rate: 1)
        let faster = try renderCloudTone(rate: 1.04, window: 4)
        XCTAssertEqual(normal.completed, 200)
        XCTAssertEqual(faster.completed, 200)
        XCTAssertLessThanOrEqual(normal.maximumPending, 2)
        XCTAssertLessThanOrEqual(faster.maximumPending, 4)
        func lastAudible(_ samples: [Float]) -> Int {
            samples.lastIndex(where: { abs($0) > 0.01 }) ?? 0
        }
        let recovered = Double(lastAudible(normal.samples) - lastAudible(faster.samples)) / 8_000
        XCTAssertGreaterThan(recovered, 0.10, "Measure final output, including the processor tail")
        XCTAssertLessThan(recovered, 0.24)
        for samples in [normal.samples, faster.samples] {
            let section = Array(samples[4_000..<20_000])
            let crossings = zip(section, section.dropFirst()).filter { $0 <= 0 && $1 > 0 }.count
            XCTAssertEqual(Double(crossings) / 2, 440, accuracy: 2, "Pitch must not rise with playback rate")
            for offset in stride(from: 4_000, to: 20_000, by: 160) {
                let energy = samples[offset..<(offset + 160)].reduce(0.0) { $0 + Double($1 * $1) } / 160
                XCTAssertGreaterThan(energy, 0.01, "Completion-driven refill must not introduce silent blocks")
            }
        }
    }

    /// Real AVAudioEngine output; callbacks refill immediately on a serial media
    /// queue, with the production two/four buffer cap and no polling refill.
    private func renderCloudTone(rate: Float, window: Int = 2) throws -> (samples: [Float], completed: Int, maximumPending: Int) {
        let format = AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1)!
        let engine = AVAudioEngine(), player = AVAudioPlayerNode(), pitch = AVAudioUnitTimePitch()
        engine.attach(player)
        engine.attach(pitch)
        pitch.pitch = 0
        pitch.rate = rate
        engine.connect(player, to: pitch, format: format)
        engine.connect(pitch, to: engine.mainMixerNode, format: format)
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 160)
        try engine.start()
        defer { engine.stop() }
        player.play()
        let queue = DispatchQueue(label: "com.example.airsim.test-time-pitch")
        var nextPacket = 0, completed = 0, maximumPending = 0
        func feed() {
            while nextPacket - completed < window, nextPacket < 200 {
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160)!
                buffer.frameLength = 160
                for i in 0..<160 {
                    buffer.floatChannelData![0][i] = Float(sin(2 * .pi * 440 * Double(nextPacket * 160 + i) / 8_000)) * 0.3
                }
                nextPacket += 1
                maximumPending = max(maximumPending, nextPacket - completed)
                player.scheduleBuffer(buffer, completionCallbackType: .dataRendered) { _ in
                    queue.async {
                        completed += 1
                        feed()
                    }
                }
            }
        }
        queue.sync { feed() }
        let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160)!
        var samples: [Float] = []
        for _ in 0..<240 {
            XCTAssertEqual(try engine.renderOffline(160, to: output), .success)
            samples.append(contentsOf: UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
            // Give asynchronous completion delivery real audio cadence. This is
            // an offline graph and never selects or records a physical device.
            Thread.sleep(forTimeInterval: 0.02)
        }
        return queue.sync { (samples, completed, maximumPending) }
    }

    func testCloudContinuousVoicedWaveformRecoversAtFinalEngineOutput() throws {
        let reference = try renderCloudRecovery(accelerate: false)
        let recovered = try renderCloudRecovery(accelerate: true)
        let renewed = try renderCloudRecovery(accelerate: true, renewedStall: true)
        let referenceEnd = Double(reference.samples.lastIndex(where: { abs($0) > 0.01 }) ?? 0) / 8_000
        for result in [recovered, renewed] {
            XCTAssertTrue(result.sequences == (0..<2_750).map(UInt32.init), "Source frames must be scheduled in order")
            XCTAssertTrue(result.completedSequences.sorted() == (0..<2_750).map(UInt32.init), "Every real frame must complete once")
            XCTAssertEqual(result.dropped, 0)
            XCTAssertEqual(result.compacted, 0, "Fixture is continuously voiced, not digital silence")
            XCTAssertEqual(result.underruns, reference.underruns)
            XCTAssertEqual(result.maximumPending, 4)
            XCTAssertEqual(result.finalLimit, 2, "Return to the normal window without flushing")
            XCTAssertEqual(result.maximumRate, 1.04, accuracy: 0.0001)
            let end = Double(result.samples.lastIndex(where: { abs($0) > 0.01 }) ?? 0) / 8_000
            XCTAssertLessThan(end, referenceEnd - 0.7, "Final waveform must recover latency, including processor tail")
            XCTAssertLessThan(end - 55, 0.4)
            for offset in stride(from: 5 * 8_000, to: 54 * 8_000, by: 160) {
                let energy = result.samples[offset..<(offset + 160)].reduce(0.0) { $0 + Double($1 * $1) } / 160
                XCTAssertGreaterThan(energy, 0.001, "No new silent block after the first unseen stall at \(Double(offset) / 8_000)s")
            }
            print("CLOUD_WAVEFORM finalOutputS=\(end) referenceOutputS=\(referenceEnd) underruns=\(result.underruns) maxPending=\(result.maximumPending) allFrames=\(result.sequences.count)")
        }
        XCTAssertTrue(renewed.stoppedOnRenewedStall)
    }

    private struct CloudWaveformResult {
        var samples: [Float]
        var sequences: [UInt32]
        var completedSequences: [UInt32]
        var dropped: UInt64
        var compacted: UInt64
        var underruns: UInt64
        var maximumPending: Int
        var finalLimit: Int
        var maximumRate: Double
        var stoppedOnRenewedStall: Bool
    }

    /// Actual iOS AVAudioEngine output and production playout state. Source is
    /// 55 seconds of continuous varying-F0 harmonics with a nonzero envelope.
    /// The virtual 20ms clock controls arrival; real callbacks refill the player.
    private func renderCloudRecovery(accelerate: Bool, renewedStall: Bool = false) throws -> CloudWaveformResult {
        let count = 2_750
        var source: [Data] = [], phase = 0.0
        for packet in 0..<count {
            var data = Data()
            for i in 0..<160 {
                let time = Double(packet * 160 + i) / 8_000
                let f0 = 170 + 24 * sin(2 * .pi * 0.31 * time) + 7 * sin(2 * .pi * 0.83 * time)
                phase += 2 * .pi * f0 / 8_000
                let envelope = 0.25 + 0.05 * sin(2 * .pi * 1.7 * time)
                let value = envelope * (sin(phase) + 0.35 * sin(2 * phase + 0.2) + 0.16 * sin(3 * phase + 0.7))
                let sample = UInt16(bitPattern: Int16(value * 32_767))
                data.append(UInt8(truncatingIfNeeded: sample))
                data.append(UInt8(truncatingIfNeeded: sample >> 8))
            }
            source.append(data)
        }
        let format = AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1)!
        let engine = AVAudioEngine(), player = AVAudioPlayerNode(), pitch = AVAudioUnitTimePitch()
        engine.attach(player)
        if accelerate {
            engine.attach(pitch)
            pitch.pitch = 0
            pitch.rate = 1
            engine.connect(player, to: pitch, format: format)
            engine.connect(pitch, to: engine.mainMixerNode, format: format)
        } else {
            engine.connect(player, to: engine.mainMixerNode, format: format)
        }
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 160)
        try engine.start()
        defer { engine.stop() }
        player.play()
        let queue = DispatchQueue(label: "com.example.airsim.test-waveform")
        var playout = CloudPCMPlayoutBuffer(), now = 0.0, delivered = 0
        var sequences: [UInt32] = [], completedSequences: [UInt32] = []
        var maximumRate = 1.0, stoppedOnRenewedStall = false
        func schedule(_ frames: [CloudPCMBufferedFrame]) {
            if pitch.rate != Float(playout.playbackRate) { pitch.rate = Float(playout.playbackRate) }
            maximumRate = max(maximumRate, playout.playbackRate)
            for frame in frames {
                if frame.receivedAt != nil { sequences.append(frame.sequence) }
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160)!
                buffer.frameLength = 160
                for i in 0..<160 {
                    let bits = UInt16(frame.pcm[i * 2]) | UInt16(frame.pcm[i * 2 + 1]) << 8
                    buffer.floatChannelData![0][i] = Float(Int16(bitPattern: bits)) / 32_768
                }
                player.scheduleBuffer(buffer, completionCallbackType: .dataRendered) { _ in
                    queue.async {
                        // A render quantum can complete several buffers, and the
                        // native callbacks need not be delivered in source order.
                        if frame.receivedAt != nil { completedSequences.append(frame.sequence) }
                        schedule(playout.rendered(at: accelerate ? now : nil))
                    }
                }
            }
        }
        var samples: [Float] = []
        let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160)!
        for block in 0..<(count + 160) {
            queue.sync {
                now = Double(block) * 0.02
                while delivered < count {
                    let time = Double(delivered) * 0.02
                    var arrival = (2..<3.052).contains(time) ? 3.052 : time
                    if renewedStall, (24..<24.6).contains(time) { arrival = 24.6 }
                    if arrival > now + 0.00001 { break }
                    playout.enqueue(sequence: UInt32(delivered), pcm: source[delivered],
                                    arrivedAt: Date(timeIntervalSince1970: now))
                    delivered += 1
                    schedule(playout.refill(at: accelerate ? now : nil))
                }
                if delivered < count || playout.jitter.bufferedFrameCount > 0 {
                    schedule(playout.refill(allowConcealment: true, at: accelerate ? now : nil))
                }
                if renewedStall, (24.06..<24.6).contains(now), playout.playbackRate == 1 {
                    stoppedOnRenewedStall = true
                }
            }
            XCTAssertEqual(try engine.renderOffline(160, to: output), .success)
            samples.append(contentsOf: UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
            // Keep real callback cadence. Running virtual audio ten times faster
            // than wall time can starve asynchronous callbacks under host load.
            Thread.sleep(forTimeInterval: 0.02)
        }
        return queue.sync {
            CloudWaveformResult(samples: samples, sequences: sequences,
                                completedSequences: completedSequences, dropped: playout.jitter.droppedFrameCount,
                                compacted: playout.jitter.silenceCompactedFrames,
                                underruns: playout.jitter.underrunCount,
                                maximumPending: playout.maximumScheduledPackets,
                                finalLimit: playout.window.packetLimit, maximumRate: maximumRate,
                                stoppedOnRenewedStall: stoppedOnRenewedStall)
        }
    }

    func testCloudSpeechRateRecoversTransientBacklogWithoutDeletingFrames() {
        let delivery: (Int) -> Int = { sequence in
            let source = sequence * 20
            return (2_000..<3_052).contains(source) ? 3_052 : source
        }
        let reference = replayCloudDownlink(count: 3_000, delivery: delivery)
        let faster = replayCloudDownlink(count: 3_000, accelerate: true, delivery: delivery)
        XCTAssertEqual(faster.renderedSequences, (0..<3_000).map(UInt32.init))
        XCTAssertEqual(faster.dropped, 0)
        XCTAssertEqual(faster.silenceCompacted, 0)
        XCTAssertEqual(faster.underruns, reference.underruns)
        XCTAssertLessThan(faster.lateMaximumDelayMS, 220)
        XCTAssertGreaterThan(reference.lateMaximumDelayMS - faster.lateMaximumDelayMS, 800)
    }

    func testCloudSpeechRateKeepsRepeatedStallProtection() {
        for stallMS in [600, 850, 1_052] {
            let result = replayCloudDownlink(count: 2_000, accelerate: true) { sequence in
                let source = sequence * 20, phase = source % 4_000
                return (2_000..<(2_000 + stallMS)).contains(phase)
                    ? source - phase + 2_000 + stallMS : source
            }
            XCTAssertEqual(result.renderedSequences, (0..<2_000).map(UInt32.init))
            XCTAssertEqual(result.dropped, 0)
            XCTAssertEqual(result.underruns, 3)
            XCTAssertLessThanOrEqual(result.maximumBuffered, 90)
        }
    }

    func testCloudPlaybackWindowDrainsAcceleratedReservationsWithoutDiscarding() {
        var window = CloudPCMPlaybackWindow()
        window.setAccelerated(true)
        for _ in 0..<4 { window.schedulePacket() }
        window.setAccelerated(false)
        XCTAssertEqual(window.scheduledPackets, 4)
        XCTAssertEqual(window.availablePackets, 0)
        window.didRenderPacket()
        XCTAssertEqual(window.availablePackets, 0)
        window.didRenderPacket()
        XCTAssertEqual(window.availablePackets, 0)
        window.didRenderPacket()
        XCTAssertEqual(window.availablePackets, 1)
    }

    func testCloudSpeechRateToleratesMonotonicDateRoundTrip() {
        var controller = CloudPCMPlaybackRateController()
        for i in 0..<20 {
            let now = 15 + Double(i) * 0.02
            controller.update(at: now, queuedAfterRefill: 20, target: 4,
                              lastArrival: Date(timeIntervalSince1970: now).timeIntervalSince1970,
                              recovering: false)
        }
        XCTAssertEqual(controller.rate, 1.04, accuracy: 0.00001)
    }

    func testCloudSpeechRateStopsAtReserveAndWhenArrivalsStall() {
        var controller = CloudPCMPlaybackRateController()
        for i in 0..<20 {
            let now = Double(i) * 0.02
            controller.update(at: now, queuedAfterRefill: 20, target: 4,
                              lastArrival: now, recovering: false)
        }
        XCTAssertEqual(controller.rate, 1.04, accuracy: 0.00001)
        controller.update(at: 0.40, queuedAfterRefill: 6, target: 4, lastArrival: 0.40, recovering: false)
        XCTAssertEqual(controller.rate, 1)
        controller.update(at: 0.42, queuedAfterRefill: 7, target: 4, lastArrival: 0.42, recovering: false)
        XCTAssertEqual(controller.rate, 1, "Hysteresis requires four excess frames to restart")
        controller.update(at: 0.44, queuedAfterRefill: 20, target: 4, lastArrival: 0.44, recovering: false)
        XCTAssertGreaterThan(controller.rate, 1)
        controller.update(at: 0.50, queuedAfterRefill: 20, target: 4, lastArrival: 0.44, recovering: false)
        XCTAssertEqual(controller.rate, 1, "Stop before the transport's 80ms stall threshold")
        controller.update(at: 0.52, queuedAfterRefill: 20, target: 4, lastArrival: 0.52, recovering: true)
        XCTAssertEqual(controller.rate, 1)
        controller.update(at: nil, queuedAfterRefill: 20, target: 4, lastArrival: 0.52, recovering: false)
        XCTAssertEqual(controller.rate, 1, "Unknown time never authorizes acceleration")
    }

    func testCloudSpeechRateAndSilenceCompactionDoNotSpendReserveTogether() {
        var playout = CloudPCMPlayoutBuffer()
        for i in 0..<40 {
            playout.enqueue(sequence: UInt32(i), pcm: Data(repeating: 0, count: 320),
                            arrivedAt: Date(timeIntervalSince1970: 1))
        }
        _ = playout.refill(at: 1)
        for _ in 0..<15 { _ = playout.rendered(at: 1.02) }
        XCTAssertGreaterThan(playout.playbackRate, 1)
        XCTAssertEqual(playout.jitter.silenceCompactedFrames, 0)
        XCTAssertGreaterThanOrEqual(playout.jitter.bufferedFrameCount, playout.jitter.targetFrameCount + 2)
    }

    func testCloudStallReserveHoldsForTenSecondsOnArrivalClock() {
        var buffer = CloudPCMAdaptiveJitterBuffer()
        let epoch = Date(timeIntervalSince1970: 10)
        buffer.enqueue(sequence: 0, pcm: Data(repeating: 1, count: 320), arrivedAt: epoch)
        buffer.enqueue(sequence: 1, pcm: Data(repeating: 1, count: 320), arrivedAt: epoch.addingTimeInterval(1))
        let learned = buffer.targetFrameCount
        for i in 2..<452 {
            buffer.enqueue(sequence: UInt32(i), pcm: Data(repeating: 1, count: 320),
                           arrivedAt: epoch.addingTimeInterval(1 + Double(i - 1) * 0.02))
            _ = buffer.dequeue(maxFrames: 1)
        }
        XCTAssertEqual(buffer.targetFrameCount, learned, "Nine regular seconds do not spend learned reserve")
        for i in 452..<752 {
            buffer.enqueue(sequence: UInt32(i), pcm: Data(repeating: 1, count: 320),
                           arrivedAt: epoch.addingTimeInterval(1 + Double(i - 1) * 0.02))
            _ = buffer.dequeue(maxFrames: 1)
        }
        XCTAssertLessThan(buffer.targetFrameCount, learned)
    }

    func testCloudDownlinkPreservesSpeechAcrossRepeatedObservedStalls() {
        for stallMS in [600, 850, 1_052] {
            let result = replayCloudDownlink(count: 1_000) { sequence in
                let sourceMS = sequence * 20
                let phase = sourceMS % 4_000
                return phase >= 2_000 && phase < 2_000 + stallMS
                    ? sourceMS - phase + 2_000 + stallMS : sourceMS
            }
            XCTAssertEqual(result.renderedSequences, (0..<1_000).map(UInt32.init),
                           "Every real frame must survive once and in order across a \(stallMS) ms burst")
            XCTAssertEqual(result.dropped, 0)
            XCTAssertEqual(result.underruns, 3, "Only the first unseen stall may exhaust the reserve")
            XCTAssertLessThanOrEqual(result.maximumBuffered, 90)
            XCTAssertLessThanOrEqual(result.maximumDelayMS, stallMS + 100)
        }
    }

    func testCloudDownlinkSteadyStreamKeepsLowLatency() {
        let result = replayCloudDownlink(count: 500) { $0 * 20 }
        XCTAssertEqual(result.renderedSequences, (0..<500).map(UInt32.init))
        XCTAssertEqual(result.dropped, 0)
        XCTAssertEqual(result.underruns, 0)
        XCTAssertEqual(result.maximumDelayMS, 80)
    }

    func testCloudDownlinkExcessiveStallRemainsBoundedAndAccounted() {
        let result = replayCloudDownlink(count: 500) { sequence in
            let sourceMS = sequence * 20
            return (2_000..<4_500).contains(sourceMS) ? 4_500 : sourceMS
        }
        XCTAssertGreaterThan(result.dropped, 0, "Beyond-budget backlog cannot grow indefinitely")
        XCTAssertLessThanOrEqual(result.maximumBuffered, 90)
        XCTAssertEqual(UInt64(result.renderedSequences.count) + result.dropped, 500)
        XCTAssertEqual(result.renderedSequences, result.renderedSequences.sorted())
        XCTAssertEqual(Set(result.renderedSequences).count, result.renderedSequences.count)
    }

    func testCloudDownlinkSustainedClockMismatchStaysBounded() {
        let faster = replayCloudDownlink(count: 2_500) { $0 * 19 }
        XCTAssertLessThanOrEqual(faster.maximumBuffered, 90)
        XCTAssertGreaterThan(faster.dropped, 0)
        XCTAssertEqual(UInt64(faster.renderedSequences.count) + faster.dropped, 2_500)
        XCTAssertEqual(faster.renderedSequences, faster.renderedSequences.sorted())

        let slower = replayCloudDownlink(count: 2_500) { $0 * 21 }
        XCTAssertLessThanOrEqual(slower.maximumBuffered, 90)
        XCTAssertEqual(slower.renderedSequences, (0..<2_500).map(UInt32.init))
        XCTAssertEqual(slower.dropped, 0)
        XCTAssertGreaterThan(slower.underruns, 0)
        // A local cap cannot bound accumulated age at a slower upstream sender.
        XCTAssertGreaterThan(slower.maximumDelayMS, 2_000)
    }

    func testCloudDownlinkPreservesOrderingAcrossSequenceWrap() {
        var buffer = CloudPCMAdaptiveJitterBuffer()
        let start = UInt32.max - 2
        for offset in 0..<5 {
            buffer.enqueue(sequence: start &+ UInt32(offset), pcm: Data(repeating: 1, count: 320),
                           arrivedAt: Date(timeIntervalSince1970: 0))
        }
        XCTAssertEqual(buffer.dequeue(maxFrames: 5).map(\.sequence),
                       (0..<5).map { start &+ UInt32($0) })
        XCTAssertEqual(buffer.droppedFrameCount, 0)
        for offset in 5..<105 {
            buffer.enqueue(sequence: start &+ UInt32(offset), pcm: Data(repeating: 1, count: 320),
                           arrivedAt: Date(timeIntervalSince1970: 1))
        }
        XCTAssertEqual(buffer.dequeue(maxFrames: 1).first?.sequence, start &+ 15)
        XCTAssertEqual(buffer.overflowDropCount, 10)
    }

    func testCloudDownlinkSeparatesDropReasonsAndKeepsLearnedReserve() {
        var buffer = CloudPCMAdaptiveJitterBuffer()
        let epoch = Date(timeIntervalSince1970: 0)
        for sequence in 0..<4 {
            buffer.enqueue(sequence: UInt32(sequence), pcm: Data(repeating: 1, count: 320), arrivedAt: epoch)
        }
        buffer.enqueue(sequence: 0, pcm: Data(repeating: 1, count: 320), arrivedAt: epoch)
        _ = buffer.dequeue(maxFrames: 4)
        buffer.enqueue(sequence: 0, pcm: Data(repeating: 1, count: 320), arrivedAt: epoch)
        buffer.enqueue(sequence: 4, pcm: Data(repeating: 1, count: 320),
                       arrivedAt: epoch.addingTimeInterval(1.052))
        XCTAssertEqual(buffer.duplicateDropCount, 1)
        XCTAssertEqual(buffer.lateDropCount, 1)
        XCTAssertEqual(buffer.overflowDropCount, 0)
        let learned = buffer.targetFrameCount
        XCTAssertGreaterThan(learned, 50)
        buffer.notePlaybackUnderrun()
        XCTAssertGreaterThanOrEqual(buffer.targetFrameCount, learned)
        XCTAssertLessThanOrEqual(buffer.targetFrameCount, 60)
    }

    private struct CloudReplayMetrics {
        var renderedSequences: [UInt32]
        var dropped: UInt64
        var underruns: UInt64
        var maximumBuffered: Int
        var maximumDelayMS: Int
        var lateMaximumDelayMS: Int
        var silenceCompacted: UInt64
    }

    /// Simulates ordered transport delivery and real 20 ms render completions.
    /// Stall sizes come from logs; individual frame arrivals are synthetic.
    private func replayCloudDownlink(
        count: Int,
        payload: (Int) -> Data = { _ in Data(repeating: 1, count: 320) },
        sourceTime: (Int) -> Int = { $0 * 20 },
        accelerate: Bool = false,
        delivery: (Int) -> Int
    ) -> CloudReplayMetrics {
        var playout = CloudPCMPlayoutBuffer()
        let arrivals = Dictionary(grouping: 0..<count, by: delivery)
        var rendered: [UInt32] = []
        var scheduled: [(time: Double, sequence: UInt32, real: Bool)] = []
        var maximumBuffered = 0, maximumDelayMS = 0, lateMaximumDelayMS = 0
        func schedule(_ frames: [CloudPCMBufferedFrame], at time: Double, synthetic: Bool = false) {
            for frame in frames {
                let due = max(time, scheduled.last?.time ?? time) + 20 / playout.playbackRate
                scheduled.append((due, frame.sequence, !synthetic))
            }
        }
        let end = max(count * 20, arrivals.keys.max() ?? 0) + 4_000
        for time in 0...end {
            for sequence in arrivals[time] ?? [] {
                playout.enqueue(sequence: UInt32(sequence), pcm: payload(sequence),
                                arrivedAt: Date(timeIntervalSince1970: Double(time) / 1_000))
                schedule(playout.refill(at: accelerate ? Double(time) / 1_000 : nil), at: Double(time))
                maximumBuffered = max(maximumBuffered, playout.jitter.bufferedFrameCount)
            }
            while let first = scheduled.first, first.time <= Double(time) {
                scheduled.removeFirst()
                if first.real {
                    rendered.append(first.sequence)
                    let delay = Int(ceil(first.time)) - sourceTime(Int(first.sequence))
                    maximumDelayMS = max(maximumDelayMS, delay)
                    if first.sequence >= UInt32(max(0, count - 50)) {
                        lateMaximumDelayMS = max(lateMaximumDelayMS, delay)
                    }
                }
                schedule(playout.rendered(at: accelerate ? Double(time) / 1_000 : nil), at: first.time)
            }
            if time % 20 == 0, rendered.count + Int(playout.jitter.silenceCompactedFrames) < count {
                let before = playout.jitter.concealedFrameCount
                let frames = playout.refill(allowConcealment: true, at: accelerate ? Double(time) / 1_000 : nil)
                let synthetic = playout.jitter.concealedFrameCount > before
                schedule(frames, at: Double(time), synthetic: synthetic)
            }
        }
        return .init(renderedSequences: rendered, dropped: playout.jitter.droppedFrameCount,
                     underruns: playout.jitter.underrunCount, maximumBuffered: maximumBuffered,
                     maximumDelayMS: maximumDelayMS, lateMaximumDelayMS: lateMaximumDelayMS,
                     silenceCompacted: playout.jitter.silenceCompactedFrames)
    }

    func testCloudSilenceRecoveryLowersExcessLatencyWithoutLosingSpeech() {
        let silent = 5..<200
        let result = replayCloudDownlink(count: 500, payload: {
            Data(repeating: silent.contains($0) ? 0 : 1, count: 320)
        }, sourceTime: { ($0 - 19) * 20 }) { max(0, ($0 - 19) * 20) }
        let speech = (0..<500).filter { !silent.contains($0) }.map(UInt32.init)
        XCTAssertEqual(result.renderedSequences.filter { !silent.contains(Int($0)) }, speech)
        XCTAssertGreaterThan(result.silenceCompacted, 0)
        XCTAssertEqual(UInt64(result.renderedSequences.count) + result.silenceCompacted, 500)
        XCTAssertEqual(result.dropped, 0)
        XCTAssertEqual(result.underruns, 0)
        XCTAssertEqual(result.maximumDelayMS, 400)
        XCTAssertLessThanOrEqual(result.lateMaximumDelayMS, 140)
    }

    func testCloudSilenceCompactionRetainsProtectionAgainstRepeatedStalls() {
        for stallMS in [600, 850, 1_052] {
            let result = replayCloudDownlink(count: 1_000, payload: { sequence in
                Data(repeating: sequence % 100 < 50 ? 0 : 1, count: 320)
            }) { sequence in
                let sourceMS = sequence * 20, phase = sourceMS % 4_000
                return (2_000..<(2_000 + stallMS)).contains(phase)
                    ? sourceMS - phase + 2_000 + stallMS : sourceMS
            }
            XCTAssertEqual(result.dropped, 0)
            XCTAssertEqual(result.underruns, 3)
            XCTAssertEqual(UInt64(result.renderedSequences.count) + result.silenceCompacted, 1_000)
            XCTAssertEqual(result.renderedSequences.filter { $0 % 100 >= 50 },
                           (0..<1_000).map(UInt32.init).filter { $0 % 100 >= 50 })
        }
    }

    func testCloudCompactionPreservesNonzeroPCMAndSilenceBoundaries() {
        var buffer = CloudPCMAdaptiveJitterBuffer()
        let epoch = Date(timeIntervalSince1970: 12)
        let payloads = (0..<40).map { sequence in
            Data(repeating: (5..<30).contains(sequence) ? 0 : UInt8(sequence + 1), count: 320)
        }
        for sequence in payloads.indices {
            buffer.enqueue(sequence: UInt32(sequence), pcm: payloads[sequence], arrivedAt: epoch)
        }
        var rendered: [CloudPCMBufferedFrame] = []
        while buffer.bufferedFrameCount > 0 {
            rendered += buffer.dequeue(maxFrames: 2, concealIfEmpty: false)
        }
        let sequences = rendered.map { Int($0.sequence) }
        XCTAssertEqual(sequences, sequences.sorted())
        XCTAssertEqual(Set(sequences).count, sequences.count)
        XCTAssertEqual(sequences.filter { !(5..<30).contains($0) }, Array(0..<5) + Array(30..<40))
        XCTAssertTrue(sequences.contains(5))
        XCTAssertTrue(sequences.contains(29))
        for frame in rendered {
            XCTAssertEqual(frame.pcm, payloads[Int(frame.sequence)])
            XCTAssertEqual(frame.receivedAt, 12)
        }
        XCTAssertGreaterThan(buffer.silenceCompactedFrames, 0)
        XCTAssertEqual(UInt64(rendered.count) + buffer.silenceCompactedFrames, 40)
        XCTAssertEqual(buffer.droppedFrameCount, 0)
    }

    func testCloudCompactionNeverTreatsQuietSpeechAsDigitalSilence() {
        for value: UInt8 in [1, 255] {
            var buffer = CloudPCMAdaptiveJitterBuffer()
            for sequence in 0..<40 {
                var pcm = Data(repeating: 0, count: 320)
                pcm[160] = value // Even a single nonzero sample must survive.
                buffer.enqueue(sequence: UInt32(sequence), pcm: pcm, arrivedAt: Date())
            }
            XCTAssertEqual(buffer.dequeue(maxFrames: 40, concealIfEmpty: false).map(\.sequence),
                           (0..<40).map(UInt32.init))
            XCTAssertEqual(buffer.silenceCompactedFrames, 0)
        }
    }

    func testCloudCompactionRespectsReserveAndPlayerCapacity() {
        var playout = CloudPCMPlayoutBuffer()
        let epoch = Date(timeIntervalSince1970: 0)
        for sequence in 0..<20 {
            playout.enqueue(sequence: UInt32(sequence), pcm: Data(repeating: 0, count: 320), arrivedAt: epoch)
        }
        _ = playout.refill()
        for _ in 0..<6 { _ = playout.rendered() }
        let count = playout.jitter.silenceCompactedFrames
        for _ in 0..<100 { XCTAssertTrue(playout.refill().isEmpty) }
        XCTAssertEqual(playout.jitter.silenceCompactedFrames, count)
        XCTAssertEqual(playout.window.scheduledPackets, 2)

        var buffer = CloudPCMAdaptiveJitterBuffer()
        for sequence in 0..<10 {
            buffer.enqueue(sequence: UInt32(sequence), pcm: Data(repeating: 0, count: 320), arrivedAt: epoch)
        }
        _ = buffer.dequeue(maxFrames: 5, concealIfEmpty: false)
        _ = buffer.dequeue(maxFrames: 1, concealIfEmpty: false)
        XCTAssertEqual(buffer.silenceCompactedFrames, 0, "Keep all four reserve frames after scheduling")
    }

    func testCloudCompactionHandlesWrapAndDoesNotCrossMissingFrames() {
        var buffer = CloudPCMAdaptiveJitterBuffer()
        let start = UInt32.max - 8
        let epoch = Date(timeIntervalSince1970: 0)
        for offset in 0..<40 {
            buffer.enqueue(sequence: start &+ UInt32(offset), pcm: Data(repeating: 0, count: 320), arrivedAt: epoch)
        }
        var sequences: [UInt32] = []
        while buffer.bufferedFrameCount > 0 {
            sequences += buffer.dequeue(maxFrames: 1, concealIfEmpty: false).map(\.sequence)
        }
        XCTAssertEqual(sequences.first, start)
        XCTAssertEqual(sequences.last, start &+ 39)
        XCTAssertGreaterThan(buffer.silenceCompactedFrames, 0)
        XCTAssertEqual(buffer.missingSequenceCount, 0)
        buffer.reset()
        XCTAssertEqual(buffer.silenceCompactedFrames, 0)

        for sequence in Array(0..<5) + Array(6..<30) {
            buffer.enqueue(sequence: UInt32(sequence), pcm: Data(repeating: 0, count: 320), arrivedAt: epoch)
        }
        _ = buffer.dequeue(maxFrames: 5, concealIfEmpty: false)
        XCTAssertEqual(buffer.dequeue(maxFrames: 1, concealIfEmpty: false).first?.sequence, 6)
        XCTAssertEqual(buffer.silenceCompactedFrames, 0)
        XCTAssertEqual(buffer.missingSequenceCount, 1)
    }

    func testCloudCompactionWaitsForRealPlaybackAfterConcealment() {
        var buffer = CloudPCMAdaptiveJitterBuffer()
        let epoch = Date(timeIntervalSince1970: 0)
        for sequence in 0..<5 {
            buffer.enqueue(sequence: UInt32(sequence), pcm: Data(repeating: 0, count: 320), arrivedAt: epoch)
        }
        _ = buffer.dequeue(maxFrames: 5)
        _ = buffer.dequeue(maxFrames: 1)
        for sequence in 5..<30 {
            buffer.enqueue(sequence: UInt32(sequence), pcm: Data(repeating: 0, count: 320), arrivedAt: epoch)
        }
        XCTAssertEqual(buffer.dequeue(maxFrames: 5, concealIfEmpty: false).map(\.sequence), [5, 6, 7, 8, 9])
        XCTAssertEqual(buffer.silenceCompactedFrames, 0)
    }

    func testCloudRenderLatencyMeasuresLocalResidenceOnly() {
        var latency = CloudPCMRenderLatency()
        latency.record(receivedAt: 100, renderedAt: 100.08)
        XCTAssertEqual(latency.latestMS, 80, accuracy: 0.001)
        latency.record(receivedAt: 200, renderedAt: 200.04)
        XCTAssertEqual(latency.latestMS, 40, accuracy: 0.001)
        XCTAssertEqual(latency.maximumMS, 80, accuracy: 0.001)
        latency.record(receivedAt: nil, renderedAt: 201) // Concealment has no source arrival.
        latency.record(receivedAt: 202, renderedAt: 201)
        latency.record(receivedAt: .infinity, renderedAt: 201)
        XCTAssertEqual(latency.sampleCount, 2)
    }

    func testCloudDownlinkStableRecoveryDoesNotDiscardQueuedSpeech() {
        var buffer = CloudPCMAdaptiveJitterBuffer()
        let start = Date(timeIntervalSince1970: 0)
        for sequence in 0..<12 {
            buffer.enqueue(sequence: UInt32(sequence), pcm: Data(repeating: 1, count: 320), arrivedAt: start)
        }
        for sequence in 12..<212 {
            buffer.enqueue(sequence: UInt32(sequence), pcm: Data(repeating: 1, count: 320),
                           arrivedAt: start.addingTimeInterval(Double(sequence - 11) * 0.02))
            _ = buffer.dequeue(maxFrames: 1)
        }
        XCTAssertEqual(buffer.bufferedFrameCount, 12)
        XCTAssertEqual(buffer.droppedFrameCount, 0, "Reducing the target must not cut queued speech")
    }

    @MainActor
    func testLateCloudReconnectDoesNotCompleteOrFailANewerCall() async {
        for succeeds in [true, false] {
            var current = UUID()
            let original = current
            var completion: CheckedContinuation<Void, Error>?
            let started = expectation(description: "connect suspended")
            var connected = 0
            var failed = 0
            let recovery = Task { @MainActor in
                await CloudCallRecoveryCoordinator.run(
                    delays: [0], isCurrent: { current == original },
                    connect: { _ in
                        try await withCheckedThrowingContinuation { continuation in
                            completion = continuation; started.fulfill()
                        }
                    }, connected: { connected += 1 }, failed: { _ in failed += 1 }
                )
            }
            await fulfillment(of: [started], timeout: 2)
            current = UUID() // Hangup, followed by a new call, while connect is pending.
            if succeeds { completion?.resume() }
            else { completion?.resume(throwing: URLError(.networkConnectionLost)) }
            await recovery.value
            XCTAssertEqual(connected, 0)
            XCTAssertEqual(failed, 0)
        }
    }

    func testCloudControlCannotAcknowledgeAnotherCallOrGeneration() throws {
        let uuid = UUID()
        let control = try XCTUnwrap(CloudPCMControlMessage.decode("""
            {"status":"active","call_id":"a","call_uuid":"\(uuid.uuidString)","generation":2}
            """))
        XCTAssertTrue(control.matches(callID: "a", uuid: uuid, generation: 2))
        XCTAssertFalse(control.matches(callID: "b", uuid: uuid, generation: 2))
        XCTAssertFalse(control.matches(callID: "a", uuid: UUID(), generation: 2))
        XCTAssertFalse(control.matches(callID: "a", uuid: uuid, generation: 3))
    }

    func testEndingCallCannotReopenInAppPresentation() {
        let call = CallRecord(id: "ending-call", index: 0, direction: "outgoing",
                              state: "ending", number: nil, startedAt: Date(), updatedAt: Date(),
                              endedAt: nil, missed: false)
        XCTAssertNil(CallPresentationPolicy.inAppCall(surface: .app, local: call, remote: nil))
    }

    func testLocalEndIntentRejectsSameCallWithHigherGeneration() {
        var store = CallLifecycleStore()
        let uuid = UUID()
        let now = Date()
        func event(_ state: CallLifecycleState, _ generation: UInt64) -> CallLifecycleEvent {
            .init(callID: "cloud-call", callUUID: uuid, generation: generation, state: state,
                  source: state == .ending ? .app : .relay, timestamp: now, traceID: nil, failure: nil)
        }
        XCTAssertTrue(store.apply(event(.active, 1)))
        XCTAssertTrue(store.apply(event(.ending, 1)))
        XCTAssertFalse(store.apply(event(.active, 2)), "reconnect must not revoke the user's end intent")
        XCTAssertEqual(store.snapshot.state, .ending)
    }

    func testRetiredCloudCallCannotReturnAfterANewerCallEnds() {
        var store = CallLifecycleStore()
        let first = UUID(), next = UUID(), now = Date()
        func event(_ id: String, _ uuid: UUID, _ state: CallLifecycleState) -> CallLifecycleEvent {
            .init(callID: id, callUUID: uuid, generation: 1, state: state,
                  source: .relay, timestamp: now, traceID: nil, failure: nil)
        }
        XCTAssertTrue(store.apply(event("first", first, .active)))
        XCTAssertTrue(store.apply(event("first", first, .ending)))
        XCTAssertTrue(store.apply(event("next", next, .ringing)))
        XCTAssertTrue(store.apply(event("next", next, .ended)))
        XCTAssertFalse(store.apply(event("first", first, .connecting)))
        XCTAssertEqual(store.snapshot.callID, "next")
    }

    func testCloudBufferLowersReprimeTargetAfterNetworkRecovers() {
        var buffer = CloudPCMAdaptiveJitterBuffer()
        for _ in 0..<6 { buffer.notePlaybackUnderrun() }
        let raised = buffer.targetFrameCount
        let epoch = Date(timeIntervalSince1970: 100)
        for sequence in 0..<800 {
            buffer.enqueue(sequence: UInt32(sequence), pcm: Data(repeating: 1, count: 320),
                           arrivedAt: epoch.addingTimeInterval(Double(sequence) * 0.02))
            _ = buffer.dequeue(maxFrames: 1)
        }
        XCTAssertLessThan(buffer.targetFrameCount, raised, "Stable timing lowers the next rebuffer threshold without trimming speech")
        XCTAssertLessThanOrEqual(buffer.targetFrameCount, 6)
    }

    func testCloudUplinkDoesNotReplayHalfSecondOldSpeech() {
        var sender = CloudPCMUplinkSendQueue()
        sender.enqueue(Data(repeating: 1, count: 320), at: 0)
        XCTAssertNil(sender.next(at: 0.5))
        sender.enqueue(Data(repeating: 2, count: 320), at: 0.5)
        XCTAssertEqual(sender.next(at: 0.5)?.first, 2)
    }

    func testCloudBufferConcealsOnlyShortGapWithoutReprimingImmediately() {
        var buffer = CloudPCMAdaptiveJitterBuffer()
        let start = Date(timeIntervalSince1970: 100)
        let pcm = Data(repeating: 16, count: 320)
        for sequence in 0..<10 { buffer.enqueue(sequence: UInt32(sequence), pcm: pcm, arrivedAt: start) }
        _ = buffer.dequeue(maxFrames: 10)
        let concealed = buffer.dequeue(maxFrames: 1)
        XCTAssertEqual(concealed.count, 1, "a 20 ms shortage should not cause a long buffering pause")
        XCTAssertNotEqual(concealed.first?.pcm, pcm, "concealed speech must decay")
        _ = buffer.dequeue(maxFrames: 1)
        XCTAssertTrue(buffer.dequeue(maxFrames: 1).isEmpty, "never replay old speech through a long outage")
    }

    func testCloudBufferBoundsExcessiveBurstTo1800Milliseconds() {
        var buffer = CloudPCMAdaptiveJitterBuffer()
        let now = Date()
        for sequence in 0..<100 {
            buffer.enqueue(sequence: UInt32(sequence), pcm: Data(repeating: 1, count: 320), arrivedAt: now)
        }
        XCTAssertEqual(buffer.bufferedFrameCount * 20, 1_800)
        XCTAssertEqual(buffer.overflowDropCount, 10)
        XCTAssertEqual(buffer.dequeue(maxFrames: 1).first?.sequence, 10)
    }

    @MainActor
    func testVoBLEHangupReplyCannotResurrectAnEndedCall() async throws {
        let central = VoBLECallControlProbe()
        let media = VoBLEGATTMediaTransport(writer: VoBLEWriterProbe(canSend: true, maximumLength: 247))
        let coordinator = VoBLECallCoordinator(central: central, media: media,
                                               audio: VoBLEAudioEngine(transport: media))
        var states: [CallLifecycleState] = []
        var ended = 0
        coordinator.onState = { _, state in states.append(state) }
        coordinator.onEnded = { _ in ended += 1 }
        central.onEvent?(.init(callID: "call-1", generation: 1, direction: "outgoing",
                              state: "dialing", number: ""))
        states.removeAll()
        central.sendOperation = { command, id, generation in
            XCTAssertEqual(command, "end")
            central.onEvent?(.init(callID: id, generation: generation, direction: "outgoing",
                                  state: "ended", number: ""))
            return .init(requestID: "end-1", generation: generation,
                         success: true, code: "ok", detail: "accepted")
        }
        try await coordinator.end(rejectIfRinging: false)
        XCTAssertNil(coordinator.currentIdentity)
        XCTAssertEqual(ended, 1)
        XCTAssertTrue(states.isEmpty, "An acknowledged terminal event must not become ending again")
    }

    @MainActor
    func testVoBLELateHangupMismatchIsIgnoredOnlyForAcknowledgedEndedIdentity() async throws {
        let central = VoBLECallControlProbe()
        let media = VoBLEGATTMediaTransport(writer: VoBLEWriterProbe(canSend: true, maximumLength: 247))
        let coordinator = VoBLECallCoordinator(central: central, media: media,
                                               audio: VoBLEAudioEngine(transport: media))
        central.onEvent?(.init(callID: "call-1", generation: 1, direction: "outgoing",
                              state: "dialing", number: ""))
        central.sendOperation = { _, id, generation in
            central.onEvent?(.init(callID: id, generation: generation, direction: "outgoing",
                                  state: "ended", number: ""))
            central.onEvent?(.init(callID: "next-call", generation: 2, direction: "outgoing",
                                  state: "dialing", number: ""))
            return .init(requestID: "late-end", generation: generation,
                         success: false, code: "call_mismatch", detail: "")
        }
        try await coordinator.end(rejectIfRinging: false)
        XCTAssertEqual(coordinator.currentIdentity?.callID, "next-call")
        central.sendOperation = { _, _, generation in
            .init(requestID: "real-error", generation: generation,
                  success: false, code: "call_mismatch", detail: "")
        }
        do {
            try await coordinator.end(rejectIfRinging: false)
            XCTFail("A mismatch on a still-current call must remain an error")
        } catch {
            XCTAssertEqual(error as? VoBLECentralError, .bluetooth("call_mismatch"))
        }
        XCTAssertEqual(coordinator.currentIdentity?.callID, "next-call")
    }

    func testVoBLELiveActivityActionURLRoutesBackToHostApp() throws {
        let url = try XCTUnwrap(URL(
            string: "airsim://call/hangup?call_id=android-call-7"
        ))
        XCTAssertEqual(
            SystemCommunicationURL.destination(for: url),
            .liveActivity(.hangup, callID: "android-call-7")
        )
        XCTAssertEqual(
            AirSIMLiveActivityActionURL.make(
                action: .hangup, callID: "android-call-7"
            ),
            url
        )
    }

    func testBluetoothPoweredOnDoesNotDemoteReadyConnection() {
        var reducer = VoBLEConnectionReducer()
        let peripheralID = UUID()
        reducer.apply(.discovered(peripheralID))
        reducer.apply(.connected)
        reducer.apply(.characteristicsReady)
        reducer.apply(.controlSubscription(true))
        reducer.apply(.authenticated(identity: "samsung-agent"))
        XCTAssertEqual(reducer.state, .ready)

        reducer.apply(.bluetoothPoweredOn)

        XCTAssertEqual(reducer.state, .ready)
    }

    @MainActor
    func testRejectIsNotSilentlyDroppedWhileAnotherActionIsBusy() async {
        let model = AppModel()
        model.isBusy = true
        model.errorMessage = "reject was not attempted"

        await model.reject()

        XCTAssertNotEqual(model.errorMessage, "reject was not attempted")
    }

    @MainActor
    func testHangupIsNotSilentlyDroppedWhileAnotherActionIsBusy() async {
        let model = AppModel()
        model.isBusy = true
        model.errorMessage = "hangup was not attempted"

        await model.hangup()

        XCTAssertNotEqual(model.errorMessage, "hangup was not attempted")
    }

    func testLocalCallControlBodyCarriesCallIdentity() throws {
        let targeted = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(LocalCallControlBody(callID: "visible-call-7"))
        ) as? [String: String]
        XCTAssertEqual(targeted, ["call_id": "visible-call-7"])
        let legacy = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(LocalCallControlBody(callID: nil))
        ) as? [String: String]
        XCTAssertEqual(legacy, [String: String]())
    }

    func testUnansweredPushRejectRoutesToRelayEvenWithoutPreparedMedia() {
        XCTAssertEqual(CallKitEndDecision.route(
            transport: nil, cloudSessionPrepared: false,
            hasIncomingPush: true, systemCallAnswered: false,
            activeIncomingRinging: false
        ), .cloudReject)
        XCTAssertEqual(CallKitEndDecision.route(
            transport: .cloud, cloudSessionPrepared: false,
            hasIncomingPush: true, systemCallAnswered: false,
            activeIncomingRinging: false
        ), .cloudReject)
        XCTAssertEqual(CallKitEndDecision.route(
            transport: .vowlan, cloudSessionPrepared: false,
            hasIncomingPush: true, systemCallAnswered: false,
            activeIncomingRinging: true
        ), .localReject)
        XCTAssertEqual(CallKitEndDecision.route(
            transport: nil, cloudSessionPrepared: false,
            hasIncomingPush: false, systemCallAnswered: false,
            activeIncomingRinging: true
        ), .localReject)
    }

    func testLateEndCallbackDoesNotReachBackendAfterCallAlreadyEnded() {
        XCTAssertFalse(CallKitEndActionPolicy.shouldForwardToBackend(
            systemCallWasCurrent: false
        ))
        XCTAssertTrue(CallKitEndActionPolicy.shouldForwardToBackend(
            systemCallWasCurrent: true
        ))
    }

    func testLocalRejectKeepsObservedAgentDuringReconnect() {
        XCTAssertEqual(LocalCallControlTarget.select(
            locked: Optional<String>.none,
            observed: (callID: "call-on-samsung", service: "三星"),
            fallback: "小米",
            targetCallID: "call-on-samsung"
        ), "三星")
        XCTAssertNil(LocalCallControlTarget.select(
            locked: Optional<String>.none,
            observed: (callID: "call-on-samsung", service: "三星"),
            fallback: "小米",
            targetCallID: nil
        ))
        XCTAssertNil(LocalCallControlTarget.select(
            locked: Optional<String>.none,
            observed: (callID: "old-call", service: "三星"),
            fallback: "小米",
            targetCallID: "new-call"
        ))
    }

    @MainActor
    func testInitialPermissionsWaitForMicrophoneDecisionBeforeOtherPrompts() async {
        let coordinator = InitialPermissionCoordinator()
        var microphoneUndetermined = true
        var events: [String] = []

        await coordinator.requestIfNeeded(
            isForeground: { true },
            microphoneIsUndetermined: { microphoneUndetermined },
            requestMicrophone: {
                events.append("microphone")
                await Task.yield()
                microphoneUndetermined = false
            },
            startDiscovery: { events.append("discovery") },
            requestNotifications: { events.append("notifications") }
        )

        XCTAssertEqual(events, ["microphone", "discovery", "notifications"])
        XCTAssertTrue(coordinator.didStartDiscovery)
    }

    @MainActor
    func testInitialPermissionsRetryWhenMicrophonePromptWasDeferred() async {
        let coordinator = InitialPermissionCoordinator()
        var microphoneUndetermined = true
        var requestCount = 0
        var notifications = 0
        var discovery = 0

        func request() async {
            await coordinator.requestIfNeeded(
                isForeground: { true },
                microphoneIsUndetermined: { microphoneUndetermined },
                requestMicrophone: { requestCount += 1 },
                startDiscovery: { discovery += 1 },
                requestNotifications: { notifications += 1 }
            )
        }

        await request()
        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(discovery, 0)
        XCTAssertEqual(notifications, 0)

        microphoneUndetermined = false
        await request()
        await request()
        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(discovery, 1)
        XCTAssertEqual(notifications, 1)
    }

    func testRelayRetryDoesNotRepeatSuccessfulAgentRegistration() {
        XCTAssertFalse(PushRegistrationAttemptPolicy.shouldRegisterAgent(
            fingerprint: "same-token",
            route: "samsung",
            lastFingerprint: "same-token",
            lastRoute: "samsung"
        ))
    }

    func testNewAgentRouteRequiresRegistrationEvenWithSameToken() {
        XCTAssertTrue(PushRegistrationAttemptPolicy.shouldRegisterAgent(
            fingerprint: "same-token",
            route: "new-samsung",
            lastFingerprint: "same-token",
            lastRoute: "old-samsung"
        ))
    }

    func testRelayQuotaPausesOnlyRelayRegistrationUntilRetryTime() {
        let now = Date(timeIntervalSince1970: 43_200)
        let retryAfter = Date(timeIntervalSince1970: 43_500)
        XCTAssertFalse(PushRegistrationRetryPolicy.shouldAttemptRelay(now: now, retryAfter: retryAfter))
        XCTAssertTrue(PushRegistrationRetryPolicy.shouldAttemptRelay(now: retryAfter, retryAfter: retryAfter))
        XCTAssertEqual(PushRegistrationRetryPolicy.quotaRetryDate(now: now), retryAfter)
        XCTAssertEqual(
            PushRegistrationRetryPolicy.quotaRetryDate(now: Date(timeIntervalSince1970: 86_280)),
            Date(timeIntervalSince1970: 86_410)
        )
    }

    func testCloudStatusRefreshDoesNotRepeatJustBecauseTimeElapsed() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertFalse(AppRefreshPolicy.shouldQueryCloudStatus(
            cloudModeEnabled: false, lastAttempt: .distantPast, appIsForeground: true))
        XCTAssertTrue(AppRefreshPolicy.shouldQueryCloudStatus(
            cloudModeEnabled: true, lastAttempt: .distantPast, appIsForeground: true))
        XCTAssertFalse(AppRefreshPolicy.shouldQueryCloudStatus(
            cloudModeEnabled: true, lastAttempt: .distantPast, appIsForeground: false))
        XCTAssertTrue(AppRefreshPolicy.shouldQueryCloudStatus(
            cloudModeEnabled: true, lastAttempt: .distantPast,
            appIsForeground: false, beforeLiveActivityCall: true))
        XCTAssertFalse(AppRefreshPolicy.shouldQueryCloudStatus(
            cloudModeEnabled: true, lastAttempt: now.addingTimeInterval(-5), appIsForeground: true))
        XCTAssertFalse(AppRefreshPolicy.shouldQueryCloudStatus(
            cloudModeEnabled: true, lastAttempt: now.addingTimeInterval(-30), appIsForeground: true))
        XCTAssertFalse(AppRefreshPolicy.shouldQueryCloudStatus(
            cloudModeEnabled: true, lastAttempt: now.addingTimeInterval(-3_600),
            appIsForeground: false, beforeLiveActivityCall: true))
    }

    func testLegacyAgentPollFetchesPendingSMSWithoutEventEndpoint() async throws {
        let withMessage = try await LegacyAgentPoller.next(
            LegacyAgentSMSProbe(pending: 1, smsStatusAvailable: true))
        XCTAssertTrue(withMessage.smsChanged)

        let empty = try await LegacyAgentPoller.next(
            LegacyAgentSMSProbe(pending: 0, smsStatusAvailable: true))
        XCTAssertFalse(empty.smsChanged)

        let unavailableStatus = try await LegacyAgentPoller.next(
            LegacyAgentSMSProbe(pending: nil, smsStatusAvailable: false))
        XCTAssertTrue(unavailableStatus.smsChanged)
    }

    func testPendingSMSIsFetchedEvenWhenRevisionWasAlreadyObserved() {
        XCTAssertTrue(AgentEventPollingPolicy.shouldFetchSMS(
            pending: 1, eventRevision: 7, observedSMSRevision: 7))
        XCTAssertTrue(AgentEventPollingPolicy.shouldFetchSMS(
            pending: 1, eventRevision: 0, observedSMSRevision: 7))
        XCTAssertFalse(AgentEventPollingPolicy.shouldFetchSMS(
            pending: 0, eventRevision: 8, observedSMSRevision: 7))
    }

    func testSMSFetchUsesReportingAgentAfterDiscoverySwitchesPhones() async throws {
        let samsung = AgentSMSInboxProbe(name: "三星", inbox: [SMSMessage(
            sender: "10086", content: "来自三星", code: nil,
            timestamp: Date(timeIntervalSince1970: 1_791_448_212),
            deliveryID: "samsung-sms-1", direction: .incoming
        )])
        let xiaomi = AgentSMSInboxProbe(name: "小米", inbox: [])

        let fetched = try await AgentSMSInboxFetch.fetch(
            reportingAgent: samsung, discoveredAgent: xiaomi
        )

        XCTAssertEqual(fetched.messages.map(\.content), ["来自三星"])
        XCTAssertEqual(fetched.agent.name, "三星")
    }

    func testPCMReconnectCreatesFreshHandshakeForEveryAttempt() throws {
        var generated = 0
        let handshakes = PCMHandshakeSequence {
            generated += 1
            return Data("handshake-\(generated)".utf8)
        }

        XCTAssertEqual(try handshakes.next(), Data("handshake-1".utf8))
        XCTAssertEqual(try handshakes.next(), Data("handshake-2".utf8))
        XCTAssertEqual(generated, 2)
    }

    func testIncomingSMSPushAcceptsAgentNanosecondTimestamp() throws {
        let pushed = try IncomingRemoteSMS(userInfo: [
            "event": "incoming_sms",
            "delivery_id": "sms-nano-1",
            "sender": "10086",
            "content": "短信正文",
            "timestamp": "2026-10-08T08:30:12.123456789Z",
        ])
        XCTAssertEqual(pushed.deliveryID, "sms-nano-1")
        XCTAssertEqual(pushed.message.content, "短信正文")
        XCTAssertEqual(pushed.timestamp.timeIntervalSince1970, 1_791_448_212.123456789, accuracy: 0.001)
    }

    func testIncomingSMSPushAcceptsWholeSecondTimestamp() throws {
        let pushed = try IncomingRemoteSMS(userInfo: [
            "event": "incoming_sms",
            "delivery_id": "sms-second-1",
            "sender": "10086",
            "content": "短信正文",
            "timestamp": "2026-10-08T08:30:12Z",
        ])
        XCTAssertEqual(pushed.deliveryID, "sms-second-1")
    }

    func testColdLaunchSMSNavigationRequestIsConsumedOnce() {
        let suite = "airsim-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        IncomingSMSPresentationRequest.markPending(sender: "10086", defaults: defaults)
        XCTAssertEqual(IncomingSMSPresentationRequest.consume(defaults: defaults), "10086")
        XCTAssertNil(IncomingSMSPresentationRequest.consume(defaults: defaults))
    }

    func testSMSDeliveryIDDeduplicatesPushAndAgentCopies() {
        let pushed = SMSMessage(
            sender: "10086", content: "短信正文", code: nil,
            timestamp: Date(timeIntervalSince1970: 1_791_448_212),
            deliveryID: "sms-stable-1", direction: .incoming
        )
        let synchronized = SMSMessage(
            sender: "10086", content: "短信正文", code: nil,
            timestamp: Date(timeIntervalSince1970: 1_791_448_212.123456789),
            deliveryID: "sms-stable-1", direction: .incoming
        )
        XCTAssertEqual(pushed.id, synchronized.id)
    }

    func testCloudUplinkMaintainsCadenceDespiteTimerJitter() {
        for jitter in [0.001, 0.002, 0.003] {
            var queue = CloudPCMUplinkSendQueue()
            var events: [(time: TimeInterval, capture: Bool)] = []
            let count = 3_000
            for index in 0..<count {
                events.append((Double(index) * 0.020, true))
                events.append((0.006 + Double(index) * 0.020 + sin(Double(index) * 1.78) * jitter, false))
            }
            events.sort { $0.time < $1.time }
            var sent = 0
            for event in events {
                if event.capture {
                    queue.enqueue(Data(repeating: 1, count: 320), at: event.time)
                } else if queue.next(at: event.time) != nil {
                    sent += 1
                    queue.complete(at: event.time)
                }
            }
            XCTAssertEqual(sent, count, "Timer jitter must not reduce the 50-packet/s voice stream")
            XCTAssertEqual(queue.droppedPackets, 0)
            XCTAssertEqual(queue.pendingPackets, 0)
        }
    }

    func testCloudUplinkRecordsWriteLatencyWithoutAllowingImmediateBurst() {
        var queue = CloudPCMUplinkSendQueue()
        for _ in 0..<3 { queue.enqueue(Data(repeating: 1, count: 320), at: 0) }
        XCTAssertNotNil(queue.next(at: 0))
        queue.complete(at: 0.025)
        XCTAssertEqual(queue.maximumSendDurationMS, 25, accuracy: 0.001)
        XCTAssertNotNil(queue.next(at: 0.025))
        queue.complete(at: 0.026)
        XCTAssertNil(queue.next(at: 0.026))
        XCTAssertEqual(queue.capturedPackets, 3)
        XCTAssertEqual(queue.sentPackets, 2)
    }

    func testCloudUplinkNeverBurstsAfterBlockedSend() {
        var queue = CloudPCMUplinkSendQueue()
        for index in 0..<10 {
            queue.enqueue(Data(repeating: UInt8(index), count: 320), at: Double(index) * 0.02)
        }
        XCTAssertEqual(queue.next(at: 0.2)?.first, 0)
        XCTAssertNil(queue.next(at: 0.21))
        queue.complete()
        XCTAssertEqual(queue.next(at: 0.23)?.first, 1)
        queue.complete()
        XCTAssertNil(queue.next(at: 0.231))
        XCTAssertEqual(queue.next(at: 0.251)?.first, 2)
    }

    func testCloudUplinkDropsStaleBacklog() {
        var queue = CloudPCMUplinkSendQueue()
        for _ in 0..<200 { queue.enqueue(Data(repeating: 1, count: 320), at: 0) }
        XCTAssertEqual(queue.pendingPackets, 12)
        XCTAssertNil(queue.next(at: 2))
        XCTAssertEqual(queue.pendingPackets, 0)
        XCTAssertEqual(queue.droppedPackets, 200)
    }

    func testCloudDownlinkPrimesAndReordersBurst() {
        var buffer = CloudPCMAdaptiveJitterBuffer()
        let epoch = Date(timeIntervalSince1970: 1_800_000_000)
        for sequence in [0, 2, 1, 3, 4, 5, 6, 7, 8, 9] {
            buffer.enqueue(sequence: UInt32(sequence),
                           pcm: Data(repeating: UInt8(sequence), count: 320),
                           arrivedAt: epoch.addingTimeInterval(Double(sequence) * 0.02))
        }
        XCTAssertEqual(buffer.dequeue(maxFrames: 10).map(\.sequence), Array(0..<10).map(UInt32.init))
        buffer.notePlaybackUnderrun()
        XCTAssertFalse(buffer.isPrimed)
    }

    func testCloudDownlinkLimitsLateBurstLatency() {
        var buffer = CloudPCMAdaptiveJitterBuffer()
        let epoch = Date(timeIntervalSince1970: 1_800_000_000)
        for sequence in 0..<125 {
            buffer.enqueue(sequence: UInt32(sequence),
                           pcm: Data(repeating: 1, count: 320),
                           arrivedAt: epoch.addingTimeInterval(Double(sequence) * 0.02))
        }
        XCTAssertEqual(buffer.bufferedFrameCount, 90)
        XCTAssertEqual(buffer.droppedFrameCount, 35)
        XCTAssertEqual(buffer.overflowDropCount, 35)
        XCTAssertEqual(buffer.dequeue(maxFrames: 90).map(\.sequence), Array(35..<125).map(UInt32.init))
    }

    func testCloudPlayoutRefillsOnCompletionWithoutWaitingForTimer() {
        var playout = CloudPCMPlayoutBuffer()
        let now = Date(timeIntervalSince1970: 0)
        for sequence in 0..<6 {
            playout.enqueue(sequence: UInt32(sequence), pcm: Data(repeating: 1, count: 320), arrivedAt: now)
        }
        XCTAssertEqual(playout.refill().map(\.sequence), [0, 1])
        // The timer runs just before render completion and sees a full window.
        XCTAssertTrue(playout.refill(allowConcealment: true).isEmpty)
        XCTAssertEqual(playout.rendered().map(\.sequence), [2],
                       "Freed capacity must refill during the completion, not the next 20 ms tick")
        XCTAssertEqual(playout.window.scheduledPackets, 2)
        XCTAssertEqual(playout.jitter.underrunCount, 0)
    }

    func testCloudPlayoutDoesNotConcealWhileRealAudioIsScheduled() {
        var playout = CloudPCMPlayoutBuffer()
        let now = Date(timeIntervalSince1970: 0)
        for sequence in 0..<4 {
            playout.enqueue(sequence: UInt32(sequence), pcm: Data(repeating: 1, count: 320), arrivedAt: now)
        }
        _ = playout.refill()
        _ = playout.rendered()
        _ = playout.rendered()
        XCTAssertEqual(playout.jitter.bufferedFrameCount, 0)
        XCTAssertEqual(playout.window.scheduledPackets, 2)
        XCTAssertTrue(playout.rendered().isEmpty)
        XCTAssertTrue(playout.refill(allowConcealment: true).isEmpty)
        XCTAssertEqual(playout.jitter.underrunCount, 0,
                       "An empty network reserve is not starvation while the player still has audio")
        XCTAssertTrue(playout.rendered().isEmpty)
        for _ in 0..<10 { XCTAssertTrue(playout.refill().isEmpty) }
        XCTAssertEqual(playout.jitter.underrunCount, 0,
                       "Network/render probes cannot synthesize missing audio")
        XCTAssertEqual(playout.refill(allowConcealment: true).count, 1)
        XCTAssertEqual(playout.jitter.concealedFrameCount, 1)
    }

    func testCloudPlayoutBoundsConcealmentAndRecoversAfterLongGap() {
        var playout = CloudPCMPlayoutBuffer()
        let now = Date(timeIntervalSince1970: 0)
        for sequence in 0..<4 {
            playout.enqueue(sequence: UInt32(sequence), pcm: Data(repeating: 1, count: 320), arrivedAt: now)
        }
        _ = playout.refill()
        for _ in 0..<4 { _ = playout.rendered() }
        for _ in 0..<2 {
            XCTAssertEqual(playout.refill(allowConcealment: true).count, 1)
            _ = playout.rendered()
        }
        XCTAssertTrue(playout.refill(allowConcealment: true).isEmpty)
        XCTAssertFalse(playout.jitter.isPrimed)
        XCTAssertEqual(playout.jitter.concealedFrameCount, 2)
        for sequence in 4..<64 {
            playout.enqueue(sequence: UInt32(sequence), pcm: Data(repeating: 2, count: 320),
                            arrivedAt: now.addingTimeInterval(1))
        }
        XCTAssertEqual(playout.refill().map(\.sequence), [4, 5])
        XCTAssertEqual(playout.jitter.concealedFrameCount, 2)
    }

    func testCloudPlayoutReleasesCompletedCapacityWhileEnginePaused() {
        var playout = CloudPCMPlayoutBuffer()
        for sequence in 0..<4 {
            playout.enqueue(sequence: UInt32(sequence), pcm: Data(repeating: 1, count: 320),
                            arrivedAt: Date(timeIntervalSince1970: 0))
        }
        _ = playout.refill()
        XCTAssertTrue(playout.rendered(canRefill: false).isEmpty)
        XCTAssertTrue(playout.rendered(canRefill: false).isEmpty)
        XCTAssertEqual(playout.window.scheduledPackets, 0)
        XCTAssertEqual(playout.jitter.bufferedFrameCount, 2)
        XCTAssertEqual(playout.refill().map(\.sequence), [2, 3])
        XCTAssertEqual(playout.jitter.underrunCount, 0)
    }

    func testCloudPlayoutBurstRemainsBoundedWithoutCallbackInducedConcealment() {
        var playout = CloudPCMPlayoutBuffer()
        let now = Date(timeIntervalSince1970: 0)
        for sequence in 0..<100 {
            playout.enqueue(sequence: UInt32(sequence), pcm: Data(repeating: 1, count: 320), arrivedAt: now)
        }
        XCTAssertEqual(playout.jitter.droppedFrameCount, 10)
        XCTAssertEqual(playout.refill().map(\.sequence), [10, 11])
        for _ in 0..<90 {
            _ = playout.rendered()
            XCTAssertLessThanOrEqual(playout.window.scheduledPackets, 2)
        }
        XCTAssertEqual(playout.jitter.concealedFrameCount, 0)
        XCTAssertEqual(playout.jitter.underrunCount, 0)
    }

    func testCloudPlaybackReserveRefillsOnRenderedFrames() {
        var window = CloudPCMPlaybackWindow()
        for _ in 0..<2 { window.schedulePacket() }
        XCTAssertEqual(window.availablePackets, 0)
        window.didRenderPacket()
        XCTAssertEqual(window.availablePackets, 1)
        window.schedulePacket()
        XCTAssertEqual(window.scheduledPackets, 2)
    }

    func testOnlySamsungPrivateEndpointsAreAccepted() throws {
        let endpoint = try VoWLANEndpoint(host: "192.168.43.1", controlPort: 7575, pcmPort: 7576)
        XCTAssertEqual(endpoint.controlBaseURL.absoluteString, "http://192.168.43.1:7575/")
        XCTAssertThrowsError(try VoWLANEndpoint(host: "8.8.8.8", controlPort: 7575, pcmPort: 7576))
        XCTAssertFalse(AirSIMRoutePolicy.permits(.moduleLocal))
    }

    func testLegacyModuleRequestIsRejectedBeforeNetworkAccess() async {
        do {
            _ = try await AirSIMAPI().health()
            XCTFail("旧模块路线不应发出请求")
        } catch APIError.disabledLegacyRoute {
            // Expected: the old module route is blocked at the transport boundary.
        } catch {
            XCTFail("预期得到旧路线已停用错误，实际为 \(error)")
        }
    }

    func testLegacyModulePCMHandshakeIsRejected() {
        XCTAssertThrowsError(try PCMRoute.moduleLocal.handshake()) { error in
            guard case APIError.disabledLegacyRoute = error else {
                return XCTFail("预期旧模块 PCM 被拦截，实际为 \(error)")
            }
        }
    }

    func testDialTransportPrefersVoWLANOverCloud() {
        let route = DialPadTransportPresentation.make(
            mode: .automatic,
            vowlanOnline: true,
            moduleLocalReachable: false,
            cloudOnline: true,
            bluetoothReady: true
        )
        XCTAssertEqual(route?.transport, .vowlan)
    }

    func testAutomaticDialRouteFallsBackFromVoWLANToBluetoothThenCloud() {
        XCTAssertEqual(DialRouteSelector.preferred(
            mode: .automatic,
            vowlanReady: true,
            bluetoothReady: true,
            cloudReady: true
        ), .vowlan)
        XCTAssertEqual(DialRouteSelector.preferred(
            mode: .automatic,
            vowlanReady: false,
            bluetoothReady: true,
            cloudReady: true
        ), .bluetooth)
        XCTAssertEqual(DialRouteSelector.preferred(
            mode: .automatic,
            vowlanReady: false,
            bluetoothReady: false,
            cloudReady: true
        ), .cloud)
    }

    func testExplicitBluetoothRouteDoesNotDependOnVoWLANOrRelay() {
        XCTAssertEqual(DialRouteSelector.preferred(
            mode: .bluetooth,
            vowlanReady: false,
            bluetoothReady: true,
            cloudReady: false
        ), .bluetooth)
        XCTAssertTrue(OutgoingCommandAvailability.isAvailable(
            mode: .bluetooth,
            localControlReachable: false,
            bluetoothReady: true,
            cloudModeEnabled: false,
            cloudHeartbeatFresh: false
        ))
    }

    func testAndroidAgentBindingPersistsAndRejectsOtherRoutes() {
        let suite = "AirSIMTests.agent-binding.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertNil(AndroidAgentBindingPreference.selected(defaults: defaults))
        XCTAssertTrue(AndroidAgentBindingPreference.permits("samsung", defaults: defaults))
        AndroidAgentBindingPreference.set("vivo-x60", defaults: defaults)
        XCTAssertEqual(AndroidAgentBindingPreference.selected(defaults: defaults), "vivo-x60")
        XCTAssertTrue(AndroidAgentBindingPreference.permits("vivo-x60", defaults: defaults))
        XCTAssertFalse(AndroidAgentBindingPreference.permits("samsung", defaults: defaults))
        AndroidAgentBindingPreference.set(nil, defaults: defaults)
        XCTAssertNil(AndroidAgentBindingPreference.selected(defaults: defaults))
    }

    func testPairedDeviceDeletionPersistsAndDoesNotReturnFromDiscovery() {
        let suite = "AirSIMTests.paired-devices.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let samsung = PairedAndroidDeviceRecord(id: "samsung", deviceName: "Flip7", agentKind: "standalone")
        let vivo = PairedAndroidDeviceRecord(id: "vivo", deviceName: "X60", agentKind: "standalone")
        PairedAndroidDeviceStore.remember(samsung, defaults: defaults)
        PairedAndroidDeviceStore.remember(vivo, defaults: defaults)
        AndroidAgentBindingPreference.set("samsung", defaults: defaults)
        PairedAndroidDeviceStore.forget("samsung", defaults: defaults)
        PairedAndroidDeviceStore.remember(samsung, defaults: defaults)
        XCTAssertEqual(PairedAndroidDeviceStore.records(defaults: defaults).map(\.id), ["vivo"])
        XCTAssertFalse(PairedAndroidDeviceStore.permits("samsung", defaults: defaults))
        XCTAssertNil(AndroidAgentBindingPreference.selected(defaults: defaults))
        let reopened = UserDefaults(suiteName: suite)!
        XCTAssertFalse(PairedAndroidDeviceStore.permits("samsung", defaults: reopened))
        PairedAndroidDeviceStore.allowPairing("samsung", defaults: reopened)
        PairedAndroidDeviceStore.remember(samsung, defaults: reopened)
        XCTAssertEqual(Set(PairedAndroidDeviceStore.records(defaults: reopened).map(\.id)), ["vivo", "samsung"])
    }

    func testFreshVoWLANIdentityClearsOldNumberWhenNewSIMDoesNotReportNumber() throws {
        let endpoint = try VoWLANEndpoint(host: "192.168.31.203", controlPort: 7592, pcmPort: 7593)
        let previous = VoWLANDiscoveredAgent(id: "samsung", endpoint: endpoint, deviceName: "Flip7",
            manufacturer: "samsung", model: "Flip7", phoneNumber: "+10000000001", agentKind: "standalone")
        let empty = try JSONDecoder().decode(VoWLANHealthIdentity.self,
            from: Data(#"{"ok":true,"agent_id":"samsung","phone_number":""}"#.utf8))
        XCTAssertNil(previous.refreshed(with: empty).phoneNumber)
        let changed = try JSONDecoder().decode(VoWLANHealthIdentity.self,
            from: Data(#"{"ok":true,"agent_id":"samsung","phone_number":"+10000000002"}"#.utf8))
        XCTAssertEqual(previous.refreshed(with: changed).phoneNumber, "+10000000002")
    }

    func testAuthenticatedBluetoothMetadataUsesCurrentNumberAndRejectsAnotherDevice() throws {
        let metadata = try AndroidAgentMetadata.decode(
            Data(#"{"agent_id":"samsung","device_name":"Flip7","phone_number":"","agent_kind":"standalone"}"#.utf8),
            expectedID: "samsung")
        XCTAssertNil(metadata.phoneNumber)
        XCTAssertEqual(metadata.deviceName, "Flip7")
        XCTAssertThrowsError(try AndroidAgentMetadata.decode(
            Data(#"{"agent_id":"other","device_name":"Other"}"#.utf8), expectedID: "samsung"))
    }

    func testDeletedBluetoothAdvertisementCannotAutomaticallyReconnect() {
        let suite = "AirSIMTests.deleted-peripheral.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        PairedAndroidDeviceStore.rememberPeripheral("peripheral-samsung", for: "samsung", defaults: defaults)
        PairedAndroidDeviceStore.rememberPeripheral("peripheral-vivo", for: "vivo", defaults: defaults)
        PairedAndroidDeviceStore.forget("samsung", defaults: defaults)
        XCTAssertFalse(PairedAndroidDeviceStore.permitsPeripheral("peripheral-samsung", defaults: defaults))
        XCTAssertTrue(PairedAndroidDeviceStore.permitsPeripheral("peripheral-vivo", defaults: defaults))
        PairedAndroidDeviceStore.allowPairing("samsung", defaults: defaults)
        XCTAssertTrue(PairedAndroidDeviceStore.permitsPeripheral("peripheral-samsung", defaults: defaults))
    }

    @MainActor
    func testOfflineBluetoothDeviceDeletionRevokesOnlyThatKeychainCredential() async throws {
        let store = InMemoryVoBLEPairingStore()
        let one = VoBLEStoredPeer(identity: "samsung", pairingKey: Data(repeating: 1, count: 32), createdAt: Date())
        let two = VoBLEStoredPeer(identity: "vivo", pairingKey: Data(repeating: 2, count: 32), createdAt: Date())
        defer { try? store.revoke(identity: "samsung"); try? store.revoke(identity: "vivo") }
        try store.save(one); try store.save(two)
        let controller = VoBLECentralController(pairingStore: store)
        try await controller.forgetDevice("samsung")
        XCTAssertNil(try store.load(identity: "samsung"))
        XCTAssertEqual(try store.load(identity: "vivo"), two)
        XCTAssertEqual(controller.state, .stopped)
    }

    func testCloudStatusDecodesMultipleAndroidAgentsAndCurrentRoute() throws {
        let data = Data(#"""
        {
            "cloud_online": true,
            "active_agent_id": "samsung-standalone",
            "agents": [
                {
                    "agent_id": "xiaomi-standalone",
                    "agent_kind": "standalone",
                    "device_name": "Xiaomi 15",
                    "phone_number": "+8613800000001",
                    "agent_version": "standalone-0.1.0",
                    "cloud_online": false
                },
                {
                    "agent_id": "samsung-standalone",
                    "agent_kind": "standalone",
                    "device_name": "Samsung Flip7",
                    "phone_number": "+8613800000002",
                    "agent_version": "standalone-0.1.0",
                    "cloud_online": true
                }
            ]
        }
        """#.utf8)
        let status = try JSONDecoder().decode(CloudAgentStatus.self, from: data)
        XCTAssertEqual(status.activeAgentID, "samsung-standalone")
        XCTAssertEqual(status.agents.count, 2)
        XCTAssertEqual(status.agents.last?.deviceName, "Samsung Flip7")
        XCTAssertEqual(status.agents.last?.phoneNumber, "+8613800000002")
    }

    func testCloudModeCanBeDisabledWithoutDisablingLocalCalls() {
        let suite = "airsim-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: CloudModePreference.key)
        XCTAssertFalse(CloudModePreference.isEnabled(defaults: defaults))
        XCTAssertTrue(OutgoingCommandAvailability.isAvailable(
            localControlReachable: true,
            cloudModeEnabled: false,
            cloudHeartbeatFresh: false
        ))
    }

    func testExplicitBluetoothModeDisablesUnrelatedLifecycles() {
        let policy = ConnectionModeRuntimePolicy(mode: .bluetooth)

        XCTAssertTrue(policy.startsBluetooth)
        XCTAssertFalse(policy.startsVoWLAN)
        XCTAssertFalse(policy.startsCloud)
        XCTAssertFalse(policy.allowsCrossModeFallback)
        XCTAssertTrue(policy.usesCallKit)
    }

    func testOnlyAutomaticAllowsCrossModeSelection() {
        XCTAssertTrue(ConnectionModeRuntimePolicy(mode: .automatic).allowsCrossModeFallback)
        for mode in [AirSIMConnectionMode.vowlan, .bluetooth, .cloud] {
            XCTAssertFalse(ConnectionModeRuntimePolicy(mode: mode).allowsCrossModeFallback)
        }
    }

    func testVoBLEAudioVectorUsesBigEndianHeaderAndRoundTripsAtCommonMTUs() throws {
        let packet = VoBLEAudioPacket(
            flags: [], codec: .g711MuLaw, streamID: 7,
            sequence: 0x01020304, sampleTimestamp: 0x05060708,
            payload: Data([0x00, 0x7f, 0x80, 0xff]),
            authenticationTag: Data(repeating: 0xa5, count: 16)
        )

        for maximumPacketLength in [23, 185, 247] {
            let fragments = try packet.encodedFragments(maximumPacketLength: maximumPacketLength)
            XCTAssertTrue(fragments.allSatisfy { $0.count <= maximumPacketLength })
            XCTAssertEqual(Array(fragments[0][7..<11]), [0x01, 0x02, 0x03, 0x04])
            XCTAssertEqual(Array(fragments[0][11..<15]), [0x05, 0x06, 0x07, 0x08])

            var reassembler = VoBLEAudioReassembler()
            var decoded: VoBLEAudioPacket?
            for fragment in fragments {
                decoded = try reassembler.append(fragment, now: Date(timeIntervalSince1970: 10)) ?? decoded
            }
            XCTAssertEqual(decoded, packet)
        }
        XCTAssertEqual(
            try packet.encodedFragments(maximumPacketLength: 247)[0],
            Data([
                0xa5, 0x5a, 0x01, 0x01, 0x00, 0x01, 0x07,
                0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
                0x00, 0x01, 0x14, 0x00, 0x7f, 0x80, 0xff,
            ] + Array(repeating: 0xa5, count: 16))
        )
    }

    func testVoBLEReassemblyExpiryMarksNextFrameDiscontinuous() throws {
        let first = VoBLEAudioPacket(
            flags: [], codec: .g711MuLaw, streamID: 1, sequence: 1,
            sampleTimestamp: 0, payload: Data(repeating: 1, count: 160),
            authenticationTag: Data(repeating: 2, count: 16)
        )
        let second = VoBLEAudioPacket(
            flags: [], codec: .g711MuLaw, streamID: 1, sequence: 2,
            sampleTimestamp: 160, payload: Data([3]),
            authenticationTag: Data(repeating: 4, count: 16)
        )
        var reassembler = VoBLEAudioReassembler()
        let incomplete = try first.encodedFragments(maximumPacketLength: 23)
        _ = try reassembler.append(incomplete[0], now: Date(timeIntervalSince1970: 1))
        let complete = try second.encodedFragments(maximumPacketLength: 247)
        let decoded = try reassembler.append(complete[0], now: Date(timeIntervalSince1970: 1.201))

        XCTAssertTrue(decoded?.flags.contains(.discontinuity) == true)
    }

    func testVoBLEMediaCipherAndMuLawMatchAndroidVector() throws {
        let pcm = Data((0..<160).flatMap { value -> [UInt8] in
            let sample = Int16(truncatingIfNeeded: value * 257 - 20_000)
            return [UInt8(truncatingIfNeeded: sample), UInt8(truncatingIfNeeded: sample >> 8)]
        })
        let encoded = VoBLEMULaw.encode(pcm)
        XCTAssertEqual(encoded.count, 160)
        XCTAssertEqual(VoBLEMULaw.decode(encoded).count, 320)
        let key = Data(0..<32)
        let sealed = try VoBLEMediaCipher.seal(
            encoded, key: key, direction: .uplink, streamID: 1,
            sequence: 7, timestamp: 160)
        XCTAssertEqual(try VoBLEMediaCipher.open(
            sealed, key: key, direction: .uplink, streamID: 1,
            sequence: 7, timestamp: 160), encoded)
        XCTAssertThrowsError(try VoBLEMediaCipher.open(
            sealed, key: key, direction: .downlink, streamID: 1,
            sequence: 7, timestamp: 160))
    }

    func testVoBLEJitterRejectsReplayAndConcealsGap() {
        var jitter = VoBLEJitterBuffer(targetFrames: 3)
        for sequence in [UInt32(10), 11, 13] {
            XCTAssertTrue(jitter.insert(sequence: sequence,
                pcm: Data(repeating: UInt8(sequence), count: 320)))
        }
        XCTAssertFalse(jitter.insert(sequence: 11, pcm: Data(repeating: 0, count: 320)))
        XCTAssertEqual(jitter.dequeue()?.sequence, 10)
        XCTAssertEqual(jitter.dequeue()?.sequence, 11)
        let concealed = jitter.dequeue()
        XCTAssertEqual(concealed?.sequence, 12)
        XCTAssertTrue(concealed?.concealed == true)
        XCTAssertEqual(jitter.dequeue()?.sequence, 13)
    }

    @MainActor
    func testVoBLEStreamingReplenishesBeforeDevicePresentationFinishes() async throws {
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 8_000, channels: 1, interleaved: false))
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 160)
        try engine.start()
        defer { player.stop(); engine.stop() }
        let consumed = expectation(description: "streaming buffer can be replenished without a device sink")
        consumed.expectedFulfillmentCount = 3
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160))
        buffer.frameLength = 160
        for _ in 0..<3 {
            VoBLEPlaybackScheduling.schedule(buffer, on: player) { consumed.fulfill() }
        }
        player.play()
        let output = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160))
        for _ in 0..<8 { _ = try engine.renderOffline(160, to: output) }
        await fulfillment(of: [consumed], timeout: 1)
    }

    func testBluetoothAudioStatusIgnoresInactiveWiFiAndStaleCloudState() {
        for cloud in [CloudCallAudioState.idle, .failed("old relay failure")] {
            XCTAssertEqual(CallAudioStatusPresentation.text(
                transport: .bluetooth, bluetoothRunning: true, bluetoothError: nil,
                localAudioActive: false, cloudState: cloud), "Bluetooth Audio Connected")
        }
        XCTAssertEqual(CallAudioStatusPresentation.text(
            transport: .bluetooth, bluetoothRunning: false, bluetoothError: "音频启动失败",
            localAudioActive: true, cloudState: .connected), "音频启动失败")
    }

    func testVoBLEReconnectWaitsForOldDisconnectionAndIgnoresUnrelatedCallback() {
        let old = UUID(), other = UUID()
        var barrier = VoBLEReconnectBarrier()
        barrier.begin(old)
        XCTAssertFalse(barrier.permitsConnection)
        XCTAssertFalse(barrier.finish(other))
        XCTAssertFalse(barrier.permitsConnection)
        XCTAssertEqual(barrier.disconnectingID, old)
        XCTAssertTrue(barrier.finish(old))
        XCTAssertTrue(barrier.permitsConnection)
        XCTAssertFalse(barrier.finish(old))
    }

    func testVoBLECancellationCanRecoverFromMissingCallbackOnlyAfterActualDisconnection() {
        let old = UUID(), other = UUID()
        var barrier = VoBLEReconnectBarrier()
        barrier.begin(old)
        XCTAssertFalse(barrier.finishIfDisconnected(other, state: .disconnected))
        for state: CBPeripheralState in [.connecting, .connected, .disconnecting] {
            XCTAssertFalse(barrier.finishIfDisconnected(old, state: state))
            XCTAssertFalse(barrier.permitsConnection)
        }
        XCTAssertTrue(barrier.finishIfDisconnected(old, state: .disconnected))
        XCTAssertTrue(barrier.permitsConnection)
        XCTAssertFalse(barrier.finishIfDisconnected(old, state: .disconnected))
    }

    func testVoBLEJitterUnderflowDoesNotDiscardDelayedAudio() {
        var jitter = VoBLEJitterBuffer(targetFrames: 3)
        let pcm = Data(repeating: 1, count: 320)
        for sequence in UInt32(10)...12 { XCTAssertTrue(jitter.insert(sequence: sequence, pcm: pcm)) }
        for sequence in UInt32(10)...12 { XCTAssertEqual(jitter.dequeue()?.sequence, sequence) }
        for _ in 0..<20 { XCTAssertNil(jitter.dequeue()) }
        for sequence in UInt32(13)...15 { XCTAssertTrue(jitter.insert(sequence: sequence, pcm: pcm)) }
        XCTAssertEqual(jitter.dequeue()?.sequence, 13)
        XCTAssertEqual(jitter.dequeue()?.concealed, false)
    }

    func testVoBLEJitterOverflowRetainsRecentAudioInsteadOfGrowingLatency() {
        var jitter = VoBLEJitterBuffer(targetFrames: 3)
        let pcm = Data(repeating: 1, count: 320)
        for sequence in UInt32(0)...8 { XCTAssertTrue(jitter.insert(sequence: sequence, pcm: pcm)) }
        XCTAssertEqual(jitter.dequeue()?.sequence, 1)
        for sequence in UInt32(2)...8 { XCTAssertEqual(jitter.dequeue()?.sequence, sequence) }
        XCTAssertNil(jitter.dequeue())
        XCTAssertFalse(jitter.insert(sequence: 0, pcm: pcm))
    }

    func testVoBLEJitterLongGapDoesNotRepeatOldSpeech() {
        var jitter = VoBLEJitterBuffer(targetFrames: 3)
        let pcm = Data(repeating: 1, count: 320)
        for sequence in [UInt32(0), 1, 20] { XCTAssertTrue(jitter.insert(sequence: sequence, pcm: pcm)) }
        XCTAssertEqual(jitter.dequeue()?.sequence, 0)
        XCTAssertEqual(jitter.dequeue()?.sequence, 1)
        let recovered = jitter.dequeue()
        XCTAssertEqual(recovered?.sequence, 20)
        XCTAssertEqual(recovered?.concealed, false)
    }

    func testVoBLEJitterAdaptsWithinThreeToEightFrames() {
        var jitter = VoBLEJitterBuffer(targetFrames: 4)
        for _ in 0..<10 { jitter.noteDiscontinuity() }
        XCTAssertEqual(jitter.targetFrames, 8)

        for sequence in 0..<60 {
            XCTAssertTrue(jitter.insert(sequence: UInt32(sequence), pcm: Data(repeating: 0, count: 320)))
            _ = jitter.dequeue()
        }
        XCTAssertEqual(jitter.targetFrames, 7)
    }

    @MainActor
    func testVoBLETransportBackpressureBoundsEightFramesAndRejectsStaleCall() async throws {
        let writer = VoBLEWriterProbe(canSend: false, maximumLength: 185)
        let transport = VoBLEGATTMediaTransport(writer: writer)
        try transport.start(identity: .init(callID: "call-a", generation: 4),
                            mediaKey: Data(repeating: 7, count: 32))
        for _ in 0..<10 { transport.enqueueCapturedPCM(Data(repeating: 1, count: 320)) }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(transport.queuedFrameCount, 8)
        XCTAssertEqual(transport.droppedFrameCount, 2)
        XCTAssertTrue(writer.writes.isEmpty)
        writer.canSend = true
        transport.peripheralIsReadyToSend()
        XCTAssertFalse(writer.writes.isEmpty)
        transport.stop(identity: .init(callID: "other", generation: 4))
        XCTAssertTrue(transport.isRunning)
        transport.stop(identity: .init(callID: "call-a", generation: 4))
        XCTAssertFalse(transport.isRunning)
    }

    func testVoBLEAudioGateRequiresMediaAndCallKit() {
        var gate = VoBLEAudioStartGate()
        gate.mediaReady = true
        XCTAssertFalse(gate.canStart)
        gate.callKitAudioActive = true
        XCTAssertTrue(gate.canStart)
        gate.mediaReady = false
        XCTAssertFalse(gate.canStart)
    }

    func testVoBLEAppManagedAudioDoesNotWaitForCallKit() {
        var gate = VoBLEAudioStartGate()
        gate.mediaReady = true
        XCTAssertFalse(gate.canStart)
        gate.appAudioSessionActive = true
        XCTAssertTrue(gate.canStart)
        gate.mediaReady = false
        XCTAssertFalse(gate.canStart)
        gate.mediaReady = true
        gate.appAudioSessionActive = false
        XCTAssertFalse(gate.canStart)
    }

    func testVoBLEOutgoingAdoptsAndroidCallIDAndStartsMediaOnce() {
        var lifecycle = VoBLECallLifecycleReducer()
        let pending = lifecycle.beginOutgoing(
            callID: "pending", generation: 4, number: "10086")
        XCTAssertEqual(pending.direction, "outgoing")
        XCTAssertTrue(pending.isProvisional)

        let event = VoBLEAndroidEvent(
            callID: "android-call", generation: 4, direction: "outgoing",
            state: "active", number: "10086")
        guard case let .active(active, startMedia) = lifecycle.apply(event) else {
            return XCTFail("expected active")
        }
        XCTAssertEqual(active.callID, "android-call")
        XCTAssertEqual(active.uuid, pending.uuid)
        XCTAssertFalse(active.isProvisional)
        XCTAssertTrue(startMedia)
        guard case let .active(repeated, repeatedStart) = lifecycle.apply(event) else {
            return XCTFail("expected repeated active")
        }
        XCTAssertEqual(repeated, active)
        XCTAssertFalse(repeatedStart)
    }

    func testVoBLEMatchingEndCleansUpOnceAndStaleEndIsIgnored() {
        var lifecycle = VoBLECallLifecycleReducer()
        _ = lifecycle.apply(VoBLEAndroidEvent(
            callID: "call-7", generation: 7, direction: "incoming",
            state: "incoming", number: "123"))
        XCTAssertEqual(lifecycle.current?.callID, "call-7")

        XCTAssertEqual(lifecycle.apply(VoBLEAndroidEvent(
            callID: "old", generation: 6, direction: "incoming",
            state: "ended", number: "")), .ignored)
        let end = VoBLEAndroidEvent(
            callID: "call-7", generation: 7, direction: "incoming",
            state: "ended", number: "")
        guard case .ended = lifecycle.apply(end) else { return XCTFail("expected ended") }
        XCTAssertNil(lifecycle.current)
        XCTAssertEqual(lifecycle.apply(end), .ignored)
    }

    func testWatchPayloadCarriesBluetoothTransport() {
        let payload = WatchCallPayload(
            callID: "ble-call", callUUID: UUID(), phase: .active,
            number: "10010", callerName: nil, transport: "bluetooth",
            updatedAt: Date(timeIntervalSince1970: 42))
        XCTAssertEqual(payload.dictionary["transport"] as? String, "bluetooth")
        XCTAssertEqual(WatchCallPayload(dictionary: payload.dictionary)?.transport, "bluetooth")
    }

    func testVoBLEDiagnosticsRedactsSecretsAndMedia() {
        let sanitized = VoBLEDiagnosticsSnapshot.sanitize([
            "pcm_ready": "true",
            "phone_number": "+8613800000000",
            "media_key": "secret",
            "nonce": "secret",
            "authentication_tag": "secret",
            "audio_payload": "secret",
        ])
        XCTAssertEqual(sanitized, ["pcm_ready": "true"])
    }

    func testVoBLERecoveryAcceptsOnlySameGenerationWithinThreeSeconds() {
        let start = Date(timeIntervalSince1970: 100)
        let identity = VoBLEMediaSessionIdentity(callID: "call-4", generation: 4)
        let recovery = VoBLERecoveryPolicy(identity: identity, disconnectedAt: start)
        XCTAssertTrue(recovery.accepts(identity, at: start.addingTimeInterval(2.9)))
        XCTAssertFalse(recovery.accepts(
            .init(callID: "call-4", generation: 5), at: start.addingTimeInterval(1)))
        XCTAssertFalse(recovery.accepts(identity, at: start.addingTimeInterval(3.1)))
    }

    func testDialPadCanPresentBluetoothAsIndependentTransport() {
        let route = DialPadTransportPresentation.make(
            mode: .bluetooth,
            vowlanOnline: false, moduleLocalReachable: false,
            cloudOnline: false, bluetoothReady: true)
        XCTAssertEqual(route?.transport, .bluetooth)
        XCTAssertEqual(route?.title, "Bluetooth")
    }

    func testVoBLEControlEnvelopeRoundTripsAndRejectsBadMagic() throws {
        let envelope = VoBLEControlEnvelope(
            command: "answer", callID: "call-7", generation: 0x0102030405060708,
            sessionID: Data([1, 2, 3, 4]), nonce: Data(repeating: 5, count: 12),
            ciphertext: Data([6, 7, 8]), authenticationTag: Data(repeating: 9, count: 16)
        )
        let encoded = try envelope.encoded()
        XCTAssertEqual(Array(encoded[4..<12]), [1, 2, 3, 4, 5, 6, 7, 8])
        XCTAssertEqual(try VoBLEControlEnvelope.decode(encoded), envelope)

        var corrupted = encoded
        corrupted[0] = 0
        XCTAssertThrowsError(try VoBLEControlEnvelope.decode(corrupted))

        for maximumPacketLength in [23, 185, 247] {
            let fragments = try VoBLEMessageFragmenter.encode(
                encoded, type: .control, messageID: 0x1234,
                maximumPacketLength: maximumPacketLength)
            XCTAssertTrue(fragments.allSatisfy { $0.count <= maximumPacketLength })
            var reassembler = VoBLEMessageReassembler()
            var message: VoBLEMessage?
            for fragment in fragments {
                message = try reassembler.append(
                    fragment, now: Date(timeIntervalSince1970: 10)) ?? message
            }
            XCTAssertEqual(message?.messageID, 0x1234)
            XCTAssertEqual(message?.payload, encoded)
        }
    }

    func testVoBLEPairingTranscriptAndSessionKeysAreDeterministic() throws {
        let androidPrivate = Data((1...32).map(UInt8.init))
        let iphonePrivate = Data((33...64).map(UInt8.init))
        let androidPublic = try Curve25519.KeyAgreement.PrivateKey(
            rawRepresentation: androidPrivate).publicKey.rawRepresentation
        let iphonePublic = try Curve25519.KeyAgreement.PrivateKey(
            rawRepresentation: iphonePrivate).publicKey.rawRepresentation
        let transcript = VoBLEPairingTranscript(
            androidIdentity: "samsung-test", androidPublicKey: androidPublic,
            iphonePublicKey: iphonePublic,
            androidNonce: Data(repeating: 0x11, count: 32),
            iphoneNonce: Data(repeating: 0x22, count: 32)
        )
        let android = try VoBLESessionAuthenticator.derivePairing(
            privateKey: androidPrivate, peerPublicKey: iphonePublic, transcript: transcript)
        let iphone = try VoBLESessionAuthenticator.derivePairing(
            privateKey: iphonePrivate, peerPublicKey: androidPublic, transcript: transcript)
        XCTAssertEqual(android, iphone)
        XCTAssertEqual(android.pairingKey.map { String(format: "%02x", $0) }.joined(),
                       "41cef6294f3575441997664149bd8a014c8db026ad3a5312410be90f7d76c48a")
        XCTAssertEqual(android.sas, "922247")

        let modified = VoBLEPairingTranscript(
            androidIdentity: "samsung-modified", androidPublicKey: androidPublic,
            iphonePublicKey: iphonePublic,
            androidNonce: Data(repeating: 0x11, count: 32),
            iphoneNonce: Data(repeating: 0x22, count: 32)
        )
        let modifiedMaterial = try VoBLESessionAuthenticator.derivePairing(
            privateKey: androidPrivate, peerPublicKey: iphonePublic, transcript: modified)
        XCTAssertNotEqual(modifiedMaterial.pairingKey, android.pairingKey)

        let first = try VoBLESessionAuthenticator.deriveSessionKeys(
            pairingKey: android.pairingKey, sessionID: Data(repeating: 3, count: 16),
            callID: "call-1", generation: 1)
        let reconnect = try VoBLESessionAuthenticator.deriveSessionKeys(
            pairingKey: android.pairingKey, sessionID: Data(repeating: 4, count: 16),
            callID: "call-1", generation: 1)
        XCTAssertNotEqual(first.control, first.media)
        XCTAssertNotEqual(first.media, first.reconnect)
        XCTAssertNotEqual(first, reconnect)
        XCTAssertEqual(try VoBLESessionAuthenticator.deriveSessionKeys(
            pairingKey: android.pairingKey, sessionID: Data(repeating: 5, count: 16),
            callID: "", generation: 0).control.count, 32)
        let message = Data("authenticated-control".utf8)
        let tag = try VoBLESessionAuthenticator.tag(message: message, key: first.control)
        XCTAssertTrue(VoBLESessionAuthenticator.authenticate(
            message: message, tag: tag, key: first.control))
        XCTAssertFalse(VoBLESessionAuthenticator.authenticate(
            message: message, tag: tag, key: Data(repeating: 0, count: 32)))
        let reconnectTag = try VoBLESessionAuthenticator.reconnectTag(
            pairingKey: android.pairingKey, transcript: transcript)
        XCTAssertEqual(reconnectTag.count, 16)
        XCTAssertEqual(reconnectTag.map { String(format: "%02x", $0) }.joined(),
                       "a09d46e2afc3444bffc9013831d265c7")
        XCTAssertEqual(reconnectTag, try VoBLESessionAuthenticator.reconnectTag(
            pairingKey: android.pairingKey, transcript: transcript))
        XCTAssertNotEqual(reconnectTag, try VoBLESessionAuthenticator.reconnectTag(
            pairingKey: android.pairingKey, transcript: modified))
        XCTAssertEqual(try VoBLESessionAuthenticator.confirmationTag(
            pairingKey: android.pairingKey, challengeID: "challenge-1").count, 16)
    }

    func testVoBLEReplayWindowRejectsDuplicateExpiredAndRevokedPeer() {
        let now = Date(timeIntervalSince1970: 100)
        var window = VoBLEReplayWindow(maximumAge: 30, capacity: 4)
        XCTAssertTrue(window.accept(nonce: Data([1]), timestamp: now, now: now))
        XCTAssertFalse(window.accept(nonce: Data([1]), timestamp: now, now: now))
        XCTAssertFalse(window.accept(
            nonce: Data([2]), timestamp: now.addingTimeInterval(-31), now: now))
        window.revoke()
        XCTAssertFalse(window.accept(nonce: Data([3]), timestamp: now, now: now))
    }

    func testVoBLEConnectionRequiresAuthenticationAndControlSubscription() {
        var reducer = VoBLEConnectionReducer()
        reducer.apply(.bluetoothPoweredOn)
        reducer.apply(.discovered(UUID()))
        reducer.apply(.connected)
        reducer.apply(.characteristicsReady)
        reducer.apply(.controlSubscription(true))
        XCTAssertNotEqual(reducer.state, .ready)

        reducer.apply(.authenticationFailed("wrong key"))
        XCTAssertEqual(reducer.state, .failed("wrong key"))
        reducer.apply(.restored(UUID()))
        XCTAssertEqual(reducer.state, .connecting)
        reducer.apply(.characteristicsReady)
        reducer.apply(.controlSubscription(true))
        reducer.apply(.authenticated(identity: "samsung-test"))
        XCTAssertEqual(reducer.state, .ready)
    }

    func testVoBLEPairingFailureExplainsHowToRecoverStaleCredentials() {
        XCTAssertEqual(
            VoBLEPairingRecovery.userMessage(for: "peer is already paired; authenticated reconnect required"),
            "Android still has old VoBLE credentials. Clear the old pairing in Android AirSIM → Settings → VoBLE Authentication, then pair again."
        )
        XCTAssertEqual(
            VoBLEPairingRecovery.userMessage(for: "reconnect authentication failed"),
            "VoBLE keys do not match. Clear the old pairing in Android AirSIM → Settings → VoBLE Authentication, then pair again."
        )
        XCTAssertEqual(
            VoBLEPairingRecovery.userMessage(for: "peer is not paired"),
            "Android no longer has matching VoBLE credentials. Clear local credentials, then verify the security code again."
        )
        XCTAssertEqual(VoBLEPairingRecovery.userMessage(for: "蓝牙配对失败"), "蓝牙配对失败")
    }

    func testVoBLEControlLedgerRejectsStaleResponseAndExpiresDeadline() {
        var ledger = VoBLEControlRequestLedger()
        let now = Date(timeIntervalSince1970: 100)
        ledger.begin(requestID: "request-1", generation: 7, deadline: now.addingTimeInterval(1))
        XCTAssertEqual(ledger.resolve(requestID: "request-1", generation: 6), .stale)
        XCTAssertEqual(ledger.resolve(requestID: "missing", generation: 7), .missing)
        XCTAssertEqual(ledger.expire(now: now.addingTimeInterval(1.001)), ["request-1"])
    }

    @MainActor
    func testExplicitBluetoothFailureDoesNotStartVoWLANOrCloud() {
        final class FakeBluetooth: VoBLECentralControlling {
            var starts = 0
            var stops = 0
            func start() { starts += 1 }
            func stop() { stops += 1 }
        }
        let bluetooth = FakeBluetooth()
        let controller = VoBLEModeController(bluetooth: bluetooth)
        let actions = controller.activate(.bluetooth)
        XCTAssertEqual(bluetooth.starts, 1)
        XCTAssertFalse(actions.startVoWLAN)
        XCTAssertFalse(actions.startCloud)
        XCTAssertFalse(controller.shouldFallbackAfterBluetoothFailure)
    }

    @MainActor
    func testRemovingPairingResumesScanningButDoesNotReactivateDisabledMode() {
        final class BluetoothTransport: VoBLECentralControlling {
            var operations: [String] = []
            func start() { operations.append("scan") }
            func stop() { operations.append("disconnect") }
        }
        let bluetooth = BluetoothTransport()
        VoBLEPairingConnectionReset.perform(on: bluetooth, resumeScanning: true)
        XCTAssertEqual(bluetooth.operations, ["disconnect", "scan"])
        bluetooth.operations.removeAll()
        VoBLEPairingConnectionReset.perform(on: bluetooth, resumeScanning: false)
        XCTAssertEqual(bluetooth.operations, ["disconnect"])
    }

    func testVoBLECachedConnectionExpiresWithoutInterruptingAuthenticationOrReadyPeer() {
        XCTAssertFalse(VoBLEConnectionTimeoutPolicy.shouldExpire(
            state: .connecting, enabled: true, elapsed: 7.9))
        XCTAssertTrue(VoBLEConnectionTimeoutPolicy.shouldExpire(
            state: .connecting, enabled: true, elapsed: 8))
        XCTAssertFalse(VoBLEConnectionTimeoutPolicy.shouldExpire(
            state: .connecting, enabled: false, elapsed: 20))
        for state in [VoBLEConnectionState.authenticating, .ready, .stopped] {
            XCTAssertFalse(VoBLEConnectionTimeoutPolicy.shouldExpire(
                state: state, enabled: true, elapsed: 20))
        }
    }

    func testConnectionModePreferenceMigratesLegacyLocalModeAndPersistsBluetooth() {
        let suite = "airsim-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set(true, forKey: LocalModePreference.key)
        XCTAssertEqual(ConnectionModePreference.selected(defaults: defaults), .vowlan)

        ConnectionModePreference.set(.bluetooth, defaults: defaults)
        XCTAssertEqual(ConnectionModePreference.selected(defaults: defaults), .bluetooth)
        XCTAssertFalse(LocalModePreference.isEnabled(defaults: defaults))
        XCTAssertFalse(CloudModePreference.isEnabled(defaults: defaults))
    }

    @MainActor
    func testVoWLANTransportFailureFallsBackOnceToCloud() async throws {
        let local = OutgoingCallServiceProbe(dialError: URLError(.timedOut))
        var cloudAttempts = 0

        let result = try await OutgoingCallRouteCoordinator.start(
            number: "10086",
            vowlanService: local,
            cloudModeEnabled: true
        ) {
            cloudAttempts += 1
            return "cloud-call"
        }

        XCTAssertEqual(result, .cloud("cloud-call"))
        XCTAssertEqual(cloudAttempts, 1)
        let localActions = await local.recordedActions()
        XCTAssertEqual(localActions, ["warm", "dial:10086"])
    }

    @MainActor
    func testVoWLANAgentRejectionDoesNotReplayDialThroughCloud() async {
        let local = OutgoingCallServiceProbe(
            dialError: APIError.http(502, "Android Telecom 拒绝拨号")
        )
        var cloudAttempts = 0

        do {
            _ = try await OutgoingCallRouteCoordinator.start(
                number: "10086",
                vowlanService: local,
                cloudModeEnabled: true
            ) {
                cloudAttempts += 1
                return "cloud-call"
            }
            XCTFail("Agent 已明确拒绝时不得通过云端重放非幂等拨号")
        } catch APIError.http(let status, _) {
            XCTAssertEqual(status, 502)
        } catch {
            XCTFail("预期保留 Agent HTTP 错误，实际为 \(error)")
        }

        XCTAssertEqual(cloudAttempts, 0)
    }

    func testVoWLANDialWaitsPastSamsungTelecomAcknowledgementWindow() {
        XCTAssertGreaterThan(AirSIMAPI.voWLANDialTimeout, 12)
    }

    func testMaintainerBundleUsesDedicatedRelayFallback() {
        XCTAssertEqual(
            RelayConfiguration.effectiveURL(
                stored: nil,
                buildSetting: "",
                bundleID: "com.eric3u.airsim"
            ),
            "https://airsim-push.remotepilot.site"
        )
        XCTAssertEqual(
            RelayConfiguration.effectiveURL(
                stored: nil,
                buildSetting: "",
                bundleID: "org.example.airsim"
            ),
            ""
        )
        XCTAssertEqual(
            RelayConfiguration.effectiveURL(
                stored: "https://push.remotepilot.site/",
                buildSetting: "",
                bundleID: "com.eric3u.airsim"
            ),
            "https://airsim-push.remotepilot.site"
        )
        XCTAssertEqual(
            RelayConfiguration.effectiveURL(
                stored: "https://push.remotepilot.site/",
                buildSetting: "",
                bundleID: "org.example.airsim"
            ),
            "https://push.remotepilot.site/"
        )
    }

    func testRelayHealthRequiresAirSIMServiceIdentity() {
        let airSIM = Data(#"{"ok":true,"service":"airsim-push-relay","version":"0.2.1"}"#.utf8)
        let djonehub = Data(#"{"ok":true,"service":"djonehub-push-relay","version":"1.0.0"}"#.utf8)
        XCTAssertTrue(RelayHealthValidation.accepts(statusCode: 200, data: airSIM))
        XCTAssertFalse(RelayHealthValidation.accepts(statusCode: 200, data: djonehub))
        XCTAssertFalse(RelayHealthValidation.accepts(statusCode: 503, data: airSIM))
    }

    func testRelayQuotaResponseExplainsRegistrationFailure() {
        let response = Data("error code: 1027".utf8)
        let error = CloudAgentStatusError.relayFailure(statusCode: 429, data: response)
        guard case .requestLimitExceeded = error else {
            return XCTFail("Cloudflare 1027 must not be reported as an invalid Relay response")
        }
        XCTAssertTrue(error.localizedDescription.contains("quota"))
    }

    func testCurrentModePrefersVoWLANAndReportsCloudFailure() {
        XCTAssertEqual(
            ConnectionModePresentation.make(
                selectedMode: .automatic,
                vowlanOnline: true,
                bluetoothReady: true,
                cloudModeEnabled: true,
                cloudOnline: true
            ).mode,
            .vowlan
        )
        let bluetooth = ConnectionModePresentation.make(
            selectedMode: .automatic,
            vowlanOnline: false,
            bluetoothReady: true,
            cloudModeEnabled: true,
            cloudOnline: true
        )
        XCTAssertEqual(bluetooth.mode, .bluetooth)
        XCTAssertEqual(bluetooth.status, "Connected")
        let cloud = ConnectionModePresentation.make(
            selectedMode: .automatic,
            vowlanOnline: false,
            bluetoothReady: false,
            cloudModeEnabled: true,
            cloudOnline: true
        )
        XCTAssertEqual(cloud.mode, .cloud)
        XCTAssertEqual(cloud.status, "Connected")

        let unreachable = ConnectionModePresentation.make(
            selectedMode: .cloud,
            vowlanOnline: false,
            bluetoothReady: false,
            cloudModeEnabled: true,
            cloudOnline: false
        )
        XCTAssertEqual(unreachable.mode, .cloud)
        XCTAssertEqual(unreachable.status, "Unreachable")
    }

    func testCloudSelfTestReportOnlyPassesWhenEveryStagePasses() {
        var report = CloudSelfTestReport.initial
        XCTAssertFalse(report.allPassed)
        XCTAssertEqual(report.steps.map(\.id), CloudSelfTestStepID.allCases)

        for id in CloudSelfTestStepID.allCases {
            report.update(id, state: .passed, detail: "通过")
        }
        report.completedAt = Date()
        XCTAssertTrue(report.allPassed)

        report.update(.agentHeartbeat, state: .failed, detail: "无心跳")
        XCTAssertFalse(report.allPassed)
    }

    func testLiveActivityIncludesCurrentAndroidAgentIdentity() {
        let agent = AndroidAgentPresentation(
            id: "samsung-1",
            deviceName: "samsung SM-F766U",
            phoneNumber: "+8615502030017",
            agentKind: "standalone",
            cloudOnline: true,
            vowlanOnline: true,
            bluetoothOnline: true,
            isCurrent: true
        )
        let state = LiveActivityStateBuilder.make(
            call: nil,
            callerName: nil,
            moduleOnline: true,
            transport: .vowlan,
            radio: nil,
            agent: LiveActivityAgentSnapshot(agent: agent, pairedAgentCount: 2),
            idleStartedAt: Date(timeIntervalSince1970: 1)
        )

        XCTAssertEqual(state.agentDeviceName, "samsung SM-F766U")
        XCTAssertEqual(state.agentPhoneNumber, "+8615502030017")
        XCTAssertEqual(state.agentKind, "standalone")
        XCTAssertEqual(state.pairedAgentCount, 2)
        XCTAssertEqual(state.vowlanOnline, true)
        XCTAssertEqual(state.bluetoothOnline, true)
        XCTAssertEqual(state.cloudOnline, true)
    }

    func testHiddenLiveActivityDoesNotRegisterPushToStartToken() {
        let suiteName = "AirSIMTests.live-activity.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(
            LiveActivityVisibilityPreference.registrationToken("abc123", defaults: defaults),
            "abc123"
        )
        defaults.set(false, forKey: LiveActivityVisibilityPreference.key)
        XCTAssertEqual(
            LiveActivityVisibilityPreference.registrationToken("abc123", defaults: defaults),
            ""
        )
    }

    func testLocalModeLiveActivityDoesNotRequestRemotePushUpdates() {
        XCTAssertNil(LiveActivityCreationPolicy.pushType(localModeEnabled: true))
        XCTAssertNotNil(LiveActivityCreationPolicy.pushType(localModeEnabled: false))
    }

    func testVoWLANRecoveryRetriesAfterTemporaryVPNRouteLoss() {
        var recovery = VoWLANRecoveryGate()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let unavailable = VoWLANAvailability.unavailable("VPN 路由切换")

        XCTAssertTrue(recovery.shouldAttempt(for: unavailable, at: start))
        XCTAssertFalse(recovery.shouldAttempt(for: unavailable, at: start.addingTimeInterval(3)))
        XCTAssertTrue(recovery.shouldAttempt(for: unavailable, at: start.addingTimeInterval(10)))
        XCTAssertFalse(recovery.shouldAttempt(for: .unpaired, at: start.addingTimeInterval(20)))
    }

    func testIslandCallActionsReserveOnlyRightSideButtonWidth() {
        typealias Phase = AirSIMCallActivityAttributes.ContentState.Phase
        XCTAssertEqual(IslandActionLayout.reservedWidth(for: Phase.incoming), 96)
        XCTAssertEqual(IslandActionLayout.reservedWidth(for: Phase.active), 44)
        XCTAssertEqual(IslandActionLayout.reservedWidth(for: Phase.held), 44)
        XCTAssertEqual(IslandActionLayout.reservedWidth(for: Phase.standby), 0)
    }

    func testLiveActivityStateDecodesLegacyPayloadWithoutAgentFields() throws {
        let state = AirSIMCallActivityAttributes.ContentState(
            callID: "",
            number: "",
            displayName: "等待模块来电",
            phase: .standby,
            startedAt: Date(timeIntervalSince1970: 1),
            transport: .vowlan
        )
        let encoded = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(
            AirSIMCallActivityAttributes.ContentState.self,
            from: encoded
        )

        XCTAssertNil(decoded.agentDeviceName)
        XCTAssertNil(decoded.agentPhoneNumber)
        XCTAssertNil(decoded.pairedAgentCount)
    }

    func testLocalModeForcesEffectiveCloudModeOff() {
        let suiteName = "AirSIMTests.local-mode.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: LocalModePreference.key)
        defaults.set(true, forKey: CloudModePreference.key)

        XCTAssertTrue(LocalModePreference.isEnabled(defaults: defaults))
        XCTAssertFalse(CloudModePreference.isEnabled(defaults: defaults))
    }

    func testLocalPairingChoiceDoesNotReadCloudCredentialsOrChangeGlobalMode() throws {
        let suite = "AirSIMTests.pairing-choice.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: LocalModePreference.key)
        let registration = try SamsungPairingRegistrationPolicy.registration(
            localOnly: true, vowlanSecret: "fixture-key",
            cloudRegistration: { XCTFail("local pairing must not request push credentials"); return nil }
        )
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(registration)) as? [String: Any])
        XCTAssertEqual(payload["vowlan_secret"] as? String, "fixture-key")
        XCTAssertNil(payload["relay_url"])
        XCTAssertFalse(LocalModePreference.isEnabled(defaults: defaults))
    }

    func testCloudPairingChoiceRequiresCredentialsWithoutFallingBackToLocal() throws {
        XCTAssertThrowsError(try SamsungPairingRegistrationPolicy.registration(
            localOnly: false, vowlanSecret: "fixture-key", cloudRegistration: { nil }
        ))
        var cloud = AgentPushRegistration.local(vowlanSecret: "old-key")
        cloud.localMode = false
        let registration = try SamsungPairingRegistrationPolicy.registration(
            localOnly: false, vowlanSecret: "new-key", cloudRegistration: { cloud }
        )
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(registration)) as? [String: Any])
        XCTAssertEqual(payload["local_mode"] as? Bool, false)
        XCTAssertEqual(payload["vowlan_secret"] as? String, "new-key")
        XCTAssertNotNil(payload["relay_url"])
    }

    @MainActor
    func testLocalPairingWaitsForOldAgentWriteAndBlocksNewWrites() async throws {
        let gate = SamsungPairingRegistrationGate()
        XCTAssertTrue(gate.beginAgentWrite())
        var pairingStarted = false
        let pair = Task { @MainActor in
            try await gate.withPairing {
                pairingStarted = true
                XCTAssertFalse(gate.beginAgentWrite())
            }
        }
        await Task.yield()
        XCTAssertFalse(pairingStarted, "old cloud write must finish before local claim")
        XCTAssertFalse(gate.beginAgentWrite(), "no new cloud write while pairing is waiting")
        gate.endAgentWrite()
        try await pair.value
        XCTAssertTrue(pairingStarted)
        XCTAssertTrue(gate.beginAgentWrite(), "other/global operations resume after pairing")
        gate.endAgentWrite()
    }

    @MainActor
    func testPairingFailureReleasesAgentWriteGate() async throws {
        let gate = SamsungPairingRegistrationGate()
        do {
            try await gate.withPairing { throw SamsungPairingClientError.expired }
            XCTFail("pairing must fail")
        } catch { /* preserve original error, unlock for retry */ }
        XCTAssertTrue(gate.beginAgentWrite())
        gate.endAgentWrite()
    }

    func testAutomaticRegistrationPreservesLocalPairingForStandaloneAndLegacyAgent() throws {
        for json in [
            #"{"local_mode":true,"configured":true,"cloud_enabled":false,"call_push_ready":false,"message_push_ready":false}"#,
            #"{"configured":true,"cloud_enabled":false,"call_push_ready":false,"message_push_ready":false}"#
        ] {
            let status = try JSONDecoder().decode(AgentPushStatus.self, from: Data(json.utf8))
            XCTAssertTrue(status.preservesLocalPairing)
        }
        let unconfigured = try JSONDecoder().decode(AgentPushStatus.self, from: Data(
            #"{"configured":false,"cloud_enabled":false,"call_push_ready":false,"message_push_ready":false}"#.utf8))
        XCTAssertFalse(unconfigured.preservesLocalPairing)
        let cloud = try JSONDecoder().decode(AgentPushStatus.self, from: Data(
            #"{"local_mode":false,"configured":true,"cloud_enabled":false,"relay_url":"https://relay.example","call_push_ready":false,"message_push_ready":false}"#.utf8))
        XCTAssertFalse(cloud.preservesLocalPairing)
    }

    func testLocalPairingPayloadOmitsRelayAndPushCredentials() throws {
        let registration = AgentPushRegistration.local(vowlanSecret: "local-vowlan-secret")
        let data = try JSONEncoder().encode(registration)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(payload["local_mode"] as? Bool, true)
        XCTAssertEqual(payload["cloud_enabled"] as? Bool, false)
        XCTAssertEqual(payload["vowlan_secret"] as? String, "local-vowlan-secret")
        XCTAssertNil(payload["relay_url"])
        XCTAssertNil(payload["device_id"])
        XCTAssertNil(payload["device_secret"])
        XCTAssertNil(payload["voip_token"])
        XCTAssertNil(payload["alert_token"])
    }
}
