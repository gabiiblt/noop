import XCTest
@testable import Strand
import StrandAnalytics
import WhoopStore

/// Supersets run as a round, and a backup can take a line's place when its machine is taken.
final class LiftSupersetSessionTests: XCTestCase {

    private let t0 = 1_800_000_000

    private func line(_ name: String, sets: Int, rest: Int = 60, group: String? = nil,
                      backups: [String] = []) -> LiftPlanItem {
        LiftPlanItem(exercise: name, primaryMuscle: .chest, targetSets: sets, restSec: rest,
                     targetRepsLow: 10, targetWeightKg: 40, programItemId: "id-\(name)",
                     supersetGroup: group, backups: backups)
    }

    private func slot(_ e: Int, _ s: Int) -> LiftSlot { LiftSlot(exerciseIndex: e, setIndex: s) }

    /// Tap the big button `n` times, one second apart, and return the slot worked after each tap.
    private func tap(_ engine: inout LiftSessionEngine, _ n: Int, from now: Int) -> [LiftSlot?] {
        (0..<n).map { i in
            engine.advance(now: now + i)
            if case .working(let s) = engine.stage { return s }
            return nil
        }
    }

    // MARK: - The round

    func testASupersetAlternatesOneSetOfEachInTurn() {
        var engine = LiftSessionEngine(plan: [line("Bench", sets: 3, group: "g"), line("Row", sets: 3, group: "g")], startTs: t0)
        engine.advance(now: t0)                                              // warm-up -> A1
        XCTAssertEqual(engine.stage, .working(slot(0, 1)))
        var worked: [LiftSlot] = []
        for i in 1...5 {                                                     // finish a set, land on the next one
            engine.advance(now: t0 + i * 10)                                // set done
            if case .resting = engine.stage { engine.advance(now: t0 + i * 10 + 1) }   // leave the rest
            if case .working(let s) = engine.stage { worked.append(s) }
        }
        XCTAssertEqual(worked, [slot(1, 1), slot(0, 2), slot(1, 2), slot(0, 3), slot(1, 3)],
                       "A1 B1 A2 B2 A3 B3: one set of each in turn, never A1 A2 A3")
    }

    func testThereIsNoRestInsideARoundAndTheLongestRestAfterIt() {
        var engine = LiftSessionEngine(plan: [line("Bench", sets: 2, rest: 60, group: "g"),
                                              line("Row", sets: 2, rest: 120, group: "g")], startTs: t0)
        engine.advance(now: t0)                                              // A1 working
        engine.advance(now: t0 + 30)                                         // A1 done -> straight to B1
        XCTAssertEqual(engine.stage, .working(slot(1, 1)), "no rest between the members of a round")
        XCTAssertEqual(engine.recordedSet(for: slot(0, 1))?.restSec, 0)
        engine.advance(now: t0 + 60)                                         // B1 done: the round is over
        guard case .resting(let s, let endsAt) = engine.stage else { return XCTFail("expected a rest, got \(engine.stage)") }
        XCTAssertEqual(s, slot(1, 1))
        XCTAssertEqual(endsAt, t0 + 60 + 120, "the longest rest any member asked for")
    }

    func testUnevenMembersFinishTheLongerOnesLeftoverSets() {
        var engine = LiftSessionEngine(plan: [line("Bench", sets: 3, group: "g"), line("Row", sets: 2, group: "g")], startTs: t0)
        engine.advance(now: t0)
        var order: [LiftSlot] = [slot(0, 1)]
        for i in 1...4 {
            engine.advance(now: t0 + i * 10)
            if case .resting = engine.stage { engine.advance(now: t0 + i * 10 + 1) }
            if case .working(let s) = engine.stage { order.append(s) }
        }
        XCTAssertEqual(order, [slot(0, 1), slot(1, 1), slot(0, 2), slot(1, 2), slot(0, 3)])
        XCTAssertEqual(engine.upcomingSlot, nil, "nothing after the last set")
    }

    func testStartingTheSecondMemberFirstStillGoesToTheFirstMembersSameSet() {
        var engine = LiftSessionEngine(plan: [line("Bench", sets: 2, group: "g"), line("Row", sets: 2, group: "g")], startTs: t0)
        engine.start(slot(1, 1), now: t0)
        engine.advance(now: t0 + 20)                                         // B1 done
        XCTAssertEqual(engine.stage, .working(slot(0, 1)), "A still owes set 1 of this round")
    }

