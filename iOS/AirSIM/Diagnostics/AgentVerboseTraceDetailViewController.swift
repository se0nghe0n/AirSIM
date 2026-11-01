import UIKit

@MainActor
final class AgentVerboseTraceDetailViewController: PhoneTableController {
    let item: AgentVerboseTimelineItem
    init(item: AgentVerboseTimelineItem) { self.item = item; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() {
        super.viewDidLoad(); title = "Trace Details"; navigationItem.largeTitleDisplayMode = .never
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: "Copy", primaryAction: UIAction { [weak self] _ in guard let self else { return }; UIPasteboard.general.string = "\(self.item.title)\n\(self.item.detail)" })
    }
    override func render() {
        let item = item
        var metadata = [PhoneRow(id: "source", title: "Source", detail: item.source, isValue: true), PhoneRow(id: "category", title: "Category", detail: item.category, isValue: true), PhoneRow(id: "time", title: "Time", detail: item.timestamp.formatted(.iso8601), isValue: true)]
        if let traceID = item.traceID { metadata.append(PhoneRow(id: "trace", title: "Trace ID", detail: traceID, isValue: true)) }
        setSections([PhoneSection(title: "Event", rows: metadata), PhoneSection(title: "Command", rows: [PhoneRow(id: "command", title: item.title, context: { UIMenu(children: [UIAction(title: "Copy") { [item] _ in UIPasteboard.general.string = item.title }]) })]), PhoneSection(title: "Full Content", rows: [PhoneRow(id: "detail", title: item.detail, context: { UIMenu(children: [UIAction(title: "Copy") { [item] _ in UIPasteboard.general.string = item.detail }]) })])])
    }
}

#if DEBUG
#Preview("Agent Verbose · Trace Details") {
    let item = AgentVerboseTraceData.previewData().timeline[0]
    return AirSIMPreviewFixtures.navigation(AgentVerboseTraceDetailViewController(item: item))
}
#endif
