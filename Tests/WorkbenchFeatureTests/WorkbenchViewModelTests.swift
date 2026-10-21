import Foundation
@testable import WorkbenchFeature
import RedisCore
import TestSupport
import Testing

/// Live Workbench flows on DB 7 of the test server (unique key prefixes; no flushes).
@MainActor
@Suite(.serialized, .tags(.live), RedisTestServer.live(.redis))
struct WorkbenchViewModelLiveTests {
    let prefix = RedisTestServer.uniquePrefix("wb")

    private func makeModel() async throws -> WorkbenchViewModel {
        let session = try await RedisTestServer.liveSession(db: RedisTestServer.DB.workbench)
        let model = WorkbenchViewModel(session: session)
        await model.onAppear()
        return model
    }

    private func cleanup() async {
        await removeKeys(db: RedisTestServer.DB.workbench, prefix: prefix)
    }

    private func text(_ card: WorkbenchCard) async -> [String] {
        await card.renderText().value
        return card.lines?.map(\.text) ?? []
    }

    @Test func editorRunCreatesCardsInScriptOrderAndClearsEditor() async throws {
        let model = try await makeModel()
        defer { Task { await cleanup() } }
        #expect(model.historyLoaded)
        #expect(model.cards.isEmpty)
        model.editorText = "SET \(prefix)a \"hello world\"\nGET \(prefix)a"
        await model.runEditor()
        #expect(model.editorText.isEmpty)
        #expect(!model.isRunning)
        #expect(model.cards.count == 2)
        let set = model.cards[0], get = model.cards[1]
        #expect(set.execution.command.hasPrefix("SET"))
        #expect(get.execution.command.hasPrefix("GET"))
        #expect(get.isOpen)
        #expect(get.isPersisted)
        #expect(get.execution.executionTime != nil)
        #expect(await text(set) == ["\"OK\""])
        #expect(await text(get) == ["\"hello world\""])
        #expect(model.scrollToTopToken > 0)
    }

    @Test func cleanupSettingOffKeepsEditor() async throws {
        let model = try await makeModel()
        defer { Task { await cleanup() } }
        model.session.services.settings.app.workbenchCleanup = false
        model.editorText = "PING"
        await model.runEditor()
        #expect(model.editorText == "PING")
        #expect(model.cards.count == 1)
    }

    @Test func groupModeProducesOneSummaryCard() async throws {
        let model = try await makeModel()
        defer { Task { await cleanup() } }
        model.session.services.settings.app.workbenchResultsMode = .group
        model.editorText = "SET \(prefix)g 1\nINCR \(prefix)g\nHSET \(prefix)g f v"
        await model.runEditor()
        #expect(model.cards.count == 1)
        let card = try #require(model.cards.first)
        #expect(card.isGroup)
        #expect(card.title == "3 Command(s) - 2 success, 1 error(s)")
        #expect(card.viewOptions == [.text])
        let lines = await text(card)
        #expect(lines.first == "[db7] > SET \(prefix)g 1")
        #expect(lines.contains("(integer) 2"))
        #expect(card.lines?.contains { $0.style == .error && $0.text.hasPrefix("WRONGTYPE") } == true)
    }

    @Test func silentParamsLineWithoutErrorsIsNotExpandable() async throws {
        let model = try await makeModel()
        defer { Task { await cleanup() } }
        await model.run(script: "[results=silent]\nSET \(prefix)s 1\nGET \(prefix)s")
        let card = try #require(model.cards.first)
        #expect(model.cards.count == 1)
        #expect(card.execution.resultsMode == .silent)
        #expect(!card.isExpandable)
        #expect(!card.isOpen)
        #expect(card.title == "2 Command(s) - 2 success")
    }

    @Test func pipelineParamChunksCommands() async throws {
        let model = try await makeModel()
        defer { Task { await cleanup() } }
        await model.run(script: "[pipeline=2]\n5 INCR \(prefix)counter")
        #expect(model.cards.count == 5)
        #expect(await text(model.cards[0]).first?.hasPrefix("(integer)") == true)
        var all: [String] = []
        for card in model.cards { all += await text(card) }
        #expect(Set(all) == Set((1...5).map { "(integer) \($0)" }))
    }

