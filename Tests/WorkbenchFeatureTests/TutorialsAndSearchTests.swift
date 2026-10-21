import Foundation
@testable import WorkbenchFeature
import RedisCore
import TestSupport
import Testing

@MainActor
struct TutorialsViewModelTests {
    @Test func loadsTreeAndOpensPagesWithSiblings() async throws {
        let model = TutorialsViewModel(session: RedisTestServer.mockSession())
        await model.load()
        let library = try #require(model.library)
        #expect(model.loadError == nil)
        #expect(model.expandedGroups.contains(library.root.id))
        #expect(!model.expandedGroups.contains("sq"))
        model.toggleGroup("sq")
        #expect(model.expandedGroups.contains("sq"))

        await model.open(id: "sq-intro")
        let page = try #require(model.page)
        #expect(page.node.id == "sq-intro")
        #expect(!page.blocks.isEmpty)
        #expect(page.parentLabel == "Search And Query")
        #expect(page.index == 0)
        #expect(page.previous == nil)
        let next = try #require(page.next)
        await model.open(id: next.id)
        #expect(model.page?.index == 1)
        #expect(model.page?.previous?.id == "sq-intro")

        model.closePage()
        #expect(model.page == nil)
    }

    @Test func openBeforeLoadIsDeferred() async throws {
        let model = TutorialsViewModel(session: RedisTestServer.mockSession())
        await model.open(id: "ds-strings-fake-id-for-defer")
        #expect(model.page == nil)
        await model.open(id: "vss-intro")
        await model.load()
        #expect(model.page?.node.id == "vss-intro")
    }

    @Test func unknownTutorialReportsError() async {
        let model = TutorialsViewModel(session: RedisTestServer.mockSession())
        await model.load()
        await model.open(id: "does-not-exist")
        #expect(model.page == nil)
        #expect(model.pageError != nil)
    }

    @Test func relativeLinksOpenTutorials() async throws {
        let model = TutorialsViewModel(session: RedisTestServer.mockSession())
        await model.load()
        #expect(!model.handleLink(try #require(URL(string: "hashes.md"))))
        await model.open(id: "ds-strings")
        #expect(model.handleLink(try #require(URL(string: "../sq/vectors.md"))))
        #expect(!model.handleLink(try #require(URL(string: "https://redis.io/docs"))))
        #expect(!model.handleLink(try #require(URL(string: "missing.md"))))
        for _ in 0..<100 where model.page?.node.id != "vss-intro" { try await Task.sleep(for: .milliseconds(10)) }
        #expect(model.page?.node.id == "vss-intro")
        #expect(model.page?.blocks.first.map { if case .heading(level: 1, _) = $0 { true } else { false } } == false)
    }

    @Test func searchMatchesLabelsAndBodies() async {
        let model = TutorialsViewModel(session: RedisTestServer.mockSession())
        await model.load()
        model.updateSearch("Quito")
        await model.waitForSearch()
        #expect(model.searchResults.map(\.id) == ["ds-strings"])
        #expect(model.searchResults.first?.excerpt?.contains("Quito") == true)
        model.updateSearch("aggregat")
        await model.waitForSearch()
        #expect(model.searchResults.contains { $0.id == "sq-aggregations" && $0.groupPath == ["Search and query"] })
        model.updateSearch("")
        #expect(model.searchResults.isEmpty)
        #expect(!model.isSearching)
    }

    @Test func runChecks() async throws {
        let session = RedisTestServer.mockSession()
        let model = TutorialsViewModel(session: session)
        let confirm = try #require(TutorialFence.parse(info: "redis:[run_confirmation=true] Create"))
        let plain = try #require(TutorialFence.parse(info: "redis Get"))
        let hidden = try #require(TutorialFence.parse(info: "redis:[executable=false] Info"))
        #expect(model.check(code: "SET a 1", fence: confirm) == .needsConfirmation)
        #expect(model.check(code: "GET a", fence: plain) == .ready)
        #expect(model.check(code: "GET a", fence: hidden) == .notExecutable)
        await model.setSkipRunConfirmation(true)
        #expect(model.check(code: "SET a 1", fence: confirm) == .ready)
        let reloaded = TutorialsViewModel(session: session)
        await reloaded.load()
        #expect(reloaded.skipRunConfirmation)
    }

    @Test func productionDisablesRun() throws {
        var config = DatabaseConfig(name: "Prod")
        config.environment = .production
        let model = TutorialsViewModel(session: RedisTestServer.mockSession(config: config))
        let plain = try #require(TutorialFence.parse(info: "redis Get"))
        #expect(model.check(code: "GET a", fence: plain) == .production)
    }
}

