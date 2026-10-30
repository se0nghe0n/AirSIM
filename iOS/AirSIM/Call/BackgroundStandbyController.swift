import AVFoundation
import CallKit
import Foundation
import UIKit
import UserNotifications

enum BackgroundStandbySuspensionPolicy {
    static func shouldStopAudio(isAlreadySuspended: Bool) -> Bool {
        !isAlreadySuspended
    }
}

extension Notification.Name {
    static let airsimRemoteSMSReceived = Notification.Name("AirSIMRemoteSMSReceived")
    static let airsimOpenSMSConversation = Notification.Name("AirSIMOpenSMSConversation")
    static let airsimOpenIncomingCall = Notification.Name("AirSIMOpenIncomingCall")
}

/// Stable identifiers used by lock-screen incoming call notifications; actions do not require device unlock or force the app UI open.
enum IncomingCallNotification {
    static let categoryIdentifier = "AIRSIM_INCOMING_CALL"
    static let mirrorCategoryIdentifier = "AIRSIM_INCOMING_CALL_MIRROR"
    static let answerActionIdentifier = "AIRSIM_ANSWER_CALL"
    static let rejectActionIdentifier = "AIRSIM_REJECT_CALL"
    static let callIDKey = "call_id"

    static func registerCategory() {
        let answer = UNNotificationAction(
            identifier: answerActionIdentifier,
            title: "Accept",
            options: []
        )
        let reject = UNNotificationAction(
            identifier: rejectActionIdentifier,
            title: "Decline",
            options: [.destructive]
        )
        let category = UNNotificationCategory(
            identifier: categoryIdentifier,
            actions: [answer, reject],
            intentIdentifiers: [],
            options: []
        )
        let mirrorCategory = UNNotificationCategory(
            identifier: mirrorCategoryIdentifier,
            actions: [],
            intentIdentifiers: [],
            options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([category, mirrorCategory])
    }
}

enum IncomingCallPresentationRequest {
    static let key = "airsim.pending-in-app-call-presentation"

    static func markPending(defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: key)
    }

    static func consume(defaults: UserDefaults = .standard) -> Bool {
        let pending = defaults.bool(forKey: key)
        if pending { defaults.removeObject(forKey: key) }
        return pending
    }


    static func isPending(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: key)
    }
}

/// When a notification is tapped, the initial UIKit screen may not have subscribed to events yet; store only the sender without persisting SMS body text.
enum IncomingSMSPresentationRequest {
    static let key = "airsim.pending-sms-sender"

    static func markPending(sender: String, defaults: UserDefaults = .standard) {
        defaults.set(sender, forKey: key)
    }

    static func consume(defaults: UserDefaults = .standard) -> String? {
        let sender = defaults.string(forKey: key)
        defaults.removeObject(forKey: key)
        return sender
    }
}

/// Handles lock-screen notification actions and controls module calls directly within the system-granted background execution window.
@MainActor
class AirSIMNotificationDelegate: NSObject, UIApplicationDelegate, @preconcurrency UNUserNotificationCenterDelegate {
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

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
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

/// Responds to system answer/reject actions before the foreground state model is initialized; AppModel takes over the handler once started.
@MainActor
private final class ColdLaunchCallKitHandler: CallKitActionHandling {
    private let vowlan = VoWLANController()

    init() { vowlan.startBrowsing() }

    func availableSamsungAPI() async -> AirSIMAPI? {
        await vowlan.probeNow()
        guard vowlan.availability.isOnlineForDisplay,
              let endpoint = vowlan.availability.endpoint,
              let credential = VoWLANCredentialStore.load() else { return nil }
        return AirSIMAPI(route: .vowlan(endpoint: endpoint, credential: credential))
    }

