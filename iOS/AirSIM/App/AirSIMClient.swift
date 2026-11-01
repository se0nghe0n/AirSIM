import ComposableArchitecture
import Foundation
import Observation

enum AirSIMCommand: Sendable {
    case dialNumber(String), answer, reject, hangup, mute, speaker, recording, dtmf(String)
    case bindAgent(String), refreshHistory, deleteHistory([String]), refreshMessages, loadMessages, reloadLocalMessages, clearMessages
    case contacts(Bool), refreshDevices, forgetDevice(String), discover, clearError(String), presentCall
    case mode(AirSIMConnectionMode), appearance(AppAppearance), liveActivity(Bool), saveRelay(String)
    case play(CallRecordingFile), stopPlayback(Bool), deleteRecording(CallRecordingFile), reloadRecordings
    case persistTab(PhoneTab), completeOnboarding
    case liveActivityAction(AirSIMLiveActivityAction, callID: String)
}

struct AirSIMMessageResult: Sendable {
    var success: Bool
    var error: String? = nil
}

struct AirSIMClient: Sendable {
    var snapshots: @Sendable () async -> AsyncStream<AirSIMSnapshot>
    var command: @Sendable (AirSIMCommand) async throws -> Void
    var sendSMS: @Sendable (String, String) async -> AirSIMMessageResult
    var selfTest: @Sendable () async -> AsyncStream<CloudSelfTestReport>
    var pairing: @Sendable () async -> AsyncStream<PairingFeature.Discovery>
    var traceRefresh: @Sendable (AgentVerboseTraceData, Bool) async -> AgentVerboseTraceData = { data, _ in data }
    var traceEnabled: @Sendable (Bool) async -> Void = { _ in }
    var pair: @Sendable (SamsungPairingService, String, Bool) async throws -> String
}
private enum AirSIMClientKey: DependencyKey {
    static var liveValue: AirSIMClient { fatalError("Install AirSIMClient.live in the foreground scene before creating a Store") }
}
extension DependencyValues {
    var airSIM: AirSIMClient { get { self[AirSIMClientKey.self] } set { self[AirSIMClientKey.self] = newValue } }
}

/// One-shot Observation registrations are re-armed on the main actor, never polled.
@MainActor
private final class SnapshotSubscription {
    let model: AppModel
    let playback: CallRecordingPlayback
    let settings: AppSettings
    private var defaultsToken: NSObjectProtocol?
    private var generation = 0
    let continuation: AsyncStream<AirSIMSnapshot>.Continuation
    var cancelled = false
    init(model: AppModel, settings: AppSettings, playback: CallRecordingPlayback, continuation: AsyncStream<AirSIMSnapshot>.Continuation) { self.model = model; self.settings = settings; self.playback = playback; self.continuation = continuation }
    func observe() {
        guard !cancelled else { return }
        generation += 1; let observedGeneration = generation
        _ = withObservationTracking { continuation.yield(AirSIMSnapshot(model: model, settings: settings, playback: playback)) } onChange: { [weak self] in
            Task { @MainActor [weak self] in guard let self, self.generation == observedGeneration else { return }; self.observe() }
        }
    }
    func start() {
        observe()
        defaultsToken = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.observe() } }
    }
    func cancel() { cancelled = true; generation += 1; if let defaultsToken { NotificationCenter.default.removeObserver(defaultsToken) }; defaultsToken = nil }
}

