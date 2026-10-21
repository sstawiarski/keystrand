import Foundation
import RedisCore
import Testing
@testable import VectorSearchFeature

struct FTCreateBuilderTests {
    @Test func emptyFieldsProduceNoCommand() {
        #expect(FTCreateBuilder.command(indexName: "idx", keyType: .hash, prefix: "p:", fields: []) == "")
    }

    @Test func hashCommandOrdersFieldsByTypeRank() {
        let fields = [
            IndexFieldDraft(name: "title", type: .text),
            IndexFieldDraft(name: "weight", type: .numeric),
            IndexFieldDraft(name: "tags", type: .tag),
            IndexFieldDraft(name: "loc", type: .geo),
        ]
        let command = FTCreateBuilder.command(indexName: "  idx:trails ", keyType: .hash, prefix: "trail:", fields: fields)
        #expect(command == """
        FT.CREATE "idx:trails"
          ON HASH
            PREFIX 1 "trail:"
          SCHEMA
            "weight" NUMERIC
            "loc" GEO
            "tags" TAG
            "title" TEXT
        """)
    }

    @Test func jsonReferencesUseAlias() {
        #expect(FTCreateBuilder.reference("title", keyType: .json) == "$.title AS \"title\"")
        #expect(FTCreateBuilder.reference("title", keyType: .hash) == "\"title\"")
    }

    @Test func quotesAndBackslashesAreEscaped() {
        #expect(FTCreateBuilder.quote(#"a"b\c"#) == #""a\"b\\c""#)
        let command = FTCreateBuilder.command(indexName: "i", keyType: .hash, prefix: "",
                                              fields: [IndexFieldDraft(name: "f", type: .tag)])
        #expect(command.contains(#"PREFIX 1 """#))
    }

    @Test func textOptions() {
        var field = IndexFieldDraft(name: "t", type: .text)
        #expect(FTCreateBuilder.schemaLines(field, keyType: .hash) == [#""t" TEXT"#])
        field.text.weight = 2.5
        field.text.phonetic = .english
        #expect(FTCreateBuilder.schemaLines(field, keyType: .hash) == [#""t" TEXT WEIGHT 2.5 PHONETIC dm:en"#])
    }

    @Test func flatVectorParams() {
        var field = IndexFieldDraft(name: "v", type: .vector)
        field.vector.dimensions = 768
        field.vector.distanceMetric = .l2
        field.vector.initialCap = 111
        let lines = FTCreateBuilder.schemaLines(field, keyType: .hash)
        #expect(lines == [#""v" VECTOR FLAT 8"#, "  TYPE FLOAT32", "  DIM 768", "  DISTANCE_METRIC L2", "  INITIAL_CAP 111"])
    }

    @Test func hnswVectorParams() {
        var field = IndexFieldDraft(name: "v", type: .vector)
        field.vector.algorithm = .hnsw
        field.vector.dataType = .float64
        field.vector.dimensions = nil
        let lines = FTCreateBuilder.schemaLines(field, keyType: .json)
        #expect(lines.first == #"$.v AS "v" VECTOR HNSW 14"#)
        #expect(lines.contains("  DIM 384"))
        #expect(lines.contains("  M 16"))
        #expect(lines.contains("  EF_CONSTRUCTION 200"))
        #expect(lines.contains("  EF_RUNTIME 10"))
        #expect(lines.contains("  EPSILON 0.01"))
        #expect(lines.contains("  TYPE FLOAT64"))
    }

    @Test func numberFormatting() {
        #expect(FTCreateBuilder.formatNumber(3) == "3")
        #expect(FTCreateBuilder.formatNumber(0.25) == "0.25")
    }
}

struct FieldTypeInferenceTests {
    @Test func prefixAndIndexName() {
        #expect(FieldTypeInference.prefix(forKey: "trail:coast:1") == "trail:coast:")
        #expect(FieldTypeInference.prefix(forKey: "plain") == "")
        #expect(FieldTypeInference.defaultIndexName(prefix: "trail:coast:") == "idx:trail:coast")
        #expect(FieldTypeInference.defaultIndexName(prefix: "") == "idx:myindex")
    }

    static func floatBlob(_ values: [Float]) -> Data {
        var data = Data()
        for value in values {
            withUnsafeBytes(of: value.bitPattern.littleEndian) { data.append(contentsOf: $0) }
        }

        return data
    }

