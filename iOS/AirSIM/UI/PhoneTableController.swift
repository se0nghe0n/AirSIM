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
        BodyIdentity(
            id: id,
            title: title,
            detail: detail,
            image: image,
            color: color,
            enabled: enabled,
            photo: photo,
            avatarName: avatarName,
            version: bodyVersion
        )
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

enum PhoneRowUpdate: Equatable {
    case unchanged
    case reload
    case batch(deleted: [IndexPath], inserted: [IndexPath])

    init(from previous: [[String]], to next: [[String]]) {
        let hasDuplicateIDs = (previous + next).contains { Set($0).count != $0.count }
        if previous.count != next.count || hasDuplicateIDs {
            self = .reload
            return
        }
        if previous == next {
            self = .unchanged
            return
        }
        var deleted: [IndexPath] = []
        var inserted: [IndexPath] = []
        var reordered = false
        for section in next.indices {
            let oldSet = Set(previous[section])
            let newSet = Set(next[section])
            reordered = reordered || previous[section].filter(newSet.contains) != next[section].filter(oldSet.contains)
            deleted += previous[section].enumerated().compactMap { row, id in
                newSet.contains(id) ? nil : IndexPath(row: row, section: section)
            }
            inserted += next[section].enumerated().compactMap { row, id in
                oldSet.contains(id) ? nil : IndexPath(row: row, section: section)
            }
        }
        self = reordered ? .reload : .batch(deleted: deleted, inserted: inserted)
    }
}

