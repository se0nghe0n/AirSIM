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

/// A contact may store duplicate entries for the same phone number; since duplicate rows are interchangeable
/// during selection and dialing, deduplicate by number so phone-derived table row IDs stay unique.
enum ContactPhoneListPolicy {
    static func displayPhones(for phones: [String]) -> [String] {
        var seen = Set<String>()
        return phones.filter { seen.insert($0).inserted }
    }
}

enum RecentCallDialPolicy {
    static func numberToDial(_ number: String?) -> String? {
        guard let number, !number.isEmpty else { return nil }
        return number
    }
}

enum DialPadDeletePolicy {
    static func removingLast(from number: String) -> String {
        String(number.dropLast())
    }
}

enum CallSurfacePhase: Equatable {
    case incoming
    case connected
}

struct CallSurfaceContent: Equatable {
    let phase: CallSurfacePhase
    let showsDuration: Bool

    init(state: String) {
        if ["incoming", "waiting"].contains(state) {
            phase = .incoming
            showsDuration = false
        } else {
            phase = .connected
            showsDuration = true
        }
    }
}

enum CallProximityPolicy {
    static func shouldMonitor(state: String, speakerEnabled: Bool) -> Bool {
        guard !speakerEnabled else { return false }
        return ["dialing", "alerting", "connecting", "active", "held", "ending"].contains(state)
    }
}


private struct DialPadLayoutMetrics {
    let keySize: CGFloat
    let keySpacing: CGFloat
    let sectionSpacing: CGFloat
    let numberFontSize: CGFloat
    let numberHeight: CGFloat
    let contactHeight: CGFloat

    var keypadWidth: CGFloat { keySize * 3 + keySpacing * 2 }
    var digitFontSize: CGFloat { min(31, max(23, keySize * 0.34)) }
    var letterFontSize: CGFloat { min(10, max(8, keySize * 0.115)) }
    var callIconSize: CGFloat { min(30, max(23, keySize * 0.33)) }

    init(availableHeight: CGFloat, availableWidth: CGFloat, compactWidth: Bool) {
        let compactHeight = availableHeight < 700
        let desiredKeySize: CGFloat = compactWidth ? 84 : 90
        let desiredKeySpacing: CGFloat = compactWidth ? 28 : 34
        let reservedHeight: CGFloat = compactHeight ? 205 : 220
        let verticalKeySize = (availableHeight - reservedHeight) / 5
        let contentWidth = min(520, max(0, availableWidth - 32))
        let horizontalKeySize = (contentWidth - desiredKeySpacing * 2) / 3

        keySize = min(desiredKeySize, max(56, min(verticalKeySize, horizontalKeySize)))
        keySpacing = min(
            desiredKeySpacing,
            max(14, (contentWidth - keySize * 3) / 2)
        )
        sectionSpacing = compactHeight ? 8 : (compactWidth ? 12 : 16)
        numberFontSize = compactHeight ? 32 : (compactWidth ? 36 : 42)
        numberHeight = compactHeight ? 40 : 46
        contactHeight = compactHeight ? 18 : 20
    }
}

