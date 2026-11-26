import Foundation
import WhoopStore

// The text a person types into the set-detail sheet, and the rules that turn it into a `LiftSetExtras`.
//
// Pure and free of SwiftUI so the parsing is testable without a screen. Fields hold plain text and are
// parsed once, on Done — the same rule `LiftSessionEditSheet` follows — so a field is never rewritten
// while it is being typed into (the bug that stored 45.5 kg as 455).
//
// The set model follows openGym's (Duarte Santos, MIT authorization to Gabriel Bolatoglu; see
// ATTRIBUTION.md).

struct LiftSetExtrasForm: Equatable {

    /// One drop or one rest-pause burst, as typed.
    struct PartForm: Equatable, Identifiable {
        let id: UUID
        /// In the user's display unit. Blank for a rest-pause burst, which keeps the main set's weight.
        var weightText: String
        var repsText: String
        /// Seconds rested before a rest-pause burst. Blank for a drop, which is taken without rest.
        var restText: String

        init(id: UUID = UUID(), weightText: String = "", repsText: String = "", restText: String = "") {
            self.id = id
            self.weightText = weightText
            self.repsText = repsText
            self.restText = restText
        }
    }

    var setType: LiftSetType
    var isFailure: Bool
    var side: LiftSide?
    var rirText: String
    /// Seconds, as typed.
    var durationText: String
    /// Metres, as typed.
    var distanceText: String
    var parts: [PartForm]

    /// A rest period offered to a new rest-pause burst, in seconds. Short and conventional; typed over
    /// freely, and never stored unless the burst is kept.
    static let defaultBurstRestSec = 15

    /// A blank form: a plain set.
    init() {
        self.init(LiftSetExtras(), system: .metric)
    }

    init(_ extras: LiftSetExtras, system: UnitSystem) {
        setType = extras.setType
        isFailure = extras.isFailure
        side = extras.side
        rirText = extras.rir.map { LiftFormat.trim($0) } ?? ""
        durationText = extras.durationSec.map(String.init) ?? ""
        distanceText = extras.distanceM.map { LiftFormat.trim($0) } ?? ""
        parts = extras.parts.map {
            PartForm(weightText: $0.weightKg.map { LiftFormat.trim(LiftFormat.display(fromKilograms: $0, system: system)) } ?? "",
                     repsText: String($0.reps),
                     restText: $0.restSec.map(String.init) ?? "")
        }
    }

    /// The stored value. Blank or unparseable text is "not given" rather than zero, a part with no reps
    /// is dropped, and everything passes through `LiftSetExtras.normalized()` last, so the shape's own
    /// rules (no parts on a straight set, no weight on a burst) hold whatever was typed.
    func extras(system: UnitSystem) -> LiftSetExtras {
        let converted: [LiftSetPart] = parts.compactMap { part in
            guard let reps = Int(part.repsText.trimmingCharacters(in: .whitespaces)), reps > 0 else { return nil }
            let weight = LiftFormat.number(part.weightText).map {
                LiftFormat.kilograms(fromDisplay: $0, system: system)
            }
            let rest = Int(part.restText.trimmingCharacters(in: .whitespaces))
            return LiftSetPart(weightKg: weight, reps: reps, restSec: rest)
        }
        return LiftSetExtras(
            setType: setType,
            parts: converted,
            isFailure: isFailure,
            rir: LiftFormat.number(rirText),
            side: side,
            durationSec: Int(durationText.trimmingCharacters(in: .whitespaces)),
            distanceM: LiftFormat.number(distanceText)
        ).normalized()
    }

    /// Change the shape. The parts typed for the old shape do not carry over — a drop's weight means
    /// nothing on a burst and the other way round — so a switch starts the list again, with one blank
    /// part ready for the two shapes that use them.
    mutating func switchType(to newType: LiftSetType) {
        guard newType != setType else { return }
        setType = newType
        parts = []
        if newType != .straight { addPart() }
    }

    /// Append a blank drop or burst. No-op on a straight set, and at the bound.
    mutating func addPart() {
        guard setType != .straight, parts.count < LiftSetExtras.maxParts else { return }
        parts.append(PartForm(restText: setType == .restpause ? String(Self.defaultBurstRestSec) : ""))
    }

    mutating func removePart(_ id: UUID) {
        parts.removeAll { $0.id == id }
    }
}
