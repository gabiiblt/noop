import XCTest
import GRDB
@testable import WhoopStore

/// v53: a program's place in a rotation (A, B, C) and the days off after it.
final class LiftRotationStoreTests: XCTestCase {

    private func program(_ id: String, ord: Int? = nil, rest: Int = 0) -> LiftProgramRow {
        LiftProgramRow(id: id, deviceId: "my-whoop", name: id, note: nil, createdAt: 1, updatedAt: 1, archived: false,
                       rotationOrd: ord, restDaysAfter: rest)
    }

    func testAProgramKeepsItsPlaceAndRestDays() async throws {
        let store = try await WhoopStore.inMemory()
        let a = program("a", ord: 0, rest: 2)
        let b = program("b")
        _ = try await store.upsertLiftPrograms([a, b])
        let back = try await store.liftPrograms(deviceId: "my-whoop")
        XCTAssertEqual(Set(back.map(\.id)), ["a", "b"])
        XCTAssertEqual(back.first { $0.id == "a" }, a)
        XCTAssertNil(back.first { $0.id == "b" }?.rotationOrd)
        XCTAssertEqual(back.first { $0.id == "b" }?.restDaysAfter, 0)
    }

    func testNoRestStoresNullAndAnUpsertCanTakeAProgramOutOfTheRotation() async throws {
        let store = try await WhoopStore.inMemory()
        _ = try await store.upsertLiftPrograms([program("a", ord: 1, rest: 3)])
        _ = try await store.upsertLiftPrograms([program("a")])
        let raw = try await store.syncRead { db -> [Int?] in
            let r = try Row.fetchOne(db, sql: "SELECT rotationOrd, restDaysAfter FROM liftProgram WHERE id = 'a'")
            return [r?["rotationOrd"], r?["restDaysAfter"]]
        }
        XCTAssertEqual(raw, [nil, nil])
    }

    func testTheValuesAreBounded() {
        let p = program("a", ord: -4, rest: 99)
        XCTAssertEqual(p.rotationOrd, 0)
        XCTAssertEqual(p.restDaysAfter, LiftProgramRow.maxRestDays)
        XCTAssertEqual(program("b", rest: -2).restDaysAfter, 0)
    }

    func testV53KeepsWhatV52Stored() async throws {
        let dbQueue = try DatabaseQueue()
        try WhoopStore.makeMigrator().migrate(dbQueue, upTo: "v52-lift-superset-backup")
        try await dbQueue.write { db in
            try db.execute(sql: "INSERT INTO liftProgram (id, deviceId, name, createdAt, updatedAt, archived) VALUES ('p', 'my-whoop', 'Push', 1, 1, 0)")
        }
        try WhoopStore.makeMigrator().migrate(dbQueue)
        let kept = try await dbQueue.read { db -> [String?] in
            let r = try Row.fetchOne(db, sql: "SELECT name, rotationOrd, restDaysAfter FROM liftProgram")
            return [r?["name"], (r?["rotationOrd"] as Int?).map(String.init), (r?["restDaysAfter"] as Int?).map(String.init)]
        }
        XCTAssertEqual(kept, ["Push", nil, nil])
    }
}
