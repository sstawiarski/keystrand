import Foundation
import RedisCore

/// Editing rules for values in the selected format.
public enum ValueEditRules {
    public static let cannotEditFormat = "Values shown in this format are read-only"
    public static let cannotEditCompressed = "Decompressed values are read-only"
    public static let loadEntireValue = "Load the full value before editing"
    public static let nonPrintableTitle = "This value has non-printable bytes"
    public static let nonPrintableMessage = "Edit it in Workbench or the CLI so no bytes are lost."
    public static let savedAsUnicodeTitle = "Save as Unicode?"
    public static let savedAsUnicodeMessage = "The value is not valid in the selected format."

    public static func isFormatEditable(_ format: ValueFormat) -> Bool {
        format.allowsEditing
    }

    /// Editing under these formats first shows the "Editing a non-Unicode value" guard.
    public static func requiresNonUnicodeGuard(_ format: ValueFormat) -> Bool {
        format.requiresNonUnicodeGuard
    }

    /// Why the value cannot be edited, or nil when editing is allowed.
    public static func editBlockReason(_ data: Data, format: ValueFormat, isValid: Bool, isCompressed: Bool,
                                       isPartial: Bool = false) -> String? {
        if isCompressed { return cannotEditCompressed }
        if isPartial { return loadEntireValue }
        if !isFormatEditable(format) { return cannotEditFormat }
        if !FormatterRegistry.isNonUnicodeFormat(format, isValid: isValid) && !FormatterRegistry.isPrintable(data) {
            return nonPrintableTitle + "\n" + nonPrintableMessage
        }

        return nil
    }

    /// Text placed in the editor for `data` under `format`.
    public static func editorText(_ data: Data, format: ValueFormat) -> String {
        if format.editsRawText { return String(decoding: data, as: UTF8.self) }
        return FormatterRegistry.serializeForEdit(data, as: format, compressor: .none, indent: 4)
    }

    /// Encodes edited text. If it is invalid in `format`, returns UTF-8 with `isValid == false`;
    /// the UI requires confirmation before saving as Unicode.
    public static func encode(_ text: String, format: ValueFormat) -> (data: Data, isValid: Bool) {
        if format.editsRawText { return (Data(text.utf8), true) }
        do {
            return (try FormatterRegistry.parseEdited(text, as: format, compressor: .none), true)
        } catch {
            return (Data(text.utf8), false)
        }
    }

    /// Code editor language for an editor under `format`.
    public static func isJSONLike(_ format: ValueFormat) -> Bool {
        switch format {
        case .json, .msgpack, .php: return true
        default: return false
        }
    }
}

extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}
