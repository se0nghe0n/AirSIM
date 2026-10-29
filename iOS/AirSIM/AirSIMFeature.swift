import ComposableArchitecture
import Observation
import UIKit

/// Value-only projection: reducers never retain the observable backend or UIKit objects.
struct ConversationSnapshot: Equatable, Sendable { var sender: String; var messages: [SMSMessage] }

struct AirSIMSnapshot: Equatable, Sendable {
    var callHistory: [CallRecord] = []
    var isRefreshingCallHistory = false
    var callHistoryMessage: String?
    var messages: [SMSMessage] = []
    var conversations: [ConversationSnapshot] = []
    var numberInput = ""
    var isOnline = false
    var connectionMessage: String?
    var isBusy = false
    var isMuted = false
    var isRecording = false
    var isRecordingBusy = false
    var errorMessage: String?
    var modemStatus: ModemStatus?
    var cloudAgentStatus: CloudAgentStatus?
    var cloudCallAudioState: CloudCallAudioState = .idle
    var callLifecycleSnapshot: CallLifecycleSnapshot = .idle
    var inAppPresentedCall: CallRecord?
    var callAudioIsActive = false
    var callAudioStatusText = ""
    var canStartOutgoingCommand = false
    var canToggleRecording = false
    var connectionModePresentation = ConnectionModePresentation.make(vowlanOnline: false, cloudModeEnabled: false, cloudOnline: false)
    var pairedAndroidAgents: [AndroidAgentPresentation] = []
    var currentAndroidAgent: AndroidAgentPresentation?
    var pairedDeviceHistory: [AndroidAgentPresentation] = []
    var contacts: [ContactStore.Contact] = []
    var contactsAuthorized = false
    var contactsAuthorization: ContactAuthorizationState = .notDetermined
    var audioActive = false
    var speakerEnabled = false
    var audioRoute = ""
    var audioError: String?
    var vowlan: VoWLANAvailability = .unpaired
    var recordings: [CallRecordingFile] = []
    var recordingsBusy = false
    var recordingURLs: [UUID: URL] = [:]
    var preferenceMode = AirSIMConnectionMode.automatic
    var preferenceAppearance = AppAppearance.system
    var preferenceLiveActivity = true
    var preferenceRelayURL = ""
    var preferenceOnboardingComplete = false
    var playingRecordingID: UUID?

    @MainActor init(model: AppModel, settings: AppSettings, playback: CallRecordingPlayback) {
        preferenceMode = ConnectionModePreference.selected(); preferenceAppearance = settings.appearance
        preferenceLiveActivity = LiveActivityVisibilityPreference.isEnabled(); preferenceOnboardingComplete = UserDefaults.standard.bool(forKey: "airsim.first-connection-complete")
        preferenceRelayURL = RelayConfiguration.effectiveURL(stored: UserDefaults.standard.string(forKey: "airsim.push-relay-url"), buildSetting: Bundle.main.object(forInfoDictionaryKey: "AirSIMPushRelayURL") as? String, bundleID: Bundle.main.bundleIdentifier)
        callHistory = model.callHistory; isRefreshingCallHistory = model.isRefreshingCallHistory
        callHistoryMessage = model.callHistoryMessage; messages = model.messages; conversations = model.conversations.map { ConversationSnapshot(sender: $0.sender, messages: $0.messages) }
        numberInput = model.numberInput; isOnline = model.isOnline; connectionMessage = model.connectionMessage
        isBusy = model.isBusy; isMuted = model.isMuted; isRecording = model.isRecording; isRecordingBusy = model.isRecordingBusy
        errorMessage = model.errorMessage; modemStatus = model.modemStatus; cloudAgentStatus = model.cloudAgentStatus
        cloudCallAudioState = model.cloudCallAudioState; callLifecycleSnapshot = model.callLifecycleSnapshot
        inAppPresentedCall = model.inAppPresentedCall; callAudioIsActive = model.callAudioIsActive; callAudioStatusText = model.callAudioStatusText
        canStartOutgoingCommand = model.canStartOutgoingCommand; canToggleRecording = model.canToggleRecording
        connectionModePresentation = model.connectionModePresentation; pairedAndroidAgents = model.pairedAndroidAgents
        currentAndroidAgent = model.currentAndroidAgent; pairedDeviceHistory = model.pairedDeviceHistory
        contacts = model.contacts.contacts; contactsAuthorized = model.contacts.isAuthorized; contactsAuthorization = model.contacts.authorizationState
        audioActive = model.audio.active; speakerEnabled = model.audio.speakerEnabled; audioRoute = model.audio.routeDescription; audioError = model.audio.errorMessage
        vowlan = model.vowlan.availability; recordings = model.recordings.recordings; recordingsBusy = model.recordings.isBusy; playingRecordingID = playback.playingID; recordingURLs = Dictionary(uniqueKeysWithValues: recordings.map { ($0.id, model.recordings.url(for: $0)) })
    }
    init() {}
}

