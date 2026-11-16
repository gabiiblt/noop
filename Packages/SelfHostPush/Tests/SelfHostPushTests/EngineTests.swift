import XCTest
@testable import SelfHostPush

final class FakeTransport: PushTransporting {
    var caps: Capabilities
    /// Every batch handed to `post`, including ones that then failed.
    var attempts: [EncodedBatch] = []
    var posted: [EncodedBatch] = []
    var failOn: ((EncodedBatch) -> PushError?)?
    var capabilitiesError: PushError?
    var onPost: ((EncodedBatch) -> Void)?

    init(streams: [String] = PushRegistry.v1.map { $0.name }, version: PushVersion = .v1,
         state: String = "5fc7b9a0-8055-4e49-a308-3a290f98d81a") {
        caps = Capabilities(protocolVersion: version, receiverStateId: state, streams: Set(streams))
    }

    func capabilities(_ endpoint: PushEndpoint, accept: [PushVersion]) async throws -> Capabilities {
        if let e = capabilitiesError { throw e }
        return caps
    }

    func post(_ endpoint: PushEndpoint, batch: EncodedBatch, version: PushVersion) async throws -> Ack {
        attempts.append(batch)
        if let e = failOn?(batch) { throw e }
        posted.append(batch)
        onPost?(batch)
        return Ack(batchId: batch.batchId, acceptedRows: batch.recordCount)
    }
}

func header(_ b: EncodedBatch) -> [String: Any] {
    let first = String(decoding: b.body, as: UTF8.self).split(separator: "\n").first.map(String.init) ?? "{}"
    return (try? JSONSerialization.jsonObject(with: Data(first.utf8))) as? [String: Any] ?? [:]
}

func recordLines(_ b: EncodedBatch) -> [String] {
    return Array(String(decoding: b.body, as: UTF8.self).split(separator: "\n").dropFirst()).map(String.init)
}

func dailyRow(_ day: String, recovery: Double = 50) -> SourceRow {
    return SourceRow(rowId: 0, key: ["day": .string(day)], data: ["recovery": .double(recovery)])
}

func sleepRow(_ start: Int64, edited: Bool = false) -> SourceRow {
    return SourceRow(rowId: 0, key: ["startTs": .int(start)],
                     data: ["endTs": .int(start + 100), "userEdited": .bool(edited)])
}

