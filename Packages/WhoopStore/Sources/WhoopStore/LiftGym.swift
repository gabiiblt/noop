import Foundation
import GRDB

// MARK: - A gym's equipment (v51)
//
// Each place a person trains has its own plates, bars, dumbbells and machine stacks: a home rack with one pair of
// each size loads very differently from a big gym, and a plate calculator that assumes the wrong one is worse than
// none. A session records which gym it was done at, so its plate lines read that gym's plates when it is opened
// later.
//
// An inventory is kept in the gym's own unit (a 45 lb plate is not a 20.4 kg one), and the loading maths lives in
// StrandAnalytics (`LiftPlates`), ported from openGym (Duarte Santos, MIT authorization to Gabriel Bolatoglu;
// see ATTRIBUTION.md).

/// How many PAIRS of one plate size a gym owns.
public struct LiftGymPlate: Equatable, Codable, Sendable {
    public var size: Double
    public var pairs: Int

    public init(size: Double, pairs: Int) {
        self.size = size
        self.pairs = pairs
    }
}

public struct LiftGymRow: Equatable, Codable, Sendable, Identifiable {
    public var id: String
    public var deviceId: String
    public var name: String
    /// 'kg' or 'lb': the unit every number below is in.
    public var unit: String
    /// The plates owned, heaviest first. Empty means the standard set for the unit.
    public var plates: [LiftGymPlate]
    /// This gym's bar weight per equipment type ('barbell', 'ez barbell', ...). A type left out takes the built-in bar.
    public var bars: [String: Double]
    /// The dumbbells owned, lightest first. Empty means not listed.
    public var dumbbells: [Double]
    /// A machine's own weight stack, by exercise name: the weights a leg curl really has (5, 11.3, 18.1, ...).
    public var stacks: [String: [Double]]
    public var createdAt: Int
    /// When a session last used it; the gym used most recently is the one offered first.
    public var lastUsedTs: Int?

    public static let units = ["kg", "lb"]

    public init(id: String, deviceId: String, name: String, unit: String = "kg", plates: [LiftGymPlate] = [],
                bars: [String: Double] = [:], dumbbells: [Double] = [], stacks: [String: [Double]] = [:],
                createdAt: Int, lastUsedTs: Int? = nil) {
        self.id = id
        self.deviceId = deviceId
        self.name = name
        self.unit = LiftGymRow.units.contains(unit) ? unit : "kg"
        self.plates = plates.filter { $0.size > 0 && $0.pairs > 0 }.sorted { $0.size > $1.size }
        self.bars = bars.filter { $0.value > 0 }
        self.dumbbells = Array(Set(dumbbells.filter { $0 > 0 && $0 < 10_000 })).sorted()
        self.stacks = stacks.mapValues { Array(Set($0.filter { $0 > 0 && $0 < 10_000 })).sorted() }.filter { !$0.value.isEmpty }
        self.createdAt = createdAt
        self.lastUsedTs = lastUsedTs
    }

    // JSON for the four list columns: NULL for empty, so a gym with nothing set takes no text. Keys sorted, so the
    // same inventory always stores as the same text.
    static func encode<T: Encodable>(_ value: T, isEmpty: Bool) -> String? {
        guard !isEmpty, let data = try? JSONEncoder.sortedKeys.encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func decode<T: Decodable>(_ type: T.Type, _ json: String?) -> T? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    static func decode(_ row: Row) -> LiftGymRow {
        LiftGymRow(
            id: row["id"], deviceId: row["deviceId"], name: row["name"], unit: row["unit"] ?? "kg",
            plates: decode([LiftGymPlate].self, row["platesJSON"]) ?? [],
            bars: decode([String: Double].self, row["barsJSON"]) ?? [:],
            dumbbells: decode([Double].self, row["dumbbellsJSON"]) ?? [],
            stacks: decode([String: [Double]].self, row["stacksJSON"]) ?? [:],
            createdAt: row["createdAt"], lastUsedTs: row["lastUsedTs"])
    }
}

extension WhoopStore {

    /// How many gyms one device keeps. A bound against a stuck finger, far above any real number of places.
    public static let maxGyms = 20
    /// How long a gym's name may be.
    public static let maxGymNameLength = 40

    /// Upsert gyms by `id`. A name is trimmed and cut to `maxGymNameLength`; a gym with no name is skipped. A NEW gym
    /// past `maxGyms` is refused (an existing one always updates). Returns how many rows were written.
    @discardableResult
    public func upsertLiftGyms(_ rows: [LiftGymRow]) async throws -> Int {
        guard !rows.isEmpty else { return 0 }
        return try syncWrite { db in
            var n = 0
            for var r in rows {
                r.name = String(r.name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(WhoopStore.maxGymNameLength))
                guard !r.name.isEmpty else { continue }
                let exists = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM liftGym WHERE id = ?)", arguments: [r.id]) ?? false
                if !exists {
                    let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM liftGym WHERE deviceId = ?", arguments: [r.deviceId]) ?? 0
                    if count >= WhoopStore.maxGyms { continue }
                }
                try db.execute(sql: """
                    INSERT INTO liftGym
                        (id, deviceId, name, unit, platesJSON, barsJSON, dumbbellsJSON, stacksJSON, createdAt, lastUsedTs)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        name = excluded.name,
                        unit = excluded.unit,
                        platesJSON = excluded.platesJSON,
                        barsJSON = excluded.barsJSON,
                        dumbbellsJSON = excluded.dumbbellsJSON,
                        stacksJSON = excluded.stacksJSON,
                        lastUsedTs = excluded.lastUsedTs
                    """, arguments: [
                        r.id, r.deviceId, r.name, r.unit,
                        LiftGymRow.encode(r.plates, isEmpty: r.plates.isEmpty),
                        LiftGymRow.encode(r.bars, isEmpty: r.bars.isEmpty),
                        LiftGymRow.encode(r.dumbbells, isEmpty: r.dumbbells.isEmpty),
                        LiftGymRow.encode(r.stacks, isEmpty: r.stacks.isEmpty),
                        r.createdAt, r.lastUsedTs,
                    ])
                n += db.changesCount
            }
            return n
        }
    }

    /// A device's gyms, the one used most recently first.
    public func liftGyms(deviceId: String) async throws -> [LiftGymRow] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM liftGym WHERE deviceId = ?
                ORDER BY COALESCE(lastUsedTs, 0) DESC, createdAt DESC
                """, arguments: [deviceId]).map(LiftGymRow.decode)
        }
    }

    /// Delete a gym. Sessions done there keep their `gymId`, which then names nothing: history is never rewritten.
    @discardableResult
    public func deleteLiftGym(id: String) async throws -> Bool {
        try syncWrite { db in
            try db.execute(sql: "DELETE FROM liftGym WHERE id = ?", arguments: [id])
            return db.changesCount > 0
        }
    }
}
