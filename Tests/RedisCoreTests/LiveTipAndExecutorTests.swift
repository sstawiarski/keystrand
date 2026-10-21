import Foundation
import RedisCore
import TestSupport
import Testing

@MainActor
struct LiveTipSignalTests {
    @Test func keyInfoTipsTriggerAboveThresholds() {
        let key = Data("k".utf8)
        #expect(LiveTipRules.keyInfoTip(KeyInfo(name: key, type: .set, length: 1_001)) == .bigSets)
        #expect(LiveTipRules.keyInfoTip(KeyInfo(name: key, type: .set, length: 1_000)) == nil)
        #expect(LiveTipRules.keyInfoTip(KeyInfo(name: key, type: .string, size: 100_001)) == .bigStrings)
        #expect(LiveTipRules.keyInfoTip(KeyInfo(name: key, type: .list, length: 1_001)) == .compressionForList)
        #expect(LiveTipRules.keyInfoTip(KeyInfo(name: key, type: .hash, length: 1_000_000)) == nil)
    }

    @Test func valueAndCommandRules() {
        #expect(LiveTipRules.isJSONContainer(Data(#"  {"a": 1}"#.utf8)))
        #expect(LiveTipRules.isJSONContainer(Data("[1,2]".utf8)))
        #expect(!LiveTipRules.isJSONContainer(Data("42".utf8)))
        #expect(!LiveTipRules.isJSONContainer(Data("{not json".utf8)))
        #expect(LiveTipRules.isSearchVisualizationCommand("ft.search idx *"))
        #expect(LiveTipRules.isSearchVisualizationCommand("  TS.MRANGE - + FILTER a=b"))
        #expect(!LiveTipRules.isSearchVisualizationCommand("GET ft.search"))
    }

