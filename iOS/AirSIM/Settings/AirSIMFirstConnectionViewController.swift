import UIKit

@MainActor
final class AirSIMFirstConnectionViewController: ObservingViewController {
    let model: AirSIMPresentation
    var onComplete: (() -> Void)?
    private let mode = UISegmentedControl(items: AirSIMConnectionMode.allCases.map { String(localized: $0.title) })
    private let detail = phoneLabel(size: 13, color: .secondaryLabel)
    init(model: AirSIMPresentation) { self.model = model; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() {
        super.viewDidLoad(); title = "AirSIM"; view.backgroundColor = .systemBackground; navigationItem.largeTitleDisplayMode = .never
        let scroll = UIScrollView(); let stack = UIStackView(); stack.axis = .vertical; stack.spacing = 24; stack.alignment = .fill
        let icon = UIImageView(image: UIImage(systemName: "iphone.radiowaves.left.and.right")); icon.tintColor = .systemBlue; icon.contentMode = .center; icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 42, weight: .medium); icon.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.1); icon.layer.cornerRadius = 22; icon.heightAnchor.constraint(equalToConstant: 76).isActive = true; icon.widthAnchor.constraint(equalToConstant: 76).isActive = true
        let iconRow = UIStackView(arrangedSubviews: [icon, UIView()]); stack.addArrangedSubview(iconRow)
        let heading = phoneLabel("Connect Android Phone", size: 34); heading.font = UIFontMetrics(forTextStyle: .largeTitle).scaledFont(for: .systemFont(ofSize: 34, weight: .bold))
        let intro = UIStackView(arrangedSubviews: [heading, phoneLabel("AirSIM connects to your Android phone over VoWLAN or a cloud Relay.", color: .secondaryLabel)]); intro.axis = .vertical; intro.spacing = 8; stack.addArrangedSubview(intro)
        let steps = UIStackView(); steps.axis = .vertical; steps.spacing = 18
        for (index, text) in ["Start AirSIM and the audio bridge on Android", "Set up the same Wi-Fi or Android hotspot, or configure cloud Relay", "Verify the security code and finish pairing"].enumerated() {
            let image = UIImageView(image: UIImage(systemName: "\(index + 1).circle.fill")); image.tintColor = .label; image.contentMode = .top; image.widthAnchor.constraint(equalToConstant: 18).isActive = true
            let label = phoneLabel(text); label.font = UIFontMetrics(forTextStyle: .body).scaledFont(for: .systemFont(ofSize: 17, weight: .medium))
            let row = UIStackView(arrangedSubviews: [image, label]); row.axis = .horizontal; row.alignment = .top; row.spacing = 10; steps.addArrangedSubview(row)
        }
        let card = UIView(); card.backgroundColor = .secondarySystemBackground; card.layer.cornerRadius = 24; steps.translatesAutoresizingMaskIntoConstraints = false; card.addSubview(steps)
        NSLayoutConstraint.activate([steps.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 20), steps.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -20), steps.topAnchor.constraint(equalTo: card.topAnchor, constant: 20), steps.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -20)])
        stack.addArrangedSubview(card); stack.addArrangedSubview(mode); stack.addArrangedSubview(detail)
        mode.addAction(UIAction { [weak self] _ in guard let self else { return }; self.model.store.send(.settings(.modeChanged(AirSIMConnectionMode.allCases[self.mode.selectedSegmentIndex]))) }, for: .valueChanged)
        let start = phoneButton("Start Pairing", image: "lock.shield") { [weak self] in self?.pair() }; start.configuration = .filled(); start.configuration?.title = "Start Pairing"; start.configuration?.image = UIImage(systemName: "lock.shield"); start.configuration?.imagePadding = 8; start.configuration?.cornerStyle = .capsule; start.configuration?.contentInsets = NSDirectionalEdgeInsets(top: 16, leading: 20, bottom: 16, trailing: 20)
        let later = phoneButton("Pair Later in Settings") { [weak self] in self?.complete() }; later.configuration = .plain(); later.setTitle("Pair Later in Settings", for: .normal)
        let actions = UIStackView(arrangedSubviews: [start, later]); actions.axis = .vertical; actions.spacing = 10; actions.alignment = .center
        let bottom = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial)); actions.translatesAutoresizingMaskIntoConstraints = false; bottom.contentView.addSubview(actions)
        [scroll, bottom].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; view.addSubview($0) }; stack.translatesAutoresizingMaskIntoConstraints = false; scroll.addSubview(stack)
        let width = stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -48); width.priority = .defaultHigh
        NSLayoutConstraint.activate([scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor), scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor), scroll.bottomAnchor.constraint(equalTo: bottom.topAnchor), stack.centerXAnchor.constraint(equalTo: scroll.centerXAnchor), width, stack.widthAnchor.constraint(lessThanOrEqualToConstant: 600), stack.leadingAnchor.constraint(greaterThanOrEqualTo: scroll.contentLayoutGuide.leadingAnchor, constant: 24), stack.trailingAnchor.constraint(lessThanOrEqualTo: scroll.contentLayoutGuide.trailingAnchor, constant: -24), stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 24), stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -12), bottom.leadingAnchor.constraint(equalTo: view.leadingAnchor), bottom.trailingAnchor.constraint(equalTo: view.trailingAnchor), bottom.bottomAnchor.constraint(equalTo: view.bottomAnchor), actions.topAnchor.constraint(equalTo: bottom.topAnchor, constant: 16), actions.centerXAnchor.constraint(equalTo: bottom.centerXAnchor), actions.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16)])
    }
    override func render() { mode.selectedSegmentIndex = AirSIMConnectionMode.allCases.firstIndex(of: model.store.settings.mode) ?? 0; detail.text = String(localized: model.store.settings.mode.detail) }
    private func pair() {
        let controller = SamsungPairingViewController(model: model)
        controller.onDismiss = { [weak self] in guard let self else { return }; if self.model.vowlan.availability.isOnlineForDisplay { self.complete() } }
        showPhoneSheet(controller)
    }
    private func complete() { model.store.send(.completeOnboarding); onComplete?() }
}

#if DEBUG
#Preview("First Connection · Setup") {
    AirSIMPreviewFixtures.navigation(AirSIMFirstConnectionViewController(model: AirSIMPreviewFixtures.presentation()))
}
#endif
