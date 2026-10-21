import Foundation
@testable import BrowserFeature
import RedisCore
import TestSupport
import Testing

private let valkeyCapabilities = ValkeyFixtures.capabilities

private let redisCapabilities = DatabaseCapabilities(
    redisVersion: "8.0.3", serverVersion: "8.0.3", modules: [RedisModuleInfo(name: "search", version: 21012)])

/// `FT.INFO` reply captured from valkey-search 1.2.1 (Valkey 9.1.2).
private func valkeyInfoReply(numeric: Bool = true) -> RESPValue {
    var attributes: [RESPValue] = [
        .array([.simpleString("identifier"), .simpleString("brand"), .simpleString("attribute"), .simpleString("brand"),
                .simpleString("user_indexed_memory"), .integer(1), .simpleString("type"), .simpleString("TAG"),
                .simpleString("SEPARATOR"), .simpleString(","), .simpleString("CASESENSITIVE"), .simpleString("0"),
                .simpleString("size"), .bulk("1")]),
    ]
    if numeric {
        attributes.append(.array([.simpleString("identifier"), .simpleString("price"), .simpleString("attribute"),
                                  .simpleString("price"), .simpleString("user_indexed_memory"), .integer(1),
                                  .simpleString("type"), .simpleString("NUMERIC"), .simpleString("size"), .bulk("1")]))
    }

    return .array([
        .simpleString("index_name"), .simpleString("idx"),
        .simpleString("index_definition"), .array([
            .simpleString("key_type"), .simpleString("HASH"),
            .simpleString("prefixes"), .array([.simpleString("doc:")]),
            .simpleString("default_score"), .bulk("1"),
        ]),
        .simpleString("attributes"), .array(attributes),
        .simpleString("num_docs"), .integer(3),
        .simpleString("num_records"), .integer(7),
        .simpleString("total_term_occurrences"), .integer(2),
        .simpleString("num_terms"), .integer(2),
        .simpleString("hash_indexing_failures"), .bulk("0"),
        .simpleString("backfill_in_progress"), .bulk("1"),
        .simpleString("backfill_complete_percent"), .bulk("0.425000"),
        .simpleString("mutation_queue_size"), .bulk("0"),
        .simpleString("recent_mutations_queue_delay"), .bulk("0 sec"),
        .simpleString("state"), .simpleString("backfill_in_progress"),
        .simpleString("language"), .simpleString("english"),
    ])
}

struct SearchValkeyMatchAllTests {
    private let numeric = SearchIndexAttribute(identifier: "$.price", attribute: "price", type: "numeric")
    private let tag = SearchIndexAttribute(identifier: "brand", attribute: "brand", type: "tag")

    @Test func rediSearchMatchesAllWithStar() {
        #expect(SearchIndexService.matchAllQuery(attributes: [tag], capabilities: redisCapabilities) == "*")
        #expect(SearchIndexService.matchAllQuery(attributes: [], capabilities: DatabaseCapabilities()) == "*")
    }

    @Test func valkeySearchUsesFirstNumericAttribute() {
        let second = SearchIndexAttribute(identifier: "year", attribute: "", type: "numeric")
        let query = SearchIndexService.matchAllQuery(attributes: [tag, numeric, second], capabilities: valkeyCapabilities)
        #expect(query == "@price:[-inf +inf]")
        #expect(SearchIndexService.matchAllQuery(attributes: [second], capabilities: valkeyCapabilities)
            == "@year:[-inf +inf]")
    }

    @Test func valkeySearchSkipsNumericAttributesWithNoIndex() {
        let hidden = SearchIndexAttribute(identifier: "rank", attribute: "rank", type: "numeric", flags: ["NOINDEX"])
        #expect(SearchIndexService.matchAllQuery(attributes: [hidden, numeric], capabilities: valkeyCapabilities)
            == "@price:[-inf +inf]")
        #expect(SearchIndexService.matchAllQuery(attributes: [hidden], capabilities: valkeyCapabilities) == nil)
    }

    @Test func valkeySearchSkipsNumericAttributesNamedWithWhitespace() {
        let spaced = SearchIndexAttribute(identifier: "list price", attribute: "list price", type: "numeric")
        let tabbed = SearchIndexAttribute(identifier: "$.rank", attribute: "sale\trank", type: "numeric")
        #expect(SearchIndexService.matchAllQuery(attributes: [spaced, tabbed, numeric], capabilities: valkeyCapabilities)
            == "@price:[-inf +inf]")
        #expect(SearchIndexService.matchAllQuery(attributes: [spaced, tabbed], capabilities: valkeyCapabilities) == nil)
    }

    @Test func valkeySearchWithoutNumericAttributeHasNoMatchAll() {
        #expect(SearchIndexService.matchAllQuery(attributes: [tag], capabilities: valkeyCapabilities) == nil)
        #expect(SearchIndexService.matchAllQuery(attributes: [], capabilities: valkeyCapabilities) == nil)
    }

    @Test func maxResultsSettingFollowsSearchFlavor() {
        #expect(SearchIndexService.maxResultsSetting(redisCapabilities) == "MAXSEARCHRESULTS")
        #expect(SearchIndexService.maxResultsSetting(valkeyCapabilities)
            == "search.max-nonvector-search-results-fetched")
        let error = SearchIndexError.maxResultsTooLow(10, setting: "search.max-nonvector-search-results-fetched")
        #expect(error.errorDescription == "Set search.max-nonvector-search-results-fetched to at least 10.")
        #expect(SearchIndexError.maxResultsTooLow(5).errorDescription == "Set MAXSEARCHRESULTS to at least 5.")
    }
}

