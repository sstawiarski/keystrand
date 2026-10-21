import Foundation
import RedisCore
import TestSupport
import Testing

/// Keychain that refuses every read (user clicked Deny / errSecInteractionNotAllowed) but accepts writes.
private struct DenyingSecretStore: SecretStore {
    func secret(for account: String) throws -> String? { throw SecretStoreError.keychain(-25308) }
    func setSecret(_ value: String?, for account: String) throws {}
}

@MainActor
struct CoreFixTests {

    // MARK: - Error alerts

    @Test func redisErrorRepliesAreExplainedWithTheServerTextSecond() {
        let center = ToastCenter()
        center.error("WRONGTYPE Operation against a key holding the wrong kind of value")
        let toast = center.toasts.first
        #expect(toast?.title == "Wrong Key Type")
        #expect(toast?.message?.hasPrefix("The key holds a different data type") == true)
        #expect(toast?.message?.hasSuffix("Server reply: WRONGTYPE Operation against a key holding the wrong kind of value") == true)

        center.dismissAll()
        center.error("NOPERM User default has no permissions to run the 'set' command", title: "Set Value Failed")
        #expect(center.toasts.first?.title == "Set Value Failed")
        #expect(center.toasts.first?.message?.contains("not allowed") == true)
    }

    @Test func onlyKnownErrorCodesAreRewritten() {
        for code in ["READONLY", "NOAUTH", "ERR", "MOVED", "LOADING", "BUSY", "OOM", "MISCONF"] {
            #expect(ServerErrorText.explain("\(code) something") != nil, "\(code)")
        }

        #expect(ServerErrorText.explain("BUSYGROUP Consumer Group name already exists") == nil)
        #expect(ServerErrorText.explain("Key with this name does not exist.") == nil)
        let center = ToastCenter()
        center.error("Key with this name does not exist.")
        #expect(center.toasts.first?.title == ServerErrorText.defaultTitle)
        #expect(center.toasts.first?.message == "Key with this name does not exist.")
    }

    // MARK: - Database store

    @Test func saveDatabaseUpdatesWhenTheKeychainDeniesReads() async throws {
        let services = AppServices(paths: .temporary(), secrets: DenyingSecretStore())
        var config = DatabaseConfig(name: "First", host: "h", port: 1)
        try await services.saveDatabase(config)
        config.name = "Edited"
        try await services.saveDatabase(config)
        let all = try await services.databaseStore.list()
        #expect(all.count == 1)
        #expect(all.first?.name == "Edited")
    }

    @Test func createRejectsADuplicateID() async throws {
        let store = DatabaseStore(paths: .temporary(), secrets: InMemorySecretStore())
        let config = DatabaseConfig(name: "One")
        try await store.create(config)
        await #expect(throws: DatabaseStoreError.alreadyExists(config.id)) { try await store.create(config) }
        #expect(try await store.contains(config.id))
        #expect(try await store.list().count == 1)
    }

    // MARK: - Session edits

    @Test func applyDropsStateOnlyWhenTheConnectionChanged() async throws {
        let session = RedisTestServer.mockSession(config: DatabaseConfig(name: "A", host: "h", port: 1, db: 0))
        try await session.select(db: 4)
        let generation = session.dbGeneration
        var edited = session.config
        edited.name = "Renamed"
        await session.apply(config: edited)
        #expect(session.config.name == "Renamed")
        #expect(session.dbIndex == 4)
        #expect(session.dbGeneration == generation)

        edited.db = 2
        await session.apply(config: edited)
        #expect(session.dbIndex == 2)
        #expect(session.dbGeneration == generation + 1)

        edited.host = "other"
        await session.apply(config: edited)
        #expect(session.dbGeneration == generation + 2)
        #expect(session.overview == nil)
    }

    // MARK: - Confirmations

    @Test func keyEditConfirmationsDoNotRequireTyping() async throws {
        let session = RedisTestServer.mockSession(config: DatabaseConfig(name: "Prod", environment: .production))
        let key = Data("k".utf8)
        let context = KeyDetailsContext(session: session, key: key, type: .string, state: KeyDetailsState(key: key))
        let edit = Task { await context.confirmProduction(ConfirmationRequest(title: "Rename", actionID: "rename")) }
        for _ in 0..<100 where session.confirmations.pending == nil { await Task.yield() }
        #expect(session.confirmations.pending?.requiresTyping == false)
        session.confirmations.resolve(confirmed: true)
        #expect(await edit.value)

        let bulk = Task { await session.confirm(ConfirmationRequest(title: "Delete all matching keys")) }
        for _ in 0..<100 where session.confirmations.pending == nil { await Task.yield() }
        #expect(session.confirmations.pending?.requiresTyping == true)
        session.confirmations.resolve(confirmed: false)
        #expect(await bulk.value == false)
    }

