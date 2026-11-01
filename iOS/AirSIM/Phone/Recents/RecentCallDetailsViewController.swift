import ComposableArchitecture
import UIKit

@MainActor
@ViewAction(for: RecentsFeature.self)
final class RecentCallDetailsViewController: UIViewController {
    // MARK: Store

    let store: StoreOf<RecentsFeature>
    private let row: RecentCallRow

    // MARK: Lifecycle

    init(row: RecentCallRow, store: StoreOf<RecentsFeature>) {
        self.row = row
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.black.withAlphaComponent(0.18)
        buildDismissingBackdrop()
        buildCard()
    }

    // MARK: Layout

    private func buildDismissingBackdrop() {
        let backdrop = UIButton(frame: view.bounds)
        backdrop.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        backdrop.addTarget(self, action: #selector(close), for: .touchUpInside)
        view.addSubview(backdrop)
    }

    private func buildCard() {
        let card = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
        card.layer.cornerRadius = 28
        card.clipsToBounds = true
        card.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(card)

        let stack = UIStackView(header(), axis: .vertical, spacing: 8, alignment: .center)
        for button in actionButtons() {
            stack.addArrangedSubview(button)
            button.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        stack.addArrangedSubview(cancelButton())
        card.contentView.addPinnedSubview(stack, insets: UIEdgeInsets(top: 22, left: 22, bottom: 22, right: 22))

        let preferredWidth = card.widthAnchor.constraint(equalToConstant: 340)
        preferredWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            card.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            preferredWidth,
            card.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 28),
            card.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -28),
        ])
    }

    private func header() -> [UIView] {
        let avatar = UIImageView(image: phoneAvatar(name: row.name, photo: row.photo, size: 58))
        NSLayoutConstraint.activate([
            avatar.widthAnchor.constraint(equalToConstant: 58),
            avatar.heightAnchor.constraint(equalToConstant: 58),
        ])
        let name = phoneLabel(row.name, size: 20)
        name.font = .systemFont(ofSize: 20, weight: .semibold)
        let number = phoneLabel(row.number ?? "", size: 17, color: .secondaryLabel)
        let date = phoneLabel(row.time, size: 12, color: .secondaryLabel)
        for label in [name, number, date] {
            label.textAlignment = .center
        }
        return [avatar, name, number, date]
    }

    private func actionButtons() -> [UIButton] {
        let callBack = actionButton("Call Back", image: "phone.fill", color: .systemGreen, then: .callTapped(row))
        callBack.configuration?.baseBackgroundColor = .systemGreen
        callBack.configuration?.baseForegroundColor = .white
        callBack.configuration?.background.backgroundColor = .systemGreen
        return [
            callBack,
            actionButton("Send Message", image: "message.fill", color: .systemBlue, then: .messageTapped(row)),
            actionButton("Delete Call Record", image: "trash", color: .systemRed, then: .deleteTapped(row.id)),
        ]
    }

    private func actionButton(
        _ title: String,
        image: String,
        color: UIColor,
        then action: RecentsFeature.Action.View
    ) -> UIButton {
        let button = phoneButton(title, image: image, color: color) { [weak self] in
            guard let self else { return }
            self.dismiss(animated: true) { self.send(action) }
        }
        button.configuration?.cornerStyle = .medium
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 48).isActive = true
        return button
    }

    private func cancelButton() -> UIButton {
        let cancel = phoneButton("Cancel", color: .secondaryLabel) { [weak self] in self?.close() }
        cancel.configuration = .plain()
        cancel.setTitle("Cancel", for: .normal)
        return cancel
    }

    // MARK: Actions

    @objc private func close() {
        dismiss(animated: true)
    }
}

#if DEBUG
#Preview("Recent Call · Details Card") {
    let store = AirSIMPreviewFixtures.store(tab: .recents).scope(state: \.recents, action: \.recents)
    return RecentCallDetailsViewController(row: store.rows[0], store: store)
}
#endif
