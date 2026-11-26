import Foundation

// MARK: - Automatic progression (linear, double, triple, time) with the reason for every target
//
// Ported from openGym's `frontend/src/lib/progression.js` (Duarte Santos, MIT authorization to
// Gabriel Bolatoglu; see ATTRIBUTION.md), together with the two small helpers it leans on
// (`rep-range.js`'s `normalizeRepRange`, and `repStep`). The expected values in
// `LiftProgressionOracleTests` were produced by running openGym's own functions under Node.
//
// Everything here is a pure function of the finished sessions of ONE exercise. Nothing is written
// back into a session: the log is what happened, and the next target is derived from it every time it
// is needed, so changing a rule or fixing a mistyped set immediately gives the right next target, with
// no stored counter to drift. Every target carries the reason it was picked (`LiftProgressionWhy`),
// because a suggestion that cannot be audited is one the lifter stops trusting.
//
// Reading a session honestly is the whole game:
//   - a set checked off with at least its target reps  -> hit
//   - a set checked off with fewer reps                -> miss (what was logged is what was got)
//   - a set never checked off                          -> miss
//   - fewer sets than prescribed                       -> miss
// so a session that fell apart can never advance the load as though it had succeeded.
//
// Not ported (and absent from the rule list on purpose): Greyskull, steady, undulating, density and
// skill ladders; owned-dumbbell and machine-stack grids; assistance machines; per-gym splits; back-off
// sets; pyramids. Each can be added later against the same oracle.

// MARK: Rule

/// The rule that drives a lift's next target. `off` keeps the targets where the lifter set them.
public enum LiftProgressionPolicy: String, CaseIterable, Codable, Sendable {
    case off
    case linear
    case double
    case triple
    case time

    /// Which rules can drive which logging mode (openGym's `POLICIES_FOR`).
    public static func allowed(for mode: LiftProgressionMode) -> [LiftProgressionPolicy] {
        switch mode {
        case .reps: return [.off, .linear, .double, .triple]
        case .time: return [.off, .time]
        }
    }
}

public enum LiftProgressionMode: String, Codable, Sendable {
    case reps
    case time
}

public enum LiftProgressionKind: String, Codable, Sendable {
    /// Nothing logged yet: this session sets the baseline.
    case first
    case up
    case hold
    case deload
    case off
}

// MARK: Reason

/// Why a target is what it is. A case per openGym template, so a screen localises each one with its
/// own string instead of assembling English. Weights are kilograms; the screen converts at the edge.
public enum LiftProgressionWhy: Equatable, Codable, Sendable {
    case baseline
    case planChanged
    case timeUp(byS: Int)
    case timeDeload(stalls: Int, sec: Int)
    case timeHold
    case bodyweightHold
    case bodyweightAddSet(goal: Int, bottom: Int)
    case bodyweightMaxSets(sets: Int, goal: Int)
    case bodyweightUp(next: Int)
    case noWeightLogged
    case tripleDeload(stalls: Int, weightKg: Double, setsMin: Int, bottom: Int)
    case tripleHoldBeatenReps
    case tripleHoldMissed(toGo: Int, of: Int)
    case tripleAimEverySet(aim: Int)
    case tripleAimLastSet(aim: Int)
    case tripleAddSet(top: Int, bottom: Int)
    case tripleUp(sets: Int, byKg: Double, setsMin: Int, bottom: Int)
    case doubleUp(byKg: Double, bottom: Int)
    case doubleDeloadEpleyHold(stalls: Int, weightKg: Double, reps: Int)
    case doubleDeloadEpley(stalls: Int, weightKg: Double, reps: Int)
    case doubleDeload(stalls: Int, weightKg: Double)
    case doubleHold(aim: Int)
    case linearUp(byKg: Double)
    case linearDeload(stalls: Int, weightKg: Double)
    case linearDeloadOnce(weightKg: Double)
    case linearHold(toGo: Int, of: Int)

    /// Stable identifier, used by the oracle comparison and as a localisation key suffix.
    public var id: String {
        switch self {
        case .baseline: return "baseline"
        case .planChanged: return "planChanged"
        case .timeUp: return "timeUp"
        case .timeDeload: return "timeDeload"
        case .timeHold: return "timeHold"
        case .bodyweightHold: return "bodyweightHold"
        case .bodyweightAddSet: return "bodyweightAddSet"
        case .bodyweightMaxSets: return "bodyweightMaxSets"
        case .bodyweightUp: return "bodyweightUp"
        case .noWeightLogged: return "noWeightLogged"
        case .tripleDeload: return "tripleDeload"
        case .tripleHoldBeatenReps: return "tripleHoldBeatenReps"
        case .tripleHoldMissed: return "tripleHoldMissed"
        case .tripleAimEverySet: return "tripleAimEverySet"
        case .tripleAimLastSet: return "tripleAimLastSet"
        case .tripleAddSet: return "tripleAddSet"
        case .tripleUp: return "tripleUp"
        case .doubleUp: return "doubleUp"
        case .doubleDeloadEpleyHold: return "doubleDeloadEpleyHold"
        case .doubleDeloadEpley: return "doubleDeloadEpley"
        case .doubleDeload: return "doubleDeload"
        case .doubleHold: return "doubleHold"
        case .linearUp: return "linearUp"
        case .linearDeload: return "linearDeload"
        case .linearDeloadOnce: return "linearDeloadOnce"
        case .linearHold: return "linearHold"
        }
    }