    func testTheUpcomingSetOfARoundIsTheNextMembers() {
        var engine = LiftSessionEngine(plan: [line("Bench", sets: 2, group: "g"), line("Row", sets: 2, group: "g")], startTs: t0)
        engine.advance(now: t0)
        XCTAssertEqual(engine.stage, .working(slot(0, 1)))
        XCTAssertEqual(engine.upcomingSlot, slot(1, 1), "what the bar and the Lock Screen name as next")
    }

    func testALineOutsideAnyGroupStillRestsAfterEverySet() {
        var engine = LiftSessionEngine(plan: [line("Bench", sets: 2, group: "g"), line("Row", sets: 2, group: "g"),
                                              line("Curl", sets: 2, rest: 45)], startTs: t0)
        engine.start(slot(2, 1), now: t0)
        engine.advance(now: t0 + 20)
        guard case .resting(_, let endsAt) = engine.stage else { return XCTFail("expected a rest") }
        XCTAssertEqual(endsAt, t0 + 20 + 45)
        engine.advance(now: t0 + 70)
        XCTAssertEqual(engine.stage, .working(slot(2, 2)), "the same exercise, as it always did")
    }

    func testAGroupOfOneIsNoSuperset() {
        let engine = LiftSessionEngine(plan: [line("Bench", sets: 2, group: "lonely"), line("Row", sets: 2)], startTs: t0)
        XCTAssertNil(engine.supersetMembers(of: 0))
    }

    func testUndoRestoresTheSetBeforeARoundStep() {
        var engine = LiftSessionEngine(plan: [line("Bench", sets: 2, group: "g"), line("Row", sets: 2, group: "g")], startTs: t0)
        engine.advance(now: t0)
        engine.advance(now: t0 + 10)
        XCTAssertEqual(engine.stage, .working(slot(1, 1)))
        engine.undo()
        XCTAssertEqual(engine.stage, .working(slot(0, 1)))
        XCTAssertNil(engine.recordedSet(for: slot(0, 1)))
    }

    // MARK: - Swapping for a backup

    func testABackupTakesTheLinesPlaceAndTheExerciseItReplacesGoesToTheFront() {
        var engine = LiftSessionEngine(plan: [line("Leg press", sets: 3, backups: ["Hack squat", "Lunge"])], startTs: t0)
        XCTAssertTrue(engine.swapExercise(at: 0, to: "Hack squat", primaryMuscle: .quads, secondaryMuscles: [.glutes], equipment: "leverage machine"))
        let swapped = engine.plan[0]
        XCTAssertEqual(swapped.exercise, "Hack squat")
        XCTAssertEqual(swapped.swappedFrom, "Leg press")
        XCTAssertEqual(swapped.backups, ["Leg press", "Lunge"])
        XCTAssertEqual(swapped.targetSets, 3, "the slot keeps its sets")
        XCTAssertEqual(swapped.targetRepsLow, 10)
        XCTAssertEqual(swapped.restSec, 60)
        XCTAssertNil(swapped.targetWeightKg, "a weight for one machine is not a weight for another")
        XCTAssertNil(swapped.programItemId, "nothing done on it is written back onto the other exercise's program line")
        XCTAssertEqual(swapped.primaryMuscle, .quads)
        XCTAssertEqual(swapped.equipment, "leverage machine")
    }

    func testSwappingBackRestoresTheOriginalAndKeepsWhereItWasPlannedFrom() {
        var engine = LiftSessionEngine(plan: [line("Leg press", sets: 3, backups: ["Hack squat"])], startTs: t0)
        engine.swapExercise(at: 0, to: "Hack squat", primaryMuscle: nil, secondaryMuscles: [], equipment: nil)
        engine.swapExercise(at: 0, to: "Leg press", primaryMuscle: nil, secondaryMuscles: [], equipment: nil)
        XCTAssertEqual(engine.plan[0].exercise, "Leg press")
        XCTAssertEqual(engine.plan[0].swappedFrom, "Leg press", "what the line was first planned as")
        XCTAssertEqual(engine.plan[0].backups, ["Hack squat"])
    }

