import XCTest
@testable import SelfHostPush

final class StubURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?
    static var requests: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { return true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { return request }

    override func startLoading() {
        StubURLProtocol.requests.append(request)
        do {
            let (status, data) = try StubURLProtocol.handler!(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

func bodyData(of request: URLRequest) -> Data {
    if let b = request.httpBody { return b }
    guard let stream = request.httpBodyStream else { return Data() }
    stream.open()
    defer { stream.close() }
    var out = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while stream.hasBytesAvailable {
        let n = stream.read(&buffer, maxLength: buffer.count)
        if n <= 0 { break }
        out.append(buffer, count: n)
    }
    return out
}

final class TransportTests: XCTestCase {
    private let stateId = "5fc7b9a0-8055-4e49-a308-3a290f98d81a"
    private let endpoint = PushEndpoint(urlString: "https://server.tailfb9ed9.ts.net/push", token: "tok")!

    override func setUp() {
        super.setUp()
        StubURLProtocol.requests = []
        StubURLProtocol.handler = nil
    }

    private func transport() -> PushTransport {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return PushTransport(session: PushTransport.makeSession(configuration: config))
    }

    private func json(_ obj: [String: Any]) -> Data {
        return try! JSONSerialization.data(withJSONObject: obj)
    }

    private func batch(endCursor: Cursor? = Cursor(rowId: 9, keySha256: String(repeating: "d", count: 64))) -> EncodedBatch {
        let spec = PushRegistry.spec(named: "hrSample")!
        let line = encodeRecordLine(spec, key: ["ts": .int(1)], data: ["bpm": .int(60)], ext: false)
        return encodeBatch(version: .v1, sourceId: "3a3486dd-5030-4e17-a00d-a781399890f9", deviceId: "strap",
                           spec: spec, recordLines: [line], startCursor: nil, endCursor: endCursor, window: nil)
    }

    private func ackJSON(for b: EncodedBatch, mutate: ((inout [String: Any]) -> Void)? = nil) -> Data {
        var obj: [String: Any] = ["protocolVersion": "1.0", "batchId": b.batchId, "stream": b.stream,
                                  "deviceId": b.deviceId, "acceptedRows": b.recordCount, "status": "accepted"]
        if let c = b.endCursor {
            obj["endCursor"] = ["rowId": c.rowId, "keySha256": c.keySha256] as [String: Any]
        } else {
            obj["endCursor"] = NSNull()
        }
        mutate?(&obj)
        return json(obj)
    }

    func testEndpointRequiresHttpsHostAndToken() {
        XCTAssertNil(PushEndpoint(urlString: "http://server.ts.net/push", token: "t"))
        XCTAssertNil(PushEndpoint(urlString: "https://", token: "t"))
        XCTAssertNil(PushEndpoint(urlString: "https://server.ts.net/push", token: "  "))
        XCTAssertNil(PushEndpoint(urlString: "not a url", token: "t"))
        XCTAssertNotNil(PushEndpoint(urlString: " https://server.ts.net/push ", token: " t "))
        XCTAssertEqual(PushEndpoint(urlString: "https://server.ts.net/push", token: " t ")?.token, "t")
    }

    func testCapabilitiesParsedAndRequestShape() async throws {
        StubURLProtocol.handler = { _ in
            (200, self.json(["type": "capabilities", "protocolVersion": "1.100", "receiverStateId": self.stateId,
                             "streams": ["hrSample", "stepSample"]]))
        }
        let caps = try await transport().capabilities(endpoint, accept: [.ext, .v1])
        XCTAssertEqual(caps, Capabilities(protocolVersion: .ext, receiverStateId: stateId,
                                          streams: ["hrSample", "stepSample"]))
        let req = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(req.httpMethod, "GET")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
        XCTAssertEqual(req.value(forHTTPHeaderField: "NOOP-Push-Accept-Version"), "1.100,1.0")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Accept"), "application/json")
    }

    func testCapabilitiesRejectsUnofferedVersionUnknownDuplicateAndBadStateId() async {
        let cases: [[String: Any]] = [
            ["type": "capabilities", "protocolVersion": "1.0", "receiverStateId": stateId, "streams": ["stepSample"]],
            ["type": "capabilities", "protocolVersion": "1.0", "receiverStateId": stateId, "streams": ["hrSample", "hrSample"]],
            ["type": "capabilities", "protocolVersion": "1.0", "receiverStateId": stateId, "streams": ["nope"]],
            ["type": "capabilities", "protocolVersion": "1.0", "receiverStateId": stateId.uppercased(), "streams": []],
            ["type": "nope", "protocolVersion": "1.0", "receiverStateId": stateId, "streams": []],
            ["type": "capabilities", "protocolVersion": "7.7", "receiverStateId": stateId, "streams": []],
        ]
        for c in cases {
            StubURLProtocol.handler = { _ in (200, self.json(c)) }
            do {
                _ = try await transport().capabilities(endpoint, accept: [.v1])
                XCTFail("accepted \(c)")
            } catch let e as PushError {
                XCTAssertFalse(e.isRetryable, "\(c)")
            } catch {
                XCTFail("wrong error \(error)")
            }
        }
    }

    func testEmptyStreamListIsValid() async throws {
        StubURLProtocol.handler = { _ in
            (200, self.json(["type": "capabilities", "protocolVersion": "1.0", "receiverStateId": self.stateId,
                             "streams": [String]()]))
        }
        let caps = try await transport().capabilities(endpoint, accept: [.v1])
        XCTAssertTrue(caps.streams.isEmpty)
    }

    func testCapabilitiesOver16KiBRejected() async {
        StubURLProtocol.handler = { _ in (200, Data(repeating: 0x20, count: 16 * 1024 + 1)) }
        do {
            _ = try await transport().capabilities(endpoint, accept: [.v1])
            XCTFail("accepted oversized document")
        } catch let e as PushError {
            XCTAssertFalse(e.isRetryable)
        } catch {
            XCTFail("wrong error \(error)")
        }
    }

    func testPostSendsNdjsonBodyUnchangedAndValidatesAck() async throws {
        let b = batch()
        StubURLProtocol.handler = { _ in (200, self.ackJSON(for: b)) }
        let ack = try await transport().post(endpoint, batch: b, version: .v1)
        XCTAssertEqual(ack, Ack(batchId: b.batchId, acceptedRows: 1))
        let req = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Type"), "application/x-ndjson; charset=utf-8")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
        XCTAssertNil(req.value(forHTTPHeaderField: "Content-Encoding"))
        XCTAssertEqual(bodyData(of: req), b.body)
    }

    func testMismatchedAckIsFatalNotAccepted() async {
        let b = batch()
        let mutations: [(inout [String: Any]) -> Void] = [
            { $0["batchId"] = "00000000-0000-4000-8000-000000000000" },
            { $0["acceptedRows"] = 0 },
            { $0["status"] = "queued" },
            { $0["stream"] = "battery" },
            { $0["deviceId"] = "other" },
            { $0["protocolVersion"] = "1.100" },
            { $0["endCursor"] = ["rowId": 8, "keySha256": String(repeating: "d", count: 64)] as [String: Any] },
            { $0["endCursor"] = NSNull() },
            { $0.removeValue(forKey: "status") },
        ]
        for m in mutations {
            StubURLProtocol.handler = { _ in (200, self.ackJSON(for: b, mutate: m)) }
            do {
                _ = try await transport().post(endpoint, batch: b, version: .v1)
                XCTFail("accepted a mismatched acknowledgement")
            } catch let e as PushError {
                XCTAssertFalse(e.isRetryable)
            } catch {
                XCTFail("wrong error \(error)")
            }
        }
    }

    func testWindowAckRequiresNullEndCursor() async {
        let spec = PushRegistry.spec(named: "sleepSession")!
        let w = WindowSpec(replacementId: "bf8b735e-f157-4a35-beb2-9b086d10d5bd", selector: "startTs",
                           startInclusive: .int(0), endExclusive: .int(10), part: 1, parts: 1)
        let b = encodeBatch(version: .v1, sourceId: "3a3486dd-5030-4e17-a00d-a781399890f9", deviceId: "d", spec: spec,
                            recordLines: [], startCursor: nil, endCursor: nil, window: w)
        StubURLProtocol.handler = { _ in (200, self.ackJSON(for: b)) }
        do {
            let ack = try await transport().post(endpoint, batch: b, version: .v1)
            XCTAssertEqual(ack.acceptedRows, 0)
        } catch {
            XCTFail("rejected a valid window ack: \(error)")
        }
        StubURLProtocol.handler = { _ in
            (200, self.ackJSON(for: b, mutate: { $0["endCursor"] = ["rowId": 1, "keySha256": "x"] as [String: Any] }))
        }
        do {
            _ = try await transport().post(endpoint, batch: b, version: .v1)
            XCTFail("accepted a non-null endCursor for a window part")
        } catch {}
    }

    func testStatusClassification() async {
        let expectations: [(Int, Bool)] = [(408, true), (429, true), (500, true), (503, true), (599, true),
                                           (400, false), (401, false), (403, false), (404, false), (406, false),
                                           (409, false), (413, false), (422, false), (302, false), (301, false)]
        for (status, retryable) in expectations {
            StubURLProtocol.handler = { _ in (status, self.json(["type": "error", "protocolVersion": "1.0", "code": "boom"])) }
            do {
                _ = try await transport().post(endpoint, batch: batch(), version: .v1)
                XCTFail("HTTP \(status) accepted")
            } catch let e as PushError {
                XCTAssertEqual(e.isRetryable, retryable, "HTTP \(status): \(e.message)")
            } catch {
                XCTFail("wrong error \(error)")
            }
        }
    }

    func testPerBatchRefusalsAreRejectedNotFatal() {
        for status in [400, 409, 413, 422] {
            XCTAssertThrowsError(try PushTransport.check(status: status, body: Data())) { error in
                XCTAssertEqual(error as? PushError, .rejected("HTTP \(status)"))
            }
        }
        for status in [401, 403, 406, 404] {
            XCTAssertThrowsError(try PushTransport.check(status: status, body: Data())) { error in
                guard case .fatal = (error as? PushError) ?? .retryable("") else { return XCTFail("HTTP \(status)") }
            }
        }
    }

    func testRedirectIsFatalAndSessionNeverFollowsRedirects() {
        XCTAssertThrowsError(try PushTransport.check(status: 302, body: Data())) { error in
            XCTAssertEqual(error as? PushError, .fatal("redirect not followed (HTTP 302)"))
        }
        let session = PushTransport.makeSession()
        XCTAssertTrue(session.delegate is NoRedirectDelegate)
        XCTAssertNil(session.configuration.httpCookieStorage)
    }

    func testNoRedirectDelegateAnswersNil() {
        let d = NoRedirectDelegate()
        let url = URL(string: "https://example.com")!
        let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: nil, headerFields: nil)!
        var answered = false
        var followed: URLRequest? = URLRequest(url: url)
        d.urlSession(URLSession.shared, task: URLSession.shared.dataTask(with: url),
                     willPerformHTTPRedirection: response, newRequest: URLRequest(url: url)) { req in
            answered = true
            followed = req
        }
        XCTAssertTrue(answered)
        XCTAssertNil(followed)
    }

    func testErrorCodeOnlySurfacedWhenValidAndNeverResponseText() {
        XCTAssertEqual(PushTransport.errorCode(json(["type": "error", "code": "registry_mismatch"])), "registry_mismatch")
        XCTAssertNil(PushTransport.errorCode(json(["code": "Has Space"])))
        XCTAssertNil(PushTransport.errorCode(json(["code": "9starts_with_digit"])))
        XCTAssertNil(PushTransport.errorCode(json(["code": String(repeating: "a", count: 65)])))
        XCTAssertNil(PushTransport.errorCode(Data("secret health data".utf8)))
        XCTAssertThrowsError(try PushTransport.check(status: 500, body: Data("hr=61 secret".utf8))) { error in
            XCTAssertEqual(error as? PushError, .retryable("HTTP 500"))
        }
    }

    func testTransportFailuresAreRetryableAndCertificateFailuresAreNot() async {
        StubURLProtocol.handler = { _ in throw URLError(.timedOut) }
        do {
            _ = try await transport().post(endpoint, batch: batch(), version: .v1)
            XCTFail("expected failure")
        } catch let e as PushError {
            XCTAssertTrue(e.isRetryable)
        } catch {
            XCTFail("wrong error \(error)")
        }
        XCTAssertFalse(PushTransport.classify(urlError: URLError(.serverCertificateUntrusted)).isRetryable)
        XCTAssertTrue(PushTransport.classify(urlError: URLError(.cannotFindHost)).isRetryable)
        XCTAssertTrue(PushTransport.classify(urlError: URLError(.notConnectedToInternet)).isRetryable)
    }

    func testWakeTokenIsPostedBesideThePushPath() async throws {
        StubURLProtocol.handler = { _ in (200, self.json(["type": "wakeToken", "status": "stored"])) }
        let token = Data([0x00, 0xa1, 0xff, 0x10])
        try await transport().registerWakeToken(endpoint, deviceToken: token, environment: "development",
                                                topic: "com.gabiwhoop.noop")
        let req = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(req.url?.absoluteString, "https://server.tailfb9ed9.ts.net/push/wake-token")
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: bodyData(of: req)) as? [String: String])
        XCTAssertEqual(body, ["deviceToken": "00a1ff10", "environment": "development", "topic": "com.gabiwhoop.noop"])
    }

    func testWakeTokenRefusalIsSurfaced() async {
        StubURLProtocol.handler = { _ in (422, self.json(["type": "error", "code": "invalid_topic"])) }
        do {
            try await transport().registerWakeToken(endpoint, deviceToken: Data([1]), environment: "development",
                                                    topic: "x")
            XCTFail("expected failure")
        } catch let e as PushError {
            XCTAssertEqual(e, .rejected("HTTP 422 (invalid_topic)"))
        } catch {
            XCTFail("wrong error \(error)")
        }
    }

    func testWakeTokenURLKeepsAnExistingTrailingSlash() {
        let e = PushEndpoint(urlString: "https://h.ts.net:8444/push/", token: "t")!
        XCTAssertEqual(PushTransport.wakeTokenURL(for: e).absoluteString, "https://h.ts.net:8444/push/wake-token")
    }
}
