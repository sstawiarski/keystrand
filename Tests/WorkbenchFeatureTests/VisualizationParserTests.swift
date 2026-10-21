import Foundation
@testable import WorkbenchFeature
import RedisCore
import RedisUI
import SwiftUI
import Testing

private func s(_ text: String) -> ReplyNode { .string(text) }
private func i(_ value: Int) -> ReplyNode { .integer(String(value)) }
private func a(_ items: ReplyNode...) -> ReplyNode { .array(items) }

struct SearchResultParserTests {
    @Test func searchRowsUnionColumnsInFirstSeenOrder() throws {
        let reply = a(i(2), s("doc:1"), a(s("name"), s("bike"), s("price"), s("10")),
                      s("doc:2"), a(s("name"), s("car"), s("color"), s("red")))
        let table = try #require(SearchResultParser.parse(reply, command: "FT.SEARCH idx *"))
        #expect(table.matched == "2")
        #expect(table.columns == ["Doc", "name", "price", "color"])
        #expect(table.rows.count == 2)
        #expect(table.rows[0]["Doc"] == "doc:1")
        #expect(table.rows[1]["color"] == "red")
        #expect(table.rows[1]["price"] == nil)
    }

    @Test func noContentReturnsOnlyIDs() throws {
        let reply = a(i(3), s("a"), s("b"), s("c"))
        let table = try #require(SearchResultParser.parse(reply, command: "ft.search idx * NOCONTENT"))
        #expect(table.columns == ["Doc"])
        #expect(table.rows.map { $0["Doc"] } == ["a", "b", "c"])
    }

    @Test func withScoresAddsScoreColumnFirst() throws {
        let reply = a(i(1), s("doc:1"), s("1.5"), a(s("f"), s("v")))
        let table = try #require(SearchResultParser.parse(reply, command: "FT.SEARCH idx hello WITHSCORES"))
        #expect(table.columns == ["Doc", "Score", "f"])
        #expect(table.rows[0]["Score"] == "1.5")
        #expect(table.rows[0]["f"] == "v")
    }

    @Test func aggregateWithCursor() throws {
        let rows = a(i(5), a(s("brand"), s("x"), s("count"), s("2")), a(s("brand"), s("y")), a())
        let reply = a(rows, i(12345))
        let table = try #require(SearchResultParser.parse(reply, command: "FT.AGGREGATE idx * WITHCURSOR"))
        #expect(table.cursorID == "12345")
        #expect(table.matched == "5")
        #expect(table.columns == ["brand", "count"])
        #expect(table.rows.count == 3)
        #expect(table.rows[2].isEmpty)
    }

    @Test func profileUsesResultsPart() throws {
        let reply = a(a(i(1), s("doc:1"), a(s("n"), s("v"))), a(s("Shards"), a()))
        let table = try #require(SearchResultParser.parse(reply, command: "FT.PROFILE idx SEARCH QUERY *"))
        #expect(table.rows.first?["Doc"] == "doc:1")
    }

    @Test func nonArrayReplyIsNil() {
        #expect(SearchResultParser.parse(.error("ERR"), command: "FT.SEARCH idx *") == nil)
    }
}

struct IndexInfoParserTests {
    @Test func parsesDefinitionAttributesAndCounters() throws {
        let reply = a(
            s("index_name"), s("idx"),
            s("index_options"), a(),
            s("index_definition"), a(s("key_type"), s("HASH"), s("prefixes"), a(s("bike:"), s("car:"))),
            s("attributes"), a(
                a(s("identifier"), s("name"), s("attribute"), s("name"), s("type"), s("TEXT"), s("WEIGHT"), s("1"),
                  s("SORTABLE")),
                a(s("identifier"), s("price"), s("attribute"), s("price"), s("type"), s("NUMERIC"))),
            s("num_docs"), s("42"), s("max_doc_id"), s("50"), s("num_records"), s("100"), s("num_terms"), s("7"))
        let info = try #require(IndexInfoParser.parse(reply))
        #expect(info.keyType == "HASH")
        #expect(info.prefixes == ["bike:", "car:"])
        #expect(info.options.isEmpty)
        #expect(info.columns == ["IDENTIFIER", "ATTRIBUTE", "TYPE", "WEIGHT"])
        #expect(info.flagColumns == ["SORTABLE"])
        #expect(info.attributes[0]["SORTABLE"] == "true")
        #expect(info.attributes[1]["SORTABLE"] == nil)
        #expect(info.numDocs == "42")
        #expect(info.maxDocID == "50")
    }
}

