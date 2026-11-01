import UIKit

@MainActor
struct PhoneRow {
    let id: String
    var title: String
    var detail: String = ""
    var image: String? = nil
    var color: UIColor = .label
    var accessory: UIView? = nil
    var disclosure = false
    var enabled = true
    var action: (() -> Void)? = nil
    var context: (() -> UIMenu)? = nil
    var accessibilityHint: String? = nil
    var photo: Data? = nil
    var avatarName: String? = nil
    var bodyView: UIView? = nil
    var bodyViewProvider: (() -> UIView)? = nil
    var bodyVersion: String? = nil
    var insets = UIEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)
    var isValue = false
    var accessoryInline = false
    var transparent = false
    var textStyle: UIFont.TextStyle = .body

    struct BodyIdentity: Equatable {
        var id: String
        var title: String
        var detail: String
        var image: String?
        var color: UIColor
        var enabled: Bool
        var photo: Data?
        var avatarName: String?
        var version: String?
    }
    var bodyIdentity: BodyIdentity {
        BodyIdentity(id: id, title: title, detail: detail, image: image, color: color,
                     enabled: enabled, photo: photo, avatarName: avatarName, version: bodyVersion)
    }
}

@MainActor
private final class PhoneTableCell: UITableViewCell {
    var controlHost: UIStackView?
    var bodyIdentity: PhoneRow.BodyIdentity?
}

struct PhoneSection {
    var title: String = ""
    var footer: String = ""
    var rows: [PhoneRow]
}

