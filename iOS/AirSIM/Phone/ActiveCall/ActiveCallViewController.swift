import ComposableArchitecture
import UIKit

@MainActor
@ViewAction(for: ActiveCallFeature.self)
final class ActiveCallViewController: ObservingViewController {
    // MARK: Store

    let store: StoreOf<ActiveCallFeature>
    var call: CallRecord? { store.call }
    /// Suppresses device proximity monitoring; Live Previews still animate and accept input.
    var isPresentationPreview = false

    // MARK: Views

    private let mainContainer = UIView()

    /// Centered top header with symmetric horizontal clearance so nothing ever enters the top-right corner
    /// where folded iPhone Duo places its vertical Dynamic Island, clock and cellular gauge.
    private let headerStack = UIStackView(axis: .vertical, spacing: Metrics.headerItemSpacing, alignment: .center)
    private let durationLabel = phoneLabel(size: 20, color: UIColor.white.withAlphaComponent(0.78))
    private let nameLabel = phoneLabel(size: 46, color: .white)
    private let numberLabel = phoneLabel(size: 16, color: UIColor.white.withAlphaComponent(0.76))

    private let centerStack = UIStackView(axis: .vertical, spacing: Metrics.centerItemSpacing, alignment: .center)
    private let heroAvatar = CallHeroAvatarView()
    private let statusBadge = UIVisualEffectView(effect: nil)
    private let statusDot = UIView()
    private let statusLabel = phoneLabel(size: 12, color: .white)
    private let audioErrorLabel = phoneLabel(color: UIColor.systemRed.withAlphaComponent(Metrics.audioErrorAlpha))

    /// Centered one-tap recording status / stop button using native prominent Liquid Glass.
    private lazy var recordingPillButton = buildRecordingPillButton()

    private let bottomArea = UIView()
    private let connectedGridContainer = UIVisualEffectView(effect: nil)
    private let connectedGrid = UIStackView(axis: .vertical, spacing: Metrics.initialRowSpacing, alignment: .center)
    private let connectedRow1 = UIStackView(
        axis: .horizontal,
        spacing: Metrics.initialColumnSpacing,
        alignment: .top,
        distribution: .fillEqually
    )
    private let connectedRow2 = UIStackView(
        axis: .horizontal,
        spacing: Metrics.initialColumnSpacing,
        alignment: .top,
        distribution: .fillEqually
    )
    private let incomingDecisions = UIStackView(
        axis: .horizontal,
        spacing: Metrics.decisionSpacing,
        alignment: .top,
        distribution: .equalSpacing
    )

    private lazy var audioControl = CallCircleControl(
        title: "Audio",
        icon: "speaker.wave.2.fill",
        size: Metrics.initialControlSize
    ) { [weak self] in
        self?.send(.speakerButtonTapped)
    }

    private lazy var muteControl = CallCircleControl(
        title: "Mute",
        icon: "mic.slash.fill",
        size: Metrics.initialControlSize
    ) { [weak self] in
        self?.send(.muteButtonTapped)
    }

    private lazy var moreControl = CallCircleControl(
        title: "More",
        icon: "ellipsis",
        size: Metrics.initialControlSize
    ) { [weak self] in
        self?.send(.moreButtonTapped)
    }

    private lazy var endControl = CallCircleControl(
        title: "End",
        icon: "phone.down.fill",
        size: Metrics.initialControlSize,
        color: .systemRed
    ) { [weak self] in
        self?.send(.endButtonTapped)
    }

    private lazy var keypadControl = CallCircleControl(
        title: "Keypad",
        icon: "circle.grid.3x3.fill",
        size: Metrics.initialControlSize
    ) { [weak self] in
        guard let self else { return }
        self.send(self.store.keypad == nil ? .keypadButtonTapped : .keypadHideTapped)
    }

    private lazy var declineControl = CallCircleControl(
        title: "Decline",
        icon: "phone.down.fill",
        size: Metrics.decisionSize,
        color: .systemRed
    ) { [weak self] in
        self?.send(.declineButtonTapped)
    }

    private lazy var acceptControl = CallCircleControl(
        title: "Accept",
        icon: "phone.fill",
        size: Metrics.decisionSize,
        color: .systemGreen
    ) { [weak self] in
        self?.send(.answerButtonTapped)
    }

    private var keypadController: DTMFKeypadViewController?
    private var keypadAnimator: UIViewPropertyAnimator?

