import XCTest
@testable import Strand
import WhoopStore

/// Set detail (shape, drops or bursts, failure, RIR, side, time, distance) through a live session: held
/// for a set not yet performed, applied when it is recorded, kept across a relaunch, and handed to Save.
///
/// The same rule as typed numbers governs it: describing a set must never create one, so detail for a
/// set that has not happened is held in the controller and applied the instant the set is recorded.
@MainActor
final class LiftSetExtrasSessionTests: XCTestCase {

    private func controller() -> LiftSessionController {
        LiftSessionController(buzz: { _ in }, setStrapHandler: { _ in })
    }

    private func plan() -> [LiftPlanItem] {
        [LiftPlanItem(exercise: "Curl", primaryMuscle: .biceps, targetSets: 3,
                      restSec: 60, targetRepsLow: 10, targetWeightKg: 20)]
    }

    private func slot(_ s: Int) -> LiftSlot { LiftSlot(exerciseIndex: 0, setIndex: s) }

    private let drop = LiftSetExtras(setType: .dropset,
                                     parts: [LiftSetPart(weightKg: 15, reps: 6), LiftSetPart(weightKg: 10, reps: 5)],
                                     isFailure: true, rir: 0)

    override func tearDown() {
        LiftSessionPersistence.clear()
        super.tearDown()
    }

    func testDetailChosenForASetNotYetPerformedIsHeldNotInvented() {
        let c = controller()
        c.start(plan: plan(), programId: nil, programName: "Arms")
        c.advance()                                                 // set 1 active
        c.setExtras(slot(3), drop)

        XCTAssertEqual(c.extras(for: slot(3)), drop, "the row shows what was chosen")
        XCTAssertEqual(c.engine?.sets.count, 0, "and no set nobody performed is created")
    }

    func testPendingDetailIsAppliedWhenTheSetIsRecordedThenConsumed() {
        let c = controller()
        c.start(plan: plan(), programId: nil, programName: "Arms")
        c.advance()                                                 // set 1 active
        c.setExtras(slot(1), drop)
        c.advance()                                                 // Set done

        XCTAssertEqual(c.engine?.recordedSet(for: slot(1))?.extras, drop)
        XCTAssertTrue(c.pendingExtras.isEmpty, "the held entry is consumed once applied")
    }

    func testDetailOfAPerformedSetIsEditedInPlace() {
        let c = controller()
        c.start(plan: plan(), programId: nil, programName: "Arms")
        c.advance()
        c.advance()                                                 // set 1 recorded, resting
        c.setExtras(slot(1), LiftSetExtras(side: .left))

        XCTAssertEqual(c.engine?.recordedSet(for: slot(1))?.extras.side, .left)
        c.setExtras(slot(1), LiftSetExtras())
        XCTAssertTrue(c.extras(for: slot(1)).isEmpty, "putting a set back to plain clears it")
    }

    func testDetailIsStoredNormalised() {
        let c = controller()
        c.start(plan: plan(), programId: nil, programName: "Arms")
        c.setExtras(slot(2), LiftSetExtras(setType: .straight, parts: [LiftSetPart(weightKg: 5, reps: 5)], rir: 40))

        XCTAssertEqual(c.extras(for: slot(2)).parts, [], "a straight set carries no parts")
        XCTAssertEqual(c.extras(for: slot(2)).rir, 10, "RIR is clamped to 0...10")
    }

    func testRemovingAPendingSetForgetsItsDetail() {
        let c = controller()
        c.start(plan: plan(), programId: nil, programName: "Arms")
        c.setExtras(slot(3), drop)
        XCTAssertTrue(c.removeSet(fromExercise: 0))

        XCTAssertTrue(c.pendingExtras.isEmpty, "adding the set back must not return detail the user dropped")
    }

    func testSavedSetsCarryTheirDetail() {
        let c = controller()
        c.start(plan: plan(), programId: nil, programName: "Arms")
        c.advance()
        c.setExtras(slot(1), drop)
        c.advance()                                                 // set 1 done with detail
        c.setExtras(slot(2), LiftSetExtras(durationSec: 40))        // set 2 never performed

        let completed = c.setsToSave(completingUnfinished: true)
        XCTAssertEqual(completed.first { $0.slot == slot(1) }?.extras, drop)
        XCTAssertEqual(completed.first { $0.slot == slot(2) }?.extras.durationSec, 40,
                       "a set completed at finish keeps what was chosen for it")

        let discarded = c.setsToSave(completingUnfinished: false)
        XCTAssertTrue(discarded.first { $0.slot == slot(2) }?.extras.isEmpty == true,
                      "a discarded set is a 0 x 0 and carries no detail")
    }

    // MARK: - Crash safety

    func testDetailSurvivesARelaunchBothPerformedAndPending() throws {
        let c = controller()
        c.start(plan: plan(), programId: nil, programName: "Arms")
        c.advance()
        c.setExtras(slot(1), drop)
        c.advance()                                                 // set 1 done
        let pending = LiftSetExtras(side: .right, durationSec: 30)
        c.setExtras(slot(2), pending)                               // set 2 chosen in advance

        let snapshot = try XCTUnwrap(LiftSessionPersistence.load())
        let resumed = controller()
        resumed.resume(from: snapshot)

        XCTAssertEqual(resumed.engine?.recordedSet(for: slot(1))?.extras, drop)
        XCTAssertEqual(resumed.pendingExtras, [slot(2): pending])
    }

    func testASnapshotWithoutDetailStillResumesAsPlainSets() throws {
        let engine = LiftSessionEngine(plan: plan(), startTs: Int(Date().timeIntervalSince1970) - 600)
        let snapshot = LiftSessionPersistence.snapshot(engine: engine, programId: nil, programName: nil,
                                                       pendingValues: [:], pendingWarmups: [])
        let json = try XCTUnwrap(String(data: try XCTUnwrap(LiftSessionPersistence.encode(snapshot)), encoding: .utf8))
        XCTAssertFalse(json.contains("pendingExtras"), "a session with no detail encodes exactly as before")
        XCTAssertTrue(LiftSessionPersistence.pendingExtras(from: snapshot).isEmpty)
    }

    // MARK: - The typed form

    func testFormParsesTypedTextAndConvertsDropWeightsFromPounds() {
        var form = LiftSetExtrasForm()
        form.switchType(to: .dropset)
        form.parts[0].weightText = "66,14"
        form.parts[0].repsText = "6"
        form.rirText = "1,5"
        form.durationText = " 40 "

        let extras = form.extras(system: .imperial)
        XCTAssertEqual(extras.parts.count, 1)
        XCTAssertEqual(extras.parts[0].weightKg ?? 0, 30, accuracy: 0.01)
        XCTAssertEqual(extras.rir, 1.5)
        XCTAssertEqual(extras.durationSec, 40)
    }

    func testFormDropsAPartWithoutRepsAndResetsPartsWhenTheShapeChanges() {
        var form = LiftSetExtrasForm()
        form.switchType(to: .restpause)
        XCTAssertEqual(form.parts.first?.restText, String(LiftSetExtrasForm.defaultBurstRestSec))
        XCTAssertEqual(form.extras(system: .metric).parts, [], "a burst with no reps is not stored")

        form.parts[0].repsText = "5"
        form.switchType(to: .straight)
        XCTAssertTrue(form.parts.isEmpty)
        XCTAssertTrue(form.extras(system: .metric).isEmpty)
    }
}