    @Test func float32VectorDetection() {
        let blob = Self.floatBlob([0.5, -1.25, 3, 0.001, 7])
        #expect(FieldTypeInference.isFloat32Vector(blob))
        #expect(!FieldTypeInference.isFloat32Vector(Data("abcdefgh".utf8)))
        #expect(!FieldTypeInference.isFloat32Vector(Data([0xff, 0xfe, 0xfd])))
        #expect(!FieldTypeInference.isFloat32Vector(Self.floatBlob([.nan, 1])))
    }

    @Test func toPrecisionMatchesJavaScript() {
        #expect(FieldTypeInference.toPrecision(0.5, 6) == "0.500000")
        #expect(FieldTypeInference.toPrecision(-1.25, 6) == "-1.25000")
        #expect(FieldTypeInference.toPrecision(123456789, 6) == "1.23457e+8")
        #expect(FieldTypeInference.toPrecision(0.0000001234, 6) == "1.23400e-7")
        #expect(FieldTypeInference.toPrecision(0, 6) == "0.00000")
    }

    @Test func hashInferenceAppendsVectorsLast() {
        let pairs: [(field: Data, value: Data)] = [
            (Data("embedding".utf8), Self.floatBlob([1, 2, 3, 4, 5, 6])),
            (Data("price".utf8), Data("1200".utf8)),
            (Data("location".utf8), Data("-122.4, 37.7".utf8)),
            (Data("brand".utf8), Data("Trek".utf8)),
            (Data("description".utf8), Data(String(repeating: "word ", count: 20).utf8)),
            (Data("vec_json".utf8), Data("[0.1, 0.2, 0.3]".utf8)),
        ]
        let fields = FieldTypeInference.inferHash(pairs)
        #expect(fields.map(\.name) == ["price", "location", "brand", "description", "vec_json", "embedding"])
        #expect(fields.map(\.type) == [.numeric, .geo, .tag, .text, .vector, .vector])
        #expect(fields[4].vector.dimensions == 3)
        let vector = fields[5]
        #expect(vector.vector.dimensions == 6)
        #expect(vector.vector.algorithm == .flat)
        #expect(vector.vector.dataType == .float32)
        #expect(vector.sampleValue == "[1.00000, 2.00000, 3.00000, 4.00000, ...] (6 dims)")
    }

    @Test func jsonInferenceSkipsNestedContainers() throws {
        let json = try JSONParser.parse(#"[{"title":"Toy Story","year":1995,"active":true,"none":null,"loc":{"lon":10,"lat":20},"coords":[10,20],"embedding":[0.1,0.2,0.3],"meta":{"a":1},"tags":["a","b"],"numstr":"42"}]"#)
        let result = FieldTypeInference.inferJSON(json)
        let types = Dictionary(uniqueKeysWithValues: result.fields.map { ($0.name, $0.type) })
        #expect(types["title"] == .tag)
        #expect(types["year"] == .numeric)
        #expect(types["active"] == .tag)
        #expect(types["none"] == .tag)
        #expect(types["loc"] == .geo)
        #expect(types["coords"] == .geo)
        #expect(types["embedding"] == .vector)
        #expect(types["numstr"] == .tag)
        #expect(result.skipped == ["meta", "tags"])
        #expect(result.fields.first { $0.name == "none" }?.sampleValue == "")
        #expect(result.fields.first { $0.name == "embedding" }?.vector.dimensions == 3)
    }

    @Test func skippedNotices() {
        #expect(FieldTypeInference.skippedNotice([]) == nil)
        #expect(FieldTypeInference.skippedNotice(["meta"])
            == "Skipped \"meta\" because nested objects and arrays can't be indexed as they are.")
        #expect(FieldTypeInference.skippedNotice(["a", "b"])
            == "Skipped 2 fields (a, b) because nested objects and arrays can't be indexed as they are.")
    }

    @Test func geoRangeIsChecked() {
        #expect(FieldTypeInference.inferString("200, 10", strictNumbers: false).0 != .geo)
        #expect(FieldTypeInference.inferString("12.5,45", strictNumbers: false).0 == .geo)
    }
}

struct QueryCommandsTests {
    @Test func searchCommandDetection() {
        #expect(QueryCommands.searchCommand(in: "// comment\nft.search idx \"*\"")?.verb == "SEARCH")
        #expect(QueryCommands.searchCommand(in: "FT.AGGREGATE idx *")?.verb == "AGGREGATE")
        #expect(QueryCommands.searchCommand(in: "FT.SEARCH") == nil)
        #expect(QueryCommands.searchCommand(in: "FT.SEARCH   ") == nil)
        #expect(QueryCommands.searchCommand(in: "FT.SEARCHX idx") == nil)
        #expect(QueryCommands.searchCommand(in: "") == nil)
    }

