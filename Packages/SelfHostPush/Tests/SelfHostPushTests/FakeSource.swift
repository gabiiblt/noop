import Foundation
@testable import SelfHostPush

/// In-memory RowSource for tests. Rows are keyed by "stream|device".
final class FakeSource: RowSource {
    var devices: [String] = ["strap"]
    var rows: [String: [SourceRow]] = [:]
    /// Stream names the engine asked for, in order (to assert nothing unadvertised was read).
    var readStreams: [String] = []

    private func k(_ spec: StreamSpec, _ device: String) -> String { return "\(spec.name)|\(device)" }

    func set(_ spec: StreamSpec, device: String = "strap", _ list: [SourceRow]) {
        rows[k(spec, device)] = list
    }

    func deviceIds() throws -> [String] { return devices }

    func appendPage(_ spec: StreamSpec, deviceId: String, afterRowId: Int64?, limit: Int) throws -> [SourceRow] {
        readStreams.append(spec.name)
        let after = afterRowId ?? 0
        let all = (rows[k(spec, deviceId)] ?? []).filter { $0.rowId > after }.sorted { $0.rowId < $1.rowId }
        return Array(all.prefix(limit))
    }

    func row(_ spec: StreamSpec, deviceId: String, rowId: Int64) throws -> SourceRow? {
        return (rows[k(spec, deviceId)] ?? []).first { $0.rowId == rowId }
    }

    func allRows(_ spec: StreamSpec, deviceId: String) throws -> [SourceRow] {
        readStreams.append(spec.name)
        return rows[k(spec, deviceId)] ?? []
    }
}

func hrRow(_ rowId: Int64, ts: Int64, bpm: Int64 = 60) -> SourceRow {
    return SourceRow(rowId: rowId, key: ["ts": .int(ts)], data: ["bpm": .int(bpm)])
}

func tempURL(_ ext: String = "sqlite") -> URL {
    return FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + ext)
}