struct SearchValkeyInfoParsingTests {
    @Test func parsesValkeySearchInfo() throws {
        let info = SearchIndexService.parseInfo(valkeyInfoReply(), name: Data("idx".utf8))
        #expect(info.keyType == .hash)
        #expect(info.prefixes == ["doc:"])
        #expect(info.numDocs == 3)
        #expect(info.numRecords == 7)
        #expect(info.numTerms == 2)
        #expect(info.maxDocId == nil)
        #expect(info.state == "backfill_in_progress")
        #expect(info.backfillInProgress == true)
        #expect(info.backfillCompleteFraction == 0.425)
        #expect(info.attributes.map(\.attribute) == ["brand", "price"])
        let brand = try #require(info.attributes.first)
        #expect(brand.fieldType == .tag)
        #expect(brand.flags.isEmpty)
        #expect(brand.raw["SEPARATOR"] == ",")
        #expect(brand.raw["size"] == "1")
        #expect(info.attributes.last?.fieldType == .numeric)
    }

    @Test func valkeySearchFlagWithOneIsSet() {
        let attribute = SearchIndexService.parseInfo(.array([
            .simpleString("attributes"), .array([.array([
                .simpleString("identifier"), .simpleString("t"), .simpleString("type"), .simpleString("TAG"),
                .simpleString("CASESENSITIVE"), .simpleString("1"), .simpleString("size"), .bulk("2"),
            ])]),
        ]), name: Data("i".utf8)).attributes.first
        #expect(attribute?.flags == ["CASESENSITIVE"])
        #expect(attribute?.raw["size"] == "2")
    }

    @Test func rediSearchInfoKeepsMaxDocIdAndStandaloneFlags() {
        let info = SearchIndexService.parseInfo(.array([
            .bulk("max_doc_id"), .integer(14),
            .bulk("attributes"), .array([.array([
                .bulk("identifier"), .bulk("n"), .bulk("attribute"), .bulk("n"), .bulk("type"), .bulk("NUMERIC"),
                .bulk("SORTABLE"), .bulk("UNF"),
            ])]),
        ]), name: Data("i".utf8))
        #expect(info.maxDocId == 14)
        #expect(info.state == nil)
        #expect(info.backfillInProgress == nil)
        #expect(info.attributes.first?.flags == ["SORTABLE", "UNF"])
    }
}

@MainActor
struct SearchValkeyBrowserMockTests {
    private func makeSession(numeric: Bool, searchError: String? = nil) async throws -> (DatabaseSession, MockRedisClient) {
        let client = MockRedisClient(handler: { args in
            switch String(decoding: args.first ?? Data(), as: UTF8.self).uppercased() {
            case "INFO":
                return .bulk(ValkeyFixtures.serverInfo)
            case "MODULE":
                return .array([.array([.bulk("name"), .bulk("search"), .bulk("ver"), .integer(66049)])])
            case "FT._LIST":
                return .array([.bulk("idx")])
            case "FT.INFO":
                return valkeyInfoReply(numeric: numeric)
            case "CONFIG":
                let key = args.count > 2 ? String(decoding: args[2], as: UTF8.self) : ""
                return key == "search.max-nonvector-search-results-fetched" ? .array([.bulk(key), .bulk("100000")])
                    : .array([])
            case "FT.SEARCH":
                if let searchError { return .error(RESPError(searchError)) }
                return .array([.integer(2), .bulk("doc:1"), .bulk("doc:2")])
            case "TYPE":
                return .simpleString("hash")
            default:
                return nil
            }
        })
        let session = RedisTestServer.mockSession(client)
        await session.connect()
        try await session.refreshInfo()
        return (session, client)
    }

    private func searchModel(_ session: DatabaseSession) async -> BrowserViewModel {
        session.services.settings.browser.searchMode = .redisearch
        let model = BrowserViewModel(session: session)
        await model.ensureSettingsLoaded()
        model.selectIndex(Data("idx".utf8))
        await model.waitForLoad()
        return model
    }

