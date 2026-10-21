import Foundation
import RESP

/// JSON tree that keeps object key order and number literals as text (64-bit ints, exponents survive).
public indirect enum JSONValue: Hashable, Sendable {
    case object([JSONMember])
    case array([JSONValue])
    case string(String)
    /// Original literal, e.g. `"12345678901234567890"` or `"1e-7"`.
    case number(String)
    case bool(Bool)
    case null

    public var typeName: String {
        switch self {
        case .object: return "object"
        case .array: return "array"
        case .string: return "string"
        case .number(let n): return n.contains(where: { ".eE".contains($0) }) ? "number" : "integer"
        case .bool: return "boolean"
        case .null: return "null"
        }
    }
}

public extension JSONValue {
    static func integer<T: BinaryInteger>(_ value: T) -> JSONValue { .number(String(value)) }

    /// Shortest round-trip text; non-finite values become the JS spellings `NaN` / `Infinity` / `-Infinity`.
    static func double(_ value: Double) -> JSONValue { .number(JSONNumberText.double(value)) }

    static func float(_ value: Float) -> JSONValue { .number(JSONNumberText.float(value)) }

    var isContainer: Bool {
        switch self {
        case .object, .array: return true
        default: return false
        }
    }

    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    var arrayValue: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    var members: [JSONMember]? {
        if case .object(let m) = self { return m }
        return nil
    }

    subscript(key: String) -> JSONValue? {
        guard case .object(let members) = self else { return nil }
        return members.last(where: { $0.key == key })?.value
    }

    var compactText: String { JSONPrinter.print(self, indent: nil) }
}

public struct JSONMember: Hashable, Sendable {
    public var key: String
    public var value: JSONValue

    public init(key: String, value: JSONValue) {
        self.key = key
        self.value = value
    }
}

enum JSONNumberText {
    static func double(_ value: Double) -> String {
        if value.isNaN { return "NaN" }
        if value.isInfinite { return value < 0 ? "-Infinity" : "Infinity" }
        return trimmed(value.description)
    }

    static func float(_ value: Float) -> String {
        if value.isNaN { return "NaN" }
        if value.isInfinite { return value < 0 ? "-Infinity" : "Infinity" }
        return trimmed(value.description)
    }

    /// Drops a trailing `.0` from whole-number text without exponent notation.
    private static func trimmed(_ text: String) -> String {
        if text.hasSuffix(".0"), !text.contains("e") { return String(text.dropLast(2)) }
        return text
    }
}

public enum JSONParseError: Error, LocalizedError, Sendable, Equatable {
    case unexpectedEnd
    case unexpectedCharacter(Character, offset: Int)
    case invalidNumber(String)
    case invalidEscape(offset: Int)
    case duplicateKey(String)

    public var errorDescription: String? {
        switch self {
        case .unexpectedEnd: return "Unexpected end of JSON input"
        case .unexpectedCharacter(let c, let o): return "Unexpected token \(c) in JSON at position \(o)"
        case .invalidNumber(let s): return "Invalid number \(s)"
        case .invalidEscape(let o): return "Bad escaped character in JSON at position \(o)"
        case .duplicateKey(let k): return "Duplicate key \"\(k)\""
        }
    }
}

/// Big-int-safe JSON parser (RFC 8259). Keeps key order, duplicate keys, and number literals verbatim.
public enum JSONParser {
    public static func parse(_ text: String, rejectDuplicateKeys: Bool = false) throws -> JSONValue {
        var bytes = Array(text.utf8)
        return try bytes.withUnsafeMutableBufferPointer { buffer in
            var parser = Parser(bytes: UnsafeBufferPointer(buffer), rejectDuplicateKeys: rejectDuplicateKeys)
            return try parser.parseDocument()
        }
    }

    public static func parse(_ data: Data, rejectDuplicateKeys: Bool = false) throws -> JSONValue {
        try parse(String(decoding: data, as: UTF8.self), rejectDuplicateKeys: rejectDuplicateKeys)
    }

    /// `true` when `text` parses as JSON.
    public static func isValid(_ text: String) -> Bool {
        (try? parse(text)) != nil
    }

