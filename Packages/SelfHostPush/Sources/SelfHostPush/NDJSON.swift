import Foundation

public enum PushLimits {
    public static let maxRecords = 5000
    public static let maxDecodedBytes = 4_194_304
    /// Room kept for the header line when filling a batch with record lines.
    public static let headerReserve = 4096
}

public struct Cursor: Codable, Equatable, Sendable {
    public let rowId: Int64
    public let keySha256: String

    public init(rowId: Int64, keySha256: String) {
        self.rowId = rowId
        self.keySha256 = keySha256
    }

    var compact: String {
        return "{\"rowId\":\(rowId),\"keySha256\":\(JSONValue.quote(keySha256))}"
    }
}

public enum WindowBound: Equatable, Sendable {
    case int(Int64)
    case day(String)

    var compact: String {
        switch self {
        case .int(let i): return String(i)
        case .day(let d): return JSONValue.quote(d)
        }
    }
}

/// The `window` header member (replace_window and snapshot deliveries).
public struct WindowSpec: Equatable, Sendable {
    public let replacementId: String
    /// "day", "startTs" or "all" (snapshot).
    public let selector: String
    public let startInclusive: WindowBound?
    public let endExclusive: WindowBound?
    public let part: Int
    public let parts: Int

    public init(replacementId: String, selector: String, startInclusive: WindowBound?,
                endExclusive: WindowBound?, part: Int, parts: Int) {
        self.replacementId = replacementId
        self.selector = selector
        self.startInclusive = startInclusive
        self.endExclusive = endExclusive
        self.part = part
        self.parts = parts
    }

    var compact: String {
        var s = "{\"replacementId\":\(JSONValue.quote(replacementId)),\"selector\":\(JSONValue.quote(selector))"
        if let a = startInclusive, let b = endExclusive {
            s += ",\"startInclusive\":\(a.compact),\"endExclusive\":\(b.compact)"
        }
        s += ",\"part\":\(part),\"parts\":\(parts)}"
        return s
    }
}

public struct EncodedBatch: Equatable, Sendable {
    public let batchId: String
    public let stream: String
    public let deviceId: String
    public let recordCount: Int
    public let endCursor: Cursor?
    /// The decoded NDJSON entity: header line + record lines, each LF-terminated, no BOM.
    public let body: Data
}

/// The compact JSON natural key, members in registry order (also what `keyFingerprint` hashes).
public func compactKey(_ spec: StreamSpec, _ key: [String: JSONValue]) -> String {
    let members = spec.key.map { col -> String in
        return "\(JSONValue.quote(col.name)):\((key[col.name] ?? .null).compact)"
    }
    return "{" + members.joined(separator: ",") + "}"
}

/// One record line (no trailing LF). Absent data members are sent as null.
public func encodeRecordLine(_ spec: StreamSpec, key: [String: JSONValue], data: [String: JSONValue],
                             ext: Bool) -> String {
    let members = spec.dataColumns(ext: ext).map { col -> String in
        return "\(JSONValue.quote(col.name)):\((data[col.name] ?? .null).compact)"
    }
    return "{\"type\":\"record\",\"key\":\(compactKey(spec, key)),\"data\":{" + members.joined(separator: ",") + "}}"
}

/// How many leading record lines fit one request: at most 5,000 records and 4 MiB decoded, leaving
/// room for the header. Returns 0 only when the first line alone is too large.
public func countFitting(_ lines: [String]) -> Int {
    var bytes = PushLimits.headerReserve
    var n = 0
    for line in lines {
        let size = line.utf8.count + 1
        if n >= PushLimits.maxRecords || bytes + size > PushLimits.maxDecodedBytes { break }
        bytes += size
        n += 1
    }
    return n
}

/// Header + records as one NDJSON entity. `batchId` is derived from the content (and version and
/// source), so re-encoding unchanged rows after an interrupted attempt reproduces the identical
/// batch id and bytes.
public func encodeBatch(version: PushVersion, sourceId: String, deviceId: String, spec: StreamSpec,
                        recordLines: [String], startCursor: Cursor?, endCursor: Cursor?,
                        window: WindowSpec?) -> EncodedBatch {
    let start = startCursor?.compact ?? "null"
    let end = endCursor?.compact ?? "null"
    let identity = ([version.rawValue, sourceId, deviceId, spec.name, spec.delivery.rawValue,
                     start, end, window?.compact ?? "null"] + recordLines).joined(separator: "\n")
    let batchId = deterministicUUID(identity)
    var header = "{\"type\":\"batch\",\"protocolVersion\":\"\(version.rawValue)\",\"batchId\":\"\(batchId)\""
    header += ",\"sourceId\":\"\(sourceId)\",\"deviceId\":\(JSONValue.quote(deviceId))"
    header += ",\"stream\":\"\(spec.name)\",\"delivery\":\"\(spec.delivery.rawValue)\""
    header += ",\"recordCount\":\(recordLines.count),\"startCursor\":\(start),\"endCursor\":\(end)"
    if let w = window { header += ",\"window\":\(w.compact)" }
    header += "}"
    let body = Data((([header] + recordLines).joined(separator: "\n") + "\n").utf8)
    return EncodedBatch(batchId: batchId, stream: spec.name, deviceId: deviceId,
                        recordCount: recordLines.count, endCursor: endCursor, body: body)
}
