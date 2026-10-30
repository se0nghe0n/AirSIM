@preconcurrency import AVFoundation
import UIKit
import Observation

@MainActor
@Observable
final class CallRecordingPlayback: NSObject, AVAudioPlayerDelegate {
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


@MainActor
final class CallRecordingsViewController: PhoneTableController {
    let model: AirSIMPresentation
    init(model: AirSIMPresentation) { self.model = model; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() { super.viewDidLoad(); title = "Recordings"; enableRefresh { [weak self] in await self?.model.recordings.reload() } }
    override func viewWillAppear(_ animated: Bool) { super.viewWillAppear(animated); Task { await model.recordings.reload() } }
    override func viewDidDisappear(_ animated: Bool) { super.viewDidDisappear(animated); model.store.send(.recordings(.stop(!model.callLifecycleSnapshot.state.representsCall))) }
    override func render() {
        let active = model.callLifecycleSnapshot.state.representsCall
        let rows = model.recordings.recordings.map { recording -> PhoneRow in
            let playing = model.store.recordings.playingID == recording.id
            return PhoneRow(id: recording.id.uuidString, title: "", context: { [weak self] in UIMenu(children: [UIAction(title: "Share recording", image: UIImage(systemName: "square.and.arrow.up")) { [weak self] _ in self?.share(recording) }, UIAction(title: "Delete", image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in self?.delete(recording) }]) }, bodyViewProvider: { [weak self] in self?.recordingView(recording, active: active, playing: playing) ?? UIView() }, bodyVersion: "\(recording.fileName)|\(recording.startedAt.timeIntervalSinceReferenceDate)|\(recording.duration)|\(active)|\(playing)")
        }
        setSections([PhoneSection(footer: rows.isEmpty ? "" : (active ? "Playback is available after your call ends." : "Recordings stay on this iPhone. Use Share to export a recording."), rows: rows.isEmpty ? [PhoneRow(id: "empty", title: "", bodyView: phoneEmptyState("No recordings yet", image: "waveform", detail: "Tap Record during a connected call. Saved recordings appear here.", minimumHeight: 0, iconSize: 34, detailSize: 15, spacing: 12, verticalPadding: 40, headingSize: 17), transparent: true)] : rows)])
        if let error = model.store.recordings.error, presentedViewController == nil {
            let alert = UIAlertController(title: "Recording Error", message: error, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .cancel) { [weak self] _ in self?.model.store.send(.recordings(.clearError)) }); present(alert, animated: true)
        }
        if model.recordings.isBusy { let spinner = UIActivityIndicatorView(style: .medium); spinner.startAnimating(); spinner.accessibilityLabel = "Saving recording"; navigationItem.rightBarButtonItem = UIBarButtonItem(customView: spinner) } else { navigationItem.rightBarButtonItem = nil }
    }
    private func recordingView(_ recording: CallRecordingFile, active: Bool, playing: Bool) -> UIView {
        let play = phoneButton(playing ? "Stop playback" : "Play recording", image: playing ? "stop.circle.fill" : "play.circle.fill") { [weak self] in self?.model.store.send(.recordings(.play(recording))) }
        play.configuration = .plain(); play.setImage(UIImage(systemName: playing ? "stop.circle.fill" : "play.circle.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 28)), for: .normal); play.isEnabled = !active; play.widthAnchor.constraint(equalToConstant: 40).isActive = true
        let date = phoneLabel(recording.startedAt.formatted(.dateTime.month().day().hour().minute().second())); date.font = .systemFont(ofSize: 17, weight: .medium)
        let duration = phoneLabel(Duration.seconds(max(0, Int(recording.duration))).formatted(.time(pattern: .minuteSecond)), size: 12, color: .secondaryLabel); duration.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        let text = UIStackView(arrangedSubviews: [date, duration]); text.axis = .vertical; text.spacing = 4
        let share = phoneButton("Share recording", image: "square.and.arrow.up") { [weak self] in self?.share(recording) }; share.configuration?.title = nil; share.configuration?.background.backgroundColor = .clear; share.widthAnchor.constraint(equalToConstant: 40).isActive = true
        let row = UIStackView(arrangedSubviews: [play, text, UIView(), share]); row.axis = .horizontal; row.spacing = 12; row.alignment = .center; row.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        return row
    }
    private func share(_ recording: CallRecordingFile) {
        guard let url = model.snapshot.recordingURLs[recording.id] else { return }
        let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil); sheet.popoverPresentationController?.sourceView = view; sheet.popoverPresentationController?.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1); present(sheet, animated: true)
    }
    private func delete(_ recording: CallRecordingFile) { model.store.send(.recordings(.delete(recording))) }
    func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard let id = row(at: indexPath)?.id, let recording = model.recordings.recordings.first(where: { $0.id.uuidString == id }) else { return nil }
        return UISwipeActionsConfiguration(actions: [UIContextualAction(style: .destructive, title: "Delete") { [weak self] _, _, done in self?.delete(recording); done(true) }, UIContextualAction(style: .normal, title: "Share") { [weak self] _, _, done in self?.share(recording); done(true) }])
    }
}

#if DEBUG
#Preview("Recordings · Saved Calls") {
    AirSIMPreviewFixtures.navigation(CallRecordingsViewController(model: AirSIMPreviewFixtures.presentation(tab: .recents)))
}

#Preview("Recordings · Empty") {
    AirSIMPreviewFixtures.navigation(CallRecordingsViewController(model: AirSIMPreviewFixtures.presentation(tab: .recents, empty: true)))
}
#endif
