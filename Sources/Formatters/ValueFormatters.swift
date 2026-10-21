import Foundation

/// UTF-8 with replacement characters; `isValid` is `false` when the bytes are not valid UTF-8.
struct UnicodeValueFormatter: ValueFormatter {
    let format = ValueFormat.unicode

    func decode(_ data: Data, options: FormatOptions) -> FormatResult {
        let (text, valid) = TextBytes.decodeUTF8([UInt8](data))
        return .text(text, isValid: valid)
    }

    func encode(_ text: String) throws -> Data { Data(text.utf8) }
}

/// redis-cli `sdscatrepr` escaping (`\xHH`, `\n`, `\"`), reversible.
struct ASCIIValueFormatter: ValueFormatter {
    let format = ValueFormat.ascii

    func decode(_ data: Data, options: FormatOptions) -> FormatResult {
        .text(ASCIISafeEscaping.escapeBytes([UInt8](data)))
    }

    func encode(_ text: String) throws -> Data { Data(ASCIISafeEscaping.unescapeBytes(text)) }
}

struct HexValueFormatter: ValueFormatter {
    let format = ValueFormat.hex

    func decode(_ data: Data, options: FormatOptions) -> FormatResult {
        .text([UInt8](data).hexString)
    }

    func encode(_ text: String) throws -> Data {
        let digits = Array(text.utf8.filter { !isWhitespace($0) })
        guard digits.count % 2 == 0 else { throw FormatterError.invalidInput(.hex, "odd number of digits") }
        var out = Data(capacity: digits.count / 2)
        var i = 0
        while i < digits.count {
            guard let h = hexDigit(digits[i]), let l = hexDigit(digits[i + 1]) else {
                throw FormatterError.invalidInput(.hex, "invalid hex digit")
            }
            out.append(h << 4 | l)
            i += 2
        }

        return out
    }
}

struct BinaryValueFormatter: ValueFormatter {
    let format = ValueFormat.binary

    func decode(_ data: Data, options: FormatOptions) -> FormatResult {
        var out = [UInt8]()
        out.reserveCapacity(data.count * 8)
        for byte in data {
            for bit in stride(from: 7, through: 0, by: -1) {
                out.append(byte >> UInt8(bit) & 1 == 1 ? 0x31 : 0x30)
            }
        }

        return .text(String(decoding: out, as: UTF8.self))
    }

    func encode(_ text: String) throws -> Data {
        let bits = Array(text.utf8.filter { !isWhitespace($0) })
        guard bits.allSatisfy({ $0 == 0x30 || $0 == 0x31 }) else {
            throw FormatterError.invalidInput(.binary, "only 0 and 1 are allowed")
        }
        guard bits.count % 8 == 0 else { throw FormatterError.invalidInput(.binary, "bit count must be a multiple of 8") }
        var out = Data(capacity: bits.count / 8)
        var i = 0
        while i < bits.count {
            var byte: UInt8 = 0
            for k in 0..<8 { byte = byte << 1 | (bits[i + k] - 0x30) }
            out.append(byte)
            i += 8
        }

        return out
    }
}

/// Big-int-safe JSON: valid input becomes a `.json` tree; editing re-serializes compactly.
struct JSONValueFormatter: ValueFormatter {
    let format = ValueFormat.json

    func decode(_ data: Data, options: FormatOptions) -> FormatResult {
        let (text, valid) = TextBytes.decodeUTF8([UInt8](data))
        guard valid, let value = try? JSONParser.parse(text) else { return .text(text, isValid: false) }
        return .json(value)
    }

    func encode(_ text: String) throws -> Data {
        do {
            return Data(JSONPrinter.print(try JSONParser.parse(text), indent: nil).utf8)
        } catch {
            throw FormatterError.invalidInput(.json, error.localizedDescription)
        }
    }
}

struct TreeValueFormatter: ValueFormatter {
    let format: ValueFormat
    let decoder: @Sendable ([UInt8]) throws -> JSONValue
    let encoder: (@Sendable (JSONValue) throws -> [UInt8])?

    func decode(_ data: Data, options: FormatOptions) -> FormatResult {
        let bytes = [UInt8](data)
        guard let value = try? decoder(bytes) else {
            return .text(String(decoding: bytes, as: UTF8.self), isValid: false)
        }
        return .json(value)
    }

