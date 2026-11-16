import Foundation

public enum PushError: Error, Equatable, Sendable {
    /// Transport failure, 408, 429 or 5xx: nothing is lost, try again on a later trigger.
    case retryable(String)
    /// Misconfiguration or protocol violation: surfaced to the user, retried only after a change.
    case fatal(String)
    /// The receiver refused this one batch (400, 409, 413, 422): only that stream is affected, so the
    /// other streams may continue. Surfaced to the user like `fatal`.
    case rejected(String)

    public var message: String {
        switch self {
        case .retryable(let m): return m
        case .fatal(let m): return m
        case .rejected(let m): return m
        }
    }

    public var isRetryable: Bool {
        if case .retryable = self { return true }
        return false
    }
}

/// A user-supplied destination. HTTPS only: the tailnet endpoint has a real certificate.
public struct PushEndpoint: Equatable, Sendable {
    public let url: URL
    public let token: String

    public init?(urlString: String, token: String) {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty, !secret.isEmpty else { return nil }
        self.url = url
        self.token = secret
    }
}

public struct Capabilities: Equatable, Sendable {
    public let protocolVersion: PushVersion
    public let receiverStateId: String
    public let streams: Set<String>
}

public struct Ack: Equatable, Sendable {
    public let batchId: String
    public let acceptedRows: Int
}

/// Refuses every redirect, so the bearer token is never forwarded to another location.
final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

public final class PushTransport {
    public static let maxCapabilitiesBytes = 16 * 1024

    private let session: URLSession

    public init(session: URLSession? = nil) {
        self.session = session ?? PushTransport.makeSession()
    }

    /// An isolated session with no cookies or cache that never follows redirects.
    public static func makeSession(configuration: URLSessionConfiguration = .ephemeral) -> URLSession {
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 60
        return URLSession(configuration: configuration, delegate: NoRedirectDelegate(), delegateQueue: nil)
    }

    // MARK: Requests

