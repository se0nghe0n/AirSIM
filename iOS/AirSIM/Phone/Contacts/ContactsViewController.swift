import UIKit

/// A contact may store duplicate entries for the same phone number; since duplicate rows are interchangeable
/// during selection and dialing, deduplicate by number so phone-derived table row IDs stay unique.
enum ContactPhoneListPolicy {
    static func displayPhones(for phones: [String]) -> [String] {
        var seen = Set<String>()
        return phones.filter { seen.insert($0).inserted }
    }
}

@MainActor
final class ContactsViewController: PhoneTableController, UISearchResultsUpdating {
    override var tableStyle: UITableView.Style { .plain }
    let model: AirSIMPresentation
    let onCall: (String) -> Void
    let onMessage: (String) -> Void
    var onSelect: ((String) -> Void)?
    private let search = UISearchController(searchResultsController: nil)
    init(model: AirSIMPresentation, onCall: @escaping (String) -> Void, onMessage: @escaping (String) -> Void) { self.model = model; self.onCall = onCall; self.onMessage = onMessage; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() {
        super.viewDidLoad()
        if onSelect != nil { model.store.send(.contactPickerSearchChanged("")) }
        search.searchBar.text = onSelect == nil ? model.store.contactSearch : model.store.contactPickerSearch
        search.searchResultsUpdater = self; search.obscuresBackgroundDuringPresentation = false; search.searchBar.placeholder = "Search name or number"; navigationItem.searchController = search; navigationItem.hidesSearchBarWhenScrolling = false
        enableRefresh { [weak self] in await self?.model.contacts.requestAccessAndLoad() }
    }
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        Task { await model.contacts.loadIfAuthorized() }
    }
    func updateSearchResults(for searchController: UISearchController) {
        let text = searchController.searchBar.text ?? ""
        model.store.send(onSelect == nil ? .contactSearchChanged(text) : .contactPickerSearchChanged(text))
    }
    override func render() {
        title = onSelect == nil ? "Contacts" : "Choose Contact"
        navigationItem.title = onSelect == nil ? "Contacts · \(model.contacts.contacts.count)" : "Choose Contact"
        tabBarItem.title = "Contacts"
        guard model.contacts.isAuthorized else {
            let denied = model.contacts.authorizationState == .denied
            var configuration = UIContentUnavailableConfiguration.empty()
            configuration.image = UIImage(systemName: "person.crop.circle.badge.questionmark")
            configuration.text = denied ? "Contacts access is disabled" : "Allow Contacts Access"
            configuration.secondaryText = "Connect or grant access to get started."
            configuration.button = .filled(); configuration.button.title = denied ? "Open Settings" : "Allow Contacts Access"
            configuration.button.cornerStyle = .capsule
            configureContactEmptyStyle(&configuration)
            var buttonTitle = AttributeContainer(); buttonTitle.font = UIFont.systemFont(ofSize: 15, weight: .medium)
            configuration.button.attributedTitle = AttributedString(denied ? "Open Settings" : "Allow Contacts Access", attributes: buttonTitle)
            configuration.button.contentInsets = NSDirectionalEdgeInsets(top: 5, leading: 12, bottom: 5, trailing: 12)
            configuration.buttonProperties.primaryAction = UIAction { [weak self] _ in
                guard let self else { return }; if denied { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } } else { Task { await self.model.contacts.requestAccessAndLoad() } }
            }
            setSections([]); table.isHidden = true; contentUnavailableConfiguration = configuration
            return
        }
        table.isHidden = false; contentUnavailableConfiguration = nil
        let searchText = onSelect == nil ? model.store.contactSearch : model.store.contactPickerSearch
        if search.searchBar.text != searchText { search.searchBar.text = searchText }
        let query = searchText.trimmingCharacters(in: .whitespaces)
        let contacts = model.contacts.contacts.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.phones.contains { $0.localizedCaseInsensitiveContains(query) } }
        var rows: [PhoneRow] = []
        for contact in contacts {
            if let onSelect {
                for phone in ContactPhoneListPolicy.displayPhones(for: contact.phones) { rows.append(PhoneRow(id: contact.id + phone, title: contact.name, detail: phone, action: { onSelect(phone) }, photo: contact.photoData, avatarName: contact.name, bodyViewProvider: { PhoneListContentView(name: contact.name, subtitle: phone, photo: contact.photoData, avatarName: contact.name) }, insets: UIEdgeInsets(top: 0, left: 16, bottom: 0, right: 16))) }
            } else {
                rows.append(PhoneRow(id: contact.id, title: contact.name, detail: contact.phones.first ?? "", disclosure: true, action: { [weak self] in guard let self else { return }; self.navigationController?.pushViewController(ContactDetailViewController(contact: contact, onCall: self.onCall, onMessage: self.onMessage), animated: true) }, photo: contact.photoData, avatarName: contact.name, bodyViewProvider: { PhoneListContentView(name: contact.name, subtitle: contact.phones.first ?? "", photo: contact.photoData, avatarName: contact.name) }, insets: UIEdgeInsets(top: 0, left: 16, bottom: 0, right: 16)))
            }
        }
        table.separatorStyle = rows.isEmpty ? .none : .singleLine
        table.backgroundView = PhoneBackdropView()
        if rows.isEmpty {
            var configuration = UIContentUnavailableConfiguration.empty(); configuration.image = UIImage(systemName: "person.2"); configuration.text = "No contacts"; configuration.secondaryText = "Contacts sync from your device address book."
            configureContactEmptyStyle(&configuration)
            contentUnavailableConfiguration = configuration
        }
        setSections(rows.isEmpty ? [] : [PhoneSection(rows: rows)])
    }
    private func configureContactEmptyStyle(_ configuration: inout UIContentUnavailableConfiguration) {
        configuration.textProperties.font = UIFontMetrics(forTextStyle: .title3).scaledFont(for: .systemFont(ofSize: 20, weight: .bold))
        configuration.secondaryTextProperties.font = UIFontMetrics(forTextStyle: .body).scaledFont(for: .systemFont(ofSize: 20))
        configuration.secondaryTextProperties.numberOfLines = 0
        configuration.secondaryTextProperties.lineBreakMode = .byWordWrapping
        configuration.imageProperties.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 44)
        configuration.imageProperties.maximumSize = CGSize(width: 44, height: 44)
        configuration.imageToTextPadding = 24; configuration.textToSecondaryTextPadding = 2; configuration.textToButtonPadding = 28
        let width = traitCollection.horizontalSizeClass == .compact ? CGFloat(240) : CGFloat(360)
        let margin = max(16, (view.bounds.width - width) / 2)
        configuration.axesPreservingSuperviewLayoutMargins = []
        configuration.directionalLayoutMargins.leading = margin; configuration.directionalLayoutMargins.trailing = margin
    }
}

#if DEBUG
#Preview("Contacts · People") {
    AirSIMPreviewFixtures.navigation(ContactsViewController(model: AirSIMPreviewFixtures.presentation(tab: .contacts), onCall: { _ in }, onMessage: { _ in }))
}

#Preview("Contacts · Empty") {
    AirSIMPreviewFixtures.navigation(ContactsViewController(model: AirSIMPreviewFixtures.presentation(tab: .contacts, empty: true), onCall: { _ in }, onMessage: { _ in }))
}
#endif