    @Test func triggersReachTheHandlerOncePerName() async {
        let signals = LiveTipSignals()
        var received: [LiveTipSignal] = []
        signals.reportHashLoaded(key: Data("h".utf8), total: 5_001)
        signals.setHandler { received.append($0) }
        #expect(received.map(\.name) == [.bigHashes])
        signals.reportHashLoaded(key: Data("h2".utf8), total: 9_000)
        await signals.reportStringLoaded(key: Data("s".utf8), value: Data(#"{"x":1}"#.utf8))
        await signals.reportZSetLoaded(key: Data("z".utf8), members: [(Data("m".utf8), "1700000000")])
        signals.reportCLICommand("FT.INFO idx")
        #expect(received.map(\.name) == [.bigHashes, .stringToJson, .rts, .searchVisualization])
        #expect(received.first?.key == Data("h".utf8))
    }

    @Test func searchJSONChecksIndexesOnce() async throws {
        let client = MockRedisClient(responses: ["TYPE": .simpleString("ReJSON-RL"), "FT._LIST": .array([])])
        let session = RedisTestServer.mockSession(client)
        var received: [RecommendationName] = []
        session.liveTips.setHandler { received.append($0.name) }
        _ = try await KeyMetadataService(session: session)
            .metadata(for: [Data("j".utf8)], includeSize: false, includeTTL: false)
        #expect(received == [.searchJSON])
    }

    @Test func searchJSONSkippedWhenIndexesExist() async throws {
        let client = MockRedisClient(responses: ["TYPE": .simpleString("ReJSON-RL"), "FT._LIST": .bulkArray(["idx"])])
        let session = RedisTestServer.mockSession(client)
        var received: [RecommendationName] = []
        session.liveTips.setHandler { received.append($0.name) }
        let service = KeyMetadataService(session: session)
        _ = try await service.metadata(for: [Data("j".utf8)], includeSize: false, includeTTL: false)
        _ = try await service.metadata(for: [Data("j".utf8)], includeSize: false, includeTTL: false)
        #expect(received.isEmpty)
        #expect(await client.executedCommandStrings.filter { $0.hasPrefix("FT._LIST") }.count == 1)
    }
}

@MainActor
struct ExecutorPersistFailureTests {
    @Test func historyWriteFailureKeepsRepliesAndRunsLaterChunks() async throws {
        let services = RedisTestServer.makeServices()
        try FileManager.default.createDirectory(at: services.paths.root, withIntermediateDirectories: true)
        try Data("not a directory".utf8).write(to: services.paths.workbenchDirectory)
        let client = MockRedisClient(responses: ["GET a": .bulk("1"), "GET b": .bulk("2")])
        let session = DatabaseSession(config: DatabaseConfig(name: "Mock"), services: services, client: client)
        let executor = CommandExecutor(session: session, history: services.commandHistoryStore)
        var errors = 0
        var chunks = 0
        let results = try await executor.run(["GET a", "GET b"], params: ExecuteParams(batchSize: 1),
                                             settings: AppSettings(), onPersistError: { _ in errors += 1 }) { _ in
            chunks += 1
        }
        #expect(results.count == 2)
        #expect(chunks == 2)
        #expect(errors == 1)
        #expect(results.allSatisfy { $0.isNotStored == true })
        #expect(results[1].result?.first?.response == .reply(.string("2")))
    }
}

/// Unsupported and blocking commands are refused before anything is sent, however the verb is spelled.
@MainActor
struct ExecutorRefusalTests {
    @Test func quotedAndEscapedVerbsAreRefusedBeforeSending() async throws {
        let client = MockRedisClient(responses: ["GET a": .bulk("1")])
        let session = RedisTestServer.mockSession(client)
        let executor = CommandExecutor(session: session, history: session.services.commandHistoryStore)
        let commands = [#""SELECT" 3"#, #""\x73ELECT" 3"#, #""BLPOP" k 0"#, "'MONITOR'", "GET a", "select 3"]
        let results = try await executor.run(commands, params: ExecuteParams(batchSize: 10), settings: AppSettings())
        #expect(await client.executedCommandStrings == ["GET a"])
        let responses = results.map { $0.result?.first?.response }
        let refused: (String) -> CommandResponse = {
            .reply(.error("\($0) can't be run from Workbench."))
        }
        #expect(responses == [refused("SELECT"), refused("SELECT"), refused("BLPOP"), refused("MONITOR"),
                              .reply(.string("1")), refused("SELECT")])
        #expect(results.map(\.command) == commands)
    }

    @Test func unsupportedStillWinsOverInvalidRepeatAndSplitErrors() async throws {
        let client = MockRedisClient()
        let session = RedisTestServer.mockSession(client)
        let executor = CommandExecutor(session: session, history: session.services.commandHistoryStore)
        let results = try await executor.run(["select \"3", "0 GET a", "GET \"a"], params: ExecuteParams(batchSize: 10),
                                             settings: AppSettings())
        #expect(await client.executedCommands.isEmpty)
        #expect(results.map { $0.result?.first?.response } == [
            .reply(.error("SELECT can't be run from Workbench.")),
            .reply(.error("The repeat count before the command isn't valid.")),
            .reply(.error("Invalid arguments: a quote is never closed.")),
        ])
    }
}

@MainActor
struct SearchKeysLimitTests {
    @Test func offsetAtMaxSearchResultsThrowsInsteadOfEmptyPage() async throws {
        let client = MockRedisClient(responses: [
            "FT.CONFIG": .array([.bulkArray(["MAXSEARCHRESULTS", "100"])]),
            "FT.SEARCH": .array([.integer(500), .bulk("k1")]),
        ])
        let session = RedisTestServer.mockSession(client)
        let service = SearchIndexService(session: session)
        let last = try await service.searchKeys(index: Data("idx".utf8), query: "*", offset: 90, limit: 50)
        #expect(last.nextOffset == nil)
        await #expect(throws: SearchIndexError.maxResultsTooLow(150)) {
            _ = try await service.searchKeys(index: Data("idx".utf8), query: "*", offset: 100, limit: 50)
        }
    }
}