    /// Authenticated capability discovery. Sends no health data (and the "Test connection" button uses only this).
    public func capabilities(_ endpoint: PushEndpoint, accept: [PushVersion]) async throws -> Capabilities {
        var request = URLRequest(url: endpoint.url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(endpoint.token)", forHTTPHeaderField: "Authorization")
        request.setValue(accept.map { $0.rawValue }.joined(separator: ","),
                         forHTTPHeaderField: "NOOP-Push-Accept-Version")
        let (data, status) = try await perform { try await self.session.data(for: request) }
        try PushTransport.check(status: status, body: data)
        return try PushTransport.parseCapabilities(data, offered: accept)
    }

    /// POST one batch (identity coding: the tailnet link is already encrypted and the decoded bound is
    /// the same). Returns only after the acknowledgement matched the request field by field.
    public func post(_ endpoint: PushEndpoint, batch: EncodedBatch, version: PushVersion) async throws -> Ack {
        var request = URLRequest(url: endpoint.url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/x-ndjson; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(endpoint.token)", forHTTPHeaderField: "Authorization")
        let body = batch.body
        let (data, status) = try await perform { try await self.session.upload(for: request, from: body) }
        try PushTransport.check(status: status, body: data)
        return try PushTransport.validateAck(data, for: batch, version: version)
    }

    private func perform(_ work: () async throws -> (Data, URLResponse)) async throws -> (Data, Int) {
        do {
            let (data, response) = try await work()
            guard let http = response as? HTTPURLResponse else {
                throw PushError.fatal("response was not HTTP")
            }
            return (data, http.statusCode)
        } catch let e as PushError {
            throw e
        } catch let e as URLError {
            throw PushTransport.classify(urlError: e)
        } catch {
            throw PushError.retryable("network error")
        }
    }

    // MARK: Classification and parsing (static so they are unit-testable)

    static func classify(urlError e: URLError) -> PushError {
        switch e.code {
        case .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateNotYetValid,
             .serverCertificateHasUnknownRoot, .clientCertificateRejected, .secureConnectionFailed,
             .appTransportSecurityRequiresSecureConnection, .badURL, .unsupportedURL:
            return .fatal("TLS or URL problem (\(e.code.rawValue))")
        default:
            return .retryable("network error (\(e.code.rawValue))")
        }
    }

    /// Only a validated machine code is ever surfaced, never response text (it may echo health data).
    static func errorCode(_ body: Data) -> String? {
        guard body.count <= PushTransport.maxCapabilitiesBytes,
              let obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let code = obj["code"] as? String, code.count <= 64, !code.isEmpty else { return nil }
        var ok = true
        for (i, u) in code.unicodeScalars.enumerated() {
            let lower = u.value >= 97 && u.value <= 122
            let digitOrUnderscore = (u.value >= 48 && u.value <= 57) || u.value == 95
            if !(lower || (i > 0 && digitOrUnderscore)) { ok = false }
        }
        return ok ? code : nil
    }

    static func check(status: Int, body: Data) throws {
        if status >= 200 && status < 300 { return }
        let suffix = errorCode(body).map { " (\($0))" } ?? ""
        switch status {
        case 408, 429, 500...599:
            throw PushError.retryable("HTTP \(status)\(suffix)")
        case 300..<400:
            throw PushError.fatal("redirect not followed (HTTP \(status))")
        case 401, 403:
            throw PushError.fatal("authentication failed (HTTP \(status))")
        case 406:
            throw PushError.fatal("no common protocol version (HTTP 406)")
        case 400, 409, 413, 422:
            throw PushError.rejected("HTTP \(status)\(suffix)")
        default:
            throw PushError.fatal("HTTP \(status)\(suffix)")
        }
    }

    static func isCanonicalUUID(_ s: String) -> Bool {
        return UUID(uuidString: s) != nil && s == s.lowercased()
    }

    static func parseCapabilities(_ data: Data, offered: [PushVersion]) throws -> Capabilities {
        guard data.count <= PushTransport.maxCapabilitiesBytes else {
            throw PushError.fatal("capabilities response too large")
        }
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              obj["type"] as? String == "capabilities",
              let versionString = obj["protocolVersion"] as? String,
              let version = PushVersion(rawValue: versionString), offered.contains(version),
              let stateId = obj["receiverStateId"] as? String, isCanonicalUUID(stateId),
              let names = obj["streams"] as? [String] else {
            throw PushError.fatal("invalid capabilities document")
        }
        let known = Set(PushRegistry.streams(for: version).map { $0.name })
        var seen = Set<String>()
        for name in names {
            guard known.contains(name), seen.insert(name).inserted else {
                throw PushError.fatal("invalid capabilities: unknown or duplicate stream")
            }
        }
        return Capabilities(protocolVersion: version, receiverStateId: stateId, streams: seen)
    }

    static func validateAck(_ data: Data, for batch: EncodedBatch, version: PushVersion) throws -> Ack {
        let mismatch = PushError.fatal("acknowledgement does not match the request")
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              obj["protocolVersion"] as? String == version.rawValue,
              obj["batchId"] as? String == batch.batchId,
              obj["stream"] as? String == batch.stream,
              obj["deviceId"] as? String == batch.deviceId,
              (obj["acceptedRows"] as? NSNumber)?.intValue == batch.recordCount,
              obj["status"] as? String == "accepted" else { throw mismatch }
        if let expected = batch.endCursor {
            guard let c = obj["endCursor"] as? [String: Any],
                  (c["rowId"] as? NSNumber)?.int64Value == expected.rowId,
                  c["keySha256"] as? String == expected.keySha256 else { throw mismatch }
        } else if let c = obj["endCursor"], !(c is NSNull) {
            throw mismatch
        }
        return Ack(batchId: batch.batchId, acceptedRows: batch.recordCount)
    }
}
