import Foundation
import os

/// Phases of one outgoing call setup, in the order a cloud call normally passes them.
enum OutgoingCallSetupPhase: String, CaseIterable, Sendable {
    case dialStarted = "dial_started"
    case vowlanDecision = "vowlan_decision"
    case cloudStatusDone = "cloud_status_done"
    case enqueueAccepted = "enqueue_accepted"
    case prewarmSignalingConnected = "prewarm_signaling_connected"
    case dialAcceptance = "dial_acceptance"
    case signalingAdoptionStarted = "signaling_adoption_started"
    case ownerJoinSent = "owner_join_sent"
    case dialCompleted = "dial_completed"
    case dialFailed = "dial_failed"
    case signalingConnected = "signaling_connected"
    case answerPending = "answer_pending"
    case mediaPrepared = "media_prepared"
    case answerConfirmed = "answer_confirmed"
    case iceConfigReady = "ice_config_ready"
    case peerStarted = "peer_started"
    case nativeConnected = "native_connected"
    case active = "active"
    case audioReady = "audio_ready"

    /// The Agent can answer "not yet" several times; every other phase is logged at its first occurrence, so a
    /// later media rebuild does not rewrite the setup timeline.
    var repeats: Bool { self == .answerPending }
}

/// The only values a timeline line can carry besides its phase and elapsed time. A closed set keeps numbers,
/// secrets, URLs, SDP and ICE candidates out of the log by construction.
enum OutgoingCallSetupDetail: String, Sendable {
    case vowlanReady = "vowlan=ready"
    case vowlanNotReady = "vowlan=not_ready"
    case vowlanModeOff = "vowlan=mode_off"
    case statusOverlapped = "status=overlapped"
    case statusSequential = "status=sequential"
    case routeVoWLAN = "route=vowlan"
    case routeCloud = "route=cloud"
    case prewarmed = "prewarmed=true"
    case notPrewarmed = "prewarmed=false"
    case acceptanceSignaling = "source=signaling"
    case acceptanceHTTP = "source=http"
}

/// Monotonic elapsed time since an outgoing dial started, written to the unified log so a device call can be
/// measured from Console or `log stream`:
///
///     log stream --predicate 'subsystem == "com.example.airsim.call-setup"'
///
/// A line holds a per-launch dial counter, a phase, milliseconds and at most one `OutgoingCallSetupDetail`.
/// Logging is synchronous and never awaited on the call path.
@MainActor
final class OutgoingCallSetupTimeline {
    static let subsystem = "com.example.airsim.call-setup"
    static let category = "outgoing"

    private static let logger = Logger(subsystem: subsystem, category: category)
    private static var dialCounter = 0

    let dial: Int
    private(set) var callUUID: UUID?
    private let startedAt: TimeInterval
    private let now: () -> TimeInterval
    private let sink: (String) -> Void
    private var logged = Set<OutgoingCallSetupPhase>()

    init(
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        sink: @escaping (String) -> Void = { line in
            OutgoingCallSetupTimeline.logger.notice("\(line, privacy: .public)")
        }
    ) {
        Self.dialCounter += 1
        dial = Self.dialCounter
        self.now = now
        self.sink = sink
        startedAt = now()
    }

    /// The Relay named the call. Session phases are accepted only for this call.
    func bind(to callUUID: UUID) {
        self.callUUID = callUUID
    }

    func covers(_ callUUID: UUID) -> Bool {
        self.callUUID == callUUID
    }

    func mark(_ phase: OutgoingCallSetupPhase, _ detail: OutgoingCallSetupDetail? = nil, at uptime: TimeInterval? = nil)
    {
        guard phase.repeats || logged.insert(phase).inserted else { return }
        let elapsed = Int((max(0, (uptime ?? now()) - startedAt) * 1_000).rounded())
        sink(Self.line(dial: dial, phase: phase, elapsedMilliseconds: elapsed, detail: detail))
    }

    static func line(
        dial: Int,
        phase: OutgoingCallSetupPhase,
        elapsedMilliseconds: Int,
        detail: OutgoingCallSetupDetail?
    ) -> String {
        let fields = ["dial=\(dial)", "phase=\(phase.rawValue)", "elapsed_ms=\(elapsedMilliseconds)"]
        return (fields + [detail?.rawValue].compactMap { $0 }).joined(separator: " ")
    }
}