    @Test func rawModeShowsUTF8AndASCIIEscapes() async throws {
        let model = try await makeModel()
        defer { Task { await cleanup() } }
        await model.run(script: "SET \(prefix)u \"caf\\xc3\\xa9\"")
        await model.run(script: "GET \(prefix)u", params: ExecuteParams(mode: .ascii, clearEditor: false))
        #expect(await text(model.cards[0]) == ["\"caf\\xc3\\xa9\""])
        await model.run(script: "GET \(prefix)u", params: ExecuteParams(mode: .raw, clearEditor: false))
        #expect(await text(model.cards[0]) == ["\"café\""])
        #expect(model.cards[0].execution.mode == .raw)
    }

    @Test func unsupportedAndInvalidCommandsFailWithoutBreakingTheRun() async throws {
        let model = try await makeModel()
        defer { Task { await cleanup() } }
        await model.run(script: "BLPOP \(prefix)l 0\nSUBSCRIBE ch\nSET \(prefix)x \"unterminated\nPING")
        #expect(model.cards.count == 4)
        let blpop = model.cards[0]
        #expect(blpop.result?.status == .fail)
        #expect(WorkbenchResultFormatter.specialMessage(for: blpop.execution.command) != nil)
        let set = model.cards[2]
        #expect(set.result?.status == .fail)
        let unbalanced = CommandLineSplitterError.unbalancedQuotes.localizedDescription
        #expect(await text(set).first?.contains(unbalanced) == true)
        #expect(await text(model.cards[3]) == ["\"PONG\""])
    }

    @Test func historyReloadsLazilyAndCardsCanBeDeleted() async throws {
        let model = try await makeModel()
        defer { Task { await cleanup() } }
        await model.run(script: "SET \(prefix)h v\nGET \(prefix)h")
        let reloaded = WorkbenchViewModel(session: model.session)
        await reloaded.loadHistory()
        #expect(reloaded.cards.count == 2)
        let card = reloaded.cards[1]
        #expect(!card.isOpen)
        #expect(card.execution.result == nil)
        await reloaded.toggle(card)
        #expect(card.isOpen)
        #expect(card.execution.result != nil)
        #expect(await text(card) == ["\"v\""])

        await reloaded.delete(reloaded.cards[0])
        #expect(reloaded.cards.count == 1)
        let again = WorkbenchViewModel(session: model.session)
        await again.loadHistory()
        #expect(again.cards.count == 1)

        await again.clearResults()
        #expect(again.cards.isEmpty)
        let empty = WorkbenchViewModel(session: model.session)
        await empty.loadHistory()
        #expect(empty.cards.isEmpty)
    }

