import XCTest
import GRDB
@testable import WhoopStore

/// v51: a gym's equipment, and which gym a session was done at.
final class LiftGymTests: XCTestCase {
    private let dev = "my-whoop"

    private func gym(_ id: String = "g1", name: String = "Home", unit: String = "kg", created: Int = 100,
                     lastUsed: Int? = nil) -> LiftGymRow {
        LiftGymRow(id: id, deviceId: dev, name: name, unit: unit,
                   plates: [LiftGymPlate(size: 5, pairs: 2), LiftGymPlate(size: 20, pairs: 1), LiftGymPlate(size: 1.25, pairs: 0)],
                   bars: ["barbell": 15, "ez barbell": 0],
                   dumbbells: [10, 5, 5, -1],
                   stacks: ["Leg curl": [18.1, 5, 11.3], "Empty": []],
                   createdAt: created, lastUsedTs: lastUsed)
    }

    func testAGymNormalisesWhatItIsGiven() {
        let g = gym()
        XCTAssertEqual(g.plates, [LiftGymPlate(size: 20, pairs: 1), LiftGymPlate(size: 5, pairs: 2)],
                       "heaviest first, and a size with no pairs is not owned")
        XCTAssertEqual(g.bars, ["barbell": 15], "a bar of 0 is not a bar")
        XCTAssertEqual(g.dumbbells, [5, 10], "sorted, unique and positive")
        XCTAssertEqual(g.stacks, ["Leg curl": [5, 11.3, 18.1]], "an empty stack is no stack")
        XCTAssertEqual(LiftGymRow(id: "x", deviceId: dev, name: "n", unit: "stone", createdAt: 1).unit, "kg")
    }

    func testEveryFieldRoundTrips() async throws {
        let store = try await WhoopStore.inMemory()
        let g = gym(lastUsed: 500)
        _ = try await store.upsertLiftGyms([g])
        let back = try await store.liftGyms(deviceId: dev)
        XCTAssertEqual(back, [g])
    }

    func testAnEmptyInventoryStoresNullNotAnEmptyList() async throws {
        let store = try await WhoopStore.inMemory()
        _ = try await store.upsertLiftGyms([LiftGymRow(id: "e", deviceId: dev, name: "Bare", createdAt: 1)])
        let raw = try await store.syncRead { db -> [String?] in
            let r = try Row.fetchOne(db, sql: "SELECT platesJSON, barsJSON, dumbbellsJSON, stacksJSON FROM liftGym WHERE id = 'e'")
            return [r?["platesJSON"], r?["barsJSON"], r?["dumbbellsJSON"], r?["stacksJSON"]]
        }
        XCTAssertEqual(raw, [nil, nil, nil, nil])
        let back = try await store.liftGyms(deviceId: dev)
        XCTAssertEqual(back.first?.plates, [])
    }

    func testTheSameInventoryAlwaysStoresAsTheSameText() async throws {
        let store = try await WhoopStore.inMemory()
        _ = try await store.upsertLiftGyms([gym("a"), gym("b")])
        let texts = try await store.syncRead { db in
            try Row.fetchAll(db, sql: "SELECT platesJSON, barsJSON FROM liftGym ORDER BY id").map { ($0["platesJSON"] as String?, $0["barsJSON"] as String?) }
        }
        XCTAssertEqual(texts[0].0, texts[1].0)
        XCTAssertEqual(texts[0].1, texts[1].1)
    }

    func testMalformedJSONReadsAsNothingOwned() async throws {
        let store = try await WhoopStore.inMemory()
        _ = try await store.upsertLiftGyms([gym()])
        try await store.syncWrite { db in try db.execute(sql: "UPDATE liftGym SET platesJSON = '{nope', dumbbellsJSON = '7' WHERE id = 'g1'") }
        let g = try await store.liftGyms(deviceId: dev).first
        XCTAssertEqual(g?.plates, [], "a gym never fails to load because of its inventory")
        XCTAssertEqual(g?.dumbbells, [])
        XCTAssertEqual(g?.name, "Home")
    }

