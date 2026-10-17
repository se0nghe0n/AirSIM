import Foundation

@MainActor
protocol VoBLECallControlling: AnyObject {
    var state: VoBLEConnectionState { get }
    var onEvent: ((VoBLEAndroidEvent) -> Void)? { get set }
    var onAudioDownlinkFragment: ((Data) -> Void)? { get set }
    var onReadyToSendAudio: (() -> Void)? { get set }
    var onDisconnected: (() -> Void)? { get set }
    var onReady: (() -> Void)? { get set }
    func send(command: String, callID: String, generation: UInt64,
              number: String) async throws -> VoBLEControlResponse
    func mediaKey(callID: String, generation: UInt64) throws -> Data
}

extension VoBLECentralController: VoBLECallControlling {}

struct VoBLECallIdentity: Equatable, Sendable {
    let callID: String
    let generation: UInt64
    let uuid: UUID
    let direction: String
    let number: String?
    let isProvisional: Bool

    var mediaIdentity: VoBLEMediaSessionIdentity {
        .init(callID: callID, generation: generation)
    }
}

enum VoBLECallTransition: Equatable, Sendable {
    case ignored
    case incoming(VoBLECallIdentity)
    case connecting(VoBLECallIdentity)
    case active(VoBLECallIdentity, startMedia: Bool)
    case ended(VoBLECallIdentity)
}

/// Generation is the ownership boundary. A delayed event from a previous call must never
/// stop audio or CallKit for the current call.
struct VoBLECallLifecycleReducer: Sendable {
    private(set) var current: VoBLECallIdentity?
    private(set) var mediaRequested = false
    private var terminalKeys: Set<String> = []

    mutating func beginOutgoing(callID: String, generation: UInt64, number: String) -> VoBLECallIdentity {
        let value = VoBLECallIdentity(
            callID: callID, generation: generation, uuid: UUID(),
            direction: "outgoing", number: number, isProvisional: true)
        current = value
        mediaRequested = false
        return value
    }

    mutating func apply(_ event: VoBLEAndroidEvent) -> VoBLECallTransition {
        guard !event.callID.isEmpty, event.generation > 0 else { return .ignored }
        let key = "\(event.callID):\(event.generation)"
        if terminalKeys.contains(key) { return .ignored }

        if event.state == "ended" {
            guard let current,
                  current.callID == event.callID,
                  current.generation == event.generation else { return .ignored }
            terminalKeys.insert(key)
            self.current = nil
            mediaRequested = false
            return .ended(current)
        }

        let identity: VoBLECallIdentity
        if let current, current.generation == event.generation {
            if current.callID != event.callID, current.direction != "outgoing" { return .ignored }
            // Android assigns the authoritative Telecom call ID after an outgoing dial.
            identity = VoBLECallIdentity(
                callID: event.callID, generation: event.generation, uuid: current.uuid,
                direction: event.direction.isEmpty ? current.direction : event.direction,
                number: event.number.isEmpty ? current.number : event.number,
                isProvisional: false)
        } else {
            guard current == nil || event.generation > current!.generation else { return .ignored }
            identity = VoBLECallIdentity(
                callID: event.callID, generation: event.generation, uuid: UUID(),
                direction: event.direction, number: event.number.isEmpty ? nil : event.number,
                isProvisional: false)
            mediaRequested = false
        }
        current = identity

        switch event.state {
        case "incoming", "waiting": return .incoming(identity)
        case "active", "held":
            let shouldStart = !mediaRequested
            mediaRequested = true
            return .active(identity, startMedia: shouldStart)
        case "dialing", "connecting": return .connecting(identity)
        default: return .ignored
        }
    }

    mutating func resetIfMatching(_ identity: VoBLECallIdentity) -> Bool {
        guard current == identity else { return false }
        current = nil
        mediaRequested = false
        return true
    }

    func hasEnded(_ identity: VoBLECallIdentity) -> Bool {
        terminalKeys.contains("\(identity.callID):\(identity.generation)")
    }
}

@MainActor
final class VoBLECallCoordinator {
    var onIncoming: ((IncomingVoIPCall) -> Void)?
    var onState: ((VoBLECallIdentity, CallLifecycleState) -> Void)?
    var onEnded: ((VoBLECallIdentity) -> Void)?
    var onError: ((String) -> Void)?

    private let central: any VoBLECallControlling
    private let media: VoBLEGATTMediaTransport
    private let audio: VoBLEAudioEngine
    private let defaults: UserDefaults
    private var reducer = VoBLECallLifecycleReducer()
    private var recoveryTask: Task<Void, Never>?
    private var recoveringIdentity: VoBLECallIdentity?
    private let generationKey = "airsim.voble.call-generation"

