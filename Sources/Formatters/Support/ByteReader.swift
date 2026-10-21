import Foundation

struct ByteReaderError: Error, Sendable, CustomStringConvertible {
    var description: String
    init(_ description: String) { self.description = description }
    static let truncated = ByteReaderError("unexpected end of data")
}

/// Bounds-checked cursor over a byte array; every read throws instead of trapping.
struct ByteReader {
    let bytes: [UInt8]
    var offset: Int

    init(_ bytes: [UInt8], offset: Int = 0) {
        self.bytes = bytes
        self.offset = offset
    }

    init(_ data: Data) { self.init([UInt8](data)) }

    var remaining: Int { bytes.count - offset }
    var isAtEnd: Bool { offset >= bytes.count }

    func peek() throws -> UInt8 {
        guard offset < bytes.count else { throw ByteReaderError.truncated }
        return bytes[offset]
    }

    mutating func u8() throws -> UInt8 {
        guard offset < bytes.count else { throw ByteReaderError.truncated }
        defer { offset += 1 }
        return bytes[offset]
    }

    mutating func read(_ count: Int) throws -> [UInt8] {
        guard count >= 0, count <= remaining else { throw ByteReaderError.truncated }
        defer { offset += count }
        return Array(bytes[offset..<offset + count])
    }

    mutating func skip(_ count: Int) throws {
        guard count >= 0, count <= remaining else { throw ByteReaderError.truncated }
        offset += count
    }

    mutating func uintBE(_ size: Int) throws -> UInt64 {
        guard size <= remaining else { throw ByteReaderError.truncated }
        var v: UInt64 = 0
        for i in 0..<size { v = v << 8 | UInt64(bytes[offset + i]) }
        offset += size
        return v
    }

    mutating func uintLE(_ size: Int) throws -> UInt64 {
        guard size <= remaining else { throw ByteReaderError.truncated }
        var v: UInt64 = 0
        for i in stride(from: size - 1, through: 0, by: -1) { v = v << 8 | UInt64(bytes[offset + i]) }
        offset += size
        return v
    }

    mutating func u16BE() throws -> UInt16 { UInt16(try uintBE(2)) }
    mutating func u32BE() throws -> UInt32 { UInt32(try uintBE(4)) }
    mutating func u64BE() throws -> UInt64 { try uintBE(8) }
    mutating func u16LE() throws -> UInt16 { UInt16(try uintLE(2)) }
    mutating func u32LE() throws -> UInt32 { UInt32(try uintLE(4)) }
    mutating func u64LE() throws -> UInt64 { try uintLE(8) }

    /// Reads up to the next `\n` (excluded) and consumes the newline.
    mutating func line() throws -> [UInt8] {
        guard let end = bytes[offset...].firstIndex(of: 0x0A) else { throw ByteReaderError.truncated }
        defer { offset = end + 1 }
        return Array(bytes[offset..<end])
    }
}

/// Arbitrary-precision integer to decimal text, for Pickle LONG, Java BigInteger, etc.
enum BigIntText {
    /// Little-endian two's-complement bytes (Python `LONG1` / `LONG4`).
    static func fromTwosComplementLE(_ bytes: [UInt8]) -> String {
        guard !bytes.isEmpty else { return "0" }
        let negative = (bytes.last ?? 0) & 0x80 != 0
        var magnitude = bytes
        if negative {
            var carry = 1
            for i in magnitude.indices {
                let v = Int(~magnitude[i]) + carry
                magnitude[i] = UInt8(v & 0xFF)
                carry = v >> 8
            }
        }

        return fromMagnitude(bigEndian: magnitude.reversed(), negative: negative)
    }

    /// Big-endian two's-complement bytes (Java `BigInteger.toByteArray`).
    static func fromTwosComplementBE(_ bytes: [UInt8]) -> String {
        fromTwosComplementLE(bytes.reversed())
    }

    /// Limits decimal output to about 39,000 digits. Uses `0x…` hex for larger values because conversion is quadratic.
    static let maxDecimalBytes = 16_384

