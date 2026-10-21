import Foundation
import RedisCore
import TestSupport
import Testing
@testable import VectorSearchFeature

/// RediSearch indexes only DB 0. Each test uses unique key prefixes and index names and deletes both afterwards.
@MainActor
@Suite(.serialized, .tags(.live), RedisTestServer.live(.redis, modules: .search))
struct VectorSearchLiveTests {
    struct Fixture {
        let session: DatabaseSession
        let prefix: String
        var indexes: [String] = []

        func uniqueIndex(_ suffix: String = "") -> String {
            "rgtest-vs-\(UUID().uuidString.prefix(8).lowercased())\(suffix)"
        }

        func run(_ args: [RedisArgument]) async throws -> RESPValue {
            try await session.execute(args)
        }
    }

    private func withFixture(_ body: (inout Fixture) async throws -> Void) async throws {
        let session = try await RedisTestServer.liveSession(db: RedisTestServer.DB.search)
        var fixture = Fixture(session: session, prefix: RedisTestServer.uniquePrefix("vs"))
        var failure: Error?
        do {
            try await body(&fixture)
        } catch {
            failure = error
        }

        for index in fixture.indexes {
            _ = try? await session.execute(["FT.DROPINDEX", .string(index)])
        }

        if let client = try? await session.client() {
            try? await RedisTestServer.deleteKeys(client, prefix: fixture.prefix)
        }
        await session.close()
        if let failure { throw failure }
    }

    /// Polls `FT.SEARCH idx * LIMIT 0 0` until `count` documents are indexed (max ~5 s).
    private func waitForDocs(_ session: DatabaseSession, index: String, count: Int) async throws {
        for _ in 0..<100 {
            let reply = try await session.execute(["FT.SEARCH", .string(index), "*", "LIMIT", "0", "0"])
            if let total = reply.arrayValue?.first?.intValue, total >= count { return }
            try await Task.sleep(for: .milliseconds(50))
        }

        Issue.record("Index \(index) did not reach \(count) documents")
    }

    private static func floatBlob(_ values: [Float]) -> Data {
        var data = Data()
        for value in values {
            withUnsafeBytes(of: value.bitPattern.littleEndian) { data.append(contentsOf: $0) }
        }

        return data
    }

    // MARK: - Index list

    @Test func indexListLoadsFiltersAndDeletes() async throws {
        try await withFixture { fx in
            let index = fx.uniqueIndex()
            fx.indexes.append(index)
            _ = try await fx.run(["HSET", .string(fx.prefix + "1"), "title", "hello", "price", "10"])
            _ = try await fx.run(["FT.CREATE", .string(index), "ON", "HASH", "PREFIX", "1", .string(fx.prefix),
                                  "SCHEMA", "title", "TEXT", "SORTABLE", "price", "NUMERIC"])
            let model = VectorSearchViewModel(session: fx.session)
            #expect(model.availability == .available)
            await model.loadIndexes()
            #expect(model.listError == nil)
            #expect(model.hasLoadedList)
            #expect(!model.isLoadingInfos)
            let name = Data(index.utf8)
            let row = try #require(model.rows.first { $0.name == name })
            #expect(row.fieldTypes == [.text, .numeric])
            #expect(row.numFields == 2)
            #expect(row.prefixes == [fx.prefix])
            #expect(row.keyType == .hash)

            model.filter = "  \(index.uppercased()) "
            #expect(model.rows.map(\.name) == [name])
            model.filter = "no-such-index-\(UUID().uuidString)"
            #expect(model.rows.isEmpty)
            #expect(model.emptyTableMessage == "No results found")
            model.filter = ""

            let info = try #require(await model.refreshInfo(name))
            #expect(IndexListLogic.flagColumns(info.attributes) == ["SORTABLE"])

            let store = fx.session.services.queryLibraryStore
            try await store.create(QueryLibraryItem(databaseId: fx.session.id, indexName: index, type: .saved,
                                                    name: "q", query: "FT.SEARCH \(index) *"))
            model.infoPanelIndex = name
            #expect(await model.deleteIndex(name))
            #expect(!model.indexNames.contains(name))
            #expect(model.infoPanelIndex == nil)
            #expect(await store.list(databaseID: fx.session.id, indexName: index).isEmpty)
            let exists = try await fx.run(["EXISTS", .string(fx.prefix + "1")])
            #expect(exists.intValue == 1)
            #expect(fx.session.toasts.toasts.isEmpty)
        }
    }