    // MARK: Constraints & State

    private var lastPhase: ActiveCallContent.Phase?
    private var lastMoreVisible = false
    private var lastKeypadVisible = false
    private var layoutBasis: CallLayout.Basis?

    private lazy var headerTopConstraint = headerStack.topAnchor.constraint(
        equalTo: mainContainer.safeAreaLayoutGuide.topAnchor,
        constant: Metrics.initialHeaderTop
    )
    private lazy var headerMaxWidthConstraint = headerStack.widthAnchor.constraint(
        lessThanOrEqualToConstant: Metrics.initialHeaderMaxWidth
    )
    private lazy var avatarSizeConstraint = heroAvatar.widthAnchor.constraint(
        equalToConstant: Metrics.initialAvatarSize
    )
    private lazy var gridWidthConstraint = connectedRow1.widthAnchor.constraint(
        equalToConstant: Metrics.initialGridWidth
    )
    private lazy var gridRow2WidthConstraint = connectedRow2.widthAnchor.constraint(
        equalToConstant: Metrics.initialGridWidth
    )
    private lazy var incomingDecisionsWidthConstraint = incomingDecisions.widthAnchor.constraint(
        equalToConstant: Metrics.initialDecisionsWidth
    )
    private lazy var bottomInsetConstraint = bottomArea.bottomAnchor.constraint(
        equalTo: mainContainer.safeAreaLayoutGuide.bottomAnchor,
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
        overrideUserInterfaceStyle = .dark
        view.accessibilityViewIsModal = true
        buildBackdrop()
        buildMainContainer()
        buildHeader()
        buildCenter()
        buildBottomControls()
        buildMainLayout()
        startDurationTimer()
        registerForTraitChanges([UITraitHorizontalSizeClass.self, UITraitPreferredContentSizeCategory.self]) {
            (controller: Self, _) in
            controller.layoutBasis = nil
            controller.view.setNeedsLayout()
        }
    }

