import Foundation
import Testing
@testable import RedisUI

@Suite("Markdown parser")
struct MarkdownParserTests {
    @Test func headingsParagraphsAndRules() {
        let blocks = MarkdownParser.parse("# Title #\n\nSome *text*\nwrapped  \nhard\n\n---\n####### not heading")
        #expect(blocks == [
            .heading(level: 1, text: "Title"),
            .paragraph("Some *text* wrapped\nhard"),
            .rule,
            .paragraph("####### not heading"),
        ])
    }

    @Test func fencedCodeKeepsInfoAndContent() {
        let blocks = MarkdownParser.parse("```redis:[run_confirmation=true] Create\nSET a b\n\n  GET a\n```\nafter")
        #expect(blocks == [
            .code(MarkdownCodeBlock(language: "redis", info: "redis:[run_confirmation=true] Create", code: "SET a b\n\n  GET a")),
            .paragraph("after"),
        ])
    }

    @Test func unterminatedFenceRunsToEnd() {
        #expect(MarkdownParser.parse("~~~\nx") == [.code(MarkdownCodeBlock(language: nil, info: "", code: "x"))])
    }

    @Test func listsWithNestingOrderingAndTasks() {
        let blocks = MarkdownParser.parse("- one\n  continued\n  - nested\n1. first\n2) second\n- [x] done\n- [ ] todo")
        #expect(blocks == [.list([
            MarkdownListItem(text: "one continued"),
            MarkdownListItem(text: "nested", level: 1),
            MarkdownListItem(text: "first", ordered: true, number: 1),
            MarkdownListItem(text: "second", ordered: true, number: 2),
            MarkdownListItem(text: "done", checked: true),
            MarkdownListItem(text: "todo", checked: false),
        ])])
    }

    @Test func blockQuotesAreRecursive() {
        let blocks = MarkdownParser.parse("> **Note**\n> - a\n>\n> text")
        #expect(blocks == [.quote([.paragraph("**Note**"), .list([MarkdownListItem(text: "a")]), .paragraph("text")])])
    }

    @Test func tablesWithAlignment() {
        let blocks = MarkdownParser.parse("| Name | Count | Mid |\n|:-----|------:|:---:|\n| a | 1 | x |\n| b \\| c |\n\nnext")
        #expect(blocks == [
            .table(headers: ["Name", "Count", "Mid"], alignments: [.leading, .trailing, .center],
                   rows: [["a", "1", "x"], ["b | c", "", ""]]),
            .paragraph("next"),
        ])
    }

    @Test func standaloneImage() {
        #expect(MarkdownParser.parse("![Diagram](images/d.png \"title\")") == [.image(alt: "Diagram", source: "images/d.png")])
        #expect(MarkdownParser.parse("Text ![i](x.png) inline") == [.paragraph("Text ![i](x.png) inline")])
    }

    @Test func pipeWithoutSeparatorIsParagraph() {
        #expect(MarkdownParser.parse("a | b\nc") == [.paragraph("a | b c")])
    }

    @Test func crlfInput() {
        #expect(MarkdownParser.parse("## A\r\nb\r\n") == [.heading(level: 2, text: "A"), .paragraph("b")])
    }
}