    @Test func queryGuardLeavesMissingIndex() async throws {
        try await withFixture { fx in
            let model = VectorSearchViewModel(session: fx.session)
            model.openQuery(Data("missing-\(UUID().uuidString)".utf8))
            await model.loadIndexes()
            #expect(model.route == .entry)
        }
    }

    // MARK: - Create index

    @Test func createIndexFromPreselectedHashKey() async throws {
        try await withFixture { fx in
            let key = Data((fx.prefix + "bike:1").utf8)
            let other = Data((fx.prefix + "bike:2").utf8)
            let blob = Self.floatBlob([0.1, 0.2, 0.3, 0.4])
            _ = try await fx.run(["HSET", .data(key), "model", "Saturn", "price", "3837", "embedding", .data(blob)])
            _ = try await fx.run(["HSET", .data(other), "model", "Jupiter"])

            let index = fx.uniqueIndex()
            fx.indexes.append(index)
            let page = CreateIndexViewModel(session: fx.session,
                                            request: .existingData(initialKey: key, keyType: .hash, prefix: nil))
            await page.start()
            #expect(page.mode == .preselected)
            #expect(page.prefix == fx.prefix + "bike:")
            #expect(page.fields.map(\.name) == ["model", "price", "embedding"])
            #expect(page.fields.map(\.type) == [.tag, .numeric, .vector])
            #expect(page.fields.last?.vector.dimensions == 4)
            #expect(page.allChecked)
            #expect(page.createDisabledReason == nil)

            page.setChecked(page.fields[0], false)
            #expect(!page.command.contains("\"model\""))
            page.setChecked(page.fields[0], true)

            page.beginAddField()
            var draft = try #require(page.fieldEditor)
            draft.name = "color"
            draft.type = .tag
            #expect(page.commitFieldEditor(draft))
            #expect(page.isDirty)
            #expect(page.fields.count == 4)

            await page.selectKey(other, type: .hash)
            #expect(page.pendingKey?.key == other)
            page.cancelPendingKey()
            #expect(page.fields.count == 4)

            page.indexName = index
            #expect(page.command.hasPrefix("FT.CREATE \"\(index)\"\n  ON HASH\n    PREFIX 1 \"\(fx.prefix)bike:\""))
            let created = await page.create()
            #expect(created == Data(index.utf8))
            let info = try await SearchIndexService(session: fx.session).info(Data(index.utf8))
            #expect(info.attributes.count == 4)
            #expect(info.attributes.contains { $0.fieldType == .vector })
            try await waitForDocs(fx.session, index: index, count: 2)

            let history = await fx.session.services.commandHistoryStore.list(databaseID: fx.session.id, type: .search)
            #expect(history.first?.command.hasPrefix("FT.CREATE") == true)

            let duplicate = CreateIndexViewModel(session: fx.session,
                                                 request: .existingData(initialKey: key, keyType: .hash, prefix: nil),
                                                 existingIndexNames: { [index] })
            await duplicate.start()
            duplicate.indexName = " \(index) "
            #expect(duplicate.createDisabledReason == "An index with this name already exists.")
            duplicate.beginEditingName()
            duplicate.nameDraft = index
            duplicate.validateNameDraft()
            #expect(!duplicate.commitName())
            duplicate.nameDraft = index + "-2"
            duplicate.validateNameDraft()
            #expect(duplicate.commitName())
            #expect(duplicate.indexName == index + "-2")

            duplicate.beginAddField()
            var extra = try #require(duplicate.fieldEditor)
            extra.name = "color"
            extra.type = .tag
            #expect(duplicate.commitFieldEditor(extra))
            await duplicate.selectKey(other, type: .hash)
            let pending = try #require(duplicate.pendingKey)
            duplicate.cancelPendingKey()
            await duplicate.confirmPendingKey(pending)
            #expect(duplicate.selectedKey == other)
            #expect(duplicate.fields.map(\.name) == ["model"])
            #expect(!duplicate.isDirty)
        }
    }

