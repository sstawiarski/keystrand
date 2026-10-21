import Foundation
@testable import KeyTypesAdvancedFeature
import RedisCore
import RedisUI
import Testing

private func words(_ args: [RedisArgument]) -> [String] {
    args.map { String(decoding: $0.data, as: UTF8.self) }
}

private func bulk(_ text: String) -> RESPValue { .bulkString(Data(text.utf8)) }

struct ZSetHelperTests {
    @Test func rangeCommandsFollowSortOrder() {
        let key = Data("z".utf8)
        #expect(words(ZSetCommands.range(key: key, offset: 0, count: 500, order: .asc)) == ["ZRANGE", "z", "0", "499", "WITHSCORES"])
        #expect(words(ZSetCommands.range(key: key, offset: 500, count: 500, order: .desc)) == ["ZREVRANGE", "z", "500", "999", "WITHSCORES"])
        #expect(words(ZSetCommands.updateScore(key: key, member: Data("m".utf8), score: "2.5")) == ["ZADD", "z", "XX", "CH", "2.5", "m"])
        #expect(words(ZSetCommands.scan(key: key, cursor: 7, pattern: "a*")) == ["ZSCAN", "z", "7", "MATCH", "a*", "COUNT", "500"])
    }

    @Test func parsesFlatAndNestedScoredReplies() {
        let flat: RESPValue = .array([bulk("a"), bulk("1"), bulk("b"), bulk("inf")])
        let members = ZSetCommands.parseScored(flat)
        #expect(members.map(\.score) == ["1", "inf"])
        #expect(members[1].isScoreEditable == false)
        #expect(members[0].isScoreEditable)

        let nested: RESPValue = .array([.array([bulk("a"), .double(1.5)]), .array([bulk("b"), .double(-.infinity)])])
        let parsed = ZSetCommands.parseScored(nested)
        #expect(parsed.map { String(decoding: $0.name, as: UTF8.self) } == ["a", "b"])
        #expect(parsed.map(\.score) == ["1.5", "-inf"])
    }

    @Test func scoreSanitizerStripsInvalidCharacters() {
        #expect(ZSetCommands.sanitizeScore("-1a2.3.4") == "-12.34")
        #expect(ZSetCommands.sanitizeScore("1-2") == "12")
        #expect(ZSetCommands.sanitizeScore("0.1234567890123456789") == "0.123456789012345")
        #expect(ZSetCommands.normalizeScore("1.") == "1")
        #expect(ZSetCommands.normalizeScore("-") == "")
        #expect(ZSetCommands.isValidScore("3.5"))
        #expect(!ZSetCommands.isValidScore(""))
        #expect(!ZSetCommands.isValidScore("abc"))
    }
}

struct StreamHelperTests {
    @Test func nextIdMath() {
        #expect(StreamID.nextId(after: "5-3", order: .desc) == "5-2")
        #expect(StreamID.nextId(after: "5-0", order: .desc) == "4")
        #expect(StreamID.nextId(after: "0-0", order: .desc) == nil)
        #expect(StreamID.nextId(after: "5-3", order: .asc) == "5-4")
        #expect(StreamID.nextId(after: "5", order: .asc) == "5-1")
    }

    @Test func entryIdValidation() {
        #expect(StreamID.entryIdError("*", lastGeneratedId: "10-1") == nil)
        #expect(StreamID.entryIdError("abc", lastGeneratedId: nil) == "Entry ID format is incorrect")
        #expect(StreamID.entryIdError("10-1", lastGeneratedId: "10-1") == "Must be greater than the last ID")
        #expect(StreamID.entryIdError("10-2", lastGeneratedId: "10-1") == nil)
        #expect(StreamID.entryIdError("10-*", lastGeneratedId: "10-5") == nil)
        #expect(StreamID.entryIdError("9-*", lastGeneratedId: "10-5") == "Must be greater than the last ID")
        #expect(StreamID.normalizeOnBlur("0-0") == "0-1")
        #expect(StreamID.filterEntryId("12a-3*") == "12-3*")
        #expect(StreamID.isValidGroupId("$"))
        #expect(StreamID.isValidGroupId("0"))
        #expect(StreamID.isValidGroupId("1-2"))
        #expect(!StreamID.isValidGroupId("1-"))
        #expect(!StreamID.isValidGroupId("12"))
    }

