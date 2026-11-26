import Foundation

// MARK: - The set detail a live session carries beside weight, reps and RPE
//
// Everything `LiftSetRow` stores from v49 on (see `LiftSetDetail.swift`) that the logging screen edits:
// the set's shape, its drops or bursts, failure, reps in reserve, side, time and distance. Kept as ONE
// value so the session engine, its crash snapshot and the Save step each carry a single field instead of
// seven, and so the rules below live in one pure, testable place rather than in a view.
//
// The set model follows openGym's (Duarte Santos, MIT authorization to Gabriel Bolatoglu; see
// ATTRIBUTION.md).

public struct LiftSetExtras: Equatable, Codable, Sendable {
    public var setType: LiftSetType
    public var parts: [LiftSetPart]
    public var isFailure: Bool
    /// Reps in reserve. Nil when not rated.
    public var rir: Double?
    public var side: LiftSide?
    public var durationSec: Int?
    public var distanceM: Double?

    public init(setType: LiftSetType = .straight,
                parts: [LiftSetPart] = [],
                isFailure: Bool = false,
                rir: Double? = nil,
                side: LiftSide? = nil,
                durationSec: Int? = nil,
                distanceM: Double? = nil) {
        self.setType = setType
        self.parts = parts
        self.isFailure = isFailure
        self.rir = rir
        self.side = side
        self.durationSec = durationSec
        self.distanceM = distanceM
    }

    /// Nothing beyond a plain set. An empty value is never stored, so a straight set typed with only
    /// weight and reps writes exactly what it wrote before v49.
    public var isEmpty: Bool { self == LiftSetExtras() }

    /// The reps in reserve a lifter can rate: 0 (nothing left) to 10, in halves like the RPE field.
    public static let rirRange: ClosedRange<Double> = 0...10
    /// Bounds on a part list, against a stuck finger: every part is JSON on the row.
    public static let maxParts = 12

    /// The value as it is stored. A straight set carries no parts (matching `LiftSetRow.init`); a part
    /// with no reps is dropped, a negative figure is dropped, and an out-of-range RIR is clamped. A
    /// drop's weight stays; a rest-pause burst keeps no weight of its own (it shares the main set's), so
    /// one typed there is cleared rather than shown as if it counted.
    public func normalized() -> LiftSetExtras {
        var out = self
        switch setType {
        case .straight:
            out.parts = []
        case .dropset:
            out.parts = parts.prefix(Self.maxParts).filter { $0.reps > 0 }.map {
                LiftSetPart(weightKg: $0.weightKg.flatMap { $0 >= 0 ? $0 : nil }, reps: $0.reps, restSec: nil)
            }
        case .restpause:
            out.parts = parts.prefix(Self.maxParts).filter { $0.reps > 0 }.map {
                LiftSetPart(weightKg: nil, reps: $0.reps, restSec: $0.restSec.flatMap { $0 >= 0 ? $0 : nil })
            }
        }
        out.rir = rir.map { Swift.min(Swift.max($0, Self.rirRange.lowerBound), Self.rirRange.upperBound) }
        out.durationSec = durationSec.flatMap { $0 > 0 ? $0 : nil }
        out.distanceM = distanceM.flatMap { $0 > 0 ? $0 : nil }
        return out
    }

    /// For a rest-pause set, the reps its bursts add up to, which is what the set's `reps` should be:
    /// the bursts include the first one (6 + 6 is a set of 12, as `LiftSetRow.volumeKg` reads it). Nil
    /// for any other shape, or for a rest-pause set with no bursts yet. The screen offers it as the
    /// figure to type into Reps; it never overwrites a number typed there.
    public var restPauseTotal: Int? {
        guard setType == .restpause, !parts.isEmpty else { return nil }
        return parts.reduce(0) { $0 + max(0, $1.reps) }
    }
}
