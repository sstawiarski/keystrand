import Foundation

/// Converts MessagePack to and from `JSONValue`, including MessagePack-CSharp LZ4 extensions 98 (`Lz4BlockArray`) and 99 (`Lz4Block`).
enum Msgpack {
    struct DecodeError: Error, CustomStringConvertible {
        var description: String
        init(_ d: String) { description = d }
    }

    static let lz4BlockArrayType: Int8 = 98
    static let lz4BlockType: Int8 = 99
    static let maxUncompressedSize = 100_000_000

    /// Decodes exactly one value spanning all of `bytes`.
    static func decode(_ bytes: [UInt8]) throws -> JSONValue {
        var reader = ByteReader(bytes)
        let value = try decodeValue(&reader, depth: 0)
        guard reader.isAtEnd else { throw DecodeError("unexpected trailing bytes") }
        return try resolve(value, depth: 0)
    }

    // MARK: Intermediate tree (keeps bin/ext distinct until LZ4 post-processing)

    indirect enum Node {
        case value(JSONValue)
        case binary([UInt8])
        case ext(Int8, [UInt8])
        case array([Node])
        case map([(Node, Node)])
    }

    private static func decodeValue(_ r: inout ByteReader, depth: Int) throws -> Node {
        guard depth < 300 else { throw DecodeError("nesting too deep") }
        let b = try r.u8()
        switch b {
        case 0x00...0x7F: return .value(.integer(b))
        case 0x80...0x8F: return try map(&r, count: Int(b & 0x0F), depth: depth)
        case 0x90...0x9F: return try array(&r, count: Int(b & 0x0F), depth: depth)
        case 0xA0...0xBF: return .value(.string(try string(&r, count: Int(b & 0x1F))))
        case 0xC0: return .value(.null)
        case 0xC2: return .value(.bool(false))
        case 0xC3: return .value(.bool(true))
        case 0xC4: return .binary(try r.read(Int(try r.u8())))
        case 0xC5: return .binary(try r.read(Int(try r.u16BE())))
        case 0xC6: return .binary(try r.read(Int(try r.u32BE())))
        case 0xC7: let n = Int(try r.u8()); return try ext(&r, count: n)
        case 0xC8: let n = Int(try r.u16BE()); return try ext(&r, count: n)
        case 0xC9: let n = Int(try r.u32BE()); return try ext(&r, count: n)
        case 0xCA: return .value(.float(Float(bitPattern: try r.u32BE())))
        case 0xCB: return .value(.double(Double(bitPattern: try r.u64BE())))
        case 0xCC: return .value(.integer(try r.u8()))
        case 0xCD: return .value(.integer(try r.u16BE()))
        case 0xCE: return .value(.integer(try r.u32BE()))
        case 0xCF: return .value(.integer(try r.u64BE()))
        case 0xD0: return .value(.integer(Int8(bitPattern: try r.u8())))
        case 0xD1: return .value(.integer(Int16(bitPattern: try r.u16BE())))
        case 0xD2: return .value(.integer(Int32(bitPattern: try r.u32BE())))
        case 0xD3: return .value(.integer(Int64(bitPattern: try r.u64BE())))
        case 0xD4: return try ext(&r, count: 1)
        case 0xD5: return try ext(&r, count: 2)
        case 0xD6: return try ext(&r, count: 4)
        case 0xD7: return try ext(&r, count: 8)
        case 0xD8: return try ext(&r, count: 16)
        case 0xD9: return .value(.string(try string(&r, count: Int(try r.u8()))))
        case 0xDA: return .value(.string(try string(&r, count: Int(try r.u16BE()))))
        case 0xDB: return .value(.string(try string(&r, count: Int(try r.u32BE()))))
        case 0xDC: return try array(&r, count: Int(try r.u16BE()), depth: depth)
        case 0xDD: return try array(&r, count: Int(try r.u32BE()), depth: depth)
        case 0xDE: return try map(&r, count: Int(try r.u16BE()), depth: depth)
        case 0xDF: return try map(&r, count: Int(try r.u32BE()), depth: depth)
        case 0xE0...0xFF: return .value(.integer(Int8(bitPattern: b)))
        default: throw DecodeError("invalid byte 0x\(String(b, radix: 16))")
        }
    }

