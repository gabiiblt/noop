import Foundation

// MARK: - Plate loading, bars and the weights a gym owns
//
// Ported from openGym's `frontend/src/lib/plates.js`, `bar.js` and the inventory helpers of `dumbbells.js`
// (Duarte Santos, MIT authorization to Gabriel Bolatoglu; see ATTRIBUTION.md). The expected values in
// `LiftPlatesOracleTests` were produced by running openGym's own functions under Node.
//
// Which plates go on for THIS weight, from the plates a gym owns. Logged weights stay the total on the bar
// (or the added load): everything here is display, never a change to what a set recorded.
//
// An inventory is kept in the gym's own unit, because a 45 lb plate is a 45 lb plate: a unit switch does not
// turn it into a 20.4 kg one. A gym with no inventory of its own gets the standard set for its unit, which is a
// rack rather than a home gym (six pairs of each usual size).

public enum LiftPlateUnit: String, Codable, CaseIterable, Sendable {
    case kg
    case lb
}

/// How many PAIRS of one plate size a gym owns.
public struct LiftPlateStock: Equatable, Codable, Sendable {
    public var size: Double
    public var pairs: Int

    public init(size: Double, pairs: Int) {
        self.size = size
        self.pairs = pairs
    }
}

/// How an exercise is loaded: plates split over two sides of a bar, one stack, or no plates at all.
public enum LiftLoadKind: String, Codable, Sendable {
    /// A bar or a two-post machine: what is beyond the bar splits per side.
    case pairs
    /// One stack (a dip belt, a landmine, a plate-loaded machine, a sled): all of it beyond the base weight.
    case single
    /// Dumbbells, cables, pin machines, bands.
    case none
}

/// The loading line for one set.
public struct LiftRowLoad: Equatable, Sendable {
    public var kind: LiftLoadKind
    /// The weight is at or below the bar: nothing to add.
    public var barOnly: Bool
    /// Below the bar itself, which usually means the log counts the plates without the bar.
    public var underBar: Bool
    public var bar: Double?
    /// What goes on each side (a pair), or the whole stack for a single load.
    public var perSide: Double
    /// The plates for that load, heaviest first.
    public var plates: [Double]
    /// What the inventory cannot make up. Zero is an exact load.
    public var missing: Double
}

public enum LiftPlates {

    // MARK: Constants

    /// The plate sizes an inventory editor lists, heaviest first. The kg list has the change plates of gyms that
    /// stock whole and half kilos, and the lb list the fractional ones.
    public static func sizes(_ unit: LiftPlateUnit) -> [Double] {
        switch unit {
        case .kg: return [25, 20, 15, 10, 5, 2.5, 2, 1.5, 1.25, 1, 0.5]
        case .lb: return [45, 35, 25, 15, 10, 5, 2.5, 1.25, 1, 0.5]
        }
    }

    /// Sizes a gym without an inventory of its own is assumed NOT to have.
    static func uncommon(_ unit: LiftPlateUnit) -> Set<Double> {
        switch unit {
        case .kg: return [2, 1.5, 1, 0.5]
        case .lb: return [15, 1.25, 1, 0.5]
        }
    }

    /// Pairs of each size the default inventory holds: plenty, the way a rack is.
    public static let defaultPairs = 6

    /// Equipment that puts a bar in the hands, and a bar's usual weight per unit.
    public static let barEquipment: Set<String> = ["barbell", "olympic barbell", "ez barbell", "smith machine", "trap bar"]
    public static let barTypes = ["barbell", "olympic barbell", "ez barbell", "trap bar", "smith machine"]

    public static func defaultBar(_ equipment: String, unit: LiftPlateUnit) -> Double? {
        let kg: [String: Double] = ["barbell": 20, "olympic barbell": 20, "ez barbell": 10, "smith machine": 9, "trap bar": 25]
        let lb: [String: Double] = ["barbell": 45, "olympic barbell": 45, "ez barbell": 25, "smith machine": 20, "trap bar": 55]
        return (unit == .lb ? lb : kg)[equipment]
    }

    /// Quick picks for a bar's weight: the bars gyms actually rack (15 kg / 35 lb is the short one).
    public static func barPicks(_ unit: LiftPlateUnit) -> [Double] {
        unit == .lb ? [45, 35, 25, 15] : [20, 15, 10, 7.5]
    }

    /// Whether this equipment word puts a bar in the hands.
    public static func usesBar(_ equipment: String?) -> Bool {
        equipment.map(barEquipment.contains) ?? false
    }

    /// How an exercise with this equipment is loaded when the person has not said: bar equipment loads pairs,
    /// a sled machine or a weighted exercise loads a single stack, the rest no plates.
    public static func loadKind(forEquipment equipment: String?) -> LiftLoadKind {
        guard let equipment else { return .none }
        if barEquipment.contains(equipment) { return .pairs }
        if equipment == "weighted" || equipment == "sled machine" { return .single }
        return .none
    }

