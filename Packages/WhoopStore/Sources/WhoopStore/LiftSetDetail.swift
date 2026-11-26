import Foundation

// MARK: - What a set was, beyond weight x reps (v49)
//
// The set model follows openGym's (Duarte Santos, MIT authorization to Gabriel Bolatoglu; see
// ATTRIBUTION.md): a drop set and a rest-pause set are still ONE row, with their extra parts riding on
// it, so every reader that only knows weight and reps (volume, history, the export) stays correct.
//   • A drop set's parts are ADDITIONAL work after the main set: their volume is added on top.
//   • A rest-pause set's `reps` is already the TOTAL across every burst: its parts are only how that
//     total breaks down, and adding them again would count the same reps twice.

/// The shape of a set. Stored as text in `liftSet.setType`; NULL reads as `.straight`.
public enum LiftSetType: String, CaseIterable, Codable, Sendable {
    case straight
    case dropset
    case restpause

    /// The stored value: NULL for a straight set, so rows from before v49 and new straight sets agree.
    var storedValue: String? { self == .straight ? nil : rawValue }

    init(stored: String?) {
        self = stored.flatMap(LiftSetType.init(rawValue:)) ?? .straight
    }
}

/// Which limb a per-side set was done with. NULL means both, or not tracked per side.
public enum LiftSide: String, CaseIterable, Codable, Sendable {
    case left
    case right
}

/// One extra part of a set: a weight drop of a drop set, or a burst of a rest-pause set.
public struct LiftSetPart: Equatable, Codable, Sendable {
    /// Kilograms. Nil on a rest-pause burst, which keeps the main set's weight.
    public var weightKg: Double?
    public var reps: Int
    /// Rest before this part, seconds (rest-pause bursts). Nil for drops, which are taken without rest.
    public var restSec: Int?

    public init(weightKg: Double?, reps: Int, restSec: Int? = nil) {
        self.weightKg = weightKg
        self.reps = reps
        self.restSec = restSec
    }

    /// The JSON stored in `liftSet.dropsJSON`: NULL for no parts, so an empty list never takes a column.
    static func encode(_ parts: [LiftSetPart]) -> String? {
        guard !parts.isEmpty, let data = try? JSONEncoder.sortedKeys.encode(parts) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Malformed or absent JSON reads as no parts: a set never fails to load because of its extras.
    static func decode(_ json: String?) -> [LiftSetPart] {
        guard let json, let data = json.data(using: .utf8),
              let parts = try? JSONDecoder().decode([LiftSetPart].self, from: data) else { return [] }
        return parts.filter { $0.reps >= 0 }
    }
}

extension JSONEncoder {
    /// Stable key order, so the same parts always store as the same text (exports compare equal).
    static var sortedKeys: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }
}