/// Retains the native form controls across observation updates, including keyboard focus.
@MainActor
class PhoneTableController: ObservingViewController, UITableViewDataSource, UITableViewDelegate {
    var tableStyle: UITableView.Style { .insetGrouped }
    lazy var table = UITableView(frame: .zero, style: tableStyle)
    var sections: [PhoneSection] = []
    var onRefresh: (() async -> Void)?
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        table.translatesAutoresizingMaskIntoConstraints = false
        table.dataSource = self; table.delegate = self
        table.keyboardDismissMode = .interactive
        if tableStyle == .plain {
            table.backgroundColor = .clear
            table.backgroundView = PhoneBackdropView()
            table.separatorInset = UIEdgeInsets(top: 0, left: 93, bottom: 0, right: 16)
        }
        table.estimatedRowHeight = 74
        table.rowHeight = UITableView.automaticDimension
        view.addSubview(table)
        let groupExpansion: CGFloat = tableStyle == .insetGrouped && traitCollection.horizontalSizeClass == .compact ? 4 : 0
        NSLayoutConstraint.activate([table.topAnchor.constraint(equalTo: view.topAnchor), table.bottomAnchor.constraint(equalTo: view.bottomAnchor), table.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: -groupExpansion), table.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: groupExpansion)])
    }
    func setSections(_ updated: [PhoneSection]) {
        let previous = sections.map { $0.rows.map(\.id) }
        let next = updated.map { $0.rows.map(\.id) }
        // A hidden/new table may not have consumed its last reload yet. Resolve
        // UIKit's old counts before replacing the data source used by the batch.
        let canApplyUpdates = table.window != nil && table.numberOfSections == previous.count
            && previous.indices.allSatisfy { table.numberOfRows(inSection: $0) == previous[$0].count }
        sections = updated
        let hasDuplicateIDs = (previous + next).contains { Set($0).count != $0.count }
        if !canApplyUpdates || previous.count != next.count || hasDuplicateIDs {
            table.reloadData()
        } else if previous != next {
            // Insert/delete only changed identities. Stable text fields never leave their cells,
            // so asynchronous discovery, traces and self-tests cannot dismiss the keyboard.
            var deleted: [IndexPath] = []
            var inserted: [IndexPath] = []
            var reordered = false
            for section in next.indices {
                let oldSet = Set(previous[section]), newSet = Set(next[section])
                reordered = reordered || previous[section].filter(newSet.contains) != next[section].filter(oldSet.contains)
                deleted += previous[section].enumerated().compactMap { newSet.contains($0.element) ? nil : IndexPath(row: $0.offset, section: section) }
                inserted += next[section].enumerated().compactMap { oldSet.contains($0.element) ? nil : IndexPath(row: $0.offset, section: section) }
            }
            if reordered { table.reloadData() }
            else {
                UIView.performWithoutAnimation {
                    table.performBatchUpdates {
                        table.deleteRows(at: deleted, with: .none)
                        table.insertRows(at: inserted, with: .none)
                    }
                }
            }
        }
        for path in table.indexPathsForVisibleRows ?? [] {
            if sections.indices.contains(path.section), sections[path.section].rows.indices.contains(path.row), let cell = table.cellForRow(at: path) { configure(cell, at: path) }
        }
        for section in sections.indices {
            if let header = table.headerView(forSection: section) {
                configureSectionLabel(header, text: sections[section].title, header: true)
            }
            if let footer = table.footerView(forSection: section) {
                configureSectionLabel(footer, text: sections[section].footer, header: false)
            }
        }
    }

    func enableRefresh(_ action: @escaping () async -> Void) {
        onRefresh = action
        let refresh = UIRefreshControl()
        refresh.addAction(UIAction { [weak self] _ in
            Task { @MainActor in
                await self?.onRefresh?()
                self?.table.refreshControl?.endRefreshing()
            }
        }, for: .valueChanged)
        table.refreshControl = refresh
    }
    func numberOfSections(in tableView: UITableView) -> Int { sections.count }
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { sections[section].rows.count }
    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? { sections[section].title.isEmpty ? nil : sections[section].title }
    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? { sections[section].footer.isEmpty ? nil : sections[section].footer }
    func tableView(_ tableView: UITableView, willDisplayHeaderView view: UIView, forSection section: Int) {
        configureSectionLabel(view, text: sections[section].title, header: true)
    }
    func tableView(_ tableView: UITableView, willDisplayFooterView view: UIView, forSection section: Int) {
        configureSectionLabel(view, text: sections[section].footer, header: false)
    }
    private func configureSectionLabel(_ view: UIView, text: String, header: Bool) {
        guard tableStyle == .insetGrouped, let section = view as? UITableViewHeaderFooterView else { return }
        var content = section.defaultContentConfiguration()
        content.text = text; content.textProperties.color = .secondaryLabel
        content.textProperties.font = UIFontMetrics(forTextStyle: header ? .body : .footnote).scaledFont(for: .systemFont(ofSize: header ? 17 : 13, weight: header ? .semibold : .regular))
        content.textProperties.numberOfLines = 0
        content.axesPreservingSuperviewLayoutMargins = []
        content.directionalLayoutMargins.leading = 16; content.directionalLayoutMargins.trailing = 16
        section.contentConfiguration = content
    }
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "row") ?? PhoneTableCell(style: .subtitle, reuseIdentifier: "row")
        configure(cell, at: indexPath)
        return cell
    }
    func configure(_ cell: UITableViewCell, at path: IndexPath) {
        let row = sections[path.section].rows[path.row]
        let phoneCell = cell as? PhoneTableCell
        let unchangedBody = row.bodyViewProvider != nil && phoneCell?.bodyIdentity == row.bodyIdentity
        let bodyView = unchangedBody ? phoneCell?.controlHost?.arrangedSubviews.last : row.bodyView ?? row.bodyViewProvider?()
        phoneCell?.bodyIdentity = row.bodyViewProvider == nil ? nil : row.bodyIdentity
        cell.backgroundColor = tableStyle == .plain || row.transparent ? .clear : .secondarySystemGroupedBackground
        var content = row.isValue ? UIListContentConfiguration.valueCell() : cell.defaultContentConfiguration()
        content.textProperties.font = .preferredFont(forTextStyle: row.textStyle)
        if tableStyle == .insetGrouped { content.axesPreservingSuperviewLayoutMargins = []; content.directionalLayoutMargins.leading = 16; content.directionalLayoutMargins.trailing = 16 }
        content.text = row.title; content.secondaryText = row.detail.isEmpty ? nil : row.detail
        content.textProperties.color = row.enabled ? row.color : .secondaryLabel
        content.textProperties.numberOfLines = 0
        content.secondaryTextProperties.numberOfLines = 0
        content.image = row.image.flatMap(UIImage.init(systemName:))
        if bodyView == nil, let name = row.avatarName { content.image = phoneAvatar(name: name, photo: row.photo) }
        content.imageProperties.maximumSize = CGSize(width: 44, height: 44)
        if let control = bodyView ?? row.accessory, let cell = cell as? PhoneTableCell {
            cell.contentConfiguration = nil
            cell.accessoryView = nil
            if cell.controlHost?.arrangedSubviews.last !== control {
                cell.controlHost?.removeFromSuperview()
                let host = UIStackView(); host.axis = row.accessoryInline ? .horizontal : .vertical; host.spacing = 10; host.alignment = row.accessoryInline ? .center : .fill
                host.translatesAutoresizingMaskIntoConstraints = false
                if bodyView == nil && !row.title.isEmpty { host.addArrangedSubview(phoneLabel(row.title)); if row.accessoryInline { host.addArrangedSubview(UIView()); control.setContentHuggingPriority(.required, for: .horizontal) } }
                control.translatesAutoresizingMaskIntoConstraints = false
                host.addArrangedSubview(control)
                cell.contentView.addSubview(host); cell.controlHost = host
                NSLayoutConstraint.activate([host.leadingAnchor.constraint(equalTo: cell.contentView.leadingAnchor, constant: row.insets.left), host.trailingAnchor.constraint(equalTo: cell.contentView.trailingAnchor, constant: -row.insets.right), host.topAnchor.constraint(equalTo: cell.contentView.topAnchor, constant: row.insets.top), host.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor, constant: -row.insets.bottom)])
                if control is UITextView { control.heightAnchor.constraint(equalToConstant: 120).isActive = true }
                else if bodyView == nil { control.heightAnchor.constraint(greaterThanOrEqualToConstant: 32).isActive = true }
            }
        } else {
            (cell as? PhoneTableCell)?.controlHost?.removeFromSuperview()
            (cell as? PhoneTableCell)?.controlHost = nil
            cell.contentConfiguration = content
            cell.accessoryView = nil
        }
        cell.accessoryType = row.disclosure ? .disclosureIndicator : .none
        cell.selectionStyle = row.action != nil && row.enabled ? .default : .none
        cell.accessibilityHint = row.accessibilityHint
    }
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let row = sections[indexPath.section].rows[indexPath.row]
        if row.enabled { row.action?() }
    }
    func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
        guard let menu = sections[indexPath.section].rows[indexPath.row].context else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in menu() }
    }
    func row(at path: IndexPath) -> PhoneRow? {
        guard sections.indices.contains(path.section), sections[path.section].rows.indices.contains(path.row) else { return nil }
        return sections[path.section].rows[path.row]
    }
}

#if DEBUG
#Preview("Component · Table Cell") {
    let cell = PhoneTableCell(style: .subtitle, reuseIdentifier: nil)
    var content = cell.defaultContentConfiguration()
    content.text = "Mina Kim"
    content.secondaryText = "AirSIM Audio · Yesterday"
    content.image = UIImage(systemName: "phone.fill")
    cell.contentConfiguration = content
    return AirSIMPreviewFixtures.canvas(cell, height: 74)
}
#endif
