import Foundation

public enum SyntaxTokenKind: String, Hashable, Sendable {
    /// Redis command name (first token of a command line).
    case keyword
    case string
    case number
    case comment
    case bracket
    /// Workbench params line (`[pipeline=5;mode=raw]` on line 1).
    case params
    /// JSON object key.
    case key
    case boolean
    case null
    /// JSON `:` and `,`.
    case punctuation
}

/// A highlighted span. `range` is in UTF-16 units so it can be applied directly to `NSTextStorage`.
public struct SyntaxToken: Hashable, Sendable {
    public var kind: SyntaxTokenKind
    public var range: NSRange

    public init(kind: SyntaxTokenKind, range: NSRange) {
        self.kind = kind
        self.range = range
    }

    public init(_ kind: SyntaxTokenKind, _ location: Int, _ length: Int) {
        self.init(kind: kind, range: NSRange(location: location, length: length))
    }
}

/// Pure tokenizer for the Redis (Workbench / CLI) language and JSON.
public enum RedisSyntaxHighlighter {
    /// Upper-cased command names from the bundled command specs (including two-word container commands).
    public static let defaultKeywords: Set<String> = Set(CommandCatalog.shared.commands.keys.map { $0.uppercased() })

    public static func tokenize(_ text: String, language: CodeLanguage, keywords: Set<String>? = nil) -> [SyntaxToken] {
        switch language {
        case .redis: return tokenizeRedis(text, keywords: keywords ?? defaultKeywords)
        case .json: return tokenizeJSON(text)
        case .plain: return []
        }
    }

    // MARK: Redis

    /// A line starting at column 0 begins a command. Its first word (or the second after a numeric repeat prefix)
    /// is a keyword if it is in `keywords`; two-word commands such as `CLIENT KILL` highlight both words.
    /// Indented lines are continuations. `"…"`/`'…'` strings honor backslash escapes. `//` starts a comment at a token
    /// boundary. Numeric words are numbers; a bracketed first line is the params line.
    /// An empty `keywords` set treats every command-position word as a keyword.
    public static func tokenizeRedis(_ text: String, keywords: Set<String>) -> [SyntaxToken] {
        let chars = Array(text.utf16)
        var tokens: [SyntaxToken] = []
        var lineStart = 0
        var lineIndex = 0
        while lineStart <= chars.count {
            var lineEnd = lineStart
            while lineEnd < chars.count, chars[lineEnd] != Char.newline { lineEnd += 1 }
            tokenizeRedisLine(chars, start: lineStart, end: lineEnd, lineIndex: lineIndex, keywords: keywords, into: &tokens)
            lineStart = lineEnd + 1
            lineIndex += 1
        }

        return tokens
    }

    /// Zero-based indices of lines that start a command (not continuation, comment, blank or params lines).
    public static func commandLineIndices(_ text: String) -> [Int] {
        var result: [Int] = []
        var index = 0
        text.enumerateLines { line, _ in
            if isCommandLine(line, lineIndex: index) { result.append(index) }
            index += 1
        }
        return result
    }

    static func isCommandLine(_ line: String, lineIndex: Int) -> Bool {
        guard let first = line.first, !first.isWhitespace else { return false }
        if line.hasPrefix("//") { return false }
        if lineIndex == 0, isParamsLine(line) { return false }
        return true
    }

