import XCTest
import GRDB
@testable import WhoopStore

/// v50: the rule on a program line, and the target each set was built from.
final class LiftProgressionStoreTests: XCTestCase {
    private let dev = "my-whoop"

    private func session(_ store: WhoopStore) async throws {
        _ = try await store.upsertLiftSessions([LiftSessionRow(
            id: "s1", deviceId: dev, startTs: 1_800_000_000, endTs: 1_800_003_600, sport: "Strength Training",
            programId: nil, programName: nil, sessionRpe: nil, note: nil)])
    }

    func testV50AddsNullableColumns() async throws {
        let store = try await WhoopStore.inMemory()
        let itemCols = try await store.columnNamesForTest(table: "liftProgramItem")
        for c in ["progression", "targetSetsMax", "incrementKg", "deloadFactor"] {
            XCTAssertTrue(itemCols.contains(c), "liftProgramItem missing \(c)")
        }
        let setCols = try await store.columnNamesForTest(table: "liftSet")
        for c in ["targetReps", "targetWeightKg", "planJSON"] {
            XCTAssertTrue(setCols.contains(c), "liftSet missing \(c)")
        }
    }

    func testAProgramLineKeepsItsRule() async throws {
        let store = try await WhoopStore.inMemory()
        let line = LiftProgramItemRow(
            id: "i1", deviceId: dev, programId: "p1", ord: 0, exercise: "Bench press", targetSets: 3,
            targetRepsLow: 8, targetRepsHigh: 12, targetRpe: nil, targetWeightKg: 60, restSec: 90, note: nil,
            progression: "triple", targetSetsMax: 5, incrementKg: 1.25, deloadFactor: 0.85)
        let plain = LiftProgramItemRow(
            id: "i2", deviceId: dev, programId: "p1", ord: 1, exercise: "Row", targetSets: 3,
            targetRepsLow: 10, targetRepsHigh: nil, targetRpe: nil, targetWeightKg: nil, restSec: nil, note: nil)
        _ = try await store.replaceLiftProgramItems(programId: "p1", items: [line, plain])
        let back = try await store.liftProgramItems(programId: "p1")
        XCTAssertEqual(back, [line, plain])
        XCTAssertNil(back[1].progression, "a line with no rule stays rule-free, which is how every older line behaves")
    }

    func testASetKeepsItsTargetAndThePlanItWasBuiltFrom() async throws {
        let store = try await WhoopStore.inMemory()
        try await session(store)
        let plan = LiftPlanStamp(progression: "triple", sets: 3, repsLow: 8, repsHigh: 12, setsMax: 5, weightKg: 60)
        var row = LiftSetRow(id: "a", deviceId: dev, sessionId: "s1", ord: 0, exercise: "Bench press",
                             primaryMuscle: .chest, setIndex: 1, weightKg: 60, reps: 12, rpe: nil, isWarmup: false,
                             startTs: nil, endTs: nil, restSec: nil, note: nil)
        row.targetReps = 12
        row.targetWeightKg = 60
        row.plan = plan
        _ = try await store.upsertLiftSets([row])
        let back = try await store.liftSets(sessionId: "s1")
        XCTAssertEqual(back, [row])
        XCTAssertEqual(back.first?.plan, plan)

        row.plan = nil
        row.targetReps = nil
        _ = try await store.upsertLiftSets([row])
        let cleared = try await store.syncRead { db in
            try Row.fetchOne(db, sql: "SELECT targetReps, planJSON FROM liftSet WHERE id = 'a'").map { ($0["targetReps"] as Int?, $0["planJSON"] as String?) }
        }
        XCTAssertNil(cleared?.0)
        XCTAssertNil(cleared?.1, "no stamp stores NULL, not an empty object")
    }

    func testAMalformedStampReadsAsNone() async throws {
        let store = try await WhoopStore.inMemory()
        try await session(store)
        let row = LiftSetRow(id: "x", deviceId: dev, sessionId: "s1", ord: 0, exercise: "Curl", primaryMuscle: .biceps,
                             setIndex: 1, weightKg: 20, reps: 10, rpe: nil, isWarmup: false,
                             startTs: nil, endTs: nil, restSec: nil, note: nil)
        _ = try await store.upsertLiftSets([row])
        try await store.syncWrite { db in try db.execute(sql: "UPDATE liftSet SET planJSON = '{nope' WHERE id = 'x'") }
        let rows = try await store.liftSets(sessionId: "s1")
        XCTAssertNil(rows.first?.plan, "a set never fails to load because of its stamp")
        XCTAssertEqual(rows.first?.weightKg, 20)
    }

    func testASetSavedByAnOlderBuildStillDecodes() throws {
        let legacy = """
        {"id":"o","deviceId":"my-whoop","sessionId":"s1","ord":0,"exercise":"Curl","primaryMuscle":"biceps",
         "secondaryMuscles":[],"setIndex":1,"weightKg":40,"reps":10,"isWarmup":false,"setType":"dropset"}
        """
        let row = try JSONDecoder().decode(LiftSetRow.self, from: Data(legacy.utf8))
        XCTAssertNil(row.targetReps)
        XCTAssertNil(row.plan)
        XCTAssertEqual(row.setType, .dropset)
    }

    /// Existing rows survive the migration untouched and read as having no rule and no stamp.
    func testV50KeepsWhatV49Stored() async throws {
        let dbQueue = try DatabaseQueue()
        try WhoopStore.makeMigrator().migrate(dbQueue, upTo: "v49-lift-training-detail")
        try await dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO liftProgramItem (id, deviceId, programId, ord, exercise, targetSets, targetWeightKg)
                VALUES ('i', 'my-whoop', 'p', 0, 'Squat', 5, 100)
                """)
            try db.execute(sql: """
                INSERT INTO liftSet (id, deviceId, sessionId, ord, exercise, setIndex, weightKg, reps, isWarmup)
                VALUES ('s', 'my-whoop', 'sess', 0, 'Squat', 1, 100, 5, 0)
                """)
        }
        try WhoopStore.makeMigrator().migrate(dbQueue)
        let kept = try await dbQueue.read { db -> [String?] in
            let item = try Row.fetchOne(db, sql: "SELECT exercise, progression, deloadFactor FROM liftProgramItem WHERE id = 'i'")
            let set = try Row.fetchOne(db, sql: "SELECT exercise, targetReps, planJSON FROM liftSet WHERE id = 's'")
            return [item?["exercise"], item?["progression"], item?["deloadFactor"], set?["exercise"], set?["targetReps"], set?["planJSON"]]
        }
        XCTAssertEqual(kept, ["Squat", nil, nil, "Squat", nil, nil])
    }
}
