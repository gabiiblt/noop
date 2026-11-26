import Foundation
import StrandAnalytics
import WhoopStore

// The sentence under a set that says what goes on the bar, and the one-line summary of a gym.
//
// Plates are shown in the gym's own unit (a 45 lb plate is a 45 lb plate), so a kilogram weight on a pound gym
// reads in pounds here. The plate maths follows openGym's (Duarte Santos, MIT authorization to Gabriel Bolatoglu;
// see ATTRIBUTION.md).

enum LiftGymCopy {

    static func unitLabel(_ unit: LiftPlateUnit) -> String { unit == .lb ? "lb" : "kg" }

    /// "20 + 5 + 1.25", heaviest first.
    static func plates(_ list: [Double]) -> String {
        list.map { LiftFormat.trim($0) }.joined(separator: " + ")
    }

    /// What goes on for one set at this gym, or nil when nothing is to be said (no plates for this equipment).
    static func line(_ load: LiftGymLoad) -> String {
        let unit = unitLabel(load.unit)
        let l = load.load
        if l.barOnly {
            if l.underBar, let bar = l.bar {
                return String(localized: "Under the \(LiftFormat.trim(bar)) \(unit) bar: the log may count the plates without the bar.")
            }
            return String(localized: "Bar only")
        }
        let stack = l.plates.isEmpty ? "—" : plates(l.plates)
        var out = l.kind == .pairs
            ? String(localized: "Per side: \(stack) \(unit)")
            : String(localized: "Plates: \(stack) \(unit)")
        if l.missing > 0 {
            out += " · " + String(localized: "short by \(LiftFormat.trim(l.missing)) \(unit)")
        }
        return out
    }

    /// "8 plate sizes · 2 bars · 6 dumbbells", or the standard-set note for a gym that listed nothing.
    static func summary(_ gym: LiftGymRow) -> String {
        var bits: [String] = []
        if gym.plates.isEmpty {
            bits.append(String(localized: "Standard plates"))
        } else {
            bits.append(String(localized: "\(gym.plates.count) plate sizes"))
        }
        if !gym.bars.isEmpty { bits.append(String(localized: "\(gym.bars.count) bars")) }
        if !gym.dumbbells.isEmpty { bits.append(String(localized: "\(gym.dumbbells.count) dumbbells")) }
        if !gym.stacks.isEmpty { bits.append(String(localized: "\(gym.stacks.count) machine stacks")) }
        return bits.joined(separator: " · ")
    }

    /// The name a bar type goes by on screen.
    static func barName(_ equipment: String) -> String {
        switch equipment {
        case "barbell": return String(localized: "Barbell")
        case "olympic barbell": return String(localized: "Olympic barbell")
        case "ez barbell": return String(localized: "EZ bar")
        case "trap bar": return String(localized: "Trap bar")
        case "smith machine": return String(localized: "Smith machine")
        case "sled machine": return String(localized: "Sled or plate-loaded machine")
        default: return equipment
        }
    }
}
