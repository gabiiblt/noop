import XCTest
import WhoopStore
@testable import StrandAnalytics

/// Stored sets turned into the balance engine's input. The engine is checked against openGym's own code in
/// `LiftBalanceOracleTests`.
final class LiftBalanceStoreTests: XCTestCase {

    private let exercises: [String: LiftBalanceExercise] = [
        "0030": LiftBalanceExercise(name: "close grip bench press", equipment: "barbell"),
        "0047": LiftBalanceExercise(name: "incline bench press", equipment: "barbell"),
        "0251": LiftBalanceExercise(name: "chest dip", equipment: "body weight"),
        "0085": LiftBalanceExercise(name: "romanian deadlift", equipment: "barbell"),
    ]

    private func set(_ id: String, _ session: String, ord: Int, catalogue: String?, w: Double, r: Int, warm: Bool = false) -> LiftSetRow {
        LiftSetRow(id: id, deviceId: "d", sessionId: session, ord: ord, exercise: "x", primaryMuscle: nil, setIndex: 1,
                   weightKg: w, reps: r, rpe: nil, isWarmup: warm, startTs: nil, endTs: nil, restSec: nil, note: nil,
                   catalogueId: catalogue)
    }

    func testSetsWithoutACatalogueLinkAreLeftOut() {
        let rows = [set("a", "s", ord: 0, catalogue: "0030", w: 100, r: 5), set("b", "s", ord: 1, catalogue: nil, w: 200, r: 5)]
        let input = LiftBalanceStore.input(sets: rows, sessionStarts: ["s": 1], bodyweightKg: 80, female: false, exercises: exercises)
        XCTAssertEqual(input.sessions.count, 1)
        XCTAssertEqual(input.sessions[0].entries.map(\.exerciseId), ["0030"])
    }

    func testSessionsAreOrderedAndASetAtZeroRepsWasNeverPerformed() {
        let rows = [set("a", "late", ord: 0, catalogue: "0030", w: 100, r: 5), set("b", "early", ord: 0, catalogue: "0030", w: 90, r: 0)]
        let input = LiftBalanceStore.input(sets: rows, sessionStarts: ["late": 2000, "early": 1000], bodyweightKg: nil, female: false, exercises: exercises)
        XCTAssertEqual(input.sessions.map(\.timestamp), [1_000_000, 2_000_000])
        XCTAssertEqual(input.sessions[0].entries[0].sets[0].done, false)
        XCTAssertNil(input.bodyweightKg, "no weigh-in reads as none, not as zero")
    }

    func testAnEndToEndReadingThroughStorage() throws {
        let rows = [set("a", "s", ord: 0, catalogue: "0030", w: 100, r: 5), set("b", "s", ord: 1, catalogue: "0047", w: 85, r: 5)]
        let input = LiftBalanceStore.input(sets: rows, sessionStarts: ["s": 1], bodyweightKg: 80, female: false, exercises: exercises)
        let poliquin = try XCTUnwrap(LiftBalanceStore.results(input).first { $0.template.id == "poliquin" })
        let incline = try XCTUnwrap(poliquin.results.first { $0.roleId == "inclineBench" })
        XCTAssertEqual(incline.actualPct ?? 0, 85, accuracy: 1e-9)
        XCTAssertEqual(incline.status, .weak, "91% asked, 85% shown, more than five points under")
        let anchor = try XCTUnwrap(poliquin.results.first { $0.roleId == "narrowBench" })
        XCTAssertEqual(anchor.status, .balanced, "an anchor against itself")
    }

    func testTheTablesNameCatalogueExercisesAndEveryIdIsListed() {
        let ids = LiftBalanceStore.tableExerciseIds
        XCTAssertEqual(ids.count, Set(ids).count)
        XCTAssertTrue(ids.contains("0030") && ids.contains("3193"))
        XCTAssertEqual(LiftBalanceTemplate.all.map(\.id), ["poliquin", "thibaudeauPowerlifting", "atg"])
    }

    func testAWeighInIsNeededOnlyWhereTheTableAsksForOne() throws {
        let rows = [set("a", "s", ord: 0, catalogue: "0085", w: 85, r: 12)]
        let input = LiftBalanceStore.input(sets: rows, sessionStarts: ["s": 1], bodyweightKg: nil, female: false, exercises: exercises)
        let atg = try XCTUnwrap(LiftBalanceStore.results(input).first { $0.template.id == "atg" })
        let rdl = try XCTUnwrap(atg.results.first { $0.roleId == "romanianDeadlift" })
        XCTAssertTrue(rdl.needsBodyweight)
        XCTAssertEqual(rdl.status, .noData)
    }
}
