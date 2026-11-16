import GRDB
import WhoopStore
import XCTest
@testable import SelfHostPush

/// Runs against the REAL schema: `WhoopStore(path:)` creates and migrates the database exactly as the app does.
final class GRDBRowSourceTests: XCTestCase {
    private var rr: StreamSpec { return PushRegistry.spec(named: "rrInterval")! }
    private var hr: StreamSpec { return PushRegistry.spec(named: "hrSample")! }

    private func makeDatabase() async throws -> (path: String, writer: DatabaseQueue) {
        let path = tempURL().path
        _ = try await WhoopStore(path: path)
        return (path, try DatabaseQueue(path: path))
    }

    func testAppendPageIsOrderedByRowidAndLimited() async throws {
        let (path, w) = try await makeDatabase()
        try w.write { db in
            // inserted OUT of timestamp order, as a later offload backfills older rows
            for ts in [300, 100, 200, 50] {
                try db.execute(sql: "INSERT INTO hrSample (deviceId, ts, bpm) VALUES ('strap', ?, 60)", arguments: [ts])
            }
            try db.execute(sql: "INSERT INTO hrSample (deviceId, ts, bpm) VALUES ('other', 1, 99)")
        }
        let src = try GRDBRowSource(databasePath: path)
        let page = try src.appendPage(hr, deviceId: "strap", afterRowId: nil, limit: 3)
        XCTAssertEqual(page.map { $0.key["ts"] }, [.int(300), .int(100), .int(200)])
        let next = try src.appendPage(hr, deviceId: "strap", afterRowId: page.last!.rowId, limit: 10)
        XCTAssertEqual(next.map { $0.key["ts"] }, [.int(50)], "the backfilled old row follows by insertion order")
        XCTAssertEqual(next[0].data["bpm"], .int(60))
    }