    // MARK: - Scanning

    @Test func standaloneScanRunsWhenDBSIZEReportsZero() async throws {
        let client = MockRedisClient(responses: [
            "DBSIZE": .integer(0),
            "SCAN": .array([.bulk("0"), .array([.bulk("k1"), .bulk("k2")])]),
        ])
        let session = RedisTestServer.mockSession(client)
        let state = try await KeyScanner(session: session).scan(ScanRequest(match: "*", count: 500))
        #expect(state.keys.map(\.name) == [Data("k1".utf8), Data("k2".utf8)])
        #expect(state.total == nil)
        #expect(await client.executedCommandStrings.contains { $0.hasPrefix("SCAN 0") })
    }

    @Test func emptyDatabaseStillCompletesWithZeroTotal() async throws {
        let client = MockRedisClient(responses: ["DBSIZE": .integer(0), "SCAN": .array([.bulk("0"), .array([])])])
        let session = RedisTestServer.mockSession(client)
        let state = try await KeyScanner(session: session).scan(ScanRequest(match: "*", count: 500))
        #expect(state.keys.isEmpty)
        #expect(state.total == 0)
        #expect(state.cursor == .standalone(0))
    }

    @Test func largeKeyCountFiresUseSmallerKeysTip() async throws {
        let client = MockRedisClient(responses: ["DBSIZE": .integer(2_000_000),
                                                 "SCAN": .array([.bulk("0"), .array([.bulk("k")])])])
        let session = RedisTestServer.mockSession(client)
        var delivered: [LiveTipSignal] = []
        session.liveTips.setHandler { delivered.append($0) }
        _ = try await KeyScanner(session: session).scan(ScanRequest(match: "*", count: 500))
        _ = try await KeyScanner(session: session).scan(ScanRequest(match: "*", count: 500))
        #expect(delivered == [LiveTipSignal(.useSmallerKeys)])
    }

    // MARK: - Live tip signals

    @Test func liveTipSignalsBufferAndDedupe() async throws {
        let signals = LiveTipSignals()
        signals.report(.bigHashes, key: Data("h".utf8))
        signals.report(.bigHashes, key: Data("other".utf8))
        var delivered: [LiveTipSignal] = []
        signals.setHandler { delivered.append($0) }
        #expect(delivered == [LiveTipSignal(.bigHashes, key: Data("h".utf8))])
        signals.report(.searchVisualization)
        #expect(delivered.count == 2)
        signals.reset()
        signals.report(.searchVisualization)
        #expect(delivered.count == 3)
    }

    @Test func selectingAnotherDatabaseFiresAvoidLogicalDatabases() async throws {
        let session = RedisTestServer.mockSession()
        try await session.select(db: 2)
        #expect(session.liveTips.reportedNames.contains(.avoidLogicalDatabases))
    }

    // MARK: - RediSearch paging

    @Test func searchPagingStopsAtMaxSearchResults() async throws {
        let keys = (0..<500).map { RESPValue.bulk("doc:\($0)") }
        let client = MockRedisClient(responses: [
            "FT.CONFIG": .array([.array([.bulk("MAXSEARCHRESULTS"), .bulk("1000")])]),
            "FT.SEARCH": .array([.integer(5000)] + keys),
            "TYPE": .simpleString("hash"),
        ])
        let session = RedisTestServer.mockSession(client)
        let service = SearchIndexService(session: session)
        let first = try await service.searchKeys(index: Data("idx".utf8), query: "", offset: 0, limit: 500)
        #expect(first.nextOffset == 500)
        let last = try await service.searchKeys(index: Data("idx".utf8), query: "", offset: 500, limit: 500)
        #expect(last.nextOffset == nil)
        let clamped = try await service.searchKeys(index: Data("idx".utf8), query: "", offset: 800, limit: 500)
        #expect(clamped.nextOffset == nil)
        #expect(await client.executedCommandStrings.contains("FT.SEARCH idx * NOCONTENT LIMIT 800 200"))
    }

    // MARK: - Bulk import

    @Test func importerDoesNotCloseAnInjectedClient() async throws {
        let client = MockRedisClient(responses: ["SET": .simpleString("OK")])
        let session = RedisTestServer.mockSession(client)
        let summary = await CommandFileImporter(session: session).importAll(Data("SET a 1\nSET b 2\n".utf8))
        #expect(summary.succeeded == 2)
        #expect(await client.isClosed == false)
    }

    // MARK: - History and query library files