    @Test func explainAndProfile() throws {
        let command = try #require(QueryCommands.parseSearchCommand(#"FT.SEARCH 'my idx' "@a:{b}" LIMIT 0 5"#))
        #expect(QueryCommands.explain(command) == #"FT.EXPLAIN 'my idx' "@a:{b}" LIMIT 0 5"#)
        #expect(QueryCommands.profile(command) == #"FT.PROFILE 'my idx' SEARCH QUERY "@a:{b}" LIMIT 0 5"#)
        let bare = try #require(QueryCommands.parseSearchCommand("FT.AGGREGATE idx"))
        #expect(QueryCommands.profile(bare) == "FT.PROFILE idx AGGREGATE QUERY")
    }

    @Test func indexTokenHandlesQuotes() {
        #expect(QueryCommands.indexToken(#" "a\"b" rest"#).token == #""a\"b""#)
        #expect(QueryCommands.indexToken(#" "a\"b" rest"#).remainder == " rest")
        #expect(QueryCommands.indexToken(#" 'unterminated rest"#).token == "'unterminated rest")
        #expect(QueryCommands.indexToken("plain more").token == "plain")
    }

    @Test func editorSplitting() {
        let text = """
        // first
        FT.SEARCH idx "*"
          LIMIT 0 10
        FT._LIST // trailing

        FT.INFO idx
        """
        let commands = QueryCommands.commands(in: text)
        #expect(commands.count == 3)
        #expect(commands.last == "FT.INFO idx")
    }

    @Test func templatesUseIndexAndVectorField() {
        let info = SearchIndexInfo(name: Data("idx".utf8), attributes: [
            SearchIndexAttribute(identifier: "brand", attribute: "brand", type: "TAG"),
            SearchIndexAttribute(identifier: "emb", attribute: "emb", type: "VECTOR", raw: ["dim": "2", "data_type": "FLOAT32"]),
        ])
        let templates = QueryCommands.templates(indexName: "idx", info: info)
        #expect(templates.count == 10)
        #expect(templates[0].snippet == #"FT.SEARCH 'idx' "${1:*}""#)
        let knn = templates.first { $0.title == "KNN vector search" }?.snippet ?? ""
        #expect(knn.contains("@emb $vec"))
        #expect(knn.contains(#"\x00\x00\x80\x3f\x00\x00\x80\x3f"#))
        let hybrid = templates.first { $0.title == "Hybrid search" }?.snippet ?? ""
        #expect(hybrid.contains("@brand:{"))
        let noIndex = QueryCommands.templates(indexName: nil, info: nil)
        #expect(noIndex[0].snippet == #"FT.SEARCH ${1:index} "${2:*}""#)
    }
}

struct SearchResultParserTests {
    @Test func searchTable() throws {
        let reply = ReplyNode.array([
            .integer("2"),
            .string("doc:1"), .array([.string("title"), .string("A")]),
            .string("doc:2"), .array([.string("title"), .string("B"), .string("year"), .string("1999")]),
        ])
        let table = try #require(SearchResultParser.table(from: reply, command: #"FT.SEARCH idx "*""#))
        #expect(table.matched == "2")
        #expect(table.columns == ["Doc", "title", "year"])
        #expect(table.rows.count == 2)
        #expect(table.rows[1]["year"] == "1999")
        #expect(table.rows[0]["year"] == nil)
    }

    @Test func searchTableWithScoresAndNoContent() throws {
        let scored = ReplyNode.array([.integer("1"), .string("d1"), .string("0.5"), .array([.string("f"), .string("v")])])
        let table = try #require(SearchResultParser.table(from: scored, command: "FT.SEARCH idx * WITHSCORES"))
        #expect(table.columns == ["Doc", "Score", "f"])
        #expect(table.rows.first?["Score"] == "0.5")

        let ids = ReplyNode.array([.integer("2"), .string("a"), .string("b")])
        let noContent = try #require(SearchResultParser.table(from: ids, command: "FT.SEARCH idx * NOCONTENT"))
        #expect(noContent.rows.map { $0["Doc"] } == ["a", "b"])
        #expect(noContent.columns == ["Doc"])
    }