@MainActor
final class DialPadViewController: ObservingViewController {
    let model: AirSIMPresentation
    private let number = phoneLabel(size: 36)
    private let contact = phoneLabel(size: 16, color: .systemGreen)
    private let agentButton = phoneButton("Paired Android Agents") {}
    private var agentContents: UIView?
    private var agentHeight: NSLayoutConstraint!
    private var callButton: UIButton!
    private var deleteButton: UIButton!
    private var deleteTask: Task<Void, Never>?
    private var keys: [UIButton] = []
    private let stack = UIStackView()
    private var keyRows: [UIStackView] = []
    private var rowWidths: [NSLayoutConstraint] = []
    private var keyHeight: NSLayoutConstraint!
    private var numberHeight: NSLayoutConstraint!
    private var contactHeight: NSLayoutConstraint!
    private var contentWidth: NSLayoutConstraint!
    private var lastLayoutSize = CGSize.zero
    init(model: AirSIMPresentation) { self.model = model; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() {
        super.viewDidLoad()
        let backdrop = PhoneBackdropView()
        backdrop.isUserInteractionEnabled = false
        backdrop.accessibilityElementsHidden = true
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        view.insertSubview(backdrop, at: 0)
        NSLayoutConstraint.activate([
            backdrop.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            backdrop.topAnchor.constraint(equalTo: view.topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        navigationItem.title = "Dial"; navigationItem.largeTitleDisplayMode = .never
        stack.axis = .vertical; stack.spacing = 12; stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(stack)
        contentWidth = stack.widthAnchor.constraint(equalToConstant: 360)
        contentWidth.isActive = true
        NSLayoutConstraint.activate([stack.centerXAnchor.constraint(equalTo: view.centerXAnchor), stack.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor), stack.widthAnchor.constraint(lessThanOrEqualToConstant: 520), stack.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 16), stack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -16), stack.topAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.topAnchor, constant: 4), stack.bottomAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -4)])
        number.font = UIFont.systemFont(ofSize: 36, weight: .light).rounded()
        number.adjustsFontSizeToFitWidth = true; number.minimumScaleFactor = 0.45; number.numberOfLines = 1; number.textAlignment = .center
        stack.addArrangedSubview(number); stack.setCustomSpacing(2, after: number); stack.addArrangedSubview(contact)
        numberHeight = number.heightAnchor.constraint(equalToConstant: 46); numberHeight.isActive = true
        contactHeight = contact.heightAnchor.constraint(equalToConstant: 20); contactHeight.isActive = true
        agentButton.titleLabel?.numberOfLines = 3
        agentButton.addAction(UIAction { [weak self] _ in guard let self else { return }; self.showPhoneSheet(PairedAndroidAgentsViewController(model: self.model)) }, for: .touchUpInside)
        stack.addArrangedSubview(agentButton)
        agentButton.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        agentHeight = agentButton.heightAnchor.constraint(equalToConstant: 94); agentHeight.isActive = true
        let letters: [String] = ["", "ABC", "DEF", "GHI", "JKL", "MNO", "PQRS", "TUV", "WXYZ", "", "+", ""]
        let digitRows: [[String]] = [["1", "2", "3"], ["4", "5", "6"], ["7", "8", "9"], ["*", "0", "#"]]
        for (rowIndex, digits) in digitRows.enumerated() {
            let row = UIStackView(); row.axis = .horizontal; row.spacing = 28; row.distribution = .fillEqually
            for (column, digit) in digits.enumerated() {
                let subtitle = letters[rowIndex * 3 + column]
                let button = phoneButton(digit, color: .label) { [weak self] in self?.enter(digit) }
                var configuration: UIButton.Configuration
                if #available(iOS 26.0, *) { configuration = .glass() } else { configuration = .gray() }
                configuration.baseForegroundColor = .label; configuration.cornerStyle = .capsule
                var digitAttributes = AttributeContainer()
                digitAttributes.font = UIFontMetrics(forTextStyle: .title1).scaledFont(for: .systemFont(ofSize: 31, weight: .regular))
                var letterAttributes = AttributeContainer()
                letterAttributes.font = UIFontMetrics(forTextStyle: .caption2).scaledFont(for: .systemFont(ofSize: 10, weight: .semibold))
                configuration.attributedTitle = AttributedString(digit, attributes: digitAttributes)
                configuration.attributedSubtitle = AttributedString(subtitle, attributes: letterAttributes)
                configuration.titleAlignment = .center
                configuration.titlePadding = 0
                if #unavailable(iOS 26.0) {
                    configuration.background.backgroundColor = .tertiarySystemFill
                    configuration.background.strokeColor = UIColor.label.withAlphaComponent(0.12)
                    configuration.background.strokeWidth = 0.5
                }
                configuration.contentInsets = .zero
                button.configuration = configuration
                button.accessibilityLabel = subtitle.isEmpty ? digit : "\(digit) \(subtitle)"
                button.widthAnchor.constraint(equalTo: button.heightAnchor).isActive = true
                if digit == "0" { button.addGestureRecognizer(UILongPressGestureRecognizer(target: self, action: #selector(longZero(_:)))) }
                row.addArrangedSubview(button); keys.append(button)
            }
            stack.addArrangedSubview(row)
            let width = row.widthAnchor.constraint(equalToConstant: 308); width.isActive = true; rowWidths.append(width); keyRows.append(row)
        }
        let actions = UIStackView(); actions.axis = .horizontal; actions.spacing = 28; actions.distribution = .fillEqually
        let blank = UIView(); actions.addArrangedSubview(blank)
        callButton = phoneButton("Dial", image: "phone.fill", color: .white) { [weak self] in guard let self else { return }; Task { await self.model.dial() } }
        callButton.configuration?.title = nil
        callButton.configuration?.background.backgroundColor = .systemGreen
        callButton.configuration?.image = UIImage(systemName: "phone.fill")?.withTintColor(.white, renderingMode: .alwaysOriginal)
        callButton.configurationUpdateHandler = { button in
            button.configuration?.background.backgroundColor = .systemGreen
            button.configuration?.image = UIImage(systemName: "phone.fill")?.withTintColor(.white, renderingMode: .alwaysOriginal)
        }
        callButton.accessibilityIdentifier = "dialCall"
        deleteButton = phoneButton("Delete", image: "delete.left", color: .secondaryLabel) {}
        deleteButton.configuration?.title = nil
        deleteButton.configuration?.background.backgroundColor = .clear
        deleteButton.configuration?.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 18)
        deleteButton.accessibilityHint = "Tap to delete one digit; hold to keep deleting"
        (deleteButton as? PhoneActionButton)?.accessibilityAction = { [weak self] in
            guard let self else { return }
            self.model.numberInput = DialPadDeletePolicy.removingLast(from: self.model.numberInput)
        }
        deleteButton.addTarget(self, action: #selector(beginDelete), for: .touchDown)
        deleteButton.addTarget(self, action: #selector(stopDelete), for: [.touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit])
        actions.addArrangedSubview(callButton); actions.addArrangedSubview(deleteButton)
        stack.addArrangedSubview(actions); let width = actions.widthAnchor.constraint(equalToConstant: 308); width.isActive = true; rowWidths.append(width); keyRows.append(actions)
        actions.heightAnchor.constraint(equalTo: keys[0].heightAnchor).isActive = true
        keyHeight = keys[0].heightAnchor.constraint(equalToConstant: 84); keyHeight.isActive = true
    }
    override func viewWillAppear(_ animated: Bool) { super.viewWillAppear(animated); navigationController?.setNavigationBarHidden(true, animated: false) }
    override func viewWillDisappear(_ animated: Bool) { super.viewWillDisappear(animated); stopDelete(); navigationController?.setNavigationBarHidden(false, animated: false) }
    override func render() {
        number.text = model.numberInput.isEmpty ? "Enter number" : model.numberInput
        number.textColor = model.numberInput.isEmpty ? .secondaryLabel : .label
        contact.text = model.contacts.contact(for: model.numberInput)?.name ?? " "
        callButton.isEnabled = !model.numberInput.isEmpty && !model.isBusy && model.canStartOutgoingCommand
        let callOpacity: CGFloat = model.numberInput.isEmpty || !model.canStartOutgoingCommand ? 0.4 : 1
        callButton.alpha = callButton.isEnabled ? callOpacity : callOpacity * 0.5
        deleteButton.isEnabled = !model.numberInput.isEmpty
        agentButton.isHidden = model.currentAndroidAgent == nil && model.pairedAndroidAgents.isEmpty
        agentButton.configuration = nil
        agentContents?.removeFromSuperview()
        let card = AndroidAgentCardView(agent: model.currentAndroidAgent, count: model.pairedAndroidAgents.count, cloudEnabled: CloudModePreference.isEnabled())
        card.isUserInteractionEnabled = false; card.translatesAutoresizingMaskIntoConstraints = false; agentButton.addSubview(card); agentContents = card
        agentHeight.constant = model.currentAndroidAgent == nil ? 74 : 94
        NSLayoutConstraint.activate([card.leadingAnchor.constraint(equalTo: agentButton.leadingAnchor), card.trailingAnchor.constraint(equalTo: agentButton.trailingAnchor), card.topAnchor.constraint(equalTo: agentButton.topAnchor), card.bottomAnchor.constraint(equalTo: agentButton.bottomAnchor)])

    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let area = view.safeAreaLayoutGuide.layoutFrame
        guard area.size != lastLayoutSize else { return }; lastLayoutSize = area.size
        let metrics = DialPadLayoutMetrics(availableHeight: area.height, availableWidth: area.width, compactWidth: traitCollection.horizontalSizeClass == .compact)
        keyHeight.constant = metrics.keySize; contentWidth.constant = min(520, max(0, area.width - 32))
        numberHeight.constant = metrics.numberHeight; contactHeight.constant = metrics.contactHeight
        number.font = UIFont.systemFont(ofSize: metrics.numberFontSize, weight: .light).rounded()
        stack.spacing = metrics.sectionSpacing; stack.setCustomSpacing(2, after: number)
        for row in keyRows { row.spacing = metrics.keySpacing }
        for width in rowWidths { width.constant = metrics.keypadWidth }
        let labels: [String] = ["", "ABC", "DEF", "GHI", "JKL", "MNO", "PQRS", "TUV", "WXYZ", "", "+", ""]
        let digits: [String] = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "*", "0", "#"]
        for (index, key) in keys.enumerated() {
            var digit = AttributeContainer(); digit.font = UIFont.systemFont(ofSize: metrics.digitFontSize).rounded()
            var letters = AttributeContainer(); letters.font = UIFont.systemFont(ofSize: metrics.letterFontSize, weight: .semibold); letters.kern = 1.4
            key.configuration?.attributedTitle = AttributedString(digits[index], attributes: digit)
            key.configuration?.attributedSubtitle = AttributedString(labels[index], attributes: letters)
            key.configuration?.subtitleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
                var attributes = incoming; attributes.font = .systemFont(ofSize: metrics.letterFontSize, weight: .semibold); attributes.kern = 1.4; return attributes
            }
        }
        callButton.configuration?.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: metrics.callIconSize, weight: .semibold)
    }
    private func enter(_ digit: String) { model.numberInput.append(digit); if !model.isMuted { UIDevice.current.playInputClick() } }
    @objc private func longZero(_ gesture: UILongPressGestureRecognizer) { if gesture.state == .began { enter("+") } }
    @objc private func beginDelete() {
        stopDelete(); model.numberInput = DialPadDeletePolicy.removingLast(from: model.numberInput)
        deleteTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            while !Task.isCancelled, let self, !self.model.numberInput.isEmpty {
                self.model.numberInput = DialPadDeletePolicy.removingLast(from: self.model.numberInput)
                try? await Task.sleep(for: .milliseconds(90))
            }
        }
    }
    @objc private func stopDelete() { deleteTask?.cancel(); deleteTask = nil }
}

