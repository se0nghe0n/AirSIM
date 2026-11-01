import ComposableArchitecture
import UIKit

/// The paired Android Agents with the current one checked; choosing one makes it current. It owns no state: it shows
/// and sends Dial actions.
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
            image: row.isCurrent ? "checkmark.circle.fill" : "circle",
            color: row.isCurrent ? .systemGreen : .label,
            action: { [weak self] in self?.send(.agentChosen(row.id)) }
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

#if DEBUG
#Preview("Paired Android Agents") {
    let store = AirSIMPreviewFixtures.presentation().store
    return AirSIMPreviewFixtures.navigation(
        PairedAndroidAgentsViewController(store: store.scope(state: \.dial, action: \.dial))
    )
}
#endif