    func testALoggedLineIsNeverRelabelled() {
        var engine = LiftSessionEngine(plan: [line("Leg press", sets: 3, backups: ["Hack squat"])], startTs: t0)
        engine.advance(now: t0)
        engine.advance(now: t0 + 30)                                          // set 1 done
        XCTAssertFalse(engine.swapExercise(at: 0, to: "Hack squat", primaryMuscle: nil, secondaryMuscles: [], equipment: nil))
        XCTAssertEqual(engine.plan[0].exercise, "Leg press")
    }

    func testASetStartedButNotDoneCanStillBeSwapped() {
        var engine = LiftSessionEngine(plan: [line("Leg press", sets: 3, backups: ["Hack squat"])], startTs: t0)
        engine.advance(now: t0)                                              // walked up, set 1 in progress
        XCTAssertTrue(engine.swapExercise(at: 0, to: "Hack squat", primaryMuscle: nil, secondaryMuscles: [], equipment: nil),
                      "the machine was taken: nothing is recorded yet")
    }

    func testSwappingForTheSameNameOrAMissingLineDoesNothing() {
        var engine = LiftSessionEngine(plan: [line("Leg press", sets: 3)], startTs: t0)
        XCTAssertFalse(engine.swapExercise(at: 0, to: "Leg press", primaryMuscle: nil, secondaryMuscles: [], equipment: nil))
        XCTAssertFalse(engine.swapExercise(at: 0, to: "  ", primaryMuscle: nil, secondaryMuscles: [], equipment: nil))
        XCTAssertFalse(engine.swapExercise(at: 4, to: "Hack squat", primaryMuscle: nil, secondaryMuscles: [], equipment: nil))
    }

    func testASwapCanBeUndone() {
        var engine = LiftSessionEngine(plan: [line("Leg press", sets: 3, backups: ["Hack squat"])], startTs: t0)
        engine.swapExercise(at: 0, to: "Hack squat", primaryMuscle: nil, secondaryMuscles: [], equipment: nil)
        engine.undo()
        XCTAssertEqual(engine.plan[0].exercise, "Leg press")
        XCTAssertNil(engine.plan[0].swappedFrom)
    }

    func testASwappedLineDropsItsProgressionRule() {
        let rule = LiftPlanRule(stamp: LiftPlanStamp(progression: "double", sets: 3), rowReps: nil, why: .baseline)
        var item = line("Leg press", sets: 3, backups: ["Hack squat"])
        item.rule = rule
        var engine = LiftSessionEngine(plan: [item], startTs: t0)
        engine.swapExercise(at: 0, to: "Hack squat", primaryMuscle: nil, secondaryMuscles: [], equipment: nil)
        XCTAssertNil(engine.plan[0].rule, "its target was for the other exercise")
    }

    // MARK: - Crash safety

    func testTheGroupTheBackupsAndTheSwapSurviveARelaunch() throws {
        var item = line("Leg press", sets: 3, group: "g", backups: ["Hack squat", "Lunge"])
        item.equipment = "leverage machine"
        var engine = LiftSessionEngine(plan: [item, line("Curl", sets: 2, group: "g")], startTs: Int(Date().timeIntervalSince1970) - 60)
        engine.swapExercise(at: 0, to: "Hack squat", primaryMuscle: nil, secondaryMuscles: [], equipment: nil)
        let snapshot = LiftSessionPersistence.snapshot(engine: engine, programId: nil, programName: nil,
                                                       pendingValues: [:], pendingWarmups: [])
        let back = try XCTUnwrap(LiftSessionPersistence.decode(try XCTUnwrap(LiftSessionPersistence.encode(snapshot))))
        XCTAssertEqual(LiftSessionPersistence.engine(from: back).plan, engine.plan)
    }

    func testAPlanWithNoSupersetsOrBackupsEncodesAsBefore() throws {
        let engine = LiftSessionEngine(plan: [line("Curl", sets: 2)], startTs: Int(Date().timeIntervalSince1970) - 60)
        let snapshot = LiftSessionPersistence.snapshot(engine: engine, programId: nil, programName: nil,
                                                       pendingValues: [:], pendingWarmups: [])
        let json = try XCTUnwrap(String(data: try XCTUnwrap(LiftSessionPersistence.encode(snapshot)), encoding: .utf8))
        for key in ["supersetGroup", "backups", "swappedFrom"] { XCTAssertFalse(json.contains(key), key) }
    }
}
