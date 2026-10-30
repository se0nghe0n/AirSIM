import CallKit
import UIKit
import UserNotifications

/// Application delegate. Notification, CallKit and PushKit infrastructure is installed before any
/// foreground UI or AppModel is created, so lock-screen PushKit wakeups and notification actions
/// work during a cold launch. Scene/window lifecycle lives in `AirSIMSceneDelegate`.
@main
@MainActor
final class AirSIMAppDelegate: UIResponder, UIApplicationDelegate, @preconcurrency UNUserNotificationCenterDelegate {
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

    // MARK: - Application lifecycle

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
#if DEBUG
        guard !AirSIMPreviewEnvironment.isActive else { return true }
#endif
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
        print(!policy.startsCloud
            ? "[AirSIM Local] Skipped APNs and PushKit registration"
            : "[AirSIM APNs] Started user notification and PushKit registration")
#endif
        return true
    }

    /// Scene-based apps do not receive this callback from UIKit; `AirSIMSceneDelegate` forwards it.
    func applicationDidBecomeActive(_ application: UIApplication) {
#if DEBUG
        guard !AirSIMPreviewEnvironment.isActive else { return }
#endif
        // The initial authorization prompt may return after didFinishLaunching; re-registering on foreground entry is idempotent.
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
           userInfo["owner"] as? String == "watch" {
            let callID = userInfo["call_id"] as? String
            let uuid = (userInfo["call_uuid"] as? String).flatMap(UUID.init(uuidString:))
            if CallKitController.shared.matchesCurrentCall(callID: callID, uuid: uuid) {
                let reason: CXCallEndedReason = userInfo["phase"] as? String == "active"
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

    func userNotificationCenter(
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

    /// Handles lock-screen notification actions and controls module calls directly within the system-granted background execution window.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let actionIdentifier = response.actionIdentifier
        if response.notification.request.content.userInfo["event"] as? String == "incoming_sms" {
            let userInfo = response.notification.request.content.userInfo
            if let pushed = try? IncomingRemoteSMS(userInfo: userInfo), persistRemoteSMS(pushed) {
                NotificationCenter.default.post(name: .airsimRemoteSMSReceived, object: nil)
            }
            let sender = userInfo["sender"] as? String
            if let sender { IncomingSMSPresentationRequest.markPending(sender: sender) }
            NotificationCenter.default.post(
                name: .airsimOpenSMSConversation,
                object: nil,
                userInfo: sender.map { ["sender": $0] }
            )
            completionHandler()
            return
        }
        if response.notification.request.content.userInfo["event"] as? String == "incoming_call",
           actionIdentifier == UNNotificationDefaultActionIdentifier {
            IncomingCallPresentationRequest.markPending()
            NotificationCenter.default.post(name: .airsimOpenIncomingCall, object: nil)
            completionHandler()
            return
        }
        guard actionIdentifier == IncomingCallNotification.answerActionIdentifier
                || actionIdentifier == IncomingCallNotification.rejectActionIdentifier,
              let callID = response.notification.request.content.userInfo[
                  IncomingCallNotification.callIDKey
              ] as? String else {
            completionHandler()
            return
        }

        Task { @MainActor in
            defer {
                center.removeDeliveredNotifications(
                    withIdentifiers: [response.notification.request.identifier]
                )
                completionHandler()
            }
            do {
                guard let api = await coldLaunchCallHandler.availableSamsungAPI() else {
                    throw CallKitBridgeError.noReachableTransport
                }
                let status = try await api.callStatus()
                // Must match the same call that is still ringing so tapping a stale notification cannot affect a new call.
                guard status.active?.id == callID,
                      status.active?.direction == "incoming",
                      let state = status.active?.state,
                      ["incoming", "waiting"].contains(state) else { return }

                if actionIdentifier == IncomingCallNotification.answerActionIdentifier {
                    try await api.answerCall(callID: callID)
                } else {
                    _ = try await api.rejectCall(callID: callID)
                }
            } catch {
                Self.reportActionFailure(error)
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
        // Long messages carry only a preview in the APNs payload; wait for the next Agent sync to fetch the full body and avoid duplicate local entries.
        guard !pushed.contentTruncated else { return false }
        var messages = historyStore.loadMessages()
        guard !messages.contains(where: { $0.deliveryID == pushed.deliveryID }) else { return false }
        messages.append(pushed.message)
        messages.sort { $0.timestamp > $1.timestamp }
        if messages.count > 2_000 {
            messages = Array(messages.prefix(2_000))
        }
        return historyStore.saveMessages(messages)
    }
}

/// Process-wide UI model shared by the scene, Live Activity actions and Watch coordination.
@MainActor
enum AirSIMUIModel {
    static let shared = AppModel()
    static let settings = AppSettings()
}
