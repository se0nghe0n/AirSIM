import UIKit

enum RecentCallTimeFormatter {
    static func string(
        for date: Date,
        now: Date = Date(),
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String {
        let day = calendar.dateComponents([.year, .month, .day], from: date)
        let currentDay = calendar.dateComponents([.year, .month, .day], from: now)
        // localization.md: use FormatStyle for time and date display so output follows the user locale;
        // 12-hour regions (e.g., en_US) output "2:30 PM" without dropping AM/PM, while 24-hour regions remain "14:30".
        if day == currentDay {
            return date.formatted(
                Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, calendar: calendar)
            )
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           day == calendar.dateComponents([.year, .month, .day], from: yesterday) {
            return "Yesterday"
        }
        if day.year == currentDay.year {
            return date.formatted(.dateTime.month(.twoDigits).day(.twoDigits))
        }
        // Cross-year dates follow locale field ordering (e.g., MM/dd/yyyy in English instead of yyyy/MM/dd).
        return date.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits))
    }
}

enum RecentCallDialPolicy {
    static func numberToDial(_ number: String?) -> String? {
        guard let number, !number.isEmpty else { return nil }
        return number
    }
}

@MainActor
final class RecentsViewController: PhoneTableController {
    private let historyStatus = phoneLabel(size: 13, color: .secondaryLabel)
    private let historyStatusBackground = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
    override var tableStyle: UITableView.Style { .plain }
    let model: AirSIMPresentation
    let onCall: (String) -> Void
    let onMessage: (String) -> Void
    init(model: AirSIMPresentation, onCall: @escaping (String) -> Void, onMessage: @escaping (String) -> Void) { self.model = model; self.onCall = onCall; self.onMessage = onMessage; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() {
        super.viewDidLoad(); title = "Recents"
        historyStatus.translatesAutoresizingMaskIntoConstraints = false; historyStatusBackground.translatesAutoresizingMaskIntoConstraints = false
        historyStatusBackground.contentView.addSubview(historyStatus); view.addSubview(historyStatusBackground)
        NSLayoutConstraint.activate([historyStatusBackground.leadingAnchor.constraint(equalTo: view.leadingAnchor), historyStatusBackground.trailingAnchor.constraint(equalTo: view.trailingAnchor), historyStatusBackground.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor), historyStatus.leadingAnchor.constraint(equalTo: historyStatusBackground.contentView.leadingAnchor, constant: 20), historyStatus.trailingAnchor.constraint(equalTo: historyStatusBackground.contentView.trailingAnchor, constant: -20), historyStatus.topAnchor.constraint(equalTo: historyStatusBackground.contentView.topAnchor, constant: 16), historyStatus.bottomAnchor.constraint(equalTo: historyStatusBackground.contentView.bottomAnchor, constant: -16)])
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: "Recordings", image: UIImage(systemName: "waveform"), primaryAction: UIAction { [weak self] _ in guard let self else { return }; self.navigationController?.pushViewController(CallRecordingsViewController(model: self.model), animated: true) })
        navigationItem.rightBarButtonItem = UIBarButtonItem(image: UIImage(systemName: "arrow.clockwise"), primaryAction: UIAction { [weak self] _ in Task { await self?.model.refreshCallHistory() } })
        navigationItem.rightBarButtonItem?.accessibilityLabel = "Refresh call history"
        navigationItem.leftBarButtonItem?.tintColor = .systemBlue; navigationItem.rightBarButtonItem?.tintColor = .systemBlue
        table.addGestureRecognizer(UILongPressGestureRecognizer(target: self, action: #selector(longPressCall(_:))))
        enableRefresh { [weak self] in await self?.model.refreshCallHistory() }
    }
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        Task { await model.refreshCallHistory() }
    }
    override func render() {
        historyStatus.text = model.callHistoryMessage
        historyStatusBackground.isHidden = model.callHistoryMessage == nil
        table.contentInset.bottom = model.callHistoryMessage == nil ? 0 : 80
        navigationItem.rightBarButtonItem?.isEnabled = !model.isRefreshingCallHistory
        table.separatorStyle = model.callHistory.isEmpty ? .none : .singleLine
        let rows = model.callHistory.map { call -> PhoneRow in
            let contact = call.number.flatMap { model.contacts.contact(for: $0) }
            let name = contact?.name ?? model.contacts.displayName(for: call.number)
            return PhoneRow(id: call.id, title: name, detail: "\(call.missed ? "Missed" : "AirSIM Audio") · \(call.direction == "incoming" ? "↙" : "↗") · \(RecentCallTimeFormatter.string(for: call.startedAt))", color: call.missed ? .systemRed : .label, enabled: RecentCallDialPolicy.numberToDial(call.number) != nil, action: { [weak self] in if let number = RecentCallDialPolicy.numberToDial(call.number) { self?.onCall(number) } }, accessibilityHint: "Tap to call back; touch and hold for details", photo: contact?.photoData, avatarName: contact == nil ? "" : name, bodyViewProvider: { [weak self] in PhoneListContentView(name: name, subtitle: "\(call.direction == "incoming" ? "↙" : "↗") \(call.missed ? "Missed" : "AirSIM Audio")", photo: contact?.photoData, avatarName: contact == nil ? "" : name, time: RecentCallTimeFormatter.string(for: call.startedAt), missed: call.missed, callAction: { [weak self] in if let number = RecentCallDialPolicy.numberToDial(call.number) { self?.onCall(number) } }) }, bodyVersion: call.number, insets: UIEdgeInsets(top: 0, left: 16, bottom: 0, right: 16))
        }
        setSections([PhoneSection(rows: rows.isEmpty ? [PhoneRow(id: "empty", title: "", bodyView: nativePhoneEmptyState("No Recents", image: "phone.arrow.up.right", detail: "Your call history appears here after a call.", minimumHeight: 300))] : rows)])
    }
    @objc private func longPressCall(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began, let path = table.indexPathForRow(at: gesture.location(in: table)), let id = row(at: path)?.id, let call = model.callHistory.first(where: { $0.id == id }) else { return }
        showDetails(call)
    }
    private func showDetails(_ call: CallRecord) {
        guard let number = RecentCallDialPolicy.numberToDial(call.number) else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        let detail = RecentCallDetailsViewController(call: call, model: model, onCall: { [weak self] in self?.onCall(number) }, onMessage: { [weak self] in self?.onMessage(number) }, onDelete: { [weak self] in self?.model.deleteCallHistory(ids: [call.id]) })
        detail.modalPresentationStyle = .overFullScreen; detail.modalTransitionStyle = .crossDissolve
        present(detail, animated: true)
    }
    func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard let id = row(at: indexPath)?.id, let call = model.callHistory.first(where: { $0.id == id }) else { return nil }
        var actions = [UIContextualAction(style: .destructive, title: "Delete") { [weak self] _, _, done in self?.model.deleteCallHistory(ids: [call.id]); done(true) }]
        if let number = RecentCallDialPolicy.numberToDial(call.number) {
            let message = UIContextualAction(style: .normal, title: "Messages") { [weak self] _, _, done in self?.onMessage(number); done(true) }; message.backgroundColor = .systemBlue
            let dial = UIContextualAction(style: .normal, title: "Dial") { [weak self] _, _, done in self?.onCall(number); done(true) }; dial.backgroundColor = .systemGreen
            actions += [message, dial]
        }
        let config = UISwipeActionsConfiguration(actions: actions); config.performsFirstActionWithFullSwipe = false; return config
    }
}

#if DEBUG
#Preview("Recents · Calls") {
    AirSIMPreviewFixtures.navigation(RecentsViewController(model: AirSIMPreviewFixtures.presentation(tab: .recents), onCall: { _ in }, onMessage: { _ in }))
}
#endif
