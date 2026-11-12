import ComposableArchitecture
import UIKit

@MainActor
@ViewAction(for: DialFeature.self)
final class PairedAndroidAgentsViewController: PhoneTableController {
    // MARK: Store

    let store: StoreOf<DialFeature>

    // MARK: Lifecycle

    init(store: StoreOf<DialFeature>) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Paired Android Agents"
    }

    // MARK: Rendering

    override func render() {
        let rows = store.agentRows
        setSections([PhoneSection(rows: rows.isEmpty ? [emptyRow()] : rows.map(agentRow))])
    }

    // MARK: Rows

    private func agentRow(_ row: PairedAgentRow) -> PhoneRow {
        PhoneRow(
            id: row.id,
            title: row.title,
            detail: row.detail,
            action: { [weak self] in self?.send(.agentChosen(row.id)) },
            bodyViewProvider: { PairedAgentRowView(row: row) },
            bodyVersion: "\(row.isCurrent)"
        )
    }

    private func emptyRow() -> PhoneRow {
        PhoneRow(
            id: "empty",
            title: "No paired Android Agents",
            image: "smartphone.slash"
        )
    }
}

/// A sheet row as the SwiftUI list drew it: name and number, a check for the current agent, and route pills.
@MainActor
final class PairedAgentRowView: UIView {
    init(row: PairedAgentRow) {
        super.init(frame: .zero)
        let name = phoneLabel(row.title)
        name.font = .preferredFont(forTextStyle: .headline)
        let number = phoneLabel(row.number, color: .secondaryLabel)
        number.font = .preferredFont(forTextStyle: .subheadline)
        let names = UIStackView([name, number], axis: .vertical, spacing: Metrics.nameSpacing)
        let check = UIImageView(image: UIImage(systemName: row.isCurrent ? "checkmark.circle.fill" : "circle"))
        check.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .title3)
        check.tintColor = row.isCurrent ? .systemGreen : .secondaryLabel
        check.setContentHuggingPriority(.required, for: .horizontal)
        let header = UIStackView([names, check], axis: .horizontal, spacing: Metrics.spacing, alignment: .top)
        let kind = phoneLabel(row.kind, color: .secondaryLabel)
        kind.font = .preferredFont(forTextStyle: .caption1)
        kind.numberOfLines = 1
        let routes = UIStackView(
            AndroidAgentCardView.transportPills(agent: row.agent, cloudEnabled: row.cloudModeEnabled) + [
                UIView(), kind,
            ],
            axis: .horizontal,
            spacing: Metrics.spacing,
            alignment: .center
        )
        let stack = UIStackView([header, routes], axis: .vertical, spacing: Metrics.rowSpacing)
        addPinnedSubview(stack, insets: Metrics.insets)
        isAccessibilityElement = true
        accessibilityLabel = row.accessibilityLabel
        accessibilityTraits = row.isCurrent ? [.button, .selected] : .button
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

private enum Metrics {
    static let nameSpacing: CGFloat = 2
    static let spacing: CGFloat = 8
    static let rowSpacing: CGFloat = 9
    static let insets = UIEdgeInsets(top: 5, left: 0, bottom: 5, right: 0)
}

#if DEBUG
#Preview("Paired Android Agents") {
    let store = AirSIMPreviewFixtures.store()
    return AirSIMPreviewFixtures.navigation(
        PairedAndroidAgentsViewController(store: store.scope(state: \.dial, action: \.dial))
    )
}
#endif
