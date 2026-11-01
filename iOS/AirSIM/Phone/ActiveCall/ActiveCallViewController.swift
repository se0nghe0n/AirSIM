import ComposableArchitecture
import UIKit

/// The in-app call screen: the caller, the call's status and duration, Accept and Decline while the call rings, and
/// the in-call controls and End once it connects.
@MainActor
@ViewAction(for: ActiveCallFeature.self)
final class ActiveCallViewController: ObservingViewController {
    // MARK: Store

    let store: StoreOf<ActiveCallFeature>
    var call: CallRecord? { store.call }
    /// Previews and layout screenshots ignore touches and leave the proximity sensor alone.
    var isPresentationPreview = false

    // MARK: Views

    private let headerBar = UIStackView(axis: .horizontal, spacing: Metrics.headerSpacing, alignment: .center)
    private let headerLabel = phoneLabel(size: 16, color: .lightGray)
    private lazy var recordButton = phoneButton("Record", image: "record.circle", color: .white) { [weak self] in
        self?.send(.recordButtonTapped)
    }
    private let center = UIStackView(axis: .vertical, spacing: Metrics.centerSpacing, alignment: .center)
    private let avatar = UIImageView()
    private let nameLabel = phoneLabel(size: 38, color: .white)
    private let numberLabel = phoneLabel(size: 20, color: .lightGray)
    private let durationLabel = phoneLabel(size: 24, color: .lightGray)
    private let statusBadge = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
    private let statusDot = UIView()
    private let statusLabel = phoneLabel(size: 12, color: .white)
    private let bottomStack = UIStackView(axis: .vertical, spacing: Metrics.initialBottomSpacing, alignment: .center)
    private let controls = UIStackView(axis: .horizontal, spacing: Metrics.initialControlSpacing, alignment: .top)
    private lazy var muteControl = CallCircleControl(
        title: "Mute",
        icon: "mic.fill",
        size: Metrics.controlSize
    ) { [weak self] in
        self?.send(.muteButtonTapped)
    }
    private lazy var speakerControl = CallCircleControl(
        title: "Speaker",
        icon: "speaker.fill",
        size: Metrics.controlSize
    ) { [weak self] in
        self?.send(.speakerButtonTapped)
    }
    private let decisions = UIStackView(
        axis: .horizontal,
        spacing: Metrics.decisionSpacing,
        alignment: .top,
        distribution: .equalSpacing
    )
    private var lastPhase: ActiveCallContent.Phase?
    private lazy var avatarWidth = avatar.widthAnchor.constraint(equalToConstant: Metrics.initialAvatarSize)
    private lazy var headerTop = headerBar.topAnchor.constraint(
        equalTo: view.safeAreaLayoutGuide.topAnchor,
        constant: Metrics.initialHeaderTop
    )
    private lazy var headerWidth = headerBar.widthAnchor.constraint(equalToConstant: Metrics.initialHeaderWidth)
    private lazy var decisionsWidth = decisions.widthAnchor.constraint(equalToConstant: Metrics.initialDecisionsWidth)
    private lazy var bottomInset = bottomStack.bottomAnchor.constraint(
        equalTo: view.safeAreaLayoutGuide.bottomAnchor,
        constant: -Metrics.initialBottomInset
    )
    private var durationTimer: RepeatingTimer?

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }

    // MARK: Lifecycle

    init(store: StoreOf<ActiveCallFeature>) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.isUserInteractionEnabled = !isPresentationPreview
        overrideUserInterfaceStyle = .dark
        view.accessibilityViewIsModal = true
        buildBackdrop()
        buildHeader()
        buildCenter()
        buildControls()
        buildBottom()
        buildLayout()
        startDurationTimer()
        bindPresentations()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if !isPresentationPreview {
            UIDevice.current.isProximityMonitoringEnabled = false
        }
    }

    // MARK: Rendering

    override func render() {
        // Once the call leaves, the root removes this screen's window; until then it keeps the last call drawn.
        guard let content = store.content else { return }
        let compact = traitCollection.horizontalSizeClass == .compact || view.bounds.height < Metrics.compactHeight
        let layout = CallLayout(width: view.bounds.width, compact: compact, incoming: content.isIncoming)
        renderLayout(layout)
        renderCaller(content, layout: layout)
        renderRecordButton(content)
        renderControls(content)
        renderDecisions(content.phase)
        renderStatus(content)
        renderDuration(content)
        if !isPresentationPreview {
            UIDevice.current.isProximityMonitoringEnabled = content.monitorsProximity
        }
    }

    private func renderLayout(_ layout: CallLayout) {
        avatarWidth.constant = layout.avatarSize
        avatar.layer.cornerRadius = layout.avatarSize / 2
        headerWidth.constant = layout.headerWidth
        headerTop.constant = layout.headerTop
        decisionsWidth.constant = layout.decisionsWidth
        bottomInset.constant = -layout.bottomInset
        bottomStack.spacing = layout.bottomSpacing
        controls.spacing = layout.controlSpacing
        for control in controls.arrangedSubviews {
            (control as? CallCircleControl)?.setSize(layout.controlSize)
        }
        center.setCustomSpacing(layout.spacingAfterAvatar, after: avatar)
        center.setCustomSpacing(layout.spacingAfterDuration, after: durationLabel)
    }

    private func renderCaller(_ content: ActiveCallContent, layout: CallLayout) {
        headerLabel.text = content.header
        nameLabel.text = content.name
        nameLabel.font = UIFontMetrics(forTextStyle: .largeTitle)
            .scaledFont(for: .systemFont(ofSize: layout.nameFontSize, weight: .semibold))
        numberLabel.text = content.number
        numberLabel.isHidden = !content.showsNumber
        avatar.image = phoneAvatar(name: content.name, photo: content.photo, size: layout.avatarSize)
    }

    private func renderRecordButton(_ content: ActiveCallContent) {
        let icon = content.isRecording ? "record.circle.fill" : "record.circle"
        recordButton.isHidden = content.isIncoming
        recordButton.isEnabled = content.canToggleRecording
        recordButton.configuration?.image = UIImage(systemName: icon)
        recordButton.accessibilityLabel = content.isRecording ? "Stop Recording" : "Record"
        recordButton.configuration?.baseForegroundColor = content.isRecording ? .systemRed : .white
    }

    private func renderControls(_ content: ActiveCallContent) {
        controls.isHidden = content.isIncoming
        muteControl.update(
            title: content.isMuted ? "Unmute" : "Mute",
            icon: content.isMuted ? "mic.slash.fill" : "mic.fill",
            tint: content.isMuted ? .systemOrange : nil
        )
        speakerControl.update(
            title: "Speaker",
            icon: content.speakerEnabled ? "speaker.wave.2.fill" : "speaker.fill",
            tint: content.speakerEnabled ? .systemBlue : nil
        )
    }

    /// Accept and Decline while the call rings, End once it connects. Rebuilt only when the phase changes.
    private func renderDecisions(_ phase: ActiveCallContent.Phase) {
        guard phase != lastPhase else { return }
        lastPhase = phase
        for button in decisions.arrangedSubviews {
            decisions.removeArrangedSubview(button)
            button.removeFromSuperview()
        }
        switch phase {
        case .incoming:
            decisions.addArrangedSubview(
                decisionControl("Decline", icon: "phone.down.fill", color: .systemRed, action: .declineButtonTapped)
            )
            decisions.addArrangedSubview(
                decisionControl("Accept", icon: "phone.fill", color: .systemGreen, action: .answerButtonTapped)
            )
        case .connected:
            decisions.addArrangedSubview(
                decisionControl("End", icon: "phone.down.fill", color: .systemRed, action: .endButtonTapped)
            )
        }
    }

    private func renderStatus(_ content: ActiveCallContent) {
        statusLabel.text = content.status
        statusDot.backgroundColor = content.dotTone.color
        statusBadge.contentView.backgroundColor = content.badgeTone.color.withAlphaComponent(0.1)
    }

    private func renderDuration(_ content: ActiveCallContent) {
        durationLabel.text = content.duration(at: Date())
        durationLabel.font = .monospacedDigitSystemFont(
            ofSize: content.showsDuration ? Metrics.durationFontSize : Metrics.waitingFontSize,
            weight: .medium
        )
    }

    // MARK: Layout

    private func buildBackdrop() {
        let backdrop = CallBackdropView()
        backdrop.frame = view.bounds
        backdrop.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(backdrop)
    }

    /// The antenna and the call title on the left, Record on the right.
    private func buildHeader() {
        let antenna = UIImageView(image: UIImage(systemName: "antenna.radiowaves.left.and.right"))
        antenna.tintColor = .lightGray
        headerLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        recordButton.configuration?.title = nil
        NSLayoutConstraint.activate([
            recordButton.widthAnchor.constraint(equalToConstant: Metrics.recordButtonSize),
            recordButton.heightAnchor.constraint(equalToConstant: Metrics.recordButtonSize),
        ])
        for part in [antenna, headerLabel, UIView(), recordButton] {
            headerBar.addArrangedSubview(part)
        }
    }

    /// The avatar over the name, the number, the duration and the status badge.
    private func buildCenter() {
        avatar.isAccessibilityElement = false
        avatar.layer.borderWidth = 1
        avatar.layer.borderColor = UIColor.white.withAlphaComponent(0.2).cgColor
        avatar.layer.shadowColor = UIColor.black.cgColor
        avatar.layer.shadowRadius = 28
        avatar.layer.shadowOpacity = 0.34
        avatar.layer.shadowOffset = CGSize(width: 0, height: 16)
        NSLayoutConstraint.activate([
            avatarWidth,
            avatar.heightAnchor.constraint(equalTo: avatar.widthAnchor),
        ])
        center.addArrangedSubview(avatar)
        center.setCustomSpacing(Metrics.initialSpacingAfterAvatar, after: avatar)
        for label in [nameLabel, numberLabel, durationLabel] {
            label.textAlignment = .center
            label.numberOfLines = 2
            center.addArrangedSubview(label)
        }
        nameLabel.adjustsFontSizeToFitWidth = true
        nameLabel.minimumScaleFactor = 0.68
        buildStatusBadge()
        center.addArrangedSubview(statusBadge)
        center.setCustomSpacing(Metrics.initialSpacingAfterDuration, after: durationLabel)
    }

    /// A blurred capsule holding the status dot and the status text.
    private func buildStatusBadge() {
        statusBadge.layer.cornerRadius = Metrics.badgeCornerRadius
        statusBadge.clipsToBounds = true
        statusDot.backgroundColor = .systemOrange
        statusDot.layer.cornerRadius = Metrics.dotSize / 2
        NSLayoutConstraint.activate([
            statusDot.widthAnchor.constraint(equalToConstant: Metrics.dotSize),
            statusDot.heightAnchor.constraint(equalToConstant: Metrics.dotSize),
        ])
        let content = UIStackView(
            [statusDot, statusLabel],
            axis: .horizontal,
            spacing: Metrics.dotSpacing,
            alignment: .center
        )
        statusBadge.contentView.addPinnedSubview(content, insets: Metrics.badgeInsets)
    }

    /// Mute, Keypad and Speaker.
    private func buildControls() {
        let keypad = CallCircleControl(
            title: "Keypad",
            icon: "circle.grid.3x3.fill",
            size: Metrics.controlSize
        ) { [weak self] in
            self?.send(.keypadButtonTapped)
        }
        for control in [muteControl, keypad, speakerControl] {
            controls.addArrangedSubview(control)
        }
    }

    /// The in-call controls over the decision buttons.
    private func buildBottom() {
        bottomStack.addArrangedSubview(controls)
        bottomStack.addArrangedSubview(decisions)
    }

    /// The header at the top and the controls at the bottom; the center block sits halfway between them.
    private func buildLayout() {
        for part in [headerBar, center, bottomStack] {
            part.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(part)
        }
        NSLayoutConstraint.activate([
            headerTop,
            headerWidth,
            headerBar.centerXAnchor.constraint(equalTo: view.centerXAnchor),
        ])
        NSLayoutConstraint.activate([
            center.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            center.widthAnchor.constraint(lessThanOrEqualToConstant: Metrics.maximumCenterWidth),
            center.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: Metrics.centerMargin),
            center.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -Metrics.centerMargin),
        ])
        NSLayoutConstraint.activate([
            bottomStack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            bottomInset,
            decisionsWidth,
        ])
        let above = UILayoutGuide()
        let below = UILayoutGuide()
        view.addLayoutGuide(above)
        view.addLayoutGuide(below)
        NSLayoutConstraint.activate([
            above.topAnchor.constraint(equalTo: headerBar.bottomAnchor),
            above.bottomAnchor.constraint(equalTo: center.topAnchor),
            below.topAnchor.constraint(equalTo: center.bottomAnchor),
            below.bottomAnchor.constraint(equalTo: bottomStack.topAnchor),
            above.heightAnchor.constraint(equalTo: below.heightAnchor),
            above.heightAnchor.constraint(greaterThanOrEqualToConstant: 0),
        ])
    }

    private func decisionControl(
        _ title: String,
        icon: String,
        color: UIColor,
        action: ActiveCallFeature.Action.View
    ) -> CallCircleControl {
        CallCircleControl(title: title, icon: icon, size: Metrics.decisionSize, color: color) { [weak self] in
            self?.send(action)
        }
    }

    private func startDurationTimer() {
        durationTimer = RepeatingTimer(interval: 1) { [weak self] in
            Task { @MainActor in self?.tick() }
        }
    }

    private func tick() {
        guard let content = store.content else { return }
        renderDuration(content)
    }

    // MARK: Navigation

    private func bindPresentations() {
        present(item: UIBindable(store).scope(\.$keypad, action: \.keypad)) {
            phoneSheet(DTMFKeypadViewController(store: $0))
        }
    }
}