    @Test func aggregateWithCursor() throws {
        let reply = ReplyNode.array([
            .array([.integer("1"), .array([.string("brand"), .string("Trek")]), .array([])]),
            .integer("123"),
        ])
        let table = try #require(SearchResultParser.table(from: reply, command: "FT.AGGREGATE idx * WITHCURSOR"))
        #expect(table.cursorID == "123")
        #expect(table.matched == "1")
        #expect(table.columns == ["brand"])
        #expect(table.rows.count == 2)
    }

    @Test func profileUsesResults() throws {
        let reply = ReplyNode.array([
            .array([.integer("1"), .string("d"), .array([.string("x"), .string("1")])]),
            .array([.string("Shards")]),
        ])
        let table = try #require(SearchResultParser.table(from: reply, command: "FT.PROFILE idx SEARCH QUERY *"))
        #expect(table.columns == ["Doc", "x"])
    }

    @Test func otherCommandsHaveNoTable() {
        #expect(SearchResultParser.table(from: .string("OK"), command: "SET a b") == nil)
    }

    @Test func highlightRuns() {
        let runs = SearchResultParser.highlightRuns("a <b>bold</b> c")
        #expect(runs.map(\.0) == ["a ", "bold", " c"])
        #expect(runs.map(\.1) == [false, true, false])
    }

    @Test func asciiEscapedValuesDisplayAsUTF8() {
        #expect(SearchResultParser.displayValue(#"\xe5\x90\x8d"#) == "名")
        #expect(SearchResultParser.displayValue(#"\x00\x01"#) == #"\x00\x01"#)
        #expect(SearchResultParser.displayValue("plain") == "plain")
    }

    @Test func contentForSearchExecution() {
        let execution = CommandExecution(
            databaseId: DatabaseID(), command: "FT.SEARCH idx *", type: .search,
            result: [CommandExecutionResult(status: .success, response: .reply(.array([
                .integer("1"), .string("d1"), .array([.string("doc"), .string(#"{"a":1}"#)]),
            ])))])
        let content = SearchResultParser.content(for: execution)
        #expect(content.availableViews == [.table, .text, .json])
        #expect(content.defaultView == .table)
        #expect(!content.isError)
        #expect(content.lines.first == "1) (integer) 1")
    }

    @Test func contentForErrors() {
        let execution = CommandExecution(
            databaseId: DatabaseID(), command: "FT.SEARCH nope *", type: .search,
            result: [CommandExecutionResult(status: .fail, response: .reply(.error("Unknown index name")))])
        let content = SearchResultParser.content(for: execution)
        #expect(content.isError)
        #expect(content.availableViews == [.text])
        #expect(content.copyText == "Unknown index name")
    }

    @Test func cellPreviewTruncates() {
        let long = String(repeating: "x", count: 250)
        #expect(SearchResultParser.cellPreview(long).count == 201)
        #expect(SearchResultParser.cellPreview("short") == "short")
    }
}

struct IndexListLogicTests {
    static func info(_ name: String, docs: Int, types: [String], prefixes: [String] = ["p:"]) -> SearchIndexInfo {
        SearchIndexInfo(name: Data(name.utf8), keyType: .hash, prefixes: prefixes,
                        attributes: types.enumerated().map { SearchIndexAttribute(identifier: "f\($0.offset)",
                                                                                  attribute: "f\($0.offset)", type: $0.element) },
                        numDocs: docs)
    }

    @Test func rowsKeepListOrderDropFailedInfoAndFilter() {
        let names = ["idx:b", "idx:a", "missing", "Other"].map { Data($0.utf8) }
        var infos: [Data: SearchIndexInfo] = [:]
        for (name, docs) in [("idx:b", 2), ("idx:a", 1), ("Other", 3)] {
            infos[Data(name.utf8)] = Self.info(name, docs: docs, types: ["TEXT", "TAG", "TEXT", "GEOSHAPE", "VECTOR"])
        }

        let rows = IndexListLogic.rows(names: names, infos: infos, filter: "")
        #expect(rows.map(\.displayName) == ["idx:b", "idx:a", "Other"])
        #expect(rows[0].fieldTypes == [.text, .tag, .vector])
        #expect(rows[0].numFields == 5)
        #expect(rows[0].prefixText == "\"p:\"")
        #expect(IndexListLogic.rows(names: names, infos: infos, filter: "  IDX ").count == 2)
        #expect(IndexListLogic.rows(names: names, infos: infos, filter: "zzz").isEmpty)
    }

    @Test func emptyMessages() {
        #expect(IndexListLogic.emptyMessage(isLoading: true, filter: "x") == "Loading…")
        #expect(IndexListLogic.emptyMessage(isLoading: false, filter: " x ") == "No results found")
        #expect(IndexListLogic.emptyMessage(isLoading: false, filter: "  ") == "No indexes found")
    }

    @Test func emptyIndexNameDisplay() {
        #expect(IndexListLogic.displayName(Data()) == "(empty name)")
    }

    @Test func infoTexts() {
        #expect(IndexListLogic.indexingSentence(SearchIndexInfo(name: Data("i".utf8))) == "Covers all keys.")
        #expect(IndexListLogic.indexingSentence(SearchIndexInfo(name: Data("i".utf8), prefixes: ["a", "b"]))
            == "Covers keys starting with \"a\", \"b\".")
        #expect(IndexListLogic.optionsText(filter: nil, language: nil) == "No filter or default language set.")
        #expect(IndexListLogic.optionsText(filter: "@price>0", language: "english")
            == "Filter: @price>0 · Language: english")
        let info = SearchIndexInfo(name: Data("i".utf8), numDocs: 1, maxDocId: 2, numRecords: 3, numTerms: 4)
        #expect(IndexListLogic.summaryText(info) == "Documents: 1 (max ID 2) · Records: 3 · Terms: 4")
    }

    @Test func flagColumnsFollowFixedOrder() {
        let attributes = [
            SearchIndexAttribute(identifier: "a", attribute: "a", type: "TEXT", flags: ["NOSTEM", "SORTABLE"]),
            SearchIndexAttribute(identifier: "b", attribute: "b", type: "TAG", weight: "1", flags: ["UNF"]),
        ]
        #expect(IndexListLogic.flagColumns(attributes) == ["SORTABLE", "UNF", "NOSTEM"])
        #expect(IndexListLogic.hasWeights(attributes))
        #expect(!IndexListLogic.hasWeights([attributes[0]]))
    }
}

struct FieldEditorDraftTests {
    @Test func newFieldNameValidation() {
        var draft = FieldEditorDraft(field: nil)
        #expect(draft.errors(existingNames: [], supportsFloat16: true)[.name] == "Field name is required.")
        draft.name = "title"
        #expect(draft.errors(existingNames: ["title"], supportsFloat16: true)[.name] == "A field with this name already exists.")
        #expect(draft.errors(existingNames: [], supportsFloat16: true).isEmpty)
    }