@MainActor
final class PairedAndroidAgentsViewController: PhoneTableController {
    let model: AirSIMPresentation
    init(model: AirSIMPresentation) { self.model = model; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() { super.viewDidLoad(); title = "Paired Android Agents" }
    override func render() {
        let rows = model.pairedAndroidAgents.map { agent in
            PhoneRow(id: agent.id, title: agent.deviceName, detail: "\(agent.phoneNumber ?? "Number unavailable")\nVoWLAN \(agent.vowlanOnline ? "Online" : "Offline") · Cloud \(!CloudModePreference.isEnabled() ? "Off" : (agent.cloudOnline ? "Online" : "Offline")) · \(String(localized: agent.agentKindTitle))", image: agent.isCurrent ? "checkmark.circle.fill" : "circle", color: agent.isCurrent ? .systemGreen : .label, action: { [weak self] in self?.model.bindAndroidAgent(agent.id) })
        }
        setSections([PhoneSection(rows: rows.isEmpty ? [PhoneRow(id: "empty", title: "No paired Android Agents", image: "smartphone.slash")] : rows)])
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

@MainActor
final class MessagesViewController: PhoneTableController, UINavigationControllerDelegate {
    private var applyingNavigation = false
    private var renderedThreadID: String?
    private weak var composerNavigationController: UINavigationController?
    override var tableStyle: UITableView.Style { .plain }
    let model: AirSIMPresentation
    init(model: AirSIMPresentation) { self.model = model; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() {
        super.viewDidLoad(); title = "Messages"
        navigationController?.delegate = self
        let refresh = UIAction(title: "Refresh", image: UIImage(systemName: "arrow.clockwise")) { [weak self] _ in Task { await self?.model.refreshMessages() } }
        let clear = UIAction(title: "Clear all SMS", image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
            self?.confirmPhoneAction("Clear all SMS", message: "This permanently deletes local messages and undelivered module messages.") { [weak self] in
                self?.model.store.send(.command(.clearMessages))
            }
        }
        navigationItem.leftBarButtonItem = UIBarButtonItem(image: UIImage(systemName: "ellipsis"), menu: UIMenu(children: [refresh, clear]))
        navigationItem.leftBarButtonItem?.accessibilityLabel = "Message Actions"
        navigationItem.leftBarButtonItem?.tintColor = .systemBlue
        navigationItem.rightBarButtonItem = UIBarButtonItem(image: UIImage(systemName: "square.and.pencil"), primaryAction: UIAction { [weak self] _ in self?.compose(recipient: "") })
        navigationItem.rightBarButtonItem?.accessibilityLabel = "New Message"
    }
    override func render() {
        let rows = model.conversations.map { conversation -> PhoneRow in
            let contact = model.contacts.contact(for: conversation.sender)
            let name = contact?.name ?? model.contacts.displayName(for: conversation.sender)
            return PhoneRow(id: conversation.sender, title: name, detail: "\(conversation.messages.last?.content ?? "")\n\((conversation.messages.last?.timestamp ?? .now).formatted(date: .omitted, time: .shortened))", disclosure: true, action: { [weak self] in self?.openConversation(conversation.sender) }, photo: contact?.photoData, avatarName: contact == nil ? "" : name, bodyViewProvider: { PhoneListContentView(name: name, subtitle: conversation.messages.last?.content ?? "", photo: contact?.photoData, avatarName: contact == nil ? "" : name, time: (conversation.messages.last?.timestamp ?? .now).formatted(date: .omitted, time: .shortened)) }, insets: UIEdgeInsets(top: 0, left: 16, bottom: 0, right: 16))
        }
        setSections([PhoneSection(rows: rows.isEmpty ? [PhoneRow(id: "empty", title: "", bodyView: nativePhoneEmptyState("No Messages", image: "message", detail: "Received messages appear here.", minimumHeight: 180))] : rows)])
    }
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated); navigationController?.delegate = self
        Task { await model.loadMessagesFromAgent() }
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        presentComposerIfNeeded()
    }
    func compose(recipient: String) {
        model.store.send(.messages(.compose(recipient)))
        presentComposerIfNeeded()
    }
    func presentComposerIfNeeded() {
        guard model.store.messages.composerPresented else { return }
        loadViewIfNeeded()
        guard let nav = navigationController, nav.view.window != nil, nav.presentedViewController == nil else { return }
        composerNavigationController = nav.showPhoneSheet(MessageComposerViewController(model: model, recipient: model.store.messages.recipient))
    }
    func openConversation(_ sender: String) {
        if model.store.messages.conversation != sender { model.store.send(.messages(.openConversation(sender))) }
        showConversationIfNeeded(sender)
    }
    func showConversationIfNeeded(_ sender: String) {
        guard model.store.messages.conversation == sender else { return }
        loadViewIfNeeded()
        guard let nav = navigationController else { return }
        guard !applyingNavigation else { return }
        // A pop exposes the destination stack before its transition completes.
        // Reapplying the same route here would replace the departing controller.
        guard renderedThreadID != sender else { return }
        if let current = nav.topViewController as? MessageThreadViewController, current.sender == sender { return }
        if let transition = nav.transitionCoordinator {
            transition.animate(alongsideTransition: nil) { [weak self] _ in
                Task { @MainActor [weak self] in self?.showConversationIfNeeded(sender) }
            }
            return
        }
        if let composer = composerNavigationController, composer.presentingViewController != nil {
            applyingNavigation = true
            composer.dismiss(animated: true) { [weak self] in self?.applyingNavigation = false; self?.showConversationIfNeeded(sender) }
            return
        }
        applyingNavigation = true
        renderedThreadID = sender
        nav.setViewControllers([self, MessageThreadViewController(model: model, sender: sender)], animated: false)
        applyingNavigation = false
    }
    func navigationController(_ navigationController: UINavigationController, didShow viewController: UIViewController, animated: Bool) {
        if viewController === self, !applyingNavigation, let previous = renderedThreadID {
            renderedThreadID = nil
            if model.store.messages.conversation == previous { model.store.send(.messages(.closeConversation)) }
        }
    }
}

@MainActor
final class MessageThreadViewController: PhoneTableController, UITextViewDelegate {
    override var tableStyle: UITableView.Style { .plain }
    let model: AirSIMPresentation
    let sender: String
    let reply = UITextView()
    private let replyPlaceholder = phoneLabel("Message", color: .placeholderText)
    private var sendButton: UIButton!
    private var replyHeight: NSLayoutConstraint!
    private var lastIDs: [String] = []
    private var firstLoad = true
    init(model: AirSIMPresentation, sender: String) { self.model = model; self.sender = sender; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() {
        super.viewDidLoad(); navigationItem.largeTitleDisplayMode = .never
        table.separatorStyle = .none
        table.contentInsetAdjustmentBehavior = .never
        table.contentInset.bottom = 12
        table.removeFromSuperview()
        let bar = UIStackView(); bar.axis = .horizontal; bar.spacing = 10; bar.alignment = .center
        reply.font = .preferredFont(forTextStyle: .body); reply.delegate = self; reply.layer.cornerRadius = 4; reply.backgroundColor = .systemBackground; reply.accessibilityLabel = "Message"
        reply.layer.borderWidth = 0.5; reply.layer.borderColor = UIColor.separator.cgColor
        reply.textContainerInset = UIEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
        replyPlaceholder.translatesAutoresizingMaskIntoConstraints = false; reply.addSubview(replyPlaceholder)
        NSLayoutConstraint.activate([replyPlaceholder.leadingAnchor.constraint(equalTo: reply.leadingAnchor, constant: 8), replyPlaceholder.topAnchor.constraint(equalTo: reply.topAnchor, constant: 4)])
        replyHeight = reply.heightAnchor.constraint(equalToConstant: 32); replyHeight.isActive = true
        sendButton = phoneButton("Send", image: "arrow.up.circle.fill") { [weak self] in
            guard let self else { return }
            self.model.store.send(.messages(.sendReply(to: self.sender)))
        }
        if model.store.messages.conversation != sender { model.store.send(.messages(.openConversation(sender))) }
        sendButton.configuration?.title = nil; sendButton.configuration?.background.backgroundColor = .clear
        sendButton.widthAnchor.constraint(equalToConstant: 26).isActive = true
        sendButton.isEnabled = false; bar.addArrangedSubview(reply); bar.addArrangedSubview(sendButton)
        view.addSubview(table); view.addSubview(bar); bar.translatesAutoresizingMaskIntoConstraints = false
        let divider = UIView(); divider.backgroundColor = .separator; divider.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(divider)
        NSLayoutConstraint.activate([divider.leadingAnchor.constraint(equalTo: view.leadingAnchor), divider.trailingAnchor.constraint(equalTo: view.trailingAnchor), divider.heightAnchor.constraint(equalToConstant: 0.5), divider.bottomAnchor.constraint(equalTo: bar.topAnchor, constant: -16)])
        NSLayoutConstraint.activate([table.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor), table.leadingAnchor.constraint(equalTo: view.leadingAnchor), table.trailingAnchor.constraint(equalTo: view.trailingAnchor), table.bottomAnchor.constraint(equalTo: bar.topAnchor, constant: -16), bar.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16), bar.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16), bar.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -16)])
    }
    override func didMove(toParent parent: UIViewController?) {
        super.didMove(toParent: parent)
        if parent == nil, model.store.messages.conversation == sender { model.store.send(.messages(.closeConversation)) }
    }
    func textViewDidChange(_ textView: UITextView) { model.store.send(.messages(.replyChanged(reply.text ?? ""))) }
    override func render() {
        title = model.contacts.displayName(for: sender)
        let feature = model.store.messages
        if reply.text != feature.reply { reply.text = feature.reply }
        updateReplyHeight()
        replyPlaceholder.isHidden = !feature.reply.isEmpty
        sendButton.isEnabled = !feature.sending && !feature.reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if let error = feature.error, presentedViewController == nil {
            let alert = UIAlertController(title: "Error", message: error, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .cancel) { [weak self] _ in self?.model.store.send(.messages(.clearError)) })
            present(alert, animated: true)
        }
        let messages = model.messages.filter { $0.sender == sender }.sorted { $0.timestamp < $1.timestamp }
        let wasAtBottom = firstLoad || table.contentOffset.y + table.bounds.height >= table.contentSize.height - 80
        let rows = messages.map { message in PhoneRow(id: String(describing: message.id), title: "", context: { UIMenu(children: [UIAction(title: "Copy", image: UIImage(systemName: "doc.on.doc")) { _ in UIPasteboard.general.string = message.content }]) }, bodyViewProvider: { PhoneMessageBubble(message: message) }, bodyVersion: "\(message.isOutgoing)|\(message.content)", insets: UIEdgeInsets(top: 4, left: 16, bottom: 4, right: 16)) }
        let ids = rows.map(\.id); setSections([PhoneSection(rows: rows)])
        if ids != lastIDs, wasAtBottom, !rows.isEmpty { table.layoutIfNeeded(); table.scrollToRow(at: IndexPath(row: rows.count - 1, section: 0), at: .bottom, animated: !firstLoad) }
        lastIDs = ids; firstLoad = false
        alignShortConversation()
    }
    override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); updateReplyHeight(); alignShortConversation() }
    private func updateReplyHeight() {
        guard reply.bounds.width > 0 else { return }
        let keyboard = view.keyboardLayoutGuide.layoutFrame
        let safeArea = view.safeAreaLayoutGuide.layoutFrame
        let available = (keyboard.width > 0 ? keyboard.minY : safeArea.maxY) - safeArea.minY
        let maximum = max(32, available / 2)
        let desired = max(32, reply.sizeThatFits(CGSize(width: reply.bounds.width, height: .greatestFiniteMagnitude)).height)
        let height = min(desired, maximum)
        if abs(replyHeight.constant - height) > 0.5 { replyHeight.constant = height }
        reply.isScrollEnabled = desired > maximum
    }
    private func alignShortConversation() {
        let inset = max(0, table.bounds.height - table.contentSize.height - table.contentInset.bottom)
        if abs(table.contentInset.top - inset) > 1 { table.contentInset.top = inset }
        if inset > 0, abs(table.contentOffset.y + inset) > 1 { table.setContentOffset(CGPoint(x: 0, y: -inset), animated: false) }
    }
}