    /// The numbers carried by the reason, in the order openGym's template uses them.
    public var args: [Double] {
        switch self {
        case .baseline, .planChanged, .timeHold, .bodyweightHold, .noWeightLogged, .tripleHoldBeatenReps:
            return []
        case .timeUp(let s): return [Double(s)]
        case .timeDeload(let a, let b): return [Double(a), Double(b)]
        case .bodyweightAddSet(let a, let b): return [Double(a), Double(b)]
        case .bodyweightMaxSets(let a, let b): return [Double(a), Double(b)]
        case .bodyweightUp(let a): return [Double(a)]
        case .tripleDeload(let s, let w, let m, let b): return [Double(s), w, Double(m), Double(b)]
        case .tripleHoldMissed(let a, let b): return [Double(a), Double(b)]
        case .tripleAimEverySet(let a), .tripleAimLastSet(let a), .doubleHold(let a): return [Double(a)]
        case .tripleAddSet(let a, let b): return [Double(a), Double(b)]
        case .tripleUp(let n, let by, let m, let b): return [Double(n), by, Double(m), Double(b)]
        case .doubleUp(let by, let b): return [by, Double(b)]
        case .doubleDeloadEpleyHold(let s, let w, let r), .doubleDeloadEpley(let s, let w, let r):
            return [Double(s), w, Double(r)]
        case .doubleDeload(let s, let w), .linearDeload(let s, let w): return [Double(s), w]
        case .linearUp(let by): return [by]
        case .linearDeloadOnce(let w): return [w]
        case .linearHold(let a, let b): return [Double(a), Double(b)]
        }
    }
}

// MARK: Inputs

/// One logged set. Warm-up rows are left out by the caller: they are prep, not the session.
public struct LiftProgressionSet: Equatable, Sendable {
    public var weightKg: Double
    public var reps: Int
    public var seconds: Int
    public var done: Bool

    public init(weightKg: Double, reps: Int, seconds: Int = 0, done: Bool = true) {
        self.weightKg = weightKg
        self.reps = reps
        self.seconds = seconds
        self.done = done
    }
}

/// What a session was asked for. Stamped on the session when it was built; a session without one is
/// judged against the lift's current plan (`LiftProgressionConfig`).
public struct LiftProgressionTarget: Equatable, Sendable {
    public var sets: Int?
    public var reps: Int?
    public var repsMin: Int?
    public var sec: Int?
    public var weightKg: Double?
    public var setsMax: Int?
    /// Triple progression's per-set aim: "12, 12, 12, 9" is one session's plan.
    public var rowReps: [Int]?
    /// Done one side at a time. Read from the TARGET, as openGym does: a timed per-side hold doubles its
    /// rows (one left, one right), and the session was built with that in mind.
    public var perSide: Bool

    public init(sets: Int? = nil, reps: Int? = nil, repsMin: Int? = nil, sec: Int? = nil,
                weightKg: Double? = nil, setsMax: Int? = nil, rowReps: [Int]? = nil, perSide: Bool = false) {
        self.sets = sets
        self.reps = reps
        self.repsMin = repsMin
        self.sec = sec
        self.weightKg = weightKg
        self.setsMax = setsMax
        self.rowReps = rowReps
        self.perSide = perSide
    }
}

/// The plan a session was built from (openGym's `plannedOf`): the only way the next session can tell a
/// plan that was edited from one that progressed.
public struct LiftProgressionPlan: Equatable, Sendable {
    public var sets: Int
    public var reps: Int?
    public var repsMin: Int?
    public var sec: Int?
    public var setsMax: Int?
    public var weightKg: Double?

    public init(sets: Int, reps: Int? = nil, repsMin: Int? = nil, sec: Int? = nil,
                setsMax: Int? = nil, weightKg: Double? = nil) {
        self.sets = sets
        self.reps = reps
        self.repsMin = repsMin
        self.sec = sec
        self.setsMax = setsMax
        self.weightKg = weightKg
    }

    /// Everything but the weight: a weight that moved is progress, not an edited plan.
    func samePlan(as other: LiftProgressionPlan) -> Bool {
        sets == other.sets && reps == other.reps && repsMin == other.repsMin
            && sec == other.sec && setsMax == other.setsMax
    }
}

/// One finished session of one exercise.
public struct LiftProgressionSession: Equatable, Sendable {
    public var mode: LiftProgressionMode
    /// Working sets only, in the order they were done.
    public var sets: [LiftProgressionSet]
    public var target: LiftProgressionTarget?
    public var planned: LiftProgressionPlan?
    /// Rehab or a merged block that must not become the baseline for the next target.
    public var excluded: Bool