    func testEqualRRBeatsWithDifferentSeqAreBothReturnedWithMetadata() async throws {
        let (path, w) = try await makeDatabase()
        try w.write { db in
            try db.execute(sql: "INSERT INTO rrInterval (deviceId, ts, rrMs, seq, ord, srcChannel, tsSuspect) VALUES ('strap', 5, 800, 0, 1, NULL, NULL)")
            try db.execute(sql: "INSERT INTO rrInterval (deviceId, ts, rrMs, seq, ord, srcChannel, tsSuspect) VALUES ('strap', 5, 800, 1, 2, 3, 1)")
        }
        let rows = try GRDBRowSource(databasePath: path).appendPage(rr, deviceId: "strap", afterRowId: nil, limit: 10)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].key, ["ts": .int(5), "rrMs": .int(800), "seq": .int(0)])
        XCTAssertEqual(rows[1].key["seq"], .int(1))
        XCTAssertEqual(rows[0].data["srcChannel"], .null)
        XCTAssertEqual(rows[1].data["srcChannel"], .int(3))
        XCTAssertEqual(rows[1].data["tsSuspect"], .int(1))
    }

    func testRowLookupByRowidChecksTheDevice() async throws {
        let (path, w) = try await makeDatabase()
        try w.write { db in
            try db.execute(sql: "INSERT INTO hrSample (deviceId, ts, bpm) VALUES ('strap', 7, 61)")
        }
        let src = try GRDBRowSource(databasePath: path)
        let page = try src.appendPage(hr, deviceId: "strap", afterRowId: nil, limit: 1)
        let found = try src.row(hr, deviceId: "strap", rowId: page[0].rowId)
        XCTAssertEqual(found, page[0])
        XCTAssertNil(try src.row(hr, deviceId: "someone-else", rowId: page[0].rowId))
        XCTAssertNil(try src.row(hr, deviceId: "strap", rowId: 9999))
    }

    func testWritesAreRejected() async throws {
        let (path, _) = try await makeDatabase()
        _ = try GRDBRowSource(databasePath: path)
        // the same configuration the source uses must refuse writes
        var config = Configuration()
        config.readonly = true
        let ro = try DatabaseQueue(path: path, configuration: config)
        XCTAssertThrowsError(try ro.write { db in
            try db.execute(sql: "INSERT INTO hrSample (deviceId, ts, bpm) VALUES ('x', 1, 1)")
        })
    }

    func testDeviceIdsIncludeComputedNoopSourceAndBlankDatabaseIsEmpty() async throws {
        let (path, w) = try await makeDatabase()
        XCTAssertEqual(try GRDBRowSource(databasePath: path).deviceIds(), [])
        try w.write { db in
            try db.execute(sql: "INSERT INTO dailyMetric (deviceId, day) VALUES ('strap', '2026-08-01')")
            try db.execute(sql: "INSERT INTO dailyMetric (deviceId, day) VALUES ('strap-noop', '2026-08-01')")
            try db.execute(sql: "INSERT INTO sleepSession (deviceId, startTs, endTs) VALUES ('apple-health', 1, 2)")
        }
        XCTAssertEqual(try GRDBRowSource(databasePath: path).deviceIds(), ["apple-health", "strap", "strap-noop"])
    }

    func testDeviceIdsIncludeDevicesThatOnlyHaveRowsInExtensionTables() async throws {
        let (path, w) = try await makeDatabase()
        try w.write { db in
            // mood entries are stored in metricSeries under their own device id and nowhere else
            try db.execute(sql: "INSERT INTO metricSeries (deviceId, day, key, value) VALUES ('noop-mood', '2026-08-01', 'mood', 4)")
            try db.execute(sql: "INSERT INTO appleDaily (deviceId, day, steps) VALUES ('apple-health', '2026-08-01', 5000)")
        }
        let ids = try GRDBRowSource(databasePath: path).deviceIds()
        XCTAssertTrue(ids.contains("noop-mood"))
        XCTAssertTrue(ids.contains("apple-health"))
    }

    func testAllRowsSortedByKeyWithBooleansAndTextJSONKeptAsStrings() async throws {
        let (path, w) = try await makeDatabase()
        try w.write { db in
            try db.execute(sql: "INSERT INTO sleepSession (deviceId, startTs, endTs, efficiency, stagesJSON, userEdited) VALUES ('strap', 2000, 3000, 0.9, '{\"light\":200}', 1)")
            try db.execute(sql: "INSERT INTO sleepSession (deviceId, startTs, endTs, userEdited) VALUES ('strap', 1000, 1500, 0)")
        }
        let spec = PushRegistry.spec(named: "sleepSession")!
        let rows = try GRDBRowSource(databasePath: path).allRows(spec, deviceId: "strap")
        XCTAssertEqual(rows.map { $0.key["startTs"] }, [.int(1000), .int(2000)])
        XCTAssertEqual(rows[1].data["userEdited"], .bool(true))
        XCTAssertEqual(rows[0].data["userEdited"], .bool(false))
        XCTAssertEqual(rows[1].data["stagesJSON"], .string("{\"light\":200}"))
        XCTAssertEqual(rows[1].data["efficiency"], .double(0.9))
        XCTAssertEqual(rows[0].data["efficiency"], .null)
    }

    func testBlobColumnsAreBase64AndExtMembersReadWhenPresent() async throws {
        let (path, w) = try await makeDatabase()
        try w.write { db in
            try db.execute(sql: "INSERT INTO ppgWaveformSample (deviceId, ts, samples, burstIndex, baseCode) VALUES ('strap', 1, ?, 4, NULL)",
                           arguments: [Data([0, 1, 2, 255])])
            try db.execute(sql: "INSERT INTO dailyMetric (deviceId, day, avgSdnn, sleepHrOnly) VALUES ('strap', '2026-08-01', 55.5, 1)")
        }
        let src = try GRDBRowSource(databasePath: path)
        let wave = try src.appendPage(PushRegistry.spec(named: "ppgWaveformSample")!, deviceId: "strap", afterRowId: nil, limit: 5)
        XCTAssertEqual(wave[0].data["samples"], .string("AAEC/w=="))
        XCTAssertEqual(wave[0].data["burstIndex"], .int(4))
        let day = try src.allRows(PushRegistry.spec(named: "dailyMetric")!, deviceId: "strap")
        XCTAssertEqual(day[0].data["avgSdnn"], .double(55.5))
        XCTAssertEqual(day[0].data["sleepHrOnly"], .bool(true))
    }

    func testMissingTableOrColumnYieldsNothingOrNull() throws {
        let path = tempURL().path
        let w = try DatabaseQueue(path: path)
        try w.write { db in
            try db.execute(sql: "CREATE TABLE hrSample (deviceId TEXT, ts INTEGER, bpm INTEGER, PRIMARY KEY (deviceId, ts))")
            try db.execute(sql: "INSERT INTO hrSample VALUES ('strap', 1, 60)")
            // an old sleepSession without the later columns (userEdited, motionJSON ...)
            try db.execute(sql: "CREATE TABLE sleepSession (deviceId TEXT, startTs INTEGER, endTs INTEGER, PRIMARY KEY (deviceId, startTs))")
            try db.execute(sql: "INSERT INTO sleepSession VALUES ('strap', 10, 20)")
        }
        let src = try GRDBRowSource(databasePath: path)
        XCTAssertEqual(try src.appendPage(PushRegistry.spec(named: "rrInterval")!, deviceId: "strap", afterRowId: nil, limit: 5), [])
        XCTAssertEqual(try src.allRows(PushRegistry.spec(named: "workout")!, deviceId: "strap"), [])
        let sleep = try src.allRows(PushRegistry.spec(named: "sleepSession")!, deviceId: "strap")
        XCTAssertEqual(sleep[0].data["userEdited"], .bool(false), "required boolean absent from an old schema reads as false")
        XCTAssertNil(sleep[0].data["motionJSON"], "absent column is simply not present; the encoder emits null")
    }

    func testConvertHandlesStorageClassMismatchesWithoutCrashing() {
        let int = Column(name: "x", kind: .int, nullable: true)
        let real = Column(name: "x", kind: .real, nullable: true)
        XCTAssertEqual(GRDBRowSource.convert(DatabaseValue(value: 61.0)!, int), .int(61))
        XCTAssertEqual(GRDBRowSource.convert(DatabaseValue(value: 61.5)!, int), .double(61.5))
        XCTAssertEqual(GRDBRowSource.convert(DatabaseValue(value: 61)!, real), .double(61.0))
        XCTAssertEqual(GRDBRowSource.convert(.null, Column(name: "b", kind: .bool, nullable: false)), .bool(false))
        XCTAssertEqual(GRDBRowSource.convert(.null, int), .null)
    }
}
