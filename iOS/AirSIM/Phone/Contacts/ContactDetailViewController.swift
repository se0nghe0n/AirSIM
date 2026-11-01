import UIKit

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

#if DEBUG
#Preview("Contact · Details") {
    AirSIMPreviewFixtures.navigation(ContactDetailViewController(contact: AirSIMPreviewFixtures.contact, onCall: { _ in }, onMessage: { _ in }))
}
#endif
