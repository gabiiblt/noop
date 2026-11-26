import XCTest
import WhoopStore
@testable import StrandAnalytics

/// The seam between stored rows and the progression engine. The engine itself is checked against openGym's own
/// code in `LiftProgressionOracleTests`; these check that stored data reaches it the way the engine expects.
final class LiftProgressionStoreTests: XCTestCase {

    private func item(_ rule: String? = "double", sets: Int? = 3, low: Int? = 8, high: Int? = 12,
                      weight: Double? = 40, setsMax: Int? = nil, inc: Double? = nil, deload: Double? = nil) -> LiftProgramItemRow {
        LiftProgramItemRow(id: "i", deviceId: "d", programId: "p", ord: 0, exercise: "Bench press",
                           targetSets: sets, targetRepsLow: low, targetRepsHigh: high, targetRpe: nil,
                           targetWeightKg: weight, restSec: nil, note: nil, progression: rule,
                           targetSetsMax: setsMax, incrementKg: inc, deloadFactor: deload)
    }

    private func set(_ id: String, session: String, ord: Int, w: Double, r: Int, target: Int? = nil,
                     plan: LiftPlanStamp? = nil, warm: Bool = false, side: LiftSide? = nil) -> LiftSetRow {
        LiftSetRow(id: id, deviceId: "d", sessionId: session, ord: ord, exercise: "Bench press",
                   primaryMuscle: .chest, setIndex: ord + 1, weightKg: w, reps: r, rpe: nil, isWarmup: warm,
                   startTs: nil, endTs: nil, restSec: nil, note: nil, side: side,
                   targetReps: target, targetWeightKg: target == nil ? nil : w, plan: plan)
    }

    // MARK: - Config

    func testARepRangeMapsTheWayOpenGymKeepsIt() throws {
        let cfg = try XCTUnwrap(LiftProgressionStore.config(for: item()))
        XCTAssertEqual(cfg.reps, 12)
        XCTAssertEqual(cfg.repsMin, 8)
        XCTAssertEqual(cfg.sets, 3)
        XCTAssertEqual(cfg.weightKg, 40)
        XCTAssertEqual(cfg.incKg, 2.5, "no step set takes the default")
        let single = try XCTUnwrap(LiftProgressionStore.config(for: item(low: 5, high: nil)))
        XCTAssertEqual(single.reps, 5)
        XCTAssertNil(single.repsMin, "one rep number is not a range")
    }

    func testALineWithoutAUsableRuleHasNoConfig() {
        XCTAssertNil(LiftProgressionStore.config(for: item(nil)))
        XCTAssertNil(LiftProgressionStore.config(for: item("greyskull")))
        XCTAssertNil(LiftProgressionStore.config(for: item("time")), "a hold has no seconds field on a program line yet")
    }

    func testTheSetCeilingOnlyCountsAboveTheBaseSets() throws {
        XCTAssertEqual(try XCTUnwrap(LiftProgressionStore.config(for: item("triple", sets: 3, setsMax: 5))).setsMax, 5)
        XCTAssertNil(try XCTUnwrap(LiftProgressionStore.config(for: item("triple", sets: 3, setsMax: 3))).setsMax)
    }

    func testTheStepAndDeloadFactorComeFromTheLine() throws {
        let cfg = try XCTUnwrap(LiftProgressionStore.config(for: item(inc: 1.25, deload: 0.8)))
        XCTAssertEqual(cfg.incKg, 1.25)
        XCTAssertEqual(cfg.deloadFactor, 0.8)
    }

    // MARK: - Stamp

    /// What a session stamps must read back as the same plan the line produces, or every session would look
    /// like an edited plan and restart.
    func testAStampReadsBackAsTheSamePlanTheLineProduces() throws {
        for line in [item(), item("triple", setsMax: 5), item("linear", low: 5, high: nil), item("double", weight: nil)] {
            let cfg = try XCTUnwrap(LiftProgressionStore.config(for: line))
            let stamped = LiftProgressionStore.plan(from: LiftProgressionStore.stamp(for: line))
            XCTAssertEqual(stamped, LiftProgression.plannedOf(cfg), "rule \(line.progression ?? "-")")
        }
    }

    // MARK: - Sessions