    func encode(_ text: String) throws -> Data {
        guard let encoder else { throw FormatterError.notEditable(format) }
        let value: JSONValue
        do {
            value = try JSONParser.parse(text)
        } catch {
            throw FormatterError.invalidInput(format, error.localizedDescription)
        }

        do {
            return Data(try encoder(value))
        } catch {
            throw FormatterError.invalidInput(format, String(describing: error))
        }
    }
}

/// Little-endian Float32 / Float64 arrays. Displays valid UTF-8 values as text.
struct VectorValueFormatter: ValueFormatter {
    let format: ValueFormat
    static let displayLimit = 100_000

    var width: Int { format == .vector64 ? 8 : 4 }

    func decode(_ data: Data, options: FormatOptions) -> FormatResult {
        let bytes = [UInt8](data)
        if let text = String(strictUTF8: bytes) { return .text(text) }
        let values = Self.floats(bytes, width: width)
        var text = "["
        for (i, v) in values.prefix(Self.displayLimit).enumerated() {
            if i > 0 { text += options.expanded ? ", " : "," }
            text += v
        }

        if values.count > Self.displayLimit { text += ",…" }
        text += "]"
        return .text(text)
    }

    static func floats(_ bytes: [UInt8], width: Int) -> [String] {
        var out: [String] = []
        out.reserveCapacity(bytes.count / width)
        var i = 0
        while i + width <= bytes.count {
            if width == 4 {
                let bits = UInt32(bytes[i]) | UInt32(bytes[i + 1]) << 8 | UInt32(bytes[i + 2]) << 16 | UInt32(bytes[i + 3]) << 24
                out.append(JSONNumberText.float(Float(bitPattern: bits)))
            } else {
                var bits: UInt64 = 0
                for k in stride(from: 7, through: 0, by: -1) { bits = bits << 8 | UInt64(bytes[i + k]) }
                out.append(JSONNumberText.double(Double(bitPattern: bits)))
            }

            i += width
        }

        return out
    }

    /// A JSON array of numbers becomes packed floats; any other text is stored as UTF-8 (mirrors decode).
    func encode(_ text: String) throws -> Data {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("[") else { return Data(text.utf8) }
        guard let numbers = Self.parseNumbers(trimmed) else {
            throw FormatterError.invalidInput(format, "expected an array of numbers")
        }
        var out = Data(capacity: numbers.count * width)
        for n in numbers {
            if width == 4 {
                withUnsafeBytes(of: Float(n).bitPattern.littleEndian) { out.append(contentsOf: $0) }
            } else {
                withUnsafeBytes(of: n.bitPattern.littleEndian) { out.append(contentsOf: $0) }
            }
        }

        return out
    }

    static func parseNumbers(_ text: String) -> [Double]? {
        var body = Substring(text)
        guard body.hasPrefix("["), body.hasSuffix("]") else { return nil }
        body = body.dropFirst().dropLast()
        let parts = body.split(whereSeparator: { $0 == "," || $0.isWhitespace })
        var out: [Double] = []
        out.reserveCapacity(parts.count)
        for p in parts {
            switch p {
            case "NaN": out.append(.nan)
            case "Infinity": out.append(.infinity)
            case "-Infinity": out.append(-.infinity)
            default:
                guard let d = Double(p) else { return nil }
                out.append(d)
            }
        }

        return out
    }
}

/// 10/13/16/19-digit epoch text rendered with the Settings date pattern and time zone.
struct DateTimeValueFormatter: ValueFormatter {
    let format = ValueFormat.dateTime

    func decode(_ data: Data, options: FormatOptions) -> FormatResult {
        let value = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let text = TimestampFormatter.format(value, pattern: options.dateFormat, timeZone: options.timeZone) else {
            return .text(value, isValid: false)
        }
        return .text(text)
    }

    func encode(_ text: String) throws -> Data { throw FormatterError.notEditable(format) }
}

struct MarkdownValueFormatter: ValueFormatter {
    let format = ValueFormat.markdown

    func decode(_ data: Data, options: FormatOptions) -> FormatResult {
        FormatResult(content: .markdown(String(decoding: data, as: UTF8.self)), isValid: true)
    }

    func encode(_ text: String) throws -> Data { throw FormatterError.notEditable(format) }
}

@inline(__always)
private func isWhitespace(_ b: UInt8) -> Bool {
    b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D
}