    public init(mode: LiftProgressionMode = .reps, sets: [LiftProgressionSet],
                target: LiftProgressionTarget? = nil, planned: LiftProgressionPlan? = nil,
                excluded: Bool = false) {
        self.mode = mode
        self.sets = sets
        self.target = target
        self.planned = planned
        self.excluded = excluded
    }
}

/// A lift's plan and rule.
public struct LiftProgressionConfig: Equatable, Sendable {
    public var policy: LiftProgressionPolicy
    public var mode: LiftProgressionMode
    public var sets: Int
    public var reps: Int?
    public var repsMin: Int?
    /// Triple progression's ceiling on sets.
    public var setsMax: Int?
    public var sec: Int?
    public var weightKg: Double?
    /// The load step in kilograms (or seconds for a hold).
    public var incKg: Double
    public var perSide: Bool
    /// Work with no load of its own: it climbs in reps, then sets, instead of weight.
    public var bodyweight: Bool
    /// A bodyweight ceiling: past it the reps go back down and a set is added.
    public var repsMax: Int?
    /// How far a deload backs off, 0.5...0.95. Nil is the default 0.9.
    public var deloadFactor: Double?

    public init(policy: LiftProgressionPolicy, mode: LiftProgressionMode = .reps, sets: Int = 1,
                reps: Int? = nil, repsMin: Int? = nil, setsMax: Int? = nil, sec: Int? = nil,
                weightKg: Double? = nil, incKg: Double = 2.5, perSide: Bool = false,
                bodyweight: Bool = false, repsMax: Int? = nil, deloadFactor: Double? = nil) {
        self.policy = policy
        self.mode = mode
        self.sets = sets
        self.reps = reps
        self.repsMin = repsMin
        self.setsMax = setsMax
        self.sec = sec
        self.weightKg = weightKg
        self.incKg = incKg
        self.perSide = perSide
        self.bodyweight = bodyweight
        self.repsMax = repsMax
        self.deloadFactor = deloadFactor
    }
}

// MARK: Output

/// The next prescription. A field the rule has no opinion on is nil and the caller keeps what the plan said.
public struct LiftPrescription: Equatable, Sendable {
    public var policy: LiftProgressionPolicy
    public var kind: LiftProgressionKind
    public var weightKg: Double?
    public var reps: Int?
    public var sets: Int?
    public var sec: Int?
    public var rowReps: [Int]?
    public var why: LiftProgressionWhy?
    /// A deload's estimated-max target and the factor it used.
    public var target1RM: Double?
    public var deloadFactor: Double?

    public init(policy: LiftProgressionPolicy, kind: LiftProgressionKind, weightKg: Double? = nil, reps: Int? = nil,
         sets: Int? = nil, sec: Int? = nil, rowReps: [Int]? = nil, why: LiftProgressionWhy? = nil,
         target1RM: Double? = nil, deloadFactor: Double? = nil) {
        self.policy = policy
        self.kind = kind
        self.weightKg = weightKg
        self.reps = reps
        self.sets = sets
        self.sec = sec
        self.rowReps = rowReps
        self.why = why
        self.target1RM = target1RM
        self.deloadFactor = deloadFactor
    }
}

// MARK: - Engine

public enum LiftProgression {

    // MARK: Constants

    public static let deloadFactorDefault = 0.9
    public static let deloadFactorMin = 0.5
    public static let deloadFactorMax = 0.95
    /// Sessions in a row that must miss before a deload (openGym's `DELOAD_AFTER`; 3 for every ported rule).
    public static let deloadAfter = 3
    public static let defaultSecIncrement = 5.0
    /// Where adding another set of push-ups stops being progress (issue #33 upstream).
    public static let maxBodyweightSets = 6
    public static let maxTripleSets = 10

    // MARK: JS-faithful arithmetic
    //
    // openGym's `Math.round` rounds halves UP (toward +infinity), which `Double.rounded()` does not for
    // negatives; and its helpers round to one decimal. Mirroring both keeps the numbers identical.

    static func jsRound(_ x: Double) -> Double {
        let f = x.rounded(.down)
        return (x - f) >= 0.5 ? f + 1 : f
    }

    static func round1(_ v: Double) -> Double { jsRound(v * 10) / 10 }

    /// The places a step needs: one at least, three at most.
    static func stepPlaces(_ step: Double) -> Int {
        let s = "\(step.isFinite ? step : 0)"
        guard let dot = s.firstIndex(of: "."), !s.lowercased().contains("e") else { return 1 }
        let decimals = s.distance(from: dot, to: s.endIndex) - 1
        return min(3, max(1, decimals))
    }

    static func roundToStep(_ v: Double, _ step: Double) -> Double {
        let p = pow(10.0, Double(stepPlaces(step)))
        return jsRound(v * p) / p + 0
    }

