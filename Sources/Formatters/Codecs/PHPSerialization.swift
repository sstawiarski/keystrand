import Foundation

/// Converts PHP serialized values to and from `JSONValue`.
/// Arrays with ordered keys `0..n-1` become JSON arrays; other arrays become objects.
/// Objects (`O:`) store their class in the first member, `__PHP_Incomplete_Class_Name`, to serialize back as `O:`.
enum PHPSerialization {
    static let classKey = "__PHP_Incomplete_Class_Name"

    struct DecodeError: Error, CustomStringConvertible {
        var description: String
        init(_ d: String) { description = d }
    }

    static func decode(_ bytes: [UInt8]) throws -> JSONValue {
        var p = Parser(bytes: bytes)
        let value = try p.value(depth: 0)
        guard p.index == bytes.count else { throw DecodeError("unexpected trailing data at offset \(p.index)") }
        return value
    }

    private struct Parser {
        let bytes: [UInt8]
        var index = 0
        var references: [JSONValue] = []

        init(bytes: [UInt8]) { self.bytes = bytes }

        mutating func expect(_ c: UInt8) throws {
            guard index < bytes.count, bytes[index] == c else {
                throw DecodeError("expected '\(Character(Unicode.Scalar(c)))' at offset \(index)")
            }
            index += 1
        }

        mutating func readUntil(_ terminator: UInt8) throws -> String {
            guard let end = bytes[index...].firstIndex(of: terminator) else { throw DecodeError("unterminated token") }
            defer { index = end + 1 }
            return String(decoding: bytes[index..<end], as: UTF8.self)
        }

        mutating func readInt(until terminator: UInt8) throws -> Int {
            let text = try readUntil(terminator)
            guard let n = Int(text) else { throw DecodeError("invalid integer '\(text)'") }
            return n
        }

        mutating func quoted(length: Int) throws -> [UInt8] {
            try expect(UInt8(ascii: "\""))
            guard length >= 0, index + length <= bytes.count else { throw DecodeError("string length out of range") }
            let s = Array(bytes[index..<index + length])
            index += length
            try expect(UInt8(ascii: "\""))
            return s
        }

