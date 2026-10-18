@preconcurrency import AVFoundation
import SwiftUI

struct CallRecordingsView: View {
    var store: CallRecordingStore
    @Environment(AppModel.self) private var model
    @State private var playback = CallRecordingPlayback()
    @State private var errorMessage: String?

    private var callInProgress: Bool { model.callLifecycleSnapshot.state.representsCall }

    var body: some View {
        List {
            if store.recordings.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "waveform").font(.largeTitle).foregroundStyle(.secondary)
                    Text("No recordings yet").font(.headline)
                    Text("Tap Record during a connected call. Saved recordings appear here.")
                        .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 40)
                .listRowBackground(Color.clear)
            } else {
                Section {
                    ForEach(store.recordings) { recording in
                        HStack(spacing: 12) {
                            Button {
                                do { try playback.toggle(recording, url: store.url(for: recording)) }
                                catch { errorMessage = "Unable to play recording: \(error.localizedDescription)" }
                            } label: {
                                Image(systemName: playback.playingID == recording.id ? "stop.circle.fill" : "play.circle.fill")
                                    .font(.title).frame(width: 40, height: 44)
                            }
                            .buttonStyle(.borderless)
                            .disabled(callInProgress)
                            .accessibilityLabel(playback.playingID == recording.id ? "Stop playback" : "Play recording")

                            VStack(alignment: .leading, spacing: 4) {
                                Text(recording.startedAt, format: .dateTime.month().day().hour().minute().second())
                                    .font(.body.weight(.medium))
                                Text(Self.duration(recording.duration))
                                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 4)
                            ShareLink(item: store.url(for: recording)) {
                                Image(systemName: "square.and.arrow.up").frame(width: 40, height: 44)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Share recording")
                        }
                        .swipeActions {
                            Button(role: .destructive) {
                                if playback.playingID == recording.id { playback.stop() }
                                Task {
                                    do { try await store.delete(recording) }
                                    catch { errorMessage = "Unable to delete recording: \(error.localizedDescription)" }
                                }
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                } footer: {
                    Text(callInProgress
                         ? "Playback is available after your call ends."
                         : "Recordings stay on this iPhone. Use Share to export a recording.")
                }
            }
        }
        .navigationTitle("Recordings")
        .toolbar {
            if store.isBusy { ProgressView().accessibilityLabel("Saving recording") }
        }
        .task { await store.reload() }
        .refreshable { await store.reload() }
        .onChange(of: callInProgress) { _, active in
            if active { playback.stop(deactivateSession: false) }
        }
        .onDisappear { playback.stop(deactivateSession: !callInProgress) }
        .alert("Recording Error", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private static func duration(_ value: TimeInterval) -> String {
        let seconds = max(0, Int(value))
        // localization.md：用 FormatStyle 取代 String(format:)；en 输出与旧格式一致。
        return Duration.seconds(seconds).formatted(.time(pattern: .minuteSecond))
    }
}

@MainActor
@Observable
private final class CallRecordingPlayback: NSObject, AVAudioPlayerDelegate {
    private(set) var playingID: UUID?
    @ObservationIgnored private var player: AVAudioPlayer?

    func toggle(_ recording: CallRecordingFile, url: URL) throws {
        if playingID == recording.id { stop(); return }
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
