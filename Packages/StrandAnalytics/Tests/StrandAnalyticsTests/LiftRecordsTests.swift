import XCTest
@testable import StrandAnalytics
import WhoopStore

/// Records ported from openGym's set-records.js. The expected weight / reps / volume marks below were
/// produced by running openGym's own `entryRecords` under vitest on the same inputs (e1rm filtered out,
/// since NOOP keeps its own Epley estimate) and pasted verbatim:
/// {"mixed":[["reps"],["weight"],[],["reps","volume"],[],["weight"]],"firstTime":[[]],
///  "newWeightNotRepRecord":[["weight"],["reps"],[],["reps"]],"bodyweight":[["reps"],[],[]]}
final class LiftRecordsTests: XCTestCase {
    private func row(_ id: String, session: String, ord: Int, w: Double, r: Int, warmup: Bool = false,
                     exercise: String = "Bench", catalogueId: String? = nil) -> LiftSetRow {
        LiftSetRow(id: id, deviceId: "d", sessionId: session, ord: ord, exercise: exercise, primaryMuscle: .chest,
                   setIndex: ord + 1, weightKg: w, reps: r, rpe: nil, isWarmup: warmup, startTs: nil, endTs: nil,
                   restSec: nil, note: nil, catalogueId: catalogueId)
    }

    /// The session's marks in set order, e1rm removed, as openGym's oracle lists them.
    private func marks(history: [(Double, Int)], session: [(Double, Int, Bool)]) -> [[String]] {
        let h = history.enumerated().map { row("h\($0.offset)", session: "old", ord: $0.offset, w: $0.element.0, r: $0.element.1) }
        let s = session.enumerated().map { row("s\($0.offset)", session: "now", ord: $0.offset, w: $0.element.0,
                                                r: $0.element.1, warmup: $0.element.2) }
        let rec = LiftRecords.sessionRecords(s, history: h)
        return s.map { (rec[$0.id] ?? []).filter { $0 != .e1rm }.map(\.rawValue) }
    }

    func testMatchesOpenGymOracleMixed() {
        XCTAssertEqual(marks(history: [(100, 5), (80, 10)],
                             session: [(100, 6, false), (105, 3, false), (60, 12, true), (80, 11, false), (80, 11, false), (120, 1, false)]),
                       [["reps"], ["weight"], [], ["reps", "volume"], [], ["weight"]])
    }

    func testMatchesOpenGymOracleFirstTime() {
        XCTAssertEqual(marks(history: [], session: [(50, 10, false)]), [[]])
    }

    func testMatchesOpenGymOracleNewWeightIsNotARepRecord() {
        XCTAssertEqual(marks(history: [(60, 10)], session: [(70, 4, false), (70, 5, false), (50, 9, false), (50, 11, false)]),
                       [["weight"], ["reps"], [], ["reps"]])
    }

    func testMatchesOpenGymOracleBodyweight() {
        XCTAssertEqual(marks(history: [(0, 8)], session: [(0, 9, false), (0, 7, false), (10, 5, false)]),
                       [["reps"], [], []])
    }

    func testEstimatedOneRepMaxRecordUsesEpleyAndTheRepCeiling() {
        let base = LiftRecordBaseline.from(history: [row("h", session: "old", ord: 0, w: 100, r: 5)])  // e1rm 116.67
        XCTAssertTrue(LiftRecords.kinds(weightKg: 90, reps: 10, against: base).contains(.e1rm))      // 120
        XCTAssertFalse(LiftRecords.kinds(weightKg: 80, reps: 15, against: base).contains(.e1rm),
                       "above 12 reps there is no estimate to beat with")
    }

    func testCatalogueIdKeepsRecordsAcrossARename() {
        let h = [row("h", session: "old", ord: 0, w: 100, r: 5, exercise: "Bench", catalogueId: "0025")]
        let s = [row("s", session: "now", ord: 0, w: 110, r: 5, exercise: "Développé couché", catalogueId: "0025")]
        XCTAssertEqual(LiftRecords.sessionRecords(s, history: h)["s"]?.first, .weight)
        let other = [row("t", session: "now", ord: 0, w: 110, r: 5, exercise: "Squat")]
        XCTAssertNil(LiftRecords.sessionRecords(other, history: h)["t"], "a different exercise starts from nothing")
    }

    func testProgressSeriesIsOneOrderedPointPerSession() {
        let sets = [row("a", session: "s2", ord: 0, w: 100, r: 5), row("b", session: "s1", ord: 0, w: 90, r: 8),
                    row("c", session: "s1", ord: 1, w: 50, r: 10, warmup: true), row("d", session: "gone", ord: 0, w: 1, r: 1)]
        let pts = LiftProgress.series(sets, sessionStart: ["s1": 100, "s2": 200])
        XCTAssertEqual(pts.map(\.sessionId), ["s1", "s2"])
        XCTAssertEqual(pts[0].workingSets, 1)
        XCTAssertEqual(pts[0].topWeightKg, 90)
        XCTAssertEqual(pts[0].bestEstimatedOneRepMaxKg!, 90 * (1 + 8.0 / 30), accuracy: 1e-9)
        XCTAssertEqual(pts[1].volumeKg, 500)
    }

    func testVolumeLoadAddsDropSetDrops() {
        var drop = row("x", session: "s", ord: 0, w: 40, r: 10)
        drop.setType = .dropset
        drop.parts = [LiftSetPart(weightKg: 30, reps: 6)]
        XCTAssertEqual(LiftMetrics.volumeLoadKg([drop]), 400 + 180)
    }
}
