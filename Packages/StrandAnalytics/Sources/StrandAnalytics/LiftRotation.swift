import Foundation
import WhoopStore

// MARK: - A rotation of sessions (A, B, C) instead of weekdays
//
// Some people train "the next session in the cycle" rather than "Monday's session": push, pull, legs, whenever they
// get to the gym, with the rest days they like between them. A rotation is an ordered list of programs, each with the
// days off that follow it, and what is up next follows from what was done last, with no calendar to fall behind.
//
// The idea follows openGym's rotation (Duarte Santos, MIT authorization to Gabriel Bolatoglu; see ATTRIBUTION.md): the
// sequence advances after a session of one of its programs, and a rest entry pushes the next session back a day per
// rest. NOOP keeps it simple: each program appears once, and its rest days are a number on the program rather than an
// entry in the list. openGym's rotation is tied to its reminder queue and calendar, which NOOP has none of, so this is
// a re-expression and is tested on its own rather than against openGym's code.
//
//   - The next program is the one after the program of the LAST session that belongs to the rotation. A session of a
//     program outside it does not move the rotation.
//   - It is due the day after that session plus the rest days that program carries. Before then the day is a rest day.
//   - A session of a different program in the rotation (done out of order) moves the rotation on from THAT one: the
//     rotation follows what was trained, it never insists on what was planned.
//   - With no session yet, the first program is due today.

public struct LiftRotationStep: Equatable, Sendable {
    public var programId: String
    public var name: String
    /// Days off after finishing this program before the next one is due.
    public var restDaysAfter: Int
}

public struct LiftRotationNext: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        /// Nothing trained in the rotation yet: the first program is due today.
        case notStarted
        /// Due today, or overdue by `days`.
        case due(overdueDays: Int)
        /// Not due yet: a rest day, with the program due on `day` (a local day number).
        case rest(dueDay: Int, daysLeft: Int)
    }

    public var step: LiftRotationStep
    /// The program that was done last, which the rotation follows from.
    public var after: LiftRotationStep?
    public var state: State

    /// Whether the program can be started now without breaking a rest.
    public var isDue: Bool {
        switch state {
        case .notStarted, .due: return true
        case .rest: return false
        }
    }
}

public enum LiftRotation {

    /// The rotation's programs in order. An archived program is out of it.
    public static func steps(_ programs: [LiftProgramRow]) -> [LiftRotationStep] {
        programs
            .filter { !$0.archived && $0.rotationOrd != nil }
            .sorted { ($0.rotationOrd ?? 0, $0.createdAt, $0.id) < ($1.rotationOrd ?? 0, $1.createdAt, $1.id) }
            .map { LiftRotationStep(programId: $0.id, name: $0.name, restDaysAfter: $0.restDaysAfter) }
    }

    /// A local day number: days since 1970 as the calendar in `timeZone` counts them.
    public static func localDay(_ ts: Int, timeZone: TimeZone = .current) -> Int {
        let local = ts + timeZone.secondsFromGMT(for: Date(timeIntervalSince1970: TimeInterval(ts)))
        return Int((Double(local) / 86_400).rounded(.down))
    }

    /// What is up next, or nil when the rotation is empty.
    public static func next(steps: [LiftRotationStep], sessions: [LiftSessionRow], today: Int,
                            dayOf: (Int) -> Int = { localDay($0) }) -> LiftRotationNext? {
        guard let first = steps.first else { return nil }
        let index = Dictionary(steps.enumerated().map { ($1.programId, $0) }, uniquingKeysWith: { a, _ in a })
        guard let last = sessions.filter({ $0.programId.flatMap { index[$0] } != nil }).max(by: { $0.startTs < $1.startTs }),
              let at = last.programId.flatMap({ index[$0] }) else {
            return LiftRotationNext(step: first, after: nil, state: .notStarted)
        }
        let done = steps[at]
        let upcoming = steps[(at + 1) % steps.count]
        let due = dayOf(last.startTs) + 1 + done.restDaysAfter
        let state: LiftRotationNext.State = today >= due
            ? .due(overdueDays: today - due)
            : .rest(dueDay: due, daysLeft: due - today)
        return LiftRotationNext(step: upcoming, after: done, state: state)
    }

    // MARK: Edits

    /// The rotation's places renumbered 0, 1, 2... in order, so a gap left by a removal never lingers.
    public static func normalized(_ programs: [LiftProgramRow]) -> [LiftProgramRow] {
        let order = steps(programs).map(\.programId)
        return programs.map { p in
            var out = p
            out.rotationOrd = order.firstIndex(of: p.id)
            if out.rotationOrd == nil { out.restDaysAfter = 0 }
            return out
        }
    }

    /// Put a program at the end of the rotation.
    public static func adding(_ programs: [LiftProgramRow], id: String) -> [LiftProgramRow] {
        guard let i = programs.firstIndex(where: { $0.id == id }), programs[i].rotationOrd == nil else { return programs }
        var out = programs
        out[i].rotationOrd = steps(programs).count
        return normalized(out)
    }

    /// Take a program out of the rotation.
    public static func removing(_ programs: [LiftProgramRow], id: String) -> [LiftProgramRow] {
        guard let i = programs.firstIndex(where: { $0.id == id }) else { return programs }
        var out = programs
        out[i].rotationOrd = nil
        out[i].restDaysAfter = 0
        return normalized(out)
    }

    /// Move a program one place earlier (`by` -1) or later (+1) in the rotation.
    public static func moved(_ programs: [LiftProgramRow], id: String, by offset: Int) -> [LiftProgramRow] {
        var order = steps(programs).map(\.programId)
        guard let at = order.firstIndex(of: id), order.indices.contains(at + offset) else { return programs }
        order.swapAt(at, at + offset)
        return programs.map { p in
            var out = p
            if let place = order.firstIndex(of: p.id) { out.rotationOrd = place }
            return out
        }
    }

    /// Set the days off after a program, bounded.
    public static func settingRest(_ programs: [LiftProgramRow], id: String, days: Int) -> [LiftProgramRow] {
        programs.map { p in
            guard p.id == id, p.rotationOrd != nil else { return p }
            var out = p
            out.restDaysAfter = min(LiftProgramRow.maxRestDays, max(0, days))
            return out
        }
    }
}
