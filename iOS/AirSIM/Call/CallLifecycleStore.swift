import Foundation

enum CallLifecycleState: String, Codable, Equatable, Sendable {
    case idle
    case ringing
    case connecting
    case active
    case ending
    case ended
    case failed

    var isTerminal: Bool { self == .ended || self == .failed }
    var representsCall: Bool { self != .idle && !isTerminal }

    var callRecordState: String {
        switch self {
        case .idle: return "idle"
        case .ringing: return "incoming"
        case .connecting: return "dialing"
        case .active: return "active"
        case .ending: return "ending"
        case .ended: return "ended"
        case .failed: return "failed"
        }
    }
}

enum CallLifecycleSource: String, Codable, Equatable, Sendable {
    case app
    case callKit = "callkit"
    case agent
    case relay
}

struct CallLifecycleEvent: Equatable, Sendable {
    let callID: String
    let callUUID: UUID
    let generation: UInt64
    let state: CallLifecycleState
    let source: CallLifecycleSource
    let timestamp: Date
    let traceID: String?
    let failure: String?
}

struct CallLifecycleSnapshot: Equatable, Sendable {
    let callID: String?
    let callUUID: UUID?
    let generation: UInt64
    let state: CallLifecycleState
    let source: CallLifecycleSource?
    let timestamp: Date?
    let traceID: String?
    let failure: String?

    static let idle = CallLifecycleSnapshot(
        callID: nil,
        callUUID: nil,
        generation: 0,
        state: .idle,
        source: nil,
        timestamp: nil,
        traceID: nil,
        failure: nil
    )
}

/// Single reducer for per-call state. All sources must submit events rather than mutating the final state directly.
struct CallLifecycleStore: Sendable {
    private(set) var snapshot: CallLifecycleSnapshot = .idle
    private struct RetiredCall: Hashable, Sendable {
        let id: String
        let uuid: UUID
    }
    private var retired: [RetiredCall] = []

    func suppressesPresentation(callID: String) -> Bool {
        retired.contains { $0.id == callID }
    }

    mutating func retire(callID: String, uuid: UUID) {
        let identity = RetiredCall(id: callID, uuid: uuid)
        guard !retired.contains(identity) else { return }
        retired.append(identity)
        if retired.count > 64 { retired.removeFirst() }
    }

    @discardableResult
    mutating func apply(_ event: CallLifecycleEvent) -> Bool {
        guard !event.callID.isEmpty, event.generation > 0 else { return false }
        let identity = RetiredCall(id: event.callID, uuid: event.callUUID)
        // A reconnect's generation is not permission to revoke a local end intent.
        // Retain older identities too, so a delayed push cannot return after the next call.
        if suppressesPresentation(callID: event.callID), !event.state.isTerminal, event.state != .ending { return false }
        let sameIdentity = snapshot.callID == event.callID && snapshot.callUUID == event.callUUID
        if snapshot.generation > 0, !sameIdentity {
            // Legacy protocols set generation = 1 for every call; allow a new ringing/connecting call
            // with a different identity only after the previous call enters ending or reaches a terminal state.
            guard snapshot.state.isTerminal || snapshot.state == .ending,
                  event.state == .ringing || event.state == .connecting else { return false }
        } else if event.generation < snapshot.generation {
            return false
        } else if event.generation == snapshot.generation, snapshot.generation > 0 {
            if let timestamp = snapshot.timestamp, event.timestamp < timestamp { return false }
            guard Self.allows(from: snapshot.state, to: event.state) else { return false }
        } else if event.state == .idle {
            return false
        }

        snapshot = CallLifecycleSnapshot(
            callID: event.callID,
            callUUID: event.callUUID,
            generation: event.generation,
            state: event.state,
            source: event.source,
            timestamp: event.timestamp,
            traceID: event.traceID,
            failure: event.state == .failed ? event.failure : nil
        )
        if event.state == .ending || event.state.isTerminal, !retired.contains(identity) {
            retire(callID: event.callID, uuid: event.callUUID)
        }
        return true
    }

    private static func allows(from current: CallLifecycleState, to next: CallLifecycleState) -> Bool {
        if current == next { return true }
        switch current {
        case .idle:
            return [.ringing, .connecting, .active, .failed].contains(next)
        case .ringing:
            return [.connecting, .active, .ending, .ended, .failed].contains(next)
        case .connecting:
            return [.active, .ending, .ended, .failed].contains(next)
        case .active:
            return [.ending, .ended, .failed].contains(next)
        case .ending:
            return [.ended, .failed].contains(next)
        case .ended, .failed:
            return false
        }
    }
}
