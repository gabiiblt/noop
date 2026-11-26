import XCTest
import WhoopStore
@testable import StrandAnalytics

/// A rotation of programs (A, B, C): what is up next follows from what was trained last.
final class LiftRotationTests: XCTestCase {

    private let day = 86_400
    private let base = 1_800_000_000 - (1_800_000_000 % 86_400)    // a UTC midnight
    private var utc: TimeZone { TimeZone(secondsFromGMT: 0)! }

    private func program(_ id: String, ord: Int?, rest: Int = 0, archived: Bool = false, created: Int = 0) -> LiftProgramRow {
        LiftProgramRow(id: id, deviceId: "d", name: id.uppercased(), note: nil, createdAt: created, updatedAt: created,
                       archived: archived, rotationOrd: ord, restDaysAfter: rest)
    }

    private func session(_ program: String?, dayOffset: Int, hour: Int = 10) -> LiftSessionRow {
        LiftSessionRow(id: "s\(dayOffset)\(program ?? "-")", deviceId: "d", startTs: base + dayOffset * day + hour * 3600,
                       endTs: nil, sport: "Strength Training", programId: program, programName: nil, sessionRpe: nil, note: nil)
    }

    private func next(_ programs: [LiftProgramRow], _ sessions: [LiftSessionRow], today: Int) -> LiftRotationNext? {
        LiftRotation.next(steps: LiftRotation.steps(programs), sessions: sessions, today: today,
                          dayOf: { LiftRotation.localDay($0, timeZone: utc) })
    }

    private var abc: [LiftProgramRow] { [program("a", ord: 0), program("b", ord: 1), program("c", ord: 2)] }
    private var today0: Int { LiftRotation.localDay(base, timeZone: utc) }

    // MARK: - Steps

    func testStepsAreInRotationOrderAndLeaveOutArchivedAndUnrotatedPrograms() {
        let programs = [program("c", ord: 2), program("x", ord: nil), program("a", ord: 0), program("old", ord: 1, archived: true), program("b", ord: 1)]
        XCTAssertEqual(LiftRotation.steps(programs).map(\.programId), ["a", "b", "c"])
    }

    func testAnEmptyRotationHasNothingNext() {
        XCTAssertNil(next([program("a", ord: nil)], [], today: today0))
    }

    // MARK: - What is next

    func testWithNoSessionTheFirstProgramIsDueToday() throws {
        let n = try XCTUnwrap(next(abc, [], today: today0))
        XCTAssertEqual(n.step.programId, "a")
        XCTAssertEqual(n.state, .notStarted)
        XCTAssertTrue(n.isDue)
        XCTAssertNil(n.after)
    }

    func testTheNextProgramFollowsTheLastSessionAndIsDueTheDayAfter() throws {
        let sessions = [session("a", dayOffset: 0)]
        let tomorrow = try XCTUnwrap(next(abc, sessions, today: today0 + 1))
        XCTAssertEqual(tomorrow.step.programId, "b")
        XCTAssertEqual(tomorrow.after?.programId, "a")
        XCTAssertEqual(tomorrow.state, .due(overdueDays: 0))
        let sameDay = try XCTUnwrap(next(abc, sessions, today: today0))
        XCTAssertEqual(sameDay.state, .rest(dueDay: today0 + 1, daysLeft: 1), "just trained: the next one is tomorrow")
        XCTAssertFalse(sameDay.isDue)
    }

    func testTheRotationWrapsAround() throws {
        let n = try XCTUnwrap(next(abc, [session("c", dayOffset: 0)], today: today0 + 1))
        XCTAssertEqual(n.step.programId, "a")
    }

    func testRestDaysPushTheNextSessionBack() throws {
        let programs = [program("a", ord: 0), program("b", ord: 1, rest: 2), program("c", ord: 2)]
        let sessions = [session("b", dayOffset: 0)]
        XCTAssertEqual(try XCTUnwrap(next(programs, sessions, today: today0 + 1)).state, .rest(dueDay: today0 + 3, daysLeft: 2))
        XCTAssertEqual(try XCTUnwrap(next(programs, sessions, today: today0 + 3)).state, .due(overdueDays: 0))
        XCTAssertEqual(try XCTUnwrap(next(programs, sessions, today: today0 + 6)).state, .due(overdueDays: 3),
                       "skipped days make it overdue, never skip it")
    }

