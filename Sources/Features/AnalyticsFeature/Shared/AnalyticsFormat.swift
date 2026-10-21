import Foundation
import RedisCore

/// Formatting helpers shared by the Analytics pages.
public enum AnalyticsFormat {
    /// Base-1024 bytes, 3 decimals with trailing zeros dropped; `0 B` for zero, `-` for negative or NaN.
    public static func bytes(_ value: Double, decimals: Int = 3) -> String {
        guard value.isFinite, value >= 0 else { return "-" }
        if value == 0 { return "0 B" }
        return ByteFormatter.format(value, decimals: decimals)
    }

    public static func bytes(_ value: Int?) -> String {
        guard let value else { return "-" }
        return bytes(Double(value))
    }

    public static func number(_ value: Int) -> String { NumberFormatting.grouped(value) }

    /// `Scanned 42%`; `<1%` below one percent, `100%` when nothing to scan.
    public static func scannedPercentage(processed: Int, total: Int) -> String {
        guard total > 0 else { return "100%" }
        let pct = Double(processed) / Double(total) * 100
        if pct > 0 && pct < 1 { return "<1%" }
        return "\(Int(pct.rounded()))%"
    }

    public static func progressText(_ progress: AnalysisProgress) -> (percentage: String, counts: String) {
        ("Scanned \(scannedPercentage(processed: progress.processed, total: progress.total))",
         "(\(number(progress.processed))/\(number(progress.total)) keys)")
    }

    /// `Scanned 100% (8,213 of 8,213 keys)`.
    public static func progressLine(_ progress: AnalysisProgress) -> String {
        "Scanned \(scannedPercentage(processed: progress.processed, total: progress.total)) "
            + "(\(number(progress.processed)) of \(number(progress.total)) keys)"
    }

    /// Live analysis status: the scan phase until keys are being analyzed.
    public static func liveProgressText(_ progress: AnalysisProgress) -> String {
        if progress.processed == 0 { return "Scanning keys… \(number(progress.scanned)) found" }
        return "Analyzing \(number(progress.processed)) of \(number(progress.scanned)) sampled keys…"
    }

    /// 0…1 for a determinate progress bar; nil (indeterminate) while nothing was scanned.
    public static func progressFraction(_ progress: AnalysisProgress?) -> Double? {
        guard let progress, progress.scanned > 0 else { return nil }
        return min(Double(progress.processed) / Double(progress.scanned), 1)
    }

    static let durationUnits: [(String, Int)] = [("yr", 31_536_000), ("mo", 2_592_000), ("d", 86_400), ("h", 3_600), ("min", 60), ("s", 1)]

    /// `28 d, 22 h, 26 min`.
    public static func durationFull(seconds: Int) -> String {
        guard seconds > 0 else { return "0 s" }
        var rest = seconds
        var parts: [String] = []
        for (name, size) in durationUnits where rest >= size {
            parts.append("\(rest / size) \(name)")
            rest %= size
        }

        return parts.joined(separator: ", ")
    }

    /// First component of `durationFull`, e.g. `5 h`.
    public static func durationFirstUnit(seconds: Int) -> String {
        guard seconds > 0 else { return "0 s" }
        for (name, size) in durationUnits where seconds >= size { return "\(seconds / size) \(name)" }
        return "\(seconds) s"
    }

    /// TTL cell text: nil -> `-`, negative -> `No limit`, else the first duration unit.
    public static func ttl(_ ttl: Int?) -> String {
        guard let ttl else { return "-" }
        if ttl < 0 { return "No limit" }
        return durationFirstUnit(seconds: ttl)
    }

    public static func ttlTooltip(_ ttl: Int?) -> String? {
        guard let ttl, ttl >= 0 else { return nil }
        return "Time to Live\n\(number(ttl)) s\n(\(durationFull(seconds: ttl)))"
    }

    /// Displayable key or namespace (UTF-8, non-printable bytes escaped as `\xHH`).
    public static func keyName(_ data: Data) -> String {
        RedisKeyName(data).displayString()
    }

    /// First `limit` characters followed by `...` when longer.
    public static func truncated(_ text: String, limit: Int) -> String {
        text.count > limit ? String(text.prefix(limit)) + "…" : text
    }

    /// Converts a microsecond duration for display: msec keeps up to 3 decimals; thousands are space separated.
    public static func duration(microseconds: Int, unit: SlowLogDurationUnit) -> String {
        switch unit {
        case .microseconds:
            return number(microseconds)
        case .milliseconds:
            return decimal(Double(microseconds) / 1000, maxDecimals: 3)
        }
    }

    /// `12345.678` -> `12,345.678`; trailing zeros dropped; `-` when not finite or too large for `Int`.
    public static func decimal(_ value: Double, maxDecimals: Int) -> String {
        guard value.isFinite else { return "-" }
        let factor = pow(10, Double(maxDecimals))
        let rounded = (value * factor).rounded() / factor
        let negative = rounded < 0
        let magnitude = abs(rounded)
        guard magnitude < 9e18, let integer = Int(exactly: magnitude.rounded(.towardZero)) else { return "-" }
        var fraction = String(format: "%.\(maxDecimals)f", magnitude - Double(integer))
        if fraction.hasPrefix("1") {
            return (negative ? "-" : "") + number(integer + 1)
        }

        fraction = String(fraction.dropFirst(2))
        while fraction.hasSuffix("0") { fraction.removeLast() }
        let body = number(integer) + (fraction.isEmpty ? "" : "." + fraction)
        return (negative && rounded != 0 ? "-" : "") + body
    }

    /// `[db3] ` prefix for logical databases other than 0.
    public static func dbPrefix(_ db: Int?) -> String {
        guard let db, db > 0 else { return "" }
        return "[db\(db)] "
    }

    @MainActor
    public static func date(_ date: Date, settings: SettingsStore) -> String {
        TimestampFormatter.format(date: date, pattern: settings.app.dateFormat, timeZone: settings.app.timezone.timeZone)
    }
}
