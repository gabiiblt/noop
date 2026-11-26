import XCTest
@testable import Strand
import StrandAnalytics
import WhoopStore

/// A gym on a session: which one it was done at survives a relaunch, a line carries the equipment that decides
/// whether plates apply, and the sentence under a set reads right in the gym's own unit.
final class LiftGymSessionTests: XCTestCase {

    private func gym(unit: String = "kg", plates: [LiftGymPlate] = []) -> LiftGymRow {
        LiftGymRow(id: "g", deviceId: "d", name: "Home", unit: unit, plates: plates, createdAt: 1)
    }

    // MARK: - The sentence under a set

    func testABarbellLoadReadsPerSide() throws {
        let load = try XCTUnwrap(LiftGymLoading.load(gym: gym(), equipment: "barbell", weightKg: 102.5))
        XCTAssertEqual(LiftGymCopy.line(load), "Per side: 25 + 15 + 1.25 kg")
    }

    func testAWeightAtTheBarIsBarOnlyAndUnderItIsExplained() throws {
        let at = try XCTUnwrap(LiftGymLoading.load(gym: gym(), equipment: "barbell", weightKg: 20))
        XCTAssertEqual(LiftGymCopy.line(at), "Bar only")
        let under = try XCTUnwrap(LiftGymLoading.load(gym: gym(), equipment: "barbell", weightKg: 15))
        XCTAssertEqual(LiftGymCopy.line(under), "Under the 20 kg bar: the log may count the plates without the bar.")
    }

    func testWhatTheGymCannotMakeIsSaid() throws {
        let home = gym(plates: [LiftGymPlate(size: 20, pairs: 1), LiftGymPlate(size: 5, pairs: 1)])
        let load = try XCTUnwrap(LiftGymLoading.load(gym: home, equipment: "barbell", weightKg: 120))
        XCTAssertEqual(LiftGymCopy.line(load), "Per side: 20 + 5 kg · short by 25 kg")
    }

    func testAPoundGymReadsInPounds() throws {
        let load = try XCTUnwrap(LiftGymLoading.load(gym: gym(unit: "lb"), equipment: "barbell", weight: 225))
        XCTAssertEqual(LiftGymCopy.line(load), "Per side: 45 + 45 lb", "(225 - 45) / 2 = 90, two 45 lb plates")
    }

    func testASingleStackReadsAsPlates() throws {
        let load = try XCTUnwrap(LiftGymLoading.load(gym: gym(plates: [LiftGymPlate(size: 20, pairs: 1)]),
                                                     equipment: "sled machine", weightKg: 40))
        XCTAssertEqual(LiftGymCopy.line(load), "Plates: 20 + 20 kg")
    }

    func testTheGymSummary() {
        XCTAssertEqual(LiftGymCopy.summary(gym()), "Standard plates")
        let full = LiftGymRow(id: "g", deviceId: "d", name: "Big", plates: [LiftGymPlate(size: 20, pairs: 2)],
                              bars: ["barbell": 15], dumbbells: [5, 10, 15], stacks: ["Leg curl": [5]], createdAt: 1)
        XCTAssertEqual(LiftGymCopy.summary(full), "1 plate sizes · 1 bars · 3 dumbbells · 1 machine stacks")
    }

    // MARK: - Crash safety

    func testTheGymAndTheEquipmentSurviveARelaunch() throws {
        let line = LiftPlanItem(exercise: "Back squat", targetSets: 3, programItemId: "i1", equipment: "barbell")
        let engine = LiftSessionEngine(plan: [line], startTs: Int(Date().timeIntervalSince1970) - 60)
        let snapshot = LiftSessionPersistence.snapshot(engine: engine, programId: "p", programName: "Legs",
                                                       pendingValues: [:], pendingWarmups: [], gymId: "g1")
        let back = try XCTUnwrap(LiftSessionPersistence.decode(try XCTUnwrap(LiftSessionPersistence.encode(snapshot))))
        XCTAssertEqual(back.gymId, "g1")
        XCTAssertEqual(LiftSessionPersistence.engine(from: back).plan[0].equipment, "barbell")
    }

    func testASnapshotWithoutAGymEncodesAsBefore() throws {
        let engine = LiftSessionEngine(plan: [LiftPlanItem(exercise: "Curl")], startTs: Int(Date().timeIntervalSince1970) - 60)
        let snapshot = LiftSessionPersistence.snapshot(engine: engine, programId: nil, programName: nil,
                                                       pendingValues: [:], pendingWarmups: [])
        let json = try XCTUnwrap(String(data: try XCTUnwrap(LiftSessionPersistence.encode(snapshot)), encoding: .utf8))
        XCTAssertFalse(json.contains("gymId"))
        XCTAssertFalse(json.contains("equipment"))
        XCTAssertNil(LiftSessionPersistence.engine(from: snapshot).plan[0].equipment)
    }
}