    /// Keys that appear more than once in the same object anywhere in the document.
    public static func duplicateKeys(in value: JSONValue) -> [String] {
        var result: [String] = []

        func walk(_ v: JSONValue) {
            switch v {
            case .object(let members):
                var seen = Set<String>()
                for m in members {
                    if !seen.insert(m.key).inserted, !result.contains(m.key) { result.append(m.key) }
                    walk(m.value)
                }
            case .array(let items):
                items.forEach(walk)
            default:
                break
            }
        }

        walk(value)
        return result
    }

    private static let maxDepth = 300

    private struct Parser {
        let bytes: UnsafeBufferPointer<UInt8>
        let rejectDuplicateKeys: Bool
        var index = 0
        var depth = 0

        init(bytes: UnsafeBufferPointer<UInt8>, rejectDuplicateKeys: Bool) {
            self.bytes = bytes
            self.rejectDuplicateKeys = rejectDuplicateKeys
        }

        mutating func parseDocument() throws -> JSONValue {
            skipWhitespace()
            let value = try parseValue()
            skipWhitespace()
            if index < bytes.count { throw unexpected() }
            return value
        }

        func unexpected() -> JSONParseError {
            guard index < bytes.count else { return .unexpectedEnd }
            return .unexpectedCharacter(character(at: index), offset: index)
        }

        func character(at offset: Int) -> Character {
            let b = bytes[offset]
            if b < 0x80 { return Character(Unicode.Scalar(b)) }
            var end = offset + 1
            while end < bytes.count, end < offset + 4, bytes[end] & 0xC0 == 0x80 { end += 1 }
            let s = String(decoding: UnsafeBufferPointer(rebasing: bytes[offset..<end]), as: UTF8.self)
            return s.first ?? "\u{FFFD}"
        }

        mutating func skipWhitespace() {
            while index < bytes.count {
                switch bytes[index] {
                case 0x20, 0x09, 0x0A, 0x0D: index += 1
                default: return
                }
            }
        }

        mutating func parseValue() throws -> JSONValue {
            guard index < bytes.count else { throw JSONParseError.unexpectedEnd }
            switch bytes[index] {
            case UInt8(ascii: "{"): return try parseObject()
            case UInt8(ascii: "["): return try parseArray()
            case UInt8(ascii: "\""): return .string(try parseString())
            case UInt8(ascii: "t"): try expectLiteral("true"); return .bool(true)
            case UInt8(ascii: "f"): try expectLiteral("false"); return .bool(false)
            case UInt8(ascii: "n"): try expectLiteral("null"); return .null
            case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"): return .number(try parseNumber())
            default: throw unexpected()
            }
        }

        mutating func expectLiteral(_ literal: String) throws {
            for b in literal.utf8 {
                guard index < bytes.count else { throw JSONParseError.unexpectedEnd }
                guard bytes[index] == b else { throw unexpected() }
                index += 1
            }
        }

        mutating func enter() throws {
            depth += 1
            if depth > JSONParser.maxDepth { throw unexpected() }
        }

        mutating func parseObject() throws -> JSONValue {
            try enter()
            defer { depth -= 1 }
            index += 1
            var members: [JSONMember] = []
            var seen = Set<String>()
            skipWhitespace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "}") {
                index += 1
                return .object(members)
            }

            while true {
                skipWhitespace()
                guard index < bytes.count else { throw JSONParseError.unexpectedEnd }
                guard bytes[index] == UInt8(ascii: "\"") else { throw unexpected() }
                let key = try parseString()
                if rejectDuplicateKeys, !seen.insert(key).inserted { throw JSONParseError.duplicateKey(key) }
                skipWhitespace()
                guard index < bytes.count else { throw JSONParseError.unexpectedEnd }
                guard bytes[index] == UInt8(ascii: ":") else { throw unexpected() }
                index += 1
                skipWhitespace()
                let value = try parseValue()
                members.append(JSONMember(key: key, value: value))
                skipWhitespace()
                guard index < bytes.count else { throw JSONParseError.unexpectedEnd }
                if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                if bytes[index] == UInt8(ascii: "}") { index += 1; return .object(members) }
                throw unexpected()
            }
        }

        mutating func parseArray() throws -> JSONValue {
            try enter()
            defer { depth -= 1 }
            index += 1
            var items: [JSONValue] = []
            skipWhitespace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "]") {
                index += 1
                return .array(items)
            }

