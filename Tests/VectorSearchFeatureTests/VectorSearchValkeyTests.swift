import Foundation
import RedisCore
import TestSupport
import Testing
@testable import VectorSearchFeature

private let valkeyCapabilities = ValkeyFixtures.capabilities

struct VectorSearchValkeyLogicTests {
    @Test func valkeySearchIsAvailable() {
        #expect(valkeyCapabilities.searchVersion == 10_201)
        #expect(SearchAvailability.evaluate(state: .connected, capabilities: valkeyCapabilities) == .available)
        let oldRediSearch = DatabaseCapabilities(redisVersion: "6.0.0", modules: [RedisModuleInfo(name: "search", version: 10_610)])
        #expect(SearchAvailability.evaluate(state: .connected, capabilities: oldRediSearch) == .versionTooOld)
    }

    @Test func valkeyTemplatesDropExplainAndProfileAndUseNumericRange() {
        let info = SearchIndexInfo(name: Data("idx".utf8), attributes: [
            SearchIndexAttribute(identifier: "brand", attribute: "brand", type: "tag"),
            SearchIndexAttribute(identifier: "price", attribute: "price", type: "numeric"),
        ])
        let templates = QueryCommands.templates(indexName: "idx", info: info, capabilities: valkeyCapabilities)
        let titles = templates.map(\.title)
        #expect(!titles.contains("FT.EXPLAIN"))
        #expect(!titles.contains("FT.PROFILE"))
        #expect(titles.contains("FT._LIST"))
        #expect(templates[0].snippet == #"FT.SEARCH 'idx' "${1:@price:[-inf +inf]}""#)
        #expect(templates[1].snippet == #"FT.AGGREGATE 'idx' "${1:@price:[-inf +inf]}""#)

        let tagOnly = SearchIndexInfo(name: Data("idx".utf8), attributes: [info.attributes[0]])
        let fallback = QueryCommands.templates(indexName: "idx", info: tagOnly, capabilities: valkeyCapabilities)
        #expect(fallback[0].snippet == #"FT.SEARCH 'idx' "${1:query}""#)
    }

    @Test func rediSearchTemplatesKeepExplainAndStar() {
        let caps = DatabaseCapabilities(redisVersion: "8.0.3", serverVersion: "8.0.3",
                                        modules: [RedisModuleInfo(name: "search", version: 21012)])
        let templates = QueryCommands.templates(indexName: "idx", info: nil, capabilities: caps)
        #expect(templates.count == 10)
        #expect(templates.map(\.title).contains("FT.EXPLAIN"))
        #expect(templates[0].snippet == #"FT.SEARCH 'idx' "${1:*}""#)
    }

    @Test func summaryOmitsMissingMaxDocIdAndShowsState() {
        let info = SearchIndexInfo(name: Data("i".utf8), numDocs: 1, numRecords: 3, numTerms: 4)
        #expect(IndexListLogic.summaryText(info) == "Documents: 1 · Records: 3 · Terms: 4")
        #expect(IndexListLogic.stateText(info) == nil)

        let ready = SearchIndexInfo(name: Data("i".utf8), state: "ready", backfillInProgress: false,
                                    backfillCompleteFraction: 1)
        #expect(IndexListLogic.stateText(ready) == "State: ready")
        #expect(IndexListLogic.backfillText(ready) == nil)

        let filling = SearchIndexInfo(name: Data("i".utf8), state: "backfill_in_progress", backfillInProgress: true,
                                      backfillCompleteFraction: 0.425)
        #expect(IndexListLogic.backfillText(filling) == "42%")
        #expect(IndexListLogic.stateText(filling) == "State: backfill_in_progress (42% backfilled)")
    }
}

/// Query page and index creation on a scripted valkey-search server in DB 3.
@MainActor
struct VectorSearchValkeyMockTests {
    private func makeSession() async throws -> (DatabaseSession, MockRedisClient) {
        let client = MockRedisClient(handler: { args in
            switch String(decoding: args.first ?? Data(), as: UTF8.self).uppercased() {
            case "INFO":
                return .bulk(ValkeyFixtures.serverInfo)
            case "MODULE":
                return .array([.array([.bulk("name"), .bulk("search"), .bulk("ver"), .integer(66049)])])
            case "FT._LIST":
                return .array([])
            default:
                return nil
            }
        })
        let session = RedisTestServer.mockSession(client, config: DatabaseConfig(name: "Mock", db: 3))
        await session.connect()
        try await session.refreshInfo()
        return (session, client)
    }

    @Test func explainAndProfileAreUnavailable() async throws {
        let (session, client) = try await makeSession()
        let page = QueryPageViewModel(session: session, indexName: Data("idx".utf8))
        #expect(!page.supportsExplain)
        page.editorText = "FT.SEARCH idx @n:[0 1]"
        await client.resetRecording()
        await page.explain()
        await page.profile()
        #expect(page.cards.isEmpty)
        #expect(await client.executedCommands.isEmpty)
    }

    @Test func indexesCanBeCreatedOutsideDatabaseZero() async throws {
        let (session, _) = try await makeSession()
        #expect(session.dbIndex == 3)
        #expect(QuerySafety.indexCreationBlockedReason(session) == nil)
        #expect(VectorSearchViewModel(session: session).sampleBlockedReason == nil)
        let page = CreateIndexViewModel(session: session, request: .existingData(initialKey: nil, keyType: nil, prefix: nil))
        #expect(page.createDisabledReason != VectorSearchStrings.wrongDatabaseReason)
        #expect(!page.supportsFloat16)
    }
}
