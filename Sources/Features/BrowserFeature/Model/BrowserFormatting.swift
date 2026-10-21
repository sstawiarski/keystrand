import Foundation
import RedisCore
import RedisUI

/// Text helpers for the key list, summary, Add Key validation, and Bulk Actions.
public enum BrowserFormatting {
    public static let maxTTL = TTLInput.maxTTL
    public static let displayNameLimit = 200

    /// Display string for a key name in the chosen key-name format.
    public static func keyDisplayName(_ name: Data, format: KeyNameFormat) -> String {
        RedisKeyName(name).displayString(format: format)
    }

    /// Cell text: first 200 characters, with runs of whitespace kept visible (non-breaking spaces).
    public static func cellName(_ display: String) -> String {
        let cut = display.count > displayNameLimit ? String(display.prefix(displayNameLimit)) : display
        guard cut.contains("  ") || cut.contains("\t") || cut.contains("\n") else { return cut }
        var out = ""
        out.reserveCapacity(cut.count)
        for character in cut {
            switch character {
            case " ": out.append("\u{00A0}")
            case "\t": out.append("\u{00A0}\u{00A0}\u{00A0}\u{00A0}")
            case "\n", "\r", "\r\n": out.append("\u{21B5}")
            default: out.append(character)
            }
        }

        return out
    }

    /// Tooltip / popover title for a long key name (500 max, keeping the last 50).
    public static func tooltipName(_ display: String) -> String {
        TextTruncation.formatLongName(display, maxLength: 500, tail: 50)
    }

    /// Short name for notifications and popovers (68 max, keeping the last 15).
    public static func shortName(_ display: String) -> String {
        TextTruncation.formatLongName(display, maxLength: 68, tail: 15)
    }

    /// Grouped counts (`1,234`); nil -> `-`.
    public static func count(_ value: Int?) -> String {
        guard let value, value >= 0 else { return "-" }
        return NumberFormatting.grouped(value)
    }

    /// `1 key`, `1,234 keys`.
    public static func keyCount(_ value: Int) -> String {
        "\(NumberFormatting.grouped(value)) \(value == 1 ? "key" : "keys")"
    }

    /// Key list status text. Unfiltered lists show the total; filters and trees show found and scanned counts.
    /// A `~` prefixes the scanned count if an incomplete scan reaches the total.
    public static func summary(found: Int, total: Int?, scanned: Int, isComplete: Bool, isFiltered: Bool,
                               isTree: Bool, isLoading: Bool, hasStarted: Bool) -> String {
        if !hasStarted && total == nil { return isLoading ? "Scanning…" : "" }
        if !isFiltered && !isTree { return keyCount(total ?? found) }
        var scannedText = NumberFormatting.grouped(scanned)
        if let total, scanned >= total, !isComplete { scannedText = "~" + scannedText }
        guard let total else { return "Found \(NumberFormatting.grouped(found)) · scanned \(scannedText)" }
        return "Found \(NumberFormatting.grouped(found)) · scanned \(scannedText) of \(NumberFormatting.grouped(total))"
    }

    /// Status bar text in RediSearch mode: `Found 12 of 1,234`, plus `matching <query>` when the query was generated
    /// in place of an empty one.
    public static func searchSummary(found: Int, total: Int?, generatedQuery: String? = nil) -> String {
        var text = "Found \(NumberFormatting.grouped(found))"
        if let total { text += " of \(NumberFormatting.grouped(total))" }
        if let generatedQuery { text += " matching \(generatedQuery)" }
        return text
    }

    /// Folder percentage: `<1%` or rounded.
    public static func percentage(_ value: Double) -> String {
        if value > 0 && value < 1 { return "<1%" }
        return "\(Int(value.rounded()))%"
    }

    /// Folder tooltip: `<fullName><delimiter>*` + `N key(s) (P%)` (+ delimiters when several).
    public static func folderTooltip(fullName: String, delimiters: [String], keyCount: Int, percentage: Double) -> String {
        let delimiter = delimiters.count == 1 ? delimiters[0] : "-"
        var text = "\(fullName)\(delimiter)*\n\(count(keyCount)) key\(keyCount == 1 ? "" : "s") (\(Self.percentage(percentage)))"
        if delimiters.count > 1 { text += "\nDelimiters: " + delimiters.joined(separator: " ") }
        return text
    }

    /// Size cell: `formatBytes(size, 0)`; `0`/nil -> `-`; `-1` (too large) -> `-`.
    public static func sizeText(_ size: Int?, decimals: Int = 0) -> String {
        guard let size, size > 0 else { return "-" }
        return ByteFormatter.format(size, decimals: decimals)
    }

    /// TTL cell: `No limit`, or the first unit of the duration.
    public static func ttlText(_ ttl: Int?) -> String {
        TTLText.text(ttl)
    }

    /// TTL tooltip: exact seconds, full duration and expiry time.
    public static func ttlTooltip(_ ttl: Int?) -> String {
        guard ttl != nil else { return "Time to Live" }
        return TTLText.secondsTooltip(ttl)
    }

    // MARK: - Input sanitizing