    func callKitStart(number: String) async throws {
        guard let api = await availableSamsungAPI() else { throw CallKitBridgeError.noReachableTransport }
        try await api.dial(number: number)
    }
    func callKitAnswer(origin: CallAnswerOrigin) async throws {
        if let pushedCall = CallKitController.shared.currentIncomingPush,
           pushedCall.isVirtual {
            try VirtualCallTTSController.shared.prepare(pushedCall)
        } else if CloudModePreference.isEnabled(),
                  let pushedCall = CallKitController.shared.currentIncomingPush,
                  pushedCall.authenticatedMediaURL != nil {
            try await IPhoneCloudCallSession.shared.answer(pushedCall)
        } else if let api = await availableSamsungAPI() {
            try await api.answerCall()
        } else {
            throw CallKitBridgeError.noReachableTransport
        }
    }
    func callKitEnd() async throws {
        if VirtualCallTTSController.shared.isPrepared
            || CallKitController.shared.currentIncomingPush?.isVirtual == true {
            VirtualCallTTSController.shared.stop()
            return
        }
        if CloudModePreference.isEnabled(),
           let pushedCall = CallKitController.shared.currentIncomingPush,
            pushedCall.authenticatedMediaURL != nil {
            if IPhoneCloudCallSession.shared.isPrepared {
                await IPhoneCloudCallSession.shared.end()
            } else {
                try await IPhoneCloudCallSession.shared.reject(pushedCall)
            }
            return
        }
        guard let api = await availableSamsungAPI() else { throw CallKitBridgeError.noReachableTransport }
        let call = (try? await api.callStatus())?.active
        if let call,
           call.direction == "incoming",
           ["incoming", "waiting"].contains(call.state) {
            _ = try await api.rejectCall(callID: call.id)
        } else {
            try await api.hangupCall(callID: call?.id)
        }
    }
    func callKitSetMuted(_ muted: Bool) async {
        if VirtualCallTTSController.shared.isPrepared {
            VirtualCallTTSController.shared.setMuted(muted)
            return
        }
        IPhoneCloudCallSession.shared.setMuted(muted)
        if !IPhoneCloudCallSession.shared.isPrepared,
           let api = await availableSamsungAPI() { try? await api.setAudioMuted(muted) }
    }
    func callKitPlayDTMF(_ digits: String) async throws {
        if VirtualCallTTSController.shared.isPrepared { return }
        for digit in digits where "0123456789*#".contains(digit) {
            guard let api = await availableSamsungAPI() else { throw CallKitBridgeError.noReachableTransport }
            try await api.sendDTMF(String(digit))
        }
    }
    func callKitAudioSessionDidActivate() async {
        if VirtualCallTTSController.shared.isPrepared {
            VirtualCallTTSController.shared.start()
        } else if IPhoneCloudCallSession.shared.hasActiveCall {
            IPhoneCloudCallSession.shared.startAudioWithRetry()
        }
    }
    func callKitAudioSessionDidDeactivate() {
        if VirtualCallTTSController.shared.isPrepared { VirtualCallTTSController.shared.stop() }
        else { IPhoneCloudCallSession.shared.stopAudio() }
    }
    func callKitProviderDidReset() async {
        if VirtualCallTTSController.shared.isPrepared { VirtualCallTTSController.shared.stop() }
        else { IPhoneCloudCallSession.shared.stopAudio() }
    }
    func callKitDidFail(_ message: String) {}
}

/// Maintains silent audio playback in personal sideload mode so iOS continues polling module calls after the screen turns off.
@MainActor
final class BackgroundStandbyController {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let silentBuffer: AVAudioPCMBuffer
    private var enabled = false
    private var appIsBackground = false
    private var suspendedForCall = false
    private var retryTask: Task<Void, Never>?
    private var interruptionObserver: NSObjectProtocol?
    private var mediaServicesResetObserver: NSObjectProtocol?