    @Test func rerunUsesCardModeAndKeepsEditor() async throws {
        let model = try await makeModel()
        defer { Task { await cleanup() } }
        await model.run(script: "INCR \(prefix)r", params: ExecuteParams(mode: .raw, clearEditor: false))
        model.editorText = "draft"
        await model.rerun(try #require(model.cards.first))
        #expect(model.cards.count == 2)
        #expect(model.cards[0].execution.mode == .raw)
        #expect(await text(model.cards[0]) == ["(integer) 2"])
        #expect(model.editorText == "draft")
    }

    @Test func historyUpWalksPreviousCommands() async throws {
        let model = try await makeModel()
        defer { Task { await cleanup() } }
        await model.run(script: "SET \(prefix)k 1")
        await model.run(script: "GET \(prefix)k")
        #expect(model.historyUp(caretAtStart: true))
        #expect(model.editorText == "GET \(prefix)k")
        #expect(model.historyUp(caretAtStart: false))
        #expect(model.editorText == "SET \(prefix)k 1")
        #expect(model.historyUp(caretAtStart: false))
        #expect(model.editorText.isEmpty)
        model.editorText = "typed"
        model.editorTextDidChange()
        #expect(!model.historyUp(caretAtStart: false))
    }

    @Test(RedisTestServer.needs(.timeSeries)) func timeSeriesDefaultsToChartAndRemembersTextChoice() async throws {
        let model = try await makeModel()
        defer { Task { await cleanup() } }
        let key = "\(prefix)ts"
        await model.run(script: "TS.ADD \(key) 1000 1.5\nTS.ADD \(key) 2000 2.5\nTS.RANGE \(key) - +")
        let card = model.cards[2]
        #expect(card.selectedView == .timeSeries)
        #expect(card.viewOptions == [.text, .timeSeries])
        if case .reply(let node)? = card.result?.response {
            let series = try #require(TimeSeriesParser.parse(node, command: card.execution.command))
            #expect(series.first?.points.count == 2)
        } else {
            Issue.record("expected a reply")
        }

        model.select(.text, for: card)
        #expect(model.timeSeriesPreferences.selectedView == "text")
        try await Task.sleep(for: .milliseconds(200))
        let fresh = WorkbenchViewModel(session: model.session)
        await fresh.onAppear()
        #expect(fresh.timeSeriesPreferences.selectedView == "text")
        #expect(fresh.cards.first.map { fresh.defaultView(for: $0.execution) } == .text)
    }

    @Test(RedisTestServer.needs(.json)) func jsonAndClientListPickTheirViews() async throws {
        let model = try await makeModel()
        defer { Task { await cleanup() } }
        await model.run(script: "JSON.SET \(prefix)j $ '{\"a\":[1,2],\"b\":\"x\"}'\nJSON.GET \(prefix)j\nCLIENT LIST")
        #expect(model.cards[1].selectedView == .json)
        #expect(model.cards[2].selectedView == .clientList)
        if case .reply(let node)? = model.cards[1].result?.response {
            #expect(JSONResultParser.parse(node, command: model.cards[1].execution.command, mode: .ascii) != nil)
        }

        if case .reply(let node)? = model.cards[2].result?.response, let text = node.scalarText {
            #expect(!ClientListParser.parse(text).rows.isEmpty)
        } else {
            Issue.record("CLIENT LIST should be a text reply")
        }
    }

    @Test func completionsSuggestCommands() async throws {
        let model = try await makeModel()
        let items = model.completions(text: "HGETA", cursor: 5)
        #expect(items.contains { $0.label.uppercased() == "HGETALL" })
        let hint = model.signature(text: "SET key ", cursor: 8)
        #expect(hint?.label.uppercased().hasPrefix("SET") == true)
    }

    @Test func geoSearchShowsMapWithCoordinates() async throws {
        let model = try await makeModel()
        defer { Task { await cleanup() } }
        let key = "\(prefix)geo"
        await model.run(script: """
        GEOADD \(key) 13.361389 38.115556 Palermo 15.087269 37.502669 Catania
        GEOSEARCH \(key) FROMLONLAT 15 37 BYRADIUS 200 km ASC WITHCOORD WITHDIST
        """)
        let card = model.cards[1]
        #expect(card.selectedView == .geoMap)
        guard case .reply(let node)? = card.result?.response else {
            Issue.record("expected a reply")
            return
        }
        let geo = try #require(GeoParser.parse(node, command: card.execution.command))
        #expect(geo.rows.map(\.member) == ["Catania", "Palermo"])
        #expect(geo.locatedRows.count == 2)
    }
}

/// Logic that must never reach a server (FLUSHDB guard, production confirmation, query library).
@MainActor
struct WorkbenchViewModelMockTests {
    @Test func flushWarningCancelSendsNothing() async throws {
        let client = MockRedisClient()
        let session = RedisTestServer.mockSession(client)
        let model = WorkbenchViewModel(session: session)
        let run = Task { await model.run(script: "SET a 1\nFLUSHDB") }
        for _ in 0..<100 where model.flushWarning == nil { try await Task.sleep(for: .milliseconds(10)) }
        let warning = try #require(model.flushWarning)
        #expect(warning.verbs == ["FLUSHDB"])
        #expect(warning.message.contains("search index"))
        model.resolveFlushWarning(proceed: false)
        #expect(await run.value == false)
        #expect(model.cards.isEmpty)
        #expect(await client.executedCommandStrings.allSatisfy { !$0.uppercased().contains("FLUSH") })
    }