    // MARK: Inventory

    /// The standard set for a unit: the usual sizes, six pairs of each, heaviest first.
    public static func defaultInventory(_ unit: LiftPlateUnit) -> [LiftPlateStock] {
        sizes(unit).filter { !uncommon(unit).contains($0) }.map { LiftPlateStock(size: $0, pairs: defaultPairs) }
    }

    /// A stored inventory as the loader reads it: sizes with at least one pair, heaviest first. An inventory
    /// with no usable size reads as the standard set again.
    public static func inventory(_ own: [LiftPlateStock], unit: LiftPlateUnit) -> [LiftPlateStock] {
        let usable = own.filter { $0.size > 0 && $0.pairs > 0 }
        guard !own.isEmpty else { return defaultInventory(unit) }
        return usable.sorted { $0.size > $1.size }
    }

    /// Whether a size is one a plate can be: positive, under 100, on the quarter grid the loader counts in.
    public static func isPlateSize(_ w: Double) -> Bool {
        w > 0 && w < 100 && abs(w * q - jsRound(w * q)) < 1e-9
    }

    // MARK: Arithmetic

    // Everything is done in quarter-units so 1.25 and 2.5 stay exact integers.
    private static let q = 4.0

    /// openGym's `Math.round` rounds halves up, which `Double.rounded()` does not for negatives.
    static func jsRound(_ x: Double) -> Double {
        let f = x.rounded(.down)
        return (x - f) >= 0.5 ? f + 1 : f
    }

    private static func quarters(_ w: Double) -> Int { Int(jsRound(w * q)) }

    // MARK: Stack

    /// Plates for `weight`, from `inventory` (heaviest first). Heaviest-first greedy when that lands exactly,
    /// the way a bar is loaded in practice. When greedy misses (a home gym with one pair of each size, an odd
    /// inventory) the fewest plates that hit the weight exactly, biased to heavier plates on ties. When nothing
    /// hits it, the closest load BELOW and what is missing.
    public static func plateStack(_ weight: Double, inventory inv: [LiftPlateStock]) -> (plates: [Double], missing: Double) {
        let requested = max(0, weight.isFinite ? weight : 0)
        let target = Int((requested * q).rounded(.down))
        if target == 0 { return ([], requested) }
        // A size under an eighth of a unit is under the quarter grid the loader counts in: it cannot be placed.
        let items = inv.filter { $0.size > 0 && $0.pairs > 0 && quarters($0.size) > 0 }.sorted { $0.size > $1.size }

        // 1. greedy
        var greedy: [Double] = []
        var left = target
        for p in items {
            let unit = quarters(p.size)
            var k = min(p.pairs, unit > 0 ? left / unit : 0)
            while k > 0 { greedy.append(p.size); left -= unit; k -= 1 }
        }
        // At or beyond everything owned, greedy has put every plate on and the rest is missing. The search
        // below would only find that again, with a table as long as the target.
        let all = items.reduce(0) { $0 + quarters($1.size) * $1.pairs }
        if left == 0 || target >= all { return (greedy, requested - Double(target - left) / q) }

        // 2. exact fit with the fewest plates: f[i][s] = min plates using sizes i... to make s
        let n = items.count
        let inf = 1_000_000_000
        var f = Array(repeating: Array(repeating: inf, count: target + 1), count: n + 1)
        f[n][0] = 0
        var i = n - 1
        while i >= 0 {
            let unit = quarters(items[i].size)
            let cap = items[i].pairs
            for s in 0...target {
                var best = f[i + 1][s]
                var k = 1
                while k <= cap && k * unit <= s {
                    let v = f[i + 1][s - k * unit]
                    if v + k < best { best = v + k }
                    k += 1
                }
                f[i][s] = best
            }
            i -= 1
        }
        // The heaviest reachable sum at or below the target (the target itself when it fits).
        var sum = target
        while sum > 0 && f[0][sum] >= inf { sum -= 1 }
        var plates: [Double] = []
        var s = sum
        for idx in 0..<n {
            let unit = quarters(items[idx].size)
            let cap = items[idx].pairs
            // Largest k that still leaves an optimal remainder: heavier plates on ties.
            var k = min(cap, s / unit)
            while k >= 0 {
                if f[idx + 1][s - k * unit] + k == f[idx][s] {
                    for _ in 0..<k { plates.append(items[idx].size) }
                    s -= k * unit
                    break
                }
                k -= 1
            }
        }
        return (plates, requested - Double(sum) / q)
    }

