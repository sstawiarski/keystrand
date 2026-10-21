import Foundation

/// "View format" for values. Settings persist the raw values, so they must not change.
public enum ValueFormat: String, CaseIterable, Codable, Sendable, Hashable, Identifiable {
    case unicode = "Unicode"
    case ascii = "ASCII"
    case json = "JSON"
    case hex = "HEX"
    case binary = "Binary"
    case msgpack = "Msgpack"
    case php = "PHP serialized"
    case java = "Java serialized"
    case protobuf = "Protobuf"
    case pickle = "Pickle"
    case vector32 = "Vector 32-bit"
    case vector64 = "Vector 64-bit"
    case dateTime = "DateTime"
    case markdown = "Markdown"

    public var id: String { rawValue }

    /// Order of the format picker menu.
    public static let menuOrder: [ValueFormat] = [
        .unicode, .ascii, .binary, .hex, .json, .markdown, .msgpack, .pickle, .protobuf,
        .php, .java, .vector32, .vector64, .dateTime,
    ]

    public var menuLabel: String {
        self == .dateTime ? "Timestamp to DateTime" : rawValue
    }

    /// Whether the formatter can encode edited text. `allowsEditing` controls whether the UI permits edits.
    public var isEditable: Bool {
        switch self {
        case .unicode, .ascii, .json, .hex, .binary, .msgpack, .php, .vector32, .vector64: return true
        case .java, .protobuf, .pickle, .dateTime, .markdown: return false
        }
    }

    /// Formats rendered as plain text (no JSON tree / markdown rendering).
    public var isTextView: Bool {
        switch self {
        case .unicode, .ascii, .hex, .binary, .vector32, .vector64, .dateTime: return true
        default: return false
        }
    }

    /// Disables edits for Protobuf, Java, Pickle, Vector 32/64, HEX and Binary values across all key types.
    public var allowsEditing: Bool {
        switch self {
        case .protobuf, .java, .pickle, .vector32, .vector64, .hex, .binary: return false
        case .unicode, .ascii, .json, .msgpack, .php, .dateTime, .markdown: return true
        }
    }

    /// The editor works on the raw UTF-8 text rather than on a serialized form of the value.
    public var editsRawText: Bool {
        self == .unicode || self == .dateTime || self == .markdown
    }

    /// Whether editing first requires the “Edit a Non-Unicode Value?” confirmation.
    public var requiresNonUnicodeGuard: Bool {
        self != .unicode && allowsEditing
    }
}
