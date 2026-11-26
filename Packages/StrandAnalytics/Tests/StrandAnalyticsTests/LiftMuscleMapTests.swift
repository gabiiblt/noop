import XCTest
import WhoopStore
@testable import StrandAnalytics

/// Stored sets turned into the muscle map. The recovery maths is checked against openGym's own code in
/// `LiftRecoveryOracleTests`; these check what reaches it, and what the map says.
final class LiftMuscleMapTests: XCTestCase {

    private let now = 1_800_000_000
    private let day = 86_400

    private func set(_ id: String, session: String, ord: Int, exercise: String = "Bench press", primary: LiftMuscle? = .chest,
                     secondary: [LiftMuscle] = [.triceps, .frontDelts], w: Double = 80, r: Int = 8, warm: Bool = false,
                     type: LiftSetType = .straight, parts: [LiftSetPart] = [], rir: Double? = nil) -> LiftSetRow {
        LiftSetRow(id: id, deviceId: "d", sessionId: session, ord: ord, exercise: exercise, primaryMuscle: primary,
                   secondaryMuscles: secondary, setIndex: ord + 1, weightKg: w, reps: r, rpe: nil, isWarmup: warm,
                   startTs: nil, endTs: nil, restSec: nil, note: nil, setType: type, parts: parts, rir: rir)
    }

    private func bench(_ session: String, count: Int = 8) -> [LiftSetRow] {
        (0..<count).map { set("\(session)-\($0)", session: session, ord: $0) }
    }

    private func entry(_ map: [LiftMuscleMapEntry], _ m: LiftMuscle) -> LiftMuscleMapEntry { map.first { $0.muscle == m }! }

    // MARK: - Reading stored sets