    static func isParamsLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.count >= 2 && trimmed.hasPrefix("[") && trimmed.hasSuffix("]")
    }

    private struct Word {
        var start: Int
        var end: Int
        var quoted: Bool
    }

    private static func tokenizeRedisLine(_ chars: [UInt16], start: Int, end: Int, lineIndex: Int,
                                          keywords: Set<String>, into tokens: inout [SyntaxToken]) {
        guard start < end else { return }
        if lineIndex == 0 {
            let line = String(utf16CodeUnits: Array(chars[start..<end]), count: end - start)
            if isParamsLine(line) {
                var s = start
                while s < end, Char.isSpace(chars[s]) { s += 1 }
                var e = end
                while e > s, Char.isSpace(chars[e - 1]) { e -= 1 }
                tokens.append(SyntaxToken(.params, s, e - s))
                return
            }
        }

        let isCommandStart = !Char.isSpace(chars[start])
        var lineTokens: [SyntaxToken] = []
        var words: [Word] = []
        var i = start
        while i < end {
            let c = chars[i]
            if Char.isSpace(c) { i += 1; continue }
            if c == Char.slash, i + 1 < end, chars[i + 1] == Char.slash {
                lineTokens.append(SyntaxToken(.comment, i, end - i))
                break
            }

            if c == Char.doubleQuote || c == Char.singleQuote {
                let close = scanQuoted(chars, from: i, end: end)
                lineTokens.append(SyntaxToken(.string, i, close - i))
                words.append(Word(start: i, end: close, quoted: true))
                i = close
                continue
            }

            var j = i
            while j < end, !Char.isSpace(chars[j]) { j += 1 }
            words.append(Word(start: i, end: j, quoted: false))
            i = j
        }

        var commandWordIndices: Set<Int> = []
        if isCommandStart, let first = words.first, !first.quoted {
            var commandIndex = 0
            if isInteger(chars, first), words.count > 1, !words[1].quoted { commandIndex = 1 }
            let name = upper(chars, words[commandIndex])
            if commandIndex + 1 < words.count, !words[commandIndex + 1].quoted,
               keywords.contains(name + " " + upper(chars, words[commandIndex + 1])) {
                commandWordIndices = [commandIndex, commandIndex + 1]
            } else if keywords.isEmpty || keywords.contains(name) {
                commandWordIndices = [commandIndex]
            }
        }

        for (index, word) in words.enumerated() where !word.quoted {
            if commandWordIndices.contains(index) {
                lineTokens.append(SyntaxToken(.keyword, word.start, word.end - word.start))
            } else if isNumber(chars, word) {
                lineTokens.append(SyntaxToken(.number, word.start, word.end - word.start))
            } else {
                for k in word.start..<word.end where Char.isBracket(chars[k]) {
                    lineTokens.append(SyntaxToken(.bracket, k, 1))
                }
            }
        }

        lineTokens.sort { $0.range.location < $1.range.location }
        tokens.append(contentsOf: lineTokens)
    }

    /// Returns the index just past the closing quote (or `end` when unterminated).
    private static func scanQuoted(_ chars: [UInt16], from start: Int, end: Int) -> Int {
        let quote = chars[start]
        var i = start + 1
        while i < end {
            if chars[i] == Char.backslash { i += 2; continue }
            if chars[i] == quote { return i + 1 }
            i += 1
        }

        return min(i, end)
    }

    private static func upper(_ chars: [UInt16], _ word: Word) -> String {
        String(utf16CodeUnits: Array(chars[word.start..<word.end]), count: word.end - word.start).uppercased()
    }

    private static func isInteger(_ chars: [UInt16], _ word: Word) -> Bool {
        guard word.end > word.start else { return false }
        return chars[word.start..<word.end].allSatisfy(Char.isDigit)
    }

    private static func isNumber(_ chars: [UInt16], _ word: Word) -> Bool {
        let slice = Array(chars[word.start..<word.end])
        return scanNumber(slice, from: 0) == slice.count && !slice.isEmpty
    }

    /// Scans `-?digits(.digits)?([eE][+-]?digits)?` and returns the end index, or `from` when no number starts there.
    static func scanNumber(_ chars: [UInt16], from start: Int) -> Int {
        var i = start
        if i < chars.count, chars[i] == Char.minus { i += 1 }
        let digitsStart = i
        while i < chars.count, Char.isDigit(chars[i]) { i += 1 }
        guard i > digitsStart else { return start }
        if i + 1 < chars.count, chars[i] == Char.dot, Char.isDigit(chars[i + 1]) {
            i += 1
            while i < chars.count, Char.isDigit(chars[i]) { i += 1 }
        }

        if i < chars.count, chars[i] == Char.lowerE || chars[i] == Char.upperE {
            var j = i + 1
            if j < chars.count, chars[j] == Char.plus || chars[j] == Char.minus { j += 1 }
            let expStart = j
            while j < chars.count, Char.isDigit(chars[j]) { j += 1 }
            if j > expStart { i = j }
        }

        return i
    }

    // MARK: JSON

    /// Strings (keys when followed by `:`), numbers, `true`/`false`, `null`, brackets and `:`/`,`. Tolerates invalid input.
    public static func tokenizeJSON(_ text: String) -> [SyntaxToken] {
        let chars = Array(text.utf16)
        var tokens: [SyntaxToken] = []
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if Char.isSpace(c) || c == Char.newline || c == Char.carriageReturn { i += 1; continue }
            if c == Char.doubleQuote {
                var j = i + 1
                var closed = false
                while j < chars.count {
                    if chars[j] == Char.backslash { j += 2; continue }
                    if chars[j] == Char.doubleQuote { closed = true; j += 1; break }
                    if chars[j] == Char.newline { break }
                    j += 1
                }

                j = min(j, chars.count)
                var k = j
                while k < chars.count, Char.isSpace(chars[k]) || chars[k] == Char.newline || chars[k] == Char.carriageReturn { k += 1 }
                let isKey = closed && k < chars.count && chars[k] == Char.colon
                tokens.append(SyntaxToken(isKey ? .key : .string, i, j - i))
                i = j
                continue
            }

            if c == Char.minus || Char.isDigit(c) {
                let end = scanNumber(chars, from: i)
                if end > i {
                    tokens.append(SyntaxToken(.number, i, end - i))
                    i = end
                    continue
                }
            }

            if Char.isBracket(c) && c != Char.openParen && c != Char.closeParen {
                tokens.append(SyntaxToken(.bracket, i, 1))
                i += 1
                continue
            }

            if c == Char.colon || c == Char.comma {
                tokens.append(SyntaxToken(.punctuation, i, 1))
                i += 1
                continue
            }

            if Char.isLetter(c) {
                var j = i
                while j < chars.count, Char.isLetter(chars[j]) { j += 1 }
                let word = String(utf16CodeUnits: Array(chars[i..<j]), count: j - i)
                switch word {
                case "true", "false": tokens.append(SyntaxToken(.boolean, i, j - i))
                case "null": tokens.append(SyntaxToken(.null, i, j - i))
                default: break
                }

                i = j
                continue
            }

            i += 1
        }

        return tokens
    }
}

enum Char {
    static let newline: UInt16 = 10
    static let carriageReturn: UInt16 = 13
    static let space: UInt16 = 32
    static let tab: UInt16 = 9
    static let doubleQuote: UInt16 = 34
    static let singleQuote: UInt16 = 39
    static let backslash: UInt16 = 92
    static let slash: UInt16 = 47
    static let minus: UInt16 = 45
    static let plus: UInt16 = 43
    static let dot: UInt16 = 46
    static let colon: UInt16 = 58
    static let comma: UInt16 = 44
    static let lowerE: UInt16 = 101
    static let upperE: UInt16 = 69
    static let openParen: UInt16 = 40
    static let closeParen: UInt16 = 41

    static func isSpace(_ c: UInt16) -> Bool { c == space || c == tab || c == carriageReturn }
    static func isDigit(_ c: UInt16) -> Bool { c >= 48 && c <= 57 }
    static func isLetter(_ c: UInt16) -> Bool { (c >= 65 && c <= 90) || (c >= 97 && c <= 122) }
    static func isBracket(_ c: UInt16) -> Bool { c == 123 || c == 125 || c == 91 || c == 93 || c == 40 || c == 41 }
}
