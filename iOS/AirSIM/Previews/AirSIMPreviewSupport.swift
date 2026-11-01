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
    nonisolated static let phone = "+1 202 555 0100"
    static let contact = ContactStore.Contact(
        id: "preview-mina",
        name: "Mina Kim",
        phones: [phone, "+1 202 555 0101"].map(ContactStore.normalized),
        emails: ["mina@example.com"],
        photoData: nil
    )
    static let contacts = [
        contact,
        ContactStore.Contact(
            id: "preview-alex",
            name: "Alex Rivera",
            phones: [ContactStore.normalized("+1 202 555 0102")],
            emails: [],
            photoData: nil
        ),
    ]
    static let agents = [
        AndroidAgentPresentation(
            id: "preview-samsung",
            deviceName: "Samsung Galaxy",
            phoneNumber: phone,
            agentKind: "standalone",
            cloudOnline: true,
            vowlanOnline: true,
            isCurrent: true
        ),
        AndroidAgentPresentation(
            id: "preview-pixel",
            deviceName: "Pixel 8 Pro",
            phoneNumber: nil,
            agentKind: "standalone",
            cloudOnline: false,
            vowlanOnline: false,
            isCurrent: false
        ),
    ]
    static let messages = [
        SMSMessage(
            sender: phone,
            content: "Hi Mina, are we still meeting at 3?",
            code: nil,
            timestamp: date.addingTimeInterval(-300),
            deliveryID: "preview-message-1",
            direction: .incoming
        ),
        SMSMessage(
            sender: phone,
            content: "Yes! I will meet you outside the station.",
            code: nil,
            timestamp: date.addingTimeInterval(-240),
            deliveryID: "preview-message-2",
            direction: .outgoing
        ),
        SMSMessage(
            sender: phone,
            content: "Perfect, see you there.",
            code: nil,
            timestamp: date.addingTimeInterval(-180),
            deliveryID: "preview-message-3",
            direction: .incoming
        ),
    ]
    static let history = [
        CallRecord(
            id: "preview-recent-1",
            index: 1,
            direction: "incoming",
            state: "ended",
            number: phone,
            startedAt: date.addingTimeInterval(-900),
            updatedAt: date.addingTimeInterval(-840),
            endedAt: date.addingTimeInterval(-840),
            missed: false
        ),
        CallRecord(
            id: "preview-recent-2",
            index: 2,
            direction: "outgoing",
            state: "ended",
            number: "+1 202 555 0102",
            startedAt: date.addingTimeInterval(-4_000),
            updatedAt: date.addingTimeInterval(-3_940),
            endedAt: date.addingTimeInterval(-3_940),
            missed: false
        ),
        CallRecord(
            id: "preview-recent-3",
            index: 3,
            direction: "incoming",
            state: "ended",
            number: "+1 202 555 0199",
            startedAt: date.addingTimeInterval(-7_200),
            updatedAt: date.addingTimeInterval(-7_200),
            endedAt: date.addingTimeInterval(-7_200),
            missed: true
        ),
    ]
    static let recordings = [
        CallRecordingFile(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000101")!,
            callID: "preview-recent-1",
            startedAt: date.addingTimeInterval(-900),
            duration: 65,
            fileName: "preview-call-1.wav",
            bytes: 1_024_000
        ),
        CallRecordingFile(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000102")!,
            callID: "preview-recent-2",
            startedAt: date.addingTimeInterval(-4_000),
            duration: 142,
            fileName: "preview-call-2.wav",
            bytes: 2_048_000
        ),
    ]
    static let pairingServices = [
        SamsungPairingService(
            endpoint: .service(name: "Samsung Galaxy", type: "_airsim-pair._tcp", domain: "local.", interface: nil),
            sessionID: "preview-pairing",
            serverPublicKey: Data(repeating: 0, count: 32),
            expiresAt: date.addingTimeInterval(600)
        ),
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
        return CallRecord(
            id: "preview-call",
            index: 0,
            direction: "incoming",
            state: state,
            number: phone,
            startedAt: now.addingTimeInterval(-65),
            updatedAt: now,
            endedAt: nil,
            missed: false
        )
    }

    /// A root store over fixture data whose client contacts nothing.
    static func store(
        tab: PhoneTab = .dial,
        callState: String? = nil,
        empty: Bool = false,
        appearance: AppAppearance = .light
    ) -> StoreOf<AirSIMFeature> {
        let snapshot = backendSnapshot(callState: callState, empty: empty, appearance: appearance)
        let services = empty ? [] : pairingServices
        let status = empty ? "Waiting for the Android pairing broadcast…" : "Found 1 device available to pair"
        let report = selfTestReport
        var state = AirSIMFeature.State(snapshot: snapshot)
        state.selectedTab = tab
        state.firstConnectionComplete = true
        state.settings.report = report
        state.settings.selfTestCompleted = true
        state.settings.pairing.services = services
        state.settings.pairing.status = status

        let client = AirSIMClient(
            snapshots: { [snapshot] in
                AsyncStream {
                    $0.yield(snapshot)
                    $0.finish()
                }
            },
            command: { _ in },
            sendSMS: { _, _ in .init(success: true) },
            selfTest: {
                AsyncStream {
                    $0.yield(report)
                    $0.finish()
                }
            },
            pairing: {
                AsyncStream {
                    $0.yield(.init(services: services, status: status))
                    $0.finish()
                }
            },
            pair: { _, _, _ in "Preview pairing complete. No device was contacted." }
        )
        return Store(initialState: state) {
            AirSIMFeature()
        } withDependencies: {
            $0.airSIM = client
            $0.uuid = .incrementing
            // Freeze the diagnostic refresh loop; only explicit actions update previews.
            $0.continuousClock = TestClock<Duration>()
        }
    }

    /// Settings seeds its mode, appearance, relay URL and Live Activity switch from these saved preferences.
    private static func backendSnapshot(callState: String?, empty: Bool, appearance: AppAppearance) -> AirSIMSnapshot {
        var snapshot = AirSIMSnapshot()
        snapshot.numberInput = phone
        snapshot.contacts = ContactDirectory(all: empty ? [] : contacts, isAuthorized: true, authorization: .authorized)
        snapshot.callHistory = empty ? [] : history
        snapshot.messages = empty ? [] : messages
        snapshot.conversations = empty ? [] : [.init(sender: phone, messages: messages)]
        snapshot.pairedAndroidAgents = empty ? [] : agents
        snapshot.currentAndroidAgent = empty ? nil : agents.first
        snapshot.pairedDeviceHistory = empty ? [] : agents
        snapshot.recordings = empty ? [] : recordings
        snapshot.canStartOutgoingCommand = !empty
        snapshot.isOnline = !empty
        if !empty, let endpoint = try? VoWLANEndpoint(host: "192.168.1.20", controlPort: 8080) {
            snapshot.vowlan = .verified(endpoint, at: date)
        }
        snapshot.connectionModePresentation = .make(vowlanOnline: !empty, cloudModeEnabled: true, cloudOnline: !empty)
        snapshot.preferenceMode = .automatic
        snapshot.preferenceAppearance = appearance
        snapshot.preferenceRelayURL = "https://relay.example.com"
        snapshot.preferenceOnboardingComplete = true
        snapshot.cloudModeEnabled = true
        if let callState {
            let record = call(callState)
            snapshot.inAppPresentedCall = record
            snapshot.callLifecycleSnapshot = CallLifecycleSnapshot(
                callID: record.id,
                callUUID: UUID(uuidString: "00000000-0000-0000-0000-000000000301")!,
                generation: 1,
                state: callState == "incoming" ? .ringing : .active,
                source: .app,
                timestamp: date,
                traceID: "PREVIEW1",
                failure: nil
            )
            snapshot.callAudioIsActive = callState == "active"
            snapshot.audioActive = callState == "active"
            snapshot.callAudioStatusText = callState == "active" ? "Audio Connected" : "Connecting Audio"
            snapshot.audioRoute = "iPhone"
            snapshot.canToggleRecording = callState == "active"
        }
        return snapshot
    }

    static func navigation(_ controller: UIViewController) -> UINavigationController {
        let navigation = UINavigationController(rootViewController: controller)
        navigation.navigationBar.prefersLargeTitles = true
        return navigation
    }

    static func canvas(
        _ content: UIView,
        width: CGFloat = 360,
        height: CGFloat = 160,
        dark: Bool = false
    ) -> UIViewController {
        PreviewCanvasViewController(content: content, size: CGSize(width: width, height: height), dark: dark)
    }
}

/// Preview-only sizing adapter, not an app screen or SwiftUI hosting controller.
@MainActor
private final class PreviewCanvasViewController: UIViewController {
    let content: UIView
    let size: CGSize

    init(content: UIView, size: CGSize, dark: Bool) {
        self.content = content
        self.size = size
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
