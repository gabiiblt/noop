import XCTest
import WhoopStore
@testable import StrandAnalytics

/// A stored gym applied to one set. The plate maths itself is checked against openGym's own code in
/// `LiftPlatesOracleTests`; these check that a gym's inventory, bars and unit reach it correctly.
final class LiftGymLoadingTests: XCTestCase {

    private func gym(unit: String = "kg", plates: [LiftGymPlate] = [], bars: [String: Double] = [:],
                     dumbbells: [Double] = []) -> LiftGymRow {
        LiftGymRow(id: "g", deviceId: "d", name: "Gym", unit: unit, plates: plates, bars: bars,
                   dumbbells: dumbbells, createdAt: 1)
    }

    func testABarbellSplitsWhatIsBeyondTheBarOverTwoSides() throws {
        let out = try XCTUnwrap(LiftGymLoading.load(gym: gym(), equipment: "barbell", weightKg: 102.5))
        XCTAssertEqual(out.base, 20)
        XCTAssertEqual(out.load.perSide, 41.25)
        XCTAssertEqual(out.load.plates, [25, 15, 1.25])
        XCTAssertEqual(out.achievable, 102.5)
    }

    func testTheGymsOwnBarBeatsTheBuiltInOne() throws {
        let short = gym(bars: ["barbell": 15])
        let out = try XCTUnwrap(LiftGymLoading.load(gym: short, equipment: "barbell", weightKg: 60))
        XCTAssertEqual(out.base, 15)
        XCTAssertEqual(out.load.perSide, 22.5)
    }

    func testAHomeRackThatCannotMakeTheWeightSaysWhatIsMissing() throws {
        let home = gym(plates: [LiftGymPlate(size: 20, pairs: 1), LiftGymPlate(size: 5, pairs: 1)])
        let out = try XCTUnwrap(LiftGymLoading.load(gym: home, equipment: "barbell", weightKg: 120))
        XCTAssertEqual(out.load.plates, [20, 5])
        XCTAssertEqual(out.load.missing, 25, "50 per side asked, 25 per side owned")
        XCTAssertEqual(out.achievable, 70, "the bar plus two sides of 25")
    }

    func testAGymThatListedNoPlatesHasTheStandardSet() throws {
        XCTAssertEqual(LiftGymLoading.inventory(of: gym()), LiftPlates.defaultInventory(.kg))
        XCTAssertEqual(LiftGymLoading.inventory(of: gym(unit: "lb")), LiftPlates.defaultInventory(.lb))
    }

    func testAPoundGymWorksInPoundsAndNeverConvertsItsPlates() throws {
        let lb = gym(unit: "lb")
        let out = try XCTUnwrap(LiftGymLoading.load(gym: lb, equipment: "barbell", weightKg: 100))
        XCTAssertEqual(out.unit, .lb)
        XCTAssertEqual(out.requested, 220.46, "100 kg is 220.46 lb, to two decimals")
        XCTAssertEqual(out.base, 45, "the bar is a 45 lb bar, not 44.1")
        XCTAssertTrue(out.load.plates.allSatisfy { LiftPlates.sizes(.lb).contains($0) })
    }

    func testAWeightTypedInTheGymsUnitMatchesItsKilogramTwin() throws {
        let lb = gym(unit: "lb")
        let a = try XCTUnwrap(LiftGymLoading.load(gym: lb, equipment: "barbell", weight: 225))
        let b = try XCTUnwrap(LiftGymLoading.load(gym: lb, equipment: "barbell", weightKg: 225 / LiftGymLoading.poundsPerKilogram))
        XCTAssertEqual(a.load.plates, b.load.plates)
        XCTAssertEqual(a.load.perSide, 90, "(225 - 45) / 2")
    }

    func testASingleStackLoadsAllOfItAndBothPlatesOfAPair() throws {
        let sled = gym(plates: [LiftGymPlate(size: 20, pairs: 1)])
        let out = try XCTUnwrap(LiftGymLoading.load(gym: sled, equipment: "sled machine", weightKg: 40))
        XCTAssertEqual(out.base, 0)
        XCTAssertEqual(out.load.plates, [20, 20], "one pair of 20s is two 20s on a sled")
    }

    func testEquipmentThatTakesNoPlatesHasNoLoad() {
        XCTAssertNil(LiftGymLoading.load(gym: gym(), equipment: "dumbbell", weightKg: 20))
        XCTAssertNil(LiftGymLoading.load(gym: gym(), equipment: "cable", weightKg: 20))
        XCTAssertNil(LiftGymLoading.load(gym: gym(), equipment: nil, weightKg: 20))
        XCTAssertNil(LiftGymLoading.load(gym: gym(), equipment: "barbell", weightKg: 0))
    }

    func testAWeightAtOrUnderTheBarIsBarOnly() throws {
        let out = try XCTUnwrap(LiftGymLoading.load(gym: gym(), equipment: "barbell", weightKg: 20))
        XCTAssertTrue(out.load.barOnly)
        let under = try XCTUnwrap(LiftGymLoading.load(gym: gym(), equipment: "barbell", weightKg: 15))
        XCTAssertTrue(under.load.underBar, "usually the log counts the plates without the bar")
    }

    func testTheNearestDumbbellIsOnesTheGymOwns() {
        let g = gym(dumbbells: [10, 12.5, 15, 20])
        XCTAssertEqual(LiftGymLoading.nearestDumbbell(gym: g, weightKg: 13), 12.5)
        XCTAssertEqual(LiftGymLoading.nearestDumbbell(gym: g, weightKg: 100), 20)
        XCTAssertNil(LiftGymLoading.nearestDumbbell(gym: gym(), weightKg: 13))
    }

    func testAMachinesStackIsKeptPerExercise() {
        let g = LiftGymRow(id: "g", deviceId: "d", name: "G", stacks: ["Leg curl": [18.1, 5]], createdAt: 1)
        XCTAssertEqual(LiftGymLoading.stack(of: g, exercise: "Leg curl"), [5, 18.1])
        XCTAssertEqual(LiftGymLoading.stack(of: g, exercise: "Row"), [])
    }
}
