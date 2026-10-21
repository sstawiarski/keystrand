import Foundation
import RedisUI

/// Validation and preview of date-fns style date formats (Settings › General › Date and Time Format).
public enum DateFormatValidator {
    public static let maxLength = 50
    public static let tooLongMessage = "Format should not exceed 50 characters"
    public static let unsupportedMessage = "This format is not supported."
    public static let invalidPreview = "Invalid Format"

    /// Letters date-fns accepts as pattern tokens; any other unquoted latin letter makes date-fns throw.
    static let tokenLetters: Set<Character> = Set("GyYRuQqMLwIdDEeciabBhHKkmsSXxOztTPpo")
    /// Letters date-fns reads as an ordinal token when directly followed by `o` (`do`, `Mo`, `Do`).
    static let ordinalLetters: Set<Character> = Set("yYQqMLwIdDecihHKkms")
    /// Week-year and day-of-year tokens date-fns refuses unless explicitly enabled.
    static let protectedTokens: Set<String> = ["D", "DD", "YY", "YYYY"]

    /// Error message for `pattern`, or nil when it can be saved. Empty patterns have no message but cannot be saved.
    public static func error(for pattern: String) -> String? {
        if pattern.count > maxLength { return tooLongMessage }
        if pattern.trimmingCharacters(in: .whitespaces).isEmpty { return nil }
        return isSupported(pattern) ? nil : unsupportedMessage
    }

    public static func canSave(_ pattern: String) -> Bool {
        !pattern.trimmingCharacters(in: .whitespaces).isEmpty && error(for: pattern) == nil
    }

    /// Tokenizes like date-fns `format`: quoted literals, `Xo` ordinals, then runs of the same letter.
    public static func isSupported(_ pattern: String) -> Bool {
        guard !pattern.trimmingCharacters(in: .whitespaces).isEmpty, pattern.count <= maxLength else { return false }
        let chars = Array(pattern)
        var index = 0
        while index < chars.count {
            let c = chars[index]
            if c == "'" {
                guard let next = endOfQuote(chars, from: index) else { return false }
                index = next
                continue
            }

            guard c.isASCII, c.isLetter else {
                index += 1
                continue
            }
            guard tokenLetters.contains(c) else { return false }
            if ordinalLetters.contains(c), index + 1 < chars.count, chars[index + 1] == "o" {
                index += 2
                continue
            }

            var end = index + 1
            while end < chars.count, chars[end] == c { end += 1 }
            if protectedTokens.contains(String(chars[index..<end])) { return false }
            index = end
        }

        return TimestampFormatter.isValidPattern(pattern)
    }

    /// Index just past the quoted literal (or `''` escape) starting at `start`; nil when the quote never closes.
    private static func endOfQuote(_ chars: [Character], from start: Int) -> Int? {
        if start + 1 < chars.count, chars[start + 1] == "'" { return start + 2 }
        var index = start + 1
        while index < chars.count {
            if chars[index] == "'" {
                if index + 1 < chars.count, chars[index + 1] == "'" {
                    index += 2
                    continue
                }

                return index + 1
            }

            index += 1
        }

        return nil
    }

    /// `date` formatted with `pattern`, or "Invalid Format".
    public static func preview(_ pattern: String, timeZone: TimeZone, date: Date = Date()) -> String {
        guard isSupported(pattern) else { return invalidPreview }
        let text = TimestampFormatter.format(date: date, pattern: pattern, timeZone: timeZone)
        return text.isEmpty ? invalidPreview : text
    }
}

/// Digits-only numeric settings ("Keys to Scan", "Commands in pipeline").
public enum NumericSettingParser {
    /// Keeps only ASCII digits (the field rejects everything else).
    public static func digitsOnly(_ text: String) -> String {
        String(text.filter { $0.isASCII && $0.isNumber })
    }

    /// Returns 10,000 if the first 9 ASCII digits are empty or zero; raises positive values below 500 to 500.
    public static func scanThreshold(from text: String) -> Int {
        guard let value = Int(digitsOnly(text).prefix(9)), value > 0 else { return AppSettings.defaultScanThreshold }
        return max(value, AppSettings.minimumScanThreshold)
    }

    /// Returns the default 10,000 for nonpositive input; raises positive values below 500 to 500.
    public static func scanThreshold(value: Int) -> Int {
        guard value > 0 else { return AppSettings.defaultScanThreshold }
        return max(value, AppSettings.minimumScanThreshold)
    }

    /// Defaults to 5 for empty input. Keeps nonnegative values; 0 or 1 puts every command in one pipeline.
    public static func pipelineBatchSize(from text: String) -> Int {
        guard let value = Int(digitsOnly(text).prefix(9)) else { return AppSettings().workbenchBatchSize }
        return max(value, 0)
    }

    /// Auto-refresh rate in seconds: 1.0 ... 999.9, nil when not a number.
    public static func refreshRate(from text: String) -> Double? {
        let normalized = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard let value = Double(normalized), value.isFinite else { return nil }
        return min(max(value, 1.0), 999.9)
    }
}

/// App version and diagnostics text (Help > Copy System Info).
public struct AppVersionInfo: Hashable, Sendable {
    public var version: String
    public var build: String
    public var osVersion: String
    public var architecture: String

    public init(version: String, build: String, osVersion: String, architecture: String) {
        self.version = version
        self.build = build
        self.osVersion = osVersion
        self.architecture = architecture
    }

    public static func current(bundle: Bundle = .main) -> AppVersionInfo {
        let info = bundle.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "1.0.0"
        let build = info["CFBundleVersion"] as? String ?? "1"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return AppVersionInfo(version: version, build: build,
                              osVersion: "macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
                              architecture: currentArchitecture)
    }

    static var currentArchitecture: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }

    /// `Keystrand v1.0.0 (42)`.
    public var versionLine: String { "Keystrand v\(version) (\(build))" }

    /// Fenced diagnostics block (labels padded to 15 characters, empty rows dropped).
    public var diagnostics: String {
        let rows: [(String, String)] = [
            ("App version:", version),
            ("Build:", build),
            ("OS:", "\(osVersion) (\(architecture))"),
        ]
        let body = rows.filter { !$0.1.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { $0.0.padding(toLength: 15, withPad: " ", startingAt: 0) + $0.1 }
        return (["```", "Keystrand diagnostics"] + body + ["```"]).joined(separator: "\n")
    }
}
