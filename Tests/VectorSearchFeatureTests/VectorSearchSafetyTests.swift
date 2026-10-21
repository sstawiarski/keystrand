import Foundation
import RedisCore
import RedisUI
import TestSupport
import Testing
@testable import VectorSearchFeature

struct IndexInfoTextTests {
    @Test func indexingSentenceAndTypes() {
        let info = SearchIndexInfo(name: Data("idx".utf8), keyType: .hash, prefixes: ["bike:"],
                                   attributes: [SearchIndexAttribute(identifier: "t", attribute: "t", type: "TEXT"),
                                                SearchIndexAttribute(identifier: "v", attribute: "v", type: "VECTOR")])
        #expect(IndexListLogic.indexingSentence(info) == "Covers HASH keys starting with \"bike:\".")
        #expect(IndexListLogic.row(info).typesText == "TEXT, VECTOR")
        #expect(IndexAttributeRow.rows(info).map(\.id) == [0, 1])
    }
}

struct QuerySafetyLogicTests {
    @Test func dangerousVerbsMatchLowercaseServerListAndSubcommands() {
        let server: Set<String> = ["flushall", "keys", "config|set", "debug"]
        let verbs = QuerySafety.dangerousVerbs(
            in: ["flushall", "KEYS *", "CONFIG SET maxmemory 1", "config get maxmemory", "FT.SEARCH idx *",
                 "Debug sleep 0", "keys\n  other"],
            serverList: server)
        #expect(verbs == ["FLUSHALL", "KEYS", "CONFIG", "DEBUG"])
        #expect(QuerySafety.dangerousVerbs(in: ["CONFIG GET x"], serverList: server).isEmpty)
    }

    @Test func dangerousVerbsFallBackToCatalogWhenServerListIsEmpty() {
        let verbs = QuerySafety.dangerousVerbs(in: ["FLUSHALL", "FT.SEARCH idx *"], serverList: [])
        #expect(verbs == ["FLUSHALL"])
    }

    @Test func escapedAndQuotedVerbsAreJudgedOnTheArgumentsThatAreSent() {
        let server: Set<String> = ["flushdb", "config|set", "client|kill"]
        let commands = [#""\x46LUSHDB""#, #""CONFIG" "SET" maxmemory 1"#, #"client 'kill' ID 1"#, #"FT.SEARCH "idx"#]
        #expect(QuerySafety.dangerousVerbs(in: commands, serverList: server) == ["FLUSHDB", "CONFIG", "CLIENT"])
        #expect(QuerySafety.flushVerbs(in: [#""\x46LUSHDB""#, #""FLUSHALL""#, "FLUSHDB"]) == ["FLUSHDB", "FLUSHALL"])
    }

    @Test func flushVerbsInScriptOrder() {
        #expect(QuerySafety.flushVerbs(in: ["FT.SEARCH i *", "flushall async", "FLUSHDB", "FLUSHALL"]) == ["FLUSHALL", "FLUSHDB"])
        #expect(QuerySafety.flushVerbs(in: ["FT.SEARCH flushdb *"]).isEmpty)
        let message = QuerySafety.flushMessage(verbs: ["FLUSHDB"], hasSearch: true)
        #expect(message.contains("current logical database"))
        #expect(message.contains("drops every search index"))
    }

    @Test func expandedCountDoesNotExpandRepeats() {
        #expect(QueryCommands.expandedCount(in: "2000000000 FT.SEARCH idx *") == 2_000_000_000)
        #expect(QueryCommands.expandedCount(in: "\(Int32.max) PING\n\(Int32.max) PING\n5 PING") > QuerySafety.maxCommands)
    }

    @Test(arguments: [
        "FT.SEARCH idx \"*\"",
        "3 FT.SEARCH idx *\nFT.INFO idx",
        "// Find trails\nFT.SEARCH 'idx:trails' \"@difficulty:{easy}\"\n  LIMIT 0 10",
        "[pipeline=2;mode=raw]\n// comment\n  // indented\n2 FT.AGGREGATE idx * // trailing\nPING",
        "FT.INFO idx\nFT.SEARCH idx *",
        "0 FT.SEARCH idx *",
        "",
        "   \n// only a comment",
        "FT.SEARCH idx \"a // b\" LIMIT 0 1",
    ])
    func firstCommandMatchesFullParser(_ script: String) {
        let parsed = QueryCommands.commands(in: script)
        let expected = parsed.first.flatMap {
            QueryCommands.parseSearchCommand(WorkbenchScriptParser.multilineToOneLine($0))
        }
        #expect(QueryCommands.searchCommand(in: script) == expected)
        #expect(QueryCommands.expandedCount(in: script) == parsed.count)
    }
}

struct PickerKeyTreeTests {
    @Test func splitsOnDelimitersAndRespectsPrefixLength() {
        #expect(PickerKeyTree.split("a:b:c", options: PickerTreeOptions()) == ["a", "b", "c"])
        #expect(PickerKeyTree.split("a:b-c", options: PickerTreeOptions(delimiters: [":", "-"])) == ["a", "b", "c"])
        #expect(PickerKeyTree.split("ab:cd:e", options: PickerTreeOptions(prefixLength: 3)) == ["ab:cd", "e"])
        #expect(PickerKeyTree.split("plain", options: PickerTreeOptions()) == ["plain"])
        #expect(PickerTreeOptions(delimiters: ["", ""], prefixLength: -4).delimiters == [":"])
    }

