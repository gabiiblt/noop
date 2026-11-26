import Foundation
import WhoopStore

// MARK: - Muscle recovery: how fatigued each muscle is now, and how much strength it has kept
//
// Ported from openGym's `frontend/src/lib/recovery.js` (Duarte Santos, MIT authorization to Gabriel Bolatoglu; see
// ATTRIBUTION.md), with the two small helpers it leans on (`onerm.js`'s Epley estimate and `effort.js`'s `rirOf`).
// The expected values in `LiftRecoveryOracleTests` were produced by running openGym's own `fatigueOf` and
// `strengthOf` under Node.
//
// Fatigue is a stimulus that decays, not tonnage: hypertrophy dose-response tracks sets near failure, so each
// completed set counts by how close to failure it was (logged RIR first, an RIR estimated from the exercise's
// 90-day best second, full credit when unknowable), a muscle takes its share by how much the exercise works it, and
// the stimulus fades with a half-life of its own (24 h arms and small muscles, 30 h torso, 48 h legs and lower back).
// A session is scaled by how it compares with the weeks before it (a first session on a muscle counts more, a deload
// less), then the accumulated value is squashed with 1 - exp(-v) so more sets start higher but never pin.
//
// Retained strength is the other half: full for 14 days after a muscle last did a working set, then decaying toward
// a floor of 0.5 with a 28-day half-life, so a muscle left alone shows up as detrained.
//
// Not ported: the cardio and activity stimuli, per-side sets, and bodyweight load (a set's weight is the kilograms
// moved). Each can be added later against the same oracle.

/// One set as the recovery model reads it. Weights are kilograms.
public struct LiftRecoverySet: Equatable, Sendable {
    public struct Drop: Equatable, Sendable {
        public var weightKg: Double
        public var reps: Int
        public init(weightKg: Double, reps: Int) {
            self.weightKg = weightKg
            self.reps = reps
        }
    }

    public var weightKg: Double?
    public var reps: Int?
    public var done: Bool
    public var isWarmup: Bool
    /// Reps in reserve as logged, or nil.
    public var rir: Double?
    /// RPE as logged, or nil; read as 10 - RPE reps in reserve when no RIR was logged.
    public var rpe: Double?
    /// Taken to failure: reads as RIR 0 when nothing was rated.
    public var isFailure: Bool
    /// A drop set's drops. A rest-pause set's bursts are NOT extra work (its `reps` already totals them).
    public var drops: [Drop]

    public init(weightKg: Double?, reps: Int?, done: Bool = true, isWarmup: Bool = false, rir: Double? = nil,
                rpe: Double? = nil, isFailure: Bool = false, drops: [Drop] = []) {
        self.weightKg = weightKg
        self.reps = reps
        self.done = done
        self.isWarmup = isWarmup
        self.rir = rir
        self.rpe = rpe
        self.isFailure = isFailure
        self.drops = drops
    }
}

/// One exercise of one session: its sets and how it works each muscle (1 for a primary, less for a secondary).
public struct LiftRecoveryEntry: Equatable, Sendable {
    /// What the 90-day capacity anchor is keyed by: the exercise.
    public var exercise: String
    public var weights: [LiftMuscle: Double]
    /// An assistance machine's load is help received: it has no one-rep max and stays out of the anchor.
    public var isAssisted: Bool
    public var sets: [LiftRecoverySet]

    public init(exercise: String, weights: [LiftMuscle: Double], isAssisted: Bool = false, sets: [LiftRecoverySet]) {
        self.exercise = exercise
        self.weights = weights
        self.isAssisted = isAssisted
        self.sets = sets
    }
}

public struct LiftRecoverySession: Equatable, Sendable {
    /// Milliseconds since 1970.
    public var timestamp: Double
    public var entries: [LiftRecoveryEntry]

    public init(timestamp: Double, entries: [LiftRecoveryEntry]) {
        self.timestamp = timestamp
        self.entries = entries
    }
}

/// How ready a muscle is: below 0.25 ready, 0.25 through 0.5 recovering, above 0.5 fatigued.
public enum LiftFatigueState: String, Codable, Sendable {
    case ready
    case recovering
    case fatigued
}

public enum LiftRecovery {

    // MARK: Constants

