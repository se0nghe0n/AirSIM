import Foundation
import os

/// A successful dial invocation is not an answer, media acknowledgement or permission to open audio.
enum CloudOutgoingDialAcceptancePolicy {
    static func accepts(_ control: CloudCallControlMessage, for call: IncomingVoIPCall, currentConnection: Bool) -> Bool
    {
        currentConnection && call.isOutgoing && control.status == "outgoing_dial_accepted"
            && control.callID == call.callID
            && control.callUUID?.lowercased() == call.uuid.uuidString.lowercased()
            && control.generation == call.generation
    }
}

/// Call-scoped proof, including proof received before polling starts. Cancelling one waiter leaves the socket alone.
@MainActor
final class CloudOutgoingDialAcceptance {
    private var accepted = false
    private var invalidated = false
    private var waiters: [UUID: CheckedContinuation<Bool, Never>] = [:]

    var waiterCount: Int { waiters.count }

    func accept() {
        guard !invalidated else { return }
        accepted = true
        finishWaiters(true)
    }

    func invalidate() {
        invalidated = true
        accepted = false
        finishWaiters(false)
    }

    func wait() async -> Bool {
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled || invalidated {
                    continuation.resume(returning: false)
                } else if accepted {
                    continuation.resume(returning: true)
                } else {
                    waiters[id] = continuation
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.waiters.removeValue(forKey: id)?.resume(returning: false)
            }
        }
    }

    private func finishWaiters(_ value: Bool) {
        let pending = Array(waiters.values)
        waiters.removeAll()
        for waiter in pending { waiter.resume(returning: value) }
    }
}

enum CloudOutgoingDialAcceptanceSource: Sendable {
    case signaling
    case http
}

@MainActor
enum CloudOutgoingDialAcceptanceRace {
    static func wait(
        signaling: CloudOutgoingDialAcceptance?,
        http: @escaping @MainActor @Sendable () async throws -> Void
    ) async throws -> CloudOutgoingDialAcceptanceSource {
        try await withThrowingTaskGroup(of: CloudOutgoingDialAcceptanceSource?.self) { group in
            defer { group.cancelAll() }
            group.addTask {
                try await http()
                return .http
            }
            if let signaling {
                group.addTask { await signaling.wait() ? .signaling : nil }
            }
            while let result = try await group.next() {
                try Task.checkCancellation()
                if let result { return result }
            }
            throw CancellationError()
        }
    }
}

/// A connection has one completion, whether pong, authenticated outgoing proof, cancellation or socket loss wins.
/// The lock also covers cancellation before the bridge queue installs the continuation/socket.
final class CloudSignalingConnectionGate: Sendable {
    private struct State {
        var result: Result<Void, Error>?
        var completion: (@Sendable (Result<Void, Error>) -> Void)?
    }

    let connection: UUID
    private let outgoing: IncomingVoIPCall?
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(connection: UUID, outgoing: IncomingVoIPCall? = nil) {
        self.connection = connection
        self.outgoing = outgoing
    }

    var isPending: Bool { state.withLock { $0.result == nil } }

    func install(_ completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
        let result = state.withLock { state -> Result<Void, Error>? in
            if let result = state.result { return result }
            state.completion = completion
            return nil
        }
        if let result { completion(result) }
    }

    @discardableResult
    func finish(_ result: Result<Void, Error>) -> Bool {
        let outcome = state.withLock { state -> (Bool, (@Sendable (Result<Void, Error>) -> Void)?) in
            guard state.result == nil else { return (false, nil) }
            state.result = result
            let completion = state.completion
            state.completion = nil
            return (true, completion)
        }
        outcome.1?(result)
        return outcome.0
    }

    @discardableResult
    func accept(_ control: CloudCallControlMessage, connection: UUID) -> Bool {
        guard let outgoing,
            CloudOutgoingDialAcceptancePolicy.accepts(
                control,
                for: outgoing,
                currentConnection: connection == self.connection
            )
        else { return false }
        return finish(.success(()))
    }

