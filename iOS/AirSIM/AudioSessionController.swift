import AVFoundation
import WebRTC

enum VoWLANAudioPlan {
    static let controlPath = "/api/calls/webrtc"
    static let usesHostICE = true
    static let opensNetworkPCM = false

    static func offerJSON(callUUID: UUID, generation: UInt64, sessionID: UUID, sdp: String) -> String {
        let escaped = sdp
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return #"{"action":"webrtc_offer","call_uuid":"\#(callUUID.uuidString.lowercased())","generation":\#(generation),"session_id":"\#(sessionID.uuidString.lowercased())","sdp":"\#(escaped)"}"#
    }
}

/// Local media has no socket or sample transport. The legacy route fails closed.
enum LocalWebRTCRoute: Equatable, Sendable {
    case moduleLocal
    case vowlan(endpoint: VoWLANEndpoint, credential: VoWLANCredential)
}

struct VoWLANWebRTCSession: Encodable, Equatable, Sendable {
    let version: Int = 1
    let callUUID: UUID
    let generation: UInt64
    let sessionID: UUID
    enum CodingKeys: String, CodingKey {
        case version, generation
        case callUUID = "call_uuid"
        case sessionID = "session_id"
    }
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(version, forKey: .version)
        try values.encode(callUUID.uuidString.lowercased(), forKey: .callUUID)
        try values.encode(generation, forKey: .generation)
        try values.encode(sessionID.uuidString.lowercased(), forKey: .sessionID)
    }
}

struct VoWLANWebRTCStatus: Decodable, Equatable, Sendable {
    enum State: String, Decodable, Sendable { case preparing, ready, failed, closed }
    let version: Int
    let callUUID: UUID
    let generation: UInt64
    let sessionID: UUID
    let status: State
    let reason: String?
    enum CodingKeys: String, CodingKey {
        case version, generation, status, reason
        case callUUID = "call_uuid"
        case sessionID = "session_id"
    }
    func matches(_ session: VoWLANWebRTCSession) -> Bool {
        version == session.version && callUUID == session.callUUID
            && generation == session.generation && sessionID == session.sessionID
    }
}

enum SpeakerRoutePolicy {
    static let retryDelays: [TimeInterval] = [0, 0.15, 0.35, 0.7, 1.2]
    static let routeVerificationDelay: TimeInterval = 0.08

    static func toggledTarget(
        currentRouteIsSpeaker: Bool,
        pendingTarget: Bool? = nil
    ) -> Bool {
        !(pendingTarget ?? currentRouteIsSpeaker)
    }

    static func routeMatches(requestedSpeaker: Bool, currentRouteIsSpeaker: Bool) -> Bool {
        requestedSpeaker == currentRouteIsSpeaker
    }

    static func requestedSpeakerAfterSystemRouteChange(
        requestedSpeaker: Bool,
        observedRouteIsSpeaker: Bool
    ) -> Bool {
        // observedRouteIsSpeaker is deliberately not adopted: CallKit can briefly expose the
        // previous playback route while activating a new call. Only the user's button changes
        // the requested override.
        _ = observedRouteIsSpeaker
        return requestedSpeaker
    }
}

/// Owns the local native WebRTC call, including authenticated carrier readiness.
@MainActor
@Observable
final class AudioSessionController {
    private(set) var active = false
    private(set) var routeDescription = ""
    private(set) var transportReady = false
    private(set) var diagnosticDescription = ""
    private(set) var moduleDiagnosticDescription = ""
    private(set) var speakerEnabled = false
    private(set) var speakerRoutePending = false
    var errorMessage: String?

