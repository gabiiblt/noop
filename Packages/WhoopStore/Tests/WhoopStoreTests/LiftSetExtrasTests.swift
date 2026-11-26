import XCTest
@testable import WhoopStore

final class LiftSetExtrasTests: XCTestCase {

    func testAPlainSetIsEmptyAndStoresNothingExtra() {
        XCTAssertTrue(LiftSetExtras().isEmpty)
        XCTAssertFalse(LiftSetExtras(isFailure: true).isEmpty)
        XCTAssertFalse(LiftSetExtras(side: .left).isEmpty)
        XCTAssertFalse(LiftSetExtras(rir: 0).isEmpty, "0 RIR is a rating, not a blank")
    }

    func testStraightSetDropsItsParts() {
        let e = LiftSetExtras(setType: .straight, parts: [LiftSetPart(weightKg: 20, reps: 5)]).normalized()
        XCTAssertEqual(e.parts, [])
        XCTAssertTrue(e.isEmpty)
    }

    func testDropSetKeepsDropWeightsAndRemovesEmptyDrops() {
        let e = LiftSetExtras(setType: .dropset, parts: [
            LiftSetPart(weightKg: 30, reps: 6, restSec: 20),
            LiftSetPart(weightKg: 20, reps: 0),
            LiftSetPart(weightKg: -5, reps: 4),
        ]).normalized()
        XCTAssertEqual(e.parts, [LiftSetPart(weightKg: 30, reps: 6), LiftSetPart(weightKg: nil, reps: 4)],
                       "a drop takes no rest, and a negative weight is dropped rather than stored")
    }

    func testRestPauseBurstsKeepRestButNoWeight() {
        let e = LiftSetExtras(setType: .restpause, parts: [
            LiftSetPart(weightKg: 99, reps: 6, restSec: 15),
            LiftSetPart(weightKg: nil, reps: 5, restSec: -1),
        ]).normalized()
        XCTAssertEqual(e.parts, [LiftSetPart(weightKg: nil, reps: 6, restSec: 15),
                                 LiftSetPart(weightKg: nil, reps: 5, restSec: nil)])
    }

    func testRestPauseTotalIsTheSumOfEveryBurst() {
        XCTAssertNil(LiftSetExtras().restPauseTotal)
        XCTAssertNil(LiftSetExtras(setType: .restpause).restPauseTotal, "no bursts yet, no total")
        XCTAssertEqual(LiftSetExtras(setType: .restpause, parts: [
            LiftSetPart(weightKg: nil, reps: 6), LiftSetPart(weightKg: nil, reps: 6),
        ]).restPauseTotal, 12)
        XCTAssertNil(LiftSetExtras(setType: .dropset, parts: [LiftSetPart(weightKg: 20, reps: 5)]).restPauseTotal)
    }

    func testRirIsClampedAndTimeAndDistanceMustBePositive() {
        let e = LiftSetExtras(rir: 14, durationSec: 0, distanceM: -3).normalized()
        XCTAssertEqual(e.rir, 10)
        XCTAssertNil(e.durationSec)
        XCTAssertNil(e.distanceM)
        XCTAssertEqual(LiftSetExtras(rir: -2).normalized().rir, 0)
    }

    func testPartCountIsBounded() {
        let many = (0..<30).map { _ in LiftSetPart(weightKg: 10, reps: 1) }
        XCTAssertEqual(LiftSetExtras(setType: .dropset, parts: many).normalized().parts.count, LiftSetExtras.maxParts)
    }

    func testCodableRoundTrip() throws {
        let e = LiftSetExtras(setType: .dropset, parts: [LiftSetPart(weightKg: 30, reps: 6)],
                              isFailure: true, rir: 1.5, side: .right, durationSec: 40, distanceM: 20)
        let back = try JSONDecoder().decode(LiftSetExtras.self, from: JSONEncoder().encode(e))
        XCTAssertEqual(back, e)
    }
}
