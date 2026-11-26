import Foundation

// MARK: - Strength balance: how one lift stands against another, and against body weight
//
// Ported from openGym's `frontend/src/lib/structuralBalance.js` (Duarte Santos, MIT authorization to Gabriel
// Bolatoglu; see ATTRIBUTION.md), with its tables (`LiftBalanceTemplates.swift`, generated from openGym's
// `structuralBalanceTemplates.js`). The expected values in `LiftBalanceOracleTests` were produced by running openGym's
// own `computeBalance` under Node over 76 histories and all three tables.
//
// A table gives each lift a ROLE: an anchor lift (the squat, the close-grip bench), other lifts as a percentage of an
// anchor's estimated one-rep max (Poliquin, Thibaudeau), lifts as a percentage of body weight for a number of reps
// (ATG: "Romanian deadlift, body weight for 12"), and rep counts at body weight (pull-ups, dips). A lift is Balanced
// when it reaches its ratio, Borderline within five points below it, Weak under that, and has No data until the sets
// to score it exist.
//
// THESE ARE REFERENCE RATIOS FROM COACHING LITERATURE, never a norm for anyone: a lifter whose anchor is weak scores
// every other lift as strong, and a ratio below a table's says which lift trails the others in THIS person's log, not
// that anything is wrong. The screen says so.
//
// Reading rules worth knowing: a one-rep max is Epley, capped at 12 reps (no guessing from a set of 20); a lift on the
// lifter (a dip, a pull-up, a belt movement) is the body mass plus the load, so it needs a weigh-in; an assistance
// machine's load is help received and comes OFF the body mass; a bench dip stays out of the belt rule; warm-ups and
// sets never performed are ignored.

public enum LiftBalanceMode: String, Codable, Sendable {
    case loadRatio
    case bodyweightRatio
    case repCount
}

public enum LiftBalanceStatus: String, Codable, Sendable {
    case balanced
    case borderline
    case weak
    case noData = "no-data"
}

public struct LiftBalanceRole: Equatable, Sendable {
    public var id: String
    /// openGym's English label, which is also its localisation key.
    public var label: String
    public var mode: LiftBalanceMode
    /// Catalogue ids, the preferred variant first: the role reads the best across them.
    public var exerciseIds: [String]
    /// Load-ratio roles: the role this one is held against, in the same table. Nil for an anchor.
    public var anchorRoleId: String?
    /// Percent of the anchor's one-rep max, or of body weight; for a rep count, the rep target.
    public var targetPct: Double?
    public var targetPctFemale: Double?
    /// Body-weight roles: the reps the table's load is for.
    public var reps: Int?
    public var repsTarget: Int?
    public var repsTargetFemale: Int?
}

public struct LiftBalanceTemplate: Equatable, Sendable {
    public var id: String
    public var label: String
    public var roles: [LiftBalanceRole]
}

/// What the bundled catalogue says about an exercise: its name and equipment word.
public struct LiftBalanceExercise: Equatable, Sendable {
    public var name: String
    public var equipment: String

    public init(name: String, equipment: String) {
        self.name = name
        self.equipment = equipment
    }
}

public struct LiftBalanceSet: Equatable, Sendable {
    public var weightKg: Double
    public var reps: Int
    public var done: Bool
    public var isWarmup: Bool

    public init(weightKg: Double, reps: Int, done: Bool = true, isWarmup: Bool = false) {
        self.weightKg = weightKg
        self.reps = reps
        self.done = done
        self.isWarmup = isWarmup
    }
}

/// One exercise in one session. `onLifter` overrides the catalogue rule (does the weight add to the lifter's own mass).
public struct LiftBalanceEntry: Equatable, Sendable {
    public var exerciseId: String
    public var sets: [LiftBalanceSet]
    public var onLifter: Bool?

    public init(exerciseId: String, sets: [LiftBalanceSet], onLifter: Bool? = nil) {
        self.exerciseId = exerciseId
        self.sets = sets
        self.onLifter = onLifter
    }
}

public struct LiftBalanceSession: Equatable, Sendable {
    /// Milliseconds since 1970, or any increasing stamp: it only names the reading's date.
    public var timestamp: Double
    /// The weigh-in stamped on this session, the honest figure for an old one.
    public var bodyweightKg: Double?
    public var entries: [LiftBalanceEntry]

    public init(timestamp: Double, bodyweightKg: Double? = nil, entries: [LiftBalanceEntry]) {
        self.timestamp = timestamp
        self.bodyweightKg = bodyweightKg
        self.entries = entries
    }
}