    func testTheRotationFollowsWhatWasTrainedNotWhatWasPlanned() throws {
        // A was due, B was trained instead: C is next.
        let sessions = [session("a", dayOffset: 0), session("b", dayOffset: 2)]
        XCTAssertEqual(try XCTUnwrap(next(abc, sessions, today: today0 + 3)).step.programId, "c")
    }

    func testASessionOfAProgramOutsideTheRotationDoesNotMoveIt() throws {
        let sessions = [session("a", dayOffset: 0), session("other", dayOffset: 1), session(nil, dayOffset: 1)]
        let n = try XCTUnwrap(next(abc, sessions, today: today0 + 2))
        XCTAssertEqual(n.step.programId, "b")
        XCTAssertEqual(n.after?.programId, "a")
    }

    func testTheMostRecentSessionDecidesWhateverTheOrderGiven() throws {
        let sessions = [session("b", dayOffset: 3), session("a", dayOffset: 0), session("c", dayOffset: 1)]
        XCTAssertEqual(try XCTUnwrap(next(abc, sessions, today: today0 + 4)).step.programId, "c")
    }

    func testASingleProgramRotationRepeatsIt() throws {
        let n = try XCTUnwrap(next([program("a", ord: 0)], [session("a", dayOffset: 0)], today: today0 + 1))
        XCTAssertEqual(n.step.programId, "a")
    }

    func testTheDayIsTheLocalOne() {
        let late = base + 23 * 3600 + 30 * 60       // 23:30 UTC
        let paris = TimeZone(identifier: "Europe/Paris")!
        XCTAssertEqual(LiftRotation.localDay(late, timeZone: utc), today0)
        XCTAssertEqual(LiftRotation.localDay(late, timeZone: paris), today0 + 1, "already tomorrow in Paris")
    }

    // MARK: - Editing

    func testAddingPutsAProgramAtTheEndAndRemovingClosesTheGap() {
        var programs = [program("a", ord: 0), program("b", ord: nil), program("c", ord: 1)]
        programs = LiftRotation.adding(programs, id: "b")
        XCTAssertEqual(LiftRotation.steps(programs).map(\.programId), ["a", "c", "b"])
        programs = LiftRotation.removing(programs, id: "a")
        XCTAssertEqual(programs.first { $0.id == "c" }?.rotationOrd, 0, "renumbered with no gap")
        XCTAssertEqual(programs.first { $0.id == "b" }?.rotationOrd, 1)
        XCTAssertNil(programs.first { $0.id == "a" }?.rotationOrd)
    }

    func testAddingTwiceOrRemovingAnOutsiderChangesNothing() {
        let programs = [program("a", ord: 0), program("b", ord: nil)]
        XCTAssertEqual(LiftRotation.adding(programs, id: "a"), programs)
        XCTAssertEqual(LiftRotation.removing(programs, id: "b").map(\.rotationOrd), [0, nil])
    }

    func testMovingSwapsNeighboursAndStopsAtTheEnds() {
        let programs = abc
        XCTAssertEqual(LiftRotation.steps(LiftRotation.moved(programs, id: "c", by: -1)).map(\.programId), ["a", "c", "b"])
        XCTAssertEqual(LiftRotation.moved(programs, id: "a", by: -1), programs)
        XCTAssertEqual(LiftRotation.moved(programs, id: "c", by: 1), programs)
    }

    func testRestDaysAreBoundedAndLeaveWithTheProgram() {
        var programs = LiftRotation.settingRest(abc, id: "b", days: 99)
        XCTAssertEqual(programs.first { $0.id == "b" }?.restDaysAfter, LiftProgramRow.maxRestDays)
        XCTAssertEqual(LiftRotation.settingRest(abc, id: "b", days: -3).first { $0.id == "b" }?.restDaysAfter, 0)
        programs = LiftRotation.removing(programs, id: "b")
        XCTAssertEqual(programs.first { $0.id == "b" }?.restDaysAfter, 0, "a program out of the rotation carries no rest")
    }
}
