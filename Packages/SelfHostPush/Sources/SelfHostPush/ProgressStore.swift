import Foundation
import GRDB

/// Upload progress, kept in its own small SQLite file beside the main database (no migration of the
/// main store, so upstream schema changes never collide). Scoped by a namespace: a changed endpoint,
/// protocol version or receiver state id starts a fresh baseline; rotating only the token does not.
public final class ProgressStore {
    private let queue: DatabaseQueue
    /// Random per-installation id, created once (never an account).
    public let sourceId: String

    public init(url: URL) throws {
        let q = try DatabaseQueue(path: url.path)
        try q.write { db in
            try db.execute(sql: "CREATE TABLE IF NOT EXISTS meta (k TEXT PRIMARY KEY, v TEXT NOT NULL)")
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS cursor (
                  ns TEXT NOT NULL, device TEXT NOT NULL, stream TEXT NOT NULL,
                  rowId INTEGER NOT NULL, keySha256 TEXT NOT NULL,
                  PRIMARY KEY (ns, device, stream))
                """)
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS dayhash (
                  ns TEXT NOT NULL, device TEXT NOT NULL, stream TEXT NOT NULL,
                  day TEXT NOT NULL, hash TEXT NOT NULL,
                  PRIMARY KEY (ns, device, stream, day))
                """)
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS snaphash (
                  ns TEXT NOT NULL, device TEXT NOT NULL, stream TEXT NOT NULL, hash TEXT NOT NULL,
                  PRIMARY KEY (ns, device, stream))
                """)
            try db.execute(sql: "CREATE TABLE IF NOT EXISTS device (name TEXT PRIMARY KEY)")
        }
        let existing: String? = try q.read { db in
            try String.fetchOne(db, sql: "SELECT v FROM meta WHERE k = 'sourceId'")
        }
        var id = existing ?? ""
        if existing == nil {
            id = UUID().uuidString.lowercased()
            let fresh = id
            try q.write { db in
                try db.execute(sql: "INSERT INTO meta (k, v) VALUES ('sourceId', ?)", arguments: [fresh])
            }
        }
        self.queue = q
        self.sourceId = id
    }

    // MARK: Namespace

    /// Lowercased, without trailing slashes.
    public static func normalize(endpoint: URL) -> String {
        var s = endpoint.absoluteString
        while s.hasSuffix("/") { s.removeLast() }
        return s.lowercased()
    }

    /// Progress is valid only for (source, endpoint, protocol version, receiver state). The bearer
    /// token is deliberately not an input: rotating it keeps progress.
    public func namespace(endpoint: URL, version: PushVersion, receiverStateId: String) -> String {
        let raw = [sourceId, ProgressStore.normalize(endpoint: endpoint), version.rawValue, receiverStateId]
            .joined(separator: "\n")
        return sha256Hex(Data(raw.utf8))
    }

    // MARK: Append cursors

    public func cursor(ns: String, device: String, stream: String) throws -> Cursor? {
        return try queue.read { db -> Cursor? in
            guard let row = try Row.fetchOne(
                db, sql: "SELECT rowId, keySha256 FROM cursor WHERE ns = ? AND device = ? AND stream = ?",
                arguments: [ns, device, stream]) else { return nil }
            let rowId: Int64 = row["rowId"]
            let sha: String = row["keySha256"]
            return Cursor(rowId: rowId, keySha256: sha)
        }
    }

    /// nil clears the cursor (the stream is replayed from the start).
    public func setCursor(_ cursor: Cursor?, ns: String, device: String, stream: String) throws {
        try queue.write { db in
            if let c = cursor {
                try db.execute(sql: """
                    INSERT INTO cursor (ns, device, stream, rowId, keySha256) VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT (ns, device, stream) DO UPDATE SET
                      rowId = excluded.rowId, keySha256 = excluded.keySha256
                    """, arguments: [ns, device, stream, c.rowId, c.keySha256])
            } else {
                try db.execute(sql: "DELETE FROM cursor WHERE ns = ? AND device = ? AND stream = ?",
                               arguments: [ns, device, stream])
            }
        }
    }

    /// The stored cursor if its row still exists with the same natural-key fingerprint; otherwise the
    /// cursor is cleared and nil is returned. A restore, prune, VACUUM or replaced database changes
    /// insertion positions, and trusting a stale cursor would silently skip rows.
    public func verifiedCursor(ns: String, device: String, spec: StreamSpec, source: RowSource) throws -> Cursor? {
        guard let stored = try cursor(ns: ns, device: device, stream: spec.name) else { return nil }
        if let row = try source.row(spec, deviceId: device, rowId: stored.rowId),
           fingerprint(of: row, spec: spec, deviceId: device) == stored.keySha256 {
            return stored
        }
        try setCursor(nil, ns: ns, device: device, stream: spec.name)
        return nil
    }

    // MARK: Per-day hashes (replace-window streams)

    public func dayHashes(ns: String, device: String, stream: String) throws -> [String: String] {
        return try queue.read { db -> [String: String] in
            var out: [String: String] = [:]
            let rows = try Row.fetchAll(db, sql: "SELECT day, hash FROM dayhash WHERE ns = ? AND device = ? AND stream = ?",
                                        arguments: [ns, device, stream])
            for r in rows {
                let day: String = r["day"]
                let hash: String = r["hash"]
                out[day] = hash
            }
            return out
        }
    }

    public func applyDayHashes(set: [String: String], remove: [String], ns: String, device: String,
                               stream: String) throws {
        try queue.write { db in
            for (day, hash) in set {
                try db.execute(sql: """
                    INSERT INTO dayhash (ns, device, stream, day, hash) VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT (ns, device, stream, day) DO UPDATE SET hash = excluded.hash
                    """, arguments: [ns, device, stream, day, hash])
            }
            for day in remove {
                try db.execute(sql: "DELETE FROM dayhash WHERE ns = ? AND device = ? AND stream = ? AND day = ?",
                               arguments: [ns, device, stream, day])
            }
        }
    }

    // MARK: Snapshot hashes

    public func snapshotHash(ns: String, device: String, stream: String) throws -> String? {
        return try queue.read { db in
            try String.fetchOne(db, sql: "SELECT hash FROM snaphash WHERE ns = ? AND device = ? AND stream = ?",
                                arguments: [ns, device, stream])
        }
    }

    public func setSnapshotHash(_ hash: String?, ns: String, device: String, stream: String) throws {
        try queue.write { db in
            if let h = hash {
                try db.execute(sql: """
                    INSERT INTO snaphash (ns, device, stream, hash) VALUES (?, ?, ?, ?)
                    ON CONFLICT (ns, device, stream) DO UPDATE SET hash = excluded.hash
                    """, arguments: [ns, device, stream, h])
            } else {
                try db.execute(sql: "DELETE FROM snaphash WHERE ns = ? AND device = ? AND stream = ?",
                               arguments: [ns, device, stream])
            }
        }
    }

    // MARK: Known devices

    /// Every device scope ever considered. Unioned with live discovery so deleting a device's last
    /// mutable row still produces an empty authoritative window instead of stale receiver data.
    public func knownDevices() throws -> [String] {
        return try queue.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM device ORDER BY name")
        }
    }

    public func rememberDevices(_ names: [String]) throws {
        try queue.write { db in
            for n in names {
                try db.execute(sql: "INSERT OR IGNORE INTO device (name) VALUES (?)", arguments: [n])
            }
        }
    }
}