    @Test func historyAddFlagsOversizedResults() async throws {
        let store = CommandHistoryStore(paths: .temporary())
        let id = DatabaseID()
        let big = CommandExecution(databaseId: id, command: "GET big", result: [
            CommandExecutionResult(status: .success, response: .message(String(repeating: "x", count: 1_100_000))),
        ])
        let small = CommandExecution(databaseId: id, command: "GET small", result: [
            CommandExecutionResult(status: .success, response: .message("ok")),
        ])
        let returned = try await store.add([big, small])
        #expect(returned.map(\.isNotStored) == [true, nil])
        #expect(returned[0].result == big.result)
        let stored = await store.get(big.id, databaseID: id, type: .workbench)
        #expect(stored?.result?.first?.sizeLimitExceeded == true)
    }

    @Test func queryLibraryKeepsValidItemsAndBacksUpADamagedFile() async throws {
        let paths = AppPaths.temporary()
        let id = DatabaseID()
        let item = QueryLibraryItem(databaseId: id, indexName: "idx", name: "Saved", query: "FT.SEARCH idx *")
        let encoded = try JSONFile.makeEncoder().encode([item])
        var array = try #require(try JSONSerialization.jsonObject(with: encoded) as? [Any])
        array.append(["unexpected": 1])
        try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: array).write(to: paths.queryLibraryFile)

        let store = QueryLibraryStore(paths: paths)
        #expect(await store.list(databaseID: id).map(\.name) == ["Saved"])
        let backups = try FileManager.default.contentsOfDirectory(atPath: paths.root.path).filter { $0.contains("damaged") }
        #expect(backups.count == 1)
        try await store.seed([QueryLibraryItem(databaseId: id, indexName: "idx", type: .sample, name: "Sample", query: "*")])
        let reloaded = QueryLibraryStore(paths: paths)
        #expect(await reloaded.list(databaseID: id).count == 2)
    }

    @Test func unreadableQueryLibraryIsBackedUpBeforeItIsReplaced() async throws {
        let paths = AppPaths.temporary()
        try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: paths.queryLibraryFile)
        let store = QueryLibraryStore(paths: paths)
        let id = DatabaseID()
        #expect(await store.list(databaseID: id).isEmpty)
        try await store.create(QueryLibraryItem(databaseId: id, indexName: "idx", name: "New", query: "*"))
        let names = try FileManager.default.contentsOfDirectory(atPath: paths.root.path)
        let backup = try #require(names.first { $0.contains("damaged") })
        #expect(try Data(contentsOf: paths.root.appendingPathComponent(backup)) == Data("{ not json".utf8))
    }
}

extension LiveRedisCoreTests {
    @Test func bulkUploadDoesNotChangeTheSharedClient() async throws {
        let session = try await freshSession()
        let prefix = RedisTestServer.uniquePrefix("import")
        let spareDB = RedisTestServer.DB.redisCoreSpare
        let file = "SELECT \(spareDB)\nSET \(prefix)moved 1\nCLIENT SETNAME hijacked\n"
        let summary = await CommandFileImporter(session: session).importAll(Data(file.utf8))
        #expect(summary.failed == 0)
        _ = try await session.execute(["SET", .string(prefix + "after"), "1"])
        #expect(try await session.execute(["CLIENT", "GETNAME"]).stringValue != "hijacked")

        let home = try await RedisTestServer.makeConnection(db: Self.db)
        #expect(try await home.execute(["EXISTS", .string(prefix + "after")]).intValue == 1)
        #expect(try await home.execute(["EXISTS", .string(prefix + "moved")]).intValue == 0)
        await home.close()
        let spare = try await RedisTestServer.makeConnection(db: spareDB)
        #expect(try await spare.execute(["EXISTS", .string(prefix + "moved")]).intValue == 1)
        _ = try await spare.execute(["UNLINK", .string(prefix + "moved")])
        await spare.close()
        await session.close()
    }

    @Test func invalidateDiscardsAClientStillConnecting() async throws {
        let pool = ClientPool(factory: RedisClientFactory(scriptRunner: ConnectionScriptRunner(shell: "/bin/sh")))
        let id = DatabaseID()
        let key = ClientKey(databaseID: id, context: .common, db: Self.db)
        let descriptor = RedisClientDescriptor(topology: .standalone(RedisEndpoint(host: RedisTestServer.host, port: RedisTestServer.port)),
                                               connection: RedisTestServer.connectionConfig(db: Self.db),
                                               preConnectScript: "sleep 0.6 # \(UUID().uuidString)")
        let pending = Task { try await pool.client(for: key, descriptor: descriptor) }
        try await Task.sleep(nanoseconds: 150_000_000)
        await pool.invalidate(databaseID: id)
        await #expect(throws: RedisClientError.self) { _ = try await pending.value }
        #expect(await pool.count == 0)

        let fresh = try await pool.client(for: key, descriptor: descriptor)
        #expect(try await fresh.execute(["PING"]).stringValue == "PONG")
        #expect(await pool.count == 1)
        await pool.closeAll()
    }
}
