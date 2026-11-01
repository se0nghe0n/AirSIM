import ComposableArchitecture
import UIKit

/// The Recents tab.
@MainActor
@ViewAction(for: RecentsFeature.self)
final class RecentsViewController: PhoneTableController {
    // MARK: Store

    let store: StoreOf<RecentsFeature>

    // MARK: Views

    override var tableStyle: UITableView.Style { .plain }
    private let statusLabel = phoneLabel(size: 13, color: .secondaryLabel)
    private let statusBanner = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
    private lazy var refreshButton = UIBarButtonItem(
        image: UIImage(systemName: "arrow.clockwise"),
        primaryAction: UIAction { [weak self] _ in self?.send(.refreshTapped) }
    )

    // MARK: Lifecycle

    init(store: StoreOf<RecentsFeature>) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Recents"
        buildNavigationItems()
        buildStatusBanner()
        table.addGestureRecognizer(UILongPressGestureRecognizer(target: self, action: #selector(longPressed(_:))))
        enableRefresh { [weak self] in await self?.send(.refreshTapped).finish() }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        send(.appeared)
    }

    // MARK: Rendering

    override func render() {
        renderStatus(store.statusMessage)
        refreshButton.isEnabled = !store.isRefreshing
        let rows = store.rows
        table.separatorStyle = rows.isEmpty ? .none : .singleLine
        setSections([PhoneSection(rows: rows.isEmpty ? [emptyRow()] : rows.map(callRow))])
    }

    private func renderStatus(_ message: String?) {
        statusLabel.text = message
        statusBanner.isHidden = message == nil
        table.contentInset.bottom = message == nil ? 0 : Metrics.statusBannerHeight
    }

    // MARK: Rows

    private func callRow(_ row: RecentCallRow) -> PhoneRow {
        PhoneRow(
            id: row.id,
            title: row.name,
            detail: row.detail,
            color: row.isMissed ? .systemRed : .label,
            enabled: row.dialNumber != nil,
            action: { [weak self] in self?.send(.callTapped(row)) },
            accessibilityHint: "Tap to call back; touch and hold for details",
            photo: row.photo,
            avatarName: row.avatarName,
            bodyViewProvider: { [weak self] in
                PhoneListContentView(
                    name: row.name,
                    subtitle: row.subtitle,
                    photo: row.photo,
                    avatarName: row.avatarName,
                    time: row.time,
                    missed: row.isMissed,
                    callAction: { [weak self] in self?.send(.callTapped(row)) }
                )
            },
            bodyVersion: row.number,
            insets: Metrics.rowInsets
        )
    }

    private func emptyRow() -> PhoneRow {
        PhoneRow(
            id: "empty",
            title: "",
            bodyView: nativePhoneEmptyState(
                "No Recents",
                image: "phone.arrow.up.right",
                detail: "Your call history appears here after a call.",
                minimumHeight: 300
            )
        )
    }

    // MARK: Layout

    private func buildNavigationItems() {
        let recordings = UIBarButtonItem(
            title: "Recordings",
            image: UIImage(systemName: "waveform"),
            primaryAction: UIAction { [weak self] _ in self?.showRecordings() }
        )
        recordings.tintColor = .systemBlue
        refreshButton.tintColor = .systemBlue
        refreshButton.accessibilityLabel = "Refresh call history"
        navigationItem.leftBarButtonItem = recordings
        navigationItem.rightBarButtonItem = refreshButton
    }

    private func buildStatusBanner() {
        statusBanner.contentView.addPinnedSubview(statusLabel, insets: Metrics.statusPadding)
        statusBanner.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statusBanner)
        NSLayoutConstraint.activate([
            statusBanner.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            statusBanner.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            statusBanner.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
        ])
    }

    // MARK: Navigation

    private func showRecordings() {
        let recordings = CallRecordingsViewController(store: store.scope(state: \.recordings, action: \.recordings))
        navigationController?.pushViewController(recordings, animated: true)
    }

    @objc private func longPressed(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began,
              let path = table.indexPathForRow(at: gesture.location(in: table)),
              let id = row(at: path)?.id,
              let row = store.state.row(id: id),
              row.dialNumber != nil
        else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        let details = RecentCallDetailsViewController(row: row, store: store)
        details.modalPresentationStyle = .overFullScreen
        details.modalTransitionStyle = .crossDissolve
        present(details, animated: true)
    }

    // MARK: UITableViewDelegate

    func tableView(
        _ tableView: UITableView,
        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        guard let id = row(at: indexPath)?.id, let row = store.state.row(id: id) else { return nil }
        let delete = UIContextualAction(style: .destructive, title: "Delete") { [weak self] _, _, done in
            self?.send(.deleteTapped(id))
            done(true)
        }
        var actions = [delete]
        if row.dialNumber != nil {
            let message = UIContextualAction(style: .normal, title: "Messages") { [weak self] _, _, done in
                self?.send(.messageTapped(row))
                done(true)
            }
            message.backgroundColor = .systemBlue
            let dial = UIContextualAction(style: .normal, title: "Dial") { [weak self] _, _, done in
                self?.send(.callTapped(row))
                done(true)
            }
            dial.backgroundColor = .systemGreen
            actions += [message, dial]
        }
        let configuration = UISwipeActionsConfiguration(actions: actions)
        configuration.performsFirstActionWithFullSwipe = false
        return configuration
    }
}

private enum Metrics {
    static let statusPadding = UIEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
    static let statusBannerHeight: CGFloat = 80
    static let rowInsets = UIEdgeInsets(top: 0, left: 16, bottom: 0, right: 16)
}

#if DEBUG
#Preview("Recents · Calls") {
    let store = AirSIMPreviewFixtures.store(tab: .recents)
    return AirSIMPreviewFixtures.navigation(
        RecentsViewController(store: store.scope(state: \.recents, action: \.recents))
    )
}
#endif
