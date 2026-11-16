import Foundation

public struct SourceRow: Equatable, Sendable {
    /// SQLite insertion rowid (0 for streams read with `allRows`).
    public let rowId: Int64
    public let key: [String: JSONValue]
    public let data: [String: JSONValue]

    public init(rowId: Int64, key: [String: JSONValue], data: [String: JSONValue]) {
        self.rowId = rowId
        self.key = key
        self.data = data
    }
}

/// Read-only view of NOOP's local database as the push engine needs it. Implemented over GRDB by
/// `GRDBRowSource`; faked in tests.
public protocol RowSource {
    /// Candidate device scopes (live discovery). The engine unions them with the ones it remembers.
    func deviceIds() throws -> [String]
    /// Rows of an append stream with `rowid > afterRowId`, ordered by rowid, at most `limit`.
    func appendPage(_ spec: StreamSpec, deviceId: String, afterRowId: Int64?, limit: Int) throws -> [SourceRow]
    /// The row currently stored at `rowId` for this device, or nil when it is gone.
    func row(_ spec: StreamSpec, deviceId: String, rowId: Int64) throws -> SourceRow?
    /// Every row of a replace-window or snapshot stream for one device, sorted by natural key.
    /// These tables are day-level and small, so a full read is cheap.
    func allRows(_ spec: StreamSpec, deviceId: String) throws -> [SourceRow]
}

/// The key fingerprint a cursor stores for `row`.
public func fingerprint(of row: SourceRow, spec: StreamSpec, deviceId: String) -> String {
    return keyFingerprint(stream: spec.name, deviceId: deviceId, keyJSON: compactKey(spec, row.key))
}
