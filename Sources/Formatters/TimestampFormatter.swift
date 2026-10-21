import Foundation
import Synchronization

/// Timestamp detection, unit conversion and date-fns style formatting.
public enum TimestampFormatter {
    public static let defaultPattern = "HH:mm:ss d MMM yyyy"

    /// Numeric text whose integer part has 10/13/16/19 digits (or 9/12/15/18 with a leading `-`),
    /// optionally followed by `.digits`.
    public static func isTimestamp(_ value: String) -> Bool {
        guard isNumberLike(value), let integerPart = integerPart(value) else { return false }
        let digits = integerPart.hasPrefix("-") ? integerPart.count - 1 : integerPart.count
        let ok = integerPart.hasPrefix("-") ? [9, 12, 15, 18].contains(digits) : [10, 13, 16, 19].contains(digits)
        guard ok else { return false }
        if integerPart.count == value.count { return true }
        guard let range = value.range(of: integerPart) else { return false }
        var rest = value
        rest.removeSubrange(range)
        let fraction = rest.dropFirst()
        return !fraction.isEmpty && fraction.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// Seconds (10 chars), microseconds (16) and nanoseconds (19) to milliseconds; other lengths are milliseconds.
    public static func milliseconds(_ value: String) -> Double? {
        guard let number = Double(value), let integerPart = integerPart(value) else { return nil }
        switch integerPart.count {
        case 10: return number * 1000
        case 16: return number / 1000
        case 19: return number / 1_000_000
        default: return number
        }
    }

    /// Formats a timestamp string, or `nil` when it is not one.
    public static func format(_ value: String, pattern: String = defaultPattern, timeZone: TimeZone = .current) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isTimestamp(trimmed), let ms = milliseconds(trimmed) else { return nil }
        return format(milliseconds: ms, pattern: pattern, timeZone: timeZone)
    }

    public static func format(milliseconds: Double, pattern: String = defaultPattern, timeZone: TimeZone = .current) -> String {
        format(date: Date(timeIntervalSince1970: milliseconds / 1000), pattern: pattern, timeZone: timeZone)
    }

    public static func format(date: Date, pattern: String = defaultPattern, timeZone: TimeZone = .current) -> String {
        guard !isDateDependent(pattern) else {
            return makeFormatter(foundationPattern(fromDateFns: pattern, date: date, timeZone: timeZone), timeZone: timeZone)
                .string(from: date)
        }
        let key = FormatterKey(pattern: pattern, timeZone: timeZone.identifier)
        return formatters.withLock { cache in
            if let formatter = cache[key] { return formatter.string(from: date) }
            let formatter = makeFormatter(foundationPattern(fromDateFns: pattern, date: date, timeZone: timeZone),
                                          timeZone: timeZone)
            cache[key] = formatter
            return formatter.string(from: date)
        }
    }

    private struct FormatterKey: Hashable {
        let pattern: String
        let timeZone: String
    }

    private static let formatters = Mutex<[FormatterKey: DateFormatter]>([:])

    /// Ordinal (`do`, `Do`, `Mo`) and epoch (`t`, `T`) tokens depend on the date, so skip the formatter cache.
    /// Quoted literals can also match this check and skip the cache.
    private static func isDateDependent(_ pattern: String) -> Bool {
        pattern.contains { $0 == "o" || $0 == "t" || $0 == "T" }
    }

    private static func makeFormatter(_ format: String, timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = format
        return formatter
    }

    /// `true` when `pattern` produces non-empty output (Settings validation).
    public static func isValidPattern(_ pattern: String) -> Bool {
        guard !pattern.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        var quoteOpen = false
        for c in pattern where c == "'" { quoteOpen.toggle() }
        return !quoteOpen && !format(date: Date(), pattern: pattern, timeZone: .current).isEmpty
    }

    /// Translates date-fns tokens that differ from Unicode TR35 (`do`, `t`, `T`, `P`, `p`, `aaa`, `R`, `I`, `i`).
    static func foundationPattern(fromDateFns pattern: String, date: Date, timeZone: TimeZone) -> String {
        let chars = Array(pattern)
        var out = ""
        var i = 0
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        func literal(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "''") + "'" }
        while i < chars.count {
            let c = chars[i]
            if c == "'" {
                var j = i + 1
                while j < chars.count {
                    if chars[j] == "'" {
                        if j + 1 < chars.count, chars[j + 1] == "'" { j += 2; continue }
                        break
                    }

                    j += 1
                }

                out += String(chars[i...min(j, chars.count - 1)])
                if j >= chars.count { out += "'" }
                i = j + 1
                continue
            }

            guard c.isLetter, c.isASCII else {
                out.append(c)
                i += 1
                continue
            }
            var j = i
            while j < chars.count, chars[j] == c { j += 1 }
            let run = j - i
            let hasOrdinal = j < chars.count && chars[j] == "o"
            switch c {
            case "d" where hasOrdinal:
                out += literal(ordinal(calendar.component(.day, from: date)))
                j += 1
            case "D" where hasOrdinal:
                out += literal(ordinal(calendar.ordinality(of: .day, in: .year, for: date) ?? 0))
                j += 1
            case "M" where hasOrdinal:
                out += literal(ordinal(calendar.component(.month, from: date)))
                j += 1
            case "t":
                out += literal(String(Int64((date.timeIntervalSince1970).rounded(.down))))
            case "T":
                out += literal(String(Int64((date.timeIntervalSince1970 * 1000).rounded(.down))))
            case "P":
                out += ["MM/dd/yyyy", "MMM d, yyyy", "MMMM d, yyyy", "EEEE, MMMM d, yyyy"][min(run, 4) - 1]
            case "p":
                out += ["h:mm a", "h:mm:ss a", "h:mm:ss a z", "h:mm:ss a zzzz"][min(run, 4) - 1]
            case "a", "b", "B":
                out += "a"
            case "R":
                out += String(repeating: "Y", count: run)
            case "I":
                out += String(repeating: "w", count: run)
            case "i":
                out += run <= 2 ? "e" : String(repeating: "E", count: run)
            default:
                out += String(repeating: c, count: run)
            }

            i = j
        }

        return out
    }

    static func ordinal(_ n: Int) -> String {
        let tens = n % 100
        if (11...13).contains(tens) { return "\(n)th" }
        switch n % 10 {
        case 1: return "\(n)st"
        case 2: return "\(n)nd"
        case 3: return "\(n)rd"
        default: return "\(n)th"
        }
    }

    /// `^-?\d*(\.\d+)?$`
    static func isNumberLike(_ value: String) -> Bool {
        var s = Substring(value)
        if s.hasPrefix("-") { s = s.dropFirst() }
        let integer = s.prefix(while: { $0.isASCII && $0.isNumber })
        s = s.dropFirst(integer.count)
        if s.isEmpty { return true }
        guard s.hasPrefix(".") else { return false }
        let fraction = s.dropFirst()
        return !fraction.isEmpty && fraction.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// Extracts the sign and digits without leading zeros, matching `parseInt(value, 10).toString()`.
    static func integerPart(_ value: String) -> String? {
        var s = Substring(value)
        let negative = s.hasPrefix("-")
        if negative { s = s.dropFirst() }
        let digits = s.prefix(while: { $0.isASCII && $0.isNumber })
        guard !digits.isEmpty else { return nil }
        var trimmed = digits.drop(while: { $0 == "0" })
        if trimmed.isEmpty { trimmed = "0" }
        let text = String(trimmed)
        return negative && text != "0" ? "-" + text : text
    }
}