        mutating func value(depth: Int) throws -> JSONValue {
            guard depth < 300 else { throw DecodeError("nesting too deep") }
            guard index < bytes.count else { throw DecodeError("unexpected end of data") }
            let type = bytes[index]
            index += 1
            switch type {
            case UInt8(ascii: "N"):
                try expect(UInt8(ascii: ";"))
                references.append(.null)
                return .null
            case UInt8(ascii: "b"):
                try expect(UInt8(ascii: ":"))
                let v = try readUntil(UInt8(ascii: ";"))
                guard v == "0" || v == "1" else { throw DecodeError("invalid boolean '\(v)'") }
                references.append(.bool(v == "1"))
                return .bool(v == "1")
            case UInt8(ascii: "i"):
                try expect(UInt8(ascii: ":"))
                let text = try readUntil(UInt8(ascii: ";"))
                guard isIntegerLiteral(text) else { throw DecodeError("invalid integer '\(text)'") }
                let v = JSONValue.number(text.hasPrefix("+") ? String(text.dropFirst()) : text)
                references.append(v)
                return v
            case UInt8(ascii: "d"):
                try expect(UInt8(ascii: ":"))
                let text = try readUntil(UInt8(ascii: ";"))
                let v = try double(text)
                references.append(v)
                return v
            case UInt8(ascii: "s"):
                try expect(UInt8(ascii: ":"))
                let n = try readInt(until: UInt8(ascii: ":"))
                let v = JSONValue.string(String(decoding: try quoted(length: n), as: UTF8.self))
                try expect(UInt8(ascii: ";"))
                references.append(v)
                return v
            case UInt8(ascii: "S"):
                try expect(UInt8(ascii: ":"))
                let n = try readInt(until: UInt8(ascii: ":"))
                let v = JSONValue.string(try escapedString(length: n))
                try expect(UInt8(ascii: ";"))
                references.append(v)
                return v
            case UInt8(ascii: "a"):
                try expect(UInt8(ascii: ":"))
                let n = try readInt(until: UInt8(ascii: ":"))
                let slot = references.count
                references.append(.null)
                let v = try array(count: n, depth: depth)
                references[slot] = v
                return v
            case UInt8(ascii: "O"):
                try expect(UInt8(ascii: ":"))
                let nameLength = try readInt(until: UInt8(ascii: ":"))
                let name = String(decoding: try quoted(length: nameLength), as: UTF8.self)
                try expect(UInt8(ascii: ":"))
                let n = try readInt(until: UInt8(ascii: ":"))
                let slot = references.count
                references.append(.null)
                let members = try properties(count: n, depth: depth)
                let v = JSONValue.object([JSONMember(key: classKey, value: .string(name))] + members)
                references[slot] = v
                return v
            case UInt8(ascii: "C"):
                try expect(UInt8(ascii: ":"))
                let nameLength = try readInt(until: UInt8(ascii: ":"))
                let name = String(decoding: try quoted(length: nameLength), as: UTF8.self)
                try expect(UInt8(ascii: ":"))
                let n = try readInt(until: UInt8(ascii: ":"))
                try expect(UInt8(ascii: "{"))
                guard n >= 0, index + n <= bytes.count else { throw DecodeError("custom data out of range") }
                let payload = Array(bytes[index..<index + n])
                index += n
                try expect(UInt8(ascii: "}"))
                let inner = (try? PHPSerialization.decode(payload)) ?? .string(String(decoding: payload, as: UTF8.self))
                let v = JSONValue.object([JSONMember(key: classKey, value: .string(name)), JSONMember(key: "data", value: inner)])
                references.append(v)
                return v
            case UInt8(ascii: "E"):
                try expect(UInt8(ascii: ":"))
                let n = try readInt(until: UInt8(ascii: ":"))
                let v = JSONValue.string(String(decoding: try quoted(length: n), as: UTF8.self))
                try expect(UInt8(ascii: ";"))
                references.append(v)
                return v
            case UInt8(ascii: "r"), UInt8(ascii: "R"):
                try expect(UInt8(ascii: ":"))
                let n = try readInt(until: UInt8(ascii: ";"))
                guard n >= 1, n <= references.count else { throw DecodeError("invalid reference \(n)") }
                let v = references[n - 1]
                if type == UInt8(ascii: "r") { references.append(v) }
                return v
            default:
                throw DecodeError("unknown type '\(Character(Unicode.Scalar(type)))' at offset \(index - 1)")
            }
        }

        mutating func array(count: Int, depth: Int) throws -> JSONValue {
            guard count >= 0, count <= bytes.count else { throw DecodeError("invalid array size") }
            try expect(UInt8(ascii: "{"))
            var members: [(key: JSONValue, value: JSONValue)] = []
            for _ in 0..<count {
                let key = try arrayKey()
                let value = try self.value(depth: depth + 1)
                members.append((key, value))
            }

            try expect(UInt8(ascii: "}"))
            let isList = members.enumerated().allSatisfy { i, m in
                if case .number(let n) = m.key { return n == String(i) }
                return false
            }
            if isList { return .array(members.map(\.value)) }
            return .object(members.map { JSONMember(key: Msgpack.keyText($0.key), value: $0.value) })
        }

        mutating func properties(count: Int, depth: Int) throws -> [JSONMember] {
            guard count >= 0, count <= bytes.count else { throw DecodeError("invalid property count") }
            try expect(UInt8(ascii: "{"))
            var members: [JSONMember] = []
            for _ in 0..<count {
                var key = Msgpack.keyText(try arrayKey())
                // Private "\0Class\0name" and protected "\0*\0name" property names.
                if key.hasPrefix("\u{0}"), let last = key.split(separator: "\u{0}", omittingEmptySubsequences: true).last {
                    key = String(last)
                }

                members.append(JSONMember(key: key, value: try value(depth: depth + 1)))
            }

            try expect(UInt8(ascii: "}"))
            return members
        }

        mutating func arrayKey() throws -> JSONValue {
            guard index < bytes.count else { throw DecodeError("unexpected end of data") }
            let saved = references.count
            let key: JSONValue
            switch bytes[index] {
            case UInt8(ascii: "i"), UInt8(ascii: "s"), UInt8(ascii: "S"):
                key = try value(depth: 0)
            default:
                throw DecodeError("invalid array key at offset \(index)")
            }

            references.removeLast(references.count - saved)
            return key
        }