public struct LiftBalanceInput: Sendable {
    /// Oldest first.
    public var sessions: [LiftBalanceSession]
    /// The latest weigh-in, kilograms.
    public var bodyweightKg: Double?
    /// Picks the table's distinct female figures where it gives them.
    public var female: Bool
    /// A role's chosen exercise, keyed "<table>:<role>".
    public var overrides: [String: String]
    /// The catalogue rows the sets refer to, by id.
    public var exercises: [String: LiftBalanceExercise]

    public init(sessions: [LiftBalanceSession], bodyweightKg: Double?, female: Bool = false,
                overrides: [String: String] = [:], exercises: [String: LiftBalanceExercise]) {
        self.sessions = sessions
        self.bodyweightKg = bodyweightKg
        self.female = female
        self.overrides = overrides
        self.exercises = exercises
    }
}

/// The best reading a role found.
public struct LiftBalanceReading: Equatable, Sendable {
    /// The estimated one-rep max (load-ratio roles).
    public var estKg: Double?
    /// The load for the role's reps (body-weight roles with reps).
    public var repsKg: Double?
    /// The set's reps (rep-count roles, and the set behind a load reading).
    public var reps: Int?
    /// The weight logged on that set.
    public var weightKg: Double
    public var timestamp: Double
    public var exerciseId: String
}

public struct LiftBalanceResult: Equatable, Sendable {
    public var roleId: String
    /// The exercise the role is set to, whether or not it was ever logged.
    public var configuredExerciseId: String?
    public var targetPct: Double
    public var isOverridden: Bool
    public var mappedExerciseId: String?
    public var current: LiftBalanceReading?
    /// What the lift scored, in percent of its target's own scale; nil when it cannot be scored yet.
    public var actualPct: Double?
    public var status: LiftBalanceStatus
    /// No score only for want of a weigh-in, with sets logged.
    public var needsBodyweight: Bool
    /// Logged, but the anchor it is held against never was.
    public var needsAnchor: Bool
}

public enum LiftBalance {

    /// Points below a target that still count as Borderline.
    public static let borderlineBandPct = 5.0
    /// A reading taken from loads exactly at a ratio can come out a floating-point hair under it.
    static let edgeTolerancePct = 1e-9
    static let repCap = 12.0

    // MARK: Catalogue rules

    /// Equipment that is the lifter's own body (or a band standing in for it).
    static func isBodyweightEquipment(_ eq: String) -> Bool { ["body weight", "band", "resistance band"].contains(eq) }

