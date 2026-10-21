import Foundation

/// A RESP2 or RESP3 reply value.
public enum RESPValue: Sendable {
    case simpleString(String)
    case error(RESPError)
    case integer(Int64)
    /// `nil` = RESP2 null bulk string (`$-1`).
    case bulkString(Data?)
    /// `nil` = RESP2 null array (`*-1`).
    case array([RESPValue]?)
    /// RESP3 `_`.
    case null
    case double(Double)
    case boolean(Bool)
    case bigNumber(String)
    case verbatimString(format: String, text: Data)
    case map([(RESPValue, RESPValue)])
    case set([RESPValue])
    case push([RESPValue])
}

// MARK: - Constructors

public extension RESPValue {
    /// Bulk string from UTF-8 text.
    static func bulk(_ text: String) -> RESPValue { .bulkString(Data(text.utf8)) }

    /// Array of bulk strings.
    static func bulkArray(_ items: [String]) -> RESPValue { .array(items.map { .bulkString(Data($0.utf8)) }) }

    static let ok: RESPValue = .simpleString("OK")
}

// MARK: - Accessors

public extension RESPValue {
    var isNull: Bool {
        switch self {
        case .null, .bulkString(nil), .array(nil): return true
        default: return false
        }
    }

    var isError: Bool {
        if case .error = self { return true }
        return false
    }

    var errorValue: RESPError? {
        if case .error(let e) = self { return e }
        return nil
    }

    /// Raw bytes for string-like replies; numbers rendered as decimal text.
    var dataValue: Data? {
        switch self {
        case .simpleString(let s): return Data(s.utf8)
        case .bulkString(let d): return d
        case .verbatimString(_, let d): return d
        case .integer(let i): return Data(String(i).utf8)
        case .double(let d): return Data(RedisArgument.format(d).utf8)
        case .bigNumber(let s): return Data(s.utf8)
        case .boolean(let b): return Data((b ? "1" : "0").utf8)
        default: return nil
        }
    }

    /// UTF-8 decoding of `dataValue` (lossy: invalid sequences become U+FFFD).
    var stringValue: String? {
        guard let data = dataValue else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    var intValue: Int64? {
        switch self {
        case .integer(let i): return i
        case .double(let d): return d.isFinite ? Int64(exactly: d.rounded(.towardZero)) : nil
        case .boolean(let b): return b ? 1 : 0
        default:
            guard let s = stringValue else { return nil }
            return Int64(s.trimmingCharacters(in: .whitespaces))
        }
    }

    var uint64Value: UInt64? {
        switch self {
        case .integer(let i): return i >= 0 ? UInt64(i) : nil
        default:
            guard let s = stringValue else { return nil }
            return UInt64(s.trimmingCharacters(in: .whitespaces))
        }
    }

    var doubleValue: Double? {
        switch self {
        case .double(let d): return d
        case .integer(let i): return Double(i)
        default:
            guard let s = stringValue?.trimmingCharacters(in: .whitespaces).lowercased() else { return nil }
            switch s {
            case "inf", "+inf": return .infinity
            case "-inf": return -.infinity
            default: return Double(s)
            }
        }
    }

    var boolValue: Bool? {
        switch self {
        case .boolean(let b): return b
        case .integer(let i): return i != 0
        default: return nil
        }
    }

    /// Elements of array-like replies (array, set, push). A map is flattened to `[k1, v1, k2, v2, ...]`.
    var arrayValue: [RESPValue]? {
        switch self {
        case .array(let a): return a
        case .set(let a), .push(let a): return a
        case .map(let pairs): return pairs.flatMap { [$0.0, $0.1] }
        default: return nil
        }
    }

    /// Key/value pairs of a RESP3 map, or of a RESP2 flat array with an even number of elements.
    var mapValue: [(RESPValue, RESPValue)]? {
        switch self {
        case .map(let pairs): return pairs
        case .array(let a?), .set(let a), .push(let a):
            guard a.count % 2 == 0 else { return nil }
            return stride(from: 0, to: a.count, by: 2).map { (a[$0], a[$0 + 1]) }
        default: return nil
        }
    }

    /// `mapValue` with keys decoded as UTF-8 strings (later duplicates win).
    var stringKeyedMap: [String: RESPValue]? {
        guard let pairs = mapValue else { return nil }
        var out: [String: RESPValue] = [:]
        for (k, v) in pairs { if let key = k.stringValue { out[key] = v } }
        return out
    }
}

// MARK: - Equatable / Hashable

extension RESPValue: Hashable {
    public static func == (lhs: RESPValue, rhs: RESPValue) -> Bool {
        switch (lhs, rhs) {
        case (.simpleString(let a), .simpleString(let b)): return a == b
        case (.error(let a), .error(let b)): return a == b
        case (.integer(let a), .integer(let b)): return a == b
        case (.bulkString(let a), .bulkString(let b)): return a == b
        case (.array(let a), .array(let b)): return a == b
        case (.null, .null): return true
        case (.double(let a), .double(let b)): return a == b || (a.isNaN && b.isNaN)
        case (.boolean(let a), .boolean(let b)): return a == b
        case (.bigNumber(let a), .bigNumber(let b)): return a == b
        case (.verbatimString(let fa, let ta), .verbatimString(let fb, let tb)): return fa == fb && ta == tb
        case (.map(let a), .map(let b)):
            return a.count == b.count && zip(a, b).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        case (.set(let a), .set(let b)): return a == b
        case (.push(let a), .push(let b)): return a == b
        default: return false
        }
    }