/// Retains the native form controls across observation updates, including keyboard focus.
@MainActor
class PhoneTableController: ObservingViewController, UITableViewDataSource, UITableViewDelegate {
    var tableStyle: UITableView.Style { .insetGrouped }
    lazy var table = UITableView(frame: .zero, style: tableStyle)
    private(set) var sections: [PhoneSection] = []
    private var onRefresh: (() async -> Void)?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        configureTable()
        layoutTable()
    }

    // MARK: Sections

    func setSections(_ updated: [PhoneSection]) {
        let previous = sections.map { $0.rows.map(\.id) }
        let next = updated.map { $0.rows.map(\.id) }
        // A hidden/new table may not have consumed its last reload yet. Resolve
        // UIKit's old counts before replacing the data source used by the batch.
        let canApplyUpdates =
            table.window != nil && table.numberOfSections == previous.count
            && previous.indices.allSatisfy { table.numberOfRows(inSection: $0) == previous[$0].count }
        sections = updated
        apply(canApplyUpdates ? PhoneRowUpdate(from: previous, to: next) : .reload)
        reconfigureVisibleRows()
        reconfigureSectionLabels()
    }

    func enableRefresh(_ action: @escaping () async -> Void) {
        onRefresh = action
        let refresh = UIRefreshControl()
        let refreshed = UIAction { [weak self] _ in
            Task { @MainActor in
                await self?.onRefresh?()
                self?.table.refreshControl?.endRefreshing()
            }
        }
        refresh.addAction(refreshed, for: .valueChanged)
        table.refreshControl = refresh
    }

    func row(at path: IndexPath) -> PhoneRow? {
        guard sections.indices.contains(path.section), sections[path.section].rows.indices.contains(path.row) else {
            return nil
        }
        return sections[path.section].rows[path.row]
    }

    private func apply(_ update: PhoneRowUpdate) {
        switch update {
        case .unchanged:
            break
        case .reload:
            table.reloadData()
        case let .batch(deleted, inserted):
            // Insert/delete only changed identities. Stable text fields never leave their cells,
            // so asynchronous discovery, traces and self-tests cannot dismiss the keyboard.
            UIView.performWithoutAnimation {
                table.performBatchUpdates {
                    table.deleteRows(at: deleted, with: .none)
                    table.insertRows(at: inserted, with: .none)
                }
            }
        }
    }

    private func reconfigureVisibleRows() {
        for path in table.indexPathsForVisibleRows ?? [] {
            guard row(at: path) != nil, let cell = table.cellForRow(at: path) else { continue }
            configure(cell, at: path)
        }
    }

    private func reconfigureSectionLabels() {
        for section in sections.indices {
            if let header = table.headerView(forSection: section) {
                configureSectionLabel(header, text: sections[section].title, header: true)
            }
            if let footer = table.footerView(forSection: section) {
                configureSectionLabel(footer, text: sections[section].footer, header: false)
            }
        }
    }

    // MARK: Cells

    private func configure(_ cell: UITableViewCell, at path: IndexPath) {
        let row = sections[path.section].rows[path.row]
        let phoneCell = cell as? PhoneTableCell
        let unchangedBody = row.bodyViewProvider != nil && phoneCell?.bodyIdentity == row.bodyIdentity
        let bodyView =
            unchangedBody
            ? phoneCell?.controlHost?.arrangedSubviews.last
            : row.bodyView ?? row.bodyViewProvider?()
        phoneCell?.bodyIdentity = row.bodyViewProvider == nil ? nil : row.bodyIdentity
        cell.backgroundColor = tableStyle == .plain || row.transparent ? .clear : .secondarySystemGroupedBackground
        if let control = bodyView ?? row.accessory, let phoneCell {
            phoneCell.contentConfiguration = nil
            phoneCell.accessoryView = nil
            if phoneCell.controlHost?.arrangedSubviews.last !== control {
                host(control, in: phoneCell, for: row, isBody: bodyView != nil)
            }
        } else {
            phoneCell?.controlHost?.removeFromSuperview()
            phoneCell?.controlHost = nil
            cell.contentConfiguration = listContent(for: row, in: cell, showsAvatar: bodyView == nil)
            cell.accessoryView = nil
        }
        cell.accessoryType = row.disclosure ? .disclosureIndicator : .none
        cell.selectionStyle = row.action != nil && row.enabled ? .default : .none
        cell.accessibilityHint = row.accessibilityHint
        // Custom row bodies draw their own content, so VoiceOver learns from the cell that a row is unavailable.
        if row.enabled {
            cell.accessibilityTraits.remove(.notEnabled)
        } else {
            cell.accessibilityTraits.insert(.notEnabled)
        }
    }

    private func listContent(
        for row: PhoneRow,
        in cell: UITableViewCell,
        showsAvatar: Bool
    ) -> UIListContentConfiguration {
        var content = row.isValue ? UIListContentConfiguration.valueCell() : cell.defaultContentConfiguration()
        content.textProperties.font = .preferredFont(forTextStyle: row.textStyle)
        if tableStyle == .insetGrouped {
            content.axesPreservingSuperviewLayoutMargins = []
            content.directionalLayoutMargins.leading = Metrics.groupedMargin
            content.directionalLayoutMargins.trailing = Metrics.groupedMargin
        }
        content.text = row.title
        content.secondaryText = row.detail.isEmpty ? nil : row.detail
        content.textProperties.color = row.enabled ? row.color : .secondaryLabel
        content.textProperties.numberOfLines = 0
        content.secondaryTextProperties.numberOfLines = 0
        content.image = row.image.flatMap(UIImage.init(systemName:))
        if showsAvatar, let name = row.avatarName {
            content.image = phoneAvatar(name: name, photo: row.photo)
        }
        content.imageProperties.maximumSize = CGSize(width: Metrics.imageSize, height: Metrics.imageSize)
        return content
    }

    private func host(_ control: UIView, in cell: PhoneTableCell, for row: PhoneRow, isBody: Bool) {
        cell.controlHost?.removeFromSuperview()
        let host = UIStackView(
            axis: row.accessoryInline ? .horizontal : .vertical,
            spacing: Metrics.controlSpacing,
            alignment: row.accessoryInline ? .center : .fill
        )
        if !isBody && !row.title.isEmpty {
            host.addArrangedSubview(phoneLabel(row.title))
            if row.accessoryInline {
                host.addArrangedSubview(UIView())
                control.setContentHuggingPriority(.required, for: .horizontal)
            }
        }
        control.translatesAutoresizingMaskIntoConstraints = false
        host.addArrangedSubview(control)
        cell.contentView.addPinnedSubview(host, insets: row.insets)
        cell.controlHost = host
        if control is UITextView {
            control.heightAnchor.constraint(equalToConstant: Metrics.textViewHeight).isActive = true
        } else if !isBody {
            control.heightAnchor.constraint(greaterThanOrEqualToConstant: Metrics.minimumControlHeight).isActive = true
        }
    }

    private func configureSectionLabel(_ view: UIView, text: String, header: Bool) {
        guard tableStyle == .insetGrouped, let section = view as? UITableViewHeaderFooterView else { return }
        var content = section.defaultContentConfiguration()
        content.text = text
        content.textProperties.color = .secondaryLabel
        content.textProperties.font =
            header
            ? UIFontMetrics(forTextStyle: .body).scaledFont(for: .systemFont(ofSize: 17, weight: .semibold))
            : UIFontMetrics(forTextStyle: .footnote).scaledFont(for: .systemFont(ofSize: 13, weight: .regular))
        content.textProperties.numberOfLines = 0
        content.axesPreservingSuperviewLayoutMargins = []
        content.directionalLayoutMargins.leading = Metrics.groupedMargin
        content.directionalLayoutMargins.trailing = Metrics.groupedMargin
        section.contentConfiguration = content
    }

    // MARK: Layout

    private func configureTable() {
        table.dataSource = self
        table.delegate = self
        table.keyboardDismissMode = .interactive
        if tableStyle == .plain {
            table.backgroundColor = .clear
            table.backgroundView = PhoneBackdropView()
            table.separatorInset = Metrics.plainSeparatorInset
        }
        table.estimatedRowHeight = Metrics.estimatedRowHeight
        table.rowHeight = UITableView.automaticDimension
    }

    private func layoutTable() {
        let expansion =
            tableStyle == .insetGrouped && traitCollection.horizontalSizeClass == .compact
            ? Metrics.compactGroupExpansion
            : 0
        view.addPinnedSubview(table, insets: UIEdgeInsets(top: 0, left: -expansion, bottom: 0, right: -expansion))
    }

    // MARK: UITableViewDataSource

    func numberOfSections(in tableView: UITableView) -> Int {
        sections.count
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        sections[section].rows.count
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        sections[section].title.isEmpty ? nil : sections[section].title
    }

    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        sections[section].footer.isEmpty ? nil : sections[section].footer
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell =
            tableView.dequeueReusableCell(withIdentifier: "row")
            ?? PhoneTableCell(style: .subtitle, reuseIdentifier: "row")
        configure(cell, at: indexPath)
        return cell
    }

    // MARK: UITableViewDelegate

    func tableView(_ tableView: UITableView, willDisplayHeaderView view: UIView, forSection section: Int) {
        configureSectionLabel(view, text: sections[section].title, header: true)
    }

    func tableView(_ tableView: UITableView, willDisplayFooterView view: UIView, forSection section: Int) {
        configureSectionLabel(view, text: sections[section].footer, header: false)
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let row = sections[indexPath.section].rows[indexPath.row]
        if row.enabled {
            row.action?()
        }
    }

    func tableView(
        _ tableView: UITableView,
        contextMenuConfigurationForRowAt indexPath: IndexPath,
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let menu = sections[indexPath.section].rows[indexPath.row].context else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in menu() }
    }
}

private enum Metrics {
    static let groupedMargin: CGFloat = 16
    static let plainSeparatorInset = UIEdgeInsets(top: 0, left: 93, bottom: 0, right: 16)
    static let estimatedRowHeight: CGFloat = 74
    static let compactGroupExpansion: CGFloat = 4
    static let imageSize: CGFloat = 44
    static let controlSpacing: CGFloat = 10
    static let textViewHeight: CGFloat = 120
    static let minimumControlHeight: CGFloat = 32
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
