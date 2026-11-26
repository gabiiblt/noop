import Foundation
import StrandAnalytics
import WhoopStore

// The sentence a lifter reads under an exercise: why today's target is what it is.
//
// One localised string per case of `LiftProgressionWhy`, so each translates as a whole sentence instead of
// being assembled from English pieces. Weights arrive in kilograms and are shown in the person's unit.
// The wording follows openGym's templates (Duarte Santos, MIT authorization to Gabriel Bolatoglu; see
// ATTRIBUTION.md). Rules the screen cannot produce yet (bodyweight climbs, holds) return nil.

enum LiftProgressionCopy {

    static func text(_ why: LiftProgressionWhy, system: UnitSystem) -> String? {
        func w(_ kg: Double) -> String { LiftFormat.weight(kg, system: system) }
        switch why {
        case .baseline:
            return String(localized: "Nothing logged yet, so this session sets the baseline.")
        case .planChanged:
            return String(localized: "Plan changed, so starting from your new target.")
        case .noWeightLogged:
            return String(localized: "No weight logged last time. Enter what you lift and progression takes it from there.")
        case .tripleDeload(let stalls, let kg, let setsMin, let bottom):
            return String(localized: "Stuck for \(stalls) sessions. Deload to \(w(kg)) and start again at \(setsMin) sets of \(bottom).")
        case .tripleHoldBeatenReps:
            return String(localized: "Short of the target, but more reps than before. Same sets and reps again.")
        case .tripleHoldMissed(let toGo, let of):
            return String(localized: "Missed reps last time. Same sets and reps again (\(toGo) of \(of) to go).")
        case .tripleAimEverySet(let aim):
            return String(localized: "Same weight, aim for \(aim) reps in every set.")
        case .tripleAimLastSet(let aim):
            return String(localized: "Same weight, aim for \(aim) reps on the last set.")
        case .tripleAddSet(let top, let bottom):
            return String(localized: "\(top) reps in every set! Add a set at \(bottom) reps.")
        case .tripleUp(let sets, let by, let setsMin, let bottom):
            return String(localized: "Top of the range on all \(sets) sets. \(w(by)) more, back to \(setsMin) sets of \(bottom).")
        case .doubleUp(let by, let bottom):
            return String(localized: "Top of the rep range in every set. \(w(by)) more, back to \(bottom) reps.")
        case .doubleDeloadEpleyHold(let stalls, let kg, let reps):
            return String(localized: "Stuck for \(stalls) sessions. Hold \(w(kg)) and use \(reps) reps.")
        case .doubleDeloadEpley(let stalls, let kg, let reps):
            return String(localized: "Stuck for \(stalls) sessions. Deload to \(w(kg)) for \(reps) reps.")
        case .doubleDeload(let stalls, let kg):
            return String(localized: "Stuck for \(stalls) sessions. Deload to \(w(kg)).")
        case .doubleHold(let aim):
            return String(localized: "Same weight, aim for \(aim) reps this time.")
        case .linearUp(let by):
            return String(localized: "Every rep last time. \(w(by)) more.")
        case .linearDeload(let stalls, let kg):
            return String(localized: "Missed reps \(stalls) sessions running. Reset to \(w(kg)) and work back up.")
        case .linearDeloadOnce(let kg):
            return String(localized: "Missed reps. Reset to \(w(kg)) and work back up.")
        case .linearHold(let toGo, let of):
            return String(localized: "Missed reps last time. Same weight again (\(toGo) of \(of) to go).")
        case .timeUp, .timeDeload, .timeHold, .bodyweightHold, .bodyweightAddSet, .bodyweightMaxSets, .bodyweightUp:
            return nil
        }
    }

    /// The rule's name, for the editor and the line under the reason.
    static func name(_ rule: LiftProgressionPolicy) -> String {
        switch rule {
        case .off: return String(localized: "No automatic progression")
        case .linear: return String(localized: "Linear progression")
        case .double: return String(localized: "Double progression")
        case .triple: return String(localized: "Triple progression")
        case .time: return String(localized: "Add time")
        }
    }

    /// What the rule does, in one or two sentences, shown under the picker.
    static func summary(_ rule: LiftProgressionPolicy) -> String {
        switch rule {
        case .off:
            return String(localized: "Targets stay where you set them.")
        case .linear:
            return String(localized: "Hit every rep in every set and the weight goes up. Repeated misses trigger a deload.")
        case .double:
            return String(localized: "Work up through a rep range at the same weight. Reach the top of the range in every set and the weight goes up, reps back to the bottom.")
        case .triple:
            return String(localized: "Reps climb to the top of the range, then a set is added, up to your most sets. All of them at the top and the weight goes up, back to your first sets and reps.")
        case .time:
            return String(localized: "Hold every set for the full duration and the target goes up.")
        }
    }
}
