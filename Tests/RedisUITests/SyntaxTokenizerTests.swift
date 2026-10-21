import Foundation
import Testing
@testable import RedisUI

private func spans(_ text: String, _ tokens: [SyntaxToken]) -> [(SyntaxTokenKind, String)] {
    let ns = text as NSString
    return tokens.map { ($0.kind, ns.substring(with: $0.range)) }
}

private func kinds(_ text: String, _ tokens: [SyntaxToken], _ kind: SyntaxTokenKind) -> [String] {
    spans(text, tokens).filter { $0.0 == kind }.map(\.1)
}

@Suite("Redis syntax tokenizer")
struct RedisSyntaxTokenizerTests {
    let keywords: Set<String> = ["SET", "GET", "HSET", "CLIENT KILL", "CLIENT", "FT.SEARCH", "ZADD"]

    @Test func commandAtLineStartIsKeyword() {
        let text = "SET foo bar"
        let tokens = RedisSyntaxHighlighter.tokenizeRedis(text, keywords: keywords)
        #expect(kinds(text, tokens, .keyword) == ["SET"])
    }

    @Test func keywordMatchIsCaseInsensitive() {
        let text = "hset h f v"
        #expect(kinds(text, RedisSyntaxHighlighter.tokenizeRedis(text, keywords: keywords), .keyword) == ["hset"])
    }

    @Test func unknownCommandIsNotHighlighted() {
        let text = "FOO bar"
        #expect(kinds(text, RedisSyntaxHighlighter.tokenizeRedis(text, keywords: keywords), .keyword).isEmpty)
    }

    @Test func emptyKeywordSetHighlightsCommandPosition() {
        let text = "ANYTHING x"
        #expect(kinds(text, RedisSyntaxHighlighter.tokenizeRedis(text, keywords: []), .keyword) == ["ANYTHING"])
    }

    @Test func twoWordCommandHighlightsBothWords() {
        let text = "CLIENT KILL ID 5"
        let tokens = RedisSyntaxHighlighter.tokenizeRedis(text, keywords: keywords)
        #expect(kinds(text, tokens, .keyword) == ["CLIENT", "KILL"])
        #expect(kinds(text, tokens, .number) == ["5"])
    }

    @Test func repeatPrefixIsNumberThenCommand() {
        let text = "10 GET foo"
        let tokens = RedisSyntaxHighlighter.tokenizeRedis(text, keywords: keywords)
        #expect(kinds(text, tokens, .number) == ["10"])
        #expect(kinds(text, tokens, .keyword) == ["GET"])
    }

    @Test func indentedContinuationIsNotACommand() {
        let text = "ZADD z\n  GET 1"
        let tokens = RedisSyntaxHighlighter.tokenizeRedis(text, keywords: keywords)
        #expect(kinds(text, tokens, .keyword) == ["ZADD"])
        #expect(kinds(text, tokens, .number) == ["1"])
    }

    @Test func stringsWithEscapesAndBothQuoteStyles() {
        let text = #"SET "a \"b\" c" 'x y'"#
        let tokens = RedisSyntaxHighlighter.tokenizeRedis(text, keywords: keywords)
        #expect(kinds(text, tokens, .string) == [#""a \"b\" c""#, "'x y'"])
    }

    @Test func unterminatedStringRunsToEndOfLine() {
        let text = "SET \"abc\nGET x"
        let tokens = RedisSyntaxHighlighter.tokenizeRedis(text, keywords: keywords)
        #expect(kinds(text, tokens, .string) == ["\"abc"])
        #expect(kinds(text, tokens, .keyword) == ["SET", "GET"])
    }

    @Test func commentsAtTokenBoundary() {
        let text = "// whole line\nGET a // trailing\nSET http://x y"
        let tokens = RedisSyntaxHighlighter.tokenizeRedis(text, keywords: keywords)
        #expect(kinds(text, tokens, .comment) == ["// whole line", "// trailing"])
        #expect(kinds(text, tokens, .keyword) == ["GET", "SET"])
    }

