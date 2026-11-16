import Foundation

/// A JSON scalar as it crosses the wire. Serialised by hand (not JSONEncoder) so member order,
/// number format and escaping are deterministic: the same bytes must come out on every retry.
public enum JSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)

    /// Compact RFC 8259 text. A non-finite double has no JSON form and becomes null.
    public var compact: String {
        switch self {
        case .null:
            return "null"
        case .bool(let b):
            return b ? "true" : "false"
        case .int(let i):
            return String(i)
        case .double(let d):
            return d.isFinite ? String(d) : "null"
        case .string(let s):
            return JSONValue.quote(s)
        }
    }

    /// A JSON string literal: only `"` `\` and control characters are escaped; `/` and non-ASCII
    /// scalars pass through as UTF-8.
    public static func quote(_ s: String) -> String {
        var out = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"":
                out += "\\\""
            case "\\":
                out += "\\\\"
            case "\n":
                out += "\\n"
            case "\r":
                out += "\\r"
            case "\t":
                out += "\\t"
            default:
                if u.value < 0x20 {
                    out += String(format: "\\u%04x", u.value)
                } else {
                    out.unicodeScalars.append(u)
                }
            }
        }
        out += "\""
        return out
    }
}