    /// Rotation, Split View, Stage Manager and iPhone Duo fold/unfold resize the call without a store change.
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let basis = currentLayoutBasis
        guard basis.boundsSize.width > 0, basis.boundsSize.height > 0, layoutBasis != basis else { return }
        render()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if let content = store.content { renderMoreMenu(content) }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if !isPresentationPreview {
            UIDevice.current.isProximityMonitoringEnabled = false
        }
    }

    // MARK: Rendering

    override func render() {
        guard let content = store.content else { return }
        guard let lastPhase, lastPhase != content.phase else {
            renderContent(content)
            return
        }
        UIView.transition(
            with: view,
            duration: Metrics.phaseTransitionDuration,
            options: [.transitionCrossDissolve, .allowUserInteraction]
        ) {
            UIView.performWithoutAnimation { self.renderContent(content) }
        }
    }

    private func renderContent(_ content: ActiveCallContent) {
        let basis = currentLayoutBasis
        layoutBasis = basis
        let layout = CallLayout(
            basis: basis,
            incoming: content.isIncoming,
            hasSecondaryHeaderLine: content.showsNumber,
            hasExtraStatusItems: content.showsRecordingPill || content.audioError != nil
        )
        lastPhase = content.phase

        renderLayout(layout)
        renderHeader(content, layout: layout)
        renderCenter(content, layout: layout)
        renderControls(content)
        renderMoreMenu(content)
        renderInlineKeypad(content, layout: layout)

        if !isPresentationPreview {
            UIDevice.current.isProximityMonitoringEnabled = content.monitorsProximity
        }
    }

    private var currentLayoutBasis: CallLayout.Basis {
        CallLayout.Basis(
            boundsSize: view.bounds.size,
            safeInsets: view.safeAreaInsets,
            horizontalSizeClass: traitCollection.horizontalSizeClass
        )
    }

    private func renderLayout(_ layout: CallLayout) {
        headerTopConstraint.constant = layout.headerTop
        headerMaxWidthConstraint.constant = layout.headerMaxWidth
        avatarSizeConstraint.constant = layout.avatarSize
        connectedGrid.spacing = layout.rowSpacing
        connectedRow1.spacing = layout.columnSpacing
        connectedRow2.spacing = layout.columnSpacing
        gridWidthConstraint.constant = layout.controlWidth * 2 + layout.columnSpacing
        gridRow2WidthConstraint.constant = layout.gridWidth
        incomingDecisionsWidthConstraint.constant = layout.decisionsWidth
        bottomInsetConstraint.constant = -layout.bottomInset

        for control in [audioControl, muteControl, moreControl, endControl, keypadControl] {
            control.setSize(layout.controlSize)
        }
    }

    private func renderHeader(_ content: ActiveCallContent, layout: CallLayout) {
        renderDuration(content, layout: layout)
        nameLabel.text = content.name
        nameLabel.font = UIFontMetrics(forTextStyle: .largeTitle)
            .scaledFont(for: .systemFont(ofSize: layout.nameFontSize, weight: .semibold).rounded())
        numberLabel.text = content.number
        numberLabel.isHidden = !content.showsNumber
    }

    private func renderDuration(_ content: ActiveCallContent, layout: CallLayout? = nil) {
        let fontSize = layout?.durationFontSize ?? (content.showsDuration ? 20 : 16)
        if content.isIncoming {
            durationLabel.text = content.header
            durationLabel.font = UIFontMetrics(forTextStyle: .subheadline)
                .scaledFont(for: .systemFont(ofSize: fontSize, weight: .semibold))
        } else {
            durationLabel.text = content.duration(at: Date())
            durationLabel.font = UIFontMetrics(forTextStyle: .title3)
                .scaledFont(for: .monospacedDigitSystemFont(ofSize: fontSize, weight: .semibold))
        }
    }

    private func renderCenter(_ content: ActiveCallContent, layout: CallLayout) {
        heroAvatar.update(
            contactName: content.contact?.name,
            photo: content.photo,
            size: layout.avatarSize
        )
        statusLabel.text = content.status
        statusDot.backgroundColor = content.dotTone.color
        if #unavailable(iOS 26.0) {
            statusBadge.contentView.backgroundColor = content.badgeTone.color.withAlphaComponent(0.16)
        }

        audioErrorLabel.text = content.audioError
        audioErrorLabel.isHidden = content.audioError == nil

        recordingPillButton.isHidden = !content.showsRecordingPill
        recordingPillButton.isEnabled = content.canToggleRecording
        recordingPillButton.accessibilityLabel = content.isRecording ? "Stop Recording" : content.recordingPillTitle
        updateRecordingPillConfiguration(content)
    }

    private func updateRecordingPillConfiguration(_ content: ActiveCallContent) {
        var config: UIButton.Configuration
        if #available(iOS 26.0, *) {
            config = .prominentGlass()
        } else {
            config = .filled()
        }
        config.cornerStyle = .capsule
        config.baseBackgroundColor = .systemRed
        config.baseForegroundColor = .white
        config.showsActivityIndicator = content.isRecordingBusy
        config.image = content.isRecordingBusy ? nil : UIImage(systemName: "stop.circle.fill")
        config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        config.imagePadding = 6
        config.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 14, bottom: 8, trailing: 14)

        var titleAttributes = AttributeContainer()
        titleAttributes.font = UIFontMetrics(forTextStyle: .caption1)
            .scaledFont(for: .systemFont(ofSize: 13, weight: .semibold))
        config.attributedTitle = AttributedString(content.recordingPillTitle, attributes: titleAttributes)
        recordingPillButton.configuration = config
    }

    private func renderControls(_ content: ActiveCallContent) {
        connectedGridContainer.isHidden = content.isIncoming
        incomingDecisions.isHidden = !content.isIncoming

        audioControl.update(
            title: "Audio",
            icon: content.speakerEnabled ? "speaker.wave.3.fill" : "speaker.wave.2.fill",
            isActive: content.speakerEnabled,
            accessibilityTitle: "Audio"
        )
        audioControl.controlAccessibilityValue = content.speakerEnabled ? "Speaker On" : "Receiver"
        audioControl.controlIdentifier = "callAudioControl"

        muteControl.update(
            title: "Mute",
            icon: "mic.slash.fill",
            isActive: content.isMuted,
            accessibilityTitle: content.isMuted ? "Unmute" : "Mute"
        )
        muteControl.controlIdentifier = "callMuteControl"

        moreControl.update(
            title: "More",
            icon: "ellipsis",
            isActive: false,
            accessibilityTitle: "More"
        )
        moreControl.controlIdentifier = "callMoreControl"

        endControl.controlIdentifier = "callEndControl"
        let showsKeypad = store.keypad != nil
        keypadControl.update(
            title: showsKeypad ? "Hide" : "Keypad",
            icon: showsKeypad ? "chevron.down" : "circle.grid.3x3.fill",
            isActive: false,
            accessibilityTitle: showsKeypad ? "Hide Keypad" : "Keypad"
        )
        keypadControl.controlIdentifier = "callKeypadControl"
    }

    private func renderMoreMenu(_ content: ActiveCallContent) {
        let record = UIAction(
            title: content.recordingMenuTitle,
            subtitle: content.recordingMenuSubtitle,
            image: UIImage(systemName: content.isRecording ? "stop.circle" : "record.circle"),
            identifier: UIAction.Identifier("callRecording"),
            attributes: content.canToggleRecording ? [] : [.disabled]
        ) { [weak self] _ in self?.send(.recordButtonTapped) }
        var actions: [UIMenuElement] = [record]
        if let contact = content.contact {
            actions.append(
                UIAction(
                    title: "Contact Card",
                    subtitle: contact.name,
                    image: UIImage(systemName: "person.crop.circle"),
                    identifier: UIAction.Identifier("callContactCard")
                ) { [weak self] _ in self?.presentContactCard() }
            )
        }
        let menu = UIMenu(children: actions)
        menu.preferredElementSize = .large
        moreControl.configureMenu(menu) { [weak self] visible in
            guard let self else { return }
            self.lastMoreVisible = visible
            if visible && !self.store.isShowingMoreMenu {
                self.send(.moreButtonTapped)
            } else if !visible && self.store.isShowingMoreMenu {
                self.send(.moreMenuDismissed)
            }
        }
        let shouldShow = store.isShowingMoreMenu && !content.isIncoming && store.keypad == nil
        guard view.window != nil, shouldShow != lastMoreVisible else { return }
        lastMoreVisible = shouldShow
        if shouldShow {
            moreControl.presentMenu()
        } else {
            moreControl.dismissMenu()
        }
    }

    private func renderInlineKeypad(_ content: ActiveCallContent, layout: CallLayout) {
        let keypadStore: StoreOf<KeypadFeature>? = store.scope(state: \.keypad, action: \.keypad.presented)
        let shouldShow = keypadStore != nil && !content.isIncoming
        let fallbackText = content.number ?? content.name

        if shouldShow, let keypadStore {
            if let existing = keypadController {
                existing.callerFallbackText = fallbackText
            } else {
                let controller = DTMFKeypadViewController(store: keypadStore, callerFallback: fallbackText)
                addChild(controller)
                controller.view.translatesAutoresizingMaskIntoConstraints = false
                mainContainer.addSubview(controller.view)
                NSLayoutConstraint.activate([
                    controller.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                    controller.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                    controller.view.topAnchor.constraint(equalTo: mainContainer.safeAreaLayoutGuide.topAnchor),
                    controller.view.bottomAnchor.constraint(equalTo: connectedRow2.topAnchor, constant: -12),
                ])
                controller.didMove(toParent: self)
                keypadController = controller
            }
            keypadController?.updateControlLayout(
                size: layout.controlSize,
                spacing: layout.columnSpacing + layout.controlWidth - layout.controlSize
            )
        }

        guard shouldShow != lastKeypadVisible else { return }
        // Finish the previous transition before reusing/removing its child on a rapid reversal.
        keypadAnimator?.stopAnimation(false)
        keypadAnimator?.finishAnimation(at: .end)
        keypadAnimator = nil
        lastKeypadVisible = shouldShow
        let animated = view.window != nil && UIView.areAnimationsEnabled && !UIAccessibility.isReduceMotionEnabled

        if shouldShow, let keypadView = keypadController?.view {
            view.layoutIfNeeded()
            keypadView.alpha = 0
            keypadView.transform = CGAffineTransform(scaleX: 0.94, y: 0.94).translatedBy(x: 0, y: 18)
            let changes = {
                self.setCallDetailsVisible(false)
                keypadView.alpha = 1
                keypadView.transform = .identity
            }
            let completion = {
                self.keypadAnimator = nil
                UIAccessibility.post(notification: .screenChanged, argument: keypadView)
            }
            if animated {
                let animator = UIViewPropertyAnimator(duration: 0.34, dampingRatio: 0.9, animations: changes)
                keypadAnimator = animator
                animator.addCompletion { _ in completion() }
                animator.startAnimation()
            } else {
                changes()
                completion()
            }
        } else if let departing = keypadController {
            keypadController = nil
            departing.view.isUserInteractionEnabled = false
            let changes = {
                self.setCallDetailsVisible(true)
                departing.view.alpha = 0
                departing.view.transform = CGAffineTransform(scaleX: 0.94, y: 0.94).translatedBy(x: 0, y: 18)
            }
            let completion = {
                departing.willMove(toParent: nil)
                departing.view.removeFromSuperview()
                departing.removeFromParent()
                self.keypadAnimator = nil
                UIAccessibility.post(notification: .screenChanged, argument: self.keypadControl)
            }
            if animated {
                let animator = UIViewPropertyAnimator(duration: 0.3, dampingRatio: 0.9, animations: changes)
                keypadAnimator = animator
                animator.addCompletion { _ in completion() }
                animator.startAnimation()
            } else {
                changes()
                completion()
            }
        }
    }

    /// Only the call details and auxiliary controls give way to DTMF; End stays in its original row.
    private func setCallDetailsVisible(_ visible: Bool) {
        for part in [headerStack, centerStack, connectedRow1, moreControl] {
            part.alpha = visible ? 1 : 0
            part.transform = visible ? .identity : CGAffineTransform(scaleX: 1.04, y: 1.04)
            part.isUserInteractionEnabled = visible
            part.accessibilityElementsHidden = !visible
        }
    }

    // MARK: Layout Construction

    private func buildBackdrop() {
        let backdrop = CallBackdropView()
        backdrop.isUserInteractionEnabled = false
        backdrop.accessibilityElementsHidden = true
        view.addPinnedSubview(backdrop)
    }

    private func buildMainContainer() {
        view.addPinnedSubview(mainContainer)
    }

    private func buildHeader() {
        durationLabel.textAlignment = .center
        durationLabel.numberOfLines = 1
        durationLabel.accessibilityIdentifier = "callStatusOrTimer"

        nameLabel.textAlignment = .center
        nameLabel.numberOfLines = 1
        nameLabel.adjustsFontSizeToFitWidth = true
        nameLabel.minimumScaleFactor = 0.56
        nameLabel.accessibilityIdentifier = "callCallerName"

        numberLabel.textAlignment = .center
        numberLabel.numberOfLines = 1
        numberLabel.adjustsFontSizeToFitWidth = true
        numberLabel.minimumScaleFactor = 0.72
        numberLabel.isHidden = true

        headerStack.addArrangedSubview(durationLabel)
        headerStack.addArrangedSubview(nameLabel)
        headerStack.addArrangedSubview(numberLabel)
        headerStack.setCustomSpacing(2, after: durationLabel)
        headerStack.setCustomSpacing(4, after: nameLabel)
    }

    private func buildCenter() {
        NSLayoutConstraint.activate([
            avatarSizeConstraint,
            heroAvatar.heightAnchor.constraint(equalTo: heroAvatar.widthAnchor),
        ])
        buildStatusBadge()
        audioErrorLabel.font = UIFontMetrics(forTextStyle: .caption1).scaledFont(for: .systemFont(ofSize: 12))
        audioErrorLabel.textAlignment = .center
        audioErrorLabel.numberOfLines = 2
        audioErrorLabel.isHidden = true

        centerStack.addArrangedSubview(heroAvatar)
        centerStack.addArrangedSubview(statusBadge)
        centerStack.addArrangedSubview(recordingPillButton)
        centerStack.addArrangedSubview(audioErrorLabel)
        centerStack.setCustomSpacing(14, after: heroAvatar)
        centerStack.setCustomSpacing(8, after: statusBadge)
        centerStack.setCustomSpacing(8, after: recordingPillButton)
    }

    private func buildStatusBadge() {
        if #available(iOS 26.0, *) {
            let glass = UIGlassEffect(style: .regular)
            glass.tintColor = UIColor.white.withAlphaComponent(0.06)
            statusBadge.effect = glass
            statusBadge.cornerConfiguration = .capsule()
        } else {
            statusBadge.effect = UIBlurEffect(style: .systemUltraThinMaterialDark)
            statusBadge.layer.cornerRadius = Metrics.badgeCornerRadius
            statusBadge.clipsToBounds = true
            statusBadge.layer.borderWidth = 0.6
            statusBadge.layer.borderColor = UIColor.white.withAlphaComponent(0.22).cgColor
        }

        statusDot.backgroundColor = .systemOrange
        statusDot.layer.cornerRadius = Metrics.dotSize / 2
        NSLayoutConstraint.activate([
            statusDot.widthAnchor.constraint(equalToConstant: Metrics.dotSize),
            statusDot.heightAnchor.constraint(equalToConstant: Metrics.dotSize),
        ])
        statusLabel.font = UIFontMetrics(forTextStyle: .caption1)
            .scaledFont(for: .systemFont(ofSize: 12, weight: .medium))
        statusLabel.numberOfLines = 1
        statusLabel.adjustsFontSizeToFitWidth = true
        statusLabel.minimumScaleFactor = 0.78

        let row = UIStackView(
            [statusDot, statusLabel],
            axis: .horizontal,
            spacing: Metrics.dotSpacing,
            alignment: .center
        )
        statusBadge.contentView.addPinnedSubview(row, insets: Metrics.badgeInsets)
    }

    private func buildRecordingPillButton() -> UIButton {
        let button = UIButton(type: .system)
        button.isHidden = true
        button.accessibilityIdentifier = "callRecordingPill"
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 34).isActive = true
        button.addAction(UIAction { [weak self] _ in self?.send(.recordButtonTapped) }, for: .touchUpInside)
        return button
    }

    private func buildBottomControls() {
        for control in [audioControl, muteControl] {
            connectedRow1.addArrangedSubview(control)
        }
        for control in [moreControl, endControl, keypadControl] {
            connectedRow2.addArrangedSubview(control)
        }
        connectedGrid.addArrangedSubview(connectedRow1)
        connectedGrid.addArrangedSubview(connectedRow2)

        if #available(iOS 26.0, *) {
            let containerEffect = UIGlassContainerEffect()
            containerEffect.spacing = 12
            connectedGridContainer.effect = containerEffect
        }
        connectedGridContainer.contentView.addPinnedSubview(connectedGrid)

        incomingDecisions.addArrangedSubview(declineControl)
        incomingDecisions.addArrangedSubview(acceptControl)

        for child in [connectedGridContainer, incomingDecisions] {
            child.translatesAutoresizingMaskIntoConstraints = false
            bottomArea.addSubview(child)
            NSLayoutConstraint.activate([
                child.topAnchor.constraint(equalTo: bottomArea.topAnchor),
                child.bottomAnchor.constraint(equalTo: bottomArea.bottomAnchor),
                child.centerXAnchor.constraint(equalTo: bottomArea.centerXAnchor),
                child.leadingAnchor.constraint(greaterThanOrEqualTo: bottomArea.leadingAnchor),
                child.trailingAnchor.constraint(lessThanOrEqualTo: bottomArea.trailingAnchor),
            ])
        }
        NSLayoutConstraint.activate([
            gridWidthConstraint,
            gridRow2WidthConstraint,
            incomingDecisionsWidthConstraint,
        ])
    }

    private func buildMainLayout() {
        let safeArea = mainContainer.safeAreaLayoutGuide
        for part in [headerStack, centerStack, bottomArea] {
            part.translatesAutoresizingMaskIntoConstraints = false
            mainContainer.addSubview(part)
        }

        // Centered horizontally across the full screen (matching native iOS Phone on folded iPhone Duo), while
        // headerMaxWidthConstraint clamps the top header symmetrically clear of the right-edge Dynamic Island + clock.
        NSLayoutConstraint.activate([
            headerTopConstraint,
            headerMaxWidthConstraint,
            headerStack.centerXAnchor.constraint(equalTo: mainContainer.centerXAnchor),
            headerStack.leadingAnchor.constraint(
                greaterThanOrEqualTo: safeArea.leadingAnchor,
                constant: 16
            ),
            headerStack.trailingAnchor.constraint(
                lessThanOrEqualTo: safeArea.trailingAnchor,
                constant: -16
            ),
        ])

        NSLayoutConstraint.activate([
            centerStack.centerXAnchor.constraint(equalTo: mainContainer.centerXAnchor),
            centerStack.widthAnchor.constraint(lessThanOrEqualToConstant: Metrics.maximumCenterWidth),
            centerStack.leadingAnchor.constraint(
                greaterThanOrEqualTo: mainContainer.leadingAnchor,
                constant: Metrics.centerMargin
            ),
            centerStack.trailingAnchor.constraint(
                lessThanOrEqualTo: mainContainer.trailingAnchor,
                constant: -Metrics.centerMargin
            ),
        ])

        NSLayoutConstraint.activate([
            bottomArea.centerXAnchor.constraint(equalTo: mainContainer.centerXAnchor),
            bottomArea.leadingAnchor.constraint(greaterThanOrEqualTo: mainContainer.leadingAnchor, constant: 16),
            bottomArea.trailingAnchor.constraint(lessThanOrEqualTo: mainContainer.trailingAnchor, constant: -16),
            bottomInsetConstraint,
        ])

        let aboveGuide = UILayoutGuide()
        let belowGuide = UILayoutGuide()
        mainContainer.addLayoutGuide(aboveGuide)
        mainContainer.addLayoutGuide(belowGuide)
        NSLayoutConstraint.activate([
            aboveGuide.topAnchor.constraint(equalTo: headerStack.bottomAnchor),
            aboveGuide.bottomAnchor.constraint(equalTo: centerStack.topAnchor),
            belowGuide.topAnchor.constraint(equalTo: centerStack.bottomAnchor),
            belowGuide.bottomAnchor.constraint(equalTo: bottomArea.topAnchor),
            aboveGuide.heightAnchor.constraint(equalTo: belowGuide.heightAnchor),
            aboveGuide.heightAnchor.constraint(greaterThanOrEqualToConstant: 8),
            belowGuide.heightAnchor.constraint(greaterThanOrEqualToConstant: 8),
        ])
    }

    // MARK: Actions & Navigation

    private func presentContactCard() {
        guard let contact = store.content?.contact else { return }
        send(.moreMenuDismissed)
        showPhoneSheet(CallContactCardViewController(contact: contact))
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
}