struct ClientListParserTests {
    @Test func splitsLinesAndPairs() {
        let text = "id=3 addr=127.0.0.1:5000 name= cmd=client|list\nid=4 addr=127.0.0.1:5001 name=x cmd=get\n"
        let model = ClientListParser.parse(text)
        #expect(model.columns == ["id", "addr", "name", "cmd"])
        #expect(model.rows.count == 2)
        #expect(model.rows[0]["name"] == "")
        #expect(model.rows[1]["cmd"] == "get")
    }

    @Test func emptyTextHasNoRows() {
        #expect(ClientListParser.parse("").rows.isEmpty)
    }
}

struct TimeSeriesParserTests {
    @Test func rangeUsesKeyArgument() throws {
        let reply = a(a(i(1000), s("1.5")), a(i(2000), s("2.5")))
        let series = try #require(TimeSeriesParser.parse(reply, command: "TS.RANGE temp:1 - +"))
        #expect(series.count == 1)
        #expect(series[0].key == "temp:1")
        #expect(series[0].points.map(\.value) == [1.5, 2.5])
    }

    @Test func mrangeItems() throws {
        let reply = a(
            a(s("a"), a(a(s("sensor"), s("1"))), a(a(i(1), s("1")))),
            a(s("b"), a(), a(a(i(2), s("4")), a(i(3), s("5")))))
        let series = try #require(TimeSeriesParser.parse(reply, command: "TS.MRANGE - + FILTER sensor=1"))
        #expect(series.map(\.key) == ["a", "b"])
        #expect(series[0].labels["sensor"] == "1")
        #expect(series[1].points.count == 2)
    }

    @Test func defaultUnitFollowsFirstTimestamp() {
        let seconds = [TimeSeriesSeries(key: "k", labels: [:], points: [TimeSeriesPoint(timestamp: 1_700_000_000, value: 1)])]
        let millis = [TimeSeriesSeries(key: "k", labels: [:],
                                       points: [TimeSeriesPoint(timestamp: 1_700_000_000_000, value: 1)])]
        #expect(TimeSeriesParser.defaultUnitIsMilliseconds(seconds) == false)
        #expect(TimeSeriesParser.defaultUnitIsMilliseconds(millis))
    }

    @Test func seriesColorsFollowTheChartPaletteInInputOrder() {
        let keys = (0..<14).map { "key\($0)" }
        let colors = TimeSeriesChartView.seriesColors(for: keys)
        #expect(colors["key0"] == ChartPalette.colors[0])
        #expect(colors["key5"] == ChartPalette.colors[5])
        #expect(colors["key12"] == ChartPalette.colors[0])
        #expect(colors.count == 14)
    }
}

struct ExplainAndProfileParserTests {
    @Test func explainNestsBraces() {
        let text = """
        INTERSECT {
          UNION {
            hello
            +hello(expanded)
          }
          @price:NUMERIC {
            1 <= @price <= 5
          }
        }
        """
        guard case .tree(let root) = ExplainParser.parse(text: text) else {
            Issue.record("expected a tree")
            return
        }
        #expect(root.type == "INTERSECT")
        #expect(root.children.count == 2)
        #expect(root.children[0].type == "UNION")
        #expect(root.children[0].children.map(\.type) == ["hello", "+hello(expanded)"])
    }