    /// Snap to a loadable multiple of the step.
    static func snapWeight(_ v: Double, _ step: Double) -> Double {
        guard step > 0 else { return round1(v) }
        return roundToStep(jsRound(v / step) * step, step)
    }

    /// Add `step` the way a stepper tap does: from a weight on the increment's grid the sum is snapped to
    /// it, from one off the grid the step is simply added.
    static func addStep(_ w: Double, _ step: Double, _ inc: Double) -> Double {
        let v = w
        let onGrid = inc > 0 && abs(v - jsRound(v / inc) * inc) <= min(0.1, inc / 4) + 1e-9
        let next = v + step
        let unit = abs(step) != 0 ? abs(step) : inc
        return max(0, onGrid ? snapWeight(next, inc) : roundToStep(next, unit))
    }

    /// Back off by a factor, landing on something loadable.
    static func deloadTo(_ cur: Double, _ step: Double, _ factor: Double = deloadFactorDefault) -> Double {
        var next = snapWeight(cur * factor, step)
        if next >= cur { next = snapWeight(cur - step, step) }
        return max(step, next)
    }

    // MARK: Estimated max

    public static func isValidDeloadFactor(_ v: Double?) -> Bool {
        guard let v, v.isFinite else { return false }
        return v >= deloadFactorMin && v <= deloadFactorMax
    }

    public static func deloadFactor(of cfg: LiftProgressionConfig) -> Double {
        isValidDeloadFactor(cfg.deloadFactor) ? cfg.deloadFactor! : deloadFactorDefault
    }

    /// Epley estimated one-rep max: weight x (1 + reps / 30), to one decimal. Nil for no load or no reps.
    public static func epley1RM(_ weight: Double, _ reps: Double) -> Double? {
        guard weight.isFinite, reps.isFinite, weight > 0, reps >= 1 else { return nil }
        let result = weight * (1 + reps / 30)
        return result.isFinite && result > 0 ? round1(result) : nil
    }

    /// The estimated max a deload aims at: the stalled session's, less `factor`. Per-side work passes the
    /// stored total and this halves it, so a total cannot inflate the estimate.
    public static func deloadTarget1RM(_ weight: Double, _ reps: Double, factor: Double = deloadFactorDefault,
                                       perSide: Bool = false) -> Double? {
        guard let base = epley1RM(weight, perSide ? reps / 2 : reps) else { return nil }
        let f = isValidDeloadFactor(factor) ? factor : deloadFactorDefault
        return round1(base * f)
    }

    // MARK: Rep range

    /// openGym's `normalizeRepRange`: `reps` is the upper bound and `repsMin` the lower, aligned to the
    /// stride (2 for per-side work), the lower always below the upper.
    public static func normalizeRepRange(reps: Int?, repsMin: Int?, stride: Int = 1) -> (reps: Int, repsMin: Int) {
        let step = stride > 0 ? stride : 1
        func positive(_ v: Int?, _ fallback: Int) -> Int { (v ?? 0) > 0 ? max(1, v!) : fallback }
        func align(_ v: Int) -> Int { max(step, Int((Double(v) / Double(step)).rounded(.up)) * step) }
        let upper = align(positive(reps, 10))
        let lower = align(positive(repsMin, max(1, upper - 2)))
        return lower >= upper ? (lower + step, lower) : (upper, lower)
    }

    static func repStep(_ cfg: LiftProgressionConfig) -> Int { cfg.perSide ? 2 : 1 }

    // MARK: Reading a session

    /// A session reduced to what a rule needs to judge it (openGym's `readSession`).
    struct Read: Equatable {
        var mode: LiftProgressionMode
        var target: LiftProgressionTarget
        var planned: LiftProgressionPlan?
        var goal: Int
        var reps: [Int]
        var held: [Int]
        var weight: Double
        var low: Int
        var ok: Bool
    }

    static func plannedOf(_ cfg: LiftProgressionConfig) -> LiftProgressionPlan {
        var plan = LiftProgressionPlan(sets: max(1, cfg.sets))
        if cfg.mode == .reps, let r = cfg.reps, r > 0 { plan.reps = r }
        if cfg.mode == .reps, let r = cfg.repsMin, r > 0 { plan.repsMin = r }
        if cfg.mode == .time, let s = cfg.sec, s > 0 { plan.sec = s }
        if cfg.mode == .reps, let m = cfg.setsMax, m > 0 { plan.setsMax = m }
        plan.weightKg = cfg.weightKg
        return plan
    }

    static func fallbackTarget(_ cfg: LiftProgressionConfig) -> LiftProgressionTarget {
        LiftProgressionTarget(sets: cfg.sets, reps: cfg.reps, repsMin: cfg.repsMin, sec: cfg.sec,
                              weightKg: cfg.weightKg, setsMax: cfg.setsMax, rowReps: nil, perSide: cfg.perSide)
    }

