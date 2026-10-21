import Foundation

/// Snappy raw block and framing formats (`ff 06 00 00 sNaPpY`).
enum Snappy {
    static let streamIdentifier: [UInt8] = [0xFF, 0x06, 0x00, 0x00, 0x73, 0x4E, 0x61, 0x50, 0x70, 0x59]

    static func decompress(_ input: [UInt8]) throws -> [UInt8] {
        if input.starts(with: streamIdentifier) { return try decodeFramed(input) }
        return try decodeRaw(input, range: 0..<input.count)
    }

    static func decodeRaw(_ input: [UInt8], range: Range<Int>) throws -> [UInt8] {
        var i = range.lowerBound
        let end = range.upperBound
        var length = 0
        var shift = 0
        while true {
            guard i < end, shift <= 28 else { throw ByteReaderError("bad Snappy length") }
            let b = input[i]
            i += 1
            length |= Int(b & 0x7F) << shift
            if b & 0x80 == 0 { break }
            shift += 7
        }

        guard length <= LZ4.maxOutput else { throw ByteReaderError("Snappy output too large") }
        var out: [UInt8] = []
        out.reserveCapacity(length)
        while i < end {
            let tag = input[i]
            i += 1
            switch tag & 0x03 {
            case 0:
                var n = Int(tag >> 2)
                if n >= 60 {
                    let extra = n - 59
                    guard i + extra <= end else { throw ByteReaderError.truncated }
                    n = 0
                    for k in 0..<extra { n |= Int(input[i + k]) << (8 * k) }
                    i += extra
                }

                n += 1
                guard n <= end - i, out.count + n <= length else { throw ByteReaderError("Snappy literal out of range") }
                out.append(contentsOf: input[i..<i + n])
                i += n
            case 1:
                guard i < end else { throw ByteReaderError.truncated }
                let n = 4 + Int((tag >> 2) & 0x07)
                let offset = Int(tag >> 5) << 8 | Int(input[i])
                i += 1
                try copy(&out, offset: offset, length: n, limit: length)
            case 2:
                guard i + 2 <= end else { throw ByteReaderError.truncated }
                let n = 1 + Int(tag >> 2)
                let offset = Int(input[i]) | Int(input[i + 1]) << 8
                i += 2
                try copy(&out, offset: offset, length: n, limit: length)
            default:
                guard i + 4 <= end else { throw ByteReaderError.truncated }
                let n = 1 + Int(tag >> 2)
                let offset = Int(input[i]) | Int(input[i + 1]) << 8 | Int(input[i + 2]) << 16 | Int(input[i + 3]) << 24
                i += 4
                try copy(&out, offset: offset, length: n, limit: length)
            }
        }

        guard out.count == length else { throw ByteReaderError("Snappy length mismatch") }
        return out
    }

    private static func copy(_ out: inout [UInt8], offset: Int, length: Int, limit: Int) throws {
        guard offset > 0, offset <= out.count, out.count + length <= limit else {
            throw ByteReaderError("Snappy copy out of range")
        }
        out.appendBackReference(distance: offset, length: length)
    }

    static func decodeFramed(_ input: [UInt8]) throws -> [UInt8] {
        var r = ByteReader(input)
        var out: [UInt8] = []
        while !r.isAtEnd {
            let type = try r.u8()
            let length = Int(try r.uintLE(3))
            guard length <= r.remaining else { throw ByteReaderError.truncated }
            switch type {
            case 0x00:
                guard length >= 4 else { throw ByteReaderError.truncated }
                out += try decodeRaw(r.bytes, range: r.offset + 4..<r.offset + length)
            case 0x01:
                guard length >= 4 else { throw ByteReaderError.truncated }
                out += r.bytes[r.offset + 4..<r.offset + length]
            case 0xFF, 0x80...0xFE:
                break
            default:
                throw ByteReaderError("unknown Snappy chunk type")
            }

            try r.skip(length)
        }

        return out
    }

    /// Valid raw Snappy stream made only of literals.
    static func encodeRaw(_ input: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        var n = input.count
        repeat {
            var b = UInt8(n & 0x7F)
            n >>= 7
            if n > 0 { b |= 0x80 }
            out.append(b)
        } while n > 0

        var i = 0
        let chunk = 65536
        while i < input.count {
            let len = min(chunk, input.count - i)
            let m = len - 1
            if m < 60 {
                out.append(UInt8(m << 2))
            } else if m < 256 {
                out += [60 << 2, UInt8(m)]
            } else {
                out += [61 << 2, UInt8(m & 0xFF), UInt8(m >> 8)]
            }

            out += input[i..<i + len]
            i += len
        }

        return out
    }
}
