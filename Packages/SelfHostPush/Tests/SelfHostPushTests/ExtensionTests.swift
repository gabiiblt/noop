import XCTest
@testable import SelfHostPush

/// Phase B: the fork's `1.100` extension (every remaining user-data table, snapshots, waveforms) and the
/// full-history behaviour of the replace-window streams.
final class ExtensionTests: XCTestCase {
    private let endpoint = PushEndpoint(urlString: "https://server.tailfb9ed9.ts.net/push", token: "tok")!
    private var paris: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Paris")!
        return c
    }
    private var farFuture: Date { return Date(timeIntervalSinceNow: 3600) }
    private var extNames: [String] { return PushRegistry.ext.map { $0.name } }

    private func makeEngine(_ src: FakeSource, _ t: FakeTransport) throws -> PushEngine {
        return PushEngine(source: src, progress: try ProgressStore(url: tempURL()), transport: t,
                          endpoint: endpoint, versions: [.ext, .v1], calendar: paris)
    }

    private func run(_ e: PushEngine) async -> PushRunResult {
        return await e.runOnce(.manual, deadline: farFuture)
    }

    private func liftSetRow(_ i: Int) -> SourceRow {
        return SourceRow(rowId: 0, key: ["id": .string(String(format: "set-%05d", i))],
                         data: ["exercise": .string("squat"), "reps": .int(5)])
    }

    private func spec(_ name: String) -> StreamSpec { return PushRegistry.spec(named: name)! }

    private func window(_ b: EncodedBatch) -> [String: Any]? { return header(b)["window"] as? [String: Any] }

    // MARK: Snapshot streams

    func testSnapshotIsSentAsWholeTableReplacementWithAllSelector() async throws {
        let src = FakeSource()
        src.set(spec("liftSet"), [liftSetRow(1), liftSetRow(2)])
        let t = FakeTransport(streams: extNames, version: .ext)
        let r = await run(try makeEngine(src, t))
        XCTAssertTrue(r.completed)
        let b = try XCTUnwrap(t.posted.first)
        let h = header(b)
        XCTAssertEqual(h["delivery"] as? String, "snapshot")
        XCTAssertEqual(h["protocolVersion"] as? String, "1.100")
        XCTAssertEqual(window(b)?["selector"] as? String, "all")
        XCTAssertEqual(window(b)?["part"] as? Int, 1)
        XCTAssertEqual(window(b)?["parts"] as? Int, 1)
        XCTAssertNil(window(b)?["startInclusive"])
        XCTAssertTrue(h["startCursor"] is NSNull)
        XCTAssertTrue(h["endCursor"] is NSNull)
        XCTAssertEqual(b.recordCount, 2)
    }

    func testSnapshotUnchangedIsElidedAndAChangeResendsTheWholeTable() async throws {
        let src = FakeSource()
        src.set(spec("liftSet"), [liftSetRow(1), liftSetRow(2)])
        let t = FakeTransport(streams: extNames, version: .ext)
        let e = try makeEngine(src, t)
        _ = await run(e)
        let again = await run(e)
        XCTAssertEqual(again.sentRows, 0)
        XCTAssertEqual(t.posted.count, 1, "unchanged snapshot must not be re-sent")
        src.set(spec("liftSet"), [liftSetRow(1), liftSetRow(2), liftSetRow(3)])
        let changed = await run(e)
        XCTAssertEqual(changed.sentRows, 3, "a snapshot replaces the whole table, not just the delta")
        XCTAssertEqual(t.posted.count, 2)
    }

    func testSnapshotEmptiedAfterBeingPopulatedSendsOneEmptyReplacement() async throws {
        let src = FakeSource()
        src.set(spec("liftSet"), [liftSetRow(1)])
        let t = FakeTransport(streams: extNames, version: .ext)
        let e = try makeEngine(src, t)
        _ = await run(e)
        src.set(spec("liftSet"), [])
        let r = await run(e)
        XCTAssertTrue(r.completed)
        XCTAssertEqual(t.posted.last?.recordCount, 0)
        XCTAssertEqual(t.posted.count, 2)
        _ = await run(e)
        XCTAssertEqual(t.posted.count, 2, "nothing more to say once the receiver has the empty table")
    }

    func testNeverPopulatedSnapshotSendsNothing() async throws {
        let src = FakeSource()
        let t = FakeTransport(streams: extNames, version: .ext)
        _ = await run(try makeEngine(src, t))
        XCTAssertTrue(t.posted.isEmpty)
    }

    func testMultipartSnapshotSplitsAtFiveThousandAndHashAdvancesOnlyAfterEveryPart() async throws {
        let src = FakeSource()
        src.set(spec("liftSet"), (1...7000).map { liftSetRow($0) })
        let t = FakeTransport(streams: extNames, version: .ext)
        t.failOn = { b in (self.window(b)?["part"] as? Int) == 2 ? .retryable("drop") : nil }
        let e = try makeEngine(src, t)
        let r1 = await run(e)
        XCTAssertEqual(r1.error, .retryable("drop"))
        t.failOn = nil
        let r2 = await run(e)
        XCTAssertTrue(r2.completed)
        XCTAssertEqual(t.posted.map { $0.recordCount }, [5000, 5000, 2000])
        XCTAssertEqual(t.posted[0].batchId, t.posted[1].batchId, "the retried part 1 is byte-identical")
        XCTAssertEqual(t.posted[0].body, t.posted[1].body)
        XCTAssertEqual(Set(t.posted.map { self.window($0)?["replacementId"] as? String }).count, 1)
    }

    func testSnapshotStreamsAreNeverReadOrSentUnderV1() async throws {
        let src = FakeSource()
        src.set(spec("liftSet"), [liftSetRow(1)])
        src.set(spec("stepSample"), [SourceRow(rowId: 1, key: ["ts": .int(1)], data: ["counter": .int(5)])])
        let t = FakeTransport(streams: PushRegistry.v1.map { $0.name }, version: .v1)
        _ = await run(try makeEngine(src, t))
        XCTAssertFalse(src.readStreams.contains("liftSet"))
        XCTAssertFalse(src.readStreams.contains("stepSample"))
        XCTAssertTrue(t.posted.isEmpty)
    }

    // MARK: Versions and members

    func testFallsBackToV1StreamsAndOmitsExtMembersWhenReceiverSelects1_0() async throws {
        let src = FakeSource()
        src.set(spec("dailyMetric"), [SourceRow(rowId: 0, key: ["day": .string("2026-08-01")],
                                                data: ["recovery": .double(61), "avgSdnn": .double(55)])])
        src.set(spec("stepSample"), [SourceRow(rowId: 1, key: ["ts": .int(1)], data: ["counter": .int(5)])])
        let t = FakeTransport(streams: PushRegistry.v1.map { $0.name }, version: .v1)
        _ = await run(try makeEngine(src, t))
        XCTAssertEqual(t.posted.map { $0.stream }, ["dailyMetric"])
        XCTAssertEqual(header(t.posted[0])["protocolVersion"] as? String, "1.0")
        XCTAssertFalse(recordLines(t.posted[0])[0].contains("avgSdnn"))
    }

    func testExtVersionSendsExtStreamsAndExtMembers() async throws {
        let src = FakeSource()
        src.set(spec("dailyMetric"), [SourceRow(rowId: 0, key: ["day": .string("2026-08-01")],
                                                data: ["recovery": .double(61), "avgSdnn": .double(55)])])
        src.set(spec("stepSample"), [SourceRow(rowId: 1, key: ["ts": .int(1)], data: ["counter": .int(5)])])
        let t = FakeTransport(streams: extNames, version: .ext)
        _ = await run(try makeEngine(src, t))
        XCTAssertEqual(Set(t.posted.map { $0.stream }), ["dailyMetric", "stepSample"])
        XCTAssertTrue(recordLines(t.posted.first { $0.stream == "dailyMetric" }!)[0].contains("\"avgSdnn\":55.0"))
        XCTAssertEqual(header(t.posted.first { $0.stream == "stepSample" }!)["protocolVersion"] as? String, "1.100")
    }

    func testBlobColumnsAreSentAsBase64Strings() async throws {
        let src = FakeSource()
        src.set(spec("ppgWaveformSample"), [SourceRow(rowId: 1, key: ["ts": .int(1)],
                                                      data: ["samples": .string("AAEC/w=="), "burstIndex": .int(2)])])
        let t = FakeTransport(streams: extNames, version: .ext)
        _ = await run(try makeEngine(src, t))
        let line = recordLines(try XCTUnwrap(t.posted.first))[0]
        XCTAssertEqual(line, "{\"type\":\"record\",\"key\":{\"ts\":1},\"data\":{\"samples\":\"AAEC/w==\",\"burstIndex\":2,\"baseCode\":null}}")
    }

    func testWaveformStreamsAreDrainedAfterTheCheapStreams() async throws {
        let src = FakeSource()
        src.set(spec("ecgWaveformSample"), [SourceRow(rowId: 1, key: ["ts": .int(1), "sequence": .int(1)],
                                                      data: ["record": .string("AA==")])])
        src.set(spec("ppgWaveformSample"), [SourceRow(rowId: 1, key: ["ts": .int(1)], data: ["samples": .string("AA==")])])
        src.set(spec("stepSample"), [SourceRow(rowId: 1, key: ["ts": .int(1)], data: ["counter": .int(1)])])
        src.set(spec("labMarker"), [SourceRow(rowId: 0, key: ["id": .string("a")], data: [:])])
        src.set(spec("dailyMetric"), [dailyRow("2026-08-01")])
        src.set(spec("hrSample"), [hrRow(1, ts: 1)])
        let t = FakeTransport(streams: extNames, version: .ext)
        _ = await run(try makeEngine(src, t))
        XCTAssertEqual(t.posted.map { $0.stream },
                       ["hrSample", "dailyMetric", "labMarker", "stepSample", "ppgWaveformSample", "ecgWaveformSample"])
    }

    // MARK: Full history and revert safety

    private func dayString(_ offset: Int) -> String {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        let start = c.date(from: DateComponents(year: 2025, month: 1, day: 1))!
        let d = c.date(byAdding: .day, value: offset, to: start)!
        let f = DateFormatter()
        f.calendar = c
        f.timeZone = c.timeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }

    func testLongHistoryIsSentOnTheFirstRunThenOnlyChangedDays() async throws {
        let src = FakeSource()
        src.set(spec("dailyMetric"), (0..<400).map { dailyRow(dayString($0)) })
        let t = FakeTransport(streams: extNames, version: .ext)
        let e = try makeEngine(src, t)
        let r1 = await run(e)
        XCTAssertEqual(r1.sentRows, 400, "the whole history, not just the last 14 days")
        XCTAssertEqual(t.posted.count, 1)
        XCTAssertEqual(window(t.posted[0])?["startInclusive"] as? String, "2025-01-01")
        let r2 = await run(e)
        XCTAssertEqual(r2.sentRows, 0)
        // an old day is edited (e.g. a re-import) and so is the newest one
        src.set(spec("dailyMetric"), (0..<400).map { dailyRow(dayString($0), recovery: ($0 == 40 || $0 == 399) ? 99 : 50) })
        let r3 = await run(e)
        XCTAssertEqual(r3.sentRows, 2, "only the two changed days, as two separate windows")
        XCTAssertEqual(t.posted.count, 3)
        XCTAssertEqual(window(t.posted[1])?["startInclusive"] as? String, dayString(40))
        XCTAssertEqual(window(t.posted[2])?["startInclusive"] as? String, dayString(399))
    }

    func testRevertingToAnEarlierStateGetsFreshIdsSoTheReceiverReapplies() async throws {
        let src = FakeSource()
        let t = FakeTransport(streams: extNames, version: .ext)
        let e = try makeEngine(src, t)
        src.set(spec("dailyMetric"), [dailyRow("2026-08-01", recovery: 50)])  // state A
        _ = await run(e)
        src.set(spec("dailyMetric"), [dailyRow("2026-08-01", recovery: 80)])  // state B
        _ = await run(e)
        src.set(spec("dailyMetric"), [dailyRow("2026-08-01", recovery: 50)])  // back to state A
        _ = await run(e)
        XCTAssertEqual(t.posted.count, 3)
        let a1 = t.posted[0], a2 = t.posted[2]
        XCTAssertEqual(a1.body.count, a2.body.count)  // same records ...
        XCTAssertNotEqual(a1.batchId, a2.batchId, "... but a receiver that cached A's ack would stay at B")
        XCTAssertNotEqual(window(a1)?["replacementId"] as? String, window(a2)?["replacementId"] as? String)
    }

    func testRevertedSnapshotAlsoGetsFreshIds() async throws {
        let src = FakeSource()
        let t = FakeTransport(streams: extNames, version: .ext)
        let e = try makeEngine(src, t)
        src.set(spec("liftSet"), [liftSetRow(1)])
        _ = await run(e)
        src.set(spec("liftSet"), [liftSetRow(1), liftSetRow(2)])
        _ = await run(e)
        src.set(spec("liftSet"), [liftSetRow(1)])
        _ = await run(e)
        XCTAssertEqual(t.posted.count, 3)
        XCTAssertNotEqual(t.posted[0].batchId, t.posted[2].batchId)
    }

    func testInterruptedAttemptAfterARevertStillRetriesByteIdentically() async throws {
        let src = FakeSource()
        let t = FakeTransport(streams: extNames, version: .ext)
        let e = try makeEngine(src, t)
        src.set(spec("dailyMetric"), [dailyRow("2026-08-01", recovery: 50)])
        _ = await run(e)
        src.set(spec("dailyMetric"), [dailyRow("2026-08-01", recovery: 80)])
        t.failOn = { _ in .retryable("timeout before the ack") }
        _ = await run(e)
        t.failOn = nil
        _ = await run(e)
        XCTAssertEqual(t.attempts.count, 3)
        XCTAssertEqual(t.attempts[1].batchId, t.attempts[2].batchId, "same prior state, same bytes, same id")
        XCTAssertEqual(t.attempts[1].body, t.attempts[2].body)
    }
}
