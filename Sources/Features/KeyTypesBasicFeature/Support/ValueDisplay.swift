import Foundation
import RedisCore

/// Collapsed single-line rendering of a value for table cells, computed off the main actor.
public struct ValuePreview: Hashable, Sendable {
    public var text: String
    public var tooltip: String
    public var isValid: Bool
    public var isCompressed: Bool
    public var isEmpty: Bool

    public init(text: String, tooltip: String, isValid: Bool, isCompressed: Bool, isEmpty: Bool) {
        self.text = text
        self.tooltip = tooltip
        self.isValid = isValid
        self.isCompressed = isCompressed
        self.isEmpty = isEmpty
    }

    public static let placeholder = ValuePreview(text: "", tooltip: "", isValid: true, isCompressed: false, isEmpty: false)
}

/// Snapshot of everything needed to format values (format, database compressor, date options). Sendable so
/// heavy formatting can run in detached tasks.
public struct ValueDisplayFormatter: Hashable, Sendable {
    public static let collapsedLength = 200
    public static let tooltipLength = 500

    public var format: ValueFormat
    public var compressor: Compressor
    public var options: FormatOptions

    public init(format: ValueFormat, compressor: Compressor = .none, options: FormatOptions = FormatOptions()) {
        self.format = format
        self.compressor = compressor
        self.options = options
    }

    public func result(_ data: Data, expanded: Bool = false) -> FormatResult {
        var options = self.options
        options.expanded = expanded
        return FormatterRegistry.format(data, as: format, compressor: compressor, options: options)
    }

    public func preview(_ data: Data, columnTitle: String? = nil) -> ValuePreview {
        let result = self.result(data)
        let full = result.displayText(expanded: false)
        let single = Self.singleLine(full, limit: Self.collapsedLength)
        let title = result.isValid ? columnTitle : FormatResult.failedTitle(format)
        let tooltipBody = TextTruncation.formatLongName(Self.singleLine(full, limit: Self.tooltipLength + 100),
                                                        maxLength: Self.tooltipLength, tail: 50)
        let tooltip = [title, tooltipBody].compactMap { $0 }.joined(separator: "\n")
        return ValuePreview(text: single, tooltip: tooltip, isValid: result.isValid, isCompressed: result.isCompressed,
                            isEmpty: data.isEmpty)
    }

    public func previews(_ values: [Data], columnTitle: String? = nil) -> [ValuePreview] {
        values.map { preview($0, columnTitle: columnTitle) }
    }

    /// Text copied for a value (pretty JSON for tree formats).
    public func copyText(_ data: Data) -> String {
        result(data, expanded: true).displayText(expanded: true, indent: 2)
    }

    /// First `limit` characters with newlines/tabs folded to spaces; runs of spaces kept as non-breaking spaces.
    public static func singleLine(_ text: String, limit: Int) -> String {
        var out = ""
        out.reserveCapacity(min(text.utf8.count, limit + 1))
        var count = 0
        var truncated = false
        for ch in text {
            if count >= limit {
                truncated = true
                break
            }

            switch ch {
            case "\n", "\r", "\r\n", "\t": out.append(" ")
            default: out.append(ch)
            }

            count += 1
        }

        return truncated ? out + "…" : out
    }
}

/// Short display name for keys, fields, members in popovers and toasts (`68` chars, last `15`).
public enum DisplayName {
    public static func of(_ data: Data, format: KeyNameFormat = .unicode) -> String {
        RedisKeyName(data).displayString(format: format)
    }

    public static func short(_ data: Data, format: KeyNameFormat = .unicode) -> String {
        short(of(data, format: format))
    }

    public static func short(_ text: String) -> String {
        TextTruncation.formatLongName(text, maxLength: 68, tail: 15)
    }
}