@MainActor
final class MessageComposerViewController: ObservingViewController, UITextViewDelegate, UIAdaptivePresentationControllerDelegate {
    let model: AirSIMPresentation
    let recipient = UITextField()
    let content = UITextView()
    private let suggestions = UIStackView()
    private let messagePlaceholder = phoneLabel("Message", color: .placeholderText)
    private let recognized = phoneLabel(size: 14)
    private let sendButton = phoneButton("Send", image: "arrow.up") {}
    private var contentHeight: NSLayoutConstraint!
    init(model: AirSIMPresentation, recipient: String) {
        self.model = model; super.init(nibName: nil, bundle: nil)
        if !model.store.messages.composerPresented { model.store.send(.messages(.compose(recipient))) }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() {
        super.viewDidLoad(); title = "New Message"; view.backgroundColor = .systemBackground; navigationItem.largeTitleDisplayMode = .never
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: "Cancel", primaryAction: UIAction { [weak self] _ in self?.model.store.send(.messages(.dismissComposer)); self?.dismiss(animated: true) })
        navigationItem.leftBarButtonItem?.tintColor = .systemBlue
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "Send", primaryAction: UIAction { [weak self] _ in self?.model.store.send(.messages(.sendComposer)) })
        recipient.placeholder = "Enter number or name"; recipient.keyboardType = .phonePad; recipient.textContentType = .telephoneNumber; recipient.font = .preferredFont(forTextStyle: .body)
        recipient.addAction(UIAction { [weak self] _ in guard let self else { return }; self.model.store.send(.messages(.recipientChanged(self.recipient.text ?? ""))) }, for: .editingChanged)
        let choose = phoneButton("Choose from Contacts", image: "plus.circle.fill", color: .label) { [weak self] in self?.chooseContact() }; choose.configuration?.title = nil; choose.configuration?.background.backgroundColor = .clear
        let to = phoneLabel("To:", color: .secondaryLabel)
        let recipientBar = UIStackView(arrangedSubviews: [choose, to, recipient, recognized]); recipientBar.axis = .horizontal; recipientBar.spacing = 9; recipientBar.alignment = .center
        choose.widthAnchor.constraint(equalToConstant: 26).isActive = true; to.setContentHuggingPriority(.required, for: .horizontal); recognized.setContentHuggingPriority(.required, for: .horizontal)
        recognized.font = .preferredFont(forTextStyle: .subheadline); recognized.numberOfLines = 1
        let suggestionScroll = UIScrollView(); suggestionScroll.showsHorizontalScrollIndicator = false; suggestions.axis = .horizontal; suggestions.spacing = 8; suggestions.translatesAutoresizingMaskIntoConstraints = false; suggestionScroll.addSubview(suggestions)
        NSLayoutConstraint.activate([suggestions.leadingAnchor.constraint(equalTo: suggestionScroll.contentLayoutGuide.leadingAnchor, constant: 16), suggestions.trailingAnchor.constraint(equalTo: suggestionScroll.contentLayoutGuide.trailingAnchor, constant: -16), suggestions.topAnchor.constraint(equalTo: suggestionScroll.contentLayoutGuide.topAnchor, constant: 8), suggestions.bottomAnchor.constraint(equalTo: suggestionScroll.contentLayoutGuide.bottomAnchor, constant: -8), suggestions.heightAnchor.constraint(equalTo: suggestionScroll.frameLayoutGuide.heightAnchor, constant: -16)])
        content.font = .preferredFont(forTextStyle: .body); content.delegate = self; content.backgroundColor = UIColor { $0.userInterfaceStyle == .dark ? .secondarySystemGroupedBackground : .white }; content.layer.cornerRadius = 18; content.textContainerInset = UIEdgeInsets(top: 9, left: 13, bottom: 9, right: 13); content.accessibilityLabel = "Message"
        messagePlaceholder.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(messagePlaceholder)
        NSLayoutConstraint.activate([messagePlaceholder.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 13), messagePlaceholder.topAnchor.constraint(equalTo: content.topAnchor, constant: 9)])
        contentHeight = content.heightAnchor.constraint(equalToConstant: 40); contentHeight.isActive = true
        sendButton.configuration?.title = nil; sendButton.configuration?.baseForegroundColor = .white; sendButton.configuration?.background.backgroundColor = .systemBlue; sendButton.widthAnchor.constraint(equalToConstant: 36).isActive = true; sendButton.heightAnchor.constraint(equalToConstant: 36).isActive = true
        sendButton.addAction(UIAction { [weak self] _ in self?.model.store.send(.messages(.sendComposer)) }, for: .touchUpInside)
        let entry = UIStackView(arrangedSubviews: [content, sendButton]); entry.axis = .horizontal; entry.spacing = 9; entry.alignment = .bottom
        let caption = phoneLabel("Messages are sent through the 4G module", size: 11, color: .tertiaryLabel); caption.textAlignment = .center
        let bottom = UIStackView(arrangedSubviews: [entry, caption]); bottom.axis = .vertical; bottom.spacing = 5
        [recipientBar, suggestionScroll, bottom].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; view.addSubview($0) }
        for (anchor, offset) in [(recipientBar.bottomAnchor, CGFloat(0)), (bottom.topAnchor, CGFloat(-10))] {
            let separator = UIView(); separator.backgroundColor = UIColor.separator.withAlphaComponent(0.10); separator.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(separator)
            NSLayoutConstraint.activate([separator.leadingAnchor.constraint(equalTo: view.leadingAnchor), separator.trailingAnchor.constraint(equalTo: view.trailingAnchor), separator.heightAnchor.constraint(equalToConstant: 0.5), separator.topAnchor.constraint(equalTo: anchor, constant: offset)])
        }
        navigationItem.rightBarButtonItem?.setTitleTextAttributes([.foregroundColor: UIColor { $0.userInterfaceStyle == .dark ? .secondaryLabel : UIColor(white: 176.0 / 255.0, alpha: 1) }], for: .disabled)
        NSLayoutConstraint.activate([recipientBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16), recipientBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16), recipientBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor), recipientBar.heightAnchor.constraint(equalToConstant: 52), suggestionScroll.topAnchor.constraint(equalTo: recipientBar.bottomAnchor), suggestionScroll.leadingAnchor.constraint(equalTo: view.leadingAnchor), suggestionScroll.trailingAnchor.constraint(equalTo: view.trailingAnchor), suggestionScroll.heightAnchor.constraint(equalToConstant: 60), bottom.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16), bottom.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16), bottom.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -10)])
        Task { await model.contacts.loadIfAuthorized() }
    }
    override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); navigationController?.presentationController?.delegate = self }
    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) { model.store.send(.messages(.dismissComposer)) }
    func textViewDidChange(_ textView: UITextView) { model.store.send(.messages(.bodyChanged(content.text ?? ""))) }
    override func render() {
        let state = model.store.messages
        if !state.composerPresented { dismiss(animated: true); return }
        if recipient.text != state.recipient { recipient.text = state.recipient }
        if content.text != state.body { content.text = state.body }
        contentHeight.constant = min(130, max(40, content.sizeThatFits(CGSize(width: max(180, content.bounds.width), height: .greatestFiniteMagnitude)).height))
        let canSend = !state.recipient.trimmingCharacters(in: .whitespaces).isEmpty && !state.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !state.sending
        sendButton.isEnabled = canSend; sendButton.alpha = 1
        sendButton.configuration?.background.backgroundColor = canSend ? .systemBlue : UIColor { $0.userInterfaceStyle == .dark ? .systemGray5 : UIColor(white: 232.0 / 255.0, alpha: 1) }
        sendButton.configuration?.image = UIImage(systemName: "arrow.up")?.withTintColor(.white, renderingMode: .alwaysOriginal)
        messagePlaceholder.isHidden = !state.body.isEmpty
        navigationItem.rightBarButtonItem?.isEnabled = canSend
        let matched = model.contacts.contact(for: state.recipient); recognized.text = matched?.name; recognized.isHidden = matched == nil
        recognized.accessibilityLabel = matched.map { "Recognized contact: \($0.name)" }
        suggestions.arrangedSubviews.forEach { suggestions.removeArrangedSubview($0); $0.removeFromSuperview() }
        let query = state.recipient.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty, matched == nil {
            for contact in model.contacts.contacts.filter({ $0.name.localizedCaseInsensitiveContains(query) || $0.phones.contains { $0.localizedCaseInsensitiveContains(query) || $0.hasSuffix(query) } }).prefix(5) {
                let button = phoneButton(contact.name) { [weak self] in self?.model.store.send(.messages(.recipientChanged(contact.phones.first ?? query))) }
                button.configuration?.subtitle = contact.phones.first; suggestions.addArrangedSubview(button)
            }
        }
        if let error = state.error, presentedViewController == nil {
            let alert = UIAlertController(title: "Error", message: error, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .cancel) { [weak self] _ in self?.model.store.send(.messages(.clearError)) }); present(alert, animated: true)
        }
    }
    private func chooseContact() {
        let picker = ContactsViewController(model: model, onCall: { _ in }, onMessage: { _ in })
        picker.onSelect = { [weak self, weak picker] phone in self?.model.store.send(.messages(.recipientChanged(phone))); picker?.dismiss(animated: true) }
        showPhoneSheet(picker)
    }
}

