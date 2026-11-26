import Foundation
import GRDB

/// `RowSource` over NOOP's real database, opened READ-ONLY on its own connection (WAL lets it read
/// beside the app's writer without blocking it). Columns come from the registry's explicit projections,
/// never `SELECT *`; a column the local schema does not have yet is simply sent as null.
public final class GRDBRowSource: RowSource {
    private let queue: DatabaseQueue

    /// Small tables whose `deviceId` values enumerate the device scopes (a `SELECT DISTINCT` over a
    /// multi-million-row sample table would scan it end to end).
    private static let discoveryTables = ["device", "dailyMetric", "sleepSession", "workout", "journal", "metricSeries", "appleDaily", "appleStepHour", "liveSession", "scoreInputProvenance", "labMarker", "liftExercise", "liftProgram", "liftProgramItem", "liftSession", "liftSet", "liftGym", "ouraRaw"]

    public init(databasePath: String) throws {
        var config = Configuration()
        config.readonly = true
        config.busyMode = .timeout(5)
        self.queue = try DatabaseQueue(path: databasePath, configuration: config)
    }

    // MARK: RowSource

    public func deviceIds() throws -> [String] {
        return try queue.read { db -> [String] in
            var out = Set<String>()
            for table in GRDBRowSource.discoveryTables {
                guard try db.tableExists(table) else { continue }
                let column = table == "device" ? "id" : "deviceId"
                for id in try String.fetchAll(db, sql: "SELECT DISTINCT \(GRDBRowSource.q(column)) FROM \(GRDBRowSource.q(table))") {
                    out.insert(id)
                }
            }
            return out.sorted()
        }
    }

    public func appendPage(_ spec: StreamSpec, deviceId: String, afterRowId: Int64?,
                           limit: Int) throws -> [SourceRow] {
        return try queue.read { db -> [SourceRow] in
            guard let present = try GRDBRowSource.projection(db, spec) else { return [] }
            let sql = "SELECT rowid AS _rid, \(GRDBRowSource.list(present)) FROM \(GRDBRowSource.q(spec.name)) "
                + "WHERE deviceId = ? AND rowid > ? ORDER BY rowid LIMIT ?"
            let rows = try Row.fetchAll(db, sql: sql, arguments: [deviceId, afterRowId ?? 0, limit])
            return rows.map { GRDBRowSource.sourceRow($0, spec, present) }
        }
    }

    public func row(_ spec: StreamSpec, deviceId: String, rowId: Int64) throws -> SourceRow? {
        return try queue.read { db -> SourceRow? in
            guard let present = try GRDBRowSource.projection(db, spec) else { return nil }
            let sql = "SELECT rowid AS _rid, \(GRDBRowSource.list(present)) FROM \(GRDBRowSource.q(spec.name)) "
                + "WHERE rowid = ? AND deviceId = ?"
            guard let r = try Row.fetchOne(db, sql: sql, arguments: [rowId, deviceId]) else { return nil }
            return GRDBRowSource.sourceRow(r, spec, present)
        }
    }

    public func allRows(_ spec: StreamSpec, deviceId: String) throws -> [SourceRow] {
        return try queue.read { db -> [SourceRow] in
            guard let present = try GRDBRowSource.projection(db, spec) else { return [] }
            let order = spec.key.map { GRDBRowSource.q($0.name) }.joined(separator: ", ")
            let sql = "SELECT rowid AS _rid, \(GRDBRowSource.list(present)) FROM \(GRDBRowSource.q(spec.name)) "
                + "WHERE deviceId = ? ORDER BY \(order)"
            let rows = try Row.fetchAll(db, sql: sql, arguments: [deviceId])
            return rows.map { GRDBRowSource.sourceRow($0, spec, present) }
        }
    }

    // MARK: Helpers

    private static func q(_ name: String) -> String {
        return "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private static func list(_ cols: [Column]) -> String {
        return cols.map { q($0.name) }.joined(separator: ", ")
    }

    /// The registry columns this database actually has, or nil when the table (or any key column)
    /// is missing, in which case the stream has nothing to send yet.
    private static func projection(_ db: Database, _ spec: StreamSpec) throws -> [Column]? {
        guard try db.tableExists(spec.name) else { return nil }
        let have = Set(try db.columns(in: spec.name).map { $0.name })
        for k in spec.key where !have.contains(k.name) { return nil }
        guard have.contains("deviceId") else { return nil }
        return (spec.key + spec.data + spec.extData).filter { have.contains($0.name) }
    }

    private static func sourceRow(_ r: Row, _ spec: StreamSpec, _ present: [Column]) -> SourceRow {
        let keyNames = Set(spec.key.map { $0.name })
        var key: [String: JSONValue] = [:]
        var data: [String: JSONValue] = [:]
        for c in present {
            let raw: DatabaseValue = r[c.name]
            let v = convert(raw, c)
            if keyNames.contains(c.name) { key[c.name] = v } else { data[c.name] = v }
        }
        // A required boolean the local schema predates (e.g. userEdited) reads as false, never null.
        let have = Set(present.map { $0.name })
        for c in spec.data where c.kind == .bool && !c.nullable && !have.contains(c.name) {
            data[c.name] = .bool(false)
        }
        let rid: Int64 = r["_rid"]
        return SourceRow(rowId: rid, key: key, data: data)
    }

    static func convert(_ v: DatabaseValue, _ c: Column) -> JSONValue {
        switch v.storage {
        case .null:
            return (c.kind == .bool && !c.nullable) ? .bool(false) : .null
        case .int64(let i):
            switch c.kind {
            case .int: return .int(i)
            case .real: return .double(Double(i))
            case .bool: return .bool(i != 0)
            case .text: return .string(String(i))
            case .blob: return .null
            }
        case .double(let d):
            switch c.kind {
            case .real: return .double(d)
            case .int: return (d == d.rounded() && abs(d) < 9.0e18) ? .int(Int64(d)) : .double(d)
            case .bool: return .bool(d != 0)
            case .text: return .string(String(d))
            case .blob: return .null
            }
        case .string(let s):
            switch c.kind {
            case .blob: return .string(Data(s.utf8).base64EncodedString())
            default: return .string(s)
            }
        case .blob(let data):
            return c.kind == .blob ? .string(data.base64EncodedString()) : .null
        }
    }
}