    static func read(_ session: LiftProgressionSession, fallback cfg: LiftProgressionConfig) -> Read {
        let stamped = session.target
        let target = stamped ?? fallbackTarget(cfg)
        let logged = session.sets
        let rowGoals: [Int]? = (session.mode == .reps && stamped?.rowReps?.isEmpty == false)
            ? stamped!.rowReps!.map { max(0, $0) } : nil
        let plannedRows: Int = rowGoals?.count ?? ((target.sets ?? 0) > 0 ? target.sets! : logged.count)
        let planned = session.mode == .time && target.perSide ? plannedRows * 2 : plannedRows
        let enough = logged.count >= planned
        // Only the sets the plan asked for decide what happens next: a bonus set moves nothing.
        let sets = stamped != nil ? Array(logged.prefix(max(1, planned))) : logged
        let done = sets.filter(\.done).map(\.weightKg)
        let weight = max(0, done.max() ?? 0)

        if session.mode == .time {
            let goal = target.sec ?? 0
            let held = sets.map { $0.done ? $0.seconds : 0 }
            return Read(mode: .time, target: target, planned: session.planned, goal: goal, reps: [],
                        held: held, weight: weight, low: 0,
                        ok: goal > 0 && enough && !held.isEmpty && held.allSatisfy { $0 >= goal })
        }
        let goal = rowGoals?.max() ?? (target.reps ?? 0)
        let reps = sets.map { $0.done ? $0.reps : 0 }
        let ok = goal > 0 && enough && !reps.isEmpty && reps.enumerated().allSatisfy { k, r in
            r >= (rowGoals.flatMap { k < $0.count ? $0[k] : nil } ?? goal)
        }
        return Read(mode: .reps, target: target, planned: session.planned, goal: goal, reps: reps, held: [],
                    weight: weight, low: reps.min() ?? 0, ok: ok)
    }

    /// Every past session, oldest first, that can be a baseline: same mode, not excluded, with at least
    /// one set actually done.
    static func reads(_ sessions: [LiftProgressionSession], cfg: LiftProgressionConfig) -> [Read] {
        sessions
            .filter { !$0.excluded && $0.mode == cfg.mode && $0.sets.contains(where: \.done) }
            .map { read($0, fallback: cfg) }
    }

    // MARK: Stalls

    private static func tripleRowsKey(_ r: Read) -> [Int]? { r.target.rowReps }

    /// The number triple progression is moving: the weakest base set while the base sets climb together,
    /// else the set added last.
    private static func tripleActive(_ s: Read) -> Int {
        guard let rows = s.target.rowReps, !rows.isEmpty else { return s.low }
        func rep(_ k: Int) -> Int { k < s.reps.count ? s.reps[k] : 0 }
        if rows.allSatisfy({ $0 == rows[0] }) { return rows.indices.map(rep).min() ?? 0 }
        return rep(rows.count - 1)
    }

    /// How many sessions in a row ended in a miss, counting back from the most recent. A change of weight,
    /// an edit of the plan, and (under double and triple) beating the best of the current run all end a streak.
    static func stallCount(_ sessions: [Read], policy: LiftProgressionPolicy) -> Int {
        var n = 0
        var i = sessions.count - 1
        while i >= 0 {
            defer { i -= 1 }
            if sessions[i].ok { break }
            if i < sessions.count - 1 && sessions[i].weight != sessions[i + 1].weight { break }
            if i < sessions.count - 1, let a = sessions[i].planned, let b = sessions[i + 1].planned, !a.samePlan(as: b) { break }
            if policy == .double {
                var run: [Int] = []
                var j = i - 1
                while j >= 0 && sessions[j].weight == sessions[i].weight { run.append(sessions[j].low); j -= 1 }
                if let best = run.max(), sessions[i].low > best { break }
            }
            if policy == .triple {
                var run: [Int] = []
                var j = i - 1
                while j >= 0 && sessions[j].weight == sessions[i].weight
                        && tripleRowsKey(sessions[j]) == tripleRowsKey(sessions[i]) {
                    run.append(tripleActive(sessions[j])); j -= 1
                }
                if let best = run.max(), tripleActive(sessions[i]) > best { break }
            }
            n += 1
        }
        return n
    }

    // MARK: Epley deload

    struct DeloadCandidate {
        var weight: Double
        var reps: Int
        var target1RM: Double
        var factor: Double
    }

    private static func positiveGridAround(_ ideal: Double, _ step: Double, _ maxWeight: Double,
                                           strictLower: Bool) -> [Double] {
        guard ideal > 0, step > 0, maxWeight > 0 else { return [] }
        let low = (ideal / step).rounded(.down) * step
        let high = (ideal / step).rounded(.up) * step
        var seen: [Double] = []
        for v in [low, high].map({ snapWeight($0, step) }) where !seen.contains(v) { seen.append(v) }
        return seen
            .filter { $0 > 0 && $0 <= maxWeight + 1e-9 && (!strictLower || $0 < maxWeight - 1e-9) }
            .sorted()
    }