    @ObservationIgnored private var vowlanPeer: CloudWebRTCPeer?
    @ObservationIgnored private var localSession: VoWLANWebRTCSession?
    @ObservationIgnored private var localAPI: AirSIMAPI?
    @ObservationIgnored private var localReadiness = CloudWebRTCReadiness()
    @ObservationIgnored private var signalingTask: Task<Void, Never>?
    @ObservationIgnored private var statusTask: Task<Void, Never>?
    @ObservationIgnored private var startupTimeoutTask: Task<Void, Never>?
    @ObservationIgnored private var activationID = UUID()
    var recordingSource: CallRecordingSource? {
        guard transportReady, let localSession else { return nil }
        return .init(callUUID: localSession.callUUID)
    }
    @ObservationIgnored private let vowlanQueue = DispatchQueue(label: "com.example.airsim.vowlan-webrtc")
    @ObservationIgnored private var callTonePlayer: AVAudioPlayer?
    @ObservationIgnored private var currentCallTone: CallTone?
    @ObservationIgnored private var muted = false
    @ObservationIgnored private var requestedSpeakerOverride = false
    @ObservationIgnored private var speakerRouteRetryTask: Task<Void, Never>?
    @ObservationIgnored private var sessionActivationManagedByCallKit = false
    @ObservationIgnored private var ownsWebRTCAudioActivation = false
    @ObservationIgnored private var routeChangeObserver: NSObjectProtocol?

