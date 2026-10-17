import Foundation

struct VoBLEPlaybackFrame: Equatable, Sendable {
    let sequence: UInt32
    let pcm: Data
    let concealed: Bool
}

struct VoBLEMediaSessionIdentity: Equatable, Sendable {
    let callID: String
    let generation: UInt64
}

@MainActor
protocol VoBLEMediaWriting: AnyObject {
    var canSendWriteWithoutResponse: Bool { get }
    var maximumWriteLength: Int { get }
    func writeWithoutResponse(_ data: Data)
}

/// Bluetooth is not a call audio route. This transport keeps the session
/// identity for control teardown and does not encode, notify, or play audio.
@MainActor
final class VoBLEGATTMediaTransport {
    private let writer: any VoBLEMediaWriting
    private var identity: VoBLEMediaSessionIdentity?

    init(writer: any VoBLEMediaWriting) { self.writer = writer }
    var queuedFrameCount: Int { 0 }
    var isRunning: Bool { identity != nil }
    var droppedFrameCount: Int { 0 }
    var diagnosticSummary: String { "" }
    var jitterTargetFrames: Int { 0 }

    func start(identity: VoBLEMediaSessionIdentity, mediaKey: Data) throws {
        guard !identity.callID.isEmpty, identity.generation > 0, mediaKey.count == 32 else {
            throw VoBLEPairingError.invalidKey
        }
        _ = writer.maximumWriteLength
        self.identity = identity
    }

    func stop(identity candidate: VoBLEMediaSessionIdentity) {
        guard candidate == identity else { return }
        identity = nil
    }

    func enqueueCapturedPCM(_ pcm: Data) {
        _ = pcm
    }

    func peripheralIsReadyToSend() {}

    func receiveDownlinkFragment(_ fragment: Data, now: Date = Date()) {
        _ = (fragment, now)
    }

    func dequeuePlayback() -> VoBLEPlaybackFrame? { nil }
}

struct VoBLEAudioStartGate: Equatable, Sendable {
    var mediaReady = false
    var callKitAudioActive = false
    var appAudioSessionActive = false
    var canStart: Bool { mediaReady && (callKitAudioActive || appAudioSessionActive) }
}