@MainActor
final class ContactsViewController: PhoneTableController, UISearchResultsUpdating {
    override var tableStyle: UITableView.Style { .plain }
    let model: AirSIMPresentation
    let onCall: (String) -> Void
    let onMessage: (String) -> Void
    var onSelect: ((String) -> Void)?
    private let search = UISearchController(searchResultsController: nil)
    init(model: AirSIMPresentation, onCall: @escaping (String) -> Void, onMessage: @escaping (String) -> Void) { self.model = model; self.onCall = onCall; self.onMessage = onMessage; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() {
        super.viewDidLoad()
        if onSelect != nil { model.store.send(.contactPickerSearchChanged("")) }
        search.searchBar.text = onSelect == nil ? model.store.contactSearch : model.store.contactPickerSearch
        search.searchResultsUpdater = self; search.obscuresBackgroundDuringPresentation = false; search.searchBar.placeholder = "Search name or number"; navigationItem.searchController = search; navigationItem.hidesSearchBarWhenScrolling = false
        enableRefresh { [weak self] in await self?.model.contacts.requestAccessAndLoad() }
    }
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        Task { await model.contacts.loadIfAuthorized() }
    }
    func updateSearchResults(for searchController: UISearchController) {
        let text = searchController.searchBar.text ?? ""
        model.store.send(onSelect == nil ? .contactSearchChanged(text) : .contactPickerSearchChanged(text))
    }
    override func render() {
        title = onSelect == nil ? "Contacts" : "Choose Contact"
        navigationItem.title = onSelect == nil ? "Contacts · \(model.contacts.contacts.count)" : "Choose Contact"
        tabBarItem.title = "Contacts"
        guard model.contacts.isAuthorized else {
            let denied = model.contacts.authorizationState == .denied
            var configuration = UIContentUnavailableConfiguration.empty()
            configuration.image = UIImage(systemName: "person.crop.circle.badge.questionmark")
            configuration.text = denied ? "Contacts access is disabled" : "Allow Contacts Access"
            configuration.secondaryText = "Connect or grant access to get started."
            configuration.button = .filled(); configuration.button.title = denied ? "Open Settings" : "Allow Contacts Access"
            configuration.button.cornerStyle = .capsule
            configureContactEmptyStyle(&configuration)
            var buttonTitle = AttributeContainer(); buttonTitle.font = UIFont.systemFont(ofSize: 15, weight: .medium)
            configuration.button.attributedTitle = AttributedString(denied ? "Open Settings" : "Allow Contacts Access", attributes: buttonTitle)
            configuration.button.contentInsets = NSDirectionalEdgeInsets(top: 5, leading: 12, bottom: 5, trailing: 12)
            configuration.buttonProperties.primaryAction = UIAction { [weak self] _ in
                guard let self else { return }; if denied { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } } else { Task { await self.model.contacts.requestAccessAndLoad() } }
            }
            setSections([]); table.isHidden = true; contentUnavailableConfiguration = configuration
            return
        }
        table.isHidden = false; contentUnavailableConfiguration = nil
        let searchText = onSelect == nil ? model.store.contactSearch : model.store.contactPickerSearch
        if search.searchBar.text != searchText { search.searchBar.text = searchText }
        let query = searchText.trimmingCharacters(in: .whitespaces)
        let contacts = model.contacts.contacts.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.phones.contains { $0.localizedCaseInsensitiveContains(query) } }
        var rows: [PhoneRow] = []
        for contact in contacts {
            if let onSelect {
                for phone in ContactPhoneListPolicy.displayPhones(for: contact.phones) { rows.append(PhoneRow(id: contact.id + phone, title: contact.name, detail: phone, action: { onSelect(phone) }, photo: contact.photoData, avatarName: contact.name, bodyViewProvider: { PhoneListContentView(name: contact.name, subtitle: phone, photo: contact.photoData, avatarName: contact.name) }, insets: UIEdgeInsets(top: 0, left: 16, bottom: 0, right: 16))) }
            } else {
                rows.append(PhoneRow(id: contact.id, title: contact.name, detail: contact.phones.first ?? "", disclosure: true, action: { [weak self] in guard let self else { return }; self.navigationController?.pushViewController(ContactDetailViewController(contact: contact, onCall: self.onCall, onMessage: self.onMessage), animated: true) }, photo: contact.photoData, avatarName: contact.name, bodyViewProvider: { PhoneListContentView(name: contact.name, subtitle: contact.phones.first ?? "", photo: contact.photoData, avatarName: contact.name) }, insets: UIEdgeInsets(top: 0, left: 16, bottom: 0, right: 16)))
            }
        }
        table.separatorStyle = rows.isEmpty ? .none : .singleLine
        table.backgroundView = PhoneBackdropView()
        if rows.isEmpty {
            var configuration = UIContentUnavailableConfiguration.empty(); configuration.image = UIImage(systemName: "person.2"); configuration.text = "No contacts"; configuration.secondaryText = "Contacts sync from your device address book."
            configureContactEmptyStyle(&configuration)
            contentUnavailableConfiguration = configuration
        }
        setSections(rows.isEmpty ? [] : [PhoneSection(rows: rows)])
    }
    private func configureContactEmptyStyle(_ configuration: inout UIContentUnavailableConfiguration) {
        configuration.textProperties.font = UIFontMetrics(forTextStyle: .title3).scaledFont(for: .systemFont(ofSize: 20, weight: .bold))
        configuration.secondaryTextProperties.font = UIFontMetrics(forTextStyle: .body).scaledFont(for: .systemFont(ofSize: 20))
        configuration.secondaryTextProperties.numberOfLines = 0
        configuration.secondaryTextProperties.lineBreakMode = .byWordWrapping
        configuration.imageProperties.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 44)
        configuration.imageProperties.maximumSize = CGSize(width: 44, height: 44)
        configuration.imageToTextPadding = 24; configuration.textToSecondaryTextPadding = 2; configuration.textToButtonPadding = 28
        let width = traitCollection.horizontalSizeClass == .compact ? CGFloat(240) : CGFloat(360)
        let margin = max(16, (view.bounds.width - width) / 2)
        configuration.axesPreservingSuperviewLayoutMargins = []
        configuration.directionalLayoutMargins.leading = margin; configuration.directionalLayoutMargins.trailing = margin
    }
}

