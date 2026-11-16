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

    // MARK: Review fixes: flip-flopping content, lost acknowledgements, cancellation

    func testAFlipFlopNeverReusesAnIdentityEvenOnTheFourthDelivery() async throws {
        let src = FakeSource()
        let t = FakeTransport(streams: extNames, version: .ext)
        let e = try makeEngine(src, t)
        for recovery in [50.0, 80.0, 50.0, 80.0] {  // A, B, A, B
            src.set(spec("dailyMetric"), [dailyRow("2026-08-01", recovery: recovery)])
            _ = await run(e)
        }
        XCTAssertEqual(t.posted.count, 4)
        XCTAssertEqual(Set(t.posted.map { $0.batchId }).count, 4, "a repeated batch id would be answered from the receiver's cache")
        XCTAssertEqual(Set(t.posted.map { self.window($0)?["replacementId"] as? String }).count, 4)
    }

    func testASnapshotFlipFlopNeverReusesAnIdentityEither() async throws {
        let src = FakeSource()
        let t = FakeTransport(streams: extNames, version: .ext)
        let e = try makeEngine(src, t)
        for n in [1, 2, 1, 2] {
            src.set(spec("liftSet"), (1...n).map { liftSetRow($0) })
            _ = await run(e)
        }
        XCTAssertEqual(t.posted.count, 4)
        XCTAssertEqual(Set(t.posted.map { $0.batchId }).count, 4)
    }

    func testALostAcknowledgementFollowedByARevertStillResendsTheWindow() async throws {
        let src = FakeSource()
        let t = FakeTransport(streams: extNames, version: .ext)
        let e = try makeEngine(src, t)
        src.set(spec("dailyMetric"), [dailyRow("2026-08-01", recovery: 50)])  // A, acknowledged
        _ = await run(e)
        src.set(spec("dailyMetric"), [dailyRow("2026-08-01", recovery: 80)])  // B: the POST may be applied
        t.failOn = { _ in .retryable("timeout, acknowledgement lost") }       // but we never hear back
        _ = await run(e)
        src.set(spec("dailyMetric"), [dailyRow("2026-08-01", recovery: 50)])  // the data goes back to A
        t.failOn = nil
        let r = await run(e)
        XCTAssertTrue(r.completed)
        XCTAssertEqual(t.posted.count, 2, "hashes equal A again, but the receiver may hold B: A must be re-sent")
        XCTAssertTrue(recordLines(t.posted[1])[0].contains("\"recovery\":50.0"))
        let after = await run(e)
        XCTAssertEqual(after.sentRows, 0, "once acknowledged there is nothing left to force")
        XCTAssertEqual(t.posted.count, 2)
    }

    func testALostAcknowledgementFollowedByARevertStillResendsTheSnapshot() async throws {
        let src = FakeSource()
        let t = FakeTransport(streams: extNames, version: .ext)
        let e = try makeEngine(src, t)
        src.set(spec("liftSet"), [liftSetRow(1)])
        _ = await run(e)
        src.set(spec("liftSet"), [liftSetRow(1), liftSetRow(2)])
        t.failOn = { _ in .retryable("acknowledgement lost") }
        _ = await run(e)
        src.set(spec("liftSet"), [liftSetRow(1)])
        t.failOn = nil
        _ = await run(e)
        XCTAssertEqual(t.posted.count, 2)
        XCTAssertEqual(t.posted[1].recordCount, 1)
        let after = await run(e)
        XCTAssertEqual(after.sentRows, 0)
        XCTAssertEqual(t.posted.count, 2)
    }

    func testCancellationBetweenWindowPartsStopsCleanlyAndTheRetryIsByteIdentical() async throws {
        let src = FakeSource()
        src.set(spec("sleepSession"), (0..<6000).map { sleepRow(1_780_000_000 + Int64($0)) })
        let t = FakeTransport(streams: extNames, version: .ext)
        let e = try makeEngine(src, t)
        // iOS takes the background time back after part 1: cancel the task the engine is running in
        t.onPost = { _ in withUnsafeCurrentTask { $0?.cancel() } }
        let r = await Task { await e.runOnce(.backgroundTask, deadline: self.farFuture) }.value
        XCTAssertEqual(t.posted.map { $0.recordCount }, [5000], "part 2 must not start after cancellation")
        XCTAssertEqual(r.pendingStreams, ["sleepSession"])
        XCTAssertNil(r.error)
        t.onPost = nil
        let resumed = await run(e)
        XCTAssertTrue(resumed.completed)
        XCTAssertEqual(t.posted.map { $0.recordCount }, [5000, 5000, 1000])
        XCTAssertEqual(t.posted[0].batchId, t.posted[1].batchId, "same generation: the retried part 1 is identical")
        XCTAssertEqual(t.posted[0].body, t.posted[1].body)
    }

    func testCancellationBetweenSnapshotPartsStopsCleanly() async throws {
        let src = FakeSource()
        src.set(spec("liftSet"), (1...7000).map { liftSetRow($0) })
        let t = FakeTransport(streams: extNames, version: .ext)
        let e = try makeEngine(src, t)
        t.onPost = { _ in withUnsafeCurrentTask { $0?.cancel() } }
        let r = await Task { await e.runOnce(.backgroundTask, deadline: self.farFuture) }.value
        XCTAssertEqual(t.posted.map { $0.recordCount }, [5000])
        XCTAssertEqual(r.pendingStreams, ["liftSet"])
        XCTAssertNil(r.error)
    }

    func testTheDeadlineIsCheckedBetweenWindowPartsToo() async throws {
        let src = FakeSource()
        src.set(spec("sleepSession"), (0..<6000).map { sleepRow(1_780_000_000 + Int64($0)) })
        let t = FakeTransport(streams: extNames, version: .ext)
        let e = try makeEngine(src, t)
        var clock = Date(timeIntervalSince1970: 1000)
        t.onPost = { _ in clock = Date(timeIntervalSince1970: 5000) }
        let r = await e.runOnce(.offloadLanded, deadline: Date(timeIntervalSince1970: 1010), now: { clock })
        XCTAssertEqual(t.posted.count, 1)
        XCTAssertEqual(r.pendingStreams, ["sleepSession"])
    }

    // MARK: appleStepHour is revised in place by the app, so it is a window on ts

    func testAppleStepHourIsSentAsATsWindowAndARevisedHourIsResent() async throws {
        let ts: Int64 = 1_774_740_600  // 2026-03-29 00:30 Paris, the 23-hour day
        let src = FakeSource()
        src.set(spec("appleStepHour"), [SourceRow(rowId: 0, key: ["ts": .int(ts)], data: ["steps": .int(100)])])
        let t = FakeTransport(streams: extNames, version: .ext)
        let e = try makeEngine(src, t)
        _ = await run(e)
        let h = header(t.posted[0])
        XCTAssertEqual(h["delivery"] as? String, "replace_window")
        XCTAssertEqual(window(t.posted[0])?["selector"] as? String, "ts")
        XCTAssertEqual(window(t.posted[0])?["startInclusive"] as? Int, 1_774_738_800)
        XCTAssertEqual(window(t.posted[0])?["endExclusive"] as? Int, 1_774_738_800 + 23 * 3600)
        // HealthKit revises the hour while it is still in progress
        src.set(spec("appleStepHour"), [SourceRow(rowId: 0, key: ["ts": .int(ts)], data: ["steps": .int(150)])])
        let r = await run(e)
        XCTAssertEqual(r.sentRows, 1)
        XCTAssertTrue(recordLines(t.posted[1])[0].contains("\"steps\":150"))
    }
}
