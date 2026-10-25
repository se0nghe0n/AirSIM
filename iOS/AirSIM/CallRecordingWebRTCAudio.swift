import Foundation
import WebRTC

/// Passive observers: the native device, codec, and voice processing remain in charge.
final class CloudWebRTCRecordingAudio {
    private let capture: CallRecordingWebRTCObserver
    private let render: CallRecordingWebRTCObserver
    let module: RTCDefaultAudioProcessingModule

    init(source: CallRecordingSource) {
        capture = CallRecordingWebRTCObserver(channel: .local, source: source)
        render = CallRecordingWebRTCObserver(channel: .remote, source: source)
        module = RTCDefaultAudioProcessingModule(
            config: nil, capturePostProcessingDelegate: nil,
            renderPreProcessingDelegate: nil)
        // SDK 144.7559.15's adapter initializer ignores its delegate argument.
        // The property setters actually bind the weak native callbacks. Keep
        // both observers strongly owned here for their owning peer factory's lifetime.
        module.capturePostProcessingDelegate = capture
        module.renderPreProcessingDelegate = render
    }
}

private final class CallRecordingWebRTCObserver: NSObject, RTCAudioCustomProcessingDelegate {
    private let channel: CallRecordingChannel
    private let source: CallRecordingSource
    // Each delegate is initialized and called on its WebRTC processing thread.
    private var sampleRate = 48_000.0

    init(channel: CallRecordingChannel, source: CallRecordingSource) {
        self.channel = channel
        self.source = source
    }

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
            channel: channel, source: source)
    }

    func audioProcessingRelease() {}
}