enum AirSIMCommand: Sendable {
    case dialNumber(String), answer, reject, hangup, mute, speaker, recording, dtmf(String)
    case bindAgent(String), refreshHistory, deleteHistory([String]), refreshMessages, loadMessages, reloadLocalMessages, clearMessages
    case contacts(Bool), refreshDevices, forgetDevice(String), discover, clearError, presentCall
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
            let success = await model.sendSMS(to: to, content: body)
            return await MainActor.run { AirSIMMessageResult(success: success, error: success ? nil : model.errorMessage) }
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
        case .clearError: model.errorMessage = nil
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

@Reducer
struct MessagesFeature {
    @ObservableState struct State: Equatable {
        var recipient = ""
        var body = ""
        var reply = ""
        var conversation: String?
        var composerPresented = false
        var sending = false
        var sendID: UUID?
        var error: String?
    }
    enum Action {
        case compose(String), openConversation(String), closeConversation, dismissComposer
        case recipientChanged(String), bodyChanged(String), replyChanged(String)
        case sendComposer, sendReply(to: String), sendResponse(id: UUID, success: Bool, body: String, composer: Bool, error: String? = nil)
        case clearError
    }
    @Dependency(\.airSIM) var client
    @Dependency(\.uuid) var uuid
    enum CancelID { case send }
    var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .compose(let recipient):
                if !state.composerPresented { state.body = "" }
                state.recipient = recipient; state.composerPresented = true; state.error = nil; state.sendID = nil; state.sending = false; return .none
            case .openConversation(let sender): state.conversation = sender; state.composerPresented = false; state.reply = ""; state.error = nil; state.sendID = nil; state.sending = false; return .none
            case .closeConversation: state.conversation = nil; state.sendID = nil; state.sending = false; return .none
            case .dismissComposer: state.composerPresented = false; state.sendID = nil; state.sending = false; return .none
            case .recipientChanged(let value): state.recipient = value; return .none
            case .bodyChanged(let value): state.body = value; return .none
            case .replyChanged(let value): state.reply = value; return .none
            case .clearError: state.error = nil; return .run { [client] _ in try await client.command(.clearError) }
            case .sendComposer, .sendReply:
                guard !state.sending else { return .none }
                let composer: Bool; if case .sendComposer = action { composer = true } else { composer = false }
                let to: String
                if case .sendReply(let sender) = action { to = sender } else { to = state.recipient }
                let body = composer ? state.body : state.reply
                guard !to.trimmingCharacters(in: .whitespaces).isEmpty, !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .none }
                let id = uuid(); state.sendID = id; state.sending = true; state.error = nil
                return .run { [client] send in
                    let result = await client.sendSMS(to, body)
                    await send(.sendResponse(id: id, success: result.success, body: body, composer: composer, error: result.error))
                }.cancellable(id: CancelID.send)
            case let .sendResponse(id, success, body, composer, error):
                guard state.sendID == id else { return .none }
                state.sendID = nil; state.sending = false
                if success {
                    if composer { state.composerPresented = false; if state.body == body { state.body = "" } }
                    else if state.reply == body { state.reply = "" }
                } else { state.error = error ?? "Unable to send message. Your draft has been kept." }
                return .none
            }
        }
    }
}