    func testSessionsAreOrderedByStartAndLeaveWarmUpsAndUndoneSetsOut() {
        let sets = [
            set("a1", session: "late", ord: 0, w: 50, r: 10),
            set("b0", session: "early", ord: 0, w: 20, r: 10, warm: true),
            set("b1", session: "early", ord: 1, w: 40, r: 8),
            set("b2", session: "early", ord: 2, w: 40, r: 0),
        ]
        let out = LiftProgressionStore.sessions(from: sets, sessionStarts: ["early": 100, "late": 200])
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out[0].sets.map(\.weightKg), [40, 40], "the warm-up is prep, not the session")
        XCTAssertEqual(out[0].sets.map(\.done), [true, false], "a set saved at 0 reps was never performed")
        XCTAssertEqual(out[1].sets.map(\.weightKg), [50])
    }

    func testASessionWithoutStampsCarriesNoTarget() {
        let out = LiftProgressionStore.sessions(from: [set("a", session: "s", ord: 0, w: 40, r: 10)],
                                                sessionStarts: ["s": 1])
        XCTAssertNil(out[0].target)
        XCTAssertNil(out[0].planned)
    }

    func testStampedAimsBecomeTheSessionsRowReps() throws {
        let stamp = LiftPlanStamp(progression: "triple", sets: 3, repsLow: 8, repsHigh: 12, setsMax: 5, weightKg: 40)
        let sets = [set("a", session: "s", ord: 0, w: 40, r: 12, target: 12, plan: stamp),
                    set("b", session: "s", ord: 1, w: 40, r: 12, target: 12, plan: stamp),
                    set("c", session: "s", ord: 2, w: 40, r: 9, target: 9, plan: stamp)]
        let session = try XCTUnwrap(LiftProgressionStore.sessions(from: sets, sessionStarts: ["s": 1]).first)
        XCTAssertEqual(session.target?.rowReps, [12, 12, 9])
        XCTAssertEqual(session.target?.reps, 12)
        XCTAssertEqual(session.target?.repsMin, 8)
        XCTAssertEqual(session.target?.setsMax, 5)
        XCTAssertEqual(session.planned?.sets, 3)
    }

    func testSetsDoneOnOneSideMakeTheSessionPerSide() throws {
        let stamp = LiftPlanStamp(sets: 2, repsLow: 8)
        let sets = [set("a", session: "s", ord: 0, w: 20, r: 8, target: 8, plan: stamp, side: .left)]
        let session = try XCTUnwrap(LiftProgressionStore.sessions(from: sets, sessionStarts: ["s": 1]).first)
        XCTAssertEqual(session.target?.perSide, true)
    }

    // MARK: - End to end through storage

    func testDoubleProgressionFromStoredSessionsAddsWeightAtTheTop() throws {
        let line = item("double")
        let stamp = LiftProgressionStore.stamp(for: line)
        let sets = [set("a", session: "s", ord: 0, w: 40, r: 12, target: 12, plan: stamp),
                    set("b", session: "s", ord: 1, w: 40, r: 12, target: 12, plan: stamp),
                    set("c", session: "s", ord: 2, w: 40, r: 12, target: 12, plan: stamp)]
        let out = try XCTUnwrap(LiftProgressionStore.prescription(for: line, lineSets: sets, sessionStarts: ["s": 1]))
        XCTAssertEqual(out.kind, .up)
        XCTAssertEqual(out.weightKg, 42.5)
        XCTAssertEqual(out.reps, 8, "a raise starts the range again at the bottom")
        XCTAssertEqual(out.why, .doubleUp(byKg: 2.5, bottom: 8))
    }

    func testTripleProgressionFromStoredSessionsAddsASetAtTheTop() throws {
        let line = item("triple", setsMax: 5)
        let stamp = LiftProgressionStore.stamp(for: line)
        let sets = (0..<3).map { set("s\($0)", session: "s", ord: $0, w: 40, r: 12, target: 12, plan: stamp) }
        let out = try XCTUnwrap(LiftProgressionStore.prescription(for: line, lineSets: sets, sessionStarts: ["s": 1]))
        XCTAssertEqual(out.kind, .up)
        XCTAssertEqual(out.rowReps, [12, 12, 12, 8], "the added set starts at the bottom of the range")
        XCTAssertEqual(out.sets, 4)
    }

    func testAnEditedPlanRestartsFromTheNewPlan() throws {
        let old = item("double", sets: 3)
        let stamp = LiftProgressionStore.stamp(for: old)
        let sets = (0..<3).map { set("s\($0)", session: "s", ord: $0, w: 40, r: 12, target: 12, plan: stamp) }
        let edited = item("double", sets: 4)
        let out = try XCTUnwrap(LiftProgressionStore.prescription(for: edited, lineSets: sets, sessionStarts: ["s": 1]))
        XCTAssertEqual(out.why, .planChanged, "the old numbers say nothing about a plan with another set count")
    }

    func testAWeightOnlyChangeIsNotAnEdit() throws {
        let old = item("double", weight: 40)
        let stamp = LiftProgressionStore.stamp(for: old)
        let sets = (0..<3).map { set("s\($0)", session: "s", ord: $0, w: 40, r: 12, target: 12, plan: stamp) }
        let out = try XCTUnwrap(LiftProgressionStore.prescription(for: item("double", weight: 45), lineSets: sets,
                                                                  sessionStarts: ["s": 1]))
        XCTAssertNotEqual(out.why, .planChanged)
    }

    func testNoRuleNoPrescription() {
        XCTAssertNil(LiftProgressionStore.prescription(for: item(nil), lineSets: [], sessionStarts: [:]))
    }

    func testNoHistoryIsABaseline() throws {
        let out = try XCTUnwrap(LiftProgressionStore.prescription(for: item("linear"), lineSets: [], sessionStarts: [:]))
        XCTAssertEqual(out.kind, .first)
        XCTAssertEqual(out.why, .baseline)
    }
}