    /// One full session on a muscle (about 8 hard sets, the per-session growth plateau) is 1.0 raw unit.
    public static let fatigueSetsPerUnit = 8.0
    /// Beyond about 10-12 sets the growth response plateaus, so extra volume must not extend the tail linearly.
    public static let fatigueMaxSetsPerSession = 12.0
    static let day = 86_400_000.0
    public static let fatigueScanMs = 30 * day
    static let rirWindowMs = 90 * day
    static let acuteWindowMs = 7 * day
    static let chronicWindowMs = 28 * day
    /// A far-from-failure set still moves blood and practises the lift: it costs no less than this.
    public static let rirFloorWeight = 0.3
    static let ratioMin = 0.5
    static let ratioMax = 2.0
    /// Prior weekly exposure for a muscle not trained in the chronic window: a first session scores amplified.
    static let noviceWeeklySets = 4.0
    /// At or below this reps in reserve a set drives adaptation.
    public static let hardRir = 3.0
    /// Above this many reps an estimate says more about work capacity than maximal strength.
    static let repCap = 12.0

    public static let strengthFullMs = 1_209_600_000.0
    public static let strengthHalfLifeMs = 2_419_200_000.0
    public static let strengthFloor = 0.5

    /// Exponential half-life of one muscle's fatigue stimulus. Lower body (heavier loads, more damage) recovers
    /// slower than upper body; small and core muscles share the fast 24 h lane.
    public static func halfLifeMs(_ muscle: LiftMuscle) -> Double {
        let h24 = 24.0 * 3_600_000, h30 = 30.0 * 3_600_000, h48 = 48.0 * 3_600_000
        switch muscle {
        case .frontDelts, .sideDelts, .rearDelts, .biceps, .triceps, .forearms, .abs, .obliques: return h24
        case .chest, .lats, .upperBack, .traps, .neck: return h30
        case .lowerBack, .glutes, .abductors, .quads, .hamstrings, .adductors, .calves: return h48
        }
    }

    static func halfLifeDecay(_ ageMs: Double, _ halfLifeMs: Double) -> Double { pow(0.5, ageMs / halfLifeMs) }

    // MARK: Effort

    /// A set's effort in RIR, or nil when it was never rated. 0 is a rating. A set taken to failure is RIR 0 by
    /// definition when nothing was rated; a rating typed by hand wins.
    static func rirOf(_ s: LiftRecoverySet) -> Double? {
        if let rir = s.rir { return rir }
        if let rpe = s.rpe { return 10 - rpe }
        return s.isFailure && !s.isWarmup ? 0 : nil
    }

    /// How much of a hard set a proximity-to-failure reading is worth, in [0.3, 1].
    public static func rirWeight(_ rir: Double?) -> Double {
        guard let rir else { return 1 }
        if rir <= hardRir { return 1 }
        if rir >= 6 { return rirFloorWeight }
        return 1 - (1 - rirFloorWeight) * (rir - hardRir) / (6 - hardRir)
    }

    static func jsRound(_ x: Double) -> Double {
        let f = x.rounded(.down)
        return (x - f) >= 0.5 ? f + 1 : f
    }

    /// Epley one-rep max to one decimal, or nil where it cannot honestly answer: no load, no reps, or more reps than
    /// the cap. A single rep is the measurement itself.
    static func estimate1RM(_ w: Double, _ r: Double) -> Double? {
        guard w.isFinite, r.isFinite, w > 0, r >= 1 else { return nil }
        if r == 1 { return jsRound(w * 10) / 10 }
        if r > repCap { return nil }
        let est = w * (1 + jsRound(r) / 30)
        guard est.isFinite, est > 0 else { return nil }
        return jsRound(est * 10) / 10
    }

    /// An estimated RIR from the exercise's recent best 1RM (Epley inverse), clamped to [0, 10]; nil without an
    /// anchor, a load, reps, or above the rep cap.
    static func estimateSetRir(weightKg w: Double, reps r: Double, anchorKg: Double) -> Double? {
        guard anchorKg > 0, w > 0, r >= 1, r <= repCap else { return nil }
        let maxReps = 30 * (anchorKg / w - 1)
        return min(10, max(0, maxReps - r))
    }

    // MARK: Anchors

    private struct Timed {
        var session: LiftRecoverySession
        var index: Int
        var timestamp: Double { session.timestamp }
    }

