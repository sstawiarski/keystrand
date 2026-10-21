import Foundation
import RESP

public protocol ValueFormatter: Sendable {
    var format: ValueFormat { get }
    /// Decodes bytes for display. Never throws; invalid input returns `isValid == false` with lossy text.
    func decode(_ data: Data, options: FormatOptions) -> FormatResult
    /// Encodes edited text. Throws `FormatterError.notEditable` for read-only formats or `FormatterError.invalidInput` for invalid text.
    func encode(_ text: String) throws -> Data
}

public extension ValueFormatter {
    var isEditable: Bool { format.isEditable }
}

/// Looks up formatters, decompresses values and serializes edits.
public enum FormatterRegistry {
    public static func formatter(for format: ValueFormat) -> any ValueFormatter {
        switch format {
        case .unicode: return UnicodeValueFormatter()
        case .ascii: return ASCIIValueFormatter()
        case .hex: return HexValueFormatter()
        case .binary: return BinaryValueFormatter()
        case .json: return JSONValueFormatter()
        case .msgpack:
            return TreeValueFormatter(format: .msgpack, decoder: { try Msgpack.decode($0) }, encoder: { try Msgpack.encode($0) })
        case .php:
            return TreeValueFormatter(format: .php, decoder: { try PHPSerialization.decode($0) },
                                      encoder: { try PHPSerialization.encode($0) })
        case .java:
            return TreeValueFormatter(format: .java, decoder: { try JavaSerialization.decode($0) }, encoder: nil)
        case .protobuf:
            return TreeValueFormatter(format: .protobuf, decoder: { try Protobuf.decode($0) }, encoder: nil)
        case .pickle:
            return TreeValueFormatter(format: .pickle, decoder: { try Pickle.decode($0) }, encoder: nil)
        case .vector32, .vector64: return VectorValueFormatter(format: format)
        case .dateTime: return DateTimeValueFormatter()
        case .markdown: return MarkdownValueFormatter()
        }
    }

    /// Decompresses (when `compressor != .none`, or by magic bytes when `options.autoDecompress`) and decodes.
    public static func format(_ data: Data, as format: ValueFormat, compressor: Compressor = .none,
                              options: FormatOptions = FormatOptions()) -> FormatResult {
        let auto = options.autoDecompress
        let decompressed = decompress(data, compressor: compressor, auto: auto)
        var result = formatter(for: format).decode(decompressed.value, options: options)
        result.isCompressed = decompressed.isCompressed
        result.compressionError = decompressed.error
        result.detectedCompressor = detectedCompressor(decompressed, data: data, compressor: compressor, auto: auto)
        return result
    }

    /// Guesses JSON objects/arrays, then printable UTF-8, then HEX. Detects compression by magic bytes if `compressor` is `.none`.
    public static func bestGuess(_ data: Data, compressor: Compressor = .none,
                                 options: FormatOptions = FormatOptions()) -> (format: ValueFormat, result: FormatResult) {
        let decompressed = decompress(data, compressor: compressor, auto: true)
        let format = guessFormat(decompressed.value)
        var result = formatter(for: format).decode(decompressed.value, options: options)
        result.isCompressed = decompressed.isCompressed
        result.compressionError = decompressed.error
        result.detectedCompressor = detectedCompressor(decompressed, data: data, compressor: compressor, auto: true)
        return (format, result)
    }

    /// The format `bestGuess` would pick for already-decompressed bytes.
    public static func guessFormat(_ data: Data) -> ValueFormat {
        let bytes = [UInt8](data)
        guard let text = String(strictUTF8: bytes) else { return .hex }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = trimmed.first, first == "{" || first == "[", (try? JSONParser.parse(trimmed)) != nil {
            return .json
        }

        if text.unicodeScalars.contains(where: TextBytes.isControl) { return .hex }
        return .unicode
    }

    /// Text placed in an editor when the user starts editing (JSON pretty-printed with 4 spaces, etc.).
    public static func serializeForEdit(_ data: Data, as format: ValueFormat, compressor: Compressor = .none) -> String {
        serializeForEdit(data, as: format, compressor: compressor, indent: 4)
    }

    public static func serializeForEdit(_ data: Data, as format: ValueFormat, compressor: Compressor = .none, indent: Int) -> String {
        let result = FormatterRegistry.format(data, as: format, compressor: compressor, options: FormatOptions(expanded: true))
        guard result.isValid else {
            return String(decoding: Decompressor.decompress(data, using: compressor).value, as: UTF8.self)
        }
        return result.displayText(expanded: true, indent: indent)
    }

    /// Encodes edited text and re-compresses it with `compressor`. Throws for read-only formats or invalid text.
    public static func parseEdited(_ text: String, as format: ValueFormat, compressor: Compressor = .none) throws -> Data {
        let encoded = try formatter(for: format).encode(text)
        return try Decompressor.compress(encoded, using: compressor)
    }

    /// Parses edited text, storing invalid input as UTF-8 instead. Re-compresses the result with `compressor`.
    public static func parseEditedLeniently(_ text: String, as format: ValueFormat, compressor: Compressor = .none) throws -> Data {
        let encoded: Data
        do {
            encoded = try formatter(for: format).encode(text)
        } catch FormatterError.invalidInput {
            encoded = Data(text.utf8)
        }

        return try Decompressor.compress(encoded, using: compressor)
    }

    /// `true` when `text` can be saved in `format` without falling back to Unicode.
    public static func isValidInput(_ text: String, as format: ValueFormat) -> Bool {
        (try? formatter(for: format).encode(text)) != nil
    }

    /// True when the bytes are not valid UTF-8 or contain control characters other than tab/newline.
    public static func isNonUnicode(_ data: Data) -> Bool {
        guard let s = String(data: data, encoding: .utf8) else { return true }
        return s.unicodeScalars.contains { $0.value < 0x20 && $0 != "\n" && $0 != "\r" && $0 != "\t" }
    }

    /// True if the bytes survive a UTF-8 decode/encode round trip.
    public static func isPrintable(_ data: Data) -> Bool {
        String(strictUTF8: [UInt8](data)) != nil
    }

    /// Identifies formats that allow edits of non-printable values without displaying raw Unicode text.
    public static func isNonUnicodeFormat(_ format: ValueFormat, isValid: Bool) -> Bool {
        switch format {
        case .msgpack: return isValid
        case .ascii, .hex, .binary: return true
        default: return false
        }
    }

    private static func decompress(_ data: Data, compressor: Compressor, auto: Bool) -> DecompressResult {
        if compressor != .none { return Decompressor.decompress(data, using: compressor) }
        return auto ? Decompressor.decompressAuto(data) : DecompressResult(value: data)
    }

    /// Auto mode already ran detection, so only a failed decode is left to report; other modes detect here.
    private static func detectedCompressor(_ decompressed: DecompressResult, data: Data, compressor: Compressor,
                                           auto: Bool) -> Compressor? {
        if decompressed.isCompressed { return decompressed.compressor }
        if auto, compressor == .none { return decompressed.error?.compressor }
        return Decompressor.detect(data)
    }
}