    /// Going from one stack to the next: what comes off and what goes on (multiset difference), each heaviest first.
    public static func plateDelta(from prev: [Double], to next: [Double]) -> (strip: [Double], add: [Double]) {
        func count(_ a: [Double]) -> [Double: Int] { a.reduce(into: [:]) { $0[$1, default: 0] += 1 } }
        let a = count(prev), b = count(next)
        var strip: [Double] = [], add: [Double] = []
        for (w, n) in a { for _ in 0..<max(0, n - (b[w] ?? 0)) { strip.append(w) } }
        for (w, n) in b { for _ in 0..<max(0, n - (a[w] ?? 0)) { add.append(w) } }
        return (strip.sorted(by: >), add.sorted(by: >))
    }

    /// The load line for one set: nil when there is nothing to load (kind none, no weight); bar-only when the
    /// weight is at or below the base; otherwise the stack for the per-side (pairs) or total (single) load plus
    /// what is missing from the inventory.
    public static func rowLoad(kind: LiftLoadKind, weight: Double, base: Double,
                               inventory inv: [LiftPlateStock]) -> LiftRowLoad? {
        guard kind == .pairs || kind == .single else { return nil }
        let w = weight.isFinite ? weight : 0
        guard w > 0 else { return nil }
        let b = max(0, base.isFinite ? base : 0)
        // Under the bar is not "bar only": a weight no bar this heavy can show.
        if w <= b {
            return LiftRowLoad(kind: kind, barOnly: true, underBar: w < b, bar: w < b ? b : nil,
                               perSide: 0, plates: [], missing: 0)
        }
        let perSide = jsRound(((w - b) / (kind == .pairs ? 2 : 1)) * 100) / 100
        // The inventory counts pairs. A bar takes one plate of a pair per side; a single stack can take both,
        // so one pair of 20s is two 20s on a sled, not one.
        let stock = kind == .single ? inv.map { LiftPlateStock(size: $0.size, pairs: $0.pairs * 2) } : inv
        let (plates, missing) = plateStack(perSide, inventory: stock)
        return LiftRowLoad(kind: kind, barOnly: false, underBar: false, bar: nil,
                           perSide: perSide, plates: plates, missing: missing)
    }

    // MARK: Owned weights (dumbbells, a machine's stack)

    private static let eps = 1e-6

    /// Sorted, de-duplicated, positive weights out of anything list-shaped.
    public static func cleanWeights(_ list: [Double]) -> [Double] {
        func tidy(_ w: Double) -> Double { jsRound(w * 1000) / 1000 }
        let kept = list.filter { $0.isFinite && $0 > 0 && $0 < 10000 }.map(tidy)
        return Array(Set(kept)).sorted()
    }

    /// The heaviest owned weight at or under `x`; the lightest one when `x` is under them all.
    public static func ownedFloor(_ ws: [Double], _ x: Double) -> Double {
        let under = ws.filter { $0 <= x + eps }
        return under.last ?? ws.first ?? 0
    }

    /// The `n`th owned weight above `w`, or the heaviest above it when fewer; nil at the top.
    public static func ownedUp(_ ws: [Double], _ w: Double, _ n: Int = 1) -> Double? {
        let above = ws.filter { $0 > w + eps }
        guard !above.isEmpty else { return nil }
        return above[min(max(n, 1), above.count) - 1]
    }

    /// The owned weight nearest a deload target, below `w`; `w` itself when nothing is lighter.
    public static func ownedDeload(_ ws: [Double], _ w: Double, factor: Double) -> Double {
        let below = ws.filter { $0 < w - eps }
        guard var best = below.first else { return w }
        let ideal = w * factor
        for x in below.dropFirst() {
            let dx = abs(x - ideal), db = abs(best - ideal)
            if dx < db - eps || (dx <= db + eps && x > best) { best = x }
        }
        return best
    }

    /// The owned weights either side of `ideal`, within `max` (and strictly under it when `strict`).
    public static func ownedAround(_ ideal: Double, _ ws: [Double], max cap: Double, strict: Bool) -> [Double] {
        guard ideal > 0, cap > 0 else { return [] }
        let ok = ws.filter { $0 > 0 && $0 <= cap + 1e-9 && (!strict || $0 < cap - 1e-9) }
        let low = ok.last { $0 <= ideal + eps }
        let high = ok.first { $0 >= ideal - eps }
        var out: [Double] = []
        for v in [low, high].compactMap({ $0 }) where !out.contains(v) { out.append(v) }
        return out.sorted()
    }

    /// The nearest weight a gym can actually make for `target`: the closest owned weight, preferring the lower
    /// one on a tie. Nil for an empty list.
    public static func nearestOwned(_ ws: [Double], to target: Double) -> Double? {
        guard let first = ws.first else { return nil }
        return ws.reduce(first) { best, x in
            let dx = abs(x - target), db = abs(best - target)
            return dx < db - eps ? x : best
        }
    }
}