    /// Pick a bounded load/reps pair for an Epley target. The search is lexicographic: hard constraints
    /// first, then closest estimated max, fewer rep changes, greater load.
    static func selectDeloadCandidate(currentWeight current: Double, targetWeight: Double, targetReps: Int,
                                      step: Double, factor: Double, reps: Int, repsMin: Int?,
                                      perSide: Bool) -> DeloadCandidate? {
        let stride = perSide ? 2 : 1
        let upper = max(stride, Int((Double(targetReps) / Double(stride)).rounded(.up)) * stride)
        let range = repsMin.map { normalizeRepRange(reps: reps, repsMin: $0, stride: stride) }
        let top = range.map { min($0.reps, max($0.repsMin, upper)) } ?? upper
        let bottom = range?.repsMin ?? top
        var repValues: [Int] = []
        var r = top
        while r >= bottom { repValues.append(r); r -= stride }
        guard let target1RM = deloadTarget1RM(targetWeight, Double(upper), factor: factor, perSide: perSide),
              current > 0, !repValues.isEmpty, step > 0 else { return nil }

        struct Cand { var weight: Double; var reps: Int; var error: Double; var repChange: Int }
        var candidates: [Cand] = []
        func half(_ r: Int) -> Double { perSide ? Double(r) / 2 : Double(r) }
        for candidateReps in repValues {
            let ideal = target1RM / (1 + half(candidateReps) / 30)
            let allowCurrent = repsMin != nil && candidateReps < upper
            var grid = positiveGridAround(ideal, step, current, strictLower: !allowCurrent)
            if allowCurrent && !grid.contains(current) { grid.append(current) }
            for w in grid {
                guard let epley = epley1RM(w, half(candidateReps)) else { continue }
                candidates.append(Cand(weight: w, reps: candidateReps, error: abs(epley - target1RM),
                                       repChange: abs(candidateReps - upper)))
            }
        }
        // A tiny lift may have no positive lower grid point: hold the load actually attempted.
        if candidates.isEmpty {
            for candidateReps in repValues {
                guard let epley = epley1RM(current, half(candidateReps)) else { continue }
                candidates.append(Cand(weight: current, reps: candidateReps, error: abs(epley - target1RM),
                                       repChange: abs(candidateReps - upper)))
            }
        }
        let best = candidates.min { a, b in
            if a.error != b.error { return a.error < b.error }
            if a.repChange != b.repChange { return a.repChange < b.repChange }
            if a.weight != b.weight { return a.weight > b.weight }
            return a.reps > b.reps
        }
        guard let best else { return nil }
        return DeloadCandidate(weight: best.weight, reps: best.reps, target1RM: target1RM,
                               factor: isValidDeloadFactor(factor) ? factor : deloadFactorDefault)
    }

    // MARK: - The next prescription

    /// The rule actually in force: the configured one if it fits the logging mode, else `off`.
    public static func effectivePolicy(_ cfg: LiftProgressionConfig) -> LiftProgressionPolicy {
        allowed(cfg.policy, cfg.mode) ? cfg.policy : .off
    }

    private static func allowed(_ p: LiftProgressionPolicy, _ m: LiftProgressionMode) -> Bool {
        LiftProgressionPolicy.allowed(for: m).contains(p)
    }

