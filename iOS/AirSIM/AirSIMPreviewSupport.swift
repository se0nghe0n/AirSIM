#if DEBUG
import UIKit
import Network
import ComposableArchitecture
import Clocks

/// Shared by the host lifecycle and fixture builders. Never enabled in release builds.
enum AirSIMPreviewEnvironment {
    static var isActive: Bool {
        ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
    }
}

/// In-memory preview data and dependencies. No AppModel, files, audio, discovery,
/// notification registration, permission prompts, or remote calls are created here.
@MainActor
enum AirSIMPreviewFixtures {
    static let date = Date(timeIntervalSince1970: 1_793_268_000)
    static let phone = "+1 202 555 0100"
    static let contact = ContactStore.Contact(
        id: "preview-mina", name: "Mina Kim", phones: [phone, "+1 202 555 0101"].map(ContactStore.normalized),
        emails: ["mina@example.com"], photoData: nil
    )
    static let contacts = [contact, ContactStore.Contact(
        id: "preview-alex", name: "Alex Rivera", phones: [ContactStore.normalized("+1 202 555 0102")],
        emails: [], photoData: nil
    )]
    static let agents = [
        AndroidAgentPresentation(id: "preview-samsung", deviceName: "Samsung Galaxy", phoneNumber: phone, agentKind: "standalone", cloudOnline: true, vowlanOnline: true, isCurrent: true),
        AndroidAgentPresentation(id: "preview-pixel", deviceName: "Pixel 8 Pro", phoneNumber: nil, agentKind: "standalone", cloudOnline: false, vowlanOnline: false, isCurrent: false),
    ]
    static let messages = [
        SMSMessage(sender: phone, content: "Hi Mina, are we still meeting at 3?", code: nil, timestamp: date.addingTimeInterval(-300), deliveryID: "preview-message-1", direction: .incoming),
        SMSMessage(sender: phone, content: "Yes! I will meet you outside the station.", code: nil, timestamp: date.addingTimeInterval(-240), deliveryID: "preview-message-2", direction: .outgoing),
        SMSMessage(sender: phone, content: "Perfect, see you there.", code: nil, timestamp: date.addingTimeInterval(-180), deliveryID: "preview-message-3", direction: .incoming),
    ]
    static let history = [
        CallRecord(id: "preview-recent-1", index: 1, direction: "incoming", state: "ended", number: phone, startedAt: date.addingTimeInterval(-900), updatedAt: date.addingTimeInterval(-840), endedAt: date.addingTimeInterval(-840), missed: false),
        CallRecord(id: "preview-recent-2", index: 2, direction: "outgoing", state: "ended", number: "+1 202 555 0102", startedAt: date.addingTimeInterval(-4_000), updatedAt: date.addingTimeInterval(-3_940), endedAt: date.addingTimeInterval(-3_940), missed: false),
        CallRecord(id: "preview-recent-3", index: 3, direction: "incoming", state: "ended", number: "+1 202 555 0199", startedAt: date.addingTimeInterval(-7_200), updatedAt: date.addingTimeInterval(-7_200), endedAt: date.addingTimeInterval(-7_200), missed: true),
    ]
    static let recordings = [
        CallRecordingFile(id: UUID(uuidString: "00000000-0000-0000-0000-000000000101")!, callID: "preview-recent-1", startedAt: date.addingTimeInterval(-900), duration: 65, fileName: "preview-call-1.wav", bytes: 1_024_000),
        CallRecordingFile(id: UUID(uuidString: "00000000-0000-0000-0000-000000000102")!, callID: "preview-recent-2", startedAt: date.addingTimeInterval(-4_000), duration: 142, fileName: "preview-call-2.wav", bytes: 2_048_000),
    ]
    static let pairingServices = [SamsungPairingService(
        endpoint: .service(name: "Samsung Galaxy", type: "_airsim-pair._tcp", domain: "local.", interface: nil),
        sessionID: "preview-pairing", serverPublicKey: Data(repeating: 0, count: 32),
        expiresAt: date.addingTimeInterval(600)
    )]
    static let traceEntries = [
        AgentVerboseTraceEntry(id: UUID(uuidString: "00000000-0000-0000-0000-000000000201")!, traceID: "PREVIEW1", timestamp: date, stage: .request, method: "POST", path: "/api/calls", detail: "Preview outgoing call request", elapsedMilliseconds: nil, source: "APP", category: "voice", fields: ["transport": "VoWLAN"]),
        AgentVerboseTraceEntry(id: UUID(uuidString: "00000000-0000-0000-0000-000000000202")!, traceID: "PREVIEW1", timestamp: date.addingTimeInterval(0.05), stage: .response, method: "POST", path: "/api/calls", detail: "Agent acknowledged the request", elapsedMilliseconds: 50, source: "APP", category: "http", fields: ["status": "200"]),
        AgentVerboseTraceEntry(id: UUID(uuidString: "00000000-0000-0000-0000-000000000203")!, traceID: "PREVIEW2", timestamp: date.addingTimeInterval(2), stage: .failure, method: "GET", path: "/api/debug", detail: "Sample reconnect event for preview only", elapsedMilliseconds: 120, source: "APP", category: "usb", fields: ["status": "503"]),
    ]
    static var selfTestReport: CloudSelfTestReport {
        var report = CloudSelfTestReport.initial
        for index in report.steps.indices {
            report.steps[index].state = .passed
            report.steps[index].detail = "Preview check passed"
        }
        report.completedAt = date
        return report
    }
    static func call(_ state: String) -> CallRecord {
        let now = Date()
        return CallRecord(id: "preview-call", index: 0, direction: "incoming", state: state, number: phone,
                          startedAt: now.addingTimeInterval(-65), updatedAt: now, endedAt: nil, missed: false)
    }