/// The call screen's sizes for its width, whether it is compact, and whether the call is ringing.
private struct CallLayout {
    let avatarSize: CGFloat
    let headerTop: CGFloat
    let headerWidth: CGFloat
    let decisionsWidth: CGFloat
    /// From the safe area's bottom to the decision buttons.
    let bottomInset: CGFloat
    let bottomSpacing: CGFloat
    let controlSpacing: CGFloat
    let controlSize: CGFloat
    let spacingAfterAvatar: CGFloat
    let spacingAfterDuration: CGFloat
    let nameFontSize: CGFloat

    init(width: CGFloat, compact: Bool, incoming: Bool) {
        let outerMargin: CGFloat = compact ? 20 : 32
        avatarSize = incoming ? (compact ? 116 : 132) : (compact ? 92 : 112)
        headerTop = compact ? 18 : 26
        headerWidth = min(520, max(0, width - outerMargin * 2))
        decisionsWidth = min(430, max(0, width - outerMargin * 2 - (compact ? 24 : 56)))
        bottomInset = (compact ? 18 : 26) + (incoming ? (compact ? 16 : 28) : (compact ? 8 : 18))
        bottomSpacing = compact ? 30 : 42
        controlSpacing = compact ? 20 : 34
        controlSize = compact ? 62 : 68
        spacingAfterAvatar = incoming ? 24 : 22
        spacingAfterDuration = incoming ? 22 : 20
        nameFontSize = incoming ? (compact ? 38 : 44) : 34
    }
}