    @Test func vectorValidation() {
        var draft = FieldEditorDraft(field: IndexFieldDraft(name: "v", type: .vector))
        #expect(draft.errors(existingNames: ["v"], supportsFloat16: true).isEmpty)
        draft.dimensions = ""
        #expect(draft.errors(existingNames: [], supportsFloat16: true)[.dimensions] == "Enter the number of dimensions.")
        draft.dimensions = "40000"
        #expect(draft.errors(existingNames: [], supportsFloat16: true)[.dimensions] == "Dimensions must be between 1 and 32768.")
        draft.dimensions = "8"
        draft.algorithm = .hnsw
        draft.maxEdges = "600"
        draft.maxNeighbors = "0"
        draft.candidateLimit = "5000"
        draft.epsilon = "0"
        let errors = draft.errors(existingNames: [], supportsFloat16: true)
        #expect(errors[.maxEdges] == "Max edges must be between 1 and 512.")
        #expect(errors[.maxNeighbors] == "Max neighbors must be between 1 and 4096.")
        #expect(errors[.candidateLimit] == "Candidate limit must be between 1 and 4096.")
        #expect(errors[.epsilon] == "Epsilon must be greater than 0.")
        draft.dataType = .float16
        #expect(draft.errors(existingNames: [], supportsFloat16: false)[.dataType] != nil)
    }

    @Test func textWeightValidationAndBuild() {
        var draft = FieldEditorDraft(field: IndexFieldDraft(name: "t", sampleValue: "hello", type: .text))
        draft.weight = "-1"
        #expect(draft.errors(existingNames: [], supportsFloat16: true)[.weight] == "Weight must be greater than 0.")
        draft.weight = "2"
        draft.phonetic = .french
        let field = draft.makeField()
        #expect(field.name == "t")
        #expect(field.sampleValue == "hello")
        #expect(field.text.weight == 2)
        #expect(field.text.phonetic == .french)
    }

