import Foundation

// MARK: - Supersets and backups on a program (v52)
//
// A superset is two or more consecutive program lines done as a ROUND: one set of each in turn, the rest taken after
// the round rather than after every set. Lines share a `supersetGroup` id; a group of one is no group.
//
// A backup is an exercise that can take a line's place for one session when its machine is taken: the plan already
// says what to do instead. At most five per line, never the line's own exercise.
//
// The model follows openGym's (Duarte Santos, MIT authorization to Gabriel Bolatoglu; see ATTRIBUTION.md): its
// `routine-backups.js` and superset helpers. The pure edits below are checked by their own tests.

public enum LiftSuperset {

    /// How many backups one line keeps.
    public static let maxBackups = 5

    /// The groups as they are stored: a group exists only while two or more CONSECUTIVE lines share it. A line left
    /// alone loses its group, and a group split by a reorder becomes one group per consecutive run (the later runs
    /// get fresh ids), so a stored group is always one contiguous block.
    public static func normalized(_ items: [LiftProgramItemRow], newId: () -> String = { UUID().uuidString }) -> [LiftProgramItemRow] {
        var out = items
        var i = 0
        var seen = Set<String>()
        while i < out.count {
            guard let g = out[i].supersetGroup else { i += 1; continue }
            var j = i
            while j + 1 < out.count, out[j + 1].supersetGroup == g { j += 1 }
            if j == i {
                out[i].supersetGroup = nil
            } else {
                // A later run of an id already used earlier is a different group now.
                let id = seen.contains(g) ? newId() : g
                seen.insert(id)
                for k in i...j { out[k].supersetGroup = id }
            }
            i = j + 1
        }
        return out
    }

    /// Whether line `index` and the next one are in the same superset.
    public static func isLinkedToNext(_ items: [LiftProgramItemRow], _ index: Int) -> Bool {
        guard items.indices.contains(index), items.indices.contains(index + 1),
              let g = items[index].supersetGroup else { return false }
        return items[index + 1].supersetGroup == g
    }

    /// Join line `index` to the next one, or cut the link between them. Joining merges the two groups (either side
    /// may already be in one); cutting leaves the lines before as one group and the lines after as another.
    public static func toggledLink(_ items: [LiftProgramItemRow], at index: Int,
                                   newId: () -> String = { UUID().uuidString }) -> [LiftProgramItemRow] {
        guard items.indices.contains(index), items.indices.contains(index + 1) else { return items }
        var out = items
        if isLinkedToNext(out, index) {
            guard let g = out[index].supersetGroup else { return out }
            let tail = newId()
            var k = index + 1
            while k < out.count, out[k].supersetGroup == g { out[k].supersetGroup = tail; k += 1 }
        } else {
            let a = out[index].supersetGroup, b = out[index + 1].supersetGroup
            let id = a ?? b ?? newId()
            out[index].supersetGroup = id
            for k in (index + 1)..<out.count where out[k].supersetGroup == b && b != nil { out[k].supersetGroup = id }
            out[index + 1].supersetGroup = id
            if let a, b != nil, a != id {
                for k in 0..<out.count where out[k].supersetGroup == a { out[k].supersetGroup = id }
            }
        }
        return normalized(out, newId: newId)
    }

    /// The backups as they may be stored: unique names, never the line's own exercise, trimmed, at most five.
    public static func cleanBackups(_ names: [String], excluding own: String) -> [String] {
        var out: [String] = []
        let ownKey = own.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for raw in names {
            let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = name.lowercased()
            guard !name.isEmpty, key != ownKey, !out.contains(where: { $0.lowercased() == key }) else { continue }
            out.append(name)
            if out.count >= maxBackups { break }
        }
        return out
    }

    /// The JSON stored in `liftProgramItem.backupsJSON`: NULL for none.
    static func encodeBackups(_ names: [String]) -> String? {
        guard !names.isEmpty, let data = try? JSONEncoder().encode(names) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Malformed or absent JSON reads as no backups.
    static func decodeBackups(_ json: String?) -> [String] {
        guard let json, let data = json.data(using: .utf8),
              let names = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return names
    }

    /// The backups after one took over a running line: the exercise it replaces goes to the FRONT, so the machine
    /// coming free is one tap back, and the one that took over leaves the list.
    public static func backupsAfterSwap(old: String, new: String, backups: [String]) -> [String] {
        cleanBackups([old] + backups, excluding: new)
    }
}