private extension ActiveCallContent.Tone {
    var color: UIColor {
        switch self {
        case .green:
            .systemGreen
        case .orange:
            .systemOrange
        case .red:
            .systemRed
        }
    }
}

/// Owns a repeating timer and invalidates it when released, which happens when the call screen is. The screen's
/// deinit cannot reach its main-actor properties, so it cannot invalidate the timer itself.
private final class RepeatingTimer {
    private let timer: Timer

    init(interval: TimeInterval, tick: @escaping @Sendable () -> Void) {
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in tick() }
    }

    deinit {
        timer.invalidate()
    }
}

private enum Metrics {
    /// Below this height the screen uses its compact sizes even in a regular width.
    static let compactHeight: CGFloat = 700
    static let headerSpacing: CGFloat = 10
    static let recordButtonSize: CGFloat = 44
    static let centerSpacing: CGFloat = 8
    static let maximumCenterWidth: CGFloat = 520
    static let centerMargin: CGFloat = 20
    static let badgeCornerRadius: CGFloat = 19
    static let badgeInsets = UIEdgeInsets(top: 11, left: 14, bottom: 11, right: 14)
    static let dotSize: CGFloat = 8
    static let dotSpacing: CGFloat = 8
    static let durationFontSize: CGFloat = 24
    static let waitingFontSize: CGFloat = 15
    static let controlSize: CGFloat = 62
    static let decisionSize: CGFloat = 76
    static let decisionSpacing: CGFloat = 100
    // Replaced by CallLayout on the first render.
    static let initialAvatarSize: CGFloat = 116
    static let initialHeaderTop: CGFloat = 18
    static let initialHeaderWidth: CGFloat = 362
    static let initialDecisionsWidth: CGFloat = 338
    static let initialBottomInset: CGFloat = 34
    static let initialBottomSpacing: CGFloat = 30
    static let initialControlSpacing: CGFloat = 20
    static let initialSpacingAfterAvatar: CGFloat = 24
    static let initialSpacingAfterDuration: CGFloat = 20
}

#if DEBUG
#Preview("Call · Incoming") {
    let store = AirSIMPreviewFixtures.store(callState: "incoming")
    let controller = ActiveCallViewController(store: store.scope(state: \.activeCall, action: \.activeCall))
    controller.isPresentationPreview = true
    return controller
}

#Preview("Call · Connected") {
    let store = AirSIMPreviewFixtures.store(callState: "active")
    let controller = ActiveCallViewController(store: store.scope(state: \.activeCall, action: \.activeCall))
    controller.isPresentationPreview = true
    return controller
}
#endif
