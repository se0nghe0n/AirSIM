import Foundation

struct LocalCallControlBody: Encodable {
    let callID: String?

    enum CodingKeys: String, CodingKey {
        case callID = "call_id"
    }
}

enum LocalAgentRoute: Equatable, Sendable {
    case moduleLocal
    case vowlan(endpoint: VoWLANEndpoint, credential: VoWLANCredential)

    var baseURL: URL {
        switch self {
        case .moduleLocal:
            // Legacy case retained only for decoding compatibility. AirSIM never contacts QDC507.
            return URL(string: "http://127.0.0.1:9/")!
        case let .vowlan(endpoint, _):
            return endpoint.controlBaseURL
        }
    }

    var traceDescription: String {
        switch self {
        case .moduleLocal: return "Disabled Legacy Module Route"
        case .vowlan: return "VoWLAN · Same Local Network"
        }
    }

    var credential: VoWLANCredential? {
        guard case let .vowlan(_, credential) = self else { return nil }
        return credential
    }
}

/// AirSIM does not allow using the legacy module USB ECM address as a Samsung control channel.
enum AirSIMRoutePolicy {
    static func permits(_ route: LocalAgentRoute) -> Bool {
        if case .vowlan = route { return true }
        return false
    }
}

/// Unified wrapper around the module Agent HTTP API; endpoint paths match the AirSIM Mac app.
struct AirSIMAPI: Sendable {
    /// Android Telecom waits up to 12 seconds for confirmation; VoWLAN must time out after the Agent confirmation window,
    /// otherwise iPhone may misclassify an in-progress non-idempotent dial as failed and trigger duplicate calls.
    static let voWLANDialTimeout: TimeInterval = 15