@MainActor
final class ContactDetailViewController: PhoneTableController {
    let contact: ContactStore.Contact
    let onCall: (String) -> Void; let onMessage: (String) -> Void
    init(contact: ContactStore.Contact, onCall: @escaping (String) -> Void, onMessage: @escaping (String) -> Void) { self.contact = contact; self.onCall = onCall; self.onMessage = onMessage; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() { super.viewDidLoad(); title = contact.name; navigationItem.largeTitleDisplayMode = .never }
    override func render() {
        let avatar = UIImageView(image: phoneAvatar(name: contact.name, photo: contact.photoData, size: 82)); avatar.widthAnchor.constraint(equalToConstant: 82).isActive = true; avatar.heightAnchor.constraint(equalToConstant: 82).isActive = true
        let heading = phoneLabel(contact.name, size: 22); heading.font = UIFontMetrics(forTextStyle: .title2).scaledFont(for: .systemFont(ofSize: 22, weight: .semibold))
        let header = UIStackView(arrangedSubviews: [avatar, heading]); header.axis = .vertical; header.spacing = 10; header.alignment = .center
        var rows: [PhoneRow] = []
        for phone in ContactPhoneListPolicy.displayPhones(for: contact.phones) {
            let number = phoneLabel(phone); let message = phoneButton("Send Message", image: "message.fill") { [weak self] in self?.onMessage(phone) }; let call = phoneButton("Dial", image: "phone.fill", color: .systemGreen) { [weak self] in self?.onCall(phone) }
            for button in [message, call] { button.configuration?.title = nil; button.widthAnchor.constraint(equalToConstant: 42).isActive = true; button.heightAnchor.constraint(equalToConstant: 42).isActive = true }
            let row = UIStackView(arrangedSubviews: [number, UIView(), message, call]); row.axis = .horizontal; row.alignment = .center; row.spacing = 12
            rows.append(PhoneRow(id: phone, title: "", bodyView: row))
        }
        setSections([PhoneSection(rows: [PhoneRow(id: "name", title: "", bodyView: header)]), PhoneSection(rows: rows)])
    }
}

@MainActor
final class ActiveCallViewController: ObservingViewController {
    private weak var keypadNavigationController: UINavigationController?
    let model: AirSIMPresentation
    private(set) var call: CallRecord
    var isPresentationPreview = false
    private let header = phoneLabel(size: 16, color: .lightGray)
    private let name = phoneLabel(size: 38, color: .white)
    private let number = phoneLabel(size: 20, color: .lightGray)
    private let status = phoneLabel(size: 12, color: .white)
    private let duration = phoneLabel(size: 24, color: .lightGray)
    private let avatar = UIImageView()
    private let center = UIStackView()
    private let controls = UIStackView()
    private let decisions = UIStackView()
    private let dot = UIView()
    private var record: UIButton!
    private var mute: CallCircleControl!
    private var speaker: CallCircleControl!
    private var lastPhase: CallSurfacePhase?
    private var avatarWidth: NSLayoutConstraint!
    private var headerWidth: NSLayoutConstraint!
    private var headerTop: NSLayoutConstraint!
    private var decisionsWidth: NSLayoutConstraint!
    private var bottomInset: NSLayoutConstraint!
    private var bottomStack: UIStackView!
    private let statusBadge = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
    private var timer: Timer?
    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }
    init(model: AirSIMPresentation, call: CallRecord) { self.model = model; self.call = call; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() {
        super.viewDidLoad(); view.isUserInteractionEnabled = !isPresentationPreview; overrideUserInterfaceStyle = .dark; view.accessibilityViewIsModal = true
        let background = CallBackdropView(); background.frame = view.bounds; background.autoresizingMask = [.flexibleWidth, .flexibleHeight]; view.addSubview(background)
        record = phoneButton("Record", image: "record.circle", color: .white) { [weak self] in Task { await self?.model.toggleRecording() } }; record.configuration?.title = nil; record.widthAnchor.constraint(equalToConstant: 44).isActive = true; record.heightAnchor.constraint(equalToConstant: 44).isActive = true
        let antenna = UIImageView(image: UIImage(systemName: "antenna.radiowaves.left.and.right")); antenna.tintColor = .lightGray
        let top = UIStackView(arrangedSubviews: [antenna, header, UIView(), record]); top.axis = .horizontal; top.alignment = .center; top.spacing = 10
        center.axis = .vertical; center.spacing = 8; center.alignment = .center
        avatarWidth = avatar.widthAnchor.constraint(equalToConstant: 116); avatarWidth.isActive = true; avatar.heightAnchor.constraint(equalTo: avatar.widthAnchor).isActive = true; avatar.isAccessibilityElement = false
        avatar.layer.shadowColor = UIColor.black.cgColor; avatar.layer.shadowRadius = 28; avatar.layer.shadowOpacity = 0.34; avatar.layer.shadowOffset = CGSize(width: 0, height: 16)
        center.addArrangedSubview(avatar); center.setCustomSpacing(24, after: avatar)
        for label in [name, number, duration] { label.textAlignment = .center; label.numberOfLines = 2; center.addArrangedSubview(label) }
        name.adjustsFontSizeToFitWidth = true; name.minimumScaleFactor = 0.68
        let badge = statusBadge; badge.layer.cornerRadius = 19; badge.clipsToBounds = true
        dot.backgroundColor = .systemOrange; dot.layer.cornerRadius = 4; dot.widthAnchor.constraint(equalToConstant: 8).isActive = true; dot.heightAnchor.constraint(equalToConstant: 8).isActive = true
        let badgeText = UIStackView(arrangedSubviews: [dot, status]); badgeText.axis = .horizontal; badgeText.spacing = 8; badgeText.alignment = .center; badgeText.translatesAutoresizingMaskIntoConstraints = false; badge.contentView.addSubview(badgeText)
        NSLayoutConstraint.activate([badgeText.leadingAnchor.constraint(equalTo: badge.contentView.leadingAnchor, constant: 14), badgeText.trailingAnchor.constraint(equalTo: badge.contentView.trailingAnchor, constant: -14), badgeText.topAnchor.constraint(equalTo: badge.contentView.topAnchor, constant: 11), badgeText.bottomAnchor.constraint(equalTo: badge.contentView.bottomAnchor, constant: -11)])
        center.addArrangedSubview(badge); center.setCustomSpacing(20, after: duration)
        controls.axis = .horizontal; controls.spacing = 20; controls.alignment = .top
        mute = CallCircleControl(title: "Mute", icon: "mic.fill", size: 62) { [weak self] in Task { await self?.model.toggleMute() } }
        let keypad = CallCircleControl(title: "Keypad", icon: "circle.grid.3x3.fill", size: 62) { [weak self] in self?.presentKeypad() }
        speaker = CallCircleControl(title: "Speaker", icon: "speaker.fill", size: 62) { [weak self] in self?.model.toggleSpeaker() }
        [mute!, keypad, speaker!].forEach { controls.addArrangedSubview($0) }
        decisions.axis = .horizontal; decisions.spacing = 100; decisions.alignment = .top
        let bottom = UIStackView(arrangedSubviews: [controls, decisions]); bottomStack = bottom; bottom.axis = .vertical; bottom.spacing = 30; bottom.alignment = .center
        for part in [top, center, bottom] { part.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(part) }
        let above = UILayoutGuide(); let below = UILayoutGuide(); view.addLayoutGuide(above); view.addLayoutGuide(below)
        headerTop = top.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 18)
        headerWidth = top.widthAnchor.constraint(equalToConstant: 362)
        decisionsWidth = decisions.widthAnchor.constraint(equalToConstant: 338)
        bottomInset = bottom.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -34)
        NSLayoutConstraint.activate([headerTop, headerWidth, top.centerXAnchor.constraint(equalTo: view.centerXAnchor), center.centerXAnchor.constraint(equalTo: view.centerXAnchor), center.widthAnchor.constraint(lessThanOrEqualToConstant: 520), center.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 20), center.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -20), above.topAnchor.constraint(equalTo: top.bottomAnchor), above.bottomAnchor.constraint(equalTo: center.topAnchor), below.topAnchor.constraint(equalTo: center.bottomAnchor), below.bottomAnchor.constraint(equalTo: bottom.topAnchor), above.heightAnchor.constraint(equalTo: below.heightAnchor), above.heightAnchor.constraint(greaterThanOrEqualToConstant: 0), bottom.centerXAnchor.constraint(equalTo: view.centerXAnchor), bottomInset, decisionsWidth])
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in Task { @MainActor in self?.updateDuration() } }
    }
    func presentKeypad(animated: Bool = true) {
        guard presentedViewController == nil else { return }
        model.store.send(.keypad(true))
        let keypad = DTMFKeypadViewController(model: model)
        keypadNavigationController = showPhoneSheet(keypad, animated: animated) { [weak self, weak keypad] in
            // UIKit can defer dismissal while presentation is still in flight.
            // The completion owns only this sheet, even if the call child is gone.
            if self?.model.store.keypadPresented != true { keypad?.navigationController?.dismiss(animated: false) }
        }
    }
    func dismissKeypad() {
        if let keypad = keypadNavigationController, keypad.presentingViewController != nil { keypad.dismiss(animated: false) }
        keypadNavigationController = nil
        model.store.send(.keypad(false))
    }
    func update(call: CallRecord) { self.call = call; if isViewLoaded { render() } }
    override func render() {
        let content = CallSurfaceContent(state: call.state); let incoming = content.phase == .incoming
        let compact = traitCollection.horizontalSizeClass == .compact || view.bounds.height < 700
        let size: CGFloat = incoming ? (compact ? 116 : 132) : (compact ? 92 : 112)
        avatarWidth.constant = size
        avatar.layer.cornerRadius = size / 2; avatar.layer.borderWidth = 1; avatar.layer.borderColor = UIColor.white.withAlphaComponent(0.2).cgColor
        let outer: CGFloat = compact ? 20 : 32
        headerWidth.constant = min(520, max(0, view.bounds.width - outer * 2))
        headerTop.constant = compact ? 18 : 26
        decisionsWidth.constant = min(430, max(0, view.bounds.width - outer * 2 - (compact ? 24 : 56)))
        decisions.distribution = .equalSpacing
        bottomInset.constant = -((compact ? 18 : 26) + (incoming ? (compact ? 16 : 28) : (compact ? 8 : 18)))
        bottomStack.spacing = compact ? 30 : 42
        controls.spacing = compact ? 20 : 34
        for control in controls.arrangedSubviews { (control as? CallCircleControl)?.setSize(compact ? 62 : 68) }
        center.setCustomSpacing(incoming ? 24 : 22, after: avatar)
        center.setCustomSpacing(incoming ? 22 : 20, after: duration)
        header.font = .systemFont(ofSize: 15, weight: .semibold)
        header.text = incoming ? "AirSIM Incoming Call" : "AirSIM Call"
        let displayName = model.contacts.displayName(for: call.number)
        name.text = displayName; name.font = UIFontMetrics(forTextStyle: .largeTitle).scaledFont(for: .systemFont(ofSize: incoming ? (compact ? 38 : 44) : 34, weight: .semibold))
        number.text = call.number; number.isHidden = call.number == nil || call.number == displayName
        avatar.image = phoneAvatar(name: displayName, photo: call.number.flatMap { model.contacts.contact(for: $0)?.photoData }, size: size)
        record.isHidden = incoming; record.isEnabled = model.canToggleRecording && !model.isRecordingBusy
        record.configuration?.image = UIImage(systemName: model.isRecording ? "record.circle.fill" : "record.circle"); record.accessibilityLabel = model.isRecording ? "Stop Recording" : "Record"; record.configuration?.baseForegroundColor = model.isRecording ? .systemRed : .white
        mute.update(title: model.isMuted ? "Unmute" : "Mute", icon: model.isMuted ? "mic.slash.fill" : "mic.fill", tint: model.isMuted ? .systemOrange : nil)
        speaker.update(title: "Speaker", icon: model.audio.speakerEnabled ? "speaker.wave.2.fill" : "speaker.fill", tint: model.audio.speakerEnabled ? .systemBlue : nil)
        controls.isHidden = incoming
        if lastPhase != content.phase {
            decisions.arrangedSubviews.forEach { decisions.removeArrangedSubview($0); $0.removeFromSuperview() }
            if incoming {
                decisions.addArrangedSubview(CallCircleControl(title: "Decline", icon: "phone.down.fill", size: 76, color: .systemRed) { [weak self] in Task { await self?.model.reject() } })
                decisions.addArrangedSubview(CallCircleControl(title: "Accept", icon: "phone.fill", size: 76, color: .systemGreen) { [weak self] in Task { await self?.model.answer() } })
            } else { decisions.addArrangedSubview(CallCircleControl(title: "End", icon: "phone.down.fill", size: 76, color: .systemRed) { [weak self] in Task { await self?.model.hangup() } }) }
            lastPhase = content.phase
        }
        if incoming {
            let online = model.isOnline || model.cloudAgentStatus?.cloudOnline == true; dot.backgroundColor = online ? .systemGreen : .systemOrange
            statusBadge.contentView.backgroundColor = (online ? UIColor.systemGreen : .systemOrange).withAlphaComponent(0.1)
            status.text = online ? "Module Online" : "Connecting to Module"
            if let signal = model.modemStatus?.signalDBM ?? model.cloudAgentStatus?.signalDBM { status.text = "\(status.text ?? "") · Signal \(signal) dBm" }
        } else {
            let audioColor: UIColor
            switch model.cloudCallAudioState {
            case .failed: audioColor = .systemRed
            case .connected: audioColor = .systemGreen
            case .starting, .connecting: audioColor = .systemOrange
            case .idle: audioColor = model.audio.active ? .systemGreen : .systemOrange
            }
            dot.backgroundColor = model.callAudioIsActive ? .systemGreen : audioColor
            statusBadge.contentView.backgroundColor = audioColor.withAlphaComponent(0.1)
            status.text = model.callAudioStatusText + (model.audio.active && !model.audio.routeDescription.isEmpty ? " · \(model.audio.routeDescription)" : "") + (model.audio.errorMessage.map { "\n\($0)" } ?? "")
        }
        updateDuration(); if !isPresentationPreview { UIDevice.current.isProximityMonitoringEnabled = CallProximityPolicy.shouldMonitor(state: call.state, speakerEnabled: model.audio.speakerEnabled) }
    }
    private func updateDuration() { duration.text = CallSurfaceContent(state: call.state).showsDuration ? Duration.seconds(max(0, Int(Date().timeIntervalSince(call.startedAt)))).formatted(.time(pattern: .minuteSecond(padMinuteToLength: 2))) : "Waiting"; duration.font = .monospacedDigitSystemFont(ofSize: CallSurfaceContent(state: call.state).showsDuration ? 24 : 15, weight: .medium) }
    override func viewDidDisappear(_ animated: Bool) { super.viewDidDisappear(animated); if !isPresentationPreview { UIDevice.current.isProximityMonitoringEnabled = false } }
    deinit { timer?.invalidate() }
}