    @Test func claimArguments() {
        let key = Data("s".utf8)
        let group = Data("g".utf8)
        var options = ClaimOptions(consumer: Data("c2".utf8), minIdleMs: 100)
        #expect(words(StreamCommands.claim(key: key, group: group, ids: ["1-1"], options: options))
            == ["XCLAIM", "s", "g", "c2", "100", "1-1", "JUSTID"])
        options.idleMs = 50
        options.retryCount = 3
        options.force = true
        #expect(words(StreamCommands.claim(key: key, group: group, ids: ["1-1"], options: options))
            == ["XCLAIM", "s", "g", "c2", "100", "1-1", "IDLE", "50", "RETRYCOUNT", "3", "FORCE", "JUSTID"])
        options.idleMs = nil
        options.timeMs = 1_700_000_000_000
        #expect(words(StreamCommands.claim(key: key, group: group, ids: ["1-1"], options: options)).contains("TIME"))
        #expect(words(StreamCommands.autoClaim(key: key, group: group, consumer: Data("c".utf8), minIdleMs: 0, start: "0-0", count: 10))
            == ["XAUTOCLAIM", "s", "g", "c", "0", "0-0", "COUNT", "10", "JUSTID"])
    }

    @Test func rangeBoundsAndEntryCommands() {
        #expect(StreamCommands.bound(nil, edge: nil, open: "-") == "-")
        #expect(StreamCommands.bound(100, edge: 100, open: "-") == "-")
        #expect(StreamCommands.bound(150, edge: 100, open: "-") == "150")
        let key = Data("s".utf8)
        #expect(words(StreamCommands.entries(key: key, start: "-", end: "+", order: .desc))
            == ["XREVRANGE", "s", "+", "-", "COUNT", "500"])
        #expect(words(StreamCommands.entries(key: key, start: "10", end: "20", order: .asc, count: 5))
            == ["XRANGE", "s", "10", "20", "COUNT", "5"])
    }

    @Test func duplicateFieldNamesGetExtraColumns() {
        let entries = [
            StreamEntry(id: "1-1", fields: [StreamField(name: Data("a".utf8), value: Data("1".utf8)),
                                            StreamField(name: Data("a".utf8), value: Data("2".utf8))]),
            StreamEntry(id: "1-2", fields: [StreamField(name: Data("b".utf8), value: Data("3".utf8))]),
        ]
        let columns = StreamCommands.columns(for: entries)
        #expect(columns.count == 3)
        #expect(columns[1] == StreamColumn(name: Data("a".utf8), occurrence: 1))
        let values = StreamCommands.values(of: entries[0])
        #expect(values[StreamColumn(name: Data("a".utf8), occurrence: 1)] == Data("2".utf8))
    }

    @Test func parsesEntriesInfoAndPending() {
        let entry: RESPValue = .array([bulk("1-1"), .array([bulk("f"), bulk("v")])])
        #expect(StreamCommands.parseEntry(entry)?.fields.first?.value == Data("v".utf8))
        let info: RESPValue = .array([bulk("length"), .integer(2), bulk("last-generated-id"), bulk("5-1"),
                                      bulk("first-entry"), entry, bulk("last-entry"), .array([bulk("5-1"), .array([])])])
        let parsed = StreamCommands.parseInfo(info)
        #expect(parsed.length == 2)
        #expect(parsed.lastGeneratedId == "5-1")
        #expect(parsed.firstEntryId == "1-1")
        #expect(parsed.lastEntryId == "5-1")
        let pending: RESPValue = .array([.array([bulk("1-1"), bulk("c"), .integer(10), .integer(2)])])
        #expect(StreamCommands.parsePending(pending).first == PendingEntry(id: "1-1", consumer: Data("c".utf8), idleMs: 10, delivered: 2))
        let auto: RESPValue = .array([bulk("0-0"), .array([bulk("1-1"), bulk("1-2")]), .array([])])
        #expect(StreamCommands.parseAutoClaim(auto).ids == ["1-1", "1-2"])
    }
}

struct VectorSetHelperTests {
    @Test func parsesNumericAndFP32Vectors() throws {
        #expect(try VectorParser.parse("1, 2 3").get() == .values([1, 2, 3]))
        #expect(try VectorParser.parse("[0.5,0.25]").get() == .values([0.5, 0.25]))
        let fp32 = try VectorParser.parse("\\x00\\x00\\x80\\x3f").get()
        #expect(fp32 == .fp32(Data([0x00, 0x00, 0x80, 0x3f])))
        #expect(fp32.dimension == 1)
        #expect(VectorParser.parse("1, x") == .failure(.invalidNumber))
        #expect(VectorParser.parse("\\x00\\x01") == .failure(.fp32Length))
        #expect(VectorParser.parse("\\xZZ") == .failure(.invalidFP32))
        #expect(VectorParser.parse("1 2", expectedDimension: 3) == .failure(.dimensionMismatch(expected: 3, received: 2)))
        #expect(VectorParser.help("1 2 3", expectedDimension: nil).text == "Numeric list, 3 dimensions.")
    }