    static func fromMagnitude(bigEndian bytes: [UInt8], negative: Bool) -> String {
        let magnitude = Array(bytes.drop(while: { $0 == 0 }))
        if magnitude.isEmpty { return "0" }
        let sign = negative ? "-" : ""
        guard magnitude.count <= maxDecimalBytes else { return sign + "0x" + magnitude.hexString }

        // Base 2^32 limbs, most significant first; each pass divides by 10^9 and yields nine digits.
        var limbs: [UInt32] = []
        limbs.reserveCapacity(magnitude.count / 4 + 1)
        let head = magnitude.count % 4
        var index = 0
        if head > 0 {
            limbs.append(magnitude[0..<head].reduce(0) { $0 << 8 | UInt32($1) })
            index = head
        }

        while index < magnitude.count {
            limbs.append(magnitude[index..<index + 4].reduce(0) { $0 << 8 | UInt32($1) })
            index += 4
        }

        let base: UInt64 = 1_000_000_000
        var chunks: [UInt32] = []
        var start = 0
        while start < limbs.count {
            var remainder: UInt64 = 0
            for i in start..<limbs.count {
                let current = remainder << 32 | UInt64(limbs[i])
                limbs[i] = UInt32(current / base)
                remainder = current % base
            }

            chunks.append(UInt32(remainder))
            while start < limbs.count, limbs[start] == 0 { start += 1 }
        }

        var text = sign + String(chunks.last ?? 0)
        for chunk in chunks.dropLast().reversed() {
            let part = String(chunk)
            text += String(repeating: "0", count: 9 - part.count) + part
        }

        return text
    }

    /// Most zeros `applyScale` pads with before it switches to exponent notation.
    static let maxScalePadding = 1_000

    /// Inserts the decimal point `scale` digits from the right for Java `BigDecimal`.
    /// If padding exceeds `maxScalePadding` zeros, writes the exact value as `<integer>E<-scale>` (`123E-1000000`).
    static func applyScale(_ integer: String, scale: Int) -> String {
        guard scale != 0 else { return integer }
        let negative = integer.hasPrefix("-")
        var digits = negative ? String(integer.dropFirst()) : integer
        if scale < 0 {
            if digits == "0" { return "0" }
            guard scale.magnitude <= UInt(maxScalePadding) else { return integer + "E" + String(scale.magnitude) }
            digits += String(repeating: "0", count: Int(scale.magnitude))
        } else {
            if digits.count <= scale {
                let padding = scale - digits.count + 1
                guard padding <= maxScalePadding else { return integer + "E-" + String(scale) }
                digits = String(repeating: "0", count: padding) + digits
            }

            digits.insert(".", at: digits.index(digits.endIndex, offsetBy: -scale))
        }

        return negative ? "-" + digits : digits
    }
}

extension Array where Element == UInt8 {
    /// Copies an LZ77 match from `distance` bytes back. If `distance < length`, overlapping output repeats those bytes.
    mutating func appendBackReference(distance: Int, length: Int) {
        guard length > 0, distance > 0, distance <= count else { return }
        let source = count - distance
        let destination = count
        append(contentsOf: repeatElement(0, count: length))
        withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            var copied = 0
            while copied < length {
                let chunk = Swift.min(distance, length - copied)
                (base + destination + copied).update(from: base + source + copied, count: chunk)
                copied += chunk
            }
        }
    }

    var hexString: String {
        let table = [Character]("0123456789abcdef")
        var s = ""
        s.reserveCapacity(count * 2)
        for b in self {
            s.append(table[Int(b >> 4)])
            s.append(table[Int(b & 0x0F)])
        }

        return s
    }
}

enum TextBytes {
    static func decodeUTF8(_ bytes: [UInt8]) -> (text: String, isValid: Bool) {
        if let s = String(strictUTF8: bytes) { return (s, true) }
        let s = String(decoding: bytes, as: UTF8.self)
        return (s, false)
    }

    /// Returns valid printable UTF-8 text or redis-cli `\xHH` escapes.
    static func displayString(_ bytes: [UInt8]) -> String {
        if let s = String(strictUTF8: bytes), !s.unicodeScalars.contains(where: isControl) { return s }
        return ASCIISafeEscaping.escapeBytes(bytes)
    }

    static func isControl(_ scalar: Unicode.Scalar) -> Bool {
        (scalar.value < 0x20 && scalar != "\n" && scalar != "\r" && scalar != "\t") || scalar.value == 0x7F
    }
}

extension String {
    /// Strict UTF-8 validation (no replacement characters), embedded NULs allowed.
    init?(strictUTF8 bytes: [UInt8]) {
        guard let s = String(validating: bytes, as: UTF8.self) else { return nil }
        self = s
    }
}
