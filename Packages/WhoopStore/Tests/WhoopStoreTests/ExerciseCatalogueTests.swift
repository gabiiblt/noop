import XCTest
@testable import WhoopStore

/// Reads the catalogue the app actually ships (StrandiOS/Resources/ExerciseCatalogue), so a rebuild that
/// changes the schema, drops the French text or breaks search fails here rather than on a phone.
final class ExerciseCatalogueTests: XCTestCase {
    static var shipped: URL {
        URL(fileURLWithPath: #filePath)            // .../Packages/WhoopStore/Tests/WhoopStoreTests/<file>
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("StrandiOS/Resources/ExerciseCatalogue")
    }

    private func catalogue() throws -> ExerciseCatalogue {
        try ExerciseCatalogue(directory: Self.shipped)
    }

    func testOpensReadOnlyWithTheWholeCatalogue() throws {
        let c = try catalogue()
        XCTAssertGreaterThan(c.count, 5000)
    }

    func testDecodesAnExerciseWithFrenchTextMusclesAndImage() throws {
        let e = try XCTUnwrap(catalogue().exercise(id: "0314"))
        XCTAssertEqual(e.nameEn, "dumbbell incline bench press")
        XCTAssertEqual(e.name(french: true), "Développé couché incliné aux haltères")
        XCTAssertEqual(e.name(french: false), "Dumbbell incline bench press")
        XCTAssertEqual(e.primaryMuscle, .chest)
        XCTAssertFalse(e.instructions(french: true).isEmpty)
        XCTAssertNotEqual(e.instructions(french: true), e.instructions(french: false))
        let url = try XCTUnwrap(catalogue().imageURL(for: e))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testSearchIgnoresAccentsAndCaseAndMatchesEveryWord() throws {
        let c = try catalogue()
        let hits = try c.search("DÉVELOPPÉ incliné haltères")
        XCTAssertTrue(hits.contains { $0.id == "0314" })
        XCTAssertTrue(hits.allSatisfy { ExerciseCatalogue.fold($0.nameFr ?? "").contains("incline") })
        XCTAssertEqual(try c.search("bench press").first?.nameEn, "barbell bench press")
    }

    func testFiltersByMuscleAndEquipment() throws {
        let c = try catalogue()
        let hits = try c.search("", muscle: .biceps, equipment: "dumbbell", limit: 50)
        XCTAssertFalse(hits.isEmpty)
        XCTAssertTrue(hits.allSatisfy { $0.primaryMuscle == .biceps && $0.equipment == "dumbbell" })
        XCTAssertEqual(try c.equipmentValues().first, "body weight")
    }

    func testLikeWildcardsInTheQueryAreLiteral() throws {
        XCTAssertTrue(try catalogue().search("%_%").isEmpty)
    }

    func testExercisesByIdKeepTheRequestedOrderAndSkipUnknownIds() throws {
        let rows = try catalogue().exercises(ids: ["0025", "nope", "0314"])
        XCTAssertEqual(rows.map(\.id), ["0025", "0314"])
    }

    func testMissingFolderThrows() {
        XCTAssertThrowsError(try ExerciseCatalogue(directory: URL(fileURLWithPath: "/nonexistent")))
    }
}