private struct CallLayout {
    struct Basis: Equatable {
        let boundsSize: CGSize
        let safeInsets: UIEdgeInsets
        let horizontalSizeClass: UIUserInterfaceSizeClass

        var safeHeight: CGFloat {
            max(0, boundsSize.height - safeInsets.top - safeInsets.bottom)
        }

        var isCompactWidth: Bool { horizontalSizeClass == .compact || boundsSize.width < 520 }
        var isShortHeight: Bool { safeHeight < Metrics.shortHeightThreshold }
    }

    let headerTop: CGFloat
    let headerMaxWidth: CGFloat
    let durationFontSize: CGFloat
    let nameFontSize: CGFloat
    let avatarSize: CGFloat
    let controlSize: CGFloat
    let controlWidth: CGFloat
    let columnSpacing: CGFloat
    let rowSpacing: CGFloat
    let gridWidth: CGFloat
    let decisionsWidth: CGFloat
    let bottomInset: CGFloat

    init(
        basis: Basis,
        incoming: Bool,
        hasSecondaryHeaderLine: Bool,
        hasExtraStatusItems: Bool
    ) {
        let width = max(320, basis.boundsSize.width)
        let height = max(460, basis.safeHeight > 0 ? basis.safeHeight : basis.boundsSize.height)
        let short = basis.isShortHeight
        let compact = basis.isCompactWidth

        headerTop = short ? 10 : (height < 670 ? 22 : 18)
        let sideObstruction = max(basis.safeInsets.left, basis.safeInsets.right)
        let symmetricClearance = max(Metrics.headerHorizontalClearance, sideObstruction + 16)
        headerMaxWidth = max(150, min(460, width - symmetricClearance * 2))

        durationFontSize = incoming ? 15 : (short ? 18 : 21)
        nameFontSize = incoming ? (short ? 34 : 44) : (short ? 38 : 48)

        let desiredControlSize: CGFloat = short ? 62 : (compact ? 76 : 80)
        let usableGridWidth = min(380, max(236, width - 48))
        let desiredColumnSpacing: CGFloat = short ? 24 : (compact ? 32 : 38)
        let maxControlByWidth = (usableGridWidth - desiredColumnSpacing * 2) / 3 - 6
        controlSize = min(desiredControlSize, max(56, floor(maxControlByWidth)))
        controlWidth = CallCircleControl.captionedWidth(for: controlSize)
        columnSpacing = min(desiredColumnSpacing, max(16, floor((usableGridWidth - controlWidth * 3) / 2)))
        rowSpacing = short ? 12 : 18
        gridWidth = controlWidth * 3 + columnSpacing * 2

        let outerMargin: CGFloat = compact ? 24 : 40
        decisionsWidth = min(340, max(220, width - outerMargin * 2 - 16))
        bottomInset = short ? 10 : 20

        let headerEstimatedHeight: CGFloat =
            durationFontSize + nameFontSize + (hasSecondaryHeaderLine ? 24 : 0) + 16
        let bottomEstimatedHeight: CGFloat =
            incoming ? 108 : (controlSize * 2 + 48 + rowSpacing)
        let statusEstimatedHeight: CGFloat = 52 + (hasExtraStatusItems ? 46 : 0)
        let availableForAvatar =
            height - headerTop - headerEstimatedHeight - bottomEstimatedHeight - statusEstimatedHeight - 36

        let maxAvatar: CGFloat = incoming ? (compact ? 188 : 220) : (compact ? 224 : 244)
        let minAvatar: CGFloat = short ? 92 : 132
        avatarSize = min(maxAvatar, max(minAvatar, floor(availableForAvatar)))

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
    static let shortHeightThreshold: CGFloat = 580
    static let headerHorizontalClearance: CGFloat = 68
    static let headerItemSpacing: CGFloat = 4
    static let centerItemSpacing: CGFloat = 10
    static let maximumCenterWidth: CGFloat = 480
    static let centerMargin: CGFloat = 24
    static let badgeCornerRadius: CGFloat = 18
    static let badgeInsets = UIEdgeInsets(top: 8, left: 13, bottom: 8, right: 13)
    static let dotSize: CGFloat = 8
    static let dotSpacing: CGFloat = 7
    static let decisionSize: CGFloat = 74
    static let decisionSpacing: CGFloat = 96
    static let initialHeaderTop: CGFloat = 14
    static let initialHeaderMaxWidth: CGFloat = 260
    static let initialAvatarSize: CGFloat = 168
    static let initialControlSize: CGFloat = 72
    static let initialColumnSpacing: CGFloat = 28
    static let initialRowSpacing: CGFloat = 16
    static let initialGridWidth: CGFloat = 272
    static let initialDecisionsWidth: CGFloat = 280
    static let initialBottomInset: CGFloat = 18
    static let audioErrorAlpha: CGFloat = 0.94
    static let phaseTransitionDuration: TimeInterval = 0.2
}

#if DEBUG
#Preview("Call · Connected (114 Silhouette)") {
    let store = AirSIMPreviewFixtures.store(callState: "active", callNumber: "114")
    return AirSIMPreviewFixtures.activeCall(store)
}