    @Test func emptyQueryRunsNumericRange() async throws {
        let (session, client) = try await makeSession(numeric: true)
        #expect(session.capabilities.searchFlavor == .valkeySearch)
        let model = await searchModel(session)
        #expect(model.isSearchAvailable)
        #expect(model.searchUnavailableReason == nil)
        #expect(!model.searchNeedsQuery)
        #expect(model.keys.map { String(decoding: $0.name, as: UTF8.self) } == ["doc:1", "doc:2"])
        #expect(model.searchMaxResults == 100_000)
        let sent = await client.executedCommandStrings
        #expect(sent.contains("FT.SEARCH idx @price:[-inf +inf] NOCONTENT LIMIT 0 500"))
        #expect(!sent.contains { $0.hasPrefix("FT.CONFIG") })
        #expect(model.searchGeneratedQuery == "@price:[-inf +inf]")
        #expect(model.summaryText == "Found 2 of 2 matching @price:[-inf +inf]")

        await model.loadKeys(reset: false)
        #expect((await client.executedCommandStrings).filter { $0.hasPrefix("FT.INFO") }.count == 1)

        model.patternText = "@brand:{a}"
        model.applyPattern()
        await model.waitForLoad()
        #expect(model.searchGeneratedQuery == nil)
        #expect(model.summaryText == "Found 2 of 2")
    }

    @Test func valkeySearchMissingIndexIsIndexNotFound() async throws {
        let (session, _) = try await makeSession(numeric: true,
                                                 searchError: "Index with name 'idx' not found in database 4")
        await #expect(throws: SearchIndexError.indexNotFound) {
            _ = try await SearchIndexService(session: session).searchKeys(index: Data("idx".utf8), query: "@brand:{a}",
                                                                          offset: 0, limit: 10)
        }
    }

    @Test func emptyQueryWithoutNumericFieldAsksForAQuery() async throws {
        let (session, client) = try await makeSession(numeric: false)
        let model = await searchModel(session)
        #expect(model.searchNeedsQuery)
        #expect(model.errorMessage == nil)
        #expect(model.keys.isEmpty)
        #expect(model.summaryText.isEmpty)
        #expect(!(await client.executedCommandStrings).contains { $0.hasPrefix("FT.SEARCH") })

        model.patternText = "@brand:{x}"
        model.applyPattern()
        await model.waitForLoad()
        #expect(!model.searchNeedsQuery)
        #expect(model.keys.count == 2)
        #expect((await client.executedCommandStrings).contains("FT.SEARCH idx @brand:{x} NOCONTENT LIMIT 0 500"))
    }
}

/// Live Browser index search against Valkey 9 on DB 0, with a unique prefix and index name.
@MainActor
@Suite(.serialized, .tags(.live), RedisTestServer.live(.valkey, modules: .search))
struct SearchValkeyLiveTests {
    @Test func emptyQueryListsEveryDocument() async throws {
        let connection = try await RedisTestServer.makeConnection(db: RedisTestServer.DB.search, endpoint: RedisTestServer.valkey)
        let prefix = RedisTestServer.uniquePrefix("browservalkeysearch")
        let index = "idx:" + prefix
        let session = try await RedisTestServer.liveSession(db: RedisTestServer.DB.search, endpoint: RedisTestServer.valkey)
        var failure: Error?
        do {
            _ = try await connection.execute(["FT.CREATE", .string(index), "ON", "HASH", "PREFIX", "1", .string(prefix),
                                              "SCHEMA", "price", "NUMERIC", "brand", "TAG"])
            _ = try await connection.execute(["HSET", .string(prefix + "1"), "price", "10", "brand", "a"])
            _ = try await connection.execute(["HSET", .string(prefix + "2"), "price", "20", "brand", "b"])
            #expect(session.capabilities.searchFlavor == .valkeySearch)

            session.services.settings.browser.searchMode = .redisearch
            let model = BrowserViewModel(session: session)
            await model.ensureSettingsLoaded()
            try #require(model.isSearchAvailable)
            await model.loadIndexes()
            #expect(model.indexes.contains(Data(index.utf8)))
            var names: Set<String> = []
            for _ in 0..<100 {
                model.selectIndex(nil)
                model.selectIndex(Data(index.utf8))
                await model.waitForLoad()
                names = Set(model.keys.map { String(decoding: $0.name, as: UTF8.self) })
                if names.count == 2 { break }
                try await Task.sleep(for: .milliseconds(50))
            }

            #expect(model.errorMessage == nil)
            #expect(!model.searchNeedsQuery)
            #expect(names == [prefix + "1", prefix + "2"])
            #expect(model.searchGeneratedQuery == "@price:[-inf +inf]")
            #expect(model.keys.allSatisfy { $0.type == .hash })
        } catch {
            failure = error
        }

        _ = try? await connection.execute(["FT.DROPINDEX", .string(index)])
        try? await RedisTestServer.deleteKeys(connection, prefix: prefix)
        await session.close()
        await connection.close()
        if let failure { throw failure }
    }
}
