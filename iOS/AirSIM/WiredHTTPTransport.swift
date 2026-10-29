import Foundation
import Network

/// Local HTTP response; the transport layer retains only the fields needed for upper-layer decoding and error handling.
struct WiredHTTPResponse: Sendable {
    let statusCode: Int
    let body: Data
}

/// Uses Network.framework to keep VoWLAN requests on Wi-Fi, independent of cellular or VPN routes.
final class WiredHTTPTransport: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.jieden.airsim.vowlan-http", qos: .userInitiated)

    func send(_ request: URLRequest, uploadFileURL: URL? = nil) async throws -> WiredHTTPResponse {
        guard let url = request.url,
              url.scheme?.lowercased() == "http",
              let host = url.host,
              let port = NWEndpoint.Port(rawValue: UInt16(url.port ?? 80)) else {
            throw WiredHTTPError.invalidRequest
        }

        let body: WiredHTTPBody
        if let uploadFileURL {
            let attributes = try FileManager.default.attributesOfItem(atPath: uploadFileURL.path)
            guard let size = attributes[.size] as? NSNumber else {
                throw WiredHTTPError.unreadableUpload
            }
            body = .file(uploadFileURL, size.uint64Value)
        } else if let data = request.httpBody, !data.isEmpty {
            body = .data(data)
        } else {
            body = .none
        }

        return try await sendOnce(request, host: NWEndpoint.Host(host), port: port, body: body)
    }

    private func sendOnce(
        _ request: URLRequest,
        host: NWEndpoint.Host,
        port: NWEndpoint.Port,
        body: WiredHTTPBody
    ) async throws -> WiredHTTPResponse {
        try await withCheckedThrowingContinuation { continuation in
            let operation = WiredHTTPRequestOperation(
                request: request,
                host: host,
                port: port,
                body: body,
                queue: queue,
                continuation: continuation
            )
            operation.start()
        }
    }

}

private enum WiredHTTPBody {
    case none
    case data(Data)
    case file(URL, UInt64)

    var length: UInt64 {
        switch self {
        case .none: return 0
        case let .data(data): return UInt64(data.count)
        case let .file(_, length): return length
        }
    }
}

/// Uses a dedicated TCP connection with `Connection: close` per request to avoid reusing stale Wi-Fi paths after wake.
private final class WiredHTTPRequestOperation: @unchecked Sendable {
    private static let maximumResponseBytes = 32 * 1_024 * 1_024
    private static let uploadChunkBytes = 64 * 1_024

    private let request: URLRequest
    private let host: NWEndpoint.Host
    private let port: NWEndpoint.Port
    private let body: WiredHTTPBody
    private let queue: DispatchQueue
    private let continuation: CheckedContinuation<WiredHTTPResponse, Error>
    private let connection: NWConnection
    private var responseData = Data()
    private var uploadHandle: FileHandle?
    private var keepAlive: WiredHTTPRequestOperation?
    private var requestStarted = false
    private var finished = false

    init(
        request: URLRequest,
        host: NWEndpoint.Host,
        port: NWEndpoint.Port,
        body: WiredHTTPBody,
        queue: DispatchQueue,
        continuation: CheckedContinuation<WiredHTTPResponse, Error>
    ) {
        self.request = request
        self.host = host
        self.port = port
        self.body = body
        self.queue = queue
        self.continuation = continuation

        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 5
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.requiredInterfaceType = .wifi
        connection = NWConnection(host: host, port: port, using: parameters)
    }