    private static func string(_ r: inout ByteReader, count: Int) throws -> String {
        let bytes = try r.read(count)
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func ext(_ r: inout ByteReader, count: Int) throws -> Node {
        let type = Int8(bitPattern: try r.u8())
        return .ext(type, try r.read(count))
    }

    private static func array(_ r: inout ByteReader, count: Int, depth: Int) throws -> Node {
        guard count <= r.remaining else { throw ByteReaderError.truncated }
        var items: [Node] = []
        items.reserveCapacity(count)
        for _ in 0..<count { items.append(try decodeValue(&r, depth: depth + 1)) }
        return .array(items)
    }

    private static func map(_ r: inout ByteReader, count: Int, depth: Int) throws -> Node {
        guard count * 2 <= r.remaining else { throw ByteReaderError.truncated }
        var pairs: [(Node, Node)] = []
        pairs.reserveCapacity(count)
        for _ in 0..<count {
            let k = try decodeValue(&r, depth: depth + 1)
            let v = try decodeValue(&r, depth: depth + 1)
            pairs.append((k, v))
        }

        return .map(pairs)
    }

    // MARK: Post-processing (LZ4 extensions, JSON mapping)

    private static func resolve(_ node: Node, depth: Int) throws -> JSONValue {
        guard depth < 64 else { throw DecodeError("LZ4 nesting too deep") }
        switch node {
        case .value(let v):
            return v
        case .binary(let bytes):
            return .string(TextBytes.displayString(bytes))
        case .ext(let type, let payload):
            if type == lz4BlockType || type == lz4BlockArrayType, let inline = inlineLZ4(payload) {
                return try decode(lz4Bytes: LZ4.decodeBlock(inline.data, expectedSize: inline.size), depth: depth)
            }

            return extValue(type, payload)
        case .array(let items):
            if items.count >= 2, case .ext(lz4BlockArrayType, let payload) = items[0] {
                let sizes = blockSizes(payload)
                let blocks = items.dropFirst().compactMap { item -> [UInt8]? in
                    if case .binary(let b) = item { return b }
                    return nil
                }
                if !sizes.isEmpty, sizes.count == blocks.count, blocks.count == items.count - 1 {
                    var out: [UInt8] = []
                    for (size, block) in zip(sizes, blocks) {
                        out += try LZ4.decodeBlock(block, expectedSize: size)
                    }

                    return try decode(lz4Bytes: out, depth: depth)
                }
            }

            return .array(try items.map { try resolve($0, depth: depth) })
        case .map(let pairs):
            return .object(try pairs.map { k, v in
                JSONMember(key: try keyText(resolve(k, depth: depth)), value: try resolve(v, depth: depth))
            })
        }
    }

    private static func decode(lz4Bytes: [UInt8], depth: Int) throws -> JSONValue {
        var reader = ByteReader(lz4Bytes)
        let value = try decodeValue(&reader, depth: 0)
        return try resolve(value, depth: depth + 1)
    }

    private static func validSize(_ size: Int) -> Bool { size > 0 && size < maxUncompressedSize }

    /// Extension payload contains a big-endian int32 uncompressed size followed by an LZ4 block.
    private static func inlineLZ4(_ payload: [UInt8]) -> (size: Int, data: [UInt8])? {
        guard payload.count >= 5 else { return nil }
        let size = Int(Int32(bitPattern: UInt32(payload[0]) << 24 | UInt32(payload[1]) << 16 | UInt32(payload[2]) << 8 | UInt32(payload[3])))
        guard validSize(size) else { return nil }
        return (size, Array(payload[4...]))
    }

    /// Extension 98 stores each block’s uncompressed size as a MessagePack integer.
    private static func blockSizes(_ payload: [UInt8]) -> [Int] {
        var r = ByteReader(payload)
        var sizes: [Int] = []
        while !r.isAtEnd {
            guard let node = try? decodeValue(&r, depth: 0), case .value(.number(let text)) = node,
                  let size = Int(text), validSize(size) else { return [] }
            sizes.append(size)
        }

        return sizes
    }

    private static func extValue(_ type: Int8, _ payload: [UInt8]) -> JSONValue {
        if type == -1, let date = timestamp(payload) {
            return .string(date)
        }

        return .object([
            JSONMember(key: "type", value: .integer(type)),
            JSONMember(key: "data", value: .string(payload.hexString)),
        ])
    }

    /// Msgpack timestamp extension (-1) as ISO 8601 UTC.
    private static func timestamp(_ p: [UInt8]) -> String? {
        var r = ByteReader(p)
        let seconds: Int64
        var nanos: UInt32 = 0
        switch p.count {
        case 4:
            guard let s = try? r.u32BE() else { return nil }
            seconds = Int64(s)
        case 8:
            guard let v = try? r.u64BE() else { return nil }
            nanos = UInt32(v >> 34)
            seconds = Int64(v & 0x3_FFFF_FFFF)
        case 12:
            guard let n = try? r.u32BE(), let s = try? r.u64BE() else { return nil }
            nanos = n
            seconds = Int64(bitPattern: s)
        default:
            return nil
        }

        let date = Date(timeIntervalSince1970: Double(seconds) + Double(nanos) / 1e9)
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: date)
    }

