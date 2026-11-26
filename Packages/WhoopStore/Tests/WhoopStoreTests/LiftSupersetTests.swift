import XCTest
import GRDB
@testable import WhoopStore

/// v52: supersets (consecutive lines done as a round) and backups (what takes a line's place when its machine is taken).
final class LiftSupersetTests: XCTestCase {
    private let dev = "my-whoop"

    private func line(_ id: String, _ exercise: String, group: String? = nil, backups: [String] = []) -> LiftProgramItemRow {
        LiftProgramItemRow(id: id, deviceId: dev, programId: "p", ord: 0, exercise: exercise, targetSets: 3,
                           targetRepsLow: 10, targetRepsHigh: nil, targetRpe: nil, targetWeightKg: nil,
                           restSec: 90, note: nil, supersetGroup: group, backups: backups)
    }

    private func groups(_ items: [LiftProgramItemRow]) -> [String?] { items.map(\.supersetGroup) }

    private var counter = 0
    private func fresh() -> String { counter += 1; return "n\(counter)" }

    // MARK: - Linking

    func testJoiningTwoLinesMakesAGroupAndCuttingItUndoesIt() {
        counter = 0
        let items = [line("a", "Bench"), line("b", "Row"), line("c", "Curl")]
        let joined = LiftSuperset.toggledLink(items, at: 0, newId: fresh)
        XCTAssertEqual(groups(joined), ["n1", "n1", nil])
        XCTAssertTrue(LiftSuperset.isLinkedToNext(joined, 0))
        XCTAssertFalse(LiftSuperset.isLinkedToNext(joined, 1))
        let cut = LiftSuperset.toggledLink(joined, at: 0, newId: fresh)
        XCTAssertEqual(groups(cut), [nil, nil, nil], "two lines cut apart are two single lines, which are no group")
    }

    func testJoiningTheNextLineExtendsAGroup() {
        counter = 0
        let items = [line("a", "Bench", group: "g"), line("b", "Row", group: "g"), line("c", "Curl")]
        XCTAssertEqual(groups(LiftSuperset.toggledLink(items, at: 1, newId: fresh)), ["g", "g", "g"])
    }

    func testJoiningTwoGroupsMergesThem() {
        let items = [line("a", "A", group: "x"), line("b", "B", group: "x"), line("c", "C", group: "y"), line("d", "D", group: "y")]
        let merged = LiftSuperset.toggledLink(items, at: 1, newId: fresh)
        XCTAssertEqual(Set(groups(merged)).count, 1, "one block of four")
        XCTAssertNotNil(merged[0].supersetGroup)
    }

    func testCuttingTheMiddleOfAGroupLeavesTwoBlocks() {
        counter = 0
        let items = (0..<4).map { line("l\($0)", "E\($0)", group: "g") }
        let cut = LiftSuperset.toggledLink(items, at: 1, newId: fresh)
        XCTAssertEqual(groups(cut), ["g", "g", "n1", "n1"])
    }

    func testCuttingTheEdgeLeavesALoneLineWithNoGroup() {
        counter = 0
        let items = (0..<3).map { line("l\($0)", "E\($0)", group: "g") }
        XCTAssertEqual(groups(LiftSuperset.toggledLink(items, at: 1, newId: fresh)), ["g", "g", nil])
    }

    func testLinkingPastTheEndsDoesNothing() {
        let items = [line("a", "A")]
        XCTAssertEqual(LiftSuperset.toggledLink(items, at: 0), items)
        XCTAssertEqual(LiftSuperset.toggledLink(items, at: -1), items)
        XCTAssertFalse(LiftSuperset.isLinkedToNext(items, 0))
    }

    // MARK: - Normalising after a reorder

    func testAGroupSplitByAReorderBecomesOneGroupPerBlock() {
        counter = 0
        let items = [line("a", "A", group: "g"), line("b", "B"), line("c", "C", group: "g"), line("d", "D", group: "g")]
        XCTAssertEqual(groups(LiftSuperset.normalized(items, newId: fresh)), [nil, nil, "g", "g"],
                       "the lone first member loses its group; the consecutive pair keeps one")
    }

    func testTwoSeparateBlocksOfTheSameIdGetDistinctIds() {
        counter = 0
        let items = [line("a", "A", group: "g"), line("b", "B", group: "g"), line("c", "C"), line("d", "D", group: "g"), line("e", "E", group: "g")]
        XCTAssertEqual(groups(LiftSuperset.normalized(items, newId: fresh)), ["g", "g", nil, "n1", "n1"])
    }