    @Test func sampleTruncation() {
        let long = String(repeating: "a", count: 600)
        let draft = FieldEditorDraft(field: IndexFieldDraft(name: "t", sampleValue: long, type: .text))
        #expect(draft.sampleIsTruncated)
        #expect(draft.displaySample.count == 501)
    }
}

struct SearchAvailabilityTests {
    @Test func gate() {
        let none = DatabaseCapabilities()
        let old = DatabaseCapabilities(modules: [RedisModuleInfo(name: "search", version: 10_610)])
        let current = DatabaseCapabilities(modules: [RedisModuleInfo(name: "search", version: 81_001)])
        #expect(SearchAvailability.evaluate(state: .connecting, capabilities: current) == .connecting)
        #expect(SearchAvailability.evaluate(state: .disconnected, capabilities: current) == .disconnected)
        #expect(SearchAvailability.evaluate(state: .connected, capabilities: none) == .moduleMissing)
        #expect(SearchAvailability.evaluate(state: .connected, capabilities: old) == .versionTooOld)
        #expect(SearchAvailability.evaluate(state: .connected, capabilities: current) == .available)
    }

    @Test func dataTypesDependOnFloat16Support() {
        #expect(VectorDataType.available(supportsFloat16: false) == [.float32, .float64])
        #expect(VectorDataType.available(supportsFloat16: true).count == 4)
    }
}

struct SampleDatasetsTests {
    @Test func bundledDatasetsLoad() throws {
        let datasets = try SampleDatasets.load()
        #expect(datasets.map(\.id) == [.trails, .recipes])
        #expect(datasets[0].sampleQueries.count == 4)
        #expect(datasets[1].sampleQueries.count == 5)
        #expect(datasets[0].keyType == .hash)
        #expect(datasets[1].keyType == .json)
        #expect(datasets[0].fieldDrafts.map(\.type) == [.text, .tag, .tag, .tag, .numeric, .numeric, .text, .vector])
        #expect(datasets[1].fieldDrafts.map(\.type) == [.text, .tag, .tag, .tag, .text, .numeric, .vector])
        #expect(SampleDatasets.dataURL(collection: "trails") != nil)
        #expect(SampleDatasets.dataURL(collection: "recipes") != nil)
        for dataset in datasets {
            #expect(dataset.createCommand.contains("DIM 64"))
            #expect(dataset.sampleQueries.allSatisfy { $0.query.contains(dataset.indexName) })
            #expect(dataset.fields.allSatisfy { dataset.createCommand.contains($0.name) })
        }
    }

    @Test func retargetedDatasetRewritesNamesAndKeys() throws {
        let recipes = try #require(SampleDatasets.dataset(.recipes))
        let copy = recipes.retargeted(indexName: "idx:test_recipes", prefix: "t:recipe:")
        #expect(copy.createCommand.hasPrefix("FT.CREATE idx:test_recipes"))
        #expect(copy.createCommand.contains(#"PREFIX 1 "t:recipe:""#))
        #expect(copy.sampleQueries.allSatisfy { $0.query.contains("idx:test_recipes") })
        let text = String(decoding: try SampleDatasets.commandData(for: copy), as: UTF8.self)
        let lines = text.split(separator: "\n").filter { !$0.isEmpty }
        #expect(lines.count == 160)
        #expect(lines.allSatisfy { $0.hasPrefix("JSON.SET t:recipe:") })
    }

    @Test func libraryItemsKeepDatasetOrder() throws {
        let trails = try #require(SampleDatasets.dataset(.trails))
        let items = SampleDatasets.libraryItems(for: trails, databaseID: DatabaseID())
        #expect(items.map(\.name) == trails.sampleQueries.map(\.name))
        #expect(items.allSatisfy { $0.type == .sample && $0.indexName == "idx:trails_vss" })
        #expect(zip(items, items.dropFirst()).allSatisfy { $0.createdAt < $1.createdAt })
    }
}

@MainActor
struct ResultCardFormattingTests {
    @Test func durations() {
        #expect(ResultCardModel.durationText(microseconds: 0) == "0.001 msec")
        #expect(ResultCardModel.durationText(microseconds: 500) == "0.500 msec")
        #expect(ResultCardModel.durationText(microseconds: 12_000) == "12 msec")
    }
}