    func testTheGymUsedMostRecentlyComesFirst() async throws {
        let store = try await WhoopStore.inMemory()
        _ = try await store.upsertLiftGyms([gym("old", name: "Old", created: 1, lastUsed: 10),
                                            gym("new", name: "New", created: 2, lastUsed: 99),
                                            gym("never", name: "Never", created: 50)])
        let names = try await store.liftGyms(deviceId: dev).map(\.name)
        XCTAssertEqual(names, ["New", "Old", "Never"])
    }

    func testANameIsTrimmedAndCutAndABlankOneIsSkipped() async throws {
        let store = try await WhoopStore.inMemory()
        let long = String(repeating: "x", count: 100)
        let n = try await store.upsertLiftGyms([gym("a", name: "  Big gym  "), gym("b", name: "   "), gym("c", name: long)])
        XCTAssertEqual(n, 2)
        let names = try await store.liftGyms(deviceId: dev).map(\.name)
        XCTAssertTrue(names.contains("Big gym"))
        XCTAssertTrue(names.contains(String(repeating: "x", count: WhoopStore.maxGymNameLength)))
    }

    func testANewGymPastTheBoundIsRefusedButAnExistingOneUpdates() async throws {
        let store = try await WhoopStore.inMemory()
        let rows = (0..<WhoopStore.maxGyms).map { gym("g\($0)", name: "Gym \($0)", created: $0) }
        _ = try await store.upsertLiftGyms(rows)
        let refused = try await store.upsertLiftGyms([gym("extra", name: "Extra")])
        XCTAssertEqual(refused, 0)
        let renamed = try await store.upsertLiftGyms([gym("g3", name: "Renamed")])
        XCTAssertEqual(renamed, 1)
        let all = try await store.liftGyms(deviceId: dev)
        XCTAssertEqual(all.count, WhoopStore.maxGyms)
        XCTAssertTrue(all.contains { $0.name == "Renamed" })
    }

    func testDeletingAGymKeepsTheSessionsDoneThere() async throws {
        let store = try await WhoopStore.inMemory()
        _ = try await store.upsertLiftGyms([gym()])
        _ = try await store.upsertLiftSessions([LiftSessionRow(
            id: "s", deviceId: dev, startTs: 1_800_000_000, endTs: nil, sport: "Strength Training",
            programId: nil, programName: nil, sessionRpe: nil, note: nil, gymId: "g1")])
        let deleted = try await store.deleteLiftGym(id: "g1")
        XCTAssertTrue(deleted)
        let sessions = try await store.liftSessions(deviceId: dev, fromTs: 0, toTs: Int.max)
        XCTAssertEqual(sessions.first?.gymId, "g1", "history is never rewritten; the id simply names nothing now")
        let gone = try await store.liftGyms(deviceId: dev)
        XCTAssertTrue(gone.isEmpty)
    }

    func testClearingADevicesDataClearsItsGyms() async throws {
        let store = try await WhoopStore.inMemory()
        _ = try await store.upsertLiftGyms([gym()])
        XCTAssertTrue(DeviceRegistryStore.deviceScopedTables.contains("liftGym"))
    }

    func testV51KeepsWhatV50Stored() async throws {
        let dbQueue = try DatabaseQueue()
        try WhoopStore.makeMigrator().migrate(dbQueue, upTo: "v50-lift-progression")
        try await dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO liftSession (id, deviceId, startTs, sport) VALUES ('s', 'my-whoop', 1800000000, 'Strength Training')
                """)
        }
        try WhoopStore.makeMigrator().migrate(dbQueue)
        let kept = try await dbQueue.read { db in
            try Row.fetchOne(db, sql: "SELECT id, gymId FROM liftSession")
                .map { ($0["id"] as String, $0["gymId"] as String?) }
        }
        XCTAssertEqual(kept?.0, "s")
        XCTAssertNil(kept?.1, "an older session was done at no known gym")
    }
}