@MainActor
final class DTMFKeypadViewController: ObservingViewController {
    let model: AirSIMPresentation
    private let digits = phoneLabel("Tap keys to send DTMF tones", size: 20)
    init(model: AirSIMPresentation) { self.model = model; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() {
        super.viewDidLoad(); title = "Call Keypad"; view.backgroundColor = .systemBackground
        let stack = UIStackView(); stack.axis = .vertical; stack.spacing = 12; stack.alignment = .center; stack.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(stack)
        NSLayoutConstraint.activate([stack.centerXAnchor.constraint(equalTo: view.centerXAnchor), stack.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor), stack.topAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.topAnchor, constant: 8), stack.bottomAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8)])
        digits.accessibilityLabel = "No digits entered"; stack.addArrangedSubview(digits)
        let digitRows: [[String]] = [["1", "2", "3"], ["4", "5", "6"], ["7", "8", "9"], ["*", "0", "#"]]
        for rowDigits in digitRows {
            let row = UIStackView(); row.axis = .horizontal; row.spacing = 24
            for digit in rowDigits {
                let key = phoneButton(digit, color: .label) { [weak self] in
                    guard let self else { return }; UIImpactFeedbackGenerator(style: .light).impactOccurred(); self.model.store.send(.dtmf(digit))
                }; key.accessibilityLabel = "Send DTMF \(digit)"; key.widthAnchor.constraint(equalToConstant: 62).isActive = true; key.heightAnchor.constraint(equalToConstant: 54).isActive = true; row.addArrangedSubview(key)
            }; stack.addArrangedSubview(row)
        }
    }
    override func render() { digits.text = enteredDigits.isEmpty ? "Tap keys to send DTMF tones" : enteredDigits; digits.accessibilityLabel = enteredDigits.isEmpty ? "No digits entered" : enteredDigits }
    override func viewDidDisappear(_ animated: Bool) { super.viewDidDisappear(animated); model.store.send(.keypad(false)) }
}

private extension DTMFKeypadViewController {
    var enteredDigits: String { model.store.keypadDigits }
}

@MainActor
private final class RecentCallDetailsViewController: UIViewController {
    let call: CallRecord; let model: AirSIMPresentation
    let onCall: () -> Void; let onMessage: () -> Void; let onDelete: () -> Void
    init(call: CallRecord, model: AirSIMPresentation, onCall: @escaping () -> Void, onMessage: @escaping () -> Void, onDelete: @escaping () -> Void) { self.call = call; self.model = model; self.onCall = onCall; self.onMessage = onMessage; self.onDelete = onDelete; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() {
        super.viewDidLoad(); view.backgroundColor = UIColor.black.withAlphaComponent(0.18)
        let backdrop = UIButton(frame: view.bounds); backdrop.autoresizingMask = [.flexibleWidth, .flexibleHeight]; backdrop.addTarget(self, action: #selector(close), for: .touchUpInside); view.addSubview(backdrop)
        let card = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial)); card.layer.cornerRadius = 28; card.clipsToBounds = true; card.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(card)
        let name = model.contacts.displayName(for: call.number)
        let image = UIImageView(image: phoneAvatar(name: name, photo: call.number.flatMap { model.contacts.contact(for: $0)?.photoData }, size: 58)); image.widthAnchor.constraint(equalToConstant: 58).isActive = true; image.heightAnchor.constraint(equalToConstant: 58).isActive = true
        let title = phoneLabel(name, size: 20); title.font = .systemFont(ofSize: 20, weight: .semibold); title.textAlignment = .center
        let number = phoneLabel(call.number ?? "", size: 17, color: .secondaryLabel); number.textAlignment = .center
        let date = phoneLabel(RecentCallTimeFormatter.string(for: call.startedAt), size: 12, color: .secondaryLabel); date.textAlignment = .center
        let stack = UIStackView(arrangedSubviews: [image, title, number, date]); stack.axis = .vertical; stack.spacing = 8; stack.alignment = .center
        for (label, icon, color, action) in [("Call Back", "phone.fill", UIColor.systemGreen, onCall), ("Send Message", "message.fill", UIColor.systemBlue, onMessage), ("Delete Call Record", "trash", UIColor.systemRed, onDelete)] {
            let button = phoneButton(label, image: icon, color: color) { [weak self] in self?.dismiss(animated: true, completion: action) }
            if label == "Call Back" { button.configuration?.baseBackgroundColor = .systemGreen; button.configuration?.baseForegroundColor = .white; button.configuration?.background.backgroundColor = .systemGreen }
            button.configuration?.cornerStyle = .medium; button.heightAnchor.constraint(greaterThanOrEqualToConstant: 48).isActive = true
            stack.addArrangedSubview(button); button.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        let cancel = phoneButton("Cancel", color: .secondaryLabel) { [weak self] in self?.close() }; cancel.configuration = .plain(); cancel.setTitle("Cancel", for: .normal); stack.addArrangedSubview(cancel)
        stack.translatesAutoresizingMaskIntoConstraints = false; card.contentView.addSubview(stack)
        let preferred = card.widthAnchor.constraint(equalToConstant: 340); preferred.priority = .defaultHigh
        NSLayoutConstraint.activate([card.centerXAnchor.constraint(equalTo: view.centerXAnchor), card.centerYAnchor.constraint(equalTo: view.centerYAnchor), preferred, card.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 28), card.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -28), stack.leadingAnchor.constraint(equalTo: card.contentView.leadingAnchor, constant: 22), stack.trailingAnchor.constraint(equalTo: card.contentView.trailingAnchor, constant: -22), stack.topAnchor.constraint(equalTo: card.contentView.topAnchor, constant: 22), stack.bottomAnchor.constraint(equalTo: card.contentView.bottomAnchor, constant: -22)])
    }
    @objc private func close() { dismiss(animated: true) }
}