@MainActor
@Suite(.serialized, .tags(.live), RedisTestServer.live(.redis))
struct TutorialRunLiveTests {
    @Test func runExecutesInWorkbenchWithoutTouchingEditor() async throws {
        let prefix = RedisTestServer.uniquePrefix("wbtut")
        let session = try await RedisTestServer.liveSession(db: RedisTestServer.DB.workbench)
        defer { Task { await removeKeys(db: RedisTestServer.DB.workbench, prefix: prefix) } }
        let workbench = WorkbenchViewModel.shared(for: session)
        workbench.editorText = "draft"
        let model = TutorialsViewModel.shared(for: session)
        let fence = try #require(TutorialFence.parse(info: "redis:[results=group] Strings"))
        let ran = await model.run(code: "SET \(prefix)bike Deimos\nGET \(prefix)bike", fence: fence)
        #expect(ran)
        #expect(workbench.editorText == "draft")
        #expect(workbench.cards.count == 1)
        #expect(workbench.cards.first?.execution.resultsMode == .group)
        #expect(workbench.cards.first?.execution.summary?.success == 2)
        #expect(session.navigator.section == .workbench)
    }
}

/// RediSearch visualizations against real Redis 8 replies (DB 0, unique prefix and index, dropped afterwards).
@MainActor
@Suite(.serialized, .tags(.live), RedisTestServer.live(.redis, modules: .search))
struct SearchVisualizationLiveTests {
    @Test func searchInfoExplainAndProfileParse() async throws {
        let prefix = RedisTestServer.uniquePrefix("wbsearch")
        let index = "idx:\(prefix)"
        let session = try await RedisTestServer.liveSession(db: RedisTestServer.DB.search)
        try #require(session.capabilities.hasSearch)
        let model = WorkbenchViewModel(session: session)
        defer {
            Task {
                _ = try? await session.execute(["FT.DROPINDEX", .string(index)])
                await removeKeys(db: RedisTestServer.DB.search, prefix: prefix)
            }
        }
        await model.run(script: """
        FT.CREATE \(index) ON HASH PREFIX 1 \(prefix) SCHEMA name TEXT SORTABLE price NUMERIC
        HSET \(prefix)1 name "Deimos bike" price 10
        HSET \(prefix)2 name "Phobos bike" price 20
        """)
        #expect(model.cards.allSatisfy { $0.result?.status == .success })

        var table: SearchTableModel?
        for _ in 0..<20 {
            await model.run(script: "FT.SEARCH \(index) bike WITHSCORES")
            if case .reply(let node)? = model.cards[0].result?.response {
                table = SearchResultParser.parse(node, command: model.cards[0].execution.command)
            }

            if table?.matched == "2" { break }
            try await Task.sleep(for: .milliseconds(100))
        }

        let parsed = try #require(table)
        #expect(parsed.matched == "2")
        #expect(parsed.columns.prefix(2) == ["Doc", "Score"])
        #expect(parsed.columns.contains("name"))
        #expect(model.cards[0].selectedView == .searchTable)

        await model.run(script: "FT.INFO \(index)")
        guard case .reply(let infoNode)? = model.cards[0].result?.response else {
            Issue.record("FT.INFO reply")
            return
        }
        let info = try #require(IndexInfoParser.parse(infoNode))
        #expect(info.keyType == "HASH")
        #expect(info.prefixes == [prefix])
        #expect(info.flagColumns.contains("SORTABLE"))
        #expect(info.attributes.count == 2)

        await model.run(script: "FT.SEARCH \(index) bike")
        let searchCard = try #require(model.cards.first)
        await model.runGenerated(for: searchCard, explain: true)
        #expect(model.cards[0].execution.command.hasPrefix("FT.EXPLAIN"))
        #expect(model.cards[0].selectedView == .explain)
        guard case .reply(let explainNode)? = model.cards[0].result?.response else {
            Issue.record("FT.EXPLAIN reply")
            return
        }
        if case .tree = ExplainParser.parse(explainNode) {} else { Issue.record("explain tree expected") }

        await model.runGenerated(for: searchCard, explain: false)
        #expect(model.cards[0].execution.command.hasPrefix("FT.PROFILE"))
        #expect(model.cards[0].selectedView == .profile)
        guard case .reply(let profileNode)? = model.cards[0].result?.response else {
            Issue.record("FT.PROFILE reply")
            return
        }
        let profile = try #require(ProfileParser.parse(profileNode))
        #expect(profile.tree != nil)
        #expect(!profile.metrics.isEmpty)
        let profileTable = SearchResultParser.parse(profileNode, command: model.cards[0].execution.command)
        #expect(profileTable?.rows.count == 2)

        await model.run(script: "FT.AGGREGATE \(index) * GROUPBY 0 REDUCE COUNT 0 AS total")
        guard case .reply(let aggregateNode)? = model.cards[0].result?.response else {
            Issue.record("FT.AGGREGATE reply")
            return
        }
        let aggregate = try #require(SearchResultParser.parse(aggregateNode, command: model.cards[0].execution.command))
        #expect(aggregate.columns == ["total"])
        #expect(aggregate.rows.first?["total"] == "2")
    }
}

func removeKeys(db: Int, prefix: String) async {
    guard let connection = try? await RedisTestServer.makeConnection(db: db) else { return }
    try? await RedisTestServer.deleteKeys(connection, prefix: prefix)
    await connection.close()
}