    /// Digits only, leading zeros stripped (a single `0` is kept), clamped to `maxTTL`.
    public static func sanitizeTTL(_ text: String) -> String {
        TTLInput.sanitize(text)
    }

    /// Digits only (no clamping), for numeric inputs such as prefix length.
    public static func digitsOnly(_ text: String) -> String {
        text.filter(\.isASCIIDigit)
    }

    /// Sorted-set score: decimal number (up to 15 decimals), `inf`, `+inf`, `-inf`.
    public static func parseScore(_ text: String) -> Double? {
        let value = text.trimmingCharacters(in: .whitespaces).lowercased()
        switch value {
        case "inf", "+inf", "infinity", "+infinity": return .infinity
        case "-inf", "-infinity": return -.infinity
        default: break
        }

        guard !value.isEmpty, value.range(of: #"^[-+]?(\d+\.?\d*|\.\d+)([eE][-+]?\d+)?$"#, options: .regularExpression) != nil,
              let number = Double(value), number.isFinite else { return nil }
        if let dot = value.firstIndex(of: "."), !value.contains("e") {
            let decimals = value[value.index(after: dot)...].count
            if decimals > 15 { return nil }
        }

        return number
    }

    /// Stream entry id: `*`, `<ms>`, `<ms>-<seq>` or `<ms>-*`.
    public static func isValidStreamID(_ text: String) -> Bool {
        let value = text.trimmingCharacters(in: .whitespaces)
        if value.isEmpty || value == "*" { return true }
        return value.range(of: #"^\d+(-(\d+|\*))?$"#, options: .regularExpression) != nil
    }

    /// Time-series sample timestamp: `*` or milliseconds.
    public static func isValidTimestamp(_ text: String) -> Bool {
        let value = text.trimmingCharacters(in: .whitespaces)
        return value.isEmpty || value == "*" || value.allSatisfy(\.isASCIIDigit)
    }

    // MARK: - Bulk actions

    /// `~N` keys expected to match: found × total / scanned (nil when unknown).
    public static func expectedAmount(found: Int, total: Int?, scanned: Int) -> Int? {
        guard let total, scanned > 0 else { return nil }
        if scanned >= total { return found }
        return Int((Double(found) * Double(total) / Double(scanned)).rounded())
    }

    /// `H:mm:ss.SSS`.
    public static func bulkDuration(_ seconds: TimeInterval) -> String {
        let totalMs = max(Int((seconds * 1000).rounded()), 0)
        let ms = totalMs % 1000
        let s = (totalMs / 1000) % 60
        let m = (totalMs / 60_000) % 60
        let h = totalMs / 3_600_000
        return String(format: "%d:%02d:%02d.%03d", h, m, s, ms)
    }

    /// Bulk progress percentage 0...100.
    public static func progress(scanned: Int, total: Int) -> Int {
        guard total > 0 else { return 0 }
        return min(100, max(0, Int((Double(scanned) / Double(total) * 100).rounded(.down))))
    }

    /// Text report for a finished bulk delete (one line per failed key + summary).
    public static func bulkDeleteReport(_ overview: BulkActionOverview, format: KeyNameFormat = .unicode) -> String {
        var lines: [String] = []
        lines.append("Bulk delete report")
        lines.append("Pattern: \(overview.filter.match)")
        lines.append("Key type: \(overview.filter.type?.displayName ?? "All Key Types")")
        lines.append("")
        for error in overview.errors {
            lines.append("\(keyDisplayName(error.key, format: format)) - Error: \(error.error)")
        }

        if !overview.errors.isEmpty { lines.append("") }
        lines.append("Status: \(overview.status.rawValue)")
        lines.append("Keys Processed: \(overview.processed)")
        lines.append("Success: \(overview.succeeded)")
        lines.append("Errors: \(overview.failed)")
        lines.append("Time Taken: \(bulkDuration(overview.duration))")
        return lines.joined(separator: "\n") + "\n"
    }

    /// True when `pattern` is `prefix*` with no other glob characters (bulk delete can prune the loaded list).
    public static func simplePrefix(of pattern: String) -> String? {
        guard pattern.hasSuffix("*") else { return nil }
        let prefix = String(pattern.dropLast())
        if KeyPattern.isGlob(prefix) { return nil }
        return KeyPattern.unescape(prefix)
    }

    /// "Find Keys with This Prefix": the key name up to and including its last delimiter, escaped, plus `*`.
    /// nil when the name has no delimiter.
    public static func prefixPattern(for display: String, delimiters: [String]) -> String? {
        var best: String.Index?
        for delimiter in delimiters where !delimiter.isEmpty {
            if let range = display.range(of: delimiter, options: .backwards), best.map({ range.upperBound > $0 }) ?? true {
                best = range.upperBound
            }
        }

        guard let end = best, end < display.endIndex else { return nil }
        return KeyPattern.escape(String(display[..<end])) + "*"
    }

    /// Truncates a file name for notifications (34 max, keep last 5).
    public static func shortFileName(_ name: String) -> String {
        TextTruncation.formatLongName(name, maxLength: 34, tail: 5)
    }
}

private extension Character {
    var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}
