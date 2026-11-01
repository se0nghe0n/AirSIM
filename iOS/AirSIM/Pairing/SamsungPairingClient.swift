import Foundation
import Network

struct SamsungPairingService: Identifiable, Equatable {
    let endpoint: NWEndpoint
    let sessionID: String
    let serverPublicKey: Data
    let expiresAt: Date

    var id: String { sessionID }

    var displayName: String {
        if case let .service(name, _, _, _) = endpoint { return name }
        return "Android Phone Bridge"
    }
}

@MainActor
@Observable
final class SamsungPairingBrowser {
    private(set) var services: [SamsungPairingService] = []
    private(set) var stateText = "Scanning the local network for VoWLAN…"

    @ObservationIgnored private let queue = DispatchQueue(label: "com.airsim.samsung-pair.browser")
    @ObservationIgnored private var browser: NWBrowser?

    func start() {
        guard browser == nil else { return }
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let active = NWBrowser(
            for: .bonjourWithTXTRecord(type: "_airsim-pair._tcp", domain: nil),
            using: parameters
        )
        active.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .ready: self.stateText = "Waiting for the Android pairing broadcast…"
                case .waiting: self.stateText = "Connect iPhone and Android to the same Wi-Fi or Android hotspot"
                case .failed(let error): self.stateText = "Local network scan failed: \(error.localizedDescription)"
                case .cancelled: self.stateText = "Scan stopped"
                default: break
                }
            }
        }
        active.browseResultsChangedHandler = { [weak self] results, _ in
            let parsed = results.compactMap(Self.parse)
                .filter { $0.expiresAt > Date() }
                .sorted { $0.expiresAt < $1.expiresAt }
            Task { @MainActor in
                self?.services = parsed
                if !parsed.isEmpty {
                    self?.stateText = "Found \(parsed.count) devices available to pair"
                }
            }
        }
        browser = active
        active.start(queue: queue)
    }

    func stop() {
        browser?.cancel()
        browser = nil
        services = []
    }

    private nonisolated static func parse(_ result: NWBrowser.Result) -> SamsungPairingService? {
        guard case let .bonjour(record) = result.metadata,
            record["v"] == "1",
            let sessionID = record["session"],
            let keyText = record["key"],
            let serverPublicKey = Data(base64URL: keyText),
            serverPublicKey.count == 32,
            let expiresText = record["expires"],
            let expiresMillis = Double(expiresText)
        else { return nil }
        return SamsungPairingService(
            endpoint: result.endpoint,
            sessionID: sessionID,
            serverPublicKey: serverPublicKey,
            expiresAt: Date(timeIntervalSince1970: expiresMillis / 1_000)
        )
    }
}

@MainActor
final class SamsungPairingRegistrationGate {
    private var activeAgentWrites = 0
    private var pairing = false

    func beginAgentWrite() -> Bool {
        guard !pairing else { return false }
        activeAgentWrites += 1
        return true
    }

    func endAgentWrite() { activeAgentWrites -= 1 }

    func withPairing<T>(_ operation: () async throws -> T) async throws -> T {
        guard !pairing else { throw SamsungPairingClientError.pairingBusy }
        pairing = true
        defer { pairing = false }
        // Wait only for local Agent writes, never for an unrelated Relay request.
        while activeAgentWrites > 0 { try await Task.sleep(nanoseconds: 20_000_000) }
        try Task.checkCancellation()
        return try await operation()
    }
}

enum SamsungPairingRegistrationPolicy {
    static func registration(
        localOnly: Bool,
        vowlanSecret: String,
        cloudRegistration: () -> AgentPushRegistration?
    ) throws -> AgentPushRegistration {
        if localOnly { return .local(vowlanSecret: vowlanSecret) }
        guard var registration = cloudRegistration(), !registration.localMode else {
            throw SamsungPairingClientError.registrationUnavailable
        }
        registration.vowlanSecret = vowlanSecret
        return registration
    }
}

enum SamsungPairingClient {
    private struct Claim: Encodable {
        let version = 1
        let sessionID: String
        let clientPublicKey: String
        let sealedRegistration: String

        enum CodingKeys: String, CodingKey {
            case version
            case sessionID = "session_id"
            case clientPublicKey = "client_public_key"
            case sealedRegistration = "sealed_registration"
        }
    }

    private struct Response: Decodable {
        let configured: Bool
        let deviceIDHint: String?
        let agentID: String?

        enum CodingKeys: String, CodingKey {
            case configured
            case deviceIDHint = "device_id_hint"
            case agentID = "agent_id"
        }
    }

    static func pair(service: SamsungPairingService, code: String, registration: AgentPushRegistration) async throws
        -> String
    {
        guard code.range(of: #"^[0-9]{6}$"#, options: .regularExpression) != nil else {
            throw SamsungPairingClientError.invalidCode
        }
        guard service.expiresAt > Date() else { throw SamsungPairingClientError.expired }
        let registrationData = try JSONEncoder().encode(registration)
        let sealed = try SamsungPairingCrypto.seal(
            registration: registrationData,
            serverPublicKey: service.serverPublicKey,
            sessionID: service.sessionID,
            code: code
        )
        let body = try JSONEncoder().encode(
            Claim(
                sessionID: service.sessionID,
                clientPublicKey: sealed.clientPublicKey.base64URL,
                sealedRegistration: sealed.combined.base64URL
            )
        )
        let responseData = try await exchange(
            endpoint: service.endpoint,
            body: body,
            timeout: exchangeTimeout(expiresAt: service.expiresAt)
        )
        let response = try JSONDecoder().decode(Response.self, from: responseData)
        guard response.configured else { throw SamsungPairingClientError.rejected }
        if let agentID = response.agentID { PairedAndroidDeviceStore.allowPairing(agentID) }
        return response.deviceIDHint.map { "Paired successfully (device …\($0))" } ?? "Paired successfully"
    }