    init() {
        // CallKit, Bluetooth, or Control Center may change the output route; button state must follow the actual audio session.
        routeChangeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor [weak self] in self?.handleRouteChange(notification) }
        }
    }

    deinit {
        if let routeChangeObserver {
            NotificationCenter.default.removeObserver(routeChangeObserver)
        }
    }

    var microphonePermissionIsUndetermined: Bool {
        AVAudioApplication.shared.recordPermission == .undetermined
    }

    func requestMicrophonePermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    @discardableResult
    func activateForCall(
        route: LocalWebRTCRoute = .moduleLocal,
        sessionAlreadyActive: Bool = false,
        callUUID: UUID = UUID(),
        generation: UInt64 = 1
    ) async -> Bool {
        guard !active else { return true }
        guard case .vowlan = route else {
            errorMessage = APIError.disabledLegacyRoute.localizedDescription
            return false
        }
        let attempt = UUID()
        activationID = attempt
        let permission = await requestMicrophonePermission()
        guard activationID == attempt, !Task.isCancelled else { return false }
        guard permission else {
            errorMessage = "Microphone access is required for two-way calls"
            return false
        }

        do {
            let session = AVAudioSession.sharedInstance()
            sessionActivationManagedByCallKit = sessionAlreadyActive
            try configureCallAudioSession()
            if !sessionAlreadyActive {
                let rtc = RTCAudioSession.sharedInstance()
                rtc.useManualAudio = true
                rtc.lockForConfiguration()
                defer { rtc.unlockForConfiguration() }
                try rtc.setActive(true)
                ownsWebRTCAudioActivation = true
            }
            // Default to the receiver for every call; override the output route only after the user explicitly enables the speaker.
            try session.overrideOutputAudioPort(requestedSpeakerOverride ? .speaker : .none)
            refreshRouteDescription()
            switch route {
            case .moduleLocal:
                throw APIError.disabledLegacyRoute
            case let .vowlan(endpoint, credential):
                guard VoWLANAudioPlan.usesHostICE, !VoWLANAudioPlan.opensNetworkPCM else {
                    throw APIError.disabledLegacyRoute
                }
                try startVoWLANWebRTC(
                    endpoint: endpoint,
                    credential: credential,
                    callUUID: callUUID,
                    generation: max(1, generation)
                )
            }
            active = true
            transportReady = false
            routeDescription = "Connecting VoWLAN WebRTC…"
            diagnosticDescription = "\(DeviceContext.displayName) WebRTC offer pending"
            moduleDiagnosticDescription = ""
            errorMessage = nil
            retryRequestedSpeakerRoute()
            return true
        } catch {
            deactivate()
            errorMessage = "Unable to enable call audio: \(error.localizedDescription)"
            return false
        }
    }

    private func startVoWLANWebRTC(
        endpoint: VoWLANEndpoint,
        credential: VoWLANCredential,
        callUUID: UUID,
        generation: UInt64
    ) throws {
        let api = AirSIMAPI(route: .vowlan(endpoint: endpoint, credential: credential))
        let identity = VoWLANWebRTCSession(callUUID: callUUID, generation: generation, sessionID: UUID())
        localSession = identity
        localAPI = api
        localReadiness.begin(identity.sessionID)
        let rtc = RTCAudioSession.sharedInstance()
        rtc.useManualAudio = true
        rtc.isAudioEnabled = true
        let queue = vowlanQueue
        let peer = try queue.sync {
            try CloudWebRTCPeer(
                callUUID: callUUID, generation: generation, sessionID: identity.sessionID,
                servers: [], queue: queue, hostOnly: true,
                signal: { [weak self] signal in
                    Task { @MainActor [weak self] in
                        guard let self, self.localSession == identity else { return }
                        self.signalingTask = Task { @MainActor [weak self] in
                            do {
                                let answer = try await api.exchangeVoWLANWebRTC(signal)
                                guard let self, !Task.isCancelled, self.localSession == identity,
                                      let peer = self.vowlanPeer else { return }
                                guard answer.isValid, answer.action == .answer,
                                      answer.callUUID == identity.callUUID,
                                      answer.generation == identity.generation,
                                      answer.sessionID == identity.sessionID else {
                                    self.failLocalSession(identity, message: "Invalid VoWLAN WebRTC answer")
                                    return
                                }
                                queue.async { peer.receive(answer) }
                                self.pollLocalReadiness(identity, api: api)
                            } catch {
                                guard !Task.isCancelled else { return }
                                self?.failLocalSession(identity, message: "VoWLAN WebRTC signaling failed")
                            }
                        }
                    }
                }, connected: { [weak self] in
                    Task { @MainActor [weak self] in
                        guard let self, self.localSession == identity else { return }
                        self.localReadiness.nativeConnected(identity.sessionID)
                        self.publishLocalReadiness()
                    }
                }, disconnected: { [weak self] in
                    Task { @MainActor [weak self] in
                        guard let self, self.localSession == identity else { return }
                        self.localReadiness.nativeDisconnected(identity.sessionID)
                        self.publishLocalReadiness()
                    }
                }, failure: { [weak self] in
                    Task { @MainActor [weak self] in
                        self?.failLocalSession(identity, message: "VoWLAN WebRTC failed")
                    }
                }, statistics: { _ in }
            )
        }
        vowlanPeer = peer
        let initiallyMuted = muted
        queue.async { peer.setMuted(initiallyMuted); peer.offer() }
        startupTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled, let self, self.localSession == identity,
                  !self.localReadiness.isReady else { return }
            self.failLocalSession(identity, message: "Android call audio was not ready within 30 seconds")
        }
    }

    private func pollLocalReadiness(_ identity: VoWLANWebRTCSession, api: AirSIMAPI) {
        statusTask?.cancel()
        statusTask = Task { @MainActor [weak self] in
            var lastResponse = ProcessInfo.processInfo.systemUptime
            var unreadySince: TimeInterval? = lastResponse
            while !Task.isCancelled {
                guard let self, self.localSession == identity else { return }
                do {
                    let status = try await api.voWLANWebRTCStatus(identity)
                    guard !Task.isCancelled, self.localSession == identity else { return }
                    guard status.matches(identity) else {
                        self.failLocalSession(identity, message: "VoWLAN audio session changed")
                        return
                    }
                    lastResponse = ProcessInfo.processInfo.systemUptime
                    switch status.status {
                    case .ready: self.localReadiness.agentConnected(identity.sessionID)
                    case .preparing: self.localReadiness.agentRecovering()
                    case .failed, .closed:
                        self.failLocalSession(identity, message: "Android call audio is unavailable")
                        return
                    }
                    self.publishLocalReadiness()
                } catch {
                    guard !Task.isCancelled, self.localSession == identity else { return }
                    self.localReadiness.agentRecovering()
                    self.publishLocalReadiness()
                    if ProcessInfo.processInfo.systemUptime - lastResponse >= 30 {
                        self.failLocalSession(identity, message: "Android audio status timed out")
                        return
                    }
                }
                let now = ProcessInfo.processInfo.systemUptime
                if self.localReadiness.isReady {
                    unreadySince = nil
                } else if let since = unreadySince {
                    if now - since >= 30 {
                        self.failLocalSession(identity, message: "Android call audio readiness timed out")
                        return
                    }
                } else {
                    unreadySince = now
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    private func publishLocalReadiness() {
        transportReady = localReadiness.isReady
        routeDescription = transportReady ? "VoWLAN WebRTC" : "Connecting VoWLAN WebRTC…"
        diagnosticDescription = transportReady
            ? "WebRTC and Android carrier audio ready"
            : "Waiting for WebRTC and Android carrier audio"
        if transportReady {
            startupTimeoutTask?.cancel()
            startupTimeoutTask = nil
            errorMessage = nil
        }
    }

    private func failLocalSession(_ identity: VoWLANWebRTCSession, message: String) {
        guard localSession == identity else { return }
        closeLocalPeer()
        transportReady = false
        routeDescription = "VoWLAN WebRTC unavailable"
        diagnosticDescription = "VoWLAN WebRTC unavailable"
        errorMessage = message
        // Keep the cellular call under user control. Do not silently fall back,
        // redial, or hang up an inbound call because its remote audio failed.
    }

    private func closeLocalPeer() {
        activationID = UUID()
        let previous = localSession
        let api = localAPI
        localSession = nil
        localAPI = nil
        localReadiness.reset()
        signalingTask?.cancel(); signalingTask = nil
        statusTask?.cancel(); statusTask = nil
        startupTimeoutTask?.cancel(); startupTimeoutTask = nil
        if let peer = vowlanPeer { vowlanQueue.async { peer.close() } }
        vowlanPeer = nil
        if let previous, let api {
            Task { try? await api.stopVoWLANWebRTC(previous) }
        }
    }

    /// Declares the voice category before CallKit executes an action; actual activation happens when the system invokes didActivate.
    func prepareForCallKit() throws {
        resetSpeakerPreferenceForNewCall()
        let rtc = RTCAudioSession.sharedInstance()
        rtc.useManualAudio = true
        rtc.isAudioEnabled = false
        try configureCallAudioSession()
        try AVAudioSession.sharedInstance().overrideOutputAudioPort(.none)
        sessionActivationManagedByCallKit = true
    }

    func setMuted(_ muted: Bool) {
        CallAudioRecorder.shared.setMuted(muted)
        self.muted = muted
        if let peer = vowlanPeer { vowlanQueue.async { peer.setMuted(muted) } }
    }

    /// Plays the incoming ringtone or outgoing ringback tone based on module call state, yielding immediately to native WebRTC once connected.
    func updateCallTone(for call: CallRecord?) {
        guard !active else {
            stopCallTone()
            return
        }
        guard let call else {
            // Settings ringtone preview is not part of call state; idle polling must not stop it early.
            if case .preview? = currentCallTone { return }
            stopCallTone()
            return
        }

        if call.direction == "incoming", ["incoming", "waiting"].contains(call.state) {
            let ringtone = UserDefaults.standard.string(forKey: "airsim.ringtone") ?? "Hero"
            playCallTone(.incoming(ringtone), looping: true)
        } else if call.direction != "incoming", ["dialing", "alerting"].contains(call.state) {
            playCallTone(.outgoingWaiting, looping: true)
        } else {
            stopCallTone()
        }
    }

    /// Previews the ringtone once in Settings rather than looping indefinitely like a real incoming call.
    func previewRingtone(named ringtone: String) {
        guard !active else { return }
        playCallTone(.preview(ringtone), looping: false)
    }

    func stopRingtonePreview() {
        guard case .preview? = currentCallTone else { return }
        stopCallTone()
    }

    func stopCallTone(deactivateSession: Bool = true) {
        let hadTone = callTonePlayer != nil || currentCallTone != nil
        callTonePlayer?.stop()
        callTonePlayer = nil
        currentCallTone = nil
        // Idle polling calls this method repeatedly; never deactivate the session used by background standby when no ringtone is playing.
        // After CallKit invokes didActivate, the audio session may only be deactivated by the system.
        guard hadTone, deactivateSession, !active, !sessionActivationManagedByCallKit else { return }
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
        )
    }

    /// Toggles the output route for the current call; turning off the speaker hands routing back to the system to select the receiver or connected Bluetooth device.
    func setSpeakerEnabled(_ enabled: Bool) {
        requestedSpeakerOverride = enabled
        speakerRoutePending = !SpeakerRoutePolicy.routeMatches(
            requestedSpeaker: enabled,
            currentRouteIsSpeaker: speakerEnabled
        )
        retryRequestedSpeakerRoute()
    }

    func toggleSpeakerRoute() {
        let pendingTarget = speakerRoutePending ? requestedSpeakerOverride : nil
        setSpeakerEnabled(SpeakerRoutePolicy.toggledTarget(
            currentRouteIsSpeaker: speakerEnabled,
            pendingTarget: pendingTarget
        ))
    }

    func resetSpeakerPreferenceForNewCall() {
        speakerRouteRetryTask?.cancel()
        speakerRouteRetryTask = nil
        requestedSpeakerOverride = false
        speakerRoutePending = false
        refreshRouteDescription()
    }

    /// A brief window exists between CallKit didActivate and AVAudioEngine actually starting.
    /// Switching routes during this window returns OSStatus -50, so preserve the user selection and retry with a bounded count.
    func retryRequestedSpeakerRoute() {
        let requested = requestedSpeakerOverride
        speakerRouteRetryTask?.cancel()
        speakerRouteRetryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if requestedSpeakerOverride == requested {
                    speakerRoutePending = false
                    speakerRouteRetryTask = nil
                }
            }
            for delay in SpeakerRoutePolicy.retryDelays {
                guard !Task.isCancelled, requestedSpeakerOverride == requested else { return }
                if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
                guard !Task.isCancelled, requestedSpeakerOverride == requested else { return }
                do {
                    try AVAudioSession.sharedInstance().overrideOutputAudioPort(
                        requested ? .speaker : .none
                    )
                    // API return only indicates the system accepted the request; currentRoute updates asynchronously.
                    // Wait for a brief confirmation window before updating button highlight from the actual output port.
                    try? await Task.sleep(for: .seconds(SpeakerRoutePolicy.routeVerificationDelay))
                    guard !Task.isCancelled, requestedSpeakerOverride == requested else { return }
                    refreshRouteDescription()
                    if SpeakerRoutePolicy.routeMatches(
                        requestedSpeaker: requested,
                        currentRouteIsSpeaker: speakerEnabled
                    ) {
                        return
                    }
                } catch {
                    // Preserve the selection while the audio session has not yet been activated by CallKit and wait for the next short retry.
                }
            }
            refreshRouteDescription()
        }
    }

    /// Aggregate carrier-device diagnostics are not the session readiness signal.
    func updateModuleDiagnostics(_ config: MaVoAudioHostConfig) {
        var details: [String] = []
        if let routeError = config.routeError, !routeError.isEmpty {
            details.append("Module audio bridge error: \(routeError)")
        } else if config.routeRunning != true {
            details.append("Android carrier audio has not started")
        } else if config.routeSessionReady == false || config.routeReady == false {
            details.append("Module audio route is not ready")
        }
        if let statistics = config.statistics, config.statisticsAvailable == true {
            details.append("D5 ↑\(statistics.uplinkBytes)B peak \(statistics.uplinkPeak) · D6 ↓\(statistics.downlinkBytes)B peak \(statistics.downlinkPeak)")
        } else if config.routeRunning == true {
            details.append("Android carrier audio started, waiting for statistics")
        }
        // Show only the last log line to preserve the root startup failure reason without flooding the call screen.
        if let lastLog = config.logTail?.last, !lastLog.isEmpty {
            details.append("Log: \(lastLog)")
        }
        moduleDiagnosticDescription = details.joined(separator: "; ")
    }

    func deactivate() {
        let callKitManagedSession = sessionActivationManagedByCallKit
        muted = false
        requestedSpeakerOverride = false
        speakerRouteRetryTask?.cancel()
        speakerRouteRetryTask = nil
        speakerRoutePending = false
        stopCallTone()
        sessionActivationManagedByCallKit = false
        let ownedLocalAudio = active || localSession != nil || vowlanPeer != nil || ownsWebRTCAudioActivation
        closeLocalPeer()
        if ownedLocalAudio { RTCAudioSession.sharedInstance().isAudioEnabled = false }
        if ownsWebRTCAudioActivation {
            ownsWebRTCAudioActivation = false
            let rtc = RTCAudioSession.sharedInstance()
            rtc.lockForConfiguration()
            try? rtc.setActive(false)
            rtc.unlockForConfiguration()
        }
        do {
            let session = AVAudioSession.sharedInstance()
            // Clear the speaker override for this call so it does not affect the next call or other apps.
            try session.overrideOutputAudioPort(.none)
            if ownedLocalAudio, !callKitManagedSession {
                try session.setActive(
                    false,
                    options: .notifyOthersOnDeactivation
                )
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        active = false
        transportReady = false
        routeDescription = ""
        diagnosticDescription = ""
        moduleDiagnosticDescription = ""
        refreshRouteDescription()
    }

    private func playCallTone(_ tone: CallTone, looping: Bool) {
        guard currentCallTone != tone || callTonePlayer?.isPlaying != true else { return }
        stopCallTone()

        do {
            let session = AVAudioSession.sharedInstance()
            // Module incoming calls are phone alerts; use .playback so they remain audible in silent mode and duck other audio.
            try session.setCategory(.playback, mode: .default, options: [.duckOthers])
            try session.setActive(true)
            let player = try AVAudioPlayer(data: SynthesizedCallTone.wavData(for: tone))
            player.numberOfLoops = looping ? -1 : 0
            player.volume = tone.volume
            player.prepareToPlay()
            guard player.play() else { throw VoiceAudioError.tonePlaybackFailed }
            callTonePlayer = player
            currentCallTone = tone
        } catch {
            callTonePlayer = nil
            currentCallTone = nil
            errorMessage = "Unable to play call tone: \(error.localizedDescription)"
        }
    }

    private func configureCallAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        // .voiceChat uses VoiceProcessingIO to provide system echo cancellation for both receiver and speaker calls.
        try session.setCategory(
            .playAndRecord,
            mode: .voiceChat,
            options: [.allowBluetoothHFP]
        )
        try session.setPreferredSampleRate(48_000)
        try session.setPreferredIOBufferDuration(0.02)
    }

    private func refreshRouteDescription() {
        let session = AVAudioSession.sharedInstance()
        let input = session.currentRoute.inputs.map { "\($0.portName)[\($0.portType.rawValue)]" }.joined(separator: ", ")
        let output = session.currentRoute.outputs.map { "\($0.portName)[\($0.portType.rawValue)]" }.joined(separator: ", ")
        let inputs = session.availableInputs?.map(\.portName).joined(separator: ", ") ?? "None"
        let routedToSpeaker = session.currentRoute.outputs.contains { $0.portType == .builtInSpeaker }
        if speakerEnabled != routedToSpeaker {
            speakerEnabled = routedToSpeaker
        }
        speakerRoutePending = speakerRouteRetryTask != nil && !SpeakerRoutePolicy.routeMatches(
            requestedSpeaker: requestedSpeakerOverride,
            currentRouteIsSpeaker: routedToSpeaker
        )
        let carrier = vowlanPeer == nil ? "Call audio" : "VoWLAN WebRTC"
        routeDescription = "\(input.isEmpty ? "No Input" : input) ↔ \(carrier) ↔ \(output.isEmpty ? "No Output" : output) (available inputs: \(inputs))"
        IPhoneCloudCallSession.shared.recordAudioRoute(output.isEmpty ? "unknown" : output)
    }

    private func handleRouteChange(_ notification: Notification) {
        refreshRouteDescription()
        guard speakerRouteRetryTask == nil else { return }
        requestedSpeakerOverride = SpeakerRoutePolicy.requestedSpeakerAfterSystemRouteChange(
            requestedSpeaker: requestedSpeakerOverride,
            observedRouteIsSpeaker: speakerEnabled
        )
        speakerRoutePending = false
    }

}

/// Tone type used during call waiting; the associated value also detects whether the user switched the incoming ringtone.
private enum CallTone: Equatable {
    case incoming(String)
    case outgoingWaiting
    case preview(String)

    var ringtoneName: String {
        switch self {
        case let .incoming(name), let .preview(name): return name
        case .outgoingWaiting: return "Waiting for Outgoing Call"
        }
    }

    var volume: Float {
        switch self {
        case .outgoingWaiting: return 0.55
        case .incoming, .preview: return 0.85
        }
    }
}

/// Synthesizes short, royalty-free PCM ringtones at runtime and wraps them as WAV data readable by AVAudioPlayer.
private enum SynthesizedCallTone {
    private struct Segment {
        let frequencies: [Double]
        let duration: Double
        let amplitude: Double

        static func silence(_ duration: Double) -> Segment {
            Segment(frequencies: [], duration: duration, amplitude: 0)
        }
    }

    private static let sampleRate = 16_000

    static func wavData(for tone: CallTone) -> Data {
        let segments = pattern(for: tone)
        var samples = [Int16]()
        samples.reserveCapacity(Int(segments.reduce(0) { $0 + $1.duration } * Double(sampleRate)))

        for segment in segments {
            let sampleCount = max(1, Int(segment.duration * Double(sampleRate)))
            let envelopeSamples = min(sampleCount / 2, sampleRate / 100)
            for index in 0..<sampleCount {
                guard !segment.frequencies.isEmpty else {
                    samples.append(0)
                    continue
                }
                let time = Double(index) / Double(sampleRate)
                let wave = segment.frequencies.reduce(0.0) {
                    $0 + sin(2 * .pi * $1 * time)
                } / Double(segment.frequencies.count)
                // Apply a 10 ms fade-in/fade-out at both ends of each segment to avoid clicks from waveform truncation.
                let edge = min(index, sampleCount - index - 1)
                let envelope = envelopeSamples > 0
                    ? min(1, Double(edge) / Double(envelopeSamples))
                    : 1
                let value = max(-1, min(1, wave * segment.amplitude * envelope))
                samples.append(Int16(value * Double(Int16.max)))
            }
        }
        return encodeWAV(samples)
    }

    private static func pattern(for tone: CallTone) -> [Segment] {
        if case .outgoingWaiting = tone {
            // 425 Hz, 1s on and 4s off, matching standard ringback cadence.
            return [
                Segment(frequencies: [425], duration: 1.0, amplitude: 0.34),
                .silence(4.0),
            ]
        }

        switch tone.ringtoneName {
        case "Signal":
            return [
                Segment(frequencies: [880], duration: 0.16, amplitude: 0.38), .silence(0.12),
                Segment(frequencies: [880], duration: 0.16, amplitude: 0.38), .silence(0.12),
                Segment(frequencies: [1_176], duration: 0.3, amplitude: 0.34), .silence(1.5),
            ]
        case "Beacon":
            return [
                Segment(frequencies: [523, 784], duration: 0.32, amplitude: 0.38), .silence(0.16),
                Segment(frequencies: [659, 988], duration: 0.32, amplitude: 0.38), .silence(0.16),
                Segment(frequencies: [784, 1_046], duration: 0.48, amplitude: 0.34), .silence(1.5),
            ]
        case "System Default":
            return [
                Segment(frequencies: [440, 480], duration: 0.8, amplitude: 0.38), .silence(0.35),
                Segment(frequencies: [440, 480], duration: 0.8, amplitude: 0.38), .silence(2.0),
            ]
        default:
            return [
                Segment(frequencies: [523, 659], duration: 0.3, amplitude: 0.38), .silence(0.1),
                Segment(frequencies: [659, 784], duration: 0.3, amplitude: 0.38), .silence(0.1),
                Segment(frequencies: [784, 1_046], duration: 0.45, amplitude: 0.34), .silence(0.18),
                Segment(frequencies: [659, 784], duration: 0.3, amplitude: 0.34), .silence(1.6),
            ]
        }
    }

    private static func encodeWAV(_ samples: [Int16]) -> Data {
        let pcmByteCount = UInt32(samples.count * MemoryLayout<Int16>.size)
        var data = Data()
        data.reserveCapacity(44 + Int(pcmByteCount))
        data.append(contentsOf: "RIFF".utf8)
        append(UInt32(36) + pcmByteCount, to: &data)
        data.append(contentsOf: "WAVEfmt ".utf8)
        append(UInt32(16), to: &data)
        append(UInt16(1), to: &data)
        append(UInt16(1), to: &data)
        append(UInt32(sampleRate), to: &data)
        append(UInt32(sampleRate * 2), to: &data)
        append(UInt16(2), to: &data)
        append(UInt16(16), to: &data)
        data.append(contentsOf: "data".utf8)
        append(pcmByteCount, to: &data)
        for sample in samples { append(UInt16(bitPattern: sample), to: &data) }
        return data
    }

    private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }
}


enum VoiceAudioError: LocalizedError {
    case tonePlaybackFailed

    var errorDescription: String? {
        switch self {
        case .tonePlaybackFailed: return "System could not start the tone player"
        }
    }
}