    func testAPrimaryCountsFullAndASecondaryCountsLess() {
        let sessions = LiftMuscleMap.sessions(from: bench("s"), sessionStarts: ["s": now - day])
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].entries.count, 1)
        XCTAssertEqual(sessions[0].entries[0].weights, [.chest: 1, .triceps: 0.4, .frontDelts: 0.4])
        XCTAssertEqual(sessions[0].timestamp, Double(now - day) * 1000)
    }

    func testAnUnclassifiedExerciseClaimsNoMuscle() {
        let rows = [set("a", session: "s", ord: 0, primary: nil, secondary: [.biceps])]
        XCTAssertEqual(LiftMuscleMap.sessions(from: rows, sessionStarts: ["s": now])[0].entries[0].weights, [:])
    }

    func testASetSavedAtZeroRepsWasNeverPerformed() {
        let rows = [set("a", session: "s", ord: 0, r: 8), set("b", session: "s", ord: 1, r: 0)]
        let sets = LiftMuscleMap.sessions(from: rows, sessionStarts: ["s": now])[0].entries[0].sets
        XCTAssertEqual(sets.map(\.done), [true, false])
    }

    func testDropsAreExtraWorkButRestPauseBurstsAreNot() {
        let parts = [LiftSetPart(weightKg: 30, reps: 6), LiftSetPart(weightKg: nil, reps: 6)]
        let drop = LiftMuscleMap.recoverySet(set("a", session: "s", ord: 0, type: .dropset, parts: parts))
        XCTAssertEqual(drop.drops.count, 2)
        let rest = LiftMuscleMap.recoverySet(set("b", session: "s", ord: 0, type: .restpause, parts: parts))
        XCTAssertEqual(rest.drops, [], "its reps already total every burst")
    }

    func testSessionsWithoutAStartAreLeftOutAndTheRestAreOrdered() {
        let rows = bench("late", count: 1) + bench("early", count: 1) + bench("ghost", count: 1)
        let out = LiftMuscleMap.sessions(from: rows, sessionStarts: ["late": now, "early": now - 5 * day])
        XCTAssertEqual(out.map(\.timestamp), [Double(now - 5 * day) * 1000, Double(now) * 1000])
    }

    // MARK: - The map

    func testEveryMuscleIsPresentHeadToToe() {
        let map = LiftMuscleMap.build(sets: [], sessionStarts: [:], now: now)
        XCTAssertEqual(map.map(\.muscle), LiftMuscle.allCases)
        XCTAssertTrue(map.allSatisfy { $0.weeklySets == 0 && $0.fatigue == 0 && $0.state == .ready })
        XCTAssertTrue(map.allSatisfy { $0.isUntrained && $0.isNeglected && $0.strength == 0.5 })
    }

    func testAFreshSessionFatiguesTheWorkedMusclesMoreThanTheOthers() {
        let map = LiftMuscleMap.build(sets: bench("s"), sessionStarts: ["s": now - day], now: now)
        XCTAssertGreaterThan(entry(map, .chest).fatigue, entry(map, .triceps).fatigue)
        XCTAssertGreaterThan(entry(map, .triceps).fatigue, 0)
        XCTAssertEqual(entry(map, .quads).fatigue, 0)
        XCTAssertEqual(entry(map, .chest).state, .fatigued, "8 hard sets yesterday")
        XCTAssertEqual(entry(map, .chest).strength, 1)
        XCTAssertEqual(entry(map, .chest).daysSinceTrained, 1)
        XCTAssertFalse(entry(map, .chest).isUntrained)
        XCTAssertFalse(entry(map, .chest).isNeglected)
    }

    func testWeeklyVolumeUsesTheFractionalCreditAndOnlyTheLastSevenDays() {
        let rows = bench("recent", count: 4) + bench("old", count: 10)
        let map = LiftMuscleMap.build(sets: rows, sessionStarts: ["recent": now - 2 * day, "old": now - 9 * day], now: now)
        XCTAssertEqual(entry(map, .chest).weeklySets, 4, "4 direct sets this week; the older session is outside it")
        XCTAssertEqual(entry(map, .triceps).weeklySets, 2, "4 indirect sets at 0.5")
    }

    func testAWarmUpMovesNeitherTheVolumeNorTheLastTrainedDay() {
        let rows = [set("w", session: "s", ord: 0, warm: true)]
        let map = LiftMuscleMap.build(sets: rows, sessionStarts: ["s": now - day], now: now)
        XCTAssertEqual(entry(map, .chest).weeklySets, 0)
        XCTAssertNil(entry(map, .chest).lastTrainedTs)
    }

    func testAMuscleLeftAloneIsNeglectedAfterTwoWeeks() {
        let rows = bench("s", count: 4)
        let recent = LiftMuscleMap.build(sets: rows, sessionStarts: ["s": now - 10 * day], now: now)
        XCTAssertEqual(entry(recent, .chest).strength, 1, "still inside the 14 days of full retention")
        let old = LiftMuscleMap.build(sets: rows, sessionStarts: ["s": now - 40 * day], now: now)
        XCTAssertTrue(entry(old, .chest).isNeglected)
        XCTAssertFalse(entry(old, .chest).isUntrained, "it was trained once, which is not the same as never")
        XCTAssertEqual(entry(old, .chest).daysSinceTrained, 40)
        XCTAssertLessThan(entry(old, .chest).strength, 1)
        XCTAssertGreaterThan(entry(old, .chest).strength, 0.5)
    }

    func testRecoveryEasesWithRestAndLegsOutlastArms() {
        let arms = (0..<8).map { set("a\($0)", session: "arm", ord: $0, exercise: "Curl", primary: .biceps, secondary: []) }
        let legs = (0..<8).map { set("l\($0)", session: "leg", ord: $0, exercise: "Squat", primary: .quads, secondary: []) }
        let map = LiftMuscleMap.build(sets: arms + legs, sessionStarts: ["arm": now - 2 * day, "leg": now - 2 * day], now: now)
        XCTAssertGreaterThan(entry(map, .quads).fatigue, entry(map, .biceps).fatigue, "48 h half-life against 24 h")
    }

    func testAFutureSessionIsNotThisWeeksVolume() {
        let map = LiftMuscleMap.build(sets: bench("s", count: 3), sessionStarts: ["s": now + day], now: now)
        XCTAssertEqual(entry(map, .chest).weeklySets, 0)
    }

    // MARK: - Shading

    private func entryWith(weekly: Double = 0, fatigue: Double = 0, strength: Double = 1, last: Int? = nil) -> LiftMuscleMapEntry {
        LiftMuscleMapEntry(muscle: .chest, weeklySets: weekly, fatigue: fatigue, state: LiftRecovery.state(fatigue),
                           strength: strength, lastTrainedTs: last, daysSinceTrained: last.map { _ in 3 })
    }

    func testVolumeShadesStepUpWithSets() {
        let steps = [0, 0.5, 2, 2.5, 3.5, 4, 9.5, 10, 30].map { LiftMuscleMap.level(entryWith(weekly: $0), mode: .volume) }
        XCTAssertEqual(steps, [0, 1, 1, 2, 2, 3, 3, 4, 4])
    }

    func testRecoveryShadesFollowFatigueAndNothingIsShadedWhenRested() {
        let steps = [0, 0.01, 0.1, 0.3, 0.6, 0.9].map { LiftMuscleMap.level(entryWith(fatigue: $0), mode: .recovery) }
        XCTAssertEqual(steps, [0, 0, 1, 2, 3, 4])
    }

    func testNeglectShadesGrowAsStrengthFadesToTheFloor() {
        let steps = [1, 0.95, 0.8, 0.6, 0.5].map { LiftMuscleMap.level(entryWith(strength: $0), mode: .neglect) }
        XCTAssertEqual(steps, [0, 1, 2, 4, 4])
        XCTAssertEqual(LiftMuscleMap.level(entryWith(strength: 0.999), mode: .neglect), 1, "any loss of retention shows")
    }

    func testTheListsSplitNeverTrainedFromLeftAlone() {
        let rows = bench("s", count: 4)
        let map = LiftMuscleMap.build(sets: rows, sessionStarts: ["s": now - 40 * day], now: now)
        XCTAssertTrue(LiftMuscleMap.untrained(map).contains(.quads))
        XCTAssertFalse(LiftMuscleMap.untrained(map).contains(.chest))
        XCTAssertEqual(LiftMuscleMap.neglected(map).first?.muscle, .chest, "trained 40 days ago, longest ago first")
        XCTAssertTrue(LiftMuscleMap.recovering(map).isEmpty, "40 days is rested")
        let fresh = LiftMuscleMap.build(sets: rows, sessionStarts: ["s": now - day], now: now)
        XCTAssertEqual(LiftMuscleMap.recovering(fresh).first?.muscle, .chest, "the most fatigued first")
    }
}
