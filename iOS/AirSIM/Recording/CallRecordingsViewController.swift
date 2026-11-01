import ComposableArchitecture
import UIKit

@MainActor
@ViewAction(for: RecordingsFeature.self)
final class CallRecordingsViewController: PhoneTableController {
    // MARK: Store

    let store: StoreOf<RecordingsFeature>

    // MARK: Lifecycle

    init(store: StoreOf<RecordingsFeature>) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Recordings"
        enableRefresh { [weak self] in await self?.send(.refreshPulled).finish() }
        presentAlert(from: store, state: \.alert, action: \.alert)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        send(.appeared)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        send(.disappeared)
    }

    // MARK: Rendering

    override func render() {
        let recordings = store.recordings
        let isCallActive = store.isCallActive
        let playingID = store.playingID
        let rows = recordings.map { recordingRow($0, isCallActive: isCallActive, isPlaying: playingID == $0.id) }
        setSections([
            PhoneSection(
                footer: footer(isEmpty: rows.isEmpty, isCallActive: isCallActive),
                rows: rows.isEmpty ? [emptyRow()] : rows
            )
        ])
        renderSavingIndicator(store.isSaving)
    }

    private func footer(isEmpty: Bool, isCallActive: Bool) -> String {
        if isEmpty { return "" }
        return isCallActive
            ? "Playback is available after your call ends."
            : "Recordings stay on this iPhone. Use Share to export a recording."
    }

    private func renderSavingIndicator(_ isSaving: Bool) {
        guard isSaving else {
            navigationItem.rightBarButtonItem = nil
            return
        }
        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.startAnimating()
        spinner.accessibilityLabel = "Saving recording"
        navigationItem.rightBarButtonItem = UIBarButtonItem(customView: spinner)
    }

    // MARK: Rows

    private func recordingRow(_ recording: CallRecordingFile, isCallActive: Bool, isPlaying: Bool) -> PhoneRow {
        PhoneRow(
            id: recording.id.uuidString,
            title: "",
            context: { [weak self] in self?.contextMenu(for: recording) ?? UIMenu() },
            bodyViewProvider: { [weak self] in
                self?.recordingView(recording, isCallActive: isCallActive, isPlaying: isPlaying) ?? UIView()
            },
            bodyVersion: [
                recording.fileName,
                "\(recording.startedAt.timeIntervalSinceReferenceDate)",
                "\(recording.duration)",
                "\(isCallActive)",
                "\(isPlaying)",
            ].joined(separator: "|")
        )
    }

    private func emptyRow() -> PhoneRow {
        PhoneRow(
            id: "empty",
            title: "",
            bodyView: phoneEmptyState(
                "No recordings yet",
                image: "waveform",
                detail: "Tap Record during a connected call. Saved recordings appear here."
            ),
            transparent: true
        )
    }

    private func recordingView(_ recording: CallRecordingFile, isCallActive: Bool, isPlaying: Bool) -> UIView {
        let playSymbol = isPlaying ? "stop.circle.fill" : "play.circle.fill"
        let play = phoneButton(isPlaying ? "Stop playback" : "Play recording", image: playSymbol) { [weak self] in
            self?.send(.playTapped(recording))
        }
        play.configuration = .plain()
        play.setImage(
            UIImage(systemName: playSymbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 28)),
            for: .normal
        )
        play.isEnabled = !isCallActive
        play.widthAnchor.constraint(equalToConstant: 40).isActive = true

        let date = phoneLabel(recording.startedAt.formatted(.dateTime.month().day().hour().minute().second()))
        date.font = .systemFont(ofSize: 17, weight: .medium)
        let length = Duration.seconds(max(0, Int(recording.duration))).formatted(.time(pattern: .minuteSecond))
        let duration = phoneLabel(length, size: 12, color: .secondaryLabel)
        duration.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        let text = UIStackView([date, duration], axis: .vertical, spacing: 4)

        let share = phoneButton("Share recording", image: "square.and.arrow.up") { [weak self] in
            self?.share(recording)
        }
        share.configuration?.title = nil
        share.configuration?.background.backgroundColor = .clear
        share.widthAnchor.constraint(equalToConstant: 40).isActive = true

        let row = UIStackView([play, text, UIView(), share], axis: .horizontal, spacing: 12, alignment: .center)
        row.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        return row
    }

    private func contextMenu(for recording: CallRecordingFile) -> UIMenu {
        UIMenu(children: [
            UIAction(title: "Share recording", image: UIImage(systemName: "square.and.arrow.up")) { [weak self] _ in
                self?.share(recording)
            },
            UIAction(title: "Delete", image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
                self?.send(.deleteTapped(recording))
            },
        ])
    }

    // MARK: Actions

    private func share(_ recording: CallRecordingFile) {
        guard let url = store.state.shareURL(for: recording) else { return }
        let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        sheet.popoverPresentationController?.sourceView = view
        sheet.popoverPresentationController?.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
        present(sheet, animated: true)
    }

    // MARK: UITableViewDelegate

    func tableView(
        _ tableView: UITableView,
        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        guard let id = row(at: indexPath)?.id, let recording = store.state.recording(id: id) else { return nil }
        let delete = UIContextualAction(style: .destructive, title: "Delete") { [weak self] _, _, done in
            self?.send(.deleteTapped(recording))
            done(true)
        }
        let share = UIContextualAction(style: .normal, title: "Share") { [weak self] _, _, done in
            self?.share(recording)
            done(true)
        }
        return UISwipeActionsConfiguration(actions: [delete, share])
    }
}

#if DEBUG
#Preview("Recordings · Saved Calls") {
    let store = AirSIMPreviewFixtures.store(tab: .recents)
    return AirSIMPreviewFixtures.navigation(
        CallRecordingsViewController(store: store.scope(state: \.recents.recordings, action: \.recents.recordings))
    )
}

#Preview("Recordings · Empty") {
    let store = AirSIMPreviewFixtures.store(tab: .recents, empty: true)
    return AirSIMPreviewFixtures.navigation(
        CallRecordingsViewController(store: store.scope(state: \.recents.recordings, action: \.recents.recordings))
    )
}
#endif