    @Test func explainWildcardIsEmpty() {
        #expect(ExplainParser.parse(text: "<WILDCARD>") == .empty)
        #expect(ExplainParser.parse(.string("")) == .empty)
        #expect(ExplainParser.parse(.integer("1")) == .failure(ExplainParser.failureMessage))
    }

    @Test func explainCLIArrayJoinsLines() {
        let node = a(s("UNION {"), s("  a"), s("  b"), s("}"), s(""))
        guard case .tree(let root) = ExplainParser.parse(node) else {
            Issue.record("expected a tree")
            return
        }
        #expect(root.type == "UNION")
        #expect(root.children.count == 2)
    }

    @Test func profileNewFormat() throws {
        let shard = a(
            s("Total profile time"), s("0.5"), s("Parsing time"), s("0.1"), s("Pipeline creation time"), s("0.01"),
            s("Warning"), s("None"),
            s("Iterators profile"), a(s("Type"), s("UNION"), s("Query type"), s("UNION"), s("Time"), s("0.2"),
                                     s("Number of reading operations"), i(3),
                                     s("Child iterators"), a(
                                        a(s("Type"), s("TEXT"), s("Term"), s("hello"), s("Time"), s("0.1"),
                                          s("Number of reading operations"), i(2)),
                                        a(s("Type"), s("TEXT"), s("Term"), s("world"), s("Time"), s("0.05"),
                                          s("Number of reading operations"), i(1)))),
            s("Result processors profile"), a(
                a(s("Type"), s("Index"), s("Time"), s("0.3"), s("Results processed"), i(3)),
                a(s("Type"), s("Loader"), s("Time"), s("0.4"), s("Results processed"), i(3))))
        let reply = a(a(i(0)), a(s("Shards"), a(shard), s("Coordinator"), a()))
        let profile = try #require(ProfileParser.parse(reply))
        #expect(profile.metrics.first?.0 == "Total Profile Time")
        #expect(profile.metrics.first?.1 == "0.5")
        let tree = try #require(profile.tree)
        #expect(tree.type == "Loader")
        #expect(tree.children.first?.type == "Index")
        let iterator = try #require(tree.children.first?.children.first)
        #expect(iterator.type == "UNION")
        #expect(iterator.children.map(\.detail) == ["hello", "world"])
        #expect(iterator.counter == "3")
    }

    @Test func profileOldFormat() throws {
        let profile = a(
            a(s("Total profile time"), s("1")),
            a(s("Parsing time"), s("0.2")),
            a(s("Iterators profile"), a(s("Type"), s("WILDCARD"), s("Time"), s("0.1"), s("Counter"), i(4))),
            a(s("Result processors profile"), a(s("Type"), s("Index"), s("Time"), s("0.1"), s("Counter"), i(4))))
        let model = try #require(ProfileParser.parse(a(a(i(0)), profile)))
        #expect(model.metrics.map(\.0).contains("Parsing Time"))
        #expect(model.tree?.type == "Index")
        #expect(model.tree?.children.first?.type == "WILDCARD")
    }
}