    /// Called on the bridge queue. A late pong must not steal the pending marker from cancellation cleanup.
    func finishPong(_ result: Result<Void, Error>, pending: inout CloudSignalingConnectionGate?) {
        if finish(result), pending === self { pending = nil }
    }

    func ownsConnection(_ currentConnection: UUID) -> Bool { currentConnection == connection }
}

/// How often the result of a queued Relay command is polled.
enum CloudCommandPollSchedule: Equatable, Sendable {
    /// One poll every `steadyInterval`. Long waits such as SMS delivery must not load the Relay.
    case steady
    /// A dial usually completes within a second, and nothing else can start until it does: poll sooner at first.
    case dial

    static let steadyInterval: Duration = .milliseconds(500)
    static let dialInitialIntervals: [Duration] = [.milliseconds(100), .milliseconds(200), .milliseconds(300)]

    /// The pause after poll number `poll` (counted from zero) returned a status that is not final.
    func interval(afterPoll poll: Int) -> Duration {
        guard self == .dial, Self.dialInitialIntervals.indices.contains(poll) else { return Self.steadyInterval }
        return Self.dialInitialIntervals[poll]
    }
}

/// Order of one cloud dial: the Relay accepts the command and names the call, media preparation for that call
/// overlaps the wait for the Android phone to start dialing, and a dial that does not start releases it again.
@MainActor
enum CloudOutgoingDialCoordinator {
    static func run<Call>(
        enqueue: () async throws -> Call,
        prewarm: (Call) -> Void,
        awaitDialing: (Call) async throws -> Void,
        discardPrewarm: (Call) -> Void
    ) async throws -> Call {
        let call = try await enqueue()
        prewarm(call)
        do {
            try await awaitDialing(call)
        } catch {
            // Failed, timed out or cancelled: nothing may stay bound to a call that never started.
            discardPrewarm(call)
            throw error
        }
        return call
    }
}

/// The signaling socket opened for an outgoing call while its dial command is still pending.
///
/// An entry is not a call. While it exists the session has no `call`, is not answered, owns nothing at the Relay
/// and has sent no control message: `answer` is still sent only after the dial command completed. `answer()` for
/// the same call adopts the socket; every other outcome releases it.
@MainActor
final class CloudOutgoingPrewarm {
    struct Entry {
        let id: UUID
        let call: IncomingVoIPCall
        /// Whether the socket connected. Never throws, so adoption can simply wait for it.
        let connection: Task<Bool, Never>
        let acceptance: CloudOutgoingDialAcceptance
    }

    /// Longer than any dial wait. A prewarm that was neither adopted nor discarded by then is released.
    static let maximumLifetime: Duration = .seconds(45)

    private(set) var entry: Entry?
    /// `answer()` is waiting for the entry's socket. Until it finishes, the socket's fate is decided there.
    private(set) var isAdopting = false
    private var expiry: Task<Void, Never>?
    private let lifetime: Duration

    init(lifetime: Duration = CloudOutgoingPrewarm.maximumLifetime) {
        self.lifetime = lifetime
    }

    var callUUID: UUID? { entry?.call.uuid }

    /// Starts connecting for `call` and returns whether a new prewarm began. Returns false, changing nothing, while
    /// the session serves a call (a prewarm must never touch the media of an existing call) and when this call is
    /// already prewarmed. `release` closes whatever the media bridge holds: a replaced entry's socket, or nothing.
    @discardableResult
    func begin(
        _ call: IncomingVoIPCall,
        sessionHasCall: Bool,
        release: () -> Void,
        connect: @escaping @MainActor () async throws -> Void,
        expired: @escaping @MainActor (IncomingVoIPCall) -> Void
    ) -> Bool {
        guard !sessionHasCall, !isAdopting else { return false }
        if let entry, Self.matches(entry.call, call) { return false }
        clear()
        release()
        let id = UUID()
        let connection = Task { @MainActor [weak self] in
            // A newer call may have taken the media before this task first ran.
            guard let self, self.entry?.id == id else { return false }
            do {
                try await connect()
                return true
            } catch {
                return false
            }
        }
        entry = Entry(id: id, call: call, connection: connection, acceptance: CloudOutgoingDialAcceptance())
        let lifetime = lifetime
        expiry = Task { @MainActor [weak self] in
            try? await Task.sleep(for: lifetime)
            guard !Task.isCancelled, let self, self.entry?.id == id, !self.isAdopting else { return }
            expired(call)
        }
        return true
    }