    @Test func addAndSimilarityBuilders() {
        let key = Data("v".utf8)
        let add = VectorSetCommands.add(key: key, element: Data("e".utf8), vector: .values([1, 2]), attributes: #"{"a":1}"#,
                                        create: VectorSetCreateOptions(quantization: .noQuant, reduceDimension: nil, buildEF: 100, links: 8))
        #expect(words(add) == ["VADD", "v", "VALUES", "2", "1", "2", "e", "NOQUANT", "EF", "100", "SETATTR", #"{"a":1}"#, "M", "8"])
        let fp = VectorSetCommands.add(key: key, element: Data("e".utf8), vector: .fp32(Data([0, 0, 128, 63])), attributes: nil)
        #expect(words(fp).prefix(3) == ["VADD", "v", "FP32"])

        let request = SimilarityRequest(key: key, query: .element(Data("e1".utf8)), count: 5, filter: ".price > 5",
                                        ef: nil, epsilon: nil, withAttributes: true)
        #expect(words(VectorSetCommands.similarity(request))
            == ["VSIM", "v", "ELE", "e1", "WITHSCORES", "WITHATTRIBS", "COUNT", "5", "FILTER", ".price > 5"])
        #expect(VectorSetCommands.similarityPreview(request) == #"VSIM v ELE e1 WITHSCORES WITHATTRIBS COUNT 5 FILTER ".price > 5""#)
        let fpRequest = SimilarityRequest(key: key, query: .vector(.fp32(Data([0, 0x80]))), count: nil, filter: nil,
                                          ef: 50, epsilon: 0.2, withAttributes: false)
        #expect(VectorSetCommands.similarityPreview(fpRequest) == #"VSIM v FP32 "\x00\x80" WITHSCORES EPSILON 0.2 EF 50"#)
    }

    @Test func quotingRules() {
        #expect(VectorSetCommands.quote("") == "\"\"")
        #expect(VectorSetCommands.quote("plain") == "plain")
        #expect(VectorSetCommands.quote("a b") == "\"a b\"")
        #expect(VectorSetCommands.quote(#"say "hi"\"#) == #""say \"hi\"\\""#)
    }

    @Test func parsesSimilarityTriplesPairsAndMaps() {
        let triples: RESPValue = .array([bulk("a"), bulk("0.9"), bulk(#"{"x":1}"#), bulk("b"), bulk("0.5"), .bulkString(nil), bulk("c")])
        let matches = VectorSetCommands.parseSimilarity(triples, withAttributes: true)
        #expect(matches.count == 2)
        #expect(matches[0].attributes == #"{"x":1}"#)
        #expect(matches[1].attributes == nil)
        #expect(matches[1].rank == 2)

        let pairs: RESPValue = .array([bulk("a"), bulk("0.9"), bulk("b")])
        #expect(VectorSetCommands.parseSimilarity(pairs, withAttributes: false).count == 1)

        let map: RESPValue = .map([(bulk("a"), .array([.double(0.75), bulk("{}")])), (bulk("b"), .double(0.5))])
        let mapped = VectorSetCommands.parseSimilarity(map, withAttributes: true)
        #expect(mapped.map(\.score) == [0.75, 0.5])
        #expect(mapped[0].attributes == "{}")
        #expect(VectorSetCommands.similarityText(0.8765) == "87.65 %")
        #expect(VectorSetCommands.similarityText(.nan) == "—")
    }

    @Test func infoMapsQuantizationAndProjection() {
        let reply: RESPValue = .array([bulk("quant-type"), bulk("f32"), bulk("vector-dim"), .integer(2),
                                       bulk("projection-input-dim"), .integer(4), bulk("size"), .integer(3)])
        let info = VectorSetCommands.parseInfo(reply)
        #expect(info.quantType == "f32")
        #expect(info.dimension == 2)
        #expect(info.inputDimension == 4)
        #expect(info.addOptions?.quantization == .noQuant)
        #expect(info.addOptions?.reduceDimension == 2)
        #expect(VectorQuantization(quantType: "int8") == .q8)
        #expect(VectorQuantization(quantType: "bin") == .bin)
    }

    @Test func filterAutocomplete() {
        let keys = ["category", "price", "year"]
        #expect(VectorSetCommands.filterSuggestions(text: ".pr", keys: keys) == ["price"])
        #expect(VectorSetCommands.filterSuggestions(text: ".price > 5 and .", keys: keys) == ["category", "year"])
        #expect(VectorSetCommands.filterSuggestions(text: "a.b", keys: keys).isEmpty)
        #expect(VectorSetCommands.applySuggestion("price", to: ".year > 1 and .p") == ".year > 1 and .price")
        #expect(VectorSetCommands.attributeKeys([#"{"b":1,"a":2}"#, "not json", #"{"c":3}"#]) == ["a", "b", "c"])
        #expect(VectorSetCommands.attributeValue(#"{"name":"x","n":5}"#, key: "name") == "x")
        #expect(VectorSetCommands.attributeValue(#"{"name":"x","n":5}"#, key: "n") == "5")
    }

    @Test func embeddingText() {
        #expect(VectorSetCommands.embeddingText([1, 0.5]).text == "[1, 0.5]")
        let long = VectorSetCommands.embeddingText([1, 2, 3], limit: 2)
        #expect(long.truncated)
        #expect(long.text == "[1, 2, ...]")
    }
}

struct TimeSeriesHelperTests {
    @Test func rangeCommandOptions() {
        let key = Data("ts".utf8)
        var query = TimeSeriesQuery()
        #expect(words(TimeSeriesCommands.range(key: key, query: query)) == ["TS.REVRANGE", "ts", "-", "+", "COUNT", "500"])
        query.order = .asc
        query.from = "1000"
        query.aggregation = .avg
        query.bucketMs = 500
        query.emptyBuckets = true
        query.minValue = 1
        query.maxValue = 2.5
        #expect(words(TimeSeriesCommands.range(key: key, query: query))
            == ["TS.RANGE", "ts", "1000", "+", "FILTER_BY_VALUE", "1", "2.5", "COUNT", "500", "AGGREGATION", "avg", "500", "EMPTY"])
    }

    @Test func nextPageMath() {
        var query = TimeSeriesQuery()
        query.order = .asc
        #expect(TimeSeriesCommands.nextPage(after: 100, query: query)?.from == "101")
        query.aggregation = .sum
        query.bucketMs = 10
        #expect(TimeSeriesCommands.nextPage(after: 100, query: query)?.from == "110")
        query.to = "105"
        #expect(TimeSeriesCommands.nextPage(after: 100, query: query) == nil)
        var desc = TimeSeriesQuery()
        desc.order = .desc
        #expect(TimeSeriesCommands.nextPage(after: 100, query: desc)?.to == "99")
        #expect(TimeSeriesCommands.nextPage(after: 0, query: desc) == nil)
    }

    @Test func parsesInfoLabelsAndSamples() {
        let reply: RESPValue = .array([
            bulk("totalSamples"), .integer(3), bulk("firstTimestamp"), .integer(1000), bulk("lastTimestamp"), .integer(3000),
            bulk("retentionTime"), .integer(0), bulk("chunkSize"), .integer(4096), bulk("duplicatePolicy"), bulk("block"),
            bulk("labels"), .array([.array([bulk("sensor"), bulk("1")])]),
            bulk("rules"), .array([.array([bulk("dest"), .integer(60000), bulk("AVG"), .integer(0)])]),
        ])
        let info = TimeSeriesCommands.parseInfo(reply)
        #expect(info.totalSamples == 3)
        #expect(info.lastTimestamp == 3000)
        #expect(info.labels.map(\.name) == ["sensor"])
        #expect(info.rules.first?.aggregation == "AVG")
        #expect(info.duplicatePolicy == "block")

        let mapLabels = TimeSeriesCommands.parseLabels(.map([(bulk("a"), bulk("1"))]))
        #expect(mapLabels.first?.value == "1")
        let samples = TimeSeriesCommands.parseSamples(.array([.array([.integer(1), bulk("1.5")]), .array([.integer(2), .double(2.25)])]))
        #expect(samples.map(\.value) == [1.5, 2.25])
        #expect(samples.map(\.valueText) == ["1.5", "2.25"])
    }

    @Test func validationAndChartThinning() {
        #expect(TimeSeriesCommands.isValidTimestamp("*"))
        #expect(TimeSeriesCommands.isValidTimestamp("123"))
        #expect(!TimeSeriesCommands.isValidTimestamp("-1"))
        #expect(TimeSeriesCommands.isValidBound(""))
        #expect(TimeSeriesCommands.isValidBound("+"))
        #expect(!TimeSeriesCommands.isValidBound("1.5"))
        #expect(TimeSeriesCommands.isValidValue("-2.5e3"))
        #expect(!TimeSeriesCommands.isValidValue("x"))
        let samples = (0..<10_000).map { TimeSeriesSample(timestamp: Int64($0), value: Double($0), valueText: "\($0)") }
        let points = TimeSeriesCommands.chartPoints(samples, limit: 100)
        #expect(points.count == 100)
        #expect(points.first?.timestamp == 0)
        #expect(points.last?.timestamp == 9_999)
        #expect(TimeSeriesCommands.durationText(ms: 0) == "No limit")
    }
}

struct ArrayHelperTests {
    @Test func indexParsing() {
        #expect(ArrayIndex.parse("0") == 0)
        #expect(ArrayIndex.parse("18446744073709551614") == 18_446_744_073_709_551_614)
        #expect(ArrayIndex.parse("18446744073709551615") == nil)
        #expect(ArrayIndex.parse("007") == nil)
        #expect(ArrayIndex.parse("-1") == nil)
        #expect(ArrayIndex.parse("") == nil)
        #expect(ArrayIndex.span(9, 0) == 10)
        #expect(ArrayIndex.span(0, 999_999) == 1_000_000)
        let small = ArrayIndex.revealWindow(for: 4)
        #expect(small.start == 0 && small.end == 4)
        let large = ArrayIndex.revealWindow(for: 100)
        #expect(large.start == 91 && large.end == 100)
        #expect(ArrayIndex.text(.integer(13)) == "13")
        #expect(ArrayIndex.text(.bigNumber("18446744073709551615")) == "18446744073709551615")
    }

    @Test func grepAndAggregateBuilders() {
        let key = Data("a".utf8)
        var request = ArrayGrepRequest(start: "", end: nil,
                                       predicates: [ArrayGrepPredicate(criteria: .exact, pattern: "x"),
                                                    ArrayGrepPredicate(criteria: .match, pattern: "7")],
                                       combineWithAnd: false, noCase: false, withValues: true, limit: 5)
        #expect(words(ArrayCommands.grep(key: key, request: request))
            == ["ARGREP", "a", "-", "+", "EXACT", "x", "MATCH", "7", "OR", "WITHVALUES", "LIMIT", "5"])
        request.predicates = [ArrayGrepPredicate(criteria: .re, pattern: "^a")]
        request.start = "10"
        request.noCase = true
        request.withValues = false
        request.limit = nil
        #expect(words(ArrayCommands.grep(key: key, request: request)) == ["ARGREP", "a", "10", "+", "RE", "^a", "NOCASE"])
        #expect(words(ArrayCommands.aggregate(key: key, start: 0, end: 9, op: .match, value: "")) == ["AROP", "a", "0", "9", "MATCH", ""])
        #expect(words(ArrayCommands.aggregate(key: key, start: 0, end: 9, op: .sum, value: "ignored")) == ["AROP", "a", "0", "9", "SUM"])
        #expect(ArrayCommands.preview(ArrayCommands.scan(key: Data("my key".utf8), start: 0, end: 9))
            == #"ARSCAN "my key" 0 9 LIMIT 1000000"#)
    }

    @Test func replyNormalization() {
        let nested: RESPValue = .array([.array([.integer(0), bulk("a")]), .array([.integer(5), .bulkString(nil)])])
        #expect(ArrayCommands.parsePairs(nested).map(\.index) == ["0"])
        let flat: RESPValue = .array([.integer(3), bulk("x"), .integer(10), bulk("7")])
        #expect(ArrayCommands.parsePairs(flat).map(\.index) == ["3", "10"])
        let indexes: RESPValue = .array([.integer(0), .integer(2)])
        #expect(ArrayCommands.parseGrep(indexes, withValues: false).map(\.index) == ["0", "2"])
        let range: RESPValue = .array([bulk("f"), .bulkString(nil), bulk("c")])
        let reversed = ArrayCommands.parseRange(range, start: 5, end: 3)
        #expect(reversed.map(\.index) == ["5", "4", "3"])
        #expect(reversed[1].value == nil)
    }
}

