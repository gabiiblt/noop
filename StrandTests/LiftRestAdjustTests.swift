import XCTest
@testable import Strand
import WhoopStore

/// The running rest can be made shorter or longer; the planned rest is not always the rest that is needed.
final class LiftRestAdjustTests: XCTestCase {

    private let t0 = 1_800_000_000

    private func resting() -> LiftSessionEngine {
        var engine = LiftSessionEngine(plan: [LiftPlanItem(exercise: "Bench", targetSets: 3, restSec: 90)], startTs: t0)
        engine.advance(now: t0)             // set 1 working
        engine.advance(now: t0 + 30)        // set 1 done: resting until t0 + 120
        return engine
    }

    func testAMoreOrLessRestMovesTheEnd() {
        var engine = resting()
        XCTAssertEqual(engine.restRemaining(now: t0 + 30), 90)
        XCTAssertTrue(engine.adjustRest(by: 15, now: t0 + 40))
        XCTAssertEqual(engine.restRemaining(now: t0 + 40), 95, "120 + 15 - 40")
        XCTAssertTrue(engine.adjustRest(by: -30, now: t0 + 40))
        XCTAssertEqual(engine.restRemaining(now: t0 + 40), 65)
    }

    func testARestCutPastNowIsSimplyOverNotNegative() {
        var engine = resting()
        XCTAssertTrue(engine.adjustRest(by: -600, now: t0 + 100))
        XCTAssertEqual(engine.restRemaining(now: t0 + 100), 0)
        XCTAssertFalse(engine.adjustRest(by: -15, now: t0 + 100), "already over: nothing to cut")
    }

    func testARestIsBoundedAgainstAStuckFinger() {
        var engine = resting()
        for _ in 0..<500 { engine.adjustRest(by: 15, now: t0 + 40) }
        XCTAssertEqual(engine.restRemaining(now: t0 + 40), LiftSessionEngine.maxRestSec)
    }

    func testOnlyARestInProgressMoves() {
        var engine = LiftSessionEngine(plan: [LiftPlanItem(exercise: "Bench", targetSets: 3, restSec: 90)], startTs: t0)
        XCTAssertFalse(engine.adjustRest(by: 15, now: t0), "the warm-up has no rest")
        engine.advance(now: t0)
        XCTAssertFalse(engine.adjustRest(by: 15, now: t0 + 5), "a set being worked has none either")
    }

    func testAdjustingTouchesNeitherTheSetsNorTheNextSet() {
        var engine = resting()
        let sets = engine.sets
        let upcoming = engine.upcomingSlot
        engine.adjustRest(by: 15, now: t0 + 40)
        XCTAssertEqual(engine.sets, sets)
        XCTAssertEqual(engine.upcomingSlot, upcoming)
        XCTAssertEqual(engine.currentSlot, LiftSlot(exerciseIndex: 0, setIndex: 1))
    }

    func testTheRestEndedByTheEngineRecordsWhatWasActuallyTaken() {
        var engine = resting()
        engine.adjustRest(by: -60, now: t0 + 40)
        engine.advance(now: t0 + 60)       // leave the rest early
        XCTAssertEqual(engine.recordedSet(for: LiftSlot(exerciseIndex: 0, setIndex: 1))?.restSec, 30, "from t0+30 to t0+60")
    }
}