    /// The dial failed, timed out, was cancelled or superseded. Releases this call's prewarm only: a newer
    /// prewarm, or a call that was answered meanwhile, is left alone.
    @discardableResult
    func discard(call: IncomingVoIPCall, release: () -> Void) -> Bool {
        guard let entry, Self.matches(entry.call, call), !isAdopting else { return false }
        clear()
        release()
        return true
    }

    /// `answer()` starts for `call`. A matching entry is returned for adoption and stays registered until
    /// `finishAdoption`. An entry for any other call is dropped; the caller replaces its media as for any new call.
    func beginAdoption(for call: IncomingVoIPCall) -> Entry? {
        guard let entry else { return nil }
        guard Self.matches(entry.call, call) else {
            clear()
            return nil
        }
        isAdopting = true
        expiry?.cancel()
        expiry = nil
        return entry
    }

    /// Adoption ended, with or without a usable socket. From here the session treats the socket as its own.
    func finishAdoption(_ adopted: Entry) {
        guard entry?.id == adopted.id else { return }
        entry?.acceptance.invalidate()
        entry = nil
        isAdopting = false
    }

    /// The session stopped and already released its media.
    func reset() {
        clear()
    }

    /// Never reuse a socket after the call generation, Relay endpoint or bearer credential changed.
    static func matches(_ left: IncomingVoIPCall, _ right: IncomingVoIPCall) -> Bool {
        left.uuid == right.uuid && left.generation == right.generation && left.callID == right.callID
            && left.isOutgoing == right.isOutgoing && left.authenticatedMediaURL == right.authenticatedMediaURL
            && left.mediaSecret == right.mediaSecret
    }

    private func clear() {
        entry?.acceptance.invalidate()
        entry?.connection.cancel()
        entry = nil
        isAdopting = false
        expiry?.cancel()
        expiry = nil
    }
}

/// Runs the cloud status check alongside the VoWLAN probe, so a dial that ends up on the cloud route has not also
/// waited for the probe. VoWLAN keeps its priority: when it is ready the status result is dropped unread.
@MainActor
enum OutgoingRoutePreparation {
    /// Whether to ask the Relay before the probe result is known. A verified VoWLAN route is expected to carry the
    /// call, and local calls do not query the Relay.
    static func overlapsCloudStatus(probesVoWLAN: Bool, cloudModeEnabled: Bool, vowlanVerified: Bool) -> Bool {
        probesVoWLAN && cloudModeEnabled && !vowlanVerified
    }

    static func run<Route, Status: Sendable>(
        overlapsCloudStatus: Bool,
        readyVoWLAN: () async -> Route?,
        fetchCloudStatus: @escaping @MainActor () async throws -> Status
    ) async -> (vowlanRoute: Route?, cloudStatus: Result<Status, Error>?) {
        guard overlapsCloudStatus else { return (await readyVoWLAN(), nil) }
        async let status = capture(fetchCloudStatus)
        // Returning with VoWLAN cancels the status request: the call then never depended on the Relay.
        guard let route = await readyVoWLAN() else { return (nil, await status) }
        return (route, nil)
    }

    private static func capture<Status: Sendable>(
        _ operation: @MainActor () async throws -> Status
    ) async -> Result<Status, Error> {
        do {
            return .success(try await operation())
        } catch {
            return .failure(error)
        }
    }
}