    func testAnAlreadyNormalGroupIsUntouched() {
        let items = [line("a", "A", group: "g"), line("b", "B", group: "g")]
        XCTAssertEqual(LiftSuperset.normalized(items), items)
    }

    // MARK: - Backups

    func testBackupsAreCleanedAndBounded() {
        let cleaned = LiftSuperset.cleanBackups([" Row ", "row", "Bench", "", "Chest press", "Fly", "Dip", "Push-up", "Cable fly"],
                                                excluding: "bench")
        XCTAssertEqual(cleaned, ["Row", "Chest press", "Fly", "Dip", "Push-up"],
                       "unique, never the line's own exercise, trimmed, at most five")
    }

    func testTheExerciseThatHandsOverGoesToTheFrontOfTheBackups() {
        XCTAssertEqual(LiftSuperset.backupsAfterSwap(old: "Leg press", new: "Hack squat", backups: ["Hack squat", "Lunge"]),
                       ["Leg press", "Lunge"])
    }

    // MARK: - Storage

    func testALineKeepsItsGroupAndBackups() async throws {
        let store = try await WhoopStore.inMemory()
        let a = line("a", "Bench", group: "g", backups: ["Dumbbell press", "Push-up"])
        let b = line("b", "Row", group: "g")
        _ = try await store.replaceLiftProgramItems(programId: "p", items: [a, b])
        let back = try await store.liftProgramItems(programId: "p")
        XCTAssertEqual(back, [a, b])
        let raw = try await store.syncRead { db in
            try Row.fetchOne(db, sql: "SELECT backupsJSON FROM liftProgramItem WHERE id = 'b'").map { $0["backupsJSON"] as String? }
        }
        XCTAssertEqual(raw, .some(nil), "no backups stores NULL")
    }

    func testMalformedBackupsReadAsNone() async throws {
        let store = try await WhoopStore.inMemory()
        _ = try await store.replaceLiftProgramItems(programId: "p", items: [line("a", "Bench", backups: ["Row"])])
        try await store.syncWrite { db in try db.execute(sql: "UPDATE liftProgramItem SET backupsJSON = '{nope'") }
        let back = try await store.liftProgramItems(programId: "p")
        XCTAssertEqual(back.first?.backups, [])
        XCTAssertEqual(back.first?.exercise, "Bench")
    }

    func testASetKeepsItsGroupAndWhatItWasSwappedFrom() async throws {
        let store = try await WhoopStore.inMemory()
        _ = try await store.upsertLiftSessions([LiftSessionRow(
            id: "s1", deviceId: dev, startTs: 1_800_000_000, endTs: nil, sport: "Strength Training",
            programId: nil, programName: nil, sessionRpe: nil, note: nil)])
        var row = LiftSetRow(id: "x", deviceId: dev, sessionId: "s1", ord: 0, exercise: "Hack squat", primaryMuscle: .quads,
                             setIndex: 1, weightKg: 100, reps: 8, rpe: nil, isWarmup: false,
                             startTs: nil, endTs: nil, restSec: nil, note: nil)
        row.supersetGroup = "g"
        row.swappedFrom = "Leg press"
        _ = try await store.upsertLiftSets([row])
        let back = try await store.liftSets(sessionId: "s1")
        XCTAssertEqual(back, [row])
    }

    func testASetSavedByAnOlderBuildStillDecodes() throws {
        let legacy = """
        {"id":"o","deviceId":"my-whoop","sessionId":"s1","ord":0,"exercise":"Curl","primaryMuscle":"biceps",
         "secondaryMuscles":[],"setIndex":1,"weightKg":40,"reps":10,"isWarmup":false}
        """
        let row = try JSONDecoder().decode(LiftSetRow.self, from: Data(legacy.utf8))
        XCTAssertNil(row.supersetGroup)
        XCTAssertNil(row.swappedFrom)
    }

    func testV52KeepsWhatV51Stored() async throws {
        let dbQueue = try DatabaseQueue()
        try WhoopStore.makeMigrator().migrate(dbQueue, upTo: "v51-lift-gym")
        try await dbQueue.write { db in
            try db.execute(sql: "INSERT INTO liftProgramItem (id, deviceId, programId, ord, exercise) VALUES ('i', 'my-whoop', 'p', 0, 'Squat')")
        }
        try WhoopStore.makeMigrator().migrate(dbQueue)
        let kept = try await dbQueue.read { db -> [String?] in
            let r = try Row.fetchOne(db, sql: "SELECT exercise, supersetGroup, backupsJSON FROM liftProgramItem")
            return [r?["exercise"], r?["supersetGroup"], r?["backupsJSON"]]
        }
        XCTAssertEqual(kept, ["Squat", nil, nil])
    }
}