    init(
        central: any VoBLECallControlling,
        media: VoBLEGATTMediaTransport,
        audio: VoBLEAudioEngine,
        defaults: UserDefaults = .standard
    ) {
        self.central = central
        self.media = media
        self.audio = audio
        self.defaults = defaults
        central.onEvent = { [weak self] event in self?.receive(event) }
        central.onAudioDownlinkFragment = { [weak media] fragment in
            media?.receiveDownlinkFragment(fragment)
        }
        central.onReadyToSendAudio = { [weak media] in media?.peripheralIsReadyToSend() }
        central.onDisconnected = { [weak self] in self?.disconnect() }
        central.onReady = { [weak self] in self?.resumeAfterReconnect() }
    }

    var currentIdentity: VoBLECallIdentity? { reducer.current }
    var isReady: Bool { central.state == .ready }

    func startOutgoing(number: String) async throws -> VoBLECallIdentity {
        _ = number
        throw VoBLECentralError.bluetooth("bluetooth_unavailable")
    }

    func answer() async throws {
        guard let identity = reducer.current else { throw VoBLECentralError.invalidResponse }
        try await requireSuccess("answer", identity: identity)
        onState?(identity, .connecting)
    }

    func end(rejectIfRinging: Bool) async throws {
        guard let identity = reducer.current else { throw VoBLECentralError.invalidResponse }
        do {
            try await requireSuccess(rejectIfRinging ? "reject" : "end", identity: identity)
        } catch {
            // The authenticated terminal event is authoritative even if an
            // older Android build rejects the later command as call_mismatch.
            guard reducer.hasEnded(identity) else { throw error }
#if DEBUG
            print("[AirSIM VoBLE Call] end acknowledged by terminal event")
#endif
            return
        }
        // An ended event or a newer call can win while awaiting the reply.
        // Never resurrect the old call or overwrite the replacement's state.
        guard reducer.current == identity else { return }
        onState?(identity, .ending)
    }

    func sendDTMF(_ digits: String) async throws {
        guard let identity = reducer.current else { throw VoBLECentralError.invalidResponse }
        for digit in digits where "0123456789*#".contains(digit) {
            let response = try await central.send(
                command: "dtmf", callID: identity.callID,
                generation: identity.generation, number: String(digit))
            guard response.success else { throw VoBLECentralError.bluetooth(response.code) }
        }
    }

    func setMuted(_ muted: Bool) { audio.setMuted(muted) }
    func setCallKitAudioActive(_ active: Bool) { audio.setCallKitAudioActive(active) }

    func disconnect() {
        guard let identity = reducer.current, recoveringIdentity == nil else { return }
        audio.setMediaReady(false)
        media.stop(identity: identity.mediaIdentity)
        recoveringIdentity = identity
        recoveryTask?.cancel()
        recoveryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.failRecovery(identity)
        }
    }

    private func receive(_ event: VoBLEAndroidEvent) {
#if DEBUG
        print("[AirSIM VoBLE Call] event state=\(event.state) generation=\(event.generation)")
#endif
        if let recoveringIdentity, event.generation != recoveringIdentity.generation { return }
        defaults.set(Int(max(event.generation, UInt64(max(0, defaults.integer(forKey: generationKey))))),
                     forKey: generationKey)
        switch reducer.apply(event) {
        case .ignored: return
        case let .incoming(identity):
            onIncoming?(IncomingVoIPCall(
                bluetoothCallID: identity.callID, uuid: identity.uuid,
                generation: identity.generation, number: identity.number))
            onState?(identity, .ringing)
        case let .connecting(identity): onState?(identity, .connecting)
        case let .active(identity, _):
            onState?(identity, .active)
        case let .ended(identity):
            audio.stop()
            media.stop(identity: identity.mediaIdentity)
            onEnded?(identity)
        }
    }

    private func resumeAfterReconnect() {
        guard let identity = recoveringIdentity,
              reducer.current == identity else { return }
        recoveryTask?.cancel()
        recoveryTask = nil
        recoveringIdentity = nil
    }

    private func failRecovery(_ identity: VoBLECallIdentity) {
        guard recoveringIdentity == identity else { return }
        recoveringIdentity = nil
        recoveryTask = nil
        guard reducer.resetIfMatching(identity) else { return }
        audio.stop()
        onEnded?(identity)
    }

    private func requireSuccess(_ command: String, identity: VoBLECallIdentity) async throws {
#if DEBUG
        print("[AirSIM VoBLE Call] command=\(command) generation=\(identity.generation)")
#endif
        let response = try await central.send(
            command: command, callID: identity.callID, generation: identity.generation, number: "")
#if DEBUG
        print("[AirSIM VoBLE Call] response command=\(command) success=\(response.success) code=\(response.code)")
#endif
        guard response.success else {
            throw VoBLECentralError.bluetooth(response.detail.isEmpty ? response.code : response.detail)
        }
    }
}