    private static func ordered(_ sessions: [LiftRecoverySession]) -> [Timed] {
        sessions.enumerated().map { Timed(session: $1, index: $0) }
            .filter { $0.timestamp.isFinite }
            .sorted { $0.timestamp != $1.timestamp ? $0.timestamp < $1.timestamp : $0.index < $1.index }
    }

    /// The best Epley estimate per exercise inside one session, in kg. A logged rating calibrates it: done plus left
    /// is the set's true rep capacity.
    private static func sessionBests(_ s: LiftRecoverySession) -> [String: Double] {
        var best: [String: Double] = [:]
        for entry in s.entries where !entry.isAssisted {
            for set in entry.sets where set.done {
                let reps = set.reps.map(Double.init)
                let logged = rirOf(set)
                let effective: Double? = reps != nil && logged != nil ? reps! + logged! : reps
                let load = max(0, set.weightKg ?? 0)
                guard let est = estimate1RM(load, effective ?? 0) else { continue }
                if best[entry.exercise] == nil || est > best[entry.exercise]! { best[entry.exercise] = est }
            }
        }
        return best
    }

    /// Per session (by its position in `ordered`), the 90-day rolling best 1RM estimate per exercise: one
    /// chronological pass, so a later session never leaks into an earlier anchor.
    private static func anchors(_ pool: [Timed]) -> [[String: Double]] {
        let bests = pool.map { sessionBests($0.session) }
        return pool.indices.map { i in
            var anchors: [String: Double] = [:]
            for j in 0...i where pool[j].timestamp > pool[i].timestamp - rirWindowMs {
                for (ex, est) in bests[j] where anchors[ex] == nil || est > anchors[ex]! { anchors[ex] = est }
            }
            return anchors
        }
    }

    // MARK: Stimulus

    /// One session's per-muscle stimulus in quality-weighted effective sets, capped per muscle.
    private static func effectiveSets(_ s: LiftRecoverySession, anchors: [String: Double]) -> [LiftMuscle: Double] {
        var sums: [LiftMuscle: Double] = [:]
        func score(weight: Double?, reps: Int?, logged: Double?, parent: LiftRecoverySet, entry: LiftRecoveryEntry) {
            // Logged effort first, an estimate against the anchor second.
            var rir: Double? = logged
            var source = logged != nil ? "logged" : ""
            if logged == nil, let anchor = anchors[entry.exercise], anchor > 0,
               let r = reps, let est = estimateSetRir(weightKg: max(0, weight ?? 0), reps: Double(r), anchorKg: anchor) {
                rir = est
                source = "estimated"
            }
            // A warm-up with no logged effort is far from failure by definition.
            let count = source != "logged" && parent.isWarmup ? rirFloorWeight : rirWeight(rir)
            for (muscle, w) in entry.weights { sums[muscle, default: 0] += count * 1 * w }
        }
        for entry in s.entries {
            for set in entry.sets {
                if set.done { score(weight: set.weightKg, reps: set.reps, logged: rirOf(set), parent: set, entry: entry) }
                // Drops are extra work at a discount, never double-counted; performed as part of a done set.
                if set.done {
                    for drop in set.drops { score(weight: drop.weightKg, reps: drop.reps, logged: nil, parent: set, entry: entry) }
                }
            }
        }
        return sums.mapValues { min($0, fatigueMaxSetsPerSession) }
    }

    private struct Event {
        var timestamp: Double
        var stimulus: Double
    }

    private static func stimuli(_ sessions: [LiftRecoverySession], now: Double) -> [LiftMuscle: [Event]] {
        let scanCutoff = now - fatigueScanMs
        let poolCutoff = now - (fatigueScanMs + rirWindowMs)
        let pool = ordered(sessions.filter { $0.timestamp.isFinite && $0.timestamp > poolCutoff })
        let byWorkout = anchors(pool)
        let eff = pool.indices.map { effectiveSets(pool[$0].session, anchors: byWorkout[$0]) }
        var byMuscle: [LiftMuscle: [Event]] = [:]
        for i in pool.indices where pool[i].timestamp > scanCutoff {
            var acute: [LiftMuscle: Double] = [:], chronic: [LiftMuscle: Double] = [:]
            for j in 0...i {
                let age = pool[i].timestamp - pool[j].timestamp
                if age < 0 || age > chronicWindowMs { continue }
                for muscle in LiftMuscle.allCases {
                    let v = eff[j][muscle] ?? 0
                    if age <= acuteWindowMs { acute[muscle, default: 0] += v }
                    chronic[muscle, default: 0] += v
                }
            }
            for muscle in LiftMuscle.allCases {
                let stimulus = eff[i][muscle] ?? 0
                guard stimulus > 0 else { continue }
                let gain = min(ratioMax, max(ratioMin,
                    ((acute[muscle] ?? 0) + noviceWeeklySets) / ((chronic[muscle] ?? 0) / 4 + noviceWeeklySets)))
                byMuscle[muscle, default: []].append(
                    Event(timestamp: pool[i].timestamp, stimulus: stimulus / fatigueSetsPerUnit * gain))
            }
        }
        return byMuscle
    }

