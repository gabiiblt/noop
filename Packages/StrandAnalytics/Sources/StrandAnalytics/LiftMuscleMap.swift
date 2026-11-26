import Foundation
import WhoopStore

// MARK: - The muscle map: volume, recovery and neglect per muscle
//
// `LiftRecovery` is the maths (ported from openGym's `recovery.js`); this is the seam that reads what the store holds
// (the sets of every session, with the muscles each was counted under) and answers, per muscle: how many sets it got
// this week, how fatigued it is, how much strength it has kept, and when it last did a working set. Pure: no
// database, no screen.
//
// An exercise's muscles are the classification each set was SNAPSHOT with, so reclassifying an exercise later never
// rewrites what past weeks counted as. An unclassified exercise (no primary muscle) claims no muscle it was never
// assigned. The recovery model credits a secondary muscle 0.4 as openGym does; the weekly volume keeps NOOP's own
// published fractional 0.5 (`LiftMetrics.muscleCounts`), so the two numbers answer different questions and are
// never mixed.

public struct LiftMuscleMapEntry: Equatable, Sendable {
    public var muscle: LiftMuscle
    /// Fractional sets in the last 7 days: a direct set 1.0, an indirect one 0.5.
    public var weeklySets: Double
    /// Fatigue in [0, 1).
    public var fatigue: Double
    public var state: LiftFatigueState
    /// Retained strength: 1 for 14 days after the last working set, decaying toward 0.5.
    public var strength: Double
    /// Unix seconds of the last session with a working set for this muscle; nil when it never has one.
    public var lastTrainedTs: Int?
    /// Whole days since then; nil when never.
    public var daysSinceTrained: Int?

    /// Never trained in the history read.
    public var isUntrained: Bool { lastTrainedTs == nil }
    /// Not trained for longer than a muscle keeps its full strength (14 days), or never.
    public var isNeglected: Bool { strength < 1 }
}

public enum LiftMuscleMap {

    /// How much a secondary muscle counts toward recovery against a primary (openGym's `SECONDARY`).
    public static let secondaryRecoveryWeight = 0.4
    static let weekSeconds = 7 * 86_400

    /// The recovery model's view of stored sets: one session per stored session, one entry per exercise in it.
    ///
    /// A set saved at zero reps was never performed and is not done. A rest-pause set's bursts are NOT extra work
    /// (its reps already total them); a drop set's drops are.
    public static func sessions(from sets: [LiftSetRow], sessionStarts: [String: Int]) -> [LiftRecoverySession] {
        Dictionary(grouping: sets, by: \.sessionId)
            .compactMap { sessionId, rows -> LiftRecoverySession? in
                guard let start = sessionStarts[sessionId] else { return nil }
                let ordered = rows.sorted { $0.ord < $1.ord }
                var order: [String] = []
                var byExercise: [String: [LiftSetRow]] = [:]
                for row in ordered {
                    if byExercise[row.exercise] == nil { order.append(row.exercise) }
                    byExercise[row.exercise, default: []].append(row)
                }
                let entries = order.map { name -> LiftRecoveryEntry in
                    let group = byExercise[name] ?? []
                    return LiftRecoveryEntry(exercise: name, weights: weights(of: group[0]), sets: group.map(recoverySet))
                }
                return LiftRecoverySession(timestamp: Double(start) * 1000, entries: entries)
            }
            .sorted { $0.timestamp < $1.timestamp }
    }

    /// 1 for the primary muscle, 0.4 for each secondary; none for an unclassified exercise.
    static func weights(of row: LiftSetRow) -> [LiftMuscle: Double] {
        var out: [LiftMuscle: Double] = [:]
        guard let primary = row.primaryMuscle else { return out }
        out[primary] = 1
        for m in row.secondaryMuscles where m != primary { out[m] = secondaryRecoveryWeight }
        return out
    }

    static func recoverySet(_ row: LiftSetRow) -> LiftRecoverySet {
        LiftRecoverySet(
            weightKg: row.weightKg, reps: row.reps, done: LiftMetrics.isPerformed(reps: row.reps), isWarmup: row.isWarmup,
            rir: row.rir, rpe: row.rpe, isFailure: row.isFailure,
            drops: row.setType == .dropset
                ? row.parts.map { LiftRecoverySet.Drop(weightKg: $0.weightKg ?? 0, reps: $0.reps) } : [])
    }