            while true {
                skipWhitespace()
                items.append(try parseValue())
                skipWhitespace()
                guard index < bytes.count else { throw JSONParseError.unexpectedEnd }
                if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                if bytes[index] == UInt8(ascii: "]") { index += 1; return .array(items) }
                throw unexpected()
            }
        }

        mutating func parseNumber() throws -> String {
            let start = index
            func digit(_ i: Int) -> Bool { i < bytes.count && bytes[i] >= 0x30 && bytes[i] <= 0x39 }
            if bytes[index] == UInt8(ascii: "-") { index += 1 }
            guard digit(index) else { throw invalidNumber(from: start) }
            if bytes[index] == UInt8(ascii: "0") {
                index += 1
            } else {
                while digit(index) { index += 1 }
            }

            if index < bytes.count, bytes[index] == UInt8(ascii: ".") {
                index += 1
                guard digit(index) else { throw invalidNumber(from: start) }
                while digit(index) { index += 1 }
            }

            if index < bytes.count, bytes[index] == UInt8(ascii: "e") || bytes[index] == UInt8(ascii: "E") {
                index += 1
                if index < bytes.count, bytes[index] == UInt8(ascii: "+") || bytes[index] == UInt8(ascii: "-") { index += 1 }
                guard digit(index) else { throw invalidNumber(from: start) }
                while digit(index) { index += 1 }
            }

            return String(decoding: UnsafeBufferPointer(rebasing: bytes[start..<index]), as: UTF8.self)
        }

        func invalidNumber(from start: Int) -> JSONParseError {
            let end = min(Swift.max(index + 1, start + 1), bytes.count)
            return .invalidNumber(String(decoding: UnsafeBufferPointer(rebasing: bytes[start..<end]), as: UTF8.self))
        }

        mutating func parseString() throws -> String {
            index += 1
            let start = index
            while index < bytes.count {
                let b = bytes[index]
                if b == UInt8(ascii: "\"") {
                    let s = String(decoding: UnsafeBufferPointer(rebasing: bytes[start..<index]), as: UTF8.self)
                    index += 1
                    return s
                }

                if b == UInt8(ascii: "\\") { break }
                index += 1
            }

            guard index < bytes.count else { throw JSONParseError.unexpectedEnd }
            var scratch = Array(bytes[start..<index])
            while index < bytes.count {
                let b = bytes[index]
                if b == UInt8(ascii: "\"") {
                    index += 1
                    return String(decoding: scratch, as: UTF8.self)
                }

                if b != UInt8(ascii: "\\") {
                    scratch.append(b)
                    index += 1
                    continue
                }

                let escapeOffset = index
                index += 1
                guard index < bytes.count else { throw JSONParseError.unexpectedEnd }
                let e = bytes[index]
                index += 1
                switch e {
                case UInt8(ascii: "\""): scratch.append(0x22)
                case UInt8(ascii: "\\"): scratch.append(0x5C)
                case UInt8(ascii: "/"): scratch.append(0x2F)
                case UInt8(ascii: "b"): scratch.append(0x08)
                case UInt8(ascii: "f"): scratch.append(0x0C)
                case UInt8(ascii: "n"): scratch.append(0x0A)
                case UInt8(ascii: "r"): scratch.append(0x0D)
                case UInt8(ascii: "t"): scratch.append(0x09)
                case UInt8(ascii: "u"):
                    var scalarValue = try readHex4(escapeOffset: escapeOffset)
                    if (0xD800...0xDBFF).contains(scalarValue) {
                        if index + 1 < bytes.count, bytes[index] == UInt8(ascii: "\\"), bytes[index + 1] == UInt8(ascii: "u") {
                            let save = index
                            index += 2
                            let low = try readHex4(escapeOffset: save)
                            if (0xDC00...0xDFFF).contains(low) {
                                scalarValue = 0x10000 + ((scalarValue - 0xD800) << 10) + (low - 0xDC00)
                            } else {
                                index = save
                                scalarValue = 0xFFFD
                            }
                        } else {
                            scalarValue = 0xFFFD
                        }
                    } else if (0xDC00...0xDFFF).contains(scalarValue) {
                        scalarValue = 0xFFFD
                    }

                    let scalar = Unicode.Scalar(scalarValue) ?? "\u{FFFD}"
                    scratch.append(contentsOf: Array(String(Character(scalar)).utf8))
                default:
                    throw JSONParseError.invalidEscape(offset: escapeOffset)
                }
            }

            throw JSONParseError.unexpectedEnd
        }

        mutating func readHex4(escapeOffset: Int) throws -> UInt32 {
            guard index + 4 <= bytes.count else { throw JSONParseError.unexpectedEnd }
            var value: UInt32 = 0
            for _ in 0..<4 {
                guard let d = hexDigit(bytes[index]) else { throw JSONParseError.invalidEscape(offset: escapeOffset) }
                value = value << 4 | UInt32(d)
                index += 1
            }

            return value
        }
    }
}