@MainActor
private final class AndroidAgentCardView: UIView {
    init(agent: AndroidAgentPresentation?, count: Int, cloudEnabled: Bool) {
        super.init(frame: .zero)
        let material = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterial)); material.layer.cornerRadius = 16; material.clipsToBounds = true; material.translatesAutoresizingMaskIntoConstraints = false; addSubview(material)
        let stack = UIStackView(); stack.axis = .vertical; stack.spacing = 10; stack.translatesAutoresizingMaskIntoConstraints = false; material.contentView.addSubview(stack)
        let icon = UIImageView(image: UIImage(systemName: agent == nil ? "smartphone.slash" : "smartphone")); icon.tintColor = agent == nil ? .secondaryLabel : .systemGreen; icon.contentMode = .center; icon.widthAnchor.constraint(equalToConstant: 34).isActive = true; icon.heightAnchor.constraint(equalToConstant: 34).isActive = true; icon.backgroundColor = UIColor.systemGreen.withAlphaComponent(agent == nil ? 0 : 0.12); icon.layer.cornerRadius = 17
        let title = phoneLabel(agent?.deviceName ?? "Paired Android Agents · \(count)", size: 15); title.font = .systemFont(ofSize: 15, weight: .semibold); title.numberOfLines = 1
        let titleRow = UIStackView(arrangedSubviews: [title]); titleRow.axis = .horizontal; titleRow.spacing = 6
        if agent != nil { let current = pill("Current", color: .systemGreen); titleRow.addArrangedSubview(current) }
        titleRow.addArrangedSubview(UIView())
        let detail = phoneLabel(agent?.phoneNumber ?? (agent == nil ? "No call route is currently available" : "Number unavailable"), size: 12, color: .secondaryLabel); detail.numberOfLines = 1
        let text = UIStackView(arrangedSubviews: [titleRow, detail]); text.axis = .vertical; text.spacing = 2
        let row = UIStackView(arrangedSubviews: [icon, text]); row.axis = .horizontal; row.spacing = 10; row.alignment = .center
        if count > 1 { let all = phoneLabel("All \(count)", size: 12, color: .systemBlue); all.setContentHuggingPriority(.required, for: .horizontal); row.addArrangedSubview(all) }
        stack.addArrangedSubview(row)
        if let agent {
            let routes = UIStackView(arrangedSubviews: [pill("VoWLAN \(agent.vowlanOnline ? "Online" : "Offline")", color: agent.vowlanOnline ? .systemGreen : .secondaryLabel), pill("Cloud \(!cloudEnabled ? "Off" : (agent.cloudOnline ? "Online" : "Offline"))", color: cloudEnabled && agent.cloudOnline ? .systemGreen : .secondaryLabel), UIView(), phoneLabel(String(localized: agent.agentKindTitle), size: 10, color: .secondaryLabel)]); routes.axis = .horizontal; routes.spacing = 8; routes.alignment = .center; stack.addArrangedSubview(routes)
        }
        NSLayoutConstraint.activate([material.leadingAnchor.constraint(equalTo: leadingAnchor), material.trailingAnchor.constraint(equalTo: trailingAnchor), material.topAnchor.constraint(equalTo: topAnchor), material.bottomAnchor.constraint(equalTo: bottomAnchor), stack.leadingAnchor.constraint(equalTo: material.contentView.leadingAnchor, constant: 12), stack.trailingAnchor.constraint(equalTo: material.contentView.trailingAnchor, constant: -12), stack.topAnchor.constraint(equalTo: material.contentView.topAnchor, constant: 12), stack.bottomAnchor.constraint(equalTo: material.contentView.bottomAnchor, constant: -12)])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private func pill(_ title: String, color: UIColor) -> UIView {
        let text = phoneLabel(title, size: 10, color: color); text.font = .systemFont(ofSize: 10, weight: .medium); text.numberOfLines = 1
        let box = UIStackView(arrangedSubviews: [text]); box.isLayoutMarginsRelativeArrangement = true; box.layoutMargins = UIEdgeInsets(top: 4, left: 8, bottom: 4, right: 8); box.backgroundColor = color.withAlphaComponent(0.1); box.layer.cornerRadius = 10; return box
    }
}

#if DEBUG
#Preview("Dial · Connected Agent") {
    AirSIMPreviewFixtures.navigation(DialPadViewController(model: AirSIMPreviewFixtures.presentation()))
}

#Preview("Paired Android Agents") {
    AirSIMPreviewFixtures.navigation(PairedAndroidAgentsViewController(model: AirSIMPreviewFixtures.presentation()))
}

#Preview("Recents · Calls") {
    AirSIMPreviewFixtures.navigation(RecentsViewController(model: AirSIMPreviewFixtures.presentation(tab: .recents), onCall: { _ in }, onMessage: { _ in }))
}

#Preview("Messages · Conversations") {
    AirSIMPreviewFixtures.navigation(MessagesViewController(model: AirSIMPreviewFixtures.presentation(tab: .messages)))
}

#Preview("Messages · Thread") {
    let model = AirSIMPreviewFixtures.presentation(tab: .messages)
    model.store.send(.messages(.openConversation(AirSIMPreviewFixtures.phone)))
    return AirSIMPreviewFixtures.navigation(MessageThreadViewController(model: model, sender: AirSIMPreviewFixtures.phone))
}

#Preview("Messages · Composer") {
    let model = AirSIMPreviewFixtures.presentation(tab: .messages)
    model.store.send(.messages(.compose(AirSIMPreviewFixtures.phone)))
    model.store.send(.messages(.bodyChanged("I will be there in five minutes.")))
    return AirSIMPreviewFixtures.navigation(MessageComposerViewController(model: model, recipient: AirSIMPreviewFixtures.phone))
}

#Preview("Contacts · People") {
    AirSIMPreviewFixtures.navigation(ContactsViewController(model: AirSIMPreviewFixtures.presentation(tab: .contacts), onCall: { _ in }, onMessage: { _ in }))
}

#Preview("Contacts · Empty") {
    AirSIMPreviewFixtures.navigation(ContactsViewController(model: AirSIMPreviewFixtures.presentation(tab: .contacts, empty: true), onCall: { _ in }, onMessage: { _ in }))
}

#Preview("Contact · Details") {
    AirSIMPreviewFixtures.navigation(ContactDetailViewController(contact: AirSIMPreviewFixtures.contact, onCall: { _ in }, onMessage: { _ in }))
}

#Preview("Call · Incoming") {
    let model = AirSIMPreviewFixtures.presentation(callState: "incoming")
    let controller = ActiveCallViewController(model: model, call: AirSIMPreviewFixtures.call("incoming"))
    controller.isPresentationPreview = true
    return controller
}

#Preview("Call · Connected") {
    let model = AirSIMPreviewFixtures.presentation(callState: "active")
    let controller = ActiveCallViewController(model: model, call: AirSIMPreviewFixtures.call("active"))
    controller.isPresentationPreview = true
    return controller
}

#Preview("Call · DTMF Keypad") {
    let model = AirSIMPreviewFixtures.presentation(callState: "active")
    model.store.send(.keypad(true))
    return AirSIMPreviewFixtures.navigation(DTMFKeypadViewController(model: model))
}

#Preview("Recent Call · Details Card") {
    RecentCallDetailsViewController(call: AirSIMPreviewFixtures.history[0], model: AirSIMPreviewFixtures.presentation(tab: .recents), onCall: {}, onMessage: {}, onDelete: {})
}

#Preview("Component · Android Agent Card") {
    AirSIMPreviewFixtures.canvas(AndroidAgentCardView(agent: AirSIMPreviewFixtures.agents[0], count: 2, cloudEnabled: true), height: 94)
}
#endif