    func start() {
        // NWConnection callbacks use weak references; the operation retains itself until the request finishes to prevent premature deallocation.
        keepAlive = self
#if DEBUG
        connection.pathUpdateHandler = { [weak self] path in
            guard self != nil else { return }
            let interfaces = path.availableInterfaces.map { "\($0.name):\($0.type)" }.joined(separator: ",")
            print("[AirSIM Network] route=wifi status=\(path.status) reason=\(path.unsatisfiedReason) available=\(interfaces)")
        }
#endif
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                guard !self.requestStarted else { return }
                guard self.connection.currentPath?.usesInterfaceType(.wifi) == true else {
                    self.finish(.failure(WiredHTTPError.wiredPathUnavailable))
                    return
                }
                self.requestStarted = true
                self.receiveNextChunk()
                self.sendRequest()
            case let .failed(error):
                self.finish(.failure(WiredHTTPError.connectionFailed(error.localizedDescription)))
#if DEBUG
            case let .waiting(error):
                print("[AirSIM Network] route=wifi waiting=\(error.localizedDescription)")
#endif
            case .cancelled:
                if !self.finished { self.finish(.failure(WiredHTTPError.connectionClosed)) }
            default:
                break
            }
        }
        connection.start(queue: queue)

        // When strict path constraints do not match, the connection may stay waiting; the request has not been sent yet, so the caller can safely decide whether to fall back.
        queue.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, !self.finished, !self.requestStarted else { return }
            self.finish(.failure(WiredHTTPError.wiredPathUnavailable))
        }

        let timeout = max(1, request.timeoutInterval)
        queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self, !self.finished else { return }
            self.finish(.failure(WiredHTTPError.timedOut))
        }
    }

    private func sendRequest() {
        do {
            let header = try makeHeader()
            let hasBody = body.length > 0
            connection.send(
                content: header,
                contentContext: .defaultStream,
                // HTTP/1.1 already declares the request body boundary via Content-Length. Do not mark
                // the NWConnection stream complete here, otherwise GET will half-close TCP early
                // and cancel the Go long-poll request.Context, returning an empty 200 body.
                isComplete: false,
                completion: .contentProcessed { [weak self] error in
                    guard let self else { return }
                    if let error {
                        self.finish(.failure(WiredHTTPError.sendFailed(error.localizedDescription)))
                    } else if hasBody {
                        self.sendBody()
                    }
                }
            )
        } catch {
            finish(.failure(error))
        }
    }

    private func makeHeader() throws -> Data {
        guard let url = request.url else { throw WiredHTTPError.invalidRequest }
        let method = request.httpMethod?.uppercased() ?? "GET"
        guard method.allSatisfy({ $0.isASCII && ($0.isLetter || $0 == "-") }) else {
            throw WiredHTTPError.invalidRequest
        }

        var path = url.path.isEmpty ? "/" : url.path
        if let query = url.query, !query.isEmpty { path += "?" + query }
        guard !path.contains("\r"), !path.contains("\n") else {
            throw WiredHTTPError.invalidRequest
        }

        var headers = request.allHTTPHeaderFields ?? [:]
        headers["Host"] = "\(host):\(port.rawValue)"
        headers["Connection"] = "close"
        headers["Accept"] = "application/json"
        headers["Content-Length"] = String(body.length)

        var lines = ["\(method) \(path) HTTP/1.1"]
        for (name, value) in headers.sorted(by: { $0.key.lowercased() < $1.key.lowercased() }) {
            guard !name.isEmpty,
                  name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-_".contains($0)) }),
                  !value.contains("\r"), !value.contains("\n") else {
                throw WiredHTTPError.invalidRequest
            }
            lines.append("\(name): \(value)")
        }
        lines.append("")
        lines.append("")
        guard let data = lines.joined(separator: "\r\n").data(using: .utf8) else {
            throw WiredHTTPError.invalidRequest
        }
        return data
    }

    private func sendBody() {
        switch body {
        case .none:
            break
        case let .data(data):
            send(data)
        case let .file(url, _):
            do {
                uploadHandle = try FileHandle(forReadingFrom: url)
                sendNextFileChunk()
            } catch {
                finish(.failure(WiredHTTPError.unreadableUpload))
            }
        }
    }

    private func sendNextFileChunk() {
        guard let uploadHandle else {
            finish(.failure(WiredHTTPError.unreadableUpload))
            return
        }
        do {
            let data = try uploadHandle.read(upToCount: Self.uploadChunkBytes) ?? Data()
            if data.isEmpty {
                // File length is already declared via Content-Length, so do not send TCP FIN; the server can still
                // return the update result on the same connection.
                send(Data())
            } else {
                send(data) { [weak self] in self?.sendNextFileChunk() }
            }
        } catch {
            finish(.failure(WiredHTTPError.unreadableUpload))
        }
    }

    private func send(_ data: Data, completion: (() -> Void)? = nil) {
        connection.send(
            content: data,
            contentContext: .defaultStream,
            isComplete: false,
            completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                if let error {
                    self.finish(.failure(WiredHTTPError.sendFailed(error.localizedDescription)))
                } else {
                    completion?()
                }
            }
        )
    }

    private func receiveNextChunk() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1_024) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                guard self.responseData.count + data.count <= Self.maximumResponseBytes else {
                    self.finish(.failure(WiredHTTPError.responseTooLarge))
                    return
                }
                self.responseData.append(data)
            }
            if let error {
                // The module occasionally closes the connection with RST when executing ATD; if a complete HTTP response has arrived, use it rather than reporting a false failure.
                if let response = try? WiredHTTPResponseParser.parse(self.responseData) {
                    self.finish(.success(response))
                } else {
                    self.finish(.failure(WiredHTTPError.receiveFailed(error.localizedDescription)))
                }
            } else if isComplete {
                do {
                    self.finish(.success(try WiredHTTPResponseParser.parse(self.responseData)))
                } catch {
                    self.finish(.failure(error))
                }
            } else {
                self.receiveNextChunk()
            }
        }
    }

    private func finish(_ result: Result<WiredHTTPResponse, Error>) {
        guard !finished else { return }
        finished = true
        try? uploadHandle?.close()
        uploadHandle = nil
        connection.stateUpdateHandler = nil
        connection.cancel()
        continuation.resume(with: result)
        keepAlive = nil
    }

}