        mutating func escapedString(length: Int) throws -> String {
            try expect(UInt8(ascii: "\""))
            var out: [UInt8] = []
            while out.count < length {
                guard index < bytes.count else { throw DecodeError("unexpected end of data") }
                if bytes[index] == UInt8(ascii: "\\"), index + 2 < bytes.count,
                   let h = hexDigit(bytes[index + 1]), let l = hexDigit(bytes[index + 2]) {
                    out.append(h << 4 | l)
                    index += 3
                } else {
                    out.append(bytes[index])
                    index += 1
                }
            }

            try expect(UInt8(ascii: "\""))
            return String(decoding: out, as: UTF8.self)
        }

        func double(_ text: String) throws -> JSONValue {
            switch text {
            case "INF": return .number("Infinity")
            case "-INF": return .number("-Infinity")
            case "NAN": return .number("NaN")
            default:
                guard let d = Double(text), d.isFinite else { throw DecodeError("invalid float '\(text)'") }
                return .double(d)
            }
        }

        func isIntegerLiteral(_ text: String) -> Bool {
            var s = Substring(text)
            if s.first == "-" || s.first == "+" { s = s.dropFirst() }
            return !s.isEmpty && s.allSatisfy { $0.isASCII && $0.isNumber }
        }
    }

    // MARK: Encoder

    static func encode(_ value: JSONValue) throws -> [UInt8] {
        var out = ""
        try write(value, into: &out)
        return Array(out.utf8)
    }

    private static func write(_ value: JSONValue, into out: inout String) throws {
        switch value {
        case .null: out += "N;"
        case .bool(let b): out += b ? "b:1;" : "b:0;"
        case .string(let s): writeString(s, into: &out)
        case .number(let text): out += numberToken(text)
        case .array(let items):
            out += "a:\(items.count):{"
            for (i, item) in items.enumerated() {
                out += "i:\(i);"
                try write(item, into: &out)
            }

            out += "}"
        case .object(let members):
            if let first = members.first, first.key == classKey, case .string(let className) = first.value {
                let props = Array(members.dropFirst())
                out += "O:\(className.utf8.count):\"\(className)\":\(props.count):{"
                for m in props {
                    writeString(m.key, into: &out)
                    try write(m.value, into: &out)
                }

                out += "}"
                return
            }

            out += "a:\(members.count):{"
            for m in members {
                if isCanonicalInteger(m.key) { out += "i:\(m.key);" } else { writeString(m.key, into: &out) }
                try write(m.value, into: &out)
            }

            out += "}"
        }
    }

    private static func writeString(_ s: String, into out: inout String) {
        out += "s:\(s.utf8.count):\"\(s)\";"
    }

    private static func isCanonicalInteger(_ s: String) -> Bool {
        guard let n = Int64(s) else { return false }
        return String(n) == s
    }

    static func numberToken(_ text: String) -> String {
        let isInteger = !text.contains(where: { ".eE".contains($0) }) && !["NaN", "Infinity", "-Infinity"].contains(text)
        if isInteger { return "i:\(text);" }
        switch text {
        case "NaN": return "d:NAN;"
        case "Infinity": return "d:INF;"
        case "-Infinity": return "d:-INF;"
        default: break
        }

        guard let d = Double(text) else { return "d:\(text);" }
        return "d:\(phpFloat(d));"
    }

    /// Uses PHP `serialize_precision = -1` style with shortest round-trip text and `1.0E+25` exponent form.
    static func phpFloat(_ d: Double) -> String {
        if d == d.rounded(), abs(d) < 1e15 { return String(Int64(d)) }
        let text = d.description
        guard let e = text.firstIndex(where: { $0 == "e" || $0 == "E" }) else { return text }
        var mantissa = String(text[..<e])
        var exponent = String(text[text.index(after: e)...])
        if !mantissa.contains(".") { mantissa += ".0" }
        if !exponent.hasPrefix("-") && !exponent.hasPrefix("+") { exponent = "+" + exponent }
        return mantissa + "E" + exponent
    }
}
