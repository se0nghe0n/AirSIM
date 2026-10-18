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

enum PCMRoute: Equatable, Sendable {
    case moduleLocal
    case vowlan(endpoint: VoWLANEndpoint, credential: VoWLANCredential)

    var host: String {
        switch self {
        case .moduleLocal: return "192.168.225.1"
        case let .vowlan(endpoint, _): return endpoint.host
        }
    }

    var port: UInt16 {
        switch self {
        case .moduleLocal: return 7_580
        case let .vowlan(endpoint, _): return endpoint.pcmPort
        }
    }

    var requiresWiFi: Bool {
        if case .vowlan = self { return true }
        return false
    }

    func handshake() throws -> Data {
        throw APIError.disabledLegacyRoute
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

/// 管理 iPhone/iPad 内置麦克风、扬声器与模块 ECM 网络 PCM 之间的双向通话音频。
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

    @ObservationIgnored private var engine: AVAudioEngine?
    @ObservationIgnored private var player: AVAudioPlayerNode?
    @ObservationIgnored private var vowlanPeer: CloudWebRTCPeer?
    @ObservationIgnored private let vowlanQueue = DispatchQueue(label: "com.example.airsim.vowlan-webrtc")
    @ObservationIgnored private var callTonePlayer: AVAudioPlayer?
    @ObservationIgnored private var currentCallTone: CallTone?
    @ObservationIgnored private var muted = false
    @ObservationIgnored private var requestedSpeakerOverride = false
    @ObservationIgnored private var speakerRouteRetryTask: Task<Void, Never>?
    @ObservationIgnored private var sessionActivationManagedByCallKit = false
    @ObservationIgnored private var routeChangeObserver: NSObjectProtocol?

    init() {
        // CallKit、蓝牙或系统控制中心都可能改变输出路由，按钮状态必须跟随真实会话。
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
        route: PCMRoute = .moduleLocal,
        sessionAlreadyActive: Bool = false,
        callUUID: UUID = UUID(),
        generation: UInt64 = 1
    ) async -> Bool {
        guard !active else { return true }
        let permission = await requestMicrophonePermission()
        guard permission else {
            errorMessage = "Microphone access is required for two-way calls"
            return false
        }

        do {
            let session = AVAudioSession.sharedInstance()
            sessionActivationManagedByCallKit = sessionAlreadyActive
            try configureCallAudioSession()
            if !sessionAlreadyActive {
                try session.setActive(true, options: .notifyOthersOnDeactivation)
            }
            // 每次通话默认使用听筒；仅在用户主动开启扬声器后覆盖输出路由。
            try session.overrideOutputAudioPort(requestedSpeakerOverride ? .speaker : .none)
            refreshRouteDescription()
            switch route {
            case .moduleLocal:
                _ = try route.handshake()
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
        let rtc = RTCAudioSession.sharedInstance()
        rtc.useManualAudio = true
        rtc.isAudioEnabled = true
        let queue = vowlanQueue
        let peer = try CloudWebRTCPeer(
            callUUID: callUUID,
            generation: generation,
            servers: [],
            queue: queue,
            hostOnly: true,
            signal: { [weak self] signal in
                Task {
                    do {
                        let answer = try await api.exchangeVoWLANWebRTC(signal)
                        queue.async { self?.vowlanPeer?.receive(answer) }
                    } catch {
                        Task { @MainActor [weak self] in
                            self?.errorMessage = error.localizedDescription
                            self?.transportReady = false
                        }
                    }
                }
            },
            connected: { [weak self] in
                Task { @MainActor [weak self] in
                    self?.transportReady = true
                    self?.routeDescription = "VoWLAN WebRTC"
                    self?.diagnosticDescription = "\(DeviceContext.displayName) WebRTC host ICE connected"
                    self?.errorMessage = nil
                }
            },
            failure: { [weak self] in
                Task { @MainActor [weak self] in
                    self?.transportReady = false
                    self?.errorMessage = "VoWLAN WebRTC failed"
                }
            },
            statistics: { _ in }
        )
        guard peer.usesHostICE else { throw APIError.disabledLegacyRoute }
        vowlanPeer = peer
        peer.setMuted(muted)
        peer.offer()
    }

    /// CallKit 执行动作前先声明语音类别，真正激活由系统随后回调 didActivate。
    func prepareForCallKit() throws {
        resetSpeakerPreferenceForNewCall()
        try configureCallAudioSession()
        try AVAudioSession.sharedInstance().overrideOutputAudioPort(.none)
        sessionActivationManagedByCallKit = true
    }

    func setMuted(_ muted: Bool) {
        CallAudioRecorder.shared.setMuted(muted)
        self.muted = muted
        vowlanPeer?.setMuted(muted)
    }

    /// 根据模块通话状态播放来电铃声或呼出等待音，接通后立即让位给网络 PCM。
    func updateCallTone(for call: CallRecord?) {
        guard !active else {
            stopCallTone()
            return
        }
        guard let call else {
            // 设置页试听不属于通话状态，空闲轮询不能提前将它停止。
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

    /// 设置页只试听一遍，不能像真实来电一样无限循环。
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
        // 空闲轮询会反复调用本方法；没有铃声时绝不能停用后台待机正在使用的会话。
        // CallKit 的 didActivate 回调之后，音频会话也只能由系统释放。
        guard hadTone, deactivateSession, !active, !sessionActivationManagedByCallKit else { return }
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
        )
    }

    /// 切换当前通话的输出路由；关闭扬声器时交还给系统选择听筒或已连接的蓝牙设备。
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

    /// CallKit 的 didActivate 与 AVAudioEngine 真正启动之间存在短暂窗口。
    /// 在窗口内切换会得到 OSStatus -50，因此把用户选择保留并做有界重试。
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
                    // API 返回只表示系统接受了请求；currentRoute 的切换是异步的。
                    // 等待一个很短的确认窗口，再以真实输出端口决定按钮高亮。
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
                    // 音频会话还没由 CallKit 激活时保留选择，等待下一次短重试。
                }
            }
            refreshRouteDescription()
        }
    }

    /// 合并模块侧 D5/D6 统计，避免把 TCP 连通误判为实际存在语音。
    func updateModuleDiagnostics(_ config: MaVoAudioHostConfig) {
        var details: [String] = []
        if let routeError = config.routeError, !routeError.isEmpty {
            details.append("Module audio bridge error: \(routeError)")
        } else if config.routeRunning != true {
            details.append("Module PCM has not started")
        } else if config.routeSessionReady == false || config.routeReady == false {
            details.append("Module audio route is not ready")
        }
        if let statistics = config.statistics, config.statisticsAvailable == true {
            details.append("D5 ↑\(statistics.uplinkBytes)B peak \(statistics.uplinkPeak) · D6 ↓\(statistics.downlinkBytes)B peak \(statistics.downlinkPeak)")
        } else if config.routeRunning == true {
            details.append("Module PCM started, waiting for statistics")
        }
        // 只显示最后一条日志，保留真正的启动失败原因，同时避免通话页被日志刷屏。
        if let lastLog = config.logTail?.last, !lastLog.isEmpty {
            details.append("Log: \(lastLog)")
        }
        moduleDiagnosticDescription = details.joined(separator: "；")
    }

    func deactivate() {
        let callKitManagedSession = sessionActivationManagedByCallKit
        sessionActivationManagedByCallKit = false
        muted = false
        requestedSpeakerOverride = false
        speakerRouteRetryTask?.cancel()
        speakerRouteRetryTask = nil
        speakerRoutePending = false
        stopCallTone()
        vowlanPeer?.close()
        vowlanPeer = nil
        RTCAudioSession.sharedInstance().isAudioEnabled = false
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        player?.stop()
        player = nil
        engine = nil
        do {
            let session = AVAudioSession.sharedInstance()
            // 清除本次通话的外放覆盖，避免影响下一次通话或其他 App。
            try session.overrideOutputAudioPort(.none)
            if !callKitManagedSession {
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
            // 模块来电属于电话提醒，使用 playback 确保手机静音时仍能听到，并压低其他音频。
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
        // voiceChat 使用 VoiceProcessingIO，为听筒和扬声器通话提供系统回声消除。
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

struct PlaybackQueueTracker {
    let maximumFrames: Int
    private(set) var scheduledFrames = 0
    private(set) var droppedFrames = 0

    mutating func reserve(frames: Int) -> Bool {
        guard frames > 0 else { return false }
        guard scheduledFrames + frames <= maximumFrames else {
            droppedFrames += frames
            return false
        }
        scheduledFrames += frames
        return true
    }

    mutating func complete(frames: Int) {
        scheduledFrames = max(0, scheduledFrames - max(0, frames))
    }

    mutating func reset() {
        scheduledFrames = 0
        droppedFrames = 0
    }
}

struct PCMFrameAccumulator {
    let frameBytes: Int
    private var bytes = Data()

    init(frameBytes: Int) {
        self.frameBytes = frameBytes
    }

    var pendingByteCount: Int { bytes.count }

    mutating func append(_ data: Data) -> Data? {
        guard frameBytes > 0, !data.isEmpty else { return nil }
        bytes.append(data)
        let completeByteCount = (bytes.count / frameBytes) * frameBytes
        guard completeByteCount > 0 else { return nil }
        let batch = Data(bytes.prefix(completeByteCount))
        bytes.removeFirst(completeByteCount)
        return batch
    }

    mutating func reset() {
        bytes.removeAll(keepingCapacity: false)
    }
}

/// 通话等待阶段使用的声音类型；关联值同时用于检测用户是否切换了来电铃声。
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

/// 运行时合成短促、无版权依赖的 PCM 铃声，并封装为 AVAudioPlayer 可读取的 WAV。
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
                // 每段两端加入 10 ms 淡入淡出，避免波形截断产生爆音。
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
            // 425 Hz、1 秒响 4 秒停，接近国内常见呼叫等待节奏。
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
        case "系统默认":
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


/// 对麦克风做语音带限与线性降采样，输出模块需要的 8 kHz PCM16LE。
final class VoicePCMEncoder: @unchecked Sendable {
    private let lock = NSLock()
    private var conditioner = VoiceCaptureConditioner()
    private var samples: [Float] = []
    private var position = 0.0
    private var sampleRate = 0.0
    private var muted = false

    func setMuted(_ muted: Bool) {
        lock.lock()
        self.muted = muted
        lock.unlock()
    }

    func encode(_ buffer: AVAudioPCMBuffer) -> Data {
        guard let input = buffer.floatChannelData?[0] else { return Data() }
        let frameCount = Int(buffer.frameLength)
        let copied = Array(UnsafeBufferPointer(start: input, count: frameCount))
        let rate = buffer.format.sampleRate

        lock.lock()
        defer { lock.unlock() }
        if sampleRate != rate {
            sampleRate = rate
            samples.removeAll(keepingCapacity: true)
            position = 0
            conditioner.reset(sampleRate: rate)
        }
        samples.append(contentsOf: conditioner.process(copied, sampleRate: rate))
        let step = rate / 8_000
        var pcm = Data()
        pcm.reserveCapacity(frameCount / max(1, Int(step)) * 2 + 4)

        while position + 1 < Double(samples.count) {
            let lower = Int(position)
            let fraction = Float(position - Double(lower))
            let value = samples[lower] * (1 - fraction) + samples[lower + 1] * fraction
            let scaled = muted ? Int16(0) : Int16(max(-1, min(1, value)) * 32_767)
            var littleEndian = scaled.littleEndian
            withUnsafeBytes(of: &littleEndian) { pcm.append(contentsOf: $0) }
            position += step
        }
        let consumed = max(0, min(Int(position), samples.count - 1))
        if consumed > 0 {
            samples.removeFirst(consumed)
            position -= Double(consumed)
        }
        return pcm
    }
}

/// 两级低通避免降采样混叠，高通去除直流与桌面低频振动。
private struct VoiceCaptureConditioner {
    private var sampleRate = 0.0
    private var previousInput: Float = 0
    private var highPassOutput: Float = 0
    private var lowPassStage1: Float = 0
    private var lowPassStage2: Float = 0

    mutating func process(_ samples: [Float], sampleRate: Double) -> [Float] {
        guard sampleRate > 0, !samples.isEmpty else { return [] }
        if self.sampleRate != sampleRate { reset(sampleRate: sampleRate) }
        let timeStep = 1 / sampleRate
        let highPassRC = 1 / (2 * Double.pi * 80)
        let highPassAlpha = Float(highPassRC / (highPassRC + timeStep))
        let lowPassCutoff = min(3_400, sampleRate * 0.45)
        let lowPassAlpha = Float(1 - exp(-2 * Double.pi * lowPassCutoff / sampleRate))
        return samples.map { sample in
            highPassOutput = highPassAlpha * (highPassOutput + sample - previousInput)
            previousInput = sample
            lowPassStage1 += lowPassAlpha * (highPassOutput - lowPassStage1)
            lowPassStage2 += lowPassAlpha * (lowPassStage1 - lowPassStage2)
            return max(-1, min(1, lowPassStage2))
        }
    }

    mutating func reset(sampleRate: Double = 0) {
        self.sampleRate = sampleRate
        previousInput = 0
        highPassOutput = 0
        lowPassStage1 = 0
        lowPassStage2 = 0
    }
}

enum VoiceAudioError: LocalizedError {
    case microphoneUnavailable
    case invalidPlaybackFormat
    case tonePlaybackFailed

    var errorDescription: String? {
        switch self {
        case .microphoneUnavailable: return "No microphone input available"
        case .invalidPlaybackFormat: return "Unable to create 8 kHz call playback format"
        case .tonePlaybackFailed: return "System could not start the tone player"
        }
    }
}
