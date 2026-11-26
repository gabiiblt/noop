import XCTest
@testable import Strand
import StrandAnalytics
import WhoopStore

/// A progression rule on a session line: its numbers become the target (and beat the carried ones), each set
/// keeps its own aim, the rule survives a relaunch, and a line with a rule is never rewritten after a session.
final class LiftProgressionSessionTests: XCTestCase {

    private let stamp = LiftPlanStamp(progression: "triple", sets: 3, repsLow: 8, repsHigh: 12, setsMax: 5, weightKg: 40)

    private func line(sets: Int = 3) -> LiftPlanItem {
        LiftPlanItem(exercise: "Bench press", primaryMuscle: .chest, targetSets: sets, restSec: 90,
                     targetRepsLow: 8, targetRepsHigh: 12, targetWeightKg: 40, programItemId: "i1")
    }

    private func slot(_ s: Int) -> LiftSlot { LiftSlot(exerciseIndex: 0, setIndex: s) }

    // MARK: - Applying a prescription

    func testAPrescriptionBecomesTheLinesNumbersAndRidesAlongForTheStamp() {
        let rx = LiftPrescription(policy: .triple, kind: .up, weightKg: 42.5, reps: 8, sets: 3, rowReps: [8, 8, 8],
                                  why: .tripleUp(sets: 5, byKg: 2.5, setsMin: 3, bottom: 8))
        let out = line().applying(rx, stamp: stamp)
        XCTAssertEqual(out.targetWeightKg, 42.5)
        XCTAssertEqual(out.targetRepsLow, 8)
        XCTAssertEqual(out.targetSets, 3)
        XCTAssertEqual(out.rule?.rowReps, [8, 8, 8])
        XCTAssertEqual(out.rule?.stamp, stamp)
        XCTAssertEqual(out.rule?.why, .tripleUp(sets: 5, byKg: 2.5, setsMin: 3, bottom: 8))
    }

    func testAnAddedSetGetsItsOwnAim() {
        let rx = LiftPrescription(policy: .triple, kind: .up, weightKg: 40, reps: 12, sets: 4, rowReps: [12, 12, 12, 8],
                                  why: .tripleAddSet(top: 12, bottom: 8))
        let out = line().applying(rx, stamp: stamp)
        XCTAssertEqual(out.targetSets, 4)
        XCTAssertEqual(out.aimReps(forSet: 1), 12)
        XCTAssertEqual(out.aimReps(forSet: 4), 8)
        XCTAssertEqual(out.aimReps(forSet: 5), 12, "a set added during the session falls back to the line's reps")
    }

    func testARuleThatHasNoOpinionKeepsWhatTheProgramSaid() {
        let rx = LiftPrescription(policy: .linear, kind: .first, why: .baseline)
        let out = line().applying(rx, stamp: stamp)
        XCTAssertEqual(out.targetWeightKg, 40)
        XCTAssertEqual(out.targetRepsLow, 8)
        XCTAssertEqual(out.targetSets, 3)
        XCTAssertNil(out.rule?.rowReps)
    }

    func testAPlainLineHasNoRule() {
        XCTAssertNil(line().rule)
        XCTAssertEqual(line().aimReps(forSet: 2), 8)
    }

    // MARK: - The grey numbers

    func testTheRulesWeightBeatsLastSessionsAndItsRepAimBeatsThePreviousSet() {
        let rx = LiftPrescription(policy: .triple, kind: .deload, weightKg: 37.5, reps: 8, sets: 3, rowReps: [8, 8, 8],
                                  why: .tripleDeload(stalls: 3, weightKg: 37.5, setsMin: 3, bottom: 8))
        let engine = LiftSessionEngine(plan: [line().applying(rx, stamp: stamp)], startTs: 1_800_000_000)
        let lastTime = [1: LiftSetCarry(weightKg: 40, reps: 9)]
        XCTAssertEqual(engine.carry(for: slot(1), lastSession: lastTime).weightKg, 37.5,
                       "a deload is lighter than last time")
        XCTAssertEqual(engine.carry(for: slot(1), lastSession: lastTime).reps, 8)
    }