    private static func fatigueValue(_ events: [Event], now: Double, muscle: LiftMuscle) -> Double {
        guard !events.isEmpty else { return 0 }
        let halfLife = halfLifeMs(muscle)
        let sorted = events.enumerated().sorted {
            $0.element.timestamp != $1.element.timestamp ? $0.element.timestamp < $1.element.timestamp : $0.offset < $1.offset
        }.map(\.element)
        var value = 0.0
        var last = sorted[0].timestamp
        for e in sorted {
            value *= halfLifeDecay(e.timestamp - last, halfLife)
            value += e.stimulus
            last = e.timestamp
        }
        value *= halfLifeDecay(max(0, now - last), halfLife)
        // Saturating: more sets start higher but never pin, and the value fades with no window-edge cliff.
        return 1 - exp(-value)
    }

    // MARK: Public

    /// Current fatigue per muscle in [0, 1), from the completed sets of the last 30 days (earlier sessions only
    /// inform the 90-day anchors). Every muscle is present.
    public static func fatigue(_ sessions: [LiftRecoverySession], now: Double) -> [LiftMuscle: Double] {
        var out = Dictionary(uniqueKeysWithValues: LiftMuscle.allCases.map { ($0, 0.0) })
        guard now.isFinite else { return out }
        let byMuscle = stimuli(sessions, now: now)
        for muscle in LiftMuscle.allCases { out[muscle] = fatigueValue(byMuscle[muscle] ?? [], now: now, muscle: muscle) }
        return out
    }

    /// Retained strength per muscle: 1 for 14 days after its last working set, then decaying toward 0.5; a muscle
    /// that never did a working set sits at the floor. Every muscle is present.
    public static func strength(_ sessions: [LiftRecoverySession], now: Double) -> [LiftMuscle: Double] {
        var out = Dictionary(uniqueKeysWithValues: LiftMuscle.allCases.map { ($0, strengthFloor) })
        guard now.isFinite else { return out }
        var latest: [LiftMuscle: Double] = [:]
        for s in sessions where s.timestamp.isFinite {
            for entry in s.entries where entry.sets.contains(where: { $0.done && !$0.isWarmup }) {
                for muscle in entry.weights.keys where s.timestamp > (latest[muscle] ?? -.infinity) {
                    latest[muscle] = s.timestamp
                }
            }
        }
        for muscle in LiftMuscle.allCases {
            guard let last = latest[muscle] else { continue }
            let age = now - last
            out[muscle] = age <= strengthFullMs ? 1 : max(strengthFloor, halfLifeDecay(age - strengthFullMs, strengthHalfLifeMs))
        }
        return out
    }

    /// The bucket a fatigue value falls in.
    public static func state(_ fatigue: Double) -> LiftFatigueState {
        fatigue > 0.5 ? .fatigued : (fatigue >= 0.25 ? .recovering : .ready)
    }

    /// Muscles above the fatigued threshold, in the muscle list's order.
    public static func fatigued(_ sessions: [LiftRecoverySession], now: Double) -> [LiftMuscle] {
        let f = fatigue(sessions, now: now)
        return LiftMuscle.allCases.filter { (f[$0] ?? 0) > 0.5 }
    }

    /// Muscles whose retained strength is below full retention, never-trained ones included at the floor.
    public static func detrained(_ sessions: [LiftRecoverySession], now: Double) -> [LiftMuscle] {
        let s = strength(sessions, now: now)
        return LiftMuscle.allCases.filter { (s[$0] ?? 1) < 1 }
    }
}