    /// The map for every muscle, head to toe, as of `now` (unix seconds).
    public static func build(sets: [LiftSetRow], sessionStarts: [String: Int], now: Int) -> [LiftMuscleMapEntry] {
        let sessions = sessions(from: sets, sessionStarts: sessionStarts)
        let nowMs = Double(now) * 1000
        let fatigue = LiftRecovery.fatigue(sessions, now: nowMs)
        let strength = LiftRecovery.strength(sessions, now: nowMs)

        let week = sets.filter { (sessionStarts[$0.sessionId] ?? .min) > now - weekSeconds && (sessionStarts[$0.sessionId] ?? .max) <= now }
        let weekly = LiftMetrics.muscleCounts(week).fractional

        var last: [LiftMuscle: Int] = [:]
        for row in sets where !row.isWarmup && LiftMetrics.isPerformed(reps: row.reps) {
            guard let start = sessionStarts[row.sessionId] else { continue }
            for muscle in weights(of: row).keys where start > (last[muscle] ?? .min) { last[muscle] = start }
        }

        return LiftMuscle.allCases.map { muscle in
            let f = fatigue[muscle] ?? 0
            let lastTs = last[muscle]
            return LiftMuscleMapEntry(
                muscle: muscle, weeklySets: weekly[muscle] ?? 0, fatigue: f, state: LiftRecovery.state(f),
                strength: strength[muscle] ?? LiftRecovery.strengthFloor,
                lastTrainedTs: lastTs, daysSinceTrained: lastTs.map { max(0, (now - $0) / 86_400) })
        }
    }
}

// MARK: - Shading

/// What the map shows. Volume and neglect read the same entries as recovery, only differently.
public enum LiftMuscleMapMode: String, CaseIterable, Codable, Sendable {
    /// Fractional sets in the last 7 days.
    case volume
    /// How fatigued each muscle is now.
    case recovery
    /// Which muscles have gone longest without a working set.
    case neglect
}

extension LiftMuscleMap {

    /// The shade step of one muscle, 0 (none) to 4 (strongest). More shade always means "more of what the mode shows":
    /// more sets, more fatigue, more neglect.
    ///
    /// The volume steps are a reading aid, never a target for anyone: the research band is stated beside the bars
    /// (`LiftMetrics.ReferenceDose`), and where a muscle sits in it is not a prescription.
    public static func level(_ entry: LiftMuscleMapEntry, mode: LiftMuscleMapMode) -> Int {
        switch mode {
        case .volume:
            let s = entry.weeklySets
            if s <= 0 { return 0 }
            if s <= 2 { return 1 }
            if s < 4 { return 2 }
            if s < 10 { return 3 }
            return 4
        case .recovery:
            if entry.fatigue < 0.02 { return 0 }
            return min(4, Int((entry.fatigue * 4).rounded(.up)))
        case .neglect:
            // Full strength is not neglect; the floor (never trained, or long gone) is the strongest shade.
            if entry.strength >= 1 { return 0 }
            return min(4, max(1, Int(((1 - entry.strength) / 0.125).rounded(.up))))
        }
    }

    /// Muscles never trained in the history read, head to toe.
    public static func untrained(_ map: [LiftMuscleMapEntry]) -> [LiftMuscle] { map.filter(\.isUntrained).map(\.muscle) }

    /// Muscles still recovering or fatigued, most fatigued first.
    public static func recovering(_ map: [LiftMuscleMapEntry]) -> [LiftMuscleMapEntry] {
        map.filter { $0.state != .ready }.sorted { $0.fatigue > $1.fatigue }
    }

    /// Muscles trained before but not for over two weeks, longest ago first.
    public static func neglected(_ map: [LiftMuscleMapEntry]) -> [LiftMuscleMapEntry] {
        map.filter { !$0.isUntrained && $0.isNeglected }.sorted { ($0.daysSinceTrained ?? 0) > ($1.daysSinceTrained ?? 0) }
    }
}