final class EngineTests: XCTestCase {
    private let endpoint = PushEndpoint(urlString: "https://server.tailfb9ed9.ts.net/push", token: "tok")!
    private var hr: StreamSpec { return PushRegistry.spec(named: "hrSample")! }
    private var daily: StreamSpec { return PushRegistry.spec(named: "dailyMetric")! }
    private var sleep: StreamSpec { return PushRegistry.spec(named: "sleepSession")! }
    private var paris: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Paris")!
        return c
    }
    private var farFuture: Date { return Date(timeIntervalSinceNow: 3600) }

    private func engine(_ source: FakeSource, _ transport: FakeTransport,
                        progress: ProgressStore? = nil) throws -> (PushEngine, ProgressStore) {
        let p = try progress ?? ProgressStore(url: tempURL())
        return (PushEngine(source: source, progress: p, transport: transport, endpoint: endpoint, calendar: paris), p)
    }

    private func run(_ e: PushEngine) async -> PushRunResult {
        return await e.runOnce(.manual, deadline: farFuture)
    }

    // MARK: Append

    func testAppendAdvancesCursorOnlyAfterValidAck() async throws {
        let src = FakeSource()
        src.set(hr, [hrRow(1, ts: 100), hrRow(2, ts: 200), hrRow(3, ts: 300)])
        let t = FakeTransport(streams: ["hrSample"])
        t.failOn = { _ in .retryable("down") }
        let (e, p) = try engine(src, t)
        let ns = p.namespace(endpoint: endpoint.url, version: .v1, receiverStateId: t.caps.receiverStateId)
        let r1 = await run(e)
        XCTAssertEqual(r1.error, .retryable("down"))
        XCTAssertNil(try p.cursor(ns: ns, device: "strap", stream: "hrSample"))
        t.failOn = nil
        let r2 = await run(e)
        XCTAssertTrue(r2.completed)
        XCTAssertEqual(r2.sentRows, 3)
        XCTAssertEqual(try p.cursor(ns: ns, device: "strap", stream: "hrSample")?.rowId, 3)
    }

    func testRetryAfterFailureReusesIdenticalBatchIdAndBytes() async throws {
        let src = FakeSource()
        src.set(hr, [hrRow(1, ts: 100), hrRow(2, ts: 200)])
        let t = FakeTransport(streams: ["hrSample"])
        t.failOn = { _ in .retryable("timeout before the ack arrived") }
        let (e, _) = try engine(src, t)
        _ = await run(e)
        t.failOn = nil
        _ = await run(e)
        XCTAssertEqual(t.attempts.count, 2)
        XCTAssertEqual(t.attempts[0].batchId, t.attempts[1].batchId)
        XCTAssertEqual(t.attempts[0].body, t.attempts[1].body)
    }

    func testBackfilledOldTsRowsAreNotStranded() async throws {
        let src = FakeSource()
        src.set(hr, [hrRow(1, ts: 1000), hrRow(2, ts: 2000)])
        let t = FakeTransport(streams: ["hrSample"])
        let (e, _) = try engine(src, t)
        _ = await run(e)
        // a later offload inserts an OLDER timestamp: it gets a higher rowid
        src.set(hr, [hrRow(1, ts: 1000), hrRow(2, ts: 2000), hrRow(3, ts: 50)])
        let r = await run(e)
        XCTAssertEqual(r.sentRows, 1)
        XCTAssertTrue(recordLines(t.posted.last!)[0].contains("\"ts\":50"))
    }

    func testBatchesRespectRecordLimitAndChainCursors() async throws {
        let src = FakeSource()
        src.set(hr, (1...12000).map { hrRow(Int64($0), ts: Int64(1000 + $0)) })
        let t = FakeTransport(streams: ["hrSample"])
        let (e, _) = try engine(src, t)
        let r = await run(e)
        XCTAssertEqual(r.sentRows, 12000)
        XCTAssertEqual(t.posted.map { $0.recordCount }, [5000, 5000, 2000])
        let h1 = header(t.posted[0])
        let h2 = header(t.posted[1])
        XCTAssertTrue(h1["startCursor"] is NSNull)
        XCTAssertEqual((h2["startCursor"] as? [String: Any])?["rowId"] as? Int, 5000)
        XCTAssertEqual((h2["startCursor"] as? [String: Any])?["keySha256"] as? String,
                       (h1["endCursor"] as? [String: Any])?["keySha256"] as? String)
    }

    func testUnadvertisedStreamNeverReadOrSent() async throws {
        let src = FakeSource()
        src.set(hr, [hrRow(1, ts: 1)])
        src.set(PushRegistry.spec(named: "battery")!, [SourceRow(rowId: 1, key: ["ts": .int(1)], data: [:])])
        let t = FakeTransport(streams: ["hrSample"])
        let (e, _) = try engine(src, t)
        _ = await run(e)
        XCTAssertEqual(Set(src.readStreams), ["hrSample"])
        XCTAssertEqual(Set(t.posted.map { $0.stream }), ["hrSample"])
    }

    func testStaleCursorTriggersReplayFromTheStart() async throws {
        let src = FakeSource()
        src.set(hr, [hrRow(1, ts: 100), hrRow(2, ts: 200)])
        let t = FakeTransport(streams: ["hrSample"])
        let (e, p) = try engine(src, t)
        _ = await run(e)
        // database replaced / VACUUMed: same rowids now hold different rows
        src.set(hr, [hrRow(1, ts: 7000), hrRow(2, ts: 8000)])
        let r = await run(e)
        XCTAssertEqual(r.sentRows, 2, "must replay, not skip")
        XCTAssertTrue(recordLines(t.posted.last!)[0].contains("\"ts\":7000"))
        XCTAssertNotNil(p)
    }

    func testReceiverStateChangeStartsFreshBaseline() async throws {
        let src = FakeSource()
        src.set(hr, [hrRow(1, ts: 100)])
        let t = FakeTransport(streams: ["hrSample"])
        let (e, _) = try engine(src, t)
        _ = await run(e)
        let again = await run(e)
        XCTAssertEqual(again.sentRows, 0)
        t.caps = Capabilities(protocolVersion: .v1, receiverStateId: "11111111-2222-4333-8444-555555555555",
                              streams: ["hrSample"])
        let rotated = await run(e)
        XCTAssertEqual(rotated.sentRows, 1, "a rotated receiver state id means a full replay")
    }

    // MARK: Errors and deadline

    func testDeadlineStopsBetweenBatchesWithoutLosingProgress() async throws {
        let src = FakeSource()
        src.set(hr, (1...12000).map { hrRow(Int64($0), ts: Int64($0)) })
        let t = FakeTransport(streams: ["hrSample"])
        let (e, p) = try engine(src, t)
        var clock = Date(timeIntervalSince1970: 1000)
        let deadline = Date(timeIntervalSince1970: 1010)
        t.onPost = { _ in clock = Date(timeIntervalSince1970: 2000) }  // time runs out after batch 1
        let r = await e.runOnce(.backgroundTask, deadline: deadline, now: { clock })
        XCTAssertEqual(r.sentRows, 5000)
        XCTAssertEqual(r.pendingStreams, ["hrSample"])
        XCTAssertNil(r.error)
        let ns = p.namespace(endpoint: endpoint.url, version: .v1, receiverStateId: t.caps.receiverStateId)
        XCTAssertEqual(try p.cursor(ns: ns, device: "strap", stream: "hrSample")?.rowId, 5000)
        clock = Date(timeIntervalSince1970: 1000)
        t.onPost = nil
        let resumed = await e.runOnce(.foreground, deadline: deadline, now: { clock })
        XCTAssertEqual(resumed.sentRows, 7000)
        XCTAssertTrue(resumed.completed)
    }

    func testRetryableErrorStopsTheRunAndKeepsProgress() async throws {
        let src = FakeSource()
        src.set(hr, [hrRow(1, ts: 1)])
        src.set(sleep, [sleepRow(1000)])
        let t = FakeTransport(streams: ["hrSample", "sleepSession"])
        t.failOn = { _ in .retryable("offline") }
        let (e, _) = try engine(src, t)
        let r = await run(e)
        XCTAssertEqual(r.error, .retryable("offline"))
        XCTAssertEqual(t.attempts.count, 1, "no point trying other streams while the network is down")
        XCTAssertFalse(r.completed)
    }

    func testRejectedStreamDoesNotBlockOthers() async throws {
        let src = FakeSource()
        src.set(hr, [hrRow(1, ts: 1)])
        src.set(sleep, [sleepRow(1000)])
        src.set(PushRegistry.spec(named: "battery")!, [SourceRow(rowId: 1, key: ["ts": .int(1)], data: [:])])
        let t = FakeTransport(streams: ["hrSample", "sleepSession", "battery"])
        t.failOn = { $0.stream == "sleepSession" ? .rejected("HTTP 422") : nil }
        let (e, _) = try engine(src, t)
        let r = await run(e)
        XCTAssertEqual(Set(t.posted.map { $0.stream }), ["hrSample", "battery"])
        XCTAssertEqual(r.error, .rejected("HTTP 422"))
        XCTAssertEqual(r.pendingStreams, ["sleepSession"])
    }

    func testFatalErrorStopsTheRun() async throws {
        let src = FakeSource()
        src.set(hr, [hrRow(1, ts: 1)])
        src.set(PushRegistry.spec(named: "battery")!, [SourceRow(rowId: 1, key: ["ts": .int(1)], data: [:])])
        let t = FakeTransport(streams: ["hrSample", "battery"])
        t.failOn = { _ in .fatal("authentication failed (HTTP 401)") }
        let (e, _) = try engine(src, t)
        let r = await run(e)
        XCTAssertEqual(t.attempts.count, 1)
        XCTAssertEqual(r.error, .fatal("authentication failed (HTTP 401)"))
    }

    func testCapabilitiesFailureSendsNothingAndReportsError() async throws {
        let src = FakeSource()
        src.set(hr, [hrRow(1, ts: 1)])
        let t = FakeTransport()
        t.capabilitiesError = .fatal("invalid capabilities document")
        let (e, _) = try engine(src, t)
        let r = await run(e)
        XCTAssertEqual(r.error, .fatal("invalid capabilities document"))
        XCTAssertTrue(t.attempts.isEmpty)
        XCTAssertTrue(src.readStreams.isEmpty, "no health data may be read before capabilities succeed")
    }

    // MARK: Replace-window

    func testWindowSendsChangedDaysOnlyAndUnchangedDaysSendNothing() async throws {
        let src = FakeSource()
        src.set(daily, [dailyRow("2026-08-01"), dailyRow("2026-08-02"), dailyRow("2026-08-03")])
        let t = FakeTransport(streams: ["dailyMetric"])
        let (e, _) = try engine(src, t)
        let r1 = await run(e)
        XCTAssertEqual(r1.sentRows, 3)
        XCTAssertEqual(t.posted.count, 1)
        let w1 = header(t.posted[0])["window"] as? [String: Any]
        XCTAssertEqual(w1?["startInclusive"] as? String, "2026-08-01")
        XCTAssertEqual(w1?["endExclusive"] as? String, "2026-08-04")
        let r2 = await run(e)
        XCTAssertEqual(r2.sentRows, 0)
        XCTAssertEqual(t.posted.count, 1, "unchanged days must not be re-sent")
        src.set(daily, [dailyRow("2026-08-01"), dailyRow("2026-08-02", recovery: 80), dailyRow("2026-08-03")])
        let r3 = await run(e)
        XCTAssertEqual(r3.sentRows, 1)
        let w3 = header(t.posted[1])["window"] as? [String: Any]
        XCTAssertEqual(w3?["startInclusive"] as? String, "2026-08-02")
        XCTAssertEqual(w3?["endExclusive"] as? String, "2026-08-03")
    }

    func testDeletedDayEmitsEmptyAuthoritativeWindow() async throws {
        let src = FakeSource()
        src.set(daily, [dailyRow("2026-08-01"), dailyRow("2026-08-02")])
        let t = FakeTransport(streams: ["dailyMetric"])
        let (e, _) = try engine(src, t)
        _ = await run(e)
        src.set(daily, [dailyRow("2026-08-01")])
        let r = await run(e)
        XCTAssertTrue(r.completed)
        let last = t.posted.last!
        XCTAssertEqual(last.recordCount, 0)
        let w = header(last)["window"] as? [String: Any]
        XCTAssertEqual(w?["startInclusive"] as? String, "2026-08-02")
        XCTAssertEqual(w?["endExclusive"] as? String, "2026-08-03")
        let again = await run(e)
        XCTAssertEqual(again.sentRows, 0)
        XCTAssertEqual(t.posted.count, 2)
    }

    func testFarApartChangedDaysBecomeSeparateWindows() async throws {
        let src = FakeSource()
        src.set(daily, [dailyRow("2026-01-05"), dailyRow("2026-06-20")])
        let t = FakeTransport(streams: ["dailyMetric"])
        let (e, _) = try engine(src, t)
        _ = await run(e)
        XCTAssertEqual(t.posted.count, 2)
        XCTAssertEqual(t.posted.map { $0.recordCount }, [1, 1])
        XCTAssertNotEqual((header(t.posted[0])["window"] as? [String: Any])?["replacementId"] as? String,
                          (header(t.posted[1])["window"] as? [String: Any])?["replacementId"] as? String)
    }

    func testWindowBoundsForStartTsStreamsAreLocalParisMidnights() async throws {
        // 2026-03-28 23:30 UTC is 2026-03-29 00:30 Paris (the spring-forward day, 23 h long)
        let start: Int64 = 1_774_740_600
        let src = FakeSource()
        src.set(sleep, [sleepRow(start)])
        let t = FakeTransport(streams: ["sleepSession"])
        let (e, _) = try engine(src, t)
        _ = await run(e)
        let w = header(t.posted[0])["window"] as? [String: Any]
        XCTAssertEqual(w?["startInclusive"] as? Int, 1_774_738_800)  // 2026-03-29 00:00 +01:00 = 23:00 UTC
        XCTAssertEqual(w?["endExclusive"] as? Int, 1_774_738_800 + 23 * 3600)
    }

    func testHashesAdvanceOnlyAfterEveryPartIsAcknowledged() async throws {
        let src = FakeSource()
        // 6,000 sessions (spanning local midnight) -> one window, two parts (5,000 + 1,000)
        src.set(sleep, (0..<6000).map { sleepRow(1_780_000_000 + Int64($0)) })
        let t = FakeTransport(streams: ["sleepSession"])
        t.failOn = { b in ((header(b)["window"] as? [String: Any])?["part"] as? Int) == 2 ? .retryable("drop") : nil }
        let (e, _) = try engine(src, t)
        let r1 = await run(e)
        XCTAssertEqual(r1.error, .retryable("drop"))
        t.failOn = nil
        let r2 = await run(e)
        XCTAssertTrue(r2.completed, "hashes must not have advanced after a half-sent replacement")
        XCTAssertEqual(r2.sentRows, 6000)
        // run 1 delivered part 1 and failed part 2; run 2 re-sent part 1 byte-identically, then part 2
        let partNumbers = t.posted.map { (header($0)["window"] as? [String: Any])?["part"] as? Int }
        XCTAssertEqual(partNumbers, [1, 1, 2])
        XCTAssertEqual(t.posted[0].batchId, t.posted[1].batchId)
        XCTAssertEqual(t.posted[0].body, t.posted[1].body)
        let ids = t.posted.map { (header($0)["window"] as? [String: Any])?["replacementId"] as? String }
        XCTAssertEqual(Set(ids).count, 1, "one replacement generation across both runs")
    }

    // MARK: Devices

    func testRememberedDeviceStillGetsItsEmptyWindowAfterLiveDiscoveryForgetsIt() async throws {
        let src = FakeSource()
        src.devices = ["strap", "old-strap"]
        src.set(daily, device: "old-strap", [dailyRow("2026-08-01")])
        let t = FakeTransport(streams: ["dailyMetric"])
        let (e, _) = try engine(src, t)
        _ = await run(e)
        XCTAssertEqual(t.posted.map { $0.deviceId }, ["old-strap"])
        src.devices = ["strap"]  // live discovery no longer lists it ...
        src.set(daily, device: "old-strap", [])  // ... and its last row is gone
        let r = await run(e)
        XCTAssertTrue(r.completed)
        XCTAssertEqual(t.posted.last?.deviceId, "old-strap")
        XCTAssertEqual(t.posted.last?.recordCount, 0)
    }

    func testEachDeviceIsScopedSeparately() async throws {
        let src = FakeSource()
        src.devices = ["a", "b"]
        src.set(hr, device: "a", [hrRow(1, ts: 1)])
        src.set(hr, device: "b", [hrRow(1, ts: 1)])
        let t = FakeTransport(streams: ["hrSample"])
        let (e, _) = try engine(src, t)
        _ = await run(e)
        XCTAssertEqual(t.posted.map { $0.deviceId }.sorted(), ["a", "b"])
    }

    func testCheapStreamsAreSentBeforeTheRest() async throws {
        let src = FakeSource()
        src.set(PushRegistry.spec(named: "gravitySample")!, [SourceRow(rowId: 1, key: ["ts": .int(1)],
                                                                      data: ["x": .double(0), "y": .double(0), "z": .double(1)])])
        src.set(hr, [hrRow(1, ts: 1)])
        src.set(daily, [dailyRow("2026-08-01")])
        let t = FakeTransport(streams: PushRegistry.v1.map { $0.name })
        let (e, _) = try engine(src, t)
        _ = await run(e)
        XCTAssertEqual(t.posted.map { $0.stream }, ["hrSample", "dailyMetric", "gravitySample"])
    }
}