    public func hash(into hasher: inout Hasher) {
        switch self {
        case .simpleString(let s): hasher.combine(0); hasher.combine(s)
        case .error(let e): hasher.combine(1); hasher.combine(e)
        case .integer(let i): hasher.combine(2); hasher.combine(i)
        case .bulkString(let d): hasher.combine(3); hasher.combine(d)
        case .array(let a): hasher.combine(4); hasher.combine(a)
        case .null: hasher.combine(5)
        case .double(let d): hasher.combine(6); hasher.combine(d.isNaN ? 0 : d)
        case .boolean(let b): hasher.combine(7); hasher.combine(b)
        case .bigNumber(let s): hasher.combine(8); hasher.combine(s)
        case .verbatimString(let f, let t): hasher.combine(9); hasher.combine(f); hasher.combine(t)
        case .map(let pairs):
            hasher.combine(10)
            for (k, v) in pairs { hasher.combine(k); hasher.combine(v) }
        case .set(let a): hasher.combine(11); hasher.combine(a)
        case .push(let a): hasher.combine(12); hasher.combine(a)
        }
    }
}

// MARK: - Rendering

extension RESPValue: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String { redisCLIText() }
    public var debugDescription: String { "RESPValue(\(redisCLIText()))" }
}

public extension RESPValue {
    /// redis-cli style rendering (`(integer) 1`, `"value"`, `(nil)`, numbered nested arrays).
    /// Binary bytes are escaped like redis-cli `sdscatrepr` (`\xHH`, `\n`, `\"`).
    func redisCLIText() -> String {
        renderCLI(prefixWidth: 0)
    }

    private func renderCLI(prefixWidth: Int) -> String {
        switch self {
        case .simpleString(let s): return s
        case .error(let e): return "(error) \(e.message)"
        case .integer(let i): return "(integer) \(i)"
        case .bulkString(nil), .array(nil), .null: return "(nil)"
        case .bulkString(let d?): return RESPValue.quoted(d)
        case .verbatimString(_, let d): return String(decoding: d, as: UTF8.self)
        case .double(let d): return "(double) \(RedisArgument.format(d))"
        case .boolean(let b): return b ? "(true)" : "(false)"
        case .bigNumber(let s): return "(big number) \(s)"
        case .array(let items?):
            return RESPValue.renderList(items.map { [$0] }, separator: ")", empty: "(empty array)", prefixWidth: prefixWidth)
        case .set(let items):
            return RESPValue.renderList(items.map { [$0] }, separator: "~", empty: "(empty set)", prefixWidth: prefixWidth)
        case .push(let items):
            return RESPValue.renderList(items.map { [$0] }, separator: ")", empty: "(empty push)", prefixWidth: prefixWidth)
        case .map(let pairs):
            return RESPValue.renderList(pairs.map { [$0.0, $0.1] }, separator: "#", empty: "(empty hash)", prefixWidth: prefixWidth)
        }
    }

    /// Each entry is one element, or a key/value pair rendered as `key => value`.
    private static func renderList(_ entries: [[RESPValue]], separator: Character, empty: String,
                                   prefixWidth: Int) -> String {
        if entries.isEmpty { return empty }
        let width = String(entries.count).count
        let indent = String(repeating: " ", count: prefixWidth)
        var out = ""
        for (index, entry) in entries.enumerated() {
            let number = String(index + 1)
            let label = String(repeating: " ", count: width - number.count) + number + String(separator) + " "
            if index > 0 { out += "\n" + indent }
            out += label
            let childWidth = prefixWidth + label.count
            out += entry[0].renderCLI(prefixWidth: childWidth)
            if entry.count > 1 {
                out += " => " + entry[1].renderCLI(prefixWidth: childWidth)
            }
        }

        return out
    }

    /// `"..."` with redis-cli escaping of non-printable bytes.
    static func quoted(_ data: Data) -> String {
        var out = "\""
        for byte in data {
            switch byte {
            case 0x5C: out += "\\\\"
            case 0x22: out += "\\\""
            case 0x0A: out += "\\n"
            case 0x0D: out += "\\r"
            case 0x09: out += "\\t"
            case 0x07: out += "\\a"
            case 0x08: out += "\\b"
            case 0x20...0x7E: out.append(Character(UnicodeScalar(byte)))
            default: out += String(format: "\\x%02x", byte)
            }
        }

        return out + "\""
    }
}
