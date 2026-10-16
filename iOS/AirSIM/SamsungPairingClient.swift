import Foundation
import Network

struct SamsungPairingService: Identifiable {
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
final class SamsungPairingBrowser: ObservableObject {
    @Published private(set) var services: [SamsungPairingService] = []
    @Published private(set) var stateText = "Scanning the local network for VoWLAN…"

    private let queue = DispatchQueue(label: "com.airsim.samsung-pair.browser")
    private var browser: NWBrowser?

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
                if !parsed.isEmpty { self?.stateText = "Found \(parsed.count) devices available to pair" }
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
              let expiresMillis = Double(expiresText) else { return nil }
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

    static func pair(service: SamsungPairingService, code: String, registration: AgentPushRegistration) async throws -> String {
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
        let body = try JSONEncoder().encode(Claim(
            sessionID: service.sessionID,
            clientPublicKey: sealed.clientPublicKey.base64URL,
            sealedRegistration: sealed.combined.base64URL
        ))
        let responseData = try await exchange(endpoint: service.endpoint, body: body)
        let response = try JSONDecoder().decode(Response.self, from: responseData)
        guard response.configured else { throw SamsungPairingClientError.rejected }
        if let agentID = response.agentID { PairedAndroidDeviceStore.allowPairing(agentID) }
        return response.deviceIDHint.map { "Paired successfully (device …\($0))" } ?? "Paired successfully"
    }

    private static func exchange(endpoint: NWEndpoint, body: Data) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let connection = NWConnection(to: endpoint, using: .tcp)
            let state = PairingExchangeState(connection: connection, continuation: continuation)
            connection.stateUpdateHandler = { newState in
                switch newState {
                case .ready: state.send(body: body)
                case .failed(let error): state.finish(.failure(error))
                case .cancelled: state.finish(.failure(SamsungPairingClientError.connectionClosed))
                default: break
                }
            }
            connection.start(queue: DispatchQueue(label: "com.airsim.samsung-pair.claim"))
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

private final class PairingExchangeState: @unchecked Sendable {
    private let connection: NWConnection
    private let continuation: CheckedContinuation<Data, Error>
    private var received = Data()
    private var finished = false
    private let lock = NSLock()

    init(connection: NWConnection, continuation: CheckedContinuation<Data, Error>) {
        self.connection = connection
        self.continuation = continuation
    }

    func send(body: Data) {
        var request = Data("POST /pair/v1/claim HTTP/1.1\r\nHost: airsim-pair.local\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
        request.append(body)
        connection.send(content: request, completion: .contentProcessed { [weak self] error in
            if let error { self?.finish(.failure(error)); return }
            self?.receive()
        })
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] content, _, isComplete, error in
            guard let self else { return }
            if let content { self.received.append(content) }
            if let error { self.finish(.failure(error)); return }
            if self.received.count > 65_536 { self.finish(.failure(SamsungPairingClientError.responseTooLarge)); return }
            if isComplete { self.finish(self.parseResponse()); return }
            self.receive()
        }
    }

    private func parseResponse() -> Result<Data, Error> {
        let marker = Data("\r\n\r\n".utf8)
        guard let range = received.range(of: marker),
              let firstLine = String(data: received[..<range.lowerBound], encoding: .utf8)?.split(separator: "\n").first,
              firstLine.contains(" 200 ") else { return .failure(SamsungPairingClientError.rejected) }
        return .success(Data(received[range.upperBound...]))
    }

    func finish(_ result: Result<Data, Error>) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        lock.unlock()
        connection.cancel()
        continuation.resume(with: result)
    }
}

enum SamsungPairingClientError: LocalizedError {
    case invalidCode, expired, rejected, responseTooLarge, connectionClosed, registrationUnavailable, pairingBusy
    var errorDescription: String? {
        switch self {
        case .invalidCode: return "Enter the six-digit code shown on Android"
        case .expired: return "The Android pairing window expired. Start again."
        case .rejected: return "Android rejected pairing. Check the code and try again."
        case .responseTooLarge: return "Android returned an invalid response"
        case .connectionClosed: return "The local network connection to Android was lost"
        case .registrationUnavailable: return "Relay/push configuration is not ready. Configure cloud settings first, or enable Local-Only Pairing for a local connection."
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