    @Test func buildsFoldersBeforeKeysAndFlattensExpandedFolders() {
        let keys = ["trail:2", "trail:10", "trail:coast:1", "solo"].map { (name: Data($0.utf8), display: $0) }
        let roots = PickerKeyTree.build(keys, options: PickerTreeOptions())
        #expect(roots.map(\.name) == ["trail", "solo"])
        #expect(roots[0].keyCount == 3)
        #expect(roots[0].children.map(\.name) == ["coast", "2", "10"])

        let collapsed = PickerKeyTree.flatten(roots, expanded: [])
        #expect(collapsed.map(\.node.name) == ["trail", "solo"])
        let open = PickerKeyTree.flatten(roots, expanded: ["trail"])
        #expect(open.map(\.node.name) == ["trail", "coast", "2", "10", "solo"])
        #expect(open.map(\.depth) == [0, 1, 1, 1, 0])
        #expect(open[2].node.keyName == Data("trail:2".utf8))

        let descending = PickerKeyTree.build(keys, options: PickerTreeOptions(sort: .desc))
        #expect(descending.map(\.name) == ["trail", "solo"])
        #expect(descending[0].children.map(\.name) == ["coast", "10", "2"])
    }

    @Test func indexListColumnsAddUpToTheMinimumWidth() {
        #expect(IndexListColumn.allCases.reduce(0) { $0 + $1.minWidth } == IndexListColumn.tableMinWidth)
        #expect(IndexListColumn.allCases.map(\.title) == ["Name", "Prefix", "Types", "Docs", "Records", "Terms", "Fields"])
        #expect(IndexListColumn.described.allSatisfy { !$0.tooltip.isEmpty })
    }
}

@MainActor
struct VectorSearchSafetyMockTests {
    private func makeSession(production: Bool = false, db: Int? = nil,
                             handler: @escaping MockRedisClient.Handler = { _ in nil }) async throws
        -> (DatabaseSession, MockRedisClient) {
        let client = MockRedisClient(handler: { args in
            switch String(decoding: args.first ?? Data(), as: UTF8.self).uppercased() {
            case "INFO":
                return .bulk("# Server\r\nredis_version:8.10.0\r\n")
            case "MODULE":
                return .array([.array([.bulk("name"), .bulk("search"), .bulk("ver"), .integer(81_001)])])
            case "FT._LIST":
                return .array([])
            case "ACL":
                return .array(["keys", "config|set", "flushall", "flushdb"].map { .bulk($0) })
            default:
                return handler(args)
            }
        })
        let config = DatabaseConfig(name: "Mock", db: db, environment: production ? .production : .unspecified)
        let session = RedisTestServer.mockSession(client, config: config)
        await session.connect()
        try await session.refreshInfo()
        return (session, client)
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<200 where !condition() {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    private func sentVerbs(_ client: MockRedisClient) async -> [String] {
        await client.executedCommands.map { String(decoding: $0.first ?? Data(), as: UTF8.self).uppercased() }
    }

    @Test func productionAsksBeforeDangerousCommandsWithSharedActionID() async throws {
        let (session, client) = try await makeSession(production: true)
        #expect(session.dangerousCommands.contains("config|set"))
        let page = QueryPageViewModel(session: session, indexName: Data("idx".utf8))
        let task = Task { await page.run(commands: ["keys *"]) }
        await waitUntil { session.confirmations.pending != nil }
        let pending = try #require(session.confirmations.pending)
        #expect(pending.actionID == "dangerous:KEYS")
        #expect(pending.confirmButtonTitle == "Run command")
        #expect(pending.message?.contains("KEYS") == true)
        session.confirmations.resolve(confirmed: false)
        await task.value
        #expect(!(await sentVerbs(client)).contains("KEYS"))
        #expect(page.cards.isEmpty)
    }

    @Test func nonProductionDoesNotAskForDangerousCommands() async throws {
        let (session, _) = try await makeSession()
        let page = QueryPageViewModel(session: session, indexName: Data("idx".utf8))
        #expect(await page.confirmDangerous(["KEYS *"]))
        #expect(session.confirmations.pending == nil)
    }

    @Test func flushCommandsWaitForConfirmationOnEveryDatabase() async throws {
        let (session, client) = try await makeSession()
        let page = QueryPageViewModel(session: session, indexName: Data("idx".utf8))
        let task = Task { await page.run(commands: ["FT.SEARCH idx *", "FLUSHDB"]) }
        await waitUntil { page.flushWarning != nil }
        let warning = try #require(page.flushWarning)
        #expect(warning.verbs == ["FLUSHDB"])
        #expect(warning.message.contains("search index"))
        page.resolveFlushWarning(proceed: false)
        await task.value
        #expect(page.flushWarning == nil)
        let verbs = await sentVerbs(client)
        #expect(!verbs.contains("FLUSHDB"))
        #expect(!verbs.contains("FT.SEARCH"))
    }

    @Test func escapedFlushAndQuotedSubcommandStillAskInProduction() async throws {
        let (session, client) = try await makeSession(production: true)
        await client.resetRecording()
        let page = QueryPageViewModel(session: session, indexName: Data("idx".utf8))
        let config = Task { await page.run(commands: [#"'CONFIG' SET maxmemory 1"#]) }
        await waitUntil { session.confirmations.pending != nil }
        #expect(session.confirmations.pending?.actionID == "dangerous:CONFIG")
        session.confirmations.resolve(confirmed: false)
        await config.value

        let flush = Task { await page.run(commands: [#""\x46LUSHDB""#]) }
        await waitUntil { session.confirmations.pending != nil }
        #expect(session.confirmations.pending?.actionID == "dangerous:FLUSHDB")
        session.confirmations.resolve(confirmed: true)
        await waitUntil { page.flushWarning != nil }
        #expect(page.flushWarning?.verbs == ["FLUSHDB"])
        page.resolveFlushWarning(proceed: false)
        await flush.value
        let verbs = await sentVerbs(client)
        #expect(!verbs.contains("CONFIG"))
        #expect(!verbs.contains("FLUSHDB"))
    }

    @Test func hugeRepeatCountIsRefusedWithoutExpanding() async throws {
        let (session, client) = try await makeSession(handler: { args in
            String(decoding: args.first ?? Data(), as: UTF8.self).uppercased() == "FT.EXPLAIN" ? .bulk("plan") : nil
        })
        let page = QueryPageViewModel(session: session, indexName: Data("idx".utf8))
        page.editorText = "2000000000 FT.SEARCH idx *"
        #expect(page.searchCommand == QueryCommands.SearchCommand(verb: "SEARCH", rest: " idx *"))
        #expect(page.explainDisabledReason == nil)
        await page.runEditor()
        #expect(page.cards.isEmpty)
        #expect(session.toasts.toasts.contains { $0.title == "Too many commands" })
        #expect(!(await sentVerbs(client)).contains("FT.SEARCH"))

        await page.explain()
        #expect(page.cards.count == 1)
        #expect(page.cards.first?.command == "FT.EXPLAIN idx *")
    }

    @Test func sampleDataIsRefusedOutsideDatabaseZero() async throws {
        let (session, client) = try await makeSession(db: 3)
        #expect(session.dbIndex == 3)
        let model = VectorSearchViewModel(session: session)
        #expect(model.sampleBlockedReason == VectorSearchStrings.wrongDatabaseReason)
        await client.resetRecording()
        await model.startSample(.recipes)
        #expect(model.loadingSample == nil)
        #expect(model.route == .entry)
        #expect(session.toasts.toasts.contains { $0.message == VectorSearchStrings.wrongDatabaseReason })
        #expect(await client.executedCommands.isEmpty)

        let dataset = try #require(SampleDatasets.dataset(.trails))
        await #expect(throws: SampleDataError.wrongDatabase) {
            _ = try await SampleDataLoader(session: session).load(dataset)
        }
        let verbs = await sentVerbs(client)
        #expect(verbs.allSatisfy { $0 == "FT._LIST" })

        let page = CreateIndexViewModel(session: session, request: .existingData(initialKey: nil, keyType: nil, prefix: nil))
        #expect(page.createDisabledReason == VectorSearchStrings.wrongDatabaseReason)
        #expect(await page.create() == nil)
    }

    @Test func productionAsksBeforeLoadingSampleData() async throws {
        let (session, client) = try await makeSession(production: true)
        let dataset = try #require(SampleDatasets.dataset(.recipes))
        let task = Task { try await SampleDataLoader(session: session).load(dataset) }
        await waitUntil { session.confirmations.pending != nil }
        #expect(session.confirmations.pending?.actionID == "vs-load-sample")
        session.confirmations.resolve(confirmed: false)
        #expect(try await task.value == .cancelled)
        let verbs = await sentVerbs(client)
        #expect(!verbs.contains("JSON.SET"))
        #expect(!verbs.contains("FT.CREATE"))
    }

    @Test func manualFieldsSwitchBetweenTableAndCommand() async throws {
        let (session, _) = try await makeSession(handler: { args in
            String(decoding: args.first ?? Data(), as: UTF8.self).uppercased() == "SCAN"
                ? .array([.bulk("0"), .array([])]) : nil
        })
        let page = CreateIndexViewModel(session: session, request: .existingData(initialKey: nil, keyType: nil, prefix: nil))
        await page.start()
        #expect(page.mode == .manual)
        #expect(page.title == "New Index")
        page.beginAddField()
        var draft = try #require(page.fieldEditor)
        draft.name = "title"
        draft.type = .tag
        #expect(page.commitFieldEditor(draft))
        #expect(page.viewMode == .table)
        #expect(page.command.contains("title") && page.command.contains("TAG"))
        #expect(CreateIndexViewMode.allCases.map(\.title) == ["Table", "Command"])
        #expect(SchemaTable.typeText(page.fields[0]) == "TAG")
        var vector = IndexFieldDraft(name: "v", type: .vector)
        vector.vector.dimensions = 8
        #expect(SchemaTable.typeText(vector) == "VECTOR (FLAT, FLOAT32, 8)")
    }

    @Test func navigationPathFollowsTheRoute() async throws {
        let (session, _) = try await makeSession()
        let model = VectorSearchViewModel(session: session)
        #expect(model.route.path.isEmpty)
        model.openCreateIndex(.sampleData(.recipes))
        #expect(model.route.path == [.createIndex])
        model.setPath([.createIndex])
        #expect(model.route.path == [.createIndex])
        model.setPath([])
        #expect(model.route == .entry)
        #expect(VectorSearchRoute.query(indexName: Data("i".utf8), openIndexPanel: false).path == [.query])
    }

    @Test func sampleDataLaunchSheetOpensOnce() async throws {
        let (session, _) = try await makeSession()
        let model = VectorSearchViewModel(session: session)
        model.consumeLaunchSheet(options: QALaunchOptions(arguments: ["app", "--sheet", "new-key"]))
        #expect(!model.isSamplePickerPresented)
        model.consumeLaunchSheet(options: QALaunchOptions(arguments: ["app", "--sheet", "sample-data"]))
        #expect(model.isSamplePickerPresented)
        model.isSamplePickerPresented = false
        model.consumeLaunchSheet(options: QALaunchOptions(arguments: ["app", "--sheet", "sample-data"]))
        #expect(!model.isSamplePickerPresented)
    }

    @Test func treeSettingsPersistToDatabaseSettings() async throws {
        let (session, _) = try await makeSession()
        let picker = KeysPickerViewModel(session: session)
        await picker.loadTreeSettingsIfNeeded()
        #expect(picker.treeOptions == PickerTreeOptions())
        await picker.applyTreeSettings(PickerTreeOptions(delimiters: ["-", ":"], prefixLength: 2, sort: .desc))
        let stored = await session.services.databaseSettingsStore.settings(for: session.id)
        #expect(stored.treeViewDelimiters == ["-", ":"])
        #expect(stored.treeViewDelimiterPrefixLength == 2)
        #expect(stored.treeViewSort == .desc)
    }
}

@MainActor
@Suite(.serialized, .tags(.live), RedisTestServer.live(.redis))
struct KeysPickerLiveTests {
    @Test func scansHashKeysIntoATree() async throws {
        let session = try await RedisTestServer.liveSession(db: RedisTestServer.DB.vectorSearch)
        let prefix = RedisTestServer.uniquePrefix("vs-tree")
        var failure: Error?
        do {
            try await exerciseTree(session, prefix: prefix)
        } catch {
            failure = error
        }

        if let client = try? await session.client() {
            try? await RedisTestServer.deleteKeys(client, prefix: prefix)
        }
        await session.close()
        if let failure { throw failure }
    }

    private func exerciseTree(_ session: DatabaseSession, prefix: String) async throws {
        for name in ["road:1", "road:2", "mountain:1"] {
            _ = try await session.execute(["HSET", .string(prefix + name), "brand", "Trek"])
        }

        _ = try await session.execute(["SET", .string(prefix + "plain"), "x"])

        let picker = KeysPickerViewModel(session: session)
        await picker.refresh()
        while picker.canScanMore { await picker.scanMore() }
        #expect(picker.error == nil)
        let ours = picker.items.filter { $0.display.hasPrefix(prefix) }.map(\.display).sorted()
        #expect(ours == ["mountain:1", "road:1", "road:2"].map { prefix + $0 })

        let expected = ["rgtest", "vs-tree", String(prefix.split(separator: ":")[2]), "mountain", "1", "road", "1", "2"]
        picker.filter = prefix
        for _ in 0..<200 where picker.rows.map(\.node.name) != expected {
            try await Task.sleep(for: .milliseconds(5))
        }

        #expect(picker.rows.map(\.node.name) == expected)
        let leaf = try #require(picker.rows.last)
        #expect(leaf.node.keyName == Data((prefix + "road:2").utf8))
        let roadPath = try #require(picker.rows[5].node.folderPath)
        picker.toggleFolder(roadPath)
        #expect(picker.rows.count == 6)

        await picker.setKeyType(.json)
        while picker.canScanMore { await picker.scanMore() }
        #expect(!picker.items.contains { $0.display.hasPrefix(prefix) })
    }
}
