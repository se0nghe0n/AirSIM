import ComposableArchitecture
import UIKit

/// A contact's numbers, each with Send Message and Dial. It owns no state: it shows the row it was opened
/// with and sends Contacts actions.
@MainActor
@ViewAction(for: ContactsFeature.self)
final class ContactDetailViewController: PhoneTableController {
    // MARK: Store

    let store: StoreOf<ContactsFeature>
    private let row: ContactRow

    // MARK: Lifecycle

    init(row: ContactRow, store: StoreOf<ContactsFeature>) {
        self.row = row
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = row.name
        navigationItem.largeTitleDisplayMode = .never
    }

    // MARK: Rendering

    override func render() {
        setSections([
            PhoneSection(rows: [headerRow()]),
            PhoneSection(rows: row.phones.map(phoneRow)),
        ])
    }

    // MARK: Rows

    private func headerRow() -> PhoneRow {
        let avatar = UIImageView(image: phoneAvatar(name: row.name, photo: row.photo, size: 82))
        NSLayoutConstraint.activate([
            avatar.widthAnchor.constraint(equalToConstant: 82),
            avatar.heightAnchor.constraint(equalToConstant: 82),
        ])
        let heading = phoneLabel(row.name, size: 22)
        heading.font = UIFontMetrics(forTextStyle: .title2).scaledFont(for: .systemFont(ofSize: 22, weight: .semibold))
        return PhoneRow(
            id: "name",
            title: "",
            bodyView: UIStackView([avatar, heading], axis: .vertical, spacing: 10, alignment: .center)
        )
    }

    private func phoneRow(_ phone: String) -> PhoneRow {
        let number = phoneLabel(phone)
        let message = phoneButton("Send Message", image: "message.fill") { [weak self] in
            self?.send(.messageTapped(phone))
        }
        let call = phoneButton("Dial", image: "phone.fill", color: .systemGreen) { [weak self] in
            self?.send(.callTapped(phone))
        }
        for button in [message, call] {
            button.configuration?.title = nil
            NSLayoutConstraint.activate([
                button.widthAnchor.constraint(equalToConstant: 42),
                button.heightAnchor.constraint(equalToConstant: 42),
            ])
        }
        return PhoneRow(
            id: phone,
            title: "",
            bodyView: UIStackView([number, UIView(), message, call], axis: .horizontal, spacing: 12, alignment: .center)
        )
    }
}

#if DEBUG
#Preview("Contact · Details") {
    let store = AirSIMPreviewFixtures.presentation(tab: .contacts).store.scope(state: \.contacts, action: \.contacts)
    return AirSIMPreviewFixtures.navigation(ContactDetailViewController(row: store.rows[0], store: store))
}
#endif
