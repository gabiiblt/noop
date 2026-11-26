import Foundation
import WhoopStore

// MARK: - Stored sets to the strength-balance engine
//
// `LiftBalance` reads sessions of exercises named by catalogue id; this turns what the store holds into them. A set
// whose exercise was typed by hand (no catalogue link) cannot be matched to a table's role and is left out: the
// tables name catalogue exercises, and guessing from a typed name would score the wrong lift.
//
// The tables are reference ratios from coaching literature (see `LiftBalance`), never a norm for anyone.

public enum LiftBalanceStore {

    /// Every catalogue id the tables name, for looking their names and equipment up.
    public static var tableExerciseIds: [String] {
        var seen = Set<String>(), out: [String] = []
        for t in LiftBalanceTemplate.all { for r in t.roles { for id in r.exerciseIds where seen.insert(id).inserted { out.append(id) } } }
        return out
    }

    /// The engine's input from stored sets, oldest session first. A set saved at zero reps was never performed.
    public static func input(sets: [LiftSetRow], sessionStarts: [String: Int], bodyweightKg: Double?, female: Bool,
                             overrides: [String: String] = [:], exercises: [String: LiftBalanceExercise]) -> LiftBalanceInput {
        let linked = sets.filter { $0.catalogueId != nil }
        let sessions = Dictionary(grouping: linked, by: \.sessionId)
            .compactMap { sessionId, rows -> LiftBalanceSession? in
                guard let start = sessionStarts[sessionId] else { return nil }
                var order: [String] = []
                var byId: [String: [LiftSetRow]] = [:]
                for row in rows.sorted(by: { $0.ord < $1.ord }) {
                    guard let id = row.catalogueId else { continue }
                    if byId[id] == nil { order.append(id) }
                    byId[id, default: []].append(row)
                }
                let entries = order.map { id in
                    LiftBalanceEntry(exerciseId: id, sets: (byId[id] ?? []).map {
                        LiftBalanceSet(weightKg: $0.weightKg ?? 0, reps: $0.reps ?? 0,
                                       done: LiftMetrics.isPerformed(reps: $0.reps), isWarmup: $0.isWarmup)
                    })
                }
                return LiftBalanceSession(timestamp: Double(start) * 1000, bodyweightKg: nil, entries: entries)
            }
            .sorted { $0.timestamp < $1.timestamp }
        return LiftBalanceInput(sessions: sessions, bodyweightKg: (bodyweightKg ?? 0) > 0 ? bodyweightKg : nil,
                                female: female, overrides: overrides, exercises: exercises)
    }

    /// Every table scored against the log.
    public static func results(_ input: LiftBalanceInput) -> [(template: LiftBalanceTemplate, results: [LiftBalanceResult])] {
        LiftBalanceTemplate.all.map { ($0, LiftBalance.compute($0, input)) }
    }
}