    static func presentation(
        tab: PhoneTab = .dial,
        callState: String? = nil,
        empty: Bool = false,
        appearance: AppAppearance = .light
    ) -> AirSIMPresentation {
        var state = AirSIMFeature.State()
        state.selectedTab = tab
        state.firstConnectionComplete = true
        state.dialNumber = phone
        state.lastBackendNumber = phone
        state.snapshot.numberInput = phone
        state.snapshot.contacts = empty ? [] : contacts
        state.snapshot.contactsAuthorized = true
        state.snapshot.contactsAuthorization = .authorized
        state.snapshot.callHistory = empty ? [] : history
        state.snapshot.messages = empty ? [] : messages
        state.snapshot.conversations = empty ? [] : [.init(sender: phone, messages: messages)]
        state.snapshot.pairedAndroidAgents = empty ? [] : agents
        state.snapshot.currentAndroidAgent = empty ? nil : agents.first
        state.snapshot.pairedDeviceHistory = empty ? [] : agents
        state.snapshot.recordings = empty ? [] : recordings
        state.snapshot.canStartOutgoingCommand = !empty
        state.snapshot.isOnline = !empty
        if !empty, let endpoint = try? VoWLANEndpoint(host: "192.168.1.20", controlPort: 8080) {
            state.snapshot.vowlan = .verified(endpoint, at: date)
        }
        state.snapshot.connectionModePresentation = .make(vowlanOnline: !empty, cloudModeEnabled: true, cloudOnline: !empty)
        state.settings.mode = .automatic
        state.settings.lastObservedMode = .automatic
        state.settings.appearance = appearance
        state.settings.lastObservedAppearance = appearance
        state.settings.relayURL = "https://relay.example.com"
        state.settings.lastObservedRelayURL = state.settings.relayURL
        state.settings.report = selfTestReport
        state.settings.selfTestCompleted = true
        state.snapshot.preferenceMode = state.settings.mode
        state.snapshot.preferenceAppearance = appearance
        state.snapshot.preferenceRelayURL = state.settings.relayURL
        state.snapshot.preferenceOnboardingComplete = true
        state.pairing.services = empty ? [] : pairingServices
        state.pairing.status = empty ? "Waiting for the Android pairing broadcast…" : "Found 1 device available to pair"
        state.pairing.code = "123456"
        state.trace.data = .previewData()
        if let callState {
            let record = call(callState)
            state.snapshot.inAppPresentedCall = record
            state.snapshot.callLifecycleSnapshot = CallLifecycleSnapshot(callID: record.id, callUUID: UUID(uuidString: "00000000-0000-0000-0000-000000000301")!, generation: 1, state: callState == "incoming" ? .ringing : .active, source: .app, timestamp: date, traceID: "PREVIEW1", failure: nil)
            state.snapshot.callAudioIsActive = callState == "active"
            state.snapshot.audioActive = callState == "active"
            state.snapshot.callAudioStatusText = callState == "active" ? "Audio Connected" : "Connecting Audio"
            state.snapshot.audioRoute = "iPhone"
            state.snapshot.canToggleRecording = callState == "active"
        }
        let snapshot = state.snapshot
        let services = state.pairing.services
        let trace = state.trace.data
        let report = selfTestReport
        let client = AirSIMClient(
            snapshots: { AsyncStream { $0.yield(snapshot); $0.finish() } },
            command: { _ in },
            sendSMS: { _, _ in .init(success: true) },
            selfTest: { AsyncStream { $0.yield(report); $0.finish() } },
            pairing: { AsyncStream { $0.yield(.init(services: services, status: services.isEmpty ? "Waiting for the Android pairing broadcast…" : "Found 1 device available to pair")); $0.finish() } },
            traceRefresh: { _, _ in trace },
            traceEnabled: { _ in },
            pair: { _, _, _ in "Preview pairing complete. No device was contacted." }
        )
        return AirSIMPresentation(store: Store(initialState: state) { AirSIMFeature() } withDependencies: {
            $0.airSIM = client
            $0.uuid = .incrementing
            // Freeze the diagnostic refresh loop; only explicit actions update previews.
            $0.continuousClock = TestClock<Duration>()
        })
    }

    static func navigation(_ controller: UIViewController) -> UINavigationController {
        let navigation = UINavigationController(rootViewController: controller)
        navigation.navigationBar.prefersLargeTitles = true
        return navigation
    }

    static func canvas(_ content: UIView, width: CGFloat = 360, height: CGFloat = 160, dark: Bool = false) -> UIViewController {
        PreviewCanvasViewController(content: content, size: CGSize(width: width, height: height), dark: dark)
    }
}

/// Preview-only sizing adapter, not an app screen or SwiftUI hosting controller.
@MainActor
private final class PreviewCanvasViewController: UIViewController {
    let content: UIView
    let size: CGSize
    init(content: UIView, size: CGSize, dark: Bool) {
        self.content = content; self.size = size
        super.init(nibName: nil, bundle: nil)
        overrideUserInterfaceStyle = dark ? .dark : .light
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        content.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(content)
        NSLayoutConstraint.activate([
            content.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            content.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            content.widthAnchor.constraint(equalToConstant: size.width),
            content.heightAnchor.constraint(equalToConstant: size.height),
        ])
    }
}
#endif