    /// The catalogue's assistance machines: a leverage machine whose name says "assisted". The name alone is not
    /// enough (partner-assisted stretches say it too); the equipment is what separates the two.
    static func isAssisted(_ ex: LiftBalanceExercise?) -> Bool {
        guard let ex, ex.equipment == "leverage machine" else { return false }
        return ex.name.range(of: #"\bassist(ed)?\b"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static let benchDipIds: Set<String> = ["1755"]

    /// The belt-and-vest variants of the hanging and supported movements: 'weighted' equipment, yet what is logged is
    /// the plate on the belt, so the lifter's mass is added back. Bench dips and push-ups keep the feet down.
    static func beltOnLifter(_ id: String, _ ex: LiftBalanceExercise?) -> Bool {
        guard let ex, ex.equipment == "weighted" else { return false }
        let name = ex.name
        let mover = name.range(of: #"\b(pull[- ]?ups?|chin[- ]?ups?|muscle[- ]?ups?|dips?)\b"#, options: [.regularExpression, .caseInsensitive]) != nil
        let bench = name.range(of: #"\bbench"#, options: [.regularExpression, .caseInsensitive]) != nil
        return mover && !bench && !benchDipIds.contains(id)
    }

    static func onLifter(_ entry: LiftBalanceEntry, _ exercises: [String: LiftBalanceExercise]) -> Bool {
        if let flag = entry.onLifter { return flag }
        let ex = exercises[entry.exerciseId]
        return (ex.map { isBodyweightEquipment($0.equipment) } ?? false) || beltOnLifter(entry.exerciseId, ex)
    }

    // MARK: Arithmetic

    static func jsRound(_ x: Double) -> Double {
        let f = x.rounded(.down)
        return (x - f) >= 0.5 ? f + 1 : f
    }

    static func epley(_ w: Double, _ r: Double) -> Double { w * (1 + r / 30) }

    /// The load a one-rep max shows for `reps` reps (Epley the other way).
    static func loadForReps(_ oneRmKg: Double, _ reps: Double) -> Double { reps > 1 ? oneRmKg / (1 + reps / 30) : oneRmKg }

    /// A table's figure is a load for a number of reps, not a one-rep max. A set of at least that many reps proves its
    /// own load; a shorter one is carried over with Epley, up to the one-rep max and back down.
    static func loadAtReps(_ loadKg: Double, _ setReps: Int, _ reps: Int) -> Double? {
        guard loadKg.isFinite, loadKg > 0, setReps >= 1 else { return nil }
        if setReps >= reps { return loadKg }
        return loadForReps(setReps == 1 ? loadKg : epley(loadKg, Double(setReps)), Double(reps))
    }

    /// Epley's estimate without a display rounding: a load table only divides one estimate by another, and two rounded
    /// ones of loads exactly at a ratio land either side of it. The rep cap still decides what is an estimate.
    static func unrounded1RM(_ loadKg: Double, _ reps: Int) -> Double? {
        guard loadKg.isFinite, loadKg > 0, reps >= 1 else { return nil }
        if reps == 1 { return loadKg }
        guard Double(reps) <= repCap else { return nil }
        let est = epley(loadKg, jsRound(Double(reps)))
        return est.isFinite && est > 0 ? est : nil
    }

    // MARK: Reading the log

    /// What one performed set moved, in kg: the logged load, with the lifter's own mass added for a lift on the lifter
    /// and taken OFF for an assistance machine. Nil when it cannot be scored without inventing a body mass.
    static func setLoadKg(_ input: LiftBalanceInput, _ session: LiftBalanceSession, _ entry: LiftBalanceEntry,
                          _ set: LiftBalanceSet) -> Double? {
        let logged = set.weightKg
        let stamped = (session.bodyweightKg ?? 0) > 0 ? session.bodyweightKg : nil
        let body = stamped ?? input.bodyweightKg
        if isAssisted(input.exercises[entry.exerciseId]) {
            guard logged > 0, let body, body > 0 else { return nil }
            return body - logged > 0 ? body - logged : nil
        }
        if !onLifter(entry, input.exercises) { return logged }
        if let body, body > 0 { return body + logged }
        return nil
    }

    /// The best reading across a role's exercises: the estimated one-rep max, or with `reps` the load for that many.
    static func resolveCurrent(_ input: LiftBalanceInput, _ ids: [String], reps: Int?) -> LiftBalanceReading? {
        let byLoad = (reps ?? 0) > 1
        var best: LiftBalanceReading?
        for id in ids {
            for session in input.sessions {
                guard let entry = session.entries.first(where: { $0.exerciseId == id }) else { continue }
                for set in entry.sets where set.done && !set.isWarmup {
                    guard let loadKg = setLoadKg(input, session, entry, set) else { continue }
                    let kg: Double? = byLoad ? loadAtReps(loadKg, set.reps, reps!) : unrounded1RM(loadKg, set.reps)
                    guard let kg else { continue }
                    let current = byLoad ? best?.repsKg : best?.estKg
                    if best == nil || kg > (current ?? -.infinity) {
                        best = LiftBalanceReading(estKg: byLoad ? nil : kg, repsKg: byLoad ? kg : nil, reps: set.reps,
                                                  weightKg: set.weightKg, timestamp: session.timestamp, exerciseId: id)
                    }
                }
            }
        }
        return best
    }

    /// The best completed rep count across a role's exercises, ignoring load: a rep target is reps at body weight, so an
    /// assistance machine reads as no data rather than as a pass.
    static func resolveCurrentReps(_ input: LiftBalanceInput, _ ids: [String]) -> LiftBalanceReading? {
        var best: LiftBalanceReading?
        for id in ids {
            for session in input.sessions {
                guard let entry = session.entries.first(where: { $0.exerciseId == id }),
                      !isAssisted(input.exercises[entry.exerciseId]) else { continue }
                var found: (r: Int, w: Double)?
                for set in entry.sets where set.done && !set.isWarmup && set.reps >= 1 {
                    if found == nil || set.reps > found!.r { found = (set.reps, set.weightKg) }
                }
                if let f = found, best == nil || f.r > best!.reps! {
                    best = LiftBalanceReading(estKg: nil, repsKg: nil, reps: f.r, weightKg: f.w,
                                              timestamp: session.timestamp, exerciseId: id)
                }
            }
        }
        return best
    }

    // MARK: Targets and status

    static func target(_ role: LiftBalanceRole, female: Bool) -> Double {
        if role.mode == .repCount {
            let t = female && role.repsTargetFemale != nil ? role.repsTargetFemale : role.repsTarget
            return Double(t ?? 0)
        }
        return (female && role.targetPctFemale != nil ? role.targetPctFemale : role.targetPct) ?? 0
    }

    public static func overrideKey(_ template: LiftBalanceTemplate, _ role: LiftBalanceRole) -> String { "\(template.id):\(role.id)" }

    /// A choice of the role's own default exercise is the default: not "Custom".
    static func override(_ input: LiftBalanceInput, _ template: LiftBalanceTemplate, _ role: LiftBalanceRole) -> String? {
        guard let id = input.overrides[overrideKey(template, role)], !id.isEmpty, id != role.exerciseIds.first else { return nil }
        return id
    }

    static func exerciseIds(_ input: LiftBalanceInput, _ template: LiftBalanceTemplate, _ role: LiftBalanceRole) -> [String] {
        override(input, template, role).map { [$0] } ?? role.exerciseIds
    }

    public static func classify(_ actualPct: Double?, target: Double) -> LiftBalanceStatus {
        guard let a = actualPct, a.isFinite else { return .noData }
        if a >= target - edgeTolerancePct { return .balanced }
        if a >= target - borderlineBandPct - edgeTolerancePct { return .borderline }
        return .weak
    }

    /// Whether a role reads "No data" only for want of a weigh-in, with sets logged.
    static func waitsOnBodyweight(_ input: LiftBalanceInput, _ role: LiftBalanceRole, _ ids: [String],
                                  current: LiftBalanceReading?) -> Bool {
        if (input.bodyweightKg ?? 0) > 0 || role.mode == .repCount { return false }
        if current != nil { return role.mode == .bodyweightRatio }
        return input.sessions.contains { session in
            !((session.bodyweightKg ?? 0) > 0) && session.entries.contains { entry in
                guard ids.contains(entry.exerciseId) else { return false }
                let assisted = isAssisted(input.exercises[entry.exerciseId])
                guard assisted || onLifter(entry, input.exercises) else { return false }
                return entry.sets.contains { $0.done && !$0.isWarmup && (!assisted || $0.weightKg > 0) }
            }
        }
    }

    /// Every role of a table, scored against the log.
    public static func compute(_ template: LiftBalanceTemplate, _ input: LiftBalanceInput) -> [LiftBalanceResult] {
        var currentByRole: [String: LiftBalanceReading] = [:]
        for role in template.roles {
            let ids = exerciseIds(input, template, role)
            let current = role.mode == .repCount
                ? resolveCurrentReps(input, ids)
                : resolveCurrent(input, ids, reps: role.mode == .bodyweightRatio ? role.reps : nil)
            if let current { currentByRole[role.id] = current }
        }
        return template.roles.map { role in
            let current = currentByRole[role.id]
            let targetPct = target(role, female: input.female)
            let classifyTarget = role.mode == .repCount ? 100 : targetPct
            let override = override(input, template, role)
            let configured = override ?? role.exerciseIds.first
            let ids = exerciseIds(input, template, role)
            let needsBodyweight = waitsOnBodyweight(input, role, ids, current: current)
            guard let current else {
                return LiftBalanceResult(roleId: role.id, configuredExerciseId: configured, targetPct: targetPct,
                                         isOverridden: override != nil, mappedExerciseId: nil, current: nil, actualPct: nil,
                                         status: .noData, needsBodyweight: needsBodyweight, needsAnchor: false)
            }
            // An anchor role (no anchorRoleId) is compared against itself: always 100% when it has data.
            let anchorCurrent = role.anchorRoleId.map { currentByRole[$0] } ?? current
            let actual = ratio(role, current, anchorCurrent: anchorCurrent, bodyweightKg: input.bodyweightKg, target: targetPct)
            let needsAnchor = role.anchorRoleId != nil && role.mode == .loadRatio && !((anchorCurrent?.estKg ?? 0) > 0)
            return LiftBalanceResult(roleId: role.id, configuredExerciseId: configured, targetPct: targetPct,
                                     isOverridden: override != nil, mappedExerciseId: current.exerciseId, current: current,
                                     actualPct: actual, status: classify(actual, target: classifyTarget),
                                     needsBodyweight: needsBodyweight, needsAnchor: needsAnchor)
        }
    }

    static func ratio(_ role: LiftBalanceRole, _ current: LiftBalanceReading, anchorCurrent: LiftBalanceReading?,
                      bodyweightKg: Double?, target: Double) -> Double? {
        switch role.mode {
        case .loadRatio:
            guard let anchor = anchorCurrent?.estKg, anchor > 0, let est = current.estKg else { return nil }
            return est / anchor * 100
        case .bodyweightRatio:
            guard let bw = bodyweightKg, bw > 0 else { return nil }
            let kg = (role.reps ?? 0) > 1 ? current.repsKg : current.estKg
            guard let kg, kg > 0 else { return nil }
            return kg / bw * 100
        case .repCount:
            guard let r = current.reps else { return nil }
            return Double(r) / target * 100
        }
    }
}
