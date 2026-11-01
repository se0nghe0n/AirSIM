import UIKit

@MainActor
final class RecentCallDetailsViewController: UIViewController {
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

#if DEBUG
#Preview("Recent Call · Details Card") {
    RecentCallDetailsViewController(call: AirSIMPreviewFixtures.history[0], model: AirSIMPreviewFixtures.presentation(tab: .recents), onCall: {}, onMessage: {}, onDelete: {})
}
#endif
