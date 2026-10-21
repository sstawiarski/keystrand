import Foundation
import Testing
@testable import RedisUI

@Suite("Editor text helpers")
struct EditorTextTests {
    @Test func tokenBeforeCaret() {
        #expect(CodeEditorText.token(in: "FT.SEA", cursor: 6) == "FT.SEA")
        #expect(CodeEditorText.token(in: "GET ke", cursor: 6) == "ke")
        #expect(CodeEditorText.token(in: "GET ", cursor: 4) == "")
        #expect(CodeEditorText.token(in: "FT.SEARCH idx '@na", cursor: 18) == "@na")
        #expect(CodeEditorText.token(in: "fn(arg", cursor: 6) == "arg")
        #expect(CodeEditorText.token(in: "SET a\nGE", cursor: 8) == "GE")
        #expect(CodeEditorText.tokenRange(in: "abc", cursor: 99) == NSRange(location: 0, length: 3))
        #expect(CodeEditorText.tokenRange(in: "abc def", cursor: 5) == NSRange(location: 4, length: 1))
    }

    @Test func lineAndColumn() {
        let text = "SET a\n  EX 10\nGET a"
        #expect(CodeEditorText.lineAndColumn(in: text, offset: 0) == (0, 0))
        #expect(CodeEditorText.lineAndColumn(in: text, offset: 8) == (1, 2))
        #expect(CodeEditorText.lineAndColumn(in: text, offset: (text as NSString).length) == (2, 5))
    }

    @Test func lineStartsAndLookup() {
        let starts = CodeEditorText.lineStarts(of: "a\nbb\n\nccc")
        #expect(starts == [0, 2, 5, 6])
        #expect(CodeEditorText.lineIndex(forOffset: 0, lineStarts: starts) == 0)
        #expect(CodeEditorText.lineIndex(forOffset: 3, lineStarts: starts) == 1)
        #expect(CodeEditorText.lineIndex(forOffset: 5, lineStarts: starts) == 2)
        #expect(CodeEditorText.lineIndex(forOffset: 100, lineStarts: starts) == 3)
        #expect(CodeEditorText.lineStarts(of: "") == [0])
        #expect(CodeEditorText.lineStarts(of: "x\n") == [0, 2])
    }
}

@Suite("Snippet expansion")
struct SnippetTests {
    @Test func plainTextHasNoSelection() {
        let result = CodeSnippet.expand("GET ")
        #expect(result.text == "GET ")
        #expect(result.selection == nil)
    }

    @Test func bracedPlaceholderIsSelected() {
        let result = CodeSnippet.expand("@title:{${1:tag}}")
        #expect(result.text == "@title:{tag}")
        #expect(result.selection == NSRange(location: 8, length: 3))
    }

    @Test func lowestNumberWinsAndZeroIsLast() {
        let result = CodeSnippet.expand("$0 @g:[${2:lon} ${1:lat}]")
        #expect(result.text == " @g:[lon lat]")
        #expect(result.selection == NSRange(location: 9, length: 3))
    }

    @Test func barePlaceholderAndEscapes() {
        let result = CodeSnippet.expand(#"'idx' '$1' \$2"#)
        #expect(result.text == "'idx' '' $2")
        #expect(result.selection == NSRange(location: 7, length: 0))
    }

    @Test func templateWithNestedText() {
        let result = CodeSnippet.expand("'${1:idx}' '${2:query to search}'")
        #expect(result.text == "'idx' 'query to search'")
        #expect(result.selection == NSRange(location: 1, length: 3))
    }

    @Test func malformedPlaceholderIsLiteral() {
        #expect(CodeSnippet.expand("${x}").text == "${x}")
        #expect(CodeSnippet.expand("${1:open").text == "${1:open")
    }
}
