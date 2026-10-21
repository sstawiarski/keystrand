import Foundation

/// Decodes protobuf without a schema as single-key objects, such as `[{"1": 150}, {"2": [{"1": "nested"}]}]`.
/// Varints and fixed64 fields become unsigned 64-bit values; fixed32 fields become floats.
/// Length-delimited fields become printable UTF-8 text, a valid nested message, or text with `\xHH` escapes, in that order.
enum Protobuf {
    struct DecodeError: Error, CustomStringConvertible {
        var description: String
        init(_ d: String) { description = d }
    }

    static func decode(_ bytes: [UInt8]) throws -> JSONValue {
        guard !bytes.isEmpty else { throw DecodeError("empty message") }
        return .array(try message(bytes, range: 0..<bytes.count, depth: 0))
    }

    private static func message(_ bytes: [UInt8], range: Range<Int>, depth: Int) throws -> [JSONValue] {
        guard depth < 64 else { throw DecodeError("nesting too deep") }
        var i = range.lowerBound
        let end = range.upperBound
        var fields: [JSONValue] = []
        while i < end {
            let tag = try varint(bytes, &i, end)
            let field = tag >> 3
            let wire = Int(tag & 7)
            guard field >= 1, field <= 536_870_911 else { throw DecodeError("invalid field number") }
            let key = String(field)
            let value: JSONValue
            switch wire {
            case 0:
                value = .integer(try varint(bytes, &i, end))
            case 1:
                guard i + 8 <= end else { throw ByteReaderError.truncated }
                var v: UInt64 = 0
                for k in stride(from: 7, through: 0, by: -1) { v = v << 8 | UInt64(bytes[i + k]) }
                i += 8
                value = .integer(v)
            case 2:
                let length = try varint(bytes, &i, end)
                guard length <= UInt64(end - i) else { throw ByteReaderError.truncated }
                let n = Int(length)
                value = lengthDelimited(bytes, range: i..<i + n, depth: depth)
                i += n
            case 5:
                guard i + 4 <= end else { throw ByteReaderError.truncated }
                let bits = UInt32(bytes[i]) | UInt32(bytes[i + 1]) << 8 | UInt32(bytes[i + 2]) << 16 | UInt32(bytes[i + 3]) << 24
                i += 4
                value = .float(Float(bitPattern: bits))
            case 3:
                // Start group: decode until the matching end-group tag.
                let groupStart = i
                var groupEnd = i
                var nesting = 1
                while nesting > 0 {
                    groupEnd = i
                    guard i < end else { throw ByteReaderError.truncated }
                    let t = try varint(bytes, &i, end)
                    switch t & 7 {
                    case 0: _ = try varint(bytes, &i, end)
                    case 1:
                        guard end - i >= 8 else { throw ByteReaderError.truncated }
                        i += 8
                    case 2:
                        let length = try varint(bytes, &i, end)
                        guard length <= UInt64(end - i) else { throw ByteReaderError.truncated }
                        i += Int(length)
                    case 3: nesting += 1
                    case 4: nesting -= 1
                    case 5:
                        guard end - i >= 4 else { throw ByteReaderError.truncated }
                        i += 4
                    default: throw DecodeError("invalid wire type")
                    }
                }

                value = .array(try message(bytes, range: groupStart..<groupEnd, depth: depth + 1))
            default:
                throw DecodeError("invalid wire type \(wire)")
            }

            fields.append(.object([JSONMember(key: key, value: value)]))
        }

        return fields
    }

    private static func lengthDelimited(_ bytes: [UInt8], range: Range<Int>, depth: Int) -> JSONValue {
        let slice = Array(bytes[range])
        if let text = String(strictUTF8: slice), !text.unicodeScalars.contains(where: TextBytes.isControl) {
            return .string(text)
        }

        if let nested = try? message(bytes, range: range, depth: depth + 1) {
            return .array(nested)
        }

        return .string(TextBytes.displayString(slice))
    }

    private static func varint(_ bytes: [UInt8], _ i: inout Int, _ end: Int) throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            guard i < end else { throw ByteReaderError.truncated }
            guard shift < 64 else { throw DecodeError("varint too long") }
            let b = bytes[i]
            i += 1
            result |= UInt64(b & 0x7F) << shift
            if b & 0x80 == 0 { return result }
            shift += 7
        }
    }
}
