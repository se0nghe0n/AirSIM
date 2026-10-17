import Foundation
import WebRTC

/// Passive observers: the native device, codec, and voice processing remain in charge.
final class CloudWebRTCRecordingAudio {
    private let capture = CallRecordingWebRTCObserver(channel: .local)
    private let render = CallRecordingWebRTCObserver(channel: .remote)
    let module: RTCDefaultAudioProcessingModule

    init() {
        module = RTCDefaultAudioProcessingModule(
            config: nil, capturePostProcessingDelegate: capture,
            renderPreProcessingDelegate: render)
    }
}

private final class CallRecordingWebRTCObserver: NSObject, RTCAudioCustomProcessingDelegate {
    private let channel: CallRecordingChannel
    // Each delegate is initialized and called on its WebRTC processing thread.
    private var sampleRate = 48_000.0

    init(channel: CallRecordingChannel) { self.channel = channel }

    func audioProcessingInitialize(sampleRate: Int, channels: Int) {
        self.sampleRate = Double(sampleRate)
    }

    func audioProcessingProcess(audioBuffer: RTCAudioBuffer) {
        guard audioBuffer.channels > 0, audioBuffer.frames > 0, sampleRate > 0 else { return }
        // AudioBuffer contains FloatS16, not normalized [-1, 1] floats. Its
        // borrowed pointer is copied only while recording, never retained.
        let samples = UnsafeBufferPointer(
            start: audioBuffer.rawBuffer(forChannel: 0), count: audioBuffer.frames)
        CallAudioRecorder.shared.appendFloat32(
            samples, sampleRate: sampleRate, normalized: false,
            channel: channel, source: .cloudWebRTC)
    }

    func audioProcessingRelease() {}
}