@inline(__always)
func hexDigit(_ b: UInt8) -> UInt8? {
    switch b {
    case 0x30...0x39: return b - 0x30
    case 0x41...0x46: return b - 0x41 + 10
    case 0x61...0x66: return b - 0x61 + 10
    default: return nil
    }
}

public enum JSONPrinter {
    /// `indent == nil` prints compact JSON; otherwise `JSON.stringify(value, null, indent)` layout.
    public static func print(_ value: JSONValue, indent: Int? = 4) -> String {
        var out = ""
        let unit = indent.flatMap { $0 > 0 ? String(repeating: " ", count: $0) : nil }
        write(value, into: &out, unit: unit, level: 0)
        return out
    }

    /// JSON string literal with `JSON.stringify` escaping.
    public static func quote(_ s: String) -> String {
        var out = ""
        writeString(s, into: &out)
        return out
    }

    private static func write(_ value: JSONValue, into out: inout String, unit: String?, level: Int) {
        switch value {
        case .null: out += "null"
        case .bool(let b): out += b ? "true" : "false"
        case .number(let n): out += n
        case .string(let s): writeString(s, into: &out)
        case .array(let items):
            if items.isEmpty { out += "[]"; return }
            out += "["
            for (i, item) in items.enumerated() {
                if i > 0 { out += "," }
                newline(&out, unit: unit, level: level + 1)
                write(item, into: &out, unit: unit, level: level + 1)
            }

            newline(&out, unit: unit, level: level)
            out += "]"
        case .object(let members):
            if members.isEmpty { out += "{}"; return }
            out += "{"
            for (i, member) in members.enumerated() {
                if i > 0 { out += "," }
                newline(&out, unit: unit, level: level + 1)
                writeString(member.key, into: &out)
                out += unit == nil ? ":" : ": "
                write(member.value, into: &out, unit: unit, level: level + 1)
            }

            newline(&out, unit: unit, level: level)
            out += "}"
        }
    }

    private static func newline(_ out: inout String, unit: String?, level: Int) {
        guard let unit, !unit.isEmpty else { return }
        out += "\n"
        for _ in 0..<level { out += unit }
    }

    /// Copies the runs between characters that need escaping in bulk; only `"`, `\` and C0 controls are escaped.
    private static func writeString(_ s: String, into out: inout String) {
        out += "\""
        let utf8 = s.utf8
        var runStart = utf8.startIndex
        var index = runStart
        while index != utf8.endIndex {
            let byte = utf8[index]
            guard byte == 0x22 || byte == 0x5C || byte < 0x20 else {
                index = utf8.index(after: index)
                continue
            }
            if runStart != index { out.unicodeScalars.append(contentsOf: s.unicodeScalars[runStart..<index]) }
            out += escape(byte)
            index = utf8.index(after: index)
            runStart = index
        }

        if runStart != utf8.endIndex { out.unicodeScalars.append(contentsOf: s.unicodeScalars[runStart...]) }
        out += "\""
    }

    private static func escape(_ byte: UInt8) -> String {
        switch byte {
        case 0x22: return "\\\""
        case 0x5C: return "\\\\"
        case 0x0A: return "\\n"
        case 0x0D: return "\\r"
        case 0x09: return "\\t"
        case 0x08: return "\\b"
        case 0x0C: return "\\f"
        default:
            let digits = Array("0123456789abcdef")
            return "\\u00" + String(digits[Int(byte >> 4)]) + String(digits[Int(byte & 0x0F)])
        }
    }
}
