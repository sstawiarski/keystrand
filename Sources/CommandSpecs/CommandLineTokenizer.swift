import Foundation

/// One word of a partially typed command line.
public struct CommandLineToken: Hashable, Sendable {
    /// Value with quotes removed and simple escapes resolved.
    public var text: String
    /// UTF-16 range in the source text, quotes included.
    public var range: NSRange
    public var isQuoted: Bool
    /// False when a quote was opened and not closed (the user is still typing inside it).
    public var isTerminated: Bool

    public init(text: String, range: NSRange, isQuoted: Bool = false, isTerminated: Bool = true) {
        self.text = text
        self.range = range
        self.isQuoted = isQuoted
        self.isTerminated = isTerminated
    }

    public var end: Int { range.location + range.length }
}

public struct TokenizedCommandLine: Hashable, Sendable {
    public var tokens: [CommandLineToken]
    /// True when the text ends with whitespace (the next token has not started yet).
    public var endsWithSeparator: Bool

    public init(tokens: [CommandLineToken], endsWithSeparator: Bool) {
        self.tokens = tokens
        self.endsWithSeparator = endsWithSeparator
    }

    public var hasUnterminatedQuote: Bool { tokens.last.map { !$0.isTerminated } ?? false }
}

/// Quote-aware tokenizer for completion and hints. Never throws; leaves unterminated quotes open.
public enum CommandLineTokenizer {
    private static let space: UInt16 = 0x20, tab: UInt16 = 0x09, lf: UInt16 = 0x0A, cr: UInt16 = 0x0D
    private static let dquote: UInt16 = 0x22, squote: UInt16 = 0x27, backslash: UInt16 = 0x5C

    public static func isSeparator(_ unit: UInt16) -> Bool {
        unit == space || unit == tab || unit == lf || unit == cr
    }

    public static func tokenize(_ text: String) -> TokenizedCommandLine {
        let units = Array(text.utf16)
        var tokens: [CommandLineToken] = []
        var i = 0
        while i < units.count {
            while i < units.count, isSeparator(units[i]) { i += 1 }
            guard i < units.count else { break }
            let start = i
            var value: [UInt16] = []
            var quoted = false
            var terminated = true
            while i < units.count, !isSeparator(units[i]) {
                let c = units[i]
                if c == dquote || c == squote {
                    quoted = true
                    let quote = c
                    i += 1
                    var closed = false
                    while i < units.count {
                        let q = units[i]
                        if q == backslash, i + 1 < units.count, quote == dquote || units[i + 1] == squote {
                            value.append(unescape(units[i + 1]))
                            i += 2
                            continue
                        }

                        if q == quote {
                            closed = true
                            i += 1
                            break
                        }

                        value.append(q)
                        i += 1
                    }

                    if !closed { terminated = false }
                } else {
                    value.append(c)
                    i += 1
                }
            }

            let token = CommandLineToken(text: String(utf16CodeUnits: value, count: value.count),
                                         range: NSRange(location: start, length: i - start),
                                         isQuoted: quoted, isTerminated: terminated)
            tokens.append(token)
        }

        let endsWithSeparator = units.last.map(isSeparator) ?? true
        return TokenizedCommandLine(tokens: tokens, endsWithSeparator: endsWithSeparator && !(tokens.last.map { !$0.isTerminated } ?? false))
    }

    /// Counts words using the CLI hint rules, including quoted and bracketed groups.
    public static func wordCount(_ text: String) -> Int {
        guard let regex = try? NSRegularExpression(pattern: #"(?:'[^']*'|[^\s'"]|"[^"]*"|\[[^\]]*\])+"#) else {
            return tokenize(text).tokens.count
        }
        return regex.numberOfMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length))
    }

    private static func unescape(_ unit: UInt16) -> UInt16 {
        switch unit {
        case 0x6E: return lf          // n
        case 0x72: return cr          // r
        case 0x74: return tab         // t
        default: return unit
        }
    }
}