    /// Longest one claim exchange may take, so an unresponsive Android cannot hold the pairing gate.
    static let maximumExchangeTimeout: TimeInterval = 15

    /// The exchange also ends when the advertised pairing window closes, if that comes first.
    static func exchangeTimeout(expiresAt: Date, now: Date = Date()) -> TimeInterval {
        min(maximumExchangeTimeout, expiresAt.timeIntervalSince(now))
    }

    static func exchange(endpoint: NWEndpoint, body: Data, timeout: TimeInterval) async throws -> Data {
        let exchange = PairingExchangeState()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                exchange.start(endpoint: endpoint, body: body, timeout: timeout, continuation: continuation)
            }
        } onCancel: {
            exchange.finish(.failure(CancellationError()))
        }
    }
}

@MainActor
enum SamsungPairingCompletionCoordinator {
    static func complete(
        performPairing: () async throws -> String,
        refreshVoWLAN: () async -> Void
    ) async rethrows -> String {
        let message = try await performPairing()
        await refreshVoWLAN()
        return message
    }
}

/// One claim exchange. The first terminal event (response, connection error or `.waiting`, deadline, or
/// task cancellation) resumes the continuation exactly once and cancels the connection. Connection
/// callbacks hold the state weakly, so the connection never keeps it alive.
private final class PairingExchangeState: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.airsim.samsung-pair.claim")
    private let lock = NSLock()
    private var connection: NWConnection?
    private var continuation: CheckedContinuation<Data, Error>?
    private var deadline: DispatchWorkItem?
    private var outcome: Result<Data, Error>?
    private var received = Data()

    func start(
        endpoint: NWEndpoint,
        body: Data,
        timeout: TimeInterval,
        continuation: CheckedContinuation<Data, Error>
    ) {
        lock.lock()
        if let outcome {
            // The calling task was cancelled before the connection was created.
            lock.unlock()
            continuation.resume(with: outcome)
            return
        }
        let connection = NWConnection(to: endpoint, using: .tcp)
        let deadline = DispatchWorkItem { [weak self] in
            self?.finish(.failure(SamsungPairingClientError.timedOut))
        }
        self.connection = connection
        self.continuation = continuation
        self.deadline = deadline
        connection.stateUpdateHandler = { [weak self] newState in
            switch newState {
            case .ready: self?.send(body: body)
            case .waiting(let error), .failed(let error): self?.finish(.failure(error))
            case .cancelled: self?.finish(.failure(SamsungPairingClientError.connectionClosed))
            default: break
            }
        }
        // Started under the lock so a concurrent finish cannot cancel the connection before it starts.
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + timeout, execute: deadline)
        lock.unlock()
    }

    private var activeConnection: NWConnection? {
        lock.withLock { connection }
    }

    private func send(body: Data) {
        guard let connection = activeConnection else { return }
        var request = Data(
            "POST /pair/v1/claim HTTP/1.1\r\nHost: airsim-pair.local\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
                .utf8
        )
        request.append(body)
        connection.send(
            content: request,
            completion: .contentProcessed { [weak self] error in
                if let error {
                    self?.finish(.failure(error))
                    return
                }
                self?.receive()
            }
        )
    }

    private func receive() {
        guard let connection = activeConnection else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) {
            [weak self] content, _, isComplete, error in
            guard let self else { return }
            if let content { self.received.append(content) }
            if let error {
                self.finish(.failure(error))
                return
            }
            if self.received.count > 65_536 {
                self.finish(.failure(SamsungPairingClientError.responseTooLarge))
                return
            }
            if isComplete {
                self.finish(self.parseResponse())
                return
            }
            self.receive()
        }
    }

    private func parseResponse() -> Result<Data, Error> {
        let marker = Data("\r\n\r\n".utf8)
        guard let range = received.range(of: marker),
            let firstLine = String(data: received[..<range.lowerBound], encoding: .utf8)?.split(separator: "\n").first,
            firstLine.contains(" 200 ")
        else { return .failure(SamsungPairingClientError.rejected) }
        return .success(Data(received[range.upperBound...]))
    }

    func finish(_ result: Result<Data, Error>) {
        lock.lock()
        guard outcome == nil else {
            lock.unlock()
            return
        }
        outcome = result
        let connection = self.connection
        let continuation = self.continuation
        let deadline = self.deadline
        self.connection = nil
        self.continuation = nil
        self.deadline = nil
        lock.unlock()
        deadline?.cancel()
        connection?.cancel()
        continuation?.resume(with: result)
    }
}

enum SamsungPairingClientError: LocalizedError {
    case invalidCode
    case expired
    case rejected
    case responseTooLarge
    case connectionClosed
    case timedOut
    case registrationUnavailable
    case pairingBusy

    var errorDescription: String? {
        switch self {
        case .invalidCode: return "Enter the six-digit code shown on Android"
        case .expired: return "The Android pairing window expired. Start again."
        case .rejected: return "Android rejected pairing. Check the code and try again."
        case .responseTooLarge: return "Android returned an invalid response"
        case .connectionClosed: return "The local network connection to Android was lost"
        case .timedOut: return "Android did not respond. Keep its pairing window open and try again."
        case .registrationUnavailable:
            return
                "Relay/push configuration is not ready. Configure cloud settings first, or enable Local-Only Pairing for a local connection."
        case .pairingBusy: return "Another pairing is in progress. Try again shortly."
        }
    }
}

private extension Data {
    init?(base64URL: String) {
        var value = base64URL.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        value += String(repeating: "=", count: (4 - value.count % 4) % 4)
        self.init(base64Encoded: value)
    }

    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
