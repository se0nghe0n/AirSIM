import ComposableArchitecture
import UIKit

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

@MainActor
final class ActiveCallViewController: ObservingViewController {
    let model: AirSIMPresentation
    @UIBindable private var store: StoreOf<AirSIMFeature>
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
    init(model: AirSIMPresentation, call: CallRecord) { self.model = model; store = model.store; self.call = call; super.init(nibName: nil, bundle: nil) }
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
        let keypad = CallCircleControl(title: "Keypad", icon: "circle.grid.3x3.fill", size: 62) { [weak self] in self?.store.send(.keypadButtonTapped) }
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
        present(item: $store.scope(\.$keypad, action: \.keypad)) { phoneSheet(DTMFKeypadViewController(store: $0)) }
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

#if DEBUG
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
#endif
