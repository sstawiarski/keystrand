import Foundation

/// MATCH filters accept `\xHH` for byte 0xHH so keys and members with invalid UTF-8 can be found.
public extension KeyPattern {
    private static let globBytes: Set<UInt8> = [0x2A, 0x3F, 0x5B, 0x5D, 0x5C]

    /// MATCH argument for `pattern`: `\xHH` becomes the byte (escaped when it is a glob character), everything else
    /// keeps its glob meaning and its UTF-8 bytes.
    static func matchBytes(_ pattern: String) -> Data {
        var out: [UInt8] = []
        forEachToken(pattern) { token in
            switch token {
            case .hexByte(let byte):
                if globBytes.contains(byte) { out.append(0x5C) }
                out.append(byte)
            case .escaped(let byte):
                out += [0x5C, byte]
            case .plain(let byte):
                out.append(byte)
            }
        }
        return Data(out)
    }

    /// The name a pattern without glob characters stands for: `\xHH` and `\*`-style escapes resolved.
    static func literalBytes(_ pattern: String) -> Data {
        var out: [UInt8] = []
        forEachToken(pattern) { token in
            switch token {
            case .hexByte(let byte):
                out.append(byte)
            case .escaped(let byte):
                if !globBytes.contains(byte) { out.append(0x5C) }
                out.append(byte)
            case .plain(let byte):
                out.append(byte)
            }
        }
        return Data(out)
    }

    /// A filter typed while key names are shown as HEX: hex digit pairs are bytes (written as `\xHH`), `*`, `?`,
    /// `[`, `]` and `-` keep their glob meaning, spaces are ignored. Nil when the text is not hex.
    static func fromHexFilter(_ text: String) -> String? {
        var out = ""
        var pending: Character?
        for character in text where character != " " {
            if "*?[]-".contains(character) {
                guard pending == nil else { return nil }
                out.append(character)
            } else if character.isHexDigit, character.isASCII {
                if let high = pending {
                    out += "\\x" + String(high) + String(character)
                    pending = nil
                } else {
                    pending = character
                }
            } else {
                return nil
            }
        }

        return pending == nil ? out : nil
    }

    private enum Token {
        case hexByte(UInt8)
        case escaped(UInt8)
        case plain(UInt8)
    }

    private static func forEachToken(_ pattern: String, _ body: (Token) -> Void) {
        let bytes = Array(pattern.utf8)
        var i = 0
        while i < bytes.count {
            if bytes[i] == 0x5C, i + 1 < bytes.count {
                if bytes[i + 1] == UInt8(ascii: "x"), i + 3 < bytes.count,
                   let high = hexValue(bytes[i + 2]), let low = hexValue(bytes[i + 3]) {
                    body(.hexByte(high << 4 | low))
                    i += 4
                } else {
                    body(.escaped(bytes[i + 1]))
                    i += 2
                }

                continue
            }

            body(.plain(bytes[i]))
            i += 1
        }
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 0x30...0x39: return byte - 0x30
        case 0x41...0x46: return byte - 0x37
        case 0x61...0x66: return byte - 0x57
        default: return nil
        }
    }
}