    @Test func numbersIncludeNegativeDecimalAndExponent() {
        let text = "ZADD z -1.5 a 2e10 b 3x"
        let tokens = RedisSyntaxHighlighter.tokenizeRedis(text, keywords: keywords)
        #expect(kinds(text, tokens, .number) == ["-1.5", "2e10"])
    }

    @Test func paramsLineOnlyOnFirstLine() {
        let text = "[pipeline=5;mode=raw]\nGET a\n[x]"
        let tokens = RedisSyntaxHighlighter.tokenizeRedis(text, keywords: keywords)
        #expect(kinds(text, tokens, .params) == ["[pipeline=5;mode=raw]"])
        #expect(kinds(text, tokens, .bracket) == ["[", "]"])
    }

    @Test func bracketsInsideWords() {
        let text = "FT.SEARCH idx @n:[1 2]"
        let tokens = RedisSyntaxHighlighter.tokenizeRedis(text, keywords: keywords)
        #expect(kinds(text, tokens, .bracket) == ["[", "]"])
        #expect(kinds(text, tokens, .keyword) == ["FT.SEARCH"])
    }

    @Test func tokensAreOrderedAndUTF16Ranged() {
        let text = "SET 🔑 \"é\" 12"
        let tokens = RedisSyntaxHighlighter.tokenizeRedis(text, keywords: keywords)
        #expect(tokens.map(\.range.location) == tokens.map(\.range.location).sorted())
        #expect(kinds(text, tokens, .string) == ["\"é\""])
        #expect(kinds(text, tokens, .number) == ["12"])
    }

    @Test func emptyTextHasNoTokens() {
        #expect(RedisSyntaxHighlighter.tokenizeRedis("", keywords: keywords).isEmpty)
        #expect(RedisSyntaxHighlighter.tokenize("SET a b", language: .plain).isEmpty)
    }

    @Test func commandLineIndices() {
        let text = "[mode=raw]\nSET a b\n  EX 10\n// c\n\nGET a"
        #expect(RedisSyntaxHighlighter.commandLineIndices(text) == [1, 5])
    }

    @Test func defaultKeywordsComeFromCatalog() {
        let keywords = RedisSyntaxHighlighter.defaultKeywords
        if !CommandCatalog.shared.commands.isEmpty {
            #expect(keywords.contains("GET"))
            #expect(keywords.contains("SET"))
        }
    }
}

@Suite("JSON tokenizer")
struct JSONSyntaxTokenizerTests {
    @Test func keysValuesAndPunctuation() {
        let text = #"{"name": "Ann", "age": -12.5e3, "ok": true, "x": null, "l": [1, false]}"#
        let tokens = RedisSyntaxHighlighter.tokenizeJSON(text)
        #expect(kinds(text, tokens, .key) == [#""name""#, #""age""#, #""ok""#, #""x""#, #""l""#])
        #expect(kinds(text, tokens, .string) == [#""Ann""#])
        #expect(kinds(text, tokens, .number) == ["-12.5e3", "1"])
        #expect(kinds(text, tokens, .boolean) == ["true", "false"])
        #expect(kinds(text, tokens, .null) == ["null"])
        #expect(kinds(text, tokens, .bracket) == ["{", "[", "]", "}"])
        #expect(kinds(text, tokens, .punctuation).count == 10)
    }

    @Test func keyDetectionAcrossWhitespaceAndNewlines() {
        let text = "{\n  \"a\"\n   : \"b\"\n}"
        let tokens = RedisSyntaxHighlighter.tokenizeJSON(text)
        #expect(kinds(text, tokens, .key) == ["\"a\""])
        #expect(kinds(text, tokens, .string) == ["\"b\""])
    }

    @Test func escapedQuotesStayInsideString() {
        let text = #"["a\"b", "c"]"#
        #expect(kinds(text, RedisSyntaxHighlighter.tokenizeJSON(text), .string) == [#""a\"b""#, #""c""#])
    }

    @Test func invalidInputDoesNotCrash() {
        let text = "{\"a: tru, -, ]]"
        let tokens = RedisSyntaxHighlighter.tokenizeJSON(text)
        #expect(tokens.allSatisfy { NSMaxRange($0.range) <= (text as NSString).length })
    }
}
