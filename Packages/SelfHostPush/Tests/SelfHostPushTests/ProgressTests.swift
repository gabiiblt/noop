import XCTest
@testable import SelfHostPush

final class ProgressTests: XCTestCase {
    private let endpoint = URL(string: "https://server.tailfb9ed9.ts.net/push")!
    private var hr: StreamSpec { return PushRegistry.spec(named: "hrSample")! }

    private func store() throws -> (ProgressStore, URL) {
        let url = tempURL()
        return (try ProgressStore(url: url), url)
    }

    func testSourceIdIsCreatedOnceAndStableAcrossReopen() throws {
        let (a, url) = try store()
        let again = try ProgressStore(url: url)
        XCTAssertEqual(a.sourceId, again.sourceId)
        XCTAssertEqual(a.sourceId, a.sourceId.lowercased())
        XCTAssertEqual(a.sourceId.count, 36)
    }

    func testNewNamespaceWhenEndpointVersionOrReceiverStateChanges() throws {
        let (s, _) = try store()
        let base = s.namespace(endpoint: endpoint, version: .v1, receiverStateId: "state-1")
        XCTAssertEqual(base, s.namespace(endpoint: endpoint, version: .v1, receiverStateId: "state-1"))
        XCTAssertNotEqual(base, s.namespace(endpoint: URL(string: "https://other.ts.net/push")!, version: .v1,
                                            receiverStateId: "state-1"))
        XCTAssertNotEqual(base, s.namespace(endpoint: endpoint, version: .ext, receiverStateId: "state-1"))
        XCTAssertNotEqual(base, s.namespace(endpoint: endpoint, version: .v1, receiverStateId: "state-2"))
    }

    func testTokenRotationKeepsProgressBecauseTokenIsNotANamespaceInput() throws {
        let (s, _) = try store()
        // trailing slash / case differences in the URL do not matter either
        XCTAssertEqual(s.namespace(endpoint: endpoint, version: .v1, receiverStateId: "x"),
                       s.namespace(endpoint: URL(string: "HTTPS://server.tailfb9ed9.ts.net/push/")!, version: .v1,
                                   receiverStateId: "x"))
    }

    func testCursorRoundTripAndScopeIsolation() throws {
        let (s, _) = try store()
        let c = Cursor(rowId: 42, keySha256: String(repeating: "a", count: 64))
        try s.setCursor(c, ns: "n1", device: "d1", stream: "hrSample")
        XCTAssertEqual(try s.cursor(ns: "n1", device: "d1", stream: "hrSample"), c)
        XCTAssertNil(try s.cursor(ns: "n2", device: "d1", stream: "hrSample"))
        XCTAssertNil(try s.cursor(ns: "n1", device: "d2", stream: "hrSample"))
        XCTAssertNil(try s.cursor(ns: "n1", device: "d1", stream: "rrInterval"))
        try s.setCursor(nil, ns: "n1", device: "d1", stream: "hrSample")
        XCTAssertNil(try s.cursor(ns: "n1", device: "d1", stream: "hrSample"))
    }

    func testValidCursorSurvivesReopen() throws {
        let (s, url) = try store()
        let src = FakeSource()
        let row = hrRow(7, ts: 1000)
        src.set(hr, [row])
        let c = Cursor(rowId: 7, keySha256: fingerprint(of: row, spec: hr, deviceId: "strap"))
        try s.setCursor(c, ns: "n", device: "strap", stream: "hrSample")
        let reopened = try ProgressStore(url: url)
        XCTAssertEqual(try reopened.verifiedCursor(ns: "n", device: "strap", spec: hr, source: src), c)
    }

    func testMissingRowResetsCursorToNil() throws {
        let (s, _) = try store()
        let src = FakeSource()
        src.set(hr, [])  // the row the cursor points at is gone (restore / prune / VACUUM)
        try s.setCursor(Cursor(rowId: 7, keySha256: String(repeating: "c", count: 64)),
                        ns: "n", device: "strap", stream: "hrSample")
        XCTAssertNil(try s.verifiedCursor(ns: "n", device: "strap", spec: hr, source: src))
        XCTAssertNil(try s.cursor(ns: "n", device: "strap", stream: "hrSample"), "stale cursor must be cleared")
    }

    func testFingerprintMismatchResetsCursorToNil() throws {
        let (s, _) = try store()
        let src = FakeSource()
        src.set(hr, [hrRow(7, ts: 5555)])  // same rowid, different row
        try s.setCursor(Cursor(rowId: 7, keySha256: fingerprint(of: hrRow(7, ts: 1000), spec: hr, deviceId: "strap")),
                        ns: "n", device: "strap", stream: "hrSample")
        XCTAssertNil(try s.verifiedCursor(ns: "n", device: "strap", spec: hr, source: src))
        XCTAssertNil(try s.cursor(ns: "n", device: "strap", stream: "hrSample"))
    }

    func testNoStoredCursorVerifiesToNil() throws {
        let (s, _) = try store()
        XCTAssertNil(try s.verifiedCursor(ns: "n", device: "strap", spec: hr, source: FakeSource()))
    }

    func testDayHashesApplyAndRemove() throws {
        let (s, _) = try store()
        try s.applyDayHashes(set: ["2026-01-01": "h1", "2026-01-02": "h2"], remove: [], ns: "n", device: "d",
                             stream: "dailyMetric")
        XCTAssertEqual(try s.dayHashes(ns: "n", device: "d", stream: "dailyMetric"),
                       ["2026-01-01": "h1", "2026-01-02": "h2"])
        try s.applyDayHashes(set: ["2026-01-02": "h2b"], remove: ["2026-01-01"], ns: "n", device: "d",
                             stream: "dailyMetric")
        XCTAssertEqual(try s.dayHashes(ns: "n", device: "d", stream: "dailyMetric"), ["2026-01-02": "h2b"])
        XCTAssertEqual(try s.dayHashes(ns: "other", device: "d", stream: "dailyMetric"), [:])
    }

    func testSnapshotHashAndKnownDevices() throws {
        let (s, _) = try store()
        try s.setSnapshotHash("abc", ns: "n", device: "d", stream: "liftSet")
        XCTAssertEqual(try s.snapshotHash(ns: "n", device: "d", stream: "liftSet"), "abc")
        try s.setSnapshotHash(nil, ns: "n", device: "d", stream: "liftSet")
        XCTAssertNil(try s.snapshotHash(ns: "n", device: "d", stream: "liftSet"))
        try s.rememberDevices(["b", "a"])
        try s.rememberDevices(["a", "c"])
        XCTAssertEqual(try s.knownDevices(), ["a", "b", "c"])
    }
}
