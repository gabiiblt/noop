import Foundation
import WhoopStore

// MARK: - A gym's equipment, applied to one set
//
// `LiftPlates` is the maths; this is the seam that reads a stored gym (`LiftGymRow`) and answers the question a
// lifter asks at the rack: what do I put on the bar for this weight, here? Pure: no database, no screen.
//
// Weights are stored in kilograms and an inventory in the gym's own unit, so a kilogram weight is converted to
// the gym's unit first and the answer is given in it. A 45 lb plate is a 45 lb plate: it is never converted.
//
// The plate maths follows openGym's (Duarte Santos, MIT authorization to Gabriel Bolatoglu; see ATTRIBUTION.md).

public struct LiftGymLoad: Equatable, Sendable {
    public var unit: LiftPlateUnit
    /// The weight asked for, in the gym's unit.
    public var requested: Double
    /// What the bar (or the base) weighs, in the gym's unit.
    public var base: Double
    public var load: LiftRowLoad

    /// The weight this gym can actually make, in its unit: the base plus what the plates add up to. Equal to
    /// `requested` when nothing is missing.
    public var achievable: Double {
        let per = load.kind == .pairs ? 2.0 : 1.0
        return base + per * max(0, load.perSide - load.missing)
    }
}

public enum LiftGymLoading {

    public static let poundsPerKilogram = 2.2046226218

    public static func unit(of gym: LiftGymRow) -> LiftPlateUnit {
        LiftPlateUnit(rawValue: gym.unit) ?? .kg
    }

    /// The plates a gym can load, heaviest first. A gym that listed none has the standard set for its unit.
    public static func inventory(of gym: LiftGymRow) -> [LiftPlateStock] {
        LiftPlates.inventory(gym.plates.map { LiftPlateStock(size: $0.size, pairs: $0.pairs) }, unit: unit(of: gym))
    }

    /// The bar for an equipment type at this gym: its own weight when the gym set one, else the built-in bar.
    public static func bar(of gym: LiftGymRow, equipment: String) -> Double? {
        gym.bars[equipment] ?? LiftPlates.defaultBar(equipment, unit: unit(of: gym))
    }

    /// Kilograms to the gym's unit, to two decimals so a typed 60 kg reads as 132.28 lb, not 132.277...
    public static func toGymUnit(kg: Double, _ unit: LiftPlateUnit) -> Double {
        unit == .lb ? LiftPlates.jsRound(kg * poundsPerKilogram * 100) / 100 : kg
    }

    public static func toKilograms(_ value: Double, _ unit: LiftPlateUnit) -> Double {
        unit == .lb ? value / poundsPerKilogram : value
    }

    /// What goes on for `weightKg` at this gym, for an exercise with this equipment word; nil when nothing loads
    /// (dumbbells, cables, bands, no weight).
    public static func load(gym: LiftGymRow, equipment: String?, weightKg: Double) -> LiftGymLoad? {
        let kind = LiftPlates.loadKind(forEquipment: equipment)
        guard kind != .none, weightKg > 0 else { return nil }
        let u = unit(of: gym)
        let requested = toGymUnit(kg: weightKg, u)
        let base = kind == .pairs ? (equipment.flatMap { bar(of: gym, equipment: $0) } ?? 0) : 0
        guard let load = LiftPlates.rowLoad(kind: kind, weight: requested, base: base, inventory: inventory(of: gym)) else {
            return nil
        }
        return LiftGymLoad(unit: u, requested: requested, base: base, load: load)
    }

    /// The same, for a weight typed in the gym's own unit (the calculator's field): nil when nothing loads.
    public static func load(gym: LiftGymRow, equipment: String?, weight: Double) -> LiftGymLoad? {
        load(gym: gym, equipment: equipment, weightKg: toKilograms(weight, unit(of: gym)))
    }

    /// The dumbbell or stack weight this gym can make nearest to `weightKg`, in the gym's unit; nil when it lists
    /// no dumbbells.
    public static func nearestDumbbell(gym: LiftGymRow, weightKg: Double) -> Double? {
        LiftPlates.nearestOwned(gym.dumbbells, to: toGymUnit(kg: weightKg, unit(of: gym)))
    }

    /// A machine's own stack for an exercise, in the gym's unit.
    public static func stack(of gym: LiftGymRow, exercise: String) -> [Double] {
        gym.stacks[exercise] ?? []
    }
}
