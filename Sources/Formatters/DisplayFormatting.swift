import Foundation
import RESP

/// Byte sizes, base 1024 (`B`, `KB`, `MB`, ... `YB`), e.g. `1.5 KB`.
public enum ByteFormatter {
    public static let units = ["B", "KB", "MB", "GB", "TB", "PB", "EB", "ZB", "YB"]

    public static func format(_ bytes: Double, decimals: Int = 3, base: Double = 1024) -> String {
        let (value, unit) = split(bytes, base: base)
        return "\(trim(value, decimals: decimals)) \(unit)"
    }

    public static func format(_ bytes: Int, decimals: Int = 3) -> String {
        format(Double(bytes), decimals: decimals)
    }

    public static func split(_ bytes: Double, base: Double = 1024) -> (value: Double, unit: String) {
        guard bytes > 0, bytes.isFinite else { return (0, "B") }
        let exponent = min(Int(log(bytes) / log(base)), units.count - 1)
        return (bytes / pow(base, Double(max(exponent, 0))), units[max(exponent, 0)])
    }

    static func trim(_ value: Double, decimals: Int) -> String {
        let factor = pow(10, Double(decimals))
        let rounded = (value * factor).rounded() / factor
        if rounded == rounded.rounded() { return String(Int64(rounded)) }
        var s = String(format: "%.\(decimals)f", rounded)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }
}

public enum NumberFormatting {
    /// Groups digits with commas (`12345678` becomes `12,345,678`), independent of the user’s locale.
    public static func grouped(_ value: Int) -> String {
        let digits = String(value.magnitude)
        var out = ""
        for (i, c) in digits.enumerated() {
            if i > 0 && (digits.count - i) % 3 == 0 { out.append(",") }
            out.append(c)
        }

        return value < 0 ? "-" + out : out
    }

    public static func percentage(_ part: Double, of total: Double, decimals: Int = 2) -> String {
        guard total > 0 else { return "0" }
        return ByteFormatter.trim(part / total * 100, decimals: decimals)
    }

    /// Rounds shares between 0% and 1% to `<1%`.
    public static func approximatePercentage(total: Double, part: Double) -> String {
        guard total > 0 else { return "0%" }
        let p = part / total * 100
        if p > 0 && p < 1 { return "<1%" }
        return "\(Int(p.rounded()))%"
    }
}

/// TTL / duration text with units `yr`, `mo`, `d`, `h`, `min`, `s`.
public enum DurationText {
    static let units: [(String, Int)] = [("yr", 31_536_000), ("mo", 2_592_000), ("d", 86_400), ("h", 3_600), ("min", 60), ("s", 1)]

    /// `3 h 2 min 5 s`.
    public static func full(seconds: Int) -> String {
        guard seconds > 0 else { return "0 s" }
        var rest = seconds
        var parts: [String] = []
        for (name, size) in units where rest >= size {
            parts.append("\(rest / size) \(name)")
            rest %= size
        }

        return parts.joined(separator: " ")
    }

    /// Returns only the largest unit, such as `3 h`.
    public static func firstUnit(seconds: Int) -> String {
        guard seconds > 0 else { return "0 s" }
        for (name, size) in units where seconds >= size { return "\(seconds / size) \(name)" }
        return "\(seconds) s"
    }
}

public enum TimestampDetector {
    /// Recognizes numeric 10/13/16/19-digit epochs or dates in ISO 8601, RFC 2822 and common layouts.
    public static func isTimestamp(_ text: String) -> Bool {
        let value = text.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return false }
        if TimestampFormatter.isNumberLike(value) { return TimestampFormatter.isTimestamp(value) }
        guard mayBeDate(value) else { return false }
        return parseDate(value) != nil
    }

    /// Every supported layout has a four-digit year and fits in a short string.
    static func mayBeDate(_ value: String) -> Bool {
        guard value.utf8.count <= 64 else { return false }
        return value.utf8.lazy.filter { $0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9") }.count >= 4
    }

    static let datePatterns = [
        "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX", "yyyy-MM-dd'T'HH:mm:ssXXXXX", "yyyy-MM-dd'T'HH:mm:ss.SSS", "yyyy-MM-dd'T'HH:mm:ss",
        "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd", "yyyy/MM/dd", "yyyy/MM/dd HH:mm:ss",
        "MM-dd-yyyy", "MM/dd/yyyy", "M/d/yyyy", "MM/dd/yyyy HH:mm:ss", "EEE, dd MMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm:ss zzz",
        "dd MMM yyyy HH:mm:ss Z", "dd MMM yyyy", "d MMM yyyy", "MMM d, yyyy", "MMMM d, yyyy", "MMM d yyyy",
        "EEE MMM dd yyyy HH:mm:ss 'GMT'Z", "EEE MMM d yyyy",
    ]

    private static let dateFormatters: [DateFormatter] = datePatterns.map { pattern in
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.isLenient = false
        formatter.dateFormat = pattern
        return formatter
    }

    // ISO8601DateFormatter parsing is thread-safe, and these are never mutated after creation.
    nonisolated(unsafe) private static let isoFormatters: [ISO8601DateFormatter] = [
        ISO8601DateFormatter.Options([.withInternetDateTime, .withFractionalSeconds]), [.withInternetDateTime],
    ].map { options in
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = options
        return formatter
    }

    static func parseDate(_ value: String) -> Date? {
        for formatter in dateFormatters {
            if let d = formatter.date(from: value) { return d }
        }

        for formatter in isoFormatters {
            if let d = formatter.date(from: value) { return d }
        }

        return nil
    }
}

public enum TextTruncation {
    /// Middle-elides names longer than `maxLength`, preserving `tail` trailing characters.
    public static func formatLongName(_ name: String, maxLength: Int = 500, tail: Int = 50) -> String {
        guard name.count > maxLength else { return name }
        let head = name.prefix(max(maxLength - tail - 3, 0))
        return head + "..." + name.suffix(tail)
    }
}
