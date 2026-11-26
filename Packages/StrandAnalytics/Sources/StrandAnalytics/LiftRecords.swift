import Foundation
import WhoopStore

// MARK: - Personal records on the set itself, and progress per exercise
//
// Ported from openGym's `frontend/src/lib/set-records.js` (Duarte Santos; reused under the MIT
// authorization he granted Gabriel Bolatoglu, see ATTRIBUTION.md). Its reference results for the four
// cases in `LiftRecordsTests` were produced by running that file under vitest, and are pasted there.
//
// Four kinds, kept apart because they are different claims:
//   weight  the heaviest load ever lifted for this exercise.
//   reps    the most reps at this weight or heavier. Only once something was done at that weight:
//           a weight never lifted before is a weight record, not a rep record.
//   e1rm    the best estimated one-rep max (NOOP's Epley, `LiftMetrics.estimatedOneRepMaxKg`; openGym
//           uses its own formula setting, so this kind is NOOP's, not a port).
//   volume  the biggest single set, weight x reps.
// A set is held against every earlier session PLUS the sets before it in its own session, so set 3 can
// beat set 2 and both keep their mark. An exercise logged for the first time sets no records: everything
// would be one, which says nothing. Warm-ups and sets that were not performed never count, and a loaded
// set never stands for a bodyweight one (0 kg means body weight only).

public enum LiftRecordKind: String, CaseIterable, Sendable {
    case weight, reps, e1rm, volume
}

/// What the history holds for one exercise.
public struct LiftRecordBaseline: Equatable, Sendable {
    public struct Point: Equatable, Sendable {
        public let weightKg: Double
        public let reps: Int
    }

    public private(set) var any: Bool
    public private(set) var weightKg: Double
    public private(set) var e1rmKg: Double
    public private(set) var volumeKg: Double
    public private(set) var points: [Point]

    public static let empty = LiftRecordBaseline(any: false, weightKg: 0, e1rmKg: 0, volumeKg: 0, points: [])

    /// The baseline of an exercise's earlier sets (the caller passes only that exercise's history).
    public static func from(history: [LiftSetRow]) -> LiftRecordBaseline {
        history.sorted { $0.ord < $1.ord }.reduce(into: empty) { base, s in
            guard let (w, r) = LiftRecords.countable(s) else { return }
            base = base.folding(weightKg: w, reps: r)
        }
    }

    /// The baseline with one more performed set folded in.
    public func folding(weightKg w: Double, reps r: Int) -> LiftRecordBaseline {
        guard r > 0 else { return self }
        var next = self
        next.any = true
        if w > 0, w > weightKg { next.weightKg = w }
        if let est = LiftMetrics.estimatedOneRepMaxKg(weightKg: w, reps: r), est > e1rmKg { next.e1rmKg = est }
        if w * Double(r) > volumeKg { next.volumeKg = w * Double(r) }
        next.points.append(Point(weightKg: w, reps: r))
        return next
    }
}

public enum LiftRecords {
    private static let eps = 1e-9

    /// Weight and reps of a set that can hold or set a record: performed, not a warm-up, reps > 0.
    static func countable(_ s: LiftSetRow) -> (Double, Int)? {
        guard !s.isWarmup, let r = s.reps, r > 0 else { return nil }
        return (max(0, s.weightKg ?? 0), r)
    }

    /// The identity records are kept under: the catalogue id when the exercise came from the catalogue
    /// (so renaming it does not reset its records), the name otherwise.
    public static func exerciseKey(_ s: LiftSetRow) -> String {
        if let id = s.catalogueId, !id.isEmpty { return "catalogue:" + id }
        return "name:" + s.exercise
    }

    /// The most reps the baseline holds at `weightKg` or heavier, or nil when nothing was done there.
    public static func repsRecord(at weightKg: Double, in base: LiftRecordBaseline) -> Int? {
        var best: Int?
        for p in base.points where p.weightKg >= weightKg - eps && (p.weightKg > 0) == (weightKg > 0) {
            if best == nil || p.reps > best! { best = p.reps }
        }
        return best
    }

    /// The kinds of record one set sets against `base`, in `LiftRecordKind` order.
    public static func kinds(weightKg: Double, reps: Int, against base: LiftRecordBaseline) -> [LiftRecordKind] {
        guard base.any, reps > 0 else { return [] }
        var out: [LiftRecordKind] = []
        if weightKg > 0, base.weightKg > 0, weightKg > base.weightKg + eps { out.append(.weight) }
        if let rec = repsRecord(at: weightKg, in: base), reps > rec { out.append(.reps) }
        if weightKg > 0 {
            if let est = LiftMetrics.estimatedOneRepMaxKg(weightKg: weightKg, reps: reps),
               base.e1rmKg > 0, est > base.e1rmKg + eps { out.append(.e1rm) }
            if base.volumeKg > 0, weightKg * Double(reps) > base.volumeKg + eps { out.append(.volume) }
        }
        return out
    }

    /// Record marks for every set of a session, keyed by set id (sets with none are absent). `history`
    /// is every set from EARLIER sessions; it is grouped by `exerciseKey` here, so the caller can pass it
    /// unfiltered. Sets are taken in performed order, each held against the history and the sets before it.
    public static func sessionRecords(_ sets: [LiftSetRow], history: [LiftSetRow]) -> [String: [LiftRecordKind]] {
        var baselines = Dictionary(grouping: history, by: exerciseKey).mapValues { LiftRecordBaseline.from(history: $0) }
        var out: [String: [LiftRecordKind]] = [:]
        for s in sets.sorted(by: { $0.ord < $1.ord }) {
            guard let (w, r) = countable(s) else { continue }
            let key = exerciseKey(s)
            let base = baselines[key] ?? .empty
            let kinds = kinds(weightKg: w, reps: r, against: base)
            if !kinds.isEmpty { out[s.id] = kinds }
            baselines[key] = base.folding(weightKg: w, reps: r)
        }
        return out
    }
}

// MARK: - Progress of one exercise across sessions

public enum LiftProgress {
    /// One session's figures for one exercise.
    public struct Point: Equatable, Sendable {
        public let sessionId: String
        public let startTs: Int
        public let workingSets: Int
        public let reps: Int
        public let topWeightKg: Double?
        public let bestEstimatedOneRepMaxKg: Double?
        public let volumeKg: Double?
    }

    /// One point per session that has performed working sets of the exercise, oldest first.
    /// `sessionStart` maps a session id to its start (unix seconds); sets of unknown sessions are dropped.
    public static func series(_ sets: [LiftSetRow], sessionStart: [String: Int]) -> [Point] {
        let working = sets.filter { !$0.isWarmup && LiftMetrics.isPerformed(reps: $0.reps) }
        return Dictionary(grouping: working, by: \.sessionId).compactMap { id, rows -> Point? in
            guard let start = sessionStart[id] else { return nil }
            let e1rm = rows.compactMap { LiftMetrics.estimatedOneRepMaxKg(weightKg: $0.weightKg, reps: $0.reps) }.max()
            return Point(sessionId: id, startTs: start, workingSets: rows.count,
                         reps: rows.reduce(0) { $0 + max(0, $1.reps ?? 0) },
                         topWeightKg: rows.compactMap(\.weightKg).filter { $0 > 0 }.max(),
                         bestEstimatedOneRepMaxKg: e1rm,
                         volumeKg: LiftMetrics.volumeLoadKg(rows))
        }.sorted { ($0.startTs, $0.sessionId) < ($1.startTs, $1.sessionId) }
    }
}
