import ComposableArchitecture
import UIKit

@MainActor
@ViewAction(for: ContactsFeature.self)
final class ContactsViewController: PhoneTableController, UISearchResultsUpdating {
    // MARK: Store

    let store: StoreOf<ContactsFeature>

    // MARK: Views

    override var tableStyle: UITableView.Style { .plain }
    private let search = UISearchController(searchResultsController: nil)

    // MARK: Lifecycle

    init(store: StoreOf<ContactsFeature>) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        buildSearch()
        switch store.mode {
        case .browse:
            enableRefresh { [weak self] in await self?.send(.refreshPulled).finish() }
        case .pick:
            buildCancelItem()
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        send(.appeared)
    }

    // MARK: Rendering

    override func render() {
        title = store.title
        navigationItem.title = store.navigationTitle
        tabBarItem.title = "Contacts"
        if let prompt = store.accessPrompt {
            renderAccessPrompt(prompt)
        } else {
            renderContacts()
        }
    }

    private func renderAccessPrompt(_ prompt: ContactsFeature.AccessPrompt) {
        let configuration = accessConfiguration(prompt)
        setSections([])
        table.isHidden = true
        contentUnavailableConfiguration = configuration
    }

    private func renderContacts() {
        table.isHidden = false
        contentUnavailableConfiguration = nil
        if search.searchBar.text != store.search {
            search.searchBar.text = store.search
        }
        let rows = store.rows
        table.separatorStyle = rows.isEmpty ? .none : .singleLine
        table.backgroundView = PhoneBackdropView()
        if rows.isEmpty {
            contentUnavailableConfiguration = emptyConfiguration()
        }
        setSections(rows.isEmpty ? [] : [PhoneSection(rows: rows.map(contactRow))])
    }

    private func accessConfiguration(_ prompt: ContactsFeature.AccessPrompt) -> UIContentUnavailableConfiguration {
        let text: String
        let buttonTitle: String
        switch prompt {
        case .allowAccess:
            text = "Allow Contacts Access"
            buttonTitle = "Allow Contacts Access"
        case .openSettings:
            text = "Contacts access is disabled"
            buttonTitle = "Open Settings"
        }
        var configuration = UIContentUnavailableConfiguration.empty()
        configuration.image = UIImage(systemName: "person.crop.circle.badge.questionmark")
        configuration.text = text
        configuration.secondaryText = "Connect or grant access to get started."
        configuration.button = .filled()
        configuration.button.title = buttonTitle
        configuration.button.cornerStyle = .capsule
        applyEmptyStyle(to: &configuration)
        var buttonFont = AttributeContainer()
        buttonFont.font = UIFont.systemFont(ofSize: 15, weight: .medium)
        configuration.button.attributedTitle = AttributedString(buttonTitle, attributes: buttonFont)
        configuration.button.contentInsets = Metrics.accessButtonInsets
        configuration.buttonProperties.primaryAction = UIAction { [weak self] _ in self?.accessButtonTapped(prompt) }
        return configuration
    }

    private func emptyConfiguration() -> UIContentUnavailableConfiguration {
        var configuration = UIContentUnavailableConfiguration.empty()
        configuration.image = UIImage(systemName: "person.2")
        configuration.text = "No contacts"
        configuration.secondaryText = "Contacts sync from your device address book."
        applyEmptyStyle(to: &configuration)
        return configuration
    }