extension AirSIMClient {
    @MainActor static func live(model: AppModel, settings: AppSettings, playback: CallRecordingPlayback) -> Self {
        Self(snapshots: {
            await MainActor.run {
                AsyncStream { continuation in
                    let subscription = SnapshotSubscription(model: model, settings: settings, playback: playback, continuation: continuation)
                    subscription.start()
                    continuation.onTermination = { @Sendable _ in Task { @MainActor in subscription.cancel() } }
                }
            }
        }, command: { command in
            try await execute(command, model: model, settings: settings, playback: playback)
        }, sendSMS: { to, body in
            let result = await model.sendSMS(to: to, content: body)
            return AirSIMMessageResult(success: result.sent, error: result.error)
        }, selfTest: {
            AsyncStream { continuation in
                let task = Task { @MainActor in
                    let report = await VoIPPushController.shared.runCloudSelfTest { continuation.yield($0) }
                    guard !Task.isCancelled else { continuation.finish(); return }
                    continuation.yield(report); continuation.finish()
                    await model.refreshCloudStatusForDiagnostics()
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }, pairing: {
            await MainActor.run {
                AsyncStream { continuation in
                    let browser = SamsungPairingBrowser()
                    let observer = PairingSubscription(browser: browser, continuation: continuation)
                    observer.observe(); browser.start()
                    continuation.onTermination = { @Sendable _ in Task { @MainActor in observer.cancel() } }
                }
            }
        }, traceRefresh: { data, clear in
            var next = data
            next.enabled = await AgentVerboseTraceRecorder.shared.isEnabled()
            if clear { await next.clear(api: model.api) } else { await next.refresh(api: model.api) }
            return next
        }, traceEnabled: { enabled in await AgentVerboseTraceRecorder.shared.setEnabled(enabled) }, pair: { service, code, localOnly in
            try await VoIPPushController.shared.performAndroidPairing(localOnly: localOnly) { registration in
                try await SamsungPairingCompletionCoordinator.complete(performPairing: { try await SamsungPairingClient.pair(service: service, code: code, registration: registration) }, refreshVoWLAN: { await model.vowlan.refreshAfterPairing() })
            }
        })
    }
    @MainActor private static func execute(_ command: AirSIMCommand, model: AppModel, settings: AppSettings, playback: CallRecordingPlayback) async throws {
        switch command {
        case .dialNumber(let number): model.numberInput = number; await model.dial()
        case .answer: await model.answer()
        case .reject: await model.reject()
        case .hangup: await model.hangup()
        case .mute: await model.toggleMute()
        case .speaker: model.toggleSpeaker()
        case .recording: await model.toggleRecording()
        case .dtmf(let digit): await model.sendDTMF(digit)
        case .bindAgent(let id): model.bindAndroidAgent(id)
        case .refreshHistory: await model.refreshCallHistory()
        case .deleteHistory(let ids): model.deleteCallHistory(ids: Set(ids))
        case .refreshMessages: await model.refreshMessages()
        case .loadMessages: await model.loadMessagesFromAgent(silently: true)
        case .reloadLocalMessages: model.reloadMessagesFromLocalStore()
        case .clearMessages: try? await model.api.clearModuleSMS(); model.clearLocalMessages()
        case .contacts(let request): if request { await model.contacts.requestAccessAndLoad() } else { await model.contacts.loadIfAuthorized() }
        case .refreshDevices: await model.refreshPairedDeviceInformation()
        case .forgetDevice(let id): try await model.forgetAndroidDevice(id)
        case .discover: model.vowlan.restartBrowsing(); await model.vowlan.probeNow()
        // An alert acknowledges the error it showed; a newer one stays for its own alert.
        case .clearError(let error): if model.errorMessage == error { model.errorMessage = nil }
        case .presentCall: model.presentCurrentCallInApp()
        case .mode(let value): model.setConnectionMode(value)
        case .appearance(let value): settings.appearance = value
        case .liveActivity(let value): model.setLiveActivityEnabled(value)
        case .saveRelay(let url):
            VoIPPushController.shared.updateRelayURL(url)
            if let (api, _) = await model.readyVoWLANRoute() { await VoIPPushController.shared.syncRegistration(with: api) }
            await model.refreshCloudStatusForDiagnostics()
        case .play(let recording):
            guard !model.callLifecycleSnapshot.state.representsCall else { return }
            try playback.toggle(recording, url: model.recordings.url(for: recording))
        case .stopPlayback(let deactivate): playback.stop(deactivateSession: deactivate)
        case .deleteRecording(let recording): if playback.playingID == recording.id { playback.stop() }; try await model.recordings.delete(recording)
        case .reloadRecordings: await model.recordings.reload()
        case .persistTab(let tab): UserDefaults.standard.set(tab.rawValue, forKey: "airsim.selected-tab")
        case .completeOnboarding: UserDefaults.standard.set(true, forKey: "airsim.first-connection-complete")
        case let .liveActivityAction(action, callID):
            guard LiveActivityActionGate.accepts(callID: callID,
                currentCallID: model.callLifecycleSnapshot.callID,
                callIsLive: model.callLifecycleSnapshot.state.representsCall && model.callLifecycleSnapshot.state != .ending) else { return }
            switch action {
            case .answer: await model.answer()
            case .reject: await model.reject()
            case .hangup: await model.hangup()
            }
        }
    }
}

@MainActor
private final class PairingSubscription {
    let browser: SamsungPairingBrowser
    let continuation: AsyncStream<PairingFeature.Discovery>.Continuation
    var cancelled = false
    init(browser: SamsungPairingBrowser, continuation: AsyncStream<PairingFeature.Discovery>.Continuation) { self.browser = browser; self.continuation = continuation }
    func observe() {
        guard !cancelled else { return }
        _ = withObservationTracking { continuation.yield(.init(services: browser.services, status: browser.stateText)) } onChange: { [weak self] in Task { @MainActor in self?.observe() } }
    }
    func cancel() { cancelled = true; browser.stop() }
}
