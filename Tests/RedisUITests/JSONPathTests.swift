import Foundation
import Testing
@testable import RedisUI

@Suite("JSON paths")
struct JSONPathTests {
    let path = JSONPath([.key("a"), .key("b"), .index(0)])

    @Test func rootRendering() {
        #expect(JSONPath.root.dotted == "$")
        #expect(JSONPath.root.bracketed == "$")
        #expect(JSONPath.root.legacy == ".")
        #expect(JSONPath.root.isRoot)
        #expect(JSONPath.root.parent == nil)
    }

    @Test func dottedPath() {
        #expect(path.dotted == "$.a.b[0]")
        #expect(path.description == "$.a.b[0]")
    }

    @Test func dottedPathUsesBracketsForNonIdentifiers() {
        let odd = JSONPath([.key("first name"), .key("1x"), .key("ok_2"), .key("é")])
        #expect(odd.dotted == #"$["first name"]["1x"].ok_2["é"]"#)
    }

    @Test func bracketedAndLegacyPaths() {
        #expect(path.bracketed == #"$["a"]["b"][0]"#)
        #expect(path.legacy == #"["a"]["b"][0]"#)
    }

    @Test func quoteSelection() {
        #expect(JSONPath([.key(#"say "hi""#)]).bracketed == #"$['say "hi"']"#)
        #expect(JSONPath([.key("it's")]).bracketed == #"$["it's"]"#)
        #expect(JSONPath([.key(#"both ' and ""#)]).bracketed == #"$["both ' and \""]"#)
        #expect(JSONPath([.key(#"back\slash"#)]).bracketed == #"$["back\\slash"]"#)
    }

    @Test func redisPathByDialect() {
        #expect(path.redisPath(jsonPath: true) == #"$["a"]["b"][0]"#)
        #expect(path.redisPath(jsonPath: false) == #"["a"]["b"][0]"#)
        #expect(JSONPath.root.redisPath(jsonPath: true) == "$")
        #expect(JSONPath.root.redisPath(jsonPath: false) == ".")
    }

    @Test func navigation() {
        #expect(path.parent == JSONPath([.key("a"), .key("b")]))
        #expect(path.last == .index(0))
        #expect(path.depth == 3)
        #expect(JSONPath.root.appending(key: "a").appending(index: 2) == JSONPath([.key("a"), .index(2)]))
        #expect(path.isDescendant(ofOrEqualTo: JSONPath([.key("a")])))
        #expect(path.isDescendant(ofOrEqualTo: path))
        #expect(!JSONPath([.key("a")]).isDescendant(ofOrEqualTo: path))
        #expect(path.isDescendant(ofOrEqualTo: .root))
    }

    @Test(arguments: [
        ("$", JSONPath.root),
        (".", JSONPath.root),
        ("$.", JSONPath.root),
        ("$.a.b[0]", JSONPath([.key("a"), .key("b"), .index(0)])),
        (#"$["a"]['b'][12]"#, JSONPath([.key("a"), .key("b"), .index(12)])),
        (#".a["x y"]"#, JSONPath([.key("a"), .key("x y")])),
        (#"["a"][1]"#, JSONPath([.key("a"), .index(1)])),
        ("a.b", JSONPath([.key("a"), .key("b")])),
        (#"$["q\"uote"]"#, JSONPath([.key(#"q"uote"#)])),
    ])
    func parsing(text: String, expected: JSONPath) throws {
        #expect(try JSONPath(parsing: text) == expected)
    }

    @Test(arguments: ["$a", "$[", #"$["a"#, "$[x]", "$..", "$.a[1"])
    func invalidPaths(text: String) {
        #expect(throws: JSONPathParseError.self) { try JSONPath(parsing: text) }
    }

    @Test func roundTrips() throws {
        let paths = [
            JSONPath([.key("a"), .index(3), .key(#"we"ird"#), .key("x.y"), .key("[z]")]),
            JSONPath([.index(0), .index(1)]),
            JSONPath([.key("")]),
        ]
        for original in paths {
            #expect(try JSONPath(parsing: original.bracketed) == original)
            #expect(try JSONPath(parsing: original.dotted) == original)
        }
    }

    @Test func componentLabels() {
        #expect(JSONPathComponent.key("name").label == "name")
        #expect(JSONPathComponent.index(4).label == "4")
    }
}