@Reducer
struct SettingsFeature {
    @ObservableState struct State: Equatable {
        var mode = AirSIMConnectionMode.automatic
        var appearance = AppAppearance.system
        var relayURL = ""
        var lastObservedMode = AirSIMConnectionMode.automatic
        var lastObservedAppearance = AppAppearance.system
        var lastObservedRelayURL = ""
        var lastObservedLiveActivity = true
        var relayHasDraft = false
        var liveActivityEnabled = true
        var report: CloudSelfTestReport?
        var selfTestRunning = false
        var selfTestCompleted = false
        var message: String?
        var deletingDevice = false
    }
    enum Action {
        case modeChanged(AirSIMConnectionMode), appearanceChanged(AppAppearance), relayChanged(String), liveActivityChanged(Bool)
        case saveRelay, runSelfTest, selfTestUpdated(CloudSelfTestReport), selfTestFinished, disappeared
        case forgetDevice(String), deletionFinished(String?)
    }
    @Dependency(\.airSIM) var client
    enum CancelID { case selfTest }
    var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .modeChanged(let mode): state.mode = mode; state.report = nil; state.selfTestRunning = false; state.selfTestCompleted = false; return .merge(.cancel(id: CancelID.selfTest), .run { [client] _ in try await client.command(.mode(mode)) })
            case .appearanceChanged(let value): state.appearance = value; return .run { [client] _ in try await client.command(.appearance(value)) }
            case .relayChanged(let value): state.relayURL = value; state.relayHasDraft = value != state.lastObservedRelayURL; return .none
            case .liveActivityChanged(let value): state.liveActivityEnabled = value; return .run { [client] _ in try await client.command(.liveActivity(value)) }
            case .saveRelay:
                state.report = nil; state.selfTestRunning = false; state.selfTestCompleted = false; state.message = "URL saved. Registration will complete automatically after pairing."
                return .merge(.cancel(id: CancelID.selfTest), .run { [client, url = state.relayURL] _ in try await client.command(.saveRelay(url)) })
            case .runSelfTest:
                guard !state.selfTestRunning, ConnectionModeRuntimePolicy(mode: state.mode).startsCloud else { return .none }
                state.selfTestRunning = true; state.selfTestCompleted = false; state.report = .initial
                return .run { [client] send in
                    for await report in await client.selfTest() { try Task.checkCancellation(); await send(.selfTestUpdated(report)) }
                    try Task.checkCancellation()
                    await send(.selfTestFinished)
                }.cancellable(id: CancelID.selfTest, cancelInFlight: true)
            case .selfTestUpdated(let report): state.report = report; return .none
            case .selfTestFinished: state.selfTestRunning = false; state.selfTestCompleted = true; return .none
            case .disappeared: state.selfTestRunning = false; return .cancel(id: CancelID.selfTest)
            case .forgetDevice(let id):
                guard !state.deletingDevice else { return .none }; state.deletingDevice = true
                return .run { [client] send in do { try await client.command(.forgetDevice(id)); await send(.deletionFinished(nil)) } catch { await send(.deletionFinished(error.localizedDescription)) } }
            case .deletionFinished(let error): state.deletingDevice = false; state.message = error; return .none
            }
        }
    }
}

