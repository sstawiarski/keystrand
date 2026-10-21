import Foundation

public enum FormattedContent: Hashable, Sendable {
    case text(String)
    case json(JSONValue)
    case markdown(String)
}

public enum FormattedContentKind: String, Hashable, Sendable {
    case text
    case json
    case markdown
}

public struct FormatResult: Hashable, Sendable {
    public var content: FormattedContent
    /// False if decoding in the requested format fails.
    public var isValid: Bool
    /// The compressor that decoded the value, or a magic-byte hint if decompression is off.
    public var detectedCompressor: Compressor?
    /// True if the displayed value was decompressed, which disables edits.
    public var isCompressed: Bool
    /// The value looked compressed but could not be decoded (corrupt or unsupported); the raw bytes are shown.
    public var compressionError: DecompressorError?

    public init(content: FormattedContent, isValid: Bool, detectedCompressor: Compressor? = nil,
                isCompressed: Bool = false, compressionError: DecompressorError? = nil) {
        self.content = content
        self.isValid = isValid
        self.detectedCompressor = detectedCompressor
        self.isCompressed = isCompressed
        self.compressionError = compressionError
    }

    public static func text(_ s: String, isValid: Bool = true) -> FormatResult {
        FormatResult(content: .text(s), isValid: isValid)
    }

    public static func json(_ value: JSONValue) -> FormatResult {
        FormatResult(content: .json(value), isValid: true)
    }

    public var kind: FormattedContentKind {
        switch content {
        case .text: return .text
        case .json: return .json
        case .markdown: return .markdown
        }
    }

    /// Plain-text rendering of the content (JSON pretty-printed with 4 spaces).
    public var text: String {
        switch content {
        case .text(let s), .markdown(let s): return s
        case .json(let v): return JSONPrinter.print(v)
        }
    }

    /// Collapsed (single-line JSON) or expanded (pretty, `indent` spaces) text for cells and tooltips.
    public func displayText(expanded: Bool, indent: Int = 2) -> String {
        switch content {
        case .text(let s), .markdown(let s): return s
        case .json(let v): return JSONPrinter.print(v, indent: expanded ? indent : nil)
        }
    }

    /// The JSON tree when the content is JSON.
    public var jsonValue: JSONValue? {
        if case .json(let v) = content { return v }
        return nil
    }

    /// User-facing tooltip title for invalid conversions.
    public static func failedTitle(_ format: ValueFormat) -> String {
        "Failed to convert to \(format.rawValue)"
    }
}

public typealias FormattedValue = FormatResult

public struct FormatOptions: Hashable, Sendable {
    /// date-fns style pattern from Settings, e.g. `HH:mm:ss d MMM yyyy`.
    public var dateFormat: String
    public var timeZone: TimeZone
    /// Expanded (pretty, multi-line) vs collapsed single-line rendering for table cells.
    public var expanded: Bool
    /// With compressor `.none`, still decompress values whose magic bytes identify a compressor.
    public var autoDecompress: Bool

    public init(dateFormat: String = "HH:mm:ss d MMM yyyy", timeZone: TimeZone = .current, expanded: Bool = false,
                autoDecompress: Bool = false) {
        self.dateFormat = dateFormat
        self.timeZone = timeZone
        self.expanded = expanded
        self.autoDecompress = autoDecompress
    }
}

public enum FormatterError: Error, LocalizedError, Sendable, Equatable {
    case notEditable(ValueFormat)
    case invalidInput(ValueFormat, String)

    public var errorDescription: String? {
        switch self {
        case .notEditable(let f): return "\(f.rawValue) values cannot be edited."
        case .invalidInput(let f, let detail): return "Invalid \(f.rawValue) value: \(detail)"
        }
    }
}
