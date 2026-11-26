import Foundation

// MARK: - The plan a session was built from (v50)
//
// Stamped on every set of an exercise in a session, AS IT WAS, the way the muscle classification is:
// editing the program later never rewrites what a past session was asked for. It is what lets the next
// target tell a plan that was EDITED (sets, rep range or set ceiling changed, so the old numbers say
// nothing about the new ones) from a plan that merely PROGRESSED (only the weight moved).
//
// The progression rules follow openGym's (Duarte Santos, MIT authorization to Gabriel Bolatoglu; see
// ATTRIBUTION.md): its `plannedOf` is the same stamp.

public struct LiftPlanStamp: Equatable, Codable, Sendable {
    /// The rule in force when the session was built ('linear', 'double', 'triple', 'time'), or nil for none.
    public var progression: String?
    /// Planned working sets.
    public var sets: Int
    /// The rep range, low and high ends.
    public var repsLow: Int?
    public var repsHigh: Int?
    /// Triple progression's ceiling on sets.
    public var setsMax: Int?
    /// The planned weight, kilograms.
    public var weightKg: Double?
    /// Planned seconds, for a timed hold.
    public var sec: Int?

    public init(progression: String? = nil, sets: Int, repsLow: Int? = nil, repsHigh: Int? = nil,
                setsMax: Int? = nil, weightKg: Double? = nil, sec: Int? = nil) {
        self.progression = progression
        self.sets = sets
        self.repsLow = repsLow
        self.repsHigh = repsHigh
        self.setsMax = setsMax
        self.weightKg = weightKg
        self.sec = sec
    }

    /// The JSON stored in `liftSet.planJSON`: NULL for no stamp, so a set with none takes no column.
    static func encode(_ stamp: LiftPlanStamp?) -> String? {
        guard let stamp, let data = try? JSONEncoder.sortedKeys.encode(stamp) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Malformed or absent JSON reads as no stamp: a set never fails to load because of it.
    static func decode(_ json: String?) -> LiftPlanStamp? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(LiftPlanStamp.self, from: data)
    }
}
