import CallKit
import UIKit
import UserNotifications

/// Application delegate. Notification, CallKit and PushKit infrastructure is installed before any
/// foreground UI or AppModel is created, so lock-screen PushKit wakeups and notification actions
/// work during a cold launch. Scene/window lifecycle lives in `AirSIMSceneDelegate`.
@main
@MainActor
final class AirSIMAppDelegate: UIResponder, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    #if DEBUG
    private lazy var coldLaunchCallHandler = ColdLaunchCallKitHandler()
    private lazy var historyStore = LocalHistoryStore()

    override init() {
        super.init()
        // Preserve normal eager bootstrap order before didFinishLaunching, while
        // the preview host avoids discovery and creation of the history directory.
        if !AirSIMPreviewEnvironment.isActive {
            _ = coldLaunchCallHandler
            _ = historyStore
        }
    }
    #else
    private let coldLaunchCallHandler = ColdLaunchCallKitHandler()
    private let historyStore = LocalHistoryStore()
    #endif
    private var sceneConnectionObserver: (any NSObjectProtocol)?

    // MARK: - Application lifecycle

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        #if DEBUG
        guard !AirSIMPreviewEnvironment.isActive else { return true }
        #endif
        // Registered before any scene connects so a session restored from a SwiftUI-lifecycle build gets this app's
        // scene delegate.
        sceneConnectionObserver = NotificationCenter.default.addObserver(
            forName: UIScene.willConnectNotification,
            object: nil,
            queue: .main
        ) { notification in
            guard let scene = notification.object as? UIWindowScene else { return }
            MainActor.assumeIsolated { AirSIMSceneDelegate.adoptRestoredScene(scene) }
        }
        LiveActivityCallActionDispatcher.shared.handler = { action, callID in
            if CallKitController.shared.managesCurrentCall {
                try await CallKitController.shared.performLiveActivityAction(action, callID: callID)
            } else {
                try await AirSIMUIModel.shared.performLiveActivityAction(action, callID: callID)
            }
        }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        IncomingCallNotification.registerCategory()
        let policy = ConnectionModeRuntimePolicy(mode: ConnectionModePreference.selected())
        CallKitController.shared.setEnabled(policy.usesCallKit)
        if policy.usesCallKit, CallKitController.shared.handler == nil {
            CallKitController.shared.handler = coldLaunchCallHandler
        }
        // Watch tokens and cross-device answer ownership must be receivable during cold launch rather than waiting for
        // foreground UI construction (which may never fire on a lock-screen PushKit wakeup).
        WatchCallCoordinator.shared.start()
        if policy.startsCloud {
            VoIPPushController.shared.start()
            application.registerForRemoteNotifications()
        }
        #if DEBUG
        print(
            !policy.startsCloud
                ? "[AirSIM Local] Skipped APNs and PushKit registration"
                : "[AirSIM APNs] Started user notification and PushKit registration"
        )
        #endif
        return true
    }

    /// Scene-based apps do not receive this callback from UIKit; `AirSIMSceneDelegate` forwards it.
    func applicationDidBecomeActive(_ application: UIApplication) {
        #if DEBUG
        guard !AirSIMPreviewEnvironment.isActive else { return }
        #endif
        // The initial authorization prompt may return after didFinishLaunching; re-registering on foreground entry is
        // idempotent.
        guard ConnectionModeRuntimePolicy(mode: ConnectionModePreference.selected()).startsCloud else { return }
        VoIPPushController.shared.start()
        application.registerForRemoteNotifications()
        Task { await VoIPPushController.shared.syncRegistration() }
    }

    // MARK: - Remote notifications

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        guard ConnectionModeRuntimePolicy(mode: ConnectionModePreference.selected()).startsCloud else { return }
        VoIPPushController.shared.storeAlertToken(deviceToken)
        #if DEBUG
        print("[AirSIM APNs] User notification token updated; bytes=\(deviceToken.count)")
        #endif
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        guard ConnectionModeRuntimePolicy(mode: ConnectionModePreference.selected()).startsCloud else { return }
        VoIPPushController.shared.clearAlertToken()
        #if DEBUG
        print("[AirSIM APNs] User notification token registration failed: \(error.localizedDescription)")
        #endif
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        guard ConnectionModeRuntimePolicy(mode: ConnectionModePreference.selected()).startsCloud else {
            completionHandler(.noData)
            return
        }
        if userInfo["event"] as? String == "call_owner",
            userInfo["owner"] as? String == "watch"
        {
            let callID = userInfo["call_id"] as? String
            let uuid = (userInfo["call_uuid"] as? String).flatMap(UUID.init(uuidString:))
            if CallKitController.shared.matchesCurrentCall(callID: callID, uuid: uuid) {
                let reason: CXCallEndedReason =
                    userInfo["phase"] as? String == "active"
                    ? .answeredElsewhere : .declinedElsewhere
                CallKitController.shared.reportCurrentCallEnded(reason: reason)
                completionHandler(.newData)
            } else {
                completionHandler(.noData)
            }
            return
        }
        do {
            let pushed = try IncomingRemoteSMS(userInfo: userInfo)
            let saved = persistRemoteSMS(pushed)
            if saved {
                NotificationCenter.default.post(name: .airsimRemoteSMSReceived, object: nil)
            }
            completionHandler(saved ? .newData : .noData)
        } catch RemoteSMSPushError.unsupportedEvent {
            completionHandler(.noData)
        } catch {
            #if DEBUG
            print("[AirSIM APNs] Failed to parse SMS push payload: \(error.localizedDescription)")
            #endif
            completionHandler(.failed)
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    // UserNotifications does not document which thread calls these, and a main-actor witness traps off the main
    // thread, so they stay nonisolated.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        guard notification.request.content.userInfo["event"] as? String == "incoming_sms" else {
            completionHandler([])
            return
        }
        completionHandler([.banner, .list, .sound])
    }

    /// Handles lock-screen notification actions and controls module calls directly within the system-granted background
    /// execution window.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping @Sendable () -> Void
    ) {
        let route = NotificationResponseRoute(
            actionIdentifier: response.actionIdentifier,
            requestIdentifier: response.notification.request.identifier,
            userInfo: response.notification.request.content.userInfo
        )
        if Thread.isMainThread {
            MainActor.assumeIsolated { handle(route, completionHandler: completionHandler) }
        } else {
            Task { @MainActor in handle(route, completionHandler: completionHandler) }
        }
    }

    private func handle(_ route: NotificationResponseRoute, completionHandler: @escaping @Sendable () -> Void) {
        switch route {
        case .openSMS(let pushed, let sender):
            if let pushed, persistRemoteSMS(pushed) {
                NotificationCenter.default.post(name: .airsimRemoteSMSReceived, object: nil)
            }
            if let sender { IncomingSMSPresentationRequest.markPending(sender: sender) }
            NotificationCenter.default.post(
                name: .airsimOpenSMSConversation,
                object: nil,
                userInfo: sender.map { ["sender": $0] }
            )
            completionHandler()
        case .openIncomingCall:
            IncomingCallPresentationRequest.markPending()
            NotificationCenter.default.post(name: .airsimOpenIncomingCall, object: nil)
            completionHandler()
        case .ignore:
            completionHandler()
        case .callAction(let answer, let callID, let requestIdentifier):
            Task { @MainActor in
                defer {
                    UNUserNotificationCenter.current().removeDeliveredNotifications(
                        withIdentifiers: [requestIdentifier]
                    )
                    completionHandler()
                }
                do {
                    guard let api = await coldLaunchCallHandler.availableSamsungAPI() else {
                        throw CallKitBridgeError.noReachableTransport
                    }
                    let status = try await api.callStatus()
                    // Must match the same call that is still ringing so tapping a stale notification cannot affect a
                    // new call.
                    guard status.active?.id == callID,
                        status.active?.direction == "incoming",
                        let state = status.active?.state,
                        ["incoming", "waiting"].contains(state)
                    else { return }

                    if answer {
                        try await api.answerCall(callID: callID)
                    } else {
                        _ = try await api.rejectCall(callID: callID)
                    }
                } catch {
                    Self.reportActionFailure(error)
                }
            }
        }
    }

    // MARK: - Helpers

    private static func reportActionFailure(_ error: Error) {
        let content = UNMutableNotificationContent()
        content.title = "AirSIM Action Failed"
        content.body = error.localizedDescription
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(
                identifier: "airsim.call-action-failed.\(UUID().uuidString)",
                content: content,
                trigger: nil
            )
        )
    }

    private func persistRemoteSMS(_ pushed: IncomingRemoteSMS) -> Bool {
        // A long message carries only a Relay preview ending in "…" (content_truncated). Save it anyway so it reaches
        // Messages without a local Agent; the next local sync returns the same delivery id and replaces the preview
        // with the full body. A delivery id that is already stored, as a full body or a preview, is left alone.
        guard
            let messages = SMSHistoryPolicy.insertingRemote(
                pushed.message,
                into: historyStore.loadMessages(),
                limit: 2_000
            )
        else { return false }
        return historyStore.saveMessages(messages)
    }
}