struct NoticeTests {
    @Test func moduleNoticesAndInspectCommands() {
        let graph = KeyTypeNotice(type: .graph, keyName: "g")
        #expect(graph.isModuleNotice)
        #expect(graph.title == "RedisGraph Key")
        #expect(graph.description(note: nil) == "Use Redis commands in Workbench to view the value.")
        #expect(KeyTypeNotice(type: .timeSeries, keyName: "t").title == "RedisTimeSeries Key")
        let bloom = KeyTypeNotice(type: .unknown("MBbloom--"), keyName: "my bloom")
        #expect(!bloom.isModuleNotice)
        #expect(bloom.title == "Unsupported Key Type")
        #expect(bloom.workbenchScript == #"BF.INFO "my bloom""#)
        #expect(bloom.description(note: nil).hasPrefix("This key type is not currently supported. Use Redis commands"))
        let custom = KeyTypeNotice(type: .unknown("custom"), keyName: "k")
        #expect(custom.workbenchScript == nil)
        #expect(custom.description(note: "Needs Redis 8.8.") == "This key type is not currently supported.\n\nNeeds Redis 8.8.")
    }
}

struct JSONHelperTests {
    @Test func unwrapsJSONPathReplies() throws {
        #expect(JSONCommands.typeName(.array([bulk("object")]), jsonPath: true) == "object")
        #expect(JSONCommands.typeName(.array([.array([bulk("array")])]), jsonPath: true) == "array")
        #expect(JSONCommands.typeName(bulk("integer"), jsonPath: false) == "integer")
        #expect(JSONCommands.unwrap(.array([]), jsonPath: true) == nil)
        let value = try JSONCommands.parseGet("[{\"a\":12345678901234567890}]", jsonPath: true)
        #expect(JSONLiteral.format(value).contains("12345678901234567890"))
        #expect(throws: (any Error).self) { try JSONCommands.parseGet("[]", jsonPath: true) }
        #expect(JSONNodeType(reply: "OBJECT") == .object)
        #expect(JSONNodeType.array.containerKind == .array)
        #expect(JSONNodeType.string.containerKind == nil)
    }
}