/// Standalone HTTP/1.1 response parser for network-free testing of fixed-length and chunked responses from the Go Agent.
enum WiredHTTPResponseParser {
    static func parse(_ data: Data) throws -> WiredHTTPResponse {
        let separator = Data("\r\n\r\n".utf8)
        guard let range = data.range(of: separator),
              let headerText = String(data: data[..<range.lowerBound], encoding: .isoLatin1) else {
            throw WiredHTTPError.invalidResponse
        }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let statusLine = lines.first else { throw WiredHTTPError.invalidResponse }
        let statusFields = statusLine.split(separator: " ", maxSplits: 2)
        guard statusFields.count >= 2,
              statusFields[0].hasPrefix("HTTP/"),
              let statusCode = Int(statusFields[1]) else {
            throw WiredHTTPError.invalidResponse
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        let encodedBody = Data(data[range.upperBound...])
        let body: Data
        if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            body = try decodeChunkedBody(encodedBody)
        } else if let lengthText = headers["content-length"], let length = Int(lengthText) {
            guard length >= 0, encodedBody.count >= length else {
                throw WiredHTTPError.incompleteResponse
            }
            body = Data(encodedBody.prefix(length))
        } else {
            body = encodedBody
        }
        return WiredHTTPResponse(statusCode: statusCode, body: body)
    }

    private static func decodeChunkedBody(_ data: Data) throws -> Data {
        let lineBreak = Data("\r\n".utf8)
        var cursor = data.startIndex
        var decoded = Data()

        while cursor < data.endIndex {
            guard let sizeRange = data[cursor...].range(of: lineBreak),
                  let sizeLine = String(data: data[cursor..<sizeRange.lowerBound], encoding: .ascii),
                  let sizeToken = sizeLine.split(separator: ";", maxSplits: 1).first,
                  let size = Int(sizeToken.trimmingCharacters(in: .whitespaces), radix: 16) else {
                throw WiredHTTPError.invalidResponse
            }
            cursor = sizeRange.upperBound
            if size == 0 { return decoded }
            guard size > 0,
                  let chunkEnd = data.index(cursor, offsetBy: size, limitedBy: data.endIndex),
                  data.distance(from: chunkEnd, to: data.endIndex) >= 2,
                  data[chunkEnd..<data.index(chunkEnd, offsetBy: 2)] == lineBreak else {
                throw WiredHTTPError.incompleteResponse
            }
            decoded.append(data[cursor..<chunkEnd])
            cursor = data.index(chunkEnd, offsetBy: 2)
        }
        throw WiredHTTPError.incompleteResponse
    }
}

private enum WiredHTTPError: LocalizedError {
    case invalidRequest
    case wiredPathUnavailable
    case connectionFailed(String)
    case connectionClosed
    case sendFailed(String)
    case receiveFailed(String)
    case timedOut
    case responseTooLarge
    case invalidResponse
    case incompleteResponse
    case unreadableUpload

    var errorDescription: String? {
        switch self {
        case .invalidRequest: return "Invalid module request format"
        case .wiredPathUnavailable: return "Wi-Fi connection not available"
        case let .connectionFailed(message): return "VoWLAN connection failed: \(message)"
        case .connectionClosed: return "VoWLAN connection closed"
        case let .sendFailed(message): return "Module request send failed: \(message)"
        case let .receiveFailed(message): return "Module response receive failed: \(message)"
        case .timedOut: return "VoWLAN request timed out"
        case .responseTooLarge: return "Module response exceeds the safe size limit"
        case .invalidResponse: return "Android Agent returned an invalid HTTP response"
        case .incompleteResponse: return "Android Agent returned an incomplete HTTP response"
        case .unreadableUpload: return "Unable to read module update package"
        }
    }
}
