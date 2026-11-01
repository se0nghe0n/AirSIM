import ComposableArchitecture
import UIKit

/// The full-screen first-run screen: what pairing needs, the connection mode, and pairing now or later in Settings.
@MainActor
@ViewAction(for: SettingsFeature.self)
final class AirSIMFirstConnectionViewController: ObservingViewController {
    // MARK: Store

    let store: StoreOf<SettingsFeature>

    // MARK: Views

    private let mode = UISegmentedControl(items: AirSIMConnectionMode.allCases.map { String(localized: $0.title) })
    private let detail = phoneLabel(size: 13, color: .secondaryLabel)

    // MARK: Lifecycle

    init(store: StoreOf<SettingsFeature>) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "AirSIM"
        view.backgroundColor = .systemBackground
        navigationItem.largeTitleDisplayMode = .never
        mode.addAction(UIAction { [weak self] _ in self?.modeSelected() }, for: .valueChanged)
        buildLayout(content: contentStack(), actions: actionStack())
    }

    // MARK: Rendering

    override func render() {
        mode.selectedSegmentIndex = AirSIMConnectionMode.allCases.firstIndex(of: store.mode) ?? 0
        detail.text = store.modeDetail
    }

    // MARK: Layout

    private func contentStack() -> UIStackView {
        UIStackView(
            [iconRow(), introStack(), stepsCard(), mode, detail],
            axis: .vertical,
            spacing: Metrics.sectionSpacing
        )
    }

    private func iconRow() -> UIStackView {
        let icon = UIImageView(image: UIImage(systemName: "iphone.radiowaves.left.and.right"))
        icon.tintColor = .systemBlue
        icon.contentMode = .center
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 42, weight: .medium)
        icon.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.1)
        icon.layer.cornerRadius = Metrics.iconCornerRadius
        NSLayoutConstraint.activate([
            icon.heightAnchor.constraint(equalToConstant: Metrics.iconSize),
            icon.widthAnchor.constraint(equalToConstant: Metrics.iconSize),
        ])
        return UIStackView(arrangedSubviews: [icon, UIView()])
    }

    private func introStack() -> UIStackView {
        let heading = phoneLabel("Connect Android Phone", size: 34)
        heading.font = UIFontMetrics(forTextStyle: .largeTitle).scaledFont(for: .systemFont(ofSize: 34, weight: .bold))
        let summary = phoneLabel(
            "AirSIM connects to your Android phone over VoWLAN or a cloud Relay.",
            color: .secondaryLabel
        )
        return UIStackView([heading, summary], axis: .vertical, spacing: 8)
    }

    private func stepsCard() -> UIView {
        let steps = [
            "Start AirSIM and the audio bridge on Android",
            "Set up the same Wi-Fi or Android hotspot, or configure cloud Relay",
            "Verify the security code and finish pairing",
        ]
        let list = UIStackView(
            steps.enumerated().map { index, text in stepRow(number: index + 1, text: text) },
            axis: .vertical,
            spacing: 18
        )
        let card = UIView()
        card.backgroundColor = .secondarySystemBackground
        card.layer.cornerRadius = Metrics.cardCornerRadius
        card.addPinnedSubview(list, insets: Metrics.cardPadding)
        return card
    }

    private func stepRow(number: Int, text: String) -> UIStackView {
        let image = UIImageView(image: UIImage(systemName: "\(number).circle.fill"))
        image.tintColor = .label
        image.contentMode = .top
        image.widthAnchor.constraint(equalToConstant: 18).isActive = true
        let label = phoneLabel(text)
        label.font = UIFontMetrics(forTextStyle: .body).scaledFont(for: .systemFont(ofSize: 17, weight: .medium))
        return UIStackView([image, label], axis: .horizontal, spacing: 10, alignment: .top)
    }

    private func actionStack() -> UIStackView {
        let start = phoneButton("Start Pairing", image: "lock.shield") { [weak self] in self?.showPairing() }
        start.configuration = .filled()
        start.configuration?.title = "Start Pairing"
        start.configuration?.image = UIImage(systemName: "lock.shield")
        start.configuration?.imagePadding = 8
        start.configuration?.cornerStyle = .capsule
        start.configuration?.contentInsets = Metrics.startPairingInsets
        let later = phoneButton("Pair Later in Settings") { [weak self] in self?.send(.pairLaterTapped) }
        later.configuration = .plain()
        later.setTitle("Pair Later in Settings", for: .normal)
        return UIStackView([start, later], axis: .vertical, spacing: 10, alignment: .center)
    }

    /// The content scrolls above a blurred bar that holds the pairing buttons.
    private func buildLayout(content: UIStackView, actions: UIStackView) {
        let scroll = UIScrollView()
        let bottomBar = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
        actions.translatesAutoresizingMaskIntoConstraints = false
        bottomBar.contentView.addSubview(actions)
        for subview in [scroll, bottomBar] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }
        content.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(content)
        let preferredWidth = content.widthAnchor.constraint(
            equalTo: scroll.frameLayoutGuide.widthAnchor,
            constant: -2 * Metrics.contentMargin
        )
        preferredWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomBar.topAnchor),
        ])
        NSLayoutConstraint.activate([
            content.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            preferredWidth,
            content.widthAnchor.constraint(lessThanOrEqualToConstant: Metrics.maximumContentWidth),
            content.leadingAnchor.constraint(
                greaterThanOrEqualTo: scroll.contentLayoutGuide.leadingAnchor,
                constant: Metrics.contentMargin
            ),
            content.trailingAnchor.constraint(
                lessThanOrEqualTo: scroll.contentLayoutGuide.trailingAnchor,
                constant: -Metrics.contentMargin
            ),
            content.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: Metrics.contentMargin),
            content.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -12),
        ])
        NSLayoutConstraint.activate([
            bottomBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bottomBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottomBar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        NSLayoutConstraint.activate([
            actions.topAnchor.constraint(equalTo: bottomBar.topAnchor, constant: Metrics.actionsPadding),
            actions.centerXAnchor.constraint(equalTo: bottomBar.centerXAnchor),
            actions.bottomAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.bottomAnchor,
                constant: -Metrics.actionsPadding
            ),
        ])
    }

    // MARK: Navigation

    /// Closing this pairing sheet with VoWLAN online finishes onboarding.
    private func showPairing() {
        send(.startPairingTapped)
        showPhoneSheet(SamsungPairingViewController(store: store.scope(state: \.pairing, action: \.pairing)))
    }

    // MARK: Actions

    private func modeSelected() {
        send(.modeChanged(AirSIMConnectionMode.allCases[mode.selectedSegmentIndex]))
    }
}

private enum Metrics {
    static let sectionSpacing: CGFloat = 24
    static let contentMargin: CGFloat = 24
    static let maximumContentWidth: CGFloat = 600
    static let iconSize: CGFloat = 76
    static let iconCornerRadius: CGFloat = 22
    static let cardCornerRadius: CGFloat = 24
    static let cardPadding = UIEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
    static let startPairingInsets = NSDirectionalEdgeInsets(top: 16, leading: 20, bottom: 16, trailing: 20)
    static let actionsPadding: CGFloat = 16
}

#if DEBUG
#Preview("First Connection · Setup") {
    let store = AirSIMPreviewFixtures.presentation().store
    return AirSIMPreviewFixtures.navigation(
        AirSIMFirstConnectionViewController(store: store.scope(state: \.settings, action: \.settings))
    )
}
#endif
