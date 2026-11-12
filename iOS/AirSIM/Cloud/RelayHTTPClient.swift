import Foundation
import os

/// One HTTPS session for Relay requests that follow each other closely, so a status check, a command enqueue, its
/// result polls and the call's TURN request share a connection instead of paying a TCP and TLS handshake each.
///
/// The session stays ephemeral and keeps no cookies, response cache or stored credentials: reusing it must not carry
/// anything from one request into the next, exactly as when every request had a session of its own. A session that
/// was idle for longer than `reuseWindow` is replaced, so a request after a pause still starts on a new connection
/// as before, rather than on one a NAT or the server may have dropped unnoticed.
final class RelayHTTPClient: Sendable {
    static let shared = RelayHTTPClient()

    private struct State {
        var session: URLSession
        var lastFinished: TimeInterval
        var inFlight = 0
    }

    private let state: OSAllocatedUnfairLock<State>
    private let makeSession: @Sendable () -> URLSession
    private let now: @Sendable () -> TimeInterval

    init(
        makeSession: @escaping @Sendable () -> URLSession = {
            URLSession(configuration: RelayHTTPClient.makeConfiguration())
        },
        now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.makeSession = makeSession
        self.now = now
        state = OSAllocatedUnfairLock(initialState: State(session: makeSession(), lastFinished: now()))
    }

    static func makeConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCredentialStorage = nil
        return configuration
    }

    /// `request.timeoutInterval` remains the idle timeout. `resourceTimeout` bounds the whole request, as
    /// `timeoutIntervalForResource` did for a per-request session, and fails with the same `URLError.timedOut`.
    func data(for request: URLRequest, resourceTimeout: TimeInterval? = nil) async throws -> (Data, URLResponse) {
        let session = checkOutSession()
        defer { checkInSession() }
        guard let resourceTimeout else { return try await Self.send(request, on: session) }
        return try await withThrowingTaskGroup(of: Outcome.self) { group in
            group.addTask {
                let (data, response) = try await Self.send(request, on: session)
                return .response(data, response)
            }
            group.addTask {
                // A cancelled timer must not win: the request then reports the cancellation itself, as before.
                do {
                    try await Task.sleep(for: .seconds(resourceTimeout))
                    return .deadline
                } catch {
                    return .timerCancelled
                }
            }
            defer { group.cancelAll() }
            while let outcome = try await group.next() {
                switch outcome {
                case let .response(data, response): return (data, response)
                case .deadline: throw URLError(.timedOut)
                case .timerCancelled: continue
                }
            }
            throw URLError(.cancelled)
        }
    }

    private enum Outcome: Sendable {
        case response(Data, URLResponse)
        case deadline
        case timerCancelled
    }

    private func checkOutSession() -> URLSession {
        let now = now()
        return state.withLock { state in
            if !RelayHTTPReusePolicy.reusesSession(idleFor: now - state.lastFinished, inFlight: state.inFlight) {
                // Nothing is in flight on the replaced session.
                state.session.finishTasksAndInvalidate()
                state.session = makeSession()
            }
            state.inFlight += 1
            return state.session
        }
    }

    private func checkInSession() {
        let now = now()
        state.withLock { state in
            state.inFlight -= 1
            state.lastFinished = now
        }
    }

    private static func send(_ request: URLRequest, on session: URLSession) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch let error as URLError where RelayHTTPReusePolicy.retriesOnNewConnection(after: error.code) {
            return try await session.data(for: request)
        }
    }
}

enum RelayHTTPReusePolicy {
    /// Long enough for one call setup or a foreground status check followed by a dial; short enough that an idle
    /// connection has not outlived a NAT binding.
    static let reuseWindow: TimeInterval = 30

    static func reusesSession(idleFor idle: TimeInterval, inFlight: Int) -> Bool {
        inFlight > 0 || idle <= reuseWindow
    }

    /// A reused connection can already be closed, for example after the app was suspended, when the next request
    /// is written. That failure did not exist with one connection per request, so it is retried once, on a new
    /// connection. Relay requests are safe to repeat: reads, registrations, and commands deduplicated by their
    /// `command_id`.
    static func retriesOnNewConnection(after code: URLError.Code) -> Bool {
        code == .networkConnectionLost
    }
}