    /// The next prescription for one exercise, from its finished sessions (oldest first).
    public static func nextPrescription(config cfg: LiftProgressionConfig,
                                        sessions all: [LiftProgressionSession]) -> LiftPrescription {
        let policy = effectivePolicy(cfg)
        let mode = cfg.mode
        let inc = cfg.incKg
        if policy == .off { return LiftPrescription(policy: policy, kind: .off) }

        let sessions = reads(all, cfg: cfg)
        let last = sessions.last
        let triple = policy == .triple && mode == .reps
        let range3 = triple ? normalizeRepRange(reps: cfg.reps ?? 10, repsMin: cfg.repsMin, stride: repStep(cfg)) : nil
        let setsMin3 = max(1, cfg.sets)
        let setsMax3 = max(setsMin3, min(maxTripleSets, (cfg.setsMax ?? 0) > 0 ? cfg.setsMax! : setsMin3))
        func startRows(_ reps: Int) -> [Int] { Array(repeating: reps, count: setsMin3) }

        func p(_ kind: LiftProgressionKind, weight: Double? = nil, reps: Int? = nil, sets: Int? = nil,
               sec: Int? = nil, rowReps: [Int]? = nil, why: LiftProgressionWhy?) -> LiftPrescription {
            LiftPrescription(policy: policy, kind: kind, weightKg: weight, reps: reps, sets: sets, sec: sec,
                             rowReps: rowReps, why: why)
        }

        guard let last else {
            if triple, let r = range3 {
                return p(.first, reps: r.repsMin, sets: setsMin3, rowReps: startRows(r.repsMin), why: .baseline)
            }
            return p(.first, why: .baseline)
        }

        // Start again from the plan when the last session was built from a different one: its numbers
        // were judged against the old target and cannot say where the new one stands.
        if let planned = last.planned, !planned.samePlan(as: plannedOf(cfg)) {
            let why = LiftProgressionWhy.planChanged
            let newWeight: Double? = (cfg.weightKg ?? 0) > 0 && planned.weightKg != cfg.weightKg ? cfg.weightKg : nil
            if mode == .time {
                let sec = (cfg.sec ?? 0) > 0 ? cfg.sec : (last.goal > 0 ? last.goal : nil)
                return p(.hold, weight: newWeight, sec: sec, why: why)
            }
            if newWeight == nil && last.weight <= 0 && cfg.bodyweight {
                return p(.hold, weight: 0, reps: (cfg.reps ?? 0) > 0 ? cfg.reps : nil, why: why)
            }
            let held: Double? = newWeight ?? (last.weight > 0 ? last.weight : ((cfg.weightKg ?? 0) > 0 ? cfg.weightKg : nil))
            if triple, let r = range3 {
                let aim = newWeight != nil ? r.repsMin : min(r.reps, max(r.repsMin, last.low + repStep(cfg)))
                return p(.hold, weight: held, reps: aim, sets: setsMin3, rowReps: startRows(aim), why: why)
            }
            if policy == .double {
                let range = normalizeRepRange(reps: (cfg.reps ?? 0) > 0 ? cfg.reps : (last.goal > 0 ? last.goal : 10),
                                              repsMin: cfg.repsMin, stride: repStep(cfg))
                let aim = newWeight != nil ? range.repsMin : min(range.reps, max(range.repsMin, last.low + repStep(cfg)))
                return p(.hold, weight: held, reps: aim, why: why)
            }
            return p(.hold, weight: held, reps: (cfg.reps ?? 0) > 0 ? cfg.reps : nil, why: why)
        }

        let stalls = stallCount(sessions, policy: policy)
        let deloadAt = deloadAfter

        if mode == .time {
            let secInc = cfg.incKg > 0 ? cfg.incKg : defaultSecIncrement
            let goal = last.goal > 0 ? last.goal : (cfg.sec ?? 0)
            if last.ok {
                let sec = goal + Int(secInc)
                return p(.up, sec: sec, why: .timeUp(byS: Int(secInc)))
            }
            if stalls >= deloadAt {
                let sec = Int(deloadTo(Double(goal), 5))
                return p(.deload, sec: sec, why: .timeDeload(stalls: stalls, sec: sec))
            }
            return p(.hold, sec: last.goal > 0 ? last.goal : cfg.sec, why: .timeHold)
        }

        let w = last.weight
        // Bodyweight work carries no external load: progress in reps, then in sets.
        if w <= 0 && cfg.bodyweight {
            let goal = last.goal > 0 ? last.goal : (cfg.reps ?? 0)
            let planSets = max(1, cfg.sets)
            let reached = last.planned != nil ? max(planSets, last.target.sets ?? 0) : planSets
            let keep: Int? = reached > planSets ? reached : nil
            if !last.ok || goal <= 0 {
                return p(.hold, weight: 0, reps: goal > 0 ? goal : nil, sets: keep, why: .bodyweightHold)
            }
            let top = (cfg.repsMax ?? 0) > 0 ? cfg.repsMax! : 0
            if top > 0 && goal >= top {
                let sets = reached + 1
                let bottom = max(1, min((cfg.reps ?? 0) > 0 ? cfg.reps! : top, top))
                if sets <= maxBodyweightSets {
                    return p(.up, weight: 0, reps: bottom, sets: sets, why: .bodyweightAddSet(goal: goal, bottom: bottom))
                }
                return p(.hold, weight: 0, reps: goal, sets: keep, why: .bodyweightMaxSets(sets: sets - 1, goal: goal))
            }
            let next = goal + repStep(cfg)
            return p(.up, weight: 0, reps: next, sets: keep, why: .bodyweightUp(next: next))
        }
        // A loaded lift logged at 0 had its weight never typed in: it asks for the weight.
        if w <= 0 {
            return p(.hold, weight: (cfg.weightKg ?? 0) > 0 ? cfg.weightKg : nil, why: .noWeightLogged)
        }

        let deloadFactorValue = deloadFactor(of: cfg)
        func epleyDeload() -> LiftPrescription? {
            guard mode == .reps, policy == .linear || policy == .double, !cfg.bodyweight else { return nil }
            let tWeight = last.target.weightKg ?? cfg.weightKg
            let tReps = last.target.reps ?? cfg.reps
            let tRepsMin = last.target.repsMin ?? cfg.repsMin
            guard let tWeight, let tReps else { return nil }
            guard let c = selectDeloadCandidate(currentWeight: w, targetWeight: tWeight, targetReps: tReps,
                                                step: inc, factor: deloadFactorValue, reps: tReps,
                                                repsMin: policy == .double ? tRepsMin : nil,
                                                perSide: cfg.perSide) else { return nil }
            let held = c.weight >= w
            var out = p(.deload, weight: c.weight, reps: c.reps, sets: cfg.sets,
                        why: held ? .doubleDeloadEpleyHold(stalls: stalls, weightKg: c.weight, reps: c.reps)
                                  : .doubleDeloadEpley(stalls: stalls, weightKg: c.weight, reps: c.reps))
            out.target1RM = c.target1RM
            out.deloadFactor = c.factor
            return out
        }

        if triple, let range3 {
            let top = range3.reps
            let bottom = range3.repsMin
            let step = repStep(cfg)
            // The per-set aim the last session was asked for; a session from before triple has only a flat target.
            let rows: [Int]
            if let own = last.target.rowReps, !own.isEmpty {
                rows = own.map { max(0, $0) }
            } else {
                let n = min(setsMax3, max(setsMin3, last.target.sets ?? setsMin3))
                let reps = min(range3.reps, max(range3.repsMin, (last.target.reps ?? 0) > 0 ? last.target.reps! : (last.goal > 0 ? last.goal : range3.repsMin)))
                rows = Array(repeating: reps, count: n)
            }
            func out(_ kind: LiftProgressionKind, _ weight: Double, _ next: [Int], _ why: LiftProgressionWhy) -> LiftPrescription {
                p(kind, weight: weight, reps: next.first, sets: next.count, rowReps: next, why: why)
            }
            if stalls >= deloadAt {
                let target1RM = deloadTarget1RM(w, Double(rows.max() ?? 0), factor: deloadFactorValue, perSide: cfg.perSide)
                var dw: Double?
                if let t = target1RM {
                    let ideal = t / (1 + (cfg.perSide ? Double(bottom) / 2 : Double(bottom)) / 30)
                    let grid = positiveGridAround(ideal, inc, w, strictLower: true)
                    if !grid.isEmpty {
                        dw = grid.reduce(grid[0]) { abs($1 - ideal) < abs($0 - ideal) ? $1 : $0 }
                    }
                }
                let weight = dw ?? deloadTo(w, inc)
                return out(.deload, weight, startRows(bottom),
                           .tripleDeload(stalls: stalls, weightKg: weight, setsMin: setsMin3, bottom: bottom))
            }
            if !last.ok {
                return out(.hold, w, rows, stalls == 0 ? .tripleHoldBeatenReps
                           : .tripleHoldMissed(toGo: deloadAt - stalls, of: deloadAt))
            }
            let got = rows.enumerated().map { k, r in min(top, max(r, k < last.reps.count ? last.reps[k] : 0)) }
            func climb(_ v: Int) -> Int { min(top, max(bottom, v + step)) }
            let n = got.count
            let baseLow = got.prefix(min(n, setsMin3)).min() ?? 0
            if n <= setsMin3 && baseLow < top {
                let aim = climb(baseLow)
                return out(.hold, w, Array(repeating: aim, count: max(n, setsMin3)), .tripleAimEverySet(aim: aim))
            }
            let active = got[n - 1]
            if n > setsMin3 && active < top {
                let aim = climb(active)
                return out(.hold, w, Array(got.prefix(n - 1).map { _ in top }) + [aim], .tripleAimLastSet(aim: aim))
            }
            if n < setsMax3 {
                return out(.up, w, got.map { _ in top } + [bottom], .tripleAddSet(top: top, bottom: bottom))
            }
            let up = addStep(w, inc, inc)
            return out(.up, up, startRows(bottom),
                       .tripleUp(sets: n, byKg: inc, setsMin: setsMin3, bottom: bottom))
        }

        if policy == .double {
            let range = normalizeRepRange(reps: (cfg.reps ?? 0) > 0 ? cfg.reps : (last.goal > 0 ? last.goal : 10),
                                          repsMin: cfg.repsMin, stride: repStep(cfg))
            let top = range.reps
            let bottom = range.repsMin
            // Hitting a session's own target is compliance with that session, not "reached the top".
            if last.ok && last.low >= top {
                return p(.up, weight: addStep(w, inc, inc), reps: bottom, why: .doubleUp(byKg: inc, bottom: bottom))
            }
            if stalls >= deloadAt {
                if let selected = epleyDeload() { return selected }
                let dw = deloadTo(w, inc)
                return p(.deload, weight: dw, reps: bottom, why: .doubleDeload(stalls: stalls, weightKg: dw))
            }
            let aim = min(top, max(bottom, last.low + repStep(cfg)))
            return p(.hold, weight: w, reps: aim, why: .doubleHold(aim: aim))
        }

        // Linear.
        if last.ok {
            return p(.up, weight: addStep(w, inc, inc), why: .linearUp(byKg: inc))
        }
        if stalls >= deloadAt {
            if let selected = epleyDeload() { return selected }
            let dw = deloadTo(w, inc)
            return p(.deload, weight: dw, why: stalls > 1 ? .linearDeload(stalls: stalls, weightKg: dw)
                                                          : .linearDeloadOnce(weightKg: dw))
        }
        return p(.hold, weight: w, why: .linearHold(toGo: deloadAt - stalls, of: deloadAt))
    }
}
