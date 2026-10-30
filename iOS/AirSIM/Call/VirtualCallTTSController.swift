import AVFoundation
import CallKit
import Foundation

enum VirtualCallTTSError: LocalizedError {
    case invalidPayload

    var errorDescription: String? {
        switch self {
        case .invalidPayload: return "Virtual call has no speech content"
        }
    }
}

/// Local media source for Dashboard virtual incoming calls. CallKit still manages system call lifecycle
/// and audio routing, but answer/hangup neither sends AT commands to the module nor opens a cloud PCM session.
@MainActor
final class VirtualCallTTSController: NSObject, AVSpeechSynthesizerDelegate {
    static let shared = VirtualCallTTSController()

    private let synthesizer = AVSpeechSynthesizer()
    private(set) var call: IncomingVoIPCall?
    private var started = false

    var isPrepared: Bool { call?.isVirtual == true }

    private override init() {
        super.init()
        synthesizer.delegate = self
        synthesizer.usesApplicationAudioSession = true
    }

    func prepare(_ incoming: IncomingVoIPCall) throws {
        guard incoming.isVirtual, incoming.ttsText?.isEmpty == false else {
            throw VirtualCallTTSError.invalidPayload
        }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetoothHFP])
        call = incoming
        started = false
    }

    /// Speech playback must start only after CXProvider activates CallKit's AVAudioSession.
    func start() {
        guard !started, let text = call?.ttsText else { return }
        started = true
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "zh-CN")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.92
        utterance.preUtteranceDelay = 0.18
        synthesizer.speak(utterance)
    }

    func setMuted(_ muted: Bool) {
        if muted {
            _ = synthesizer.pauseSpeaking(at: .immediate)
        } else if synthesizer.isPaused {
            _ = synthesizer.continueSpeaking()
        }
    }

    func stop() {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        call = nil
        started = false
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        Task { @MainActor in
            guard VirtualCallTTSController.shared.isPrepared else { return }
            // Completion of speech is treated as remote hangup; media state is cleaned up by didDeactivate after CallKit dismisses.
            CallKitController.shared.reportCurrentCallEnded(reason: .remoteEnded)
        }
    }
}