/// What a notification tap or action asks for, read from the response on whatever thread UserNotifications used.
enum NotificationResponseRoute: Equatable, Sendable {
    case openSMS(pushed: IncomingRemoteSMS?, sender: String?)
    case openIncomingCall
    case callAction(answer: Bool, callID: String, requestIdentifier: String)
    case ignore

    init(actionIdentifier: String, requestIdentifier: String, userInfo: [AnyHashable: Any]) {
        let event = userInfo["event"] as? String
        if event == "incoming_sms" {
            self = .openSMS(pushed: try? IncomingRemoteSMS(userInfo: userInfo), sender: userInfo["sender"] as? String)
        } else if event == "incoming_call", actionIdentifier == UNNotificationDefaultActionIdentifier {
            self = .openIncomingCall
        } else if actionIdentifier == IncomingCallNotification.answerActionIdentifier
            || actionIdentifier == IncomingCallNotification.rejectActionIdentifier,
            let callID = userInfo[IncomingCallNotification.callIDKey] as? String
        {
            self = .callAction(
                answer: actionIdentifier == IncomingCallNotification.answerActionIdentifier,
                callID: callID,
                requestIdentifier: requestIdentifier
            )
        } else {
            self = .ignore
        }
    }
}

/// Process-wide UI model shared by the scene, Live Activity actions and Watch coordination.
@MainActor
enum AirSIMUIModel {
    static let shared = AppModel()
    static let settings = AppSettings()
}
