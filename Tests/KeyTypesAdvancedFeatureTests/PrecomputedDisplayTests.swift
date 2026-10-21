import Foundation
@testable import KeyTypesAdvancedFeature
import RedisCore
import RedisUI
import Testing

struct PrecomputedDisplayTests {
    private func match(_ name: String, rank: Int, score: Double, attributes: String? = nil) -> SimilarityMatch {
        SimilarityMatch(name: Data(name.utf8), score: score, attributes: attributes, rank: rank)
    }

    @Test func collapsedTextFoldsNewlinesAndTruncates() {
        #expect(FormattedValueCell.collapsedText(.text("a\nb\r\nc")) == "a b c")
        #expect(FormattedValueCell.collapsedText(.text("abcdef"), truncateLength: 3) == "abc…")
        #expect(FormattedValueCell.collapsedText(.text("abc"), truncateLength: 3) == "abc")
        let json = FormatResult.json(.object([JSONMember(key: "k", value: .array([.number("1")]))]))
        #expect(FormattedValueCell.collapsedText(json) == #"{"k":[1]}"#)
    }

    @Test func attributeValuesParseOnceWithLastDuplicateWinning() {
        let values = VectorSetCommands.attributeValues(#"{"name":"x","n":5,"name":"y","tags":["a"]}"#)
        #expect(values == ["name": "y", "n": "5", "tags": #"["a"]"#])
        #expect(VectorSetCommands.attributeValues("not json").isEmpty)
        #expect(VectorSetCommands.attributeValues(nil).isEmpty)
    }

    @Test func similarityResultsSortByEachField() {
        let results = [
            match("e10", rank: 1, score: 0.9, attributes: #"{"c":"b"}"#),
            match("e2", rank: 2, score: 0.5, attributes: #"{"c":"a"}"#),
            match("e1", rank: 3, score: .nan),
        ]
        let attributes = Dictionary(uniqueKeysWithValues: results.map {
            ($0.name, VectorSetCommands.attributeValues($0.attributes))
        })

        func names(_ field: SimilaritySortField, ascending: Bool) -> [String] {
            VectorSetViewModel.sorted(results, by: field, ascending: ascending, attributes: attributes).map(\.nameText)
        }

        #expect(names(.rank, ascending: false) == ["e1", "e2", "e10"])
        #expect(names(.similarity, ascending: false) == ["e10", "e2", "e1"])
        #expect(names(.element, ascending: true) == ["e1", "e2", "e10"])
        #expect(names(.attribute("c"), ascending: true) == ["e1", "e2", "e10"])
        #expect(names(.attribute("c"), ascending: false) == ["e10", "e2", "e1"])
    }
}