    init() {
        let format = AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8_000)!
        buffer.frameLength = buffer.frameCapacity
        if let samples = buffer.floatChannelData?.pointee {
            samples.initialize(repeating: 0, count: Int(buffer.frameLength))
        }
        silentBuffer = buffer
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)

        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor [weak self] in
                self?.handleInterruption(notification)
            }
        }
        mediaServicesResetObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.ensureRunning()
            }
        }
    }

    deinit {
        retryTask?.cancel()
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
        }
        if let mediaServicesResetObserver {
            NotificationCenter.default.removeObserver(mediaServicesResetObserver)
        }
    }

    func setEnabled(_ enabled: Bool) {
        self.enabled = enabled
        if enabled {
            ensureRunning()
        } else {
            stop(deactivateSession: true)
        }
    }

    /// Pre-starts when about to enter the background and releases audio hardware immediately upon returning to the foreground.
    func setApplicationIsBackground(_ isBackground: Bool) {
        if isBackground {
            prepareForBackground()
        } else if !suspendedForCall {
            appIsBackground = false
            stop(deactivateSession: true)
        }
    }

    /// The scene still has foreground execution privileges when entering .inactive, so audio must be pre-started at this moment.
    /// Waiting until the .background callback may be too late if the system has already decided to suspend the process.
    func prepareForBackground() {
        appIsBackground = true
        ensureRunning()
    }

    /// Re-verifies that silent playback is still running after returning to the foreground or after a system audio interruption.
    func ensureRunning() {
        guard enabled, appIsBackground, !suspendedForCall else { return }
        retryTask?.cancel()
        retryTask = nil
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            if !engine.isRunning { try engine.start() }
            if !player.isPlaying {
                player.scheduleBuffer(silentBuffer, at: nil, options: .loops)
                player.play()
            }
#if DEBUG
            print("[AirSIM Background] standby audio running")
#endif
        } catch {
#if DEBUG
            print("[AirSIM Background] standby audio failed: \(error.localizedDescription)")
#endif
            scheduleRetry()
        }
    }

    /// Call PCM must exclusively own the voiceChat session and must not contend with background silent playback for the output node.
    func suspendForCall() {
        guard BackgroundStandbySuspensionPolicy.shouldStopAudio(
            isAlreadySuspended: suspendedForCall
        ) else { return }
        suspendedForCall = true
        stop(deactivateSession: true)
    }

    func resumeAfterCall() {
        suspendedForCall = false
        ensureRunning()
    }

    private func stop(deactivateSession: Bool) {
        retryTask?.cancel()
        retryTask = nil
        player.stop()
        engine.stop()
        if deactivateSession {
            try? AVAudioSession.sharedInstance().setActive(
                false,
                options: .notifyOthersOnDeactivation
            )
        }
    }

    private func scheduleRetry() {
        guard retryTask == nil, enabled, appIsBackground, !suspendedForCall else { return }
        retryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.retryNow()
        }
    }

    private func retryNow() {
        retryTask = nil
        ensureRunning()
    }

    private func handleInterruption(_ notification: Notification) {
        guard let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: rawType),
              type == .ended else { return }
        ensureRunning()
    }
}

/// Posts a local notification when the app detects an incoming module call in the background, without relying on APNs or remote servers.
@MainActor
final class IncomingCallNotifier {
    private var notifiedCallIDs: [String] = []

    func requestAuthorization() {
        IncomingCallNotification.registerCategory()
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
#if DEBUG
            if let error {
                print("[AirSIM APNs] Notification authorization failed: \(error.localizedDescription)")
            } else {
                print("[AirSIM APNs] Notification authorization status: \(granted ? "granted" : "denied")")
            }
#endif
            Task { @MainActor in
                guard ConnectionModeRuntimePolicy(
                    mode: ConnectionModePreference.selected()
                ).startsCloud else { return }
                VoIPPushController.shared.start()
                UIApplication.shared.registerForRemoteNotifications()
            }
        }
    }

    func update(call: CallRecord?, callerName: String?, appIsActive: Bool) {
        guard !appIsActive,
              let call,
              call.direction == "incoming",
              ["incoming", "waiting"].contains(call.state),
              !notifiedCallIDs.contains(call.id) else { return }

        notifiedCallIDs.append(call.id)
        if notifiedCallIDs.count > 32 { notifiedCallIDs.removeFirst() }

        let content = UNMutableNotificationContent()
        let number = call.number?.isEmpty == false ? call.number! : "Unknown Number"
        let displayName = callerName?.isEmpty == false ? callerName! : number
        content.title = "AirSIM Incoming Call"
        // Include both name and phone number so the user can identify the caller directly on the lock screen.
        content.body = displayName == number ? number : "\(displayName) · \(number)"
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        content.categoryIdentifier = IncomingCallNotification.categoryIdentifier
        content.userInfo = [IncomingCallNotification.callIDKey: call.id]
        let request = UNNotificationRequest(
            identifier: "airsim.incoming.\(call.id)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}

/// New SMS messages are read individually by the Agent via +CMTI URC; posts a system notification when the app is in the background.
@MainActor
final class IncomingSMSNotifier {
    private var notifiedMessageIDs: [String] = []

    func notify(message: SMSMessage, displayName: String, appIsActive: Bool) {
        guard !appIsActive, !notifiedMessageIDs.contains(message.id) else { return }
        notifiedMessageIDs.append(message.id)
        if notifiedMessageIDs.count > 64 { notifiedMessageIDs.removeFirst() }

        let content = UNMutableNotificationContent()
        content.title = displayName
        content.body = message.content
        content.sound = .default
        content.interruptionLevel = .active
        let request = UNNotificationRequest(
            identifier: "airsim.sms.\(message.id.hashValue)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}