    static func keyText(_ v: JSONValue) -> String {
        switch v {
        case .string(let s): return s
        case .number(let n): return n
        case .bool(let b): return b ? "true" : "false"
        case .null: return "null"
        case .array, .object: return v.compactText
        }
    }

    // MARK: Encoder

    static func encode(_ value: JSONValue) throws -> [UInt8] {
        var out: [UInt8] = []
        try write(value, into: &out)
        return out
    }

    private static func write(_ value: JSONValue, into out: inout [UInt8]) throws {
        switch value {
        case .null: out.append(0xC0)
        case .bool(let b): out.append(b ? 0xC3 : 0xC2)
        case .string(let s): writeString(s, into: &out)
        case .number(let text): try writeNumber(text, into: &out)
        case .array(let items):
            writeHeader(items.count, fix: 0x90, fixMax: 15, b16: 0xDC, b32: 0xDD, into: &out)
            for item in items { try write(item, into: &out) }
        case .object(let members):
            writeHeader(members.count, fix: 0x80, fixMax: 15, b16: 0xDE, b32: 0xDF, into: &out)
            for m in members {
                writeString(m.key, into: &out)
                try write(m.value, into: &out)
            }
        }
    }

    private static func writeHeader(_ n: Int, fix: UInt8, fixMax: Int, b16: UInt8, b32: UInt8, into out: inout [UInt8]) {
        if n <= fixMax {
            out.append(fix | UInt8(n))
        } else if n <= 0xFFFF {
            out.append(b16)
            appendBE(UInt64(n), 2, &out)
        } else {
            out.append(b32)
            appendBE(UInt64(n), 4, &out)
        }
    }

    private static func writeString(_ s: String, into out: inout [UInt8]) {
        let bytes = Array(s.utf8)
        let n = bytes.count
        if n < 32 {
            out.append(0xA0 | UInt8(n))
        } else if n <= 0xFF {
            out += [0xD9, UInt8(n)]
        } else if n <= 0xFFFF {
            out.append(0xDA)
            appendBE(UInt64(n), 2, &out)
        } else {
            out.append(0xDB)
            appendBE(UInt64(n), 4, &out)
        }

        out += bytes
    }

    private static func writeNumber(_ text: String, into out: inout [UInt8]) throws {
        if let i = Int64(text) {
            writeInt(i, into: &out)
            return
        }

        if let u = UInt64(text) {
            out.append(0xCF)
            appendBE(u, 8, &out)
            return
        }

        let d: Double
        switch text {
        case "NaN": d = .nan
        case "Infinity": d = .infinity
        case "-Infinity": d = -.infinity
        default:
            guard let parsed = Double(text) else { throw DecodeError("invalid number \(text)") }
            d = parsed
        }

        if d.isFinite, d == d.rounded(), abs(d) < 9_007_199_254_740_992 {
            writeInt(Int64(d), into: &out)
            return
        }

        out.append(0xCB)
        appendBE(d.bitPattern, 8, &out)
    }

    private static func writeInt(_ i: Int64, into out: inout [UInt8]) {
        switch i {
        case 0...0x7F: out.append(UInt8(i))
        case -32 ..< 0: out.append(UInt8(bitPattern: Int8(i)))
        case 0x80...0xFF: out += [0xCC, UInt8(i)]
        case 0x100...0xFFFF: out.append(0xCD); appendBE(UInt64(i), 2, &out)
        case 0x10000...0xFFFF_FFFF: out.append(0xCE); appendBE(UInt64(i), 4, &out)
        case Int64(Int8.min) ..< -32: out += [0xD0, UInt8(bitPattern: Int8(i))]
        case Int64(Int16.min) ..< Int64(Int8.min): out.append(0xD1); appendBE(UInt64(UInt16(bitPattern: Int16(i))), 2, &out)
        case Int64(Int32.min) ..< Int64(Int16.min): out.append(0xD2); appendBE(UInt64(UInt32(bitPattern: Int32(i))), 4, &out)
        case ..<Int64(Int32.min): out.append(0xD3); appendBE(UInt64(bitPattern: i), 8, &out)
        default: out.append(0xCF); appendBE(UInt64(i), 8, &out)
        }
    }

    private static func appendBE(_ v: UInt64, _ size: Int, _ out: inout [UInt8]) {
        for k in stride(from: size - 1, through: 0, by: -1) { out.append(UInt8((v >> (8 * UInt64(k))) & 0xFF)) }
    }
}