@Reducer
struct PairingFeature {
    struct Discovery: Sendable { var services: [SamsungPairingService]; var status: String }
    @ObservableState struct State: Equatable {
        var services: [SamsungPairingService] = []
        var status = "Scanning the local network for VoWLAN…"
        var localOnly = false
        var code = ""
        var pairingID: String?
        var message = ""
    }
    enum Action { case appeared, disappeared, discovery(Discovery), localChanged(Bool), codeChanged(String), pair(SamsungPairingService), result(String) }
    enum CancelID { case discovery, pair }
    @Dependency(\.airSIM) var client
    var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .appeared: return .run { [client] send in for await value in await client.pairing() { await send(.discovery(value)) } }.cancellable(id: CancelID.discovery, cancelInFlight: true)
            case .disappeared: return .cancel(id: CancelID.discovery)
            case .discovery(let value): state.services = value.services; state.status = value.status; return .none
            case .localChanged(let value): guard state.pairingID == nil else { return .none }; state.localOnly = value; return .none
            case .codeChanged(let value): state.code = String(value.filter(\.isNumber).prefix(6)); return .none
            case .pair(let service):
                guard state.code.count == 6, state.pairingID == nil else { return .none }; state.pairingID = service.id
                state.message = state.localOnly ? "Encrypting and saving the local VoWLAN key…" : "Encrypting and saving to the Android Agent…"
                return .run { [client, code = state.code, local = state.localOnly] send in
                    do { await send(.result(try await client.pair(service, code, local))) } catch { await send(.result("Pairing failed: \(error.localizedDescription)")) }
                }.cancellable(id: CancelID.pair)
            case .result(let message): state.pairingID = nil; state.message = message; return .none
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

@Reducer
struct AirSIMFeature {
    @ObservableState struct State: Equatable {
        var snapshot = AirSIMSnapshot()
        var dialNumber = ""
        var lastBackendNumber = ""
        var hasDialDraft = false
        var selectedTab = PhoneTab.dial
        var firstConnectionComplete = false
        var messages = MessagesFeature.State()
        var settings = SettingsFeature.State()
        var pairing = PairingFeature.State()
        var recordings = RecordingsFeature.State()
        var trace = TraceFeature.State()
        var contactSearch = ""
        var contactPickerSearch = ""
        var keypadDigits = ""
        var keypadPresented = false
        var agentsPresented = false
        var selectedRecentCallID: String?
    }
    enum Action {
        case start, stop, snapshot(AirSIMSnapshot), selectTab(PhoneTab), completeOnboarding
        case numberChanged(String), command(AirSIMCommand), commandFailed(String)
        case openURL(URL), openSMS(String), contactSearchChanged(String), keypad(Bool), dtmf(String), agents(Bool), recentDetails(String?)
        case contactPickerSearchChanged(String)
        case messages(MessagesFeature.Action), settings(SettingsFeature.Action), pairing(PairingFeature.Action)
        case recordings(RecordingsFeature.Action), trace(TraceFeature.Action)
    }
    enum CancelID { case snapshot }
    @Dependency(\.airSIM) var client
    var body: some ReducerOf<Self> {
        Scope(state: \.messages, action: \.messages) { MessagesFeature() }
        Scope(state: \.settings, action: \.settings) { SettingsFeature() }
        Scope(state: \.pairing, action: \.pairing) { PairingFeature() }
        Scope(state: \.recordings, action: \.recordings) { RecordingsFeature() }
        Scope(state: \.trace, action: \.trace) { TraceFeature() }
        Reduce { state, action in
            switch action {
            case .start: return .run { [client] send in for await value in await client.snapshots() { await send(.snapshot(value)) } }.cancellable(id: CancelID.snapshot, cancelInFlight: true)
            case .stop: return .cancel(id: CancelID.snapshot)
            case .snapshot(let value):
                state.snapshot = value; state.recordings.playingID = value.playingRecordingID
                if value.preferenceMode != state.settings.lastObservedMode { state.settings.mode = value.preferenceMode; state.settings.lastObservedMode = value.preferenceMode }
                if value.preferenceAppearance != state.settings.lastObservedAppearance { state.settings.appearance = value.preferenceAppearance; state.settings.lastObservedAppearance = value.preferenceAppearance }
                if value.preferenceLiveActivity != state.settings.lastObservedLiveActivity { state.settings.liveActivityEnabled = value.preferenceLiveActivity; state.settings.lastObservedLiveActivity = value.preferenceLiveActivity }
                if value.preferenceRelayURL != state.settings.lastObservedRelayURL {
                    if !state.settings.relayHasDraft { state.settings.relayURL = value.preferenceRelayURL }
                    state.settings.lastObservedRelayURL = value.preferenceRelayURL
                }
                if value.preferenceRelayURL == state.settings.relayURL { state.settings.relayHasDraft = false }
                if value.preferenceOnboardingComplete { state.firstConnectionComplete = true }
                if value.numberInput != state.lastBackendNumber {
                    state.lastBackendNumber = value.numberInput
                    if !state.hasDialDraft { state.dialNumber = value.numberInput }
                }
                if value.numberInput == state.dialNumber { state.hasDialDraft = false }
                if value.callLifecycleSnapshot.state.representsCall, value.playingRecordingID != nil { return .send(.recordings(.stop(false))) }
                return .none
            case .selectTab(let tab): state.selectedTab = tab; return .run { [client] _ in try await client.command(.persistTab(tab)) }
            case .completeOnboarding: state.firstConnectionComplete = true; return .run { [client] _ in try await client.command(.completeOnboarding) }
            case .numberChanged(let value): state.dialNumber = value; state.hasDialDraft = value != state.lastBackendNumber; return .none
            case .command(let command):
                if case .clearError = command { state.snapshot.errorMessage = nil }
                return .run { [client] send in do { try await client.command(command) } catch { await send(.commandFailed(error.localizedDescription)) } }
            case .commandFailed(let error): state.snapshot.errorMessage = error; return .none
            case .openSMS(let sender): state.selectedTab = .messages; return .merge(.send(.messages(.openConversation(sender))), .send(.command(.reloadLocalMessages)))
            case .openURL(let url):
                switch SystemCommunicationURL.destination(for: url) {
                case .message(let recipient): state.selectedTab = .messages; return .send(.messages(.compose(recipient)))
                case .call(let number): state.selectedTab = .dial; state.dialNumber = number; state.hasDialDraft = true; return .run { [client] _ in try await client.command(.dialNumber(number)) }
                case let .liveActivity(action, callID):
                    // The backend gate runs immediately before execution. The UI
                    // projection can lag cold-launch adoption or a new call.
                    return .send(.command(.liveActivityAction(action, callID: callID)))
                case nil: return .none
                }
            case .contactSearchChanged(let value): state.contactSearch = value; return .none
            case .contactPickerSearchChanged(let value): state.contactPickerSearch = value; return .none
            case .keypad(let presented): state.keypadPresented = presented; if presented { state.keypadDigits = "" }; return .none
            case .dtmf(let digit): state.keypadDigits = String((state.keypadDigits + digit).suffix(18)); return .send(.command(.dtmf(digit)))
            case .agents(let value): state.agentsPresented = value; return .none
            case .recentDetails(let id): state.selectedRecentCallID = id; return .none
            case .messages(.clearError): state.snapshot.errorMessage = nil; return .none
            case .messages, .settings, .pairing, .recordings, .trace: return .none
            }
        }
    }
}

/// UIKit's read-only projection of a Store. Mutations send reducer actions; no
/// controller owns or receives the backend AppModel reference.
@MainActor
final class AirSIMPresentation {
    let store: StoreOf<AirSIMFeature>
    init(model: AppModel, settings: AppSettings) {
        let playback = CallRecordingPlayback()
        var state = AirSIMFeature.State()
        state.snapshot = AirSIMSnapshot(model: model, settings: settings, playback: playback)
        state.dialNumber = model.numberInput
        state.lastBackendNumber = model.numberInput
        state.settings.mode = ConnectionModePreference.selected()
        state.pairing.localOnly = LocalModePreference.isEnabled()
        state.firstConnectionComplete = UserDefaults.standard.bool(forKey: "airsim.first-connection-complete")
        state.selectedTab = PhoneTab(rawValue: UserDefaults.standard.string(forKey: "airsim.selected-tab") ?? "") ?? .dial
        state.settings.appearance = settings.appearance
        state.settings.relayURL = RelayConfiguration.effectiveURL(stored: UserDefaults.standard.string(forKey: "airsim.push-relay-url"), buildSetting: Bundle.main.object(forInfoDictionaryKey: "AirSIMPushRelayURL") as? String, bundleID: Bundle.main.bundleIdentifier)
        state.settings.liveActivityEnabled = LiveActivityVisibilityPreference.isEnabled()
        state.settings.lastObservedMode = state.settings.mode
        state.settings.lastObservedAppearance = state.settings.appearance
        state.settings.lastObservedRelayURL = state.settings.relayURL
        state.settings.lastObservedLiveActivity = state.settings.liveActivityEnabled
        store = Store(initialState: state) { AirSIMFeature() } withDependencies: { $0.airSIM = .live(model: model, settings: settings, playback: playback) }
        store.send(.start)
    }
    init(store: StoreOf<AirSIMFeature>) { self.store = store }
    var snapshot: AirSIMSnapshot { store.snapshot }
    var numberInput: String { get { store.dialNumber } set { store.send(.numberChanged(newValue)) } }
    var errorMessage: String? { get { snapshot.errorMessage } set { if newValue == nil { store.send(.command(.clearError)) } } }
    var contacts: ContactsPresentation { ContactsPresentation(owner: self) }
    var audio: AudioPresentation { AudioPresentation(owner: self) }
    var vowlan: VoWLANPresentation { VoWLANPresentation(owner: self) }
    var recordings: RecordingsPresentation { RecordingsPresentation(owner: self) }
    var settings: SettingsPresentation { SettingsPresentation(owner: self) }
    var callHistory: [CallRecord] { snapshot.callHistory }
    var isRefreshingCallHistory: Bool { snapshot.isRefreshingCallHistory }
    var callHistoryMessage: String? { snapshot.callHistoryMessage }
    var messages: [SMSMessage] { snapshot.messages }
    var conversations: [(sender: String, messages: [SMSMessage])] { snapshot.conversations.map { ($0.sender, $0.messages) } }
    var isOnline: Bool { snapshot.isOnline }
    var connectionMessage: String? { snapshot.connectionMessage }
    var isBusy: Bool { snapshot.isBusy }
    var isMuted: Bool { snapshot.isMuted }
    var isRecording: Bool { snapshot.isRecording }
    var isRecordingBusy: Bool { snapshot.isRecordingBusy }
    var modemStatus: ModemStatus? { snapshot.modemStatus }
    var cloudAgentStatus: CloudAgentStatus? { snapshot.cloudAgentStatus }
    var cloudCallAudioState: CloudCallAudioState { snapshot.cloudCallAudioState }
    var callLifecycleSnapshot: CallLifecycleSnapshot { snapshot.callLifecycleSnapshot }
    var inAppPresentedCall: CallRecord? { snapshot.inAppPresentedCall }
    var callAudioIsActive: Bool { snapshot.callAudioIsActive }
    var callAudioStatusText: String { snapshot.callAudioStatusText }
    var canStartOutgoingCommand: Bool { snapshot.canStartOutgoingCommand }
    var canToggleRecording: Bool { snapshot.canToggleRecording }
    var connectionModePresentation: ConnectionModePresentation { snapshot.connectionModePresentation }
    var pairedAndroidAgents: [AndroidAgentPresentation] { snapshot.pairedAndroidAgents }
    var currentAndroidAgent: AndroidAgentPresentation? { snapshot.currentAndroidAgent }
    var pairedDeviceHistory: [AndroidAgentPresentation] { snapshot.pairedDeviceHistory }
    func perform(_ command: AirSIMCommand) async { await store.send(.command(command)).finish() }
    func dial() async { await perform(.dialNumber(store.dialNumber)) }
    func answer() async { await perform(.answer) }
    func reject() async { await perform(.reject) }
    func hangup() async { await perform(.hangup) }
    func toggleMute() async { await perform(.mute) }
    func toggleSpeaker() { store.send(.command(.speaker)) }
    func toggleRecording() async { await perform(.recording) }
    func sendDTMF(_ digit: String) async { await store.send(.dtmf(digit)).finish() }
    func bindAndroidAgent(_ id: String) { store.send(.command(.bindAgent(id))) }
    func refreshCallHistory() async { await perform(.refreshHistory) }
    func deleteCallHistory(ids: [String]) { store.send(.command(.deleteHistory(ids))) }
    func refreshMessages() async { await perform(.refreshMessages) }
    func loadMessagesFromAgent(silently: Bool) async { await perform(.loadMessages) }
    func reloadMessagesFromLocalStore() { store.send(.command(.reloadLocalMessages)) }
    func clearLocalMessages() { store.send(.command(.clearMessages)) }
    func refreshPairedDeviceInformation() async { await perform(.refreshDevices) }
    func setConnectionMode(_ mode: AirSIMConnectionMode) { store.send(.settings(.modeChanged(mode))) }
    func setLiveActivityEnabled(_ enabled: Bool) { store.send(.settings(.liveActivityChanged(enabled))) }
    func presentCurrentCallInApp() { store.send(.command(.presentCall)) }
}

@MainActor
struct ContactsPresentation {
    let owner: AirSIMPresentation
    var contacts: [ContactStore.Contact] { owner.snapshot.contacts }
    var isAuthorized: Bool { owner.snapshot.contactsAuthorized }
    var authorizationState: ContactAuthorizationState { owner.snapshot.contactsAuthorization }
    func contact(for number: String) -> ContactStore.Contact? {
        let target = ContactStore.normalized(number)
        guard !target.isEmpty else { return nil }
        if let exact = contacts.first(where: { $0.phones.contains(target) }) { return exact }
        guard target.count >= 7 else { return nil }
        return contacts.first { $0.phones.contains { $0.count >= 7 && $0.hasSuffix(target.suffix(7)) } }
    }
    func displayName(for number: String?) -> String {
        guard let number, !number.isEmpty else { return "Unknown Number" }
        return contact(for: number)?.name ?? number
    }
    func loadIfAuthorized() async { await owner.perform(.contacts(false)) }
    func requestAccessAndLoad() async { await owner.perform(.contacts(true)) }
}
@MainActor
struct AudioPresentation {
    let owner: AirSIMPresentation
    var active: Bool { owner.snapshot.audioActive }
    var speakerEnabled: Bool { owner.snapshot.speakerEnabled }
    var routeDescription: String { owner.snapshot.audioRoute }
    var errorMessage: String? { owner.snapshot.audioError }
}
@MainActor
struct VoWLANPresentation {
    let owner: AirSIMPresentation
    var availability: VoWLANAvailability { owner.snapshot.vowlan }
}
@MainActor
struct RecordingsPresentation {
    let owner: AirSIMPresentation
    var recordings: [CallRecordingFile] { owner.snapshot.recordings }
    var isBusy: Bool { owner.snapshot.recordingsBusy }
    func reload() async { await owner.perform(.reloadRecordings) }
}
@MainActor
struct SettingsPresentation {
    let owner: AirSIMPresentation
    var appearance: AppAppearance { get { owner.store.settings.appearance } nonmutating set { owner.store.send(.settings(.appearanceChanged(newValue))) } }
}

@Reducer
struct RecordingsFeature {
    @ObservableState struct State: Equatable { var playingID: UUID?; var error: String? }
    enum Action { case play(CallRecordingFile), stop(Bool), delete(CallRecordingFile), reload, failed(String), clearError }
    @Dependency(\.airSIM) var client
    var body: some ReducerOf<Self> {
        Reduce { state, action in
            let command: AirSIMCommand
            switch action {
            case .play(let file): command = .play(file)
            case .stop(let deactivate): command = .stopPlayback(deactivate)
            case .delete(let file): command = .deleteRecording(file)
            case .reload: command = .reloadRecordings
            case .failed(let error): state.error = error; return .none
            case .clearError: state.error = nil; return .none
            }
            return .run { [client] send in do { try await client.command(command) } catch { await send(.failed(error.localizedDescription)) } }
        }
    }
}

@Reducer
struct TraceFeature {
    @ObservableState
    struct State: Equatable {
        var data = AgentVerboseTraceData()
        var filter = AgentVerboseTraceFilter.all
        var refreshing = false
        var refreshID = 0
        var pendingClear = false
        var pendingEnabled: Bool?
    }
    enum Action {
        case appeared, disappeared, refresh, clear
        case refreshed(id: Int, AgentVerboseTraceData)
        case filterChanged(AgentVerboseTraceFilter), enabledChanged(Bool)
    }
    enum CancelID { case timer, refresh }
    @Dependency(\.airSIM) var client
    @Dependency(\.continuousClock) var clock
    var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .appeared:
                return .merge(.send(.refresh), .run { [clock] send in
                    while !Task.isCancelled { try await clock.sleep(for: .seconds(1)); await send(.refresh) }
                }.cancellable(id: CancelID.timer, cancelInFlight: true))
            case .disappeared:
                state.refreshing = false
                state.refreshID += 1
                return .merge(.cancel(id: CancelID.timer), .cancel(id: CancelID.refresh))
            case .clear:
                state.pendingClear = true
                return state.refreshing ? .none : .send(.refresh)
            case .enabledChanged(let enabled):
                state.data.enabled = enabled
                state.pendingEnabled = enabled
                return state.refreshing ? .none : .send(.refresh)
            case .refresh:
                guard !state.refreshing else { return .none }
                state.refreshing = true
                state.refreshID += 1
                let clear = state.pendingClear
                let enabled = state.pendingEnabled
                state.pendingClear = false
                state.pendingEnabled = nil
                // Serialize reads, clears and preference writes. A user command during a
                // slow poll is queued, rather than discarded or overwritten by that poll.
                return .run { [client, data = state.data, id = state.refreshID] send in
                    if let enabled { await client.traceEnabled(enabled) }
                    try Task.checkCancellation()
                    let refreshed = await client.traceRefresh(data, clear)
                    try Task.checkCancellation()
                    await send(.refreshed(id: id, refreshed))
                }.cancellable(id: CancelID.refresh)
            case let .refreshed(id, data):
                guard state.refreshing, id == state.refreshID else { return .none }
                state.data = data
                if let enabled = state.pendingEnabled { state.data.enabled = enabled }
                state.refreshing = false
                return state.pendingClear || state.pendingEnabled != nil ? .send(.refresh) : .none
            case .filterChanged(let filter):
                state.filter = filter
                return .none
            }
        }
    }
}
