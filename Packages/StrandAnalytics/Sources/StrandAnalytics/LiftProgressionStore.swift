import Foundation
import WhoopStore

// MARK: - From stored rows to the progression engine, and back to a stamp
//
// `LiftProgression` is pure over its own small types; this is the seam that turns what the store holds (a
// program line with its rule, the sets of an exercise with their stamped targets) into those types, and the
// engine's answer into the plan a session runs and the stamp it saves. Pure too: no database, no screen.
//
// The progression rules follow openGym's (Duarte Santos, MIT authorization to Gabriel Bolatoglu; see
// ATTRIBUTION.md).

public enum LiftProgressionStore {

    /// The rules a person can pick for a program line. `time` is not offered yet: a program line has no
    /// seconds field to run it on.
    public static let pickable: [LiftProgressionPolicy] = [.linear, .double, .triple]

    public static func policy(of item: LiftProgramItemRow) -> LiftProgressionPolicy? {
        guard let raw = item.progression, let p = LiftProgressionPolicy(rawValue: raw),
              pickable.contains(p) else { return nil }
        return p
    }

    /// The engine's view of a program line, or nil when the line has no usable rule.
    ///
    /// The rep range maps the way openGym keeps it: `reps` is the upper bound and `repsMin` the lower, so a
    /// line "8-12" is (12, 8) and a line with one rep number has no range. `perSide` is true when any logged
    /// set was done on one side.
    public static func config(for item: LiftProgramItemRow, perSide: Bool = false) -> LiftProgressionConfig? {
        guard let policy = policy(of: item) else { return nil }
        let high = item.targetRepsHigh
        let low = item.targetRepsLow
        let reps = (high ?? 0) > 0 ? high : ((low ?? 0) > 0 ? low : nil)
        let repsMin = (high ?? 0) > 0 && (low ?? 0) > 0 ? low : nil
        let sets = max(1, item.targetSets ?? 1)
        let ceiling = (item.targetSetsMax ?? 0) > sets ? item.targetSetsMax : nil
        return LiftProgressionConfig(
            policy: policy, mode: .reps, sets: sets, reps: reps, repsMin: repsMin, setsMax: ceiling,
            weightKg: (item.targetWeightKg ?? 0) > 0 ? item.targetWeightKg : nil,
            incKg: (item.incrementKg ?? 0) > 0 ? item.incrementKg! : defaultIncrementKg,
            perSide: perSide, bodyweight: false,
            deloadFactor: item.deloadFactor)
    }

    /// The load step when the line sets none: the smallest common plate pair.
    public static let defaultIncrementKg = 2.5

    /// The plan a session is stamped with, from the line it was built from.
    public static func stamp(for item: LiftProgramItemRow) -> LiftPlanStamp {
        let ceiling = (item.targetSetsMax ?? 0) > max(1, item.targetSets ?? 1) ? item.targetSetsMax : nil
        return LiftPlanStamp(progression: item.progression, sets: max(1, item.targetSets ?? 1),
                             repsLow: (item.targetRepsLow ?? 0) > 0 ? item.targetRepsLow : nil,
                             repsHigh: (item.targetRepsHigh ?? 0) > 0 ? item.targetRepsHigh : nil,
                             setsMax: ceiling,
                             weightKg: (item.targetWeightKg ?? 0) > 0 ? item.targetWeightKg : nil)
    }

    /// A stamp back as the engine's plan, mapping the rep range exactly as `config(for:)` does, so a plan that
    /// did not change reads as the same plan.
    static func plan(from stamp: LiftPlanStamp) -> LiftProgressionPlan {
        let reps = (stamp.repsHigh ?? 0) > 0 ? stamp.repsHigh : stamp.repsLow
        let repsMin = (stamp.repsHigh ?? 0) > 0 && (stamp.repsLow ?? 0) > 0 ? stamp.repsLow : nil
        return LiftProgressionPlan(sets: max(1, stamp.sets), reps: reps, repsMin: repsMin, sec: stamp.sec,
                                   setsMax: stamp.setsMax, weightKg: stamp.weightKg)
    }

    /// The finished sessions of ONE exercise, oldest first, as the engine reads them.
    ///
    /// `sets` is every stored set of the exercise (any order); `sessionStarts` maps a session id to when it
    /// started, so sessions sort by when they happened. A session with no stamp on its sets (older than v50,
    /// or run without a rule) carries no target and is judged against the line's current plan. Warm-ups are
    /// left out. A set saved at zero reps was never performed and reads as not done.
    public static func sessions(from sets: [LiftSetRow], sessionStarts: [String: Int]) -> [LiftProgressionSession] {
        let work = sets.filter { !$0.isWarmup }
        let grouped = Dictionary(grouping: work, by: \.sessionId)
        return grouped
            .sorted { (sessionStarts[$0.key] ?? 0, $0.key) < (sessionStarts[$1.key] ?? 0, $1.key) }
            .map { _, rows in
                let ordered = rows.sorted { $0.ord < $1.ord }
                let engineSets = ordered.map {
                    LiftProgressionSet(weightKg: $0.weightKg ?? 0, reps: $0.reps ?? 0, done: ($0.reps ?? 0) > 0)
                }
                let stamped = ordered.contains { $0.targetReps != nil || $0.plan != nil }
                guard stamped else { return LiftProgressionSession(sets: engineSets) }
                let aims = ordered.compactMap(\.targetReps)
                let stamp = ordered.compactMap(\.plan).first
                let range = stamp.map { plan(from: $0) }
                let target = LiftProgressionTarget(
                    sets: ordered.count,
                    reps: aims.max() ?? range?.reps,
                    repsMin: range?.repsMin,
                    weightKg: ordered.compactMap(\.targetWeightKg).first,
                    setsMax: range?.setsMax,
                    rowReps: aims.count == ordered.count ? aims : nil,
                    perSide: ordered.contains { $0.side != nil })
                return LiftProgressionSession(sets: engineSets, target: target, planned: range)
            }
    }

    /// The next prescription for a program line from its exercise's stored sets, or nil when the line has no
    /// rule. `lineSets` are the sets of this exercise (matched by the caller by name or catalogue id).
    public static func prescription(for item: LiftProgramItemRow, lineSets: [LiftSetRow],
                                    sessionStarts: [String: Int]) -> LiftPrescription? {
        let perSide = lineSets.contains { $0.side != nil }
        guard let cfg = config(for: item, perSide: perSide) else { return nil }
        return LiftProgression.nextPrescription(
            config: cfg, sessions: sessions(from: lineSets, sessionStarts: sessionStarts))
    }
}
