@preconcurrency import AVFoundation
import Observation

@MainActor
@Observable
final class CallRecordingPlayback: NSObject, AVAudioPlayerDelegate {
    private(set) var playingID: UUID?
    @ObservationIgnored private var player: AVAudioPlayer?

    func toggle(_ recording: CallRecordingFile, url: URL) throws {
        if playingID == recording.id {
            stop()
            return
        }
        stop()
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio)
            try session.setActive(true)
            let player = try AVAudioPlayer(contentsOf: url)
            self.player = player
            player.delegate = self
            guard player.play() else { throw CocoaError(.fileReadCorruptFile) }
            playingID = recording.id
        } catch {
            stop()
            throw error
        }
    }

    func stop(deactivateSession: Bool = true) {
        let hadPlayer = player != nil
        player?.delegate = nil
        player?.stop()
        player = nil
        playingID = nil
        // An incoming CallKit call may already own the shared session.
        let session = AVAudioSession.sharedInstance()
        if hadPlayer, deactivateSession, session.category == .playback {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard self?.player === player else { return }
            self?.stop()
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: (any Error)?) {
        Task { @MainActor [weak self] in
            guard self?.player === player else { return }
            self?.stop()
        }
    }
}