    @Test(RedisTestServer.needs(.json)) func createIndexFromJSONKeyReportsSkippedFields() async throws {
        try await withFixture { fx in
            let key = Data((fx.prefix + "doc:1").utf8)
            _ = try await fx.run(["JSON.SET", .data(key), "$",
                                  #"{"title":"Toy Story","year":1995,"meta":{"a":1},"embedding":[0.1,0.2,0.3]}"#])
            let index = fx.uniqueIndex()
            fx.indexes.append(index)
            let page = CreateIndexViewModel(session: fx.session,
                                            request: .existingData(initialKey: key, keyType: nil, prefix: nil))
            await page.start()
            #expect(page.keyType == .json)
            #expect(page.skippedFields == ["meta"])
            #expect(page.skippedNotice?.hasPrefix("Skipped \"meta\"") == true)
            #expect(page.fields.map(\.type) == [.tag, .numeric, .vector])
            #expect(page.command.contains("$.embedding AS \"embedding\" VECTOR FLAT 6"))
            page.indexName = index
            #expect(await page.create() != nil)
            try await waitForDocs(fx.session, index: index, count: 1)
        }
    }

    @Test func createIndexFailureShowsToast() async throws {
        try await withFixture { fx in
            let key = Data((fx.prefix + "h:1").utf8)
            _ = try await fx.run(["HSET", .data(key), "name", "x"])
            let index = fx.uniqueIndex()
            fx.indexes.append(index)
            _ = try await fx.run(["FT.CREATE", .string(index), "ON", "HASH", "PREFIX", "1", .string(fx.prefix),
                                  "SCHEMA", "name", "TAG"])
            let page = CreateIndexViewModel(session: fx.session,
                                            request: .existingData(initialKey: key, keyType: .hash, prefix: nil))
            await page.start()
            page.indexName = index
            #expect(await page.create() == nil)
            #expect(fx.session.toasts.toasts.contains { $0.title == VectorSearchStrings.createFailedTitle })
        }
    }

    @Test func probeFindsIndexableKeys() async throws {
        try await withFixture { fx in
            _ = try await fx.run(["HSET", .string(fx.prefix + "probe"), "a", "1"])
            #expect(try await CreateIndexViewModel.hasIndexableKeys(fx.session))
            let page = CreateIndexViewModel(session: fx.session,
                                            request: .existingData(initialKey: nil, keyType: nil, prefix: nil))
            await page.start()
            #expect(page.mode == .browse)
            #expect(page.keys.error == nil)
            #expect(page.keys.state != nil)
            #expect(page.createDisabledReason == VectorSearchStrings.selectKeyReason)
        }
    }

    // MARK: - Query page

    @Test func queryPageRunsExplainsProfilesAndSaves() async throws {
        try await withFixture { fx in
            let index = fx.uniqueIndex()
            fx.indexes.append(index)
            _ = try await fx.run(["FT.CREATE", .string(index), "ON", "HASH", "PREFIX", "1", .string(fx.prefix),
                                  "SCHEMA", "brand", "TAG", "v", "VECTOR", "FLAT", "6", "TYPE", "FLOAT32", "DIM", "2",
                                  "DISTANCE_METRIC", "L2"])
            for (i, vector) in [[1, 1], [2, 2], [5, 5]].enumerated() {
                _ = try await fx.run(["HSET", .string(fx.prefix + "\(i)"), "brand", .string("b\(i)"),
                                      "v", .data(Self.floatBlob(vector.map(Float.init)))])
            }

            try await waitForDocs(fx.session, index: index, count: 3)

            let page = QueryPageViewModel(session: fx.session, indexName: Data(index.utf8))
            await page.loadHistory()
            #expect(page.historyLoaded)
            #expect(page.cards.isEmpty)
            #expect(page.explainDisabledReason == VectorSearchStrings.noQueryReason)

            page.editorText = """
            // nearest two
            FT.SEARCH \(index) "*=>[KNN 2 @v $b AS score]"
              PARAMS 2 b "\\x00\\x00\\x80\\x3f\\x00\\x00\\x80\\x3f" SORTBY score RETURN 2 brand score DIALECT 2
            """
            #expect(page.explainDisabledReason == nil)
            await page.runEditor()
            #expect(page.editorText.contains("nearest two"))
            let card = try #require(page.cards.first)
            #expect(!card.isLoading)
            #expect(!card.isFailed)
            #expect(card.isOpen)
            let content = SearchResultParser.content(for: card.execution)
            #expect(content.table?.matched == "2")
            #expect(content.table?.rows.first?["Doc"] == fx.prefix + "0")
            #expect(content.table?.columns.contains("brand") == true)

            page.editorText = "FT.SEARCH \(index) \"@brand:{b1}\" DIALECT 2"
            await page.explain()
            #expect(page.cards.first?.command == "FT.EXPLAIN \(index) \"@brand:{b1}\" DIALECT 2")
            #expect(page.cards.first?.isFailed == false)
            await page.profile()
            #expect(page.cards.first?.command.hasPrefix("FT.PROFILE \(index) SEARCH QUERY") == true)
            #expect(page.cards.first?.isFailed == false)
            #expect(page.cards.count == 3)

            page.editorText = (0..<7).map { _ in "FT.INFO \(index)" }.joined(separator: "\n")
            await page.runEditor()
            #expect(page.cards.count == 10)
            #expect(page.cards.allSatisfy { !$0.isLoading })
            let infoContent = SearchResultParser.content(for: page.cards[0].execution)
            #expect(infoContent.info?.attributes.count == 2)

            await page.run(commands: ["FT.SEARCH no-such-index-\(UUID().uuidString) *"])
            #expect(page.cards.first?.isFailed == true)

            await page.rerun(card)
            #expect(page.cards.first?.isFailed == false)
            #expect(page.cards.first?.command == card.command)

            await page.loadLibrary()
            #expect(page.libraryItems.isEmpty)
            #expect(!page.showsLibrarySearch)
            page.beginSave()
            #expect(page.isSaveSheetPresented)
            page.saveName = "   "
            #expect(await page.save() == false)
            page.saveName = " Nearest "
            #expect(await page.save())
            #expect(!page.isSaveSheetPresented)
            let saved = try #require(page.libraryItems.first)
            #expect(saved.name == "Nearest")
            #expect(saved.type == .saved)
            page.librarySearch = "nothing-matches"
            #expect(page.filteredLibrary.isEmpty)
            #expect(page.libraryEmptyMessage == "No saved queries match the search.")
            page.librarySearch = "NEAREST"
            #expect(page.filteredLibrary.count == 1)
            page.editorText = ""
            page.load(saved)
            #expect(page.editorText == saved.query)
            #expect(page.tab == .editor)
            await page.deleteLibraryItem(saved)
            #expect(page.libraryItems.isEmpty)

            let history = await fx.session.services.commandHistoryStore.list(databaseID: fx.session.id, type: .search)
            #expect(history.count == page.cards.count)
            let collapsed = try #require(page.cards.last)
            collapsed.isOpen = false
            await page.toggle(collapsed)
            #expect(collapsed.isOpen)
            await page.delete(collapsed)
            #expect(!page.cards.contains { $0.id == collapsed.id })

            await page.clearResults()
            #expect(page.cards.isEmpty)
            #expect(await fx.session.services.commandHistoryStore.list(databaseID: fx.session.id, type: .search).isEmpty)
        }
    }

    @Test func historyReloadsCollapsedAndLoadsResultsLazily() async throws {
        try await withFixture { fx in
            let page = QueryPageViewModel(session: fx.session, indexName: Data("x".utf8))
            await page.run(commands: ["FT._LIST"])
            let reloaded = QueryPageViewModel(session: fx.session, indexName: Data("x".utf8))
            await reloaded.loadHistory()
            let card = try #require(reloaded.cards.first)
            #expect(!card.isOpen)
            await reloaded.toggle(card)
            #expect(card.isOpen)
            #expect(card.hasResult)
            #expect(card.loadError == nil)
        }
    }

    // MARK: - Sample data

    @Test(RedisTestServer.needs(.json), arguments: [SampleDatasetID.recipes, .trails])
    func sampleDataLoadsIndexesAndSeedsQueries(_ id: SampleDatasetID) async throws {
        try await withFixture { fx in
            let base = try #require(SampleDatasets.dataset(id))
            let index = fx.uniqueIndex("-sample")
            fx.indexes.append(index)
            let dataset = base.retargeted(indexName: index, prefix: fx.prefix + base.indexPrefix)
            let model = VectorSearchViewModel(session: fx.session)
            await model.loadIndexes()
            await model.startSample(dataset)
            #expect(model.loadingSample == nil)
            #expect(model.route == .query(indexName: Data(index.utf8), openIndexPanel: false))
            #expect(fx.session.toasts.toasts.isEmpty)
            let expected = id == .recipes ? 160 : 200
            try await waitForDocs(fx.session, index: index, count: expected)

            let page = try #require(model.query)
            #expect(page.tab == .library)
            #expect(page.libraryItems.count == base.sampleQueries.count)
            #expect(page.libraryItems.allSatisfy { $0.type == .sample })
            let item = try #require(page.libraryItems.first)
            page.load(item)
            #expect(page.editorText.hasPrefix("// "))
            await page.run(item)
            let card = try #require(page.cards.first)
            #expect(!card.isFailed)
            let table = SearchResultParser.content(for: card.execution).table
            #expect((table?.rows.count ?? 0) > 0)

            let outcome = try await SampleDataLoader(session: fx.session).load(dataset)
            #expect(outcome == .alreadyExists)
            let items = await fx.session.services.queryLibraryStore.list(databaseID: fx.session.id, indexName: index)
            #expect(items.count == base.sampleQueries.count)
        }
    }
}

@MainActor
struct VectorSearchMockTests {
    /// A mock session that looks connected to Redis 8.10 with (or without) the search module.
    private func makeModel(withSearch: Bool = true,
                           handler: @escaping MockRedisClient.Handler = { _ in nil }) async throws -> VectorSearchViewModel {
        let client = MockRedisClient(handler: { args in
            switch String(decoding: args.first ?? Data(), as: UTF8.self).uppercased() {
            case "INFO":
                return .bulk("# Server\r\nredis_version:8.10.0\r\n")
            case "MODULE":
                return withSearch
                    ? .array([.array([.bulk("name"), .bulk("search"), .bulk("ver"), .integer(81_001)])])
                    : .array([])
            default:
                return handler(args)
            }
        })
        let session = RedisTestServer.mockSession(client)
        await session.connect()
        try await session.refreshInfo()
        return VectorSearchViewModel(session: session)
    }

    @Test func consumesQueryNavigation() async throws {
        let model = try await makeModel()
        let name = Data("idx:x".utf8)
        model.session.navigator.navigate(.vectorSearchQuery(indexName: name, openIndexPanel: true))
        model.consumeNavigation()
        #expect(model.route == .query(indexName: name, openIndexPanel: true))
        #expect(model.query?.isIndexPanelOpen == true)
        #expect(model.session.navigator.pending == nil)
    }

    @Test func consumesCreateIndexNavigationForSampleData() async throws {
        let model = try await makeModel()
        model.session.navigator.navigate(.vectorSearchCreateIndex(.sampleData(.recipes)))
        model.consumeNavigation()
        #expect(model.route == .createIndex(.sampleData(.recipes)))
        let page = try #require(model.createIndex)
        await page.start()
        #expect(page.isSampleMode)
        #expect(page.title == "Sample Index: Recipe ideas")
        #expect(page.command.hasPrefix("FT.CREATE idx:recipes_vss"))
        #expect(page.createDisabledReason == nil)
        #expect(!page.mode.isEditable)
        page.beginAddField()
        #expect(page.fieldEditor == nil)
        model.showList()
        #expect(model.route == .entry)
        #expect(model.createIndex == nil)
    }

    @Test func ignoresOtherNavigation() async throws {
        let model = try await makeModel()
        model.session.navigator.navigate(.pubSub)
        model.consumeNavigation()
        #expect(model.route == .entry)
    }

    @Test func listLoadsFromFTList() async throws {
        let model = try await makeModel(handler: { args in
            let name = String(decoding: args.first ?? Data(), as: UTF8.self).uppercased()
            switch name {
            case "FT._LIST":
                return .array([.bulk("idx:a"), .bulk("idx:broken")])
            case "FT.INFO":
                let index = String(decoding: args.count > 1 ? args[1] : Data(), as: UTF8.self)
                if index == "idx:broken" { return .error(RESPError("Unknown index name")) }
                return .array([
                    .bulk("index_name"), .bulk(index),
                    .bulk("index_definition"), .array([.bulk("key_type"), .bulk("HASH"), .bulk("prefixes"),
                                                       .array([.bulk("a:")])]),
                    .bulk("attributes"), .array([.array([.bulk("identifier"), .bulk("t"), .bulk("attribute"), .bulk("t"),
                                                         .bulk("type"), .bulk("TEXT"), .bulk("SORTABLE")])]),
                    .bulk("num_docs"), .bulk("7"),
                ])
            default:
                return nil
            }
        })
        #expect(model.availability == .available)
        await model.loadIndexes()
        #expect(model.indexNames.count == 2)
        #expect(model.rows.map(\.displayName) == ["idx:a"])
        #expect(model.rows.first?.numDocs == 7)
        #expect(model.rows.first?.prefixes == ["a:"])
        model.sortOrder = [KeyPathComparator(\IndexListRow.numDocs, order: .reverse)]
        #expect(model.rows.count == 1)
    }

    @Test func unavailableWithoutSearchModule() async throws {
        let model = try await makeModel(withSearch: false)
        #expect(model.availability == .moduleMissing)
        await model.loadIndexes()
        #expect(!model.hasLoadedList)
    }
}