#Preview("Call · More Menu Open") {
    let store = AirSIMPreviewFixtures.store(callState: "active")
    store.send(.activeCall(.view(.moreButtonTapped)))
    return AirSIMPreviewFixtures.activeCall(store)
}

#Preview("Call · Recording Active") {
    let store = AirSIMPreviewFixtures.store(callState: "active", isRecording: true)
    return AirSIMPreviewFixtures.activeCall(store)
}

#Preview("Call · In-Call Keypad") {
    let store = AirSIMPreviewFixtures.store(callState: "active", callNumber: "114")
    store.send(.activeCall(.view(.keypadButtonTapped)))
    return AirSIMPreviewFixtures.activeCall(store)
}

#Preview("Call · In-Call Keypad (Digits Entered)") {
    let store = AirSIMPreviewFixtures.store(callState: "active", callNumber: "114")
    store.send(.activeCall(.view(.keypadButtonTapped)))
    for digit in ["1", "1", "1", "1", "2", "3", "4", "5", "6"] {
        store.send(.activeCall(.keypad(.presented(.view(.digitTapped(digit))))))
    }
    return AirSIMPreviewFixtures.activeCall(store)
}

#Preview("Call · Folded Duo Proportion (352×512)") {
    let store = AirSIMPreviewFixtures.store(callState: "active", callNumber: "114")
    store.send(.activeCall(.view(.moreButtonTapped)))
    return AirSIMPreviewFixtures.canvas(AirSIMPreviewFixtures.activeCall(store), width: 352, height: 512, dark: true)
}

#Preview("Call · Incoming") {
    let store = AirSIMPreviewFixtures.store(callState: "incoming")
    return AirSIMPreviewFixtures.activeCall(store)
}
#endif