    func testALineWithoutARuleCarriesAsBefore() {
        let engine = LiftSessionEngine(plan: [line()], startTs: 1_800_000_000)
        XCTAssertEqual(engine.carry(for: slot(1), lastSession: [1: LiftSetCarry(weightKg: 45, reps: 10)]),
                       LiftSetCarry(weightKg: 45, reps: 10))
    }

    // MARK: - Crash safety

    func testTheRuleSurvivesARelaunch() throws {
        let rx = LiftPrescription(policy: .triple, kind: .up, weightKg: 40, reps: 12, sets: 4, rowReps: [12, 12, 12, 8],
                                  why: .tripleAddSet(top: 12, bottom: 8))
        let engine = LiftSessionEngine(plan: [line().applying(rx, stamp: stamp)], startTs: Int(Date().timeIntervalSince1970) - 60)
        let snapshot = LiftSessionPersistence.snapshot(engine: engine, programId: "p", programName: "Push",
                                                       pendingValues: [:], pendingWarmups: [])
        let data = try XCTUnwrap(LiftSessionPersistence.encode(snapshot))
        let back = try XCTUnwrap(LiftSessionPersistence.decode(data))
        XCTAssertEqual(LiftSessionPersistence.engine(from: back).plan, engine.plan)
    }

    func testASnapshotWithoutARuleStillResumes() throws {
        let engine = LiftSessionEngine(plan: [line()], startTs: Int(Date().timeIntervalSince1970) - 60)
        let snapshot = LiftSessionPersistence.snapshot(engine: engine, programId: nil, programName: nil,
                                                       pendingValues: [:], pendingWarmups: [])
        let json = try XCTUnwrap(String(data: try XCTUnwrap(LiftSessionPersistence.encode(snapshot)), encoding: .utf8))
        XCTAssertFalse(json.contains("\"rule\""), "a line with no rule encodes exactly as before")
        XCTAssertNil(LiftSessionPersistence.engine(from: snapshot).plan[0].rule)
    }

    // MARK: - The program after a session

    func testALineWithARuleIsNotRewrittenFromTheHeaviestSet() {
        let ruled = LiftProgramItemRow(id: "i1", deviceId: "d", programId: "p", ord: 0, exercise: "Bench press",
                                       targetSets: 3, targetRepsLow: 8, targetRepsHigh: 12, targetRpe: nil,
                                       targetWeightKg: 40, restSec: nil, note: nil, progression: "triple")
        var plain = ruled
        plain.progression = nil
        let done = LiftSessionController.FinishedSet(slot: slot(1), weightKg: 60, reps: 5, rpe: nil, isWarmup: false,
                                                     startTs: 1, endTs: 2, restSec: nil)
        let rx = LiftPrescription(policy: .triple, kind: .up, weightKg: 40, reps: 8, sets: 3, rowReps: [8, 8, 8], why: .baseline)
        let plan = [line().applying(rx, stamp: stamp)]
        XCTAssertEqual(LiftSessionController.applyingHeaviestSets([done], plan: plan, to: [ruled]), [ruled])
        XCTAssertEqual(LiftSessionController.applyingHeaviestSets([done], plan: plan, to: [plain]).first?.targetWeightKg, 60,
                       "a plain line still takes its heaviest set, as it always did")
    }

    func testASetCountTheRuleChoseIsNeverOfferedBackToTheProgram() {
        let row = LiftProgramItemRow(id: "i1", deviceId: "d", programId: "p", ord: 0, exercise: "Bench press",
                                     targetSets: 3, targetRepsLow: 8, targetRepsHigh: 12, targetRpe: nil,
                                     targetWeightKg: 40, restSec: nil, note: nil, progression: "triple")
        let rx = LiftPrescription(policy: .triple, kind: .up, weightKg: 40, reps: 12, sets: 4, rowReps: [12, 12, 12, 8], why: .baseline)
        let ruledPlan = [line().applying(rx, stamp: stamp)]
        XCTAssertTrue(LiftSessionController.setCountChanges(plan: ruledPlan, program: [row]).isEmpty)
        var changed = line(sets: 4)
        changed.programItemId = "i1"
        XCTAssertEqual(LiftSessionController.setCountChanges(plan: [changed], program: [row]).count, 1,
                       "a plain line still reports a count the person changed")
    }
}