    @Test func escapedFlushVerbStillWarnsAndAsksInProduction() async throws {
        let client = MockRedisClient()
        let session = RedisTestServer.mockSession(client, config: DatabaseConfig(name: "Prod", environment: .production))
        let model = WorkbenchViewModel(session: session)
        let run = Task { await model.run(script: #""\x46LUSHDB""#) }
        for _ in 0..<100 where session.confirmations.pending == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(session.confirmations.pending?.actionID == "dangerous:FLUSHDB")
        session.confirmations.resolve(confirmed: true)
        for _ in 0..<100 where model.flushWarning == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(model.flushWarning?.verbs == ["FLUSHDB"])
        model.resolveFlushWarning(proceed: false)
        #expect(await run.value == false)
        #expect(await client.executedCommands.isEmpty)
    }

    @Test func productionDangerousCommandAsksForConfirmation() async throws {
        var config = DatabaseConfig(name: "Prod")
        config.environment = .production
        let client = MockRedisClient()
        let session = RedisTestServer.mockSession(client, config: config)
        session.confirmations.isProduction = true
        let model = WorkbenchViewModel(session: session)
        let run = Task { await model.confirmDangerous(["KEYS *"]) }
        for _ in 0..<100 where session.confirmations.pending == nil { try await Task.sleep(for: .milliseconds(10)) }
        let pending = try #require(session.confirmations.pending)
        #expect(pending.title == "Production Database: Check Before Running")
        #expect(pending.confirmButtonTitle == "Run Command")
        session.confirmations.resolve(confirmed: false)
        #expect(await run.value == false)
        #expect(await model.confirmDangerous(["GET a"]))
    }

    @Test func busyRunIsRejected() async throws {
        let session = RedisTestServer.mockSession()
        let model = WorkbenchViewModel(session: session)
        let first = Task { await model.run(script: "FLUSHALL") }
        for _ in 0..<100 where model.flushWarning == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await model.run(script: "PING") == false)
        model.resolveFlushWarning(proceed: false)
        #expect(await first.value == false)
    }

    @Test func emptyAndCommentOnlyScriptsDoNothing() async {
        let model = WorkbenchViewModel(session: RedisTestServer.mockSession())
        model.editorText = "   \n"
        await model.runEditor()
        #expect(await model.run(script: "// just a comment") == false)
        #expect(model.cards.isEmpty)
    }

    @Test func paramsResolutionOrder() {
        let session = RedisTestServer.mockSession()
        session.services.settings.app.workbenchBatchSize = 7
        session.services.settings.app.workbenchRunQueryMode = .raw
        let model = WorkbenchViewModel(session: session)
        let fromSettings = model.resolveParams(script: "GET a", params: ExecuteParams(clearEditor: true))
        #expect(fromSettings.batchSize == 7)
        #expect(fromSettings.mode == .raw)
        #expect(fromSettings.resultsMode == .default)
        let inline = model.resolveParams(script: "[mode=ascii;results=group;pipeline=2;clearEditor=false]\nGET a",
                                         params: ExecuteParams(mode: .raw, clearEditor: true))
        #expect(inline.mode == .ascii)
        #expect(inline.resultsMode == .group)
        #expect(inline.batchSize == 2)
        #expect(inline.clearEditor == false)
    }

    @Test func enqueueScriptReplacesEditor() {
        let model = WorkbenchViewModel(session: RedisTestServer.mockSession())
        model.editorText = "old"
        model.enqueueScript("FT.SEARCH idx *")
        #expect(model.editorText == "FT.SEARCH idx *")
    }

    @Test func sharedInstanceIsScopedToSession() {
        let session = RedisTestServer.mockSession()
        #expect(WorkbenchViewModel.shared(for: session) === WorkbenchViewModel.shared(for: session))
    }

    @Test func queryLibrarySaveSearchLoadDelete() async throws {
        let session = RedisTestServer.mockSession()
        let model = WorkbenchViewModel(session: session)
        model.editorText = "FT.SEARCH idx:gear '@brand:{Velorim}'"
        await #expect(throws: WorkbenchError.emptyName) { try await model.saveQuery(name: "  ") }
        await #expect(throws: WorkbenchError.emptyQuery) { try await model.saveQuery(name: "Empty", query: " ") }
        #expect(session.toasts.toasts.isEmpty)
        let saved = try await model.saveQuery(name: "Velorim gear")
        #expect(saved.indexName == "idx:gear")
        try await model.saveQuery(name: "Ping", query: "PING")
        await model.loadLibrary()
        #expect(model.libraryItems.map(\.name) == ["Velorim gear", "Ping"])
        #expect(model.filteredLibrary("velorim").map(\.name) == ["Velorim gear"])
        #expect(model.filteredLibrary("ping").count == 1)
        #expect(model.filteredLibrary("").count == 2)
        model.editorText = ""
        model.loadQuery(saved)
        #expect(model.editorText == saved.query)
        await model.deleteQuery(saved)
        #expect(model.libraryItems.map(\.name) == ["Ping"])
        let other = WorkbenchViewModel(session: session)
        await other.loadLibrary()
        #expect(other.libraryItems.count == 1)
    }

    @Test func sampleQueriesLoadWithDescription() {
        let model = WorkbenchViewModel(session: RedisTestServer.mockSession())
        let item = QueryLibraryItem(databaseId: model.session.id, indexName: "idx", type: .sample, name: "n",
                                    description: "Find gear", query: "FT.SEARCH idx *")
        model.loadQuery(item)
        #expect(model.editorText == "// Find gear\nFT.SEARCH idx *")
    }
}
