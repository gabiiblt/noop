import XCTest
import GRDB
@testable import WhoopStore

/// v49: set types, failure, RIR, per-side, time/distance and the catalogue link.
final class LiftTrainingDetailTests: XCTestCase {
    private let dev = "my-whoop"

    private func session(_ store: WhoopStore) async throws {
        _ = try await store.upsertLiftSessions([LiftSessionRow(
            id: "s1", deviceId: dev, startTs: 1_800_000_000, endTs: 1_800_003_600, sport: "Strength Training",
            programId: nil, programName: nil, sessionRpe: nil, note: nil)])
    }

    private func set(_ id: String, ord: Int, weight: Double? = 40, reps: Int? = 10,
                     type: LiftSetType = .straight, parts: [LiftSetPart] = []) -> LiftSetRow {
        LiftSetRow(id: id, deviceId: dev, sessionId: "s1", ord: ord, exercise: "Curl", primaryMuscle: .biceps,
                   setIndex: ord + 1, weightKg: weight, reps: reps, rpe: nil, isWarmup: false,
                   startTs: nil, endTs: nil, restSec: nil, note: nil, setType: type, parts: parts)
    }

    func testV49AddsNullableColumnsAndKeepsOldRowsStraight() async throws {
        let store = try await WhoopStore.inMemory()
        let setCols = try await store.columnNamesForTest(table: "liftSet")
        for c in ["setType", "dropsJSON", "isFailure", "rir", "side", "durationSec", "distanceM", "catalogueId"] {
            XCTAssertTrue(setCols.contains(c), "liftSet missing \(c)")
        }
        let exerciseCols = try await store.columnNamesForTest(table: "liftExercise")
        let itemCols = try await store.columnNamesForTest(table: "liftProgramItem")
        XCTAssertTrue(exerciseCols.contains("catalogueId"))
        XCTAssertTrue(itemCols.contains("catalogueId"))

        try await session(store)
        _ = try await store.upsertLiftSets([set("a", ord: 0)])
        let rows = try await store.liftSets(sessionId: "s1")
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.setType, .straight)
        XCTAssertEqual(row.parts, [])
        XCTAssertFalse(row.isFailure)
        let stored = try await store.syncRead { db -> [String?] in
            let r = try Row.fetchOne(db, sql: "SELECT setType, dropsJSON FROM liftSet WHERE id = 'a'")
            return [r?["setType"], r?["dropsJSON"]]
        }
        XCTAssertEqual(stored, [nil, nil], "a straight set stores NULL, like rows from before v49")
    }

    func testEveryNewFieldRoundTrips() async throws {
        let store = try await WhoopStore.inMemory()
        try await session(store)
        var row = set("d", ord: 0, type: .dropset, parts: [LiftSetPart(weightKg: 30, reps: 6), LiftSetPart(weightKg: 20, reps: 5)])
        row.isFailure = true
        row.rir = 0
        row.side = .left
        row.durationSec = 45
        row.distanceM = 20
        row.catalogueId = "0294"
        _ = try await store.upsertLiftSets([row])
        let back = try await store.liftSets(sessionId: "s1")
        XCTAssertEqual(back, [row])
    }

    func testDropSetVolumeAddsTheDropsButRestPauseDoesNot() {
        let drop = set("d", ord: 0, weight: 40, reps: 10, type: .dropset,
                       parts: [LiftSetPart(weightKg: 30, reps: 6), LiftSetPart(weightKg: 20, reps: 5)])
        XCTAssertEqual(drop.volumeKg, 400 + 180 + 100)
        let rp = set("r", ord: 1, weight: 40, reps: 12, type: .restpause,
                     parts: [LiftSetPart(weightKg: nil, reps: 6, restSec: 15), LiftSetPart(weightKg: nil, reps: 6, restSec: 15)])
        XCTAssertEqual(rp.volumeKg, 480, "a rest-pause set's reps already total its bursts")
        XCTAssertEqual(set("s", ord: 2, type: .straight, parts: [LiftSetPart(weightKg: 10, reps: 10)]).parts, [],
                       "a straight set carries no parts")
    }

    func testMalformedPartsJSONReadsAsNoParts() async throws {
        let store = try await WhoopStore.inMemory()
        try await session(store)
        _ = try await store.upsertLiftSets([set("x", ord: 0, type: .dropset, parts: [LiftSetPart(weightKg: 30, reps: 6)])])
        try await store.syncWrite { db in try db.execute(sql: "UPDATE liftSet SET dropsJSON = '{nope' WHERE id = 'x'") }
        let rows = try await store.liftSets(sessionId: "s1")
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.setType, .dropset)
        XCTAssertEqual(row.parts, [])
    }

    func testASetSavedByAnOlderBuildStillDecodes() throws {
        let legacy = """
        {"id":"o","deviceId":"my-whoop","sessionId":"s1","ord":0,"exercise":"Curl","primaryMuscle":"biceps",
         "secondaryMuscles":[],"setIndex":1,"weightKg":40,"reps":10,"isWarmup":false}
        """
        let row = try JSONDecoder().decode(LiftSetRow.self, from: Data(legacy.utf8))
        XCTAssertEqual(row.setType, .straight)
        XCTAssertFalse(row.isFailure)
        XCTAssertNil(row.catalogueId)
        let again = try JSONDecoder().decode(LiftSetRow.self, from: try JSONEncoder().encode(row))
        XCTAssertEqual(again, row)
    }

    func testCatalogueLinkOnARememberedExerciseSurvivesAnUntypedUpsert() async throws {
        let store = try await WhoopStore.inMemory()
        _ = try await store.upsertLiftExercises([LiftExerciseRow(
            id: "e1", deviceId: dev, name: "Curl", primaryMuscle: .biceps, createdAt: 1, lastUsedTs: 1,
            catalogueId: "0294", equipment: "dumbbell")])
        _ = try await store.upsertLiftExercises([LiftExerciseRow(
            id: "e2", deviceId: dev, name: "Curl", primaryMuscle: nil, createdAt: 2, lastUsedTs: 5)])
        let all = try await store.liftExercises(deviceId: dev)
        let row = try XCTUnwrap(all.first { $0.name == "Curl" })
        XCTAssertEqual(row.catalogueId, "0294")
        XCTAssertEqual(row.equipment, "dumbbell")
        XCTAssertEqual(row.lastUsedTs, 5)
    }

    func testProgramLineKeepsItsCatalogueId() async throws {
        let store = try await WhoopStore.inMemory()
        let item = LiftProgramItemRow(id: "i1", deviceId: dev, programId: "p1", ord: 0, exercise: "Curl",
                                      targetSets: 3, targetRepsLow: 10, targetRepsHigh: 12, targetRpe: nil,
                                      targetWeightKg: 12, restSec: 90, note: nil, catalogueId: "0294")
        _ = try await store.replaceLiftProgramItems(programId: "p1", items: [item])
        let items = try await store.liftProgramItems(programId: "p1")
        XCTAssertEqual(items, [item])
    }
}