    private func applyEmptyStyle(to configuration: inout UIContentUnavailableConfiguration) {
        configuration.textProperties.font = UIFontMetrics(forTextStyle: .title3)
            .scaledFont(for: .systemFont(ofSize: 20, weight: .bold))
        configuration.secondaryTextProperties.font = UIFontMetrics(forTextStyle: .body)
            .scaledFont(for: .systemFont(ofSize: 20))
        configuration.secondaryTextProperties.numberOfLines = 0
        configuration.secondaryTextProperties.lineBreakMode = .byWordWrapping
        configuration.imageProperties.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 44)
        configuration.imageProperties.maximumSize = CGSize(width: 44, height: 44)
        configuration.imageToTextPadding = 24
        configuration.textToSecondaryTextPadding = 2
        configuration.textToButtonPadding = 28
        let width =
            traitCollection.horizontalSizeClass == .compact
            ? Metrics.compactTextWidth
            : Metrics.regularTextWidth
        let margin = max(Metrics.minimumTextMargin, (view.bounds.width - width) / 2)
        configuration.axesPreservingSuperviewLayoutMargins = []
        configuration.directionalLayoutMargins.leading = margin
        configuration.directionalLayoutMargins.trailing = margin
    }

    // MARK: Rows

    private func contactRow(_ row: ContactRow) -> PhoneRow {
        PhoneRow(
            id: row.id,
            title: row.name,
            detail: row.phone,
            disclosure: true,
            action: { [weak self] in self?.rowTapped(row) },
            photo: row.photo,
            avatarName: row.name,
            bodyViewProvider: {
                PhoneListContentView(
                    name: row.name,
                    subtitle: row.phone,
                    photo: row.photo,
                    avatarName: row.name
                )
            },
            insets: Metrics.rowInsets
        )
    }

    // MARK: Layout

    private func buildSearch() {
        search.searchBar.text = store.search
        search.searchResultsUpdater = self
        search.obscuresBackgroundDuringPresentation = false
        search.searchBar.placeholder = "Search name or number"
        navigationItem.searchController = search
        navigationItem.hidesSearchBarWhenScrolling = false
    }

    /// The picker's sheet otherwise gets a Done item; like a swipe-down, Cancel closes it without a choice.
    private func buildCancelItem() {
        let cancel = UIBarButtonItem(
            title: "Cancel",
            primaryAction: UIAction { [weak self] _ in self?.cancelTapped() }
        )
        cancel.tintColor = .systemBlue
        navigationItem.leftBarButtonItem = cancel
    }

    // MARK: Navigation

    private func showDetails(_ row: ContactRow) {
        let details = ContactDetailViewController(row: row, store: store)
        navigationController?.pushViewController(details, animated: true)
    }

    // MARK: Actions

    private func rowTapped(_ row: ContactRow) {
        switch store.mode {
        case .browse:
            showDetails(row)
        case .pick:
            send(.phoneChosen(row.phone))
        }
    }

    private func accessButtonTapped(_ prompt: ContactsFeature.AccessPrompt) {
        switch prompt {
        case .allowAccess:
            send(.allowAccessTapped)
        case .openSettings:
            guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
            UIApplication.shared.open(url)
        }
    }

    /// The presentation binding writes the closed picker back to its parent's state.
    private func cancelTapped() {
        navigationController?.dismiss(animated: true)
    }

    // MARK: UISearchResultsUpdating

    func updateSearchResults(for searchController: UISearchController) {
        send(.searchChanged(searchController.searchBar.text ?? ""))
    }
}

private enum Metrics {
    static let rowInsets = UIEdgeInsets(top: 0, left: 16, bottom: 0, right: 16)
    static let accessButtonInsets = NSDirectionalEdgeInsets(top: 5, leading: 12, bottom: 5, trailing: 12)
    static let compactTextWidth: CGFloat = 240
    static let regularTextWidth: CGFloat = 360
    static let minimumTextMargin: CGFloat = 16
}

#if DEBUG
#Preview("Contacts · People") {
    let store = AirSIMPreviewFixtures.store(tab: .contacts)
    return AirSIMPreviewFixtures.navigation(
        ContactsViewController(store: store.scope(state: \.contacts, action: \.contacts))
    )
}

#Preview("Contacts · Empty") {
    let store = AirSIMPreviewFixtures.store(tab: .contacts, empty: true)
    return AirSIMPreviewFixtures.navigation(
        ContactsViewController(store: store.scope(state: \.contacts, action: \.contacts))
    )
}
#endif