struct GeoAndJSONParserTests {
    @Test func geosearchWithCoordinatesAndDistance() throws {
        let reply = a(a(s("Palermo"), s("190.4424"), a(s("13.361389"), s("38.115556"))),
                      a(s("Catania"), s("56.4413"), a(s("15.087269"), s("37.502669"))))
        let geo = try #require(GeoParser.parse(reply, command:
            "GEOSEARCH Sicily FROMLONLAT 15 37 BYRADIUS 200 km ASC WITHCOORD WITHDIST"))
        #expect(geo.hasCoordinates)
        #expect(geo.rows.count == 2)
        #expect(geo.rows[0].member == "Palermo")
        #expect(geo.rows[0].distance == "190.4424")
        #expect(geo.rows[0].longitude == 13.361389)
        #expect(geo.centerLongitude == 15)
        #expect(geo.centerLatitude == 37)
        #expect(geo.locatedRows.count == 2)
    }

    @Test func geoposMapsMembers() throws {
        let reply = a(a(s("13.3"), s("38.1")), .null)
        let geo = try #require(GeoParser.parse(reply, command: "GEOPOS Sicily Palermo Nowhere"))
        #expect(geo.rows.map(\.member) == ["Palermo", "Nowhere"])
        #expect(geo.rows[1].longitude == nil)
        #expect(geo.tableRows[1]["Longitude"] == "-")
    }

    @Test func georadiusCenter() {
        let center = GeoParser.queryCenter(["GEORADIUS", "k", "15", "37", "200", "km"])
        #expect(center?.0 == 15)
        #expect(center?.1 == 37)
        #expect(GeoParser.queryCenter(["GEORADIUSBYMEMBER", "k", "m", "10", "km"]) == nil)
    }

    @Test func jsonGetInASCIIModeIsUnescaped() throws {
        let value = try #require(JSONResultParser.parse(.string(#"{\"name\":\"caf\xc3\xa9\",\"n\":12345678901234567890}"#),
                                                        command: "JSON.GET doc", mode: .ascii))
        guard case .object(let members) = value else {
            Issue.record("expected an object")
            return
        }
        #expect(members.count == 2)
    }

    @Test func jsonMGetKeepsNulls() throws {
        let value = try #require(JSONResultParser.parse(a(s("[1]"), .null), command: "JSON.MGET a b $", mode: .raw))
        guard case .array(let items) = value else {
            Issue.record("expected an array")
            return
        }
        #expect(items.count == 2)
        #expect(items[1] == .null)
    }

    @Test func invalidJSONIsNil() {
        #expect(JSONResultParser.parse(.string("not json"), command: "GET k", mode: .raw) == nil)
    }

    @Test func gridJSONDetection() {
        #expect(DataGridView.looksLikeJSON(#"{"a":1}"#))
        #expect(DataGridView.looksLikeJSON("[1,2]"))
        #expect(!DataGridView.looksLikeJSON("{oops"))
        #expect(DataGridView.parseJSON(#"{\"a\":1}"#) != nil)
        #expect(DataGridView.parseJSON("plain") == nil)
    }
}

struct VisualizationRegistryTests {
    @Test func defaultsPerCommand() {
        #expect(VisualizationRegistry.defaultView(for: "FT.SEARCH idx *") == .searchTable)
        #expect(VisualizationRegistry.defaultView(for: "  ft.aggregate idx *") == .searchTable)
        #expect(VisualizationRegistry.defaultView(for: "FT.INFO idx") == .indexInfo)
        #expect(VisualizationRegistry.defaultView(for: "FT.EXPLAIN idx *") == .explain)
        #expect(VisualizationRegistry.defaultView(for: "FT.PROFILE idx SEARCH QUERY *") == .profile)
        #expect(VisualizationRegistry.defaultView(for: "JSON.GET k") == .json)
        #expect(VisualizationRegistry.defaultView(for: "GET k") == .text)
        #expect(VisualizationRegistry.defaultView(for: "client list") == .clientList)
        #expect(VisualizationRegistry.defaultView(for: "TS.MRANGE - + FILTER a=b") == .timeSeries)
        #expect(VisualizationRegistry.defaultView(for: "GEOSEARCH k FROMLONLAT 1 2 BYRADIUS 1 km WITHCOORD") == .geoMap)
        #expect(VisualizationRegistry.defaultView(for: "GEOSEARCH k FROMLONLAT 1 2 BYRADIUS 1 km") == .geoTable)
        #expect(VisualizationRegistry.defaultView(for: "FT.SEARCHX idx") == .text)
    }

    @Test func optionsStartWithText() {
        #expect(VisualizationRegistry.options(for: "GET k") == [.text, .json])
        #expect(VisualizationRegistry.options(for: "FT.PROFILE idx SEARCH QUERY *") == [.text, .profile, .searchTable])
        #expect(VisualizationRegistry.options(for: "SET k v") == [.text])
        #expect(VisualizationRegistry.options(for: "GEOSEARCH k FROMLONLAT 1 2 BYRADIUS 1 km") == [.text, .geoTable])
    }
}