struct PresentationHelperTests {
    @Test func timeSeriesSummaryItemsAndDetails() {
        var info = TimeSeriesInfo()
        #expect(TimeSeriesSummary.items(info).map(\.label) == ["First", "Last", "Retention", "Duplicates", "Chunks"])
        #expect(TimeSeriesSummary.items(info).first?.value == "—")
        #expect(TimeSeriesSummary.detailsText(info) == nil)

        info.totalSamples = 2
        info.firstTimestamp = 1_000
        info.lastTimestamp = 2_000
        info.memoryUsage = 4_096
        info.chunkCount = 1
        info.labels = [TimeSeriesLabel(name: "room", value: "a")]
        info.rules = [TimeSeriesRule(destination: Data("avg".utf8), bucketMs: 60_000, aggregation: "AVG", alignment: 0)]
        let items = TimeSeriesSummary.items(info)
        #expect(items.map(\.label).last == "Memory")
        #expect(items.first?.value == "1000")
        #expect(TimeSeriesSummary.chunkText(info) == "1")
        #expect(TimeSeriesSummary.detailsText(info) == "Labels: room=a · Rules: avg AVG 60000 ms")
    }

    @Test func pagedTablesLoadNearTheEnd() {
        let ids = Array(0..<100)
        #expect(KeyDetailsLayout.isNearEnd(99, in: ids))
        #expect(KeyDetailsLayout.isNearEnd(80, in: ids))
        #expect(!KeyDetailsLayout.isNearEnd(79, in: ids))
        #expect(KeyDetailsLayout.isNearEnd(0, in: [0, 1]))
        #expect(KeyDetailsLayout.isCompact(559))
        #expect(!KeyDetailsLayout.isCompact(560))
    }

    @Test func removalTextAndStreamPages() {
        #expect(RemovalText.title("m") == "Remove “m”?")
        #expect(RemovalText.title("g", verb: "Delete") == "Delete “g”?")
        #expect(RemovalText.message(keyName: "k", lastItemWarning: nil) == "It will be removed from “k”.")
        #expect(RemovalText.message(keyName: "k", lastItemWarning: "Removing the last item deletes the key.")
            == "It will be removed from “k”. Removing the last item deletes the key.")
        #expect(Bytes.short(String(repeating: "a", count: 80)).contains("…"))
        #expect(StreamPage(.data) == .entries)
        #expect(StreamPage(.groups) == .groups)
        #expect(StreamPage(.consumers) == .groups)
        #expect(StreamPage(.messages) == .groups)
    }
}
