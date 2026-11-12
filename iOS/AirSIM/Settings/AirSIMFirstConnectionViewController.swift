import ComposableArchitecture
import UIKit

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

    /// Both actions span the bottom bar's column, as the SwiftUI full-width buttons did.
    private func actionStack() -> UIStackView {
        let start = phoneButton("Start Pairing", image: "lock.shield") { [weak self] in self?.showPairing() }
        var prominent = UIButton.Configuration.filled()
        prominent.title = "Start Pairing"
        prominent.image = UIImage(systemName: "lock.shield")
        prominent.imagePadding = 8
        prominent.buttonSize = .large
        prominent.cornerStyle = .capsule
        start.configuration = prominent
        let later = phoneButton("Pair Later in Settings") { [weak self] in self?.send(.pairLaterTapped) }
        var plain = UIButton.Configuration.plain()
        plain.title = "Pair Later in Settings"
        later.configuration = plain
        return UIStackView([start, later], axis: .vertical, spacing: Metrics.actionSpacing)
    }

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
        layoutActions(actions, in: bottomBar)
    }

    /// Up to 600pt wide with 24pt side and 16pt vertical padding, centered in the safe area.
    private func layoutActions(_ actions: UIStackView, in bottomBar: UIView) {
        let safeArea = view.safeAreaLayoutGuide
        let preferredWidth = actions.widthAnchor.constraint(
            equalTo: safeArea.widthAnchor,
            constant: -2 * Metrics.actionsHorizontalPadding
        )
        preferredWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            actions.topAnchor.constraint(equalTo: bottomBar.topAnchor, constant: Metrics.actionsVerticalPadding),
            actions.bottomAnchor.constraint(equalTo: safeArea.bottomAnchor, constant: -Metrics.actionsVerticalPadding),
            actions.centerXAnchor.constraint(equalTo: safeArea.centerXAnchor),
            preferredWidth,
            actions.widthAnchor.constraint(lessThanOrEqualToConstant: Metrics.maximumContentWidth),
        ])
    }

    // MARK: Navigation

    /// Opens at full height without a grabber, like the SwiftUI default sheet; it keeps the app sheet's Done button.
    private func showPairing() {
        send(.startPairingTapped)
        let pairing = phoneSheet(SamsungPairingViewController(store: store.scope(state: \.pairing, action: \.pairing)))
        if let sheet = pairing.sheetPresentationController {
            sheet.detents = [.large()]
            sheet.prefersGrabberVisible = false
        }
        present(pairing, animated: true)
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
    static let actionSpacing: CGFloat = 16
    static let actionsHorizontalPadding: CGFloat = 24
    static let actionsVerticalPadding: CGFloat = 16
}

#if DEBUG
#Preview("First Connection · Setup") {
    let store = AirSIMPreviewFixtures.store()
    return AirSIMPreviewFixtures.navigation(
        AirSIMFirstConnectionViewController(store: store.scope(state: \.settings, action: \.settings))
    )
}
#endif