    let baseURL: URL
    let route: LocalAgentRoute
    private let transport: WiredHTTPTransport

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: value) { return date }
            let wholeSeconds = ISO8601DateFormatter()
            wholeSeconds.formatOptions = [.withInternetDateTime]
            if let date = wholeSeconds.date(from: value) { return date }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported ISO 8601 date: \(value)"
            )
        }
        return decoder
    }

    private static let decoder = makeDecoder()

    init(route: LocalAgentRoute = .moduleLocal) {
        self.route = route
        let baseURL = route.baseURL
        precondition(Self.isAllowedLocalURL(baseURL), "Module Agent URL must be a local HTTP URL")
        self.baseURL = baseURL
        self.transport = WiredHTTPTransport(policy: route == .moduleLocal ? .moduleLocal : .vowlan)
    }

    init(baseURL: URL) {
        precondition(baseURL == LocalAgentRoute.moduleLocal.baseURL, "Configure dynamic local addresses through LocalAgentRoute")
        self.init(route: .moduleLocal)
    }

    /// Restricts privileged control endpoints to loopback or private networks to prevent accidental requests to public hosts.
    private static func isAllowedLocalURL(_ url: URL) -> Bool {
        guard url.scheme == "http", let host = url.host?.lowercased() else { return false }
        if host == "localhost" || host == "127.0.0.1" || host == "::1" { return true }
        if host.hasPrefix("10.") || host.hasPrefix("192.168.") { return true }
        guard host.hasPrefix("172."), let second = Int(host.split(separator: ".").dropFirst().first ?? "") else {
            return false
        }
        return (16...31).contains(second)
    }

    // MARK: Calls & SMS

    func health() async throws -> AgentHealth { try await get("api/health") }
    func callStatus() async throws -> CallStatus { try await get("api/calls/status") }
    func waitForAgentEvent(after revision: UInt64, timeout: TimeInterval = 15) async throws -> AgentEventStatus {
        let boundedTimeout = min(30, max(1, timeout))
        var components = URLComponents(
            url: endpoint("api/events"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "after", value: String(revision)),
            URLQueryItem(name: "timeout_ms", value: String(Int(boundedTimeout * 1_000)))
        ]
        var request = URLRequest(url: components.url!)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = boundedTimeout + 5
        return try await decoded(request)
    }
    func waitForCallEvent(after revision: UInt64, timeout: TimeInterval = 25) async throws -> CallStatus {
        let boundedTimeout = min(30, max(1, timeout))
        var components = URLComponents(
            url: endpoint("api/calls/events"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "after", value: String(revision)),
            URLQueryItem(name: "timeout_ms", value: String(Int(boundedTimeout * 1_000)))
        ]
        var request = URLRequest(url: components.url!)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = boundedTimeout + 5
        return try await decoded(request)
    }
    func messages() async throws -> [SMSMessage] { try await get("api/sms") }
    func acknowledgeCallHistory(ids: [String]) async throws {
        guard !ids.isEmpty else { return }
        try await post("api/calls/history/ack", ["ids": ids])
    }
    func acknowledgeMessages(ids: [String]) async throws {
        let validIDs = ids.filter { !$0.isEmpty }
        guard !validIDs.isEmpty else { return }
        try await post("api/sms/ack", ["ids": validIDs])
    }
    func smsStatus() async throws -> SMSStatus { try await get("api/sms/status") }
    func simIdentity() async throws -> SIMIdentity { try await get("api/sim/identity") }
    func registerVoIPPush(_ registration: AgentPushRegistration) async throws {
        try await post("api/push/register", registration)
    }
    func pushStatus() async throws -> AgentPushStatus { try await get("api/push/status") }
    func setPushCloudEnabled(_ enabled: Bool) async throws {
        try await post("api/push/mode", ["enabled": enabled])
    }

    func dial(number: String) async throws {
        do {
            try await post(
                "api/calls/dial",
                ["number": number],
                timeout: Self.voWLANDialTimeout
            )
        } catch {
            let originalError = error
            // ATD is non-idempotent: if the response connection is reset by the module, only poll status to confirm—never auto-resend.
            for delay in [0.25, 0.5, 1.0, 1.5] {
                try? await Task.sleep(for: .seconds(delay))
                guard let status = try? await callStatus(), let call = status.active else { continue }
                let expectedState = ["dialing", "alerting", "active", "held"].contains(call.state)
                let expectedNumber = call.number?.isEmpty != false || call.number == number
                if call.direction == "outgoing", expectedState, expectedNumber { return }
            }
            throw originalError
        }
    }
    func answerCall(callID: String? = nil) async throws {
        try await post("api/calls/answer", LocalCallControlBody(callID: callID))
    }
    func rejectCall(callID: String? = nil) async throws -> RejectResponse {
        try await postDecoded("api/calls/reject", LocalCallControlBody(callID: callID))
    }
    func hangupCall(callID: String? = nil) async throws {
        try await post("api/calls/hangup", LocalCallControlBody(callID: callID))
    }
    func sendDTMF(_ digit: String) async throws { try await post("api/calls/dtmf", ["digit": digit]) }
    func setAudioMuted(_ muted: Bool) async throws { try await post("api/calls/audio/mute", ["muted": muted]) }
    func setAudioHostEnabled(_ enabled: Bool) async throws {
        try await post("api/calls/audio/host/register", ["enabled": enabled])
    }
    func warmAudioHost() async throws {
        try await post("api/calls/audio/host/warmup", EmptyBody())
    }

    func exchangeVoWLANWebRTC(_ signal: CloudWebRTCSignal) async throws -> CloudWebRTCSignal {
        let data = try await raw(method: "POST", path: "api/calls/webrtc", body: signal, timeout: 20)
        return try Self.decode(CloudWebRTCSignal.self, from: data)
    }
    func audioHostConfig() async throws -> MaVoAudioHostConfig { try await get("api/calls/audio/host/config") }

    func sendSMS(to phone: String, message: String) async throws -> SMSSendResult {
        try await postDecoded("api/sms/send", ["phone": phone, "message": message], timeout: 80)
    }
    func refreshSMS() async throws { try await post("api/sms/refresh", EmptyBody()) }
    func clearModuleSMS() async throws { try await post("api/sms/clear-module", EmptyBody()) }
    func setSMSAutoCleanup(_ enabled: Bool) async throws {
        try await send("PATCH", "api/sms/settings", ["auto_cleanup_me": enabled])
    }

    // MARK: Status, Network, Location & Debug

    func modemStatus() async throws -> ModemStatus { try await get("api/status") }
    func moduleDebug(after sequence: UInt64 = 0, limit: Int = 400) async throws -> ModuleDebugSnapshot {
        var components = URLComponents(url: endpoint("api/debug"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "after", value: String(sequence)),
            URLQueryItem(name: "limit", value: String(min(2_000, max(1, limit))))
        ]
        var request = URLRequest(url: components.url!)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 6
        return try await decoded(request, recordVerboseTrace: false)
    }
    func clearModuleDebug() async throws { try await post("api/debug/clear", EmptyBody()) }

    // MARK: Shared HTTP Implementation

    private func endpoint(_ path: String) -> URL { baseURL.appendingPathComponent(path) }

    private func get<Response: Decodable>(_ path: String) async throws -> Response {
        var request = URLRequest(url: endpoint(path))
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 6
        return try await decoded(request)
    }

    private func post<Body: Encodable>(_ path: String, _ body: Body, timeout: TimeInterval = 8) async throws {
        _ = try await raw(method: "POST", path: path, body: body, timeout: timeout)
    }

    private func postDecoded<Response: Decodable, Body: Encodable>(
        _ path: String,
        _ body: Body,
        timeout: TimeInterval = 8
    ) async throws -> Response {
        let data = try await raw(method: "POST", path: path, body: body, timeout: timeout)
        return try Self.decode(Response.self, from: data)
    }

    private func send<Body: Encodable>(_ method: String, _ path: String, _ body: Body) async throws {
        _ = try await raw(method: method, path: path, body: body, timeout: 10)
    }

    private func raw<Body: Encodable>(method: String, path: String, body: Body, timeout: TimeInterval) async throws -> Data {
        var request = URLRequest(url: endpoint(path))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        request.timeoutInterval = timeout
        let response = try await tracedResponse(for: request)
        try Self.requireSuccess(response)
        return response.body
    }

    private func decoded<Response: Decodable>(
        _ request: URLRequest,
        recordVerboseTrace: Bool = true
    ) async throws -> Response {
        let response = try await tracedResponse(for: request, recordVerboseTrace: recordVerboseTrace)
        try Self.requireSuccess(response)
        return try Self.decode(Response.self, from: response.body)
    }

    private func tracedResponse(
        for originalRequest: URLRequest,
        uploadFileURL: URL? = nil,
        recordVerboseTrace: Bool = true
    ) async throws -> WiredHTTPResponse {
        guard AirSIMRoutePolicy.permits(route) else {
            throw APIError.disabledLegacyRoute
        }
        var request = originalRequest
        let method = request.httpMethod?.uppercased() ?? "GET"
        let path: String = {
            guard let url = request.url else { return "--" }
            return url.path + (url.query.map { "?\($0)" } ?? "")
        }()
        let uploadBytes: Int = {
            guard let uploadFileURL,
                  let attributes = try? FileManager.default.attributesOfItem(atPath: uploadFileURL.path),
                  let size = attributes[.size] as? NSNumber else { return 0 }
            return size.intValue
        }()
        let trace = recordVerboseTrace
            ? await AgentVerboseTraceRecorder.shared.begin(
                method: method,
                path: path,
                bodyBytes: uploadFileURL == nil ? (request.httpBody?.count ?? 0) : uploadBytes
            )
            : nil
        if let trace {
            request.setValue(trace.id, forHTTPHeaderField: "X-AirSIM-Trace-ID")
            await AgentVerboseTraceRecorder.shared.recordRoute(
                trace,
                route: route.traceDescription,
                attempt: 1
            )
        }
        if let credential = route.credential {
            let body = request.httpBody ?? Data()
            let signed = try VoWLANRequestSigner(secret: credential.secret).sign(
                method: method,
                path: path,
                body: body
            )
            VoWLANController.apply(signed, to: &request)
        }
        do {
            let response = try await transport.send(request, uploadFileURL: uploadFileURL)
            if let trace {
                await AgentVerboseTraceRecorder.shared.finish(
                    trace,
                    statusCode: response.statusCode,
                    responseBytes: response.body.count
                )
            }
            return response
        } catch {
            if let trace {
                await AgentVerboseTraceRecorder.shared.fail(trace, error: error.localizedDescription)
            }
            throw error
        }
    }

    private static func decode<Response: Decodable>(_ type: Response.Type, from data: Data) throws -> Response {
        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw APIError.unreadablePayload("Unrecognized Module Agent response: \(error.localizedDescription)")
        }
    }

    private static func requireSuccess(_ response: WiredHTTPResponse) throws {
        guard (200..<300).contains(response.statusCode) else {
            let message = (try? decoder.decode(APIErrorPayload.self, from: response.body))?.error
            throw APIError.http(response.statusCode, message)
        }
    }
}

enum APIError: LocalizedError {
    case invalidResponse
    case http(Int, String?)
    case unreadablePayload(String)
    case disabledLegacyRoute

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "Module Agent returned an invalid response"
        case let .http(status, message): return message?.isEmpty == false ? message : "Request failed (HTTP \(status))"
        case let .unreadablePayload(message): return message
        case .disabledLegacyRoute: return "AirSIM does not support the legacy module control route"
        }
    }
}

private struct APIErrorPayload: Decodable { let error: String? }
private struct EmptyBody: Encodable {}
