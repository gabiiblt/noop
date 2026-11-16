import CryptoKit
import Foundation

/// Lowercase hex SHA-256.
public func sha256Hex(_ data: Data) -> String {
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

/// PUSH_PROTOCOL.md: SHA-256 of the UTF-8 bytes `stream`, LF, `deviceId`, LF, compact JSON of the
/// natural key with members in registry order.
public func keyFingerprint(stream: String, deviceId: String, keyJSON: String) -> String {
    return sha256Hex(Data("\(stream)\n\(deviceId)\n\(keyJSON)".utf8))
}

/// A name-based (version 5 layout) UUID derived from `identity`: the same content always yields the
/// same id, so a retried batch has an identical `batchId` without any persisted retry state.
func deterministicUUID(_ identity: String) -> String {
    var d = Array(SHA256.hash(data: Data(identity.utf8)).prefix(16))
    d[6] = (d[6] & 0x0F) | 0x50
    d[8] = (d[8] & 0x3F) | 0x80
    let hex = Array(d.map { String(format: "%02x", $0) }.joined())
    func seg(_ a: Int, _ b: Int) -> String { return String(hex[a..<b]) }
    return "\(seg(0, 8))-\(seg(8, 12))-\(seg(12, 16))-\(seg(16, 20))-\(seg(20, 32))"
}
