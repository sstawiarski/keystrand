import Foundation
@testable import BrowserFeature
import RedisCore
import TestSupport
import Testing

/// Live Browser session on DB 4 (emptied per test) with a fresh view model.
@MainActor
final class BrowserHarness {
    let session: DatabaseSession
    let connection: RedisConnection
    let model: BrowserViewModel

    private init(session: DatabaseSession, connection: RedisConnection) {
        self.session = session
        self.connection = connection
        self.model = BrowserViewModel(session: session)
    }

    static func make(view: KeyViewType = .list, db: Int = RedisTestServer.DB.browser) async throws -> BrowserHarness {
        let connection = db == 0 ? try await RedisTestServer.makeConnection(db: 0)
            : try await RedisTestServer.freshConnection(db: db)
        let session = try await RedisTestServer.liveSession(db: db)
        session.services.settings.browser.viewType = view
        session.services.settings.browser.searchMode = .pattern
        return BrowserHarness(session: session, connection: connection)
    }

    func key(_ name: String) -> Data { Data(name.utf8) }

    func names() -> [String] { model.keys.map { String(decoding: $0.name, as: UTF8.self) } }

    @discardableResult
    func run(_ args: [RedisArgument]) async throws -> RESPValue {
        try await connection.execute(args)
    }

    func exists(_ name: String) async throws -> Bool {
        try await run(["EXISTS", .string(name)]).intValue == 1
    }

    var toastTitles: [String] { session.toasts.toasts.map(\.title) }

    func close() async {
        await model.sessionWillClose()
        await connection.close()
        await session.close()
    }
}

@MainActor
func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() > deadline { return false }
        try? await Task.sleep(for: .milliseconds(20))
    }

    return true
}

@MainActor
func waitForSettings(_ session: DatabaseSession, timeout: TimeInterval = 5,
                     _ condition: (DatabaseSettings) -> Bool) async -> DatabaseSettings? {
    let deadline = Date().addingTimeInterval(timeout)
    while true {
        let settings = await session.services.databaseSettingsStore.settings(for: session.id)
        if condition(settings) { return settings }
        if Date() > deadline { return nil }
        try? await Task.sleep(for: .milliseconds(20))
    }
}

@MainActor
@Suite(.serialized, .tags(.live), RedisTestServer.live(.redis))
struct BrowserLiveTests {

    // MARK: - Scanning and summary

    @Test func listViewLoadsKeysWithTotal() async throws {
        let h = try await BrowserHarness.make()
        defer { Task { await h.close() } }
        try await RedisTestServer.seedStrings(h.connection, prefix: "k:", count: 30)
        await h.model.start()
        #expect(h.model.keys.count == 30)
        #expect(h.model.total == 30)
        #expect(h.model.isComplete)
        #expect(h.model.summaryText == "30 keys")
        #expect(!h.model.showsScanMoreButton)
        #expect(!h.model.isDatabaseEmpty)
    }

    @Test func emptyDatabaseState() async throws {
        let h = try await BrowserHarness.make()
        defer { Task { await h.close() } }
        await h.model.start()
        #expect(h.model.hasStarted)
        #expect(h.model.isDatabaseEmpty)
        #expect(h.model.summaryText == "0 keys")
    }

    @Test func scanMoreLoadsEveryKeyOnce() async throws {
        let h = try await BrowserHarness.make()
        defer { Task { await h.close() } }
        try await RedisTestServer.seedStrings(h.connection, prefix: "many:", count: 1_500)
        await h.model.start()
        #expect(h.model.keys.count >= BrowserViewModel.listScanCount)
        var rounds = 0
        while !h.model.isComplete && rounds < 20 {
            h.model.scanMore()
            await h.model.waitForLoad()
            rounds += 1
        }

        #expect(h.model.isComplete)
        #expect(h.model.keys.count == 1_500)
        #expect(Set(h.model.keys.map(\.name)).count == 1_500)
    }

    @Test func patternFilterExactMatchAndReset() async throws {
        let h = try await BrowserHarness.make()
        defer { Task { await h.close() } }
        try await RedisTestServer.seedStrings(h.connection, prefix: "alpha:", count: 5)
        try await RedisTestServer.seedStrings(h.connection, prefix: "beta:", count: 3)
        await h.model.start()
        #expect(h.model.keys.count == 8)

        h.model.patternText = "beta:*"
        h.model.applyPattern()
        await h.model.waitForLoad()
        #expect(h.model.isFiltered)
        #expect(Set(h.names()) == ["beta:0", "beta:1", "beta:2"])
        #expect(h.model.summaryText.hasPrefix("Found 3 ·"))
        #expect(h.model.historyItems.first?.match == "beta:*")

        h.model.patternText = "alpha:2"
        h.model.applyPattern()
        await h.model.waitForLoad()
        #expect(h.names() == ["alpha:2"])
        #expect(h.model.keys.first?.type == .string)
        #expect(h.model.isComplete)

        h.model.patternText = "missing"
        h.model.applyPattern()
        await h.model.waitForLoad()
        #expect(h.model.keys.isEmpty)
        #expect(!h.model.isDatabaseEmpty)

        h.model.resetFilters()
        await h.model.waitForLoad()
        #expect(!h.model.isFiltered)
        #expect(h.model.keys.count == 8)
        #expect(h.model.patternText.isEmpty)
    }

    @Test func clearingTheSearchFieldShowsEveryKey() async throws {
        let h = try await BrowserHarness.make()
        defer { Task { await h.close() } }
        try await RedisTestServer.seedStrings(h.connection, prefix: "alpha:", count: 2)
        try await RedisTestServer.seedStrings(h.connection, prefix: "beta:", count: 3)
        await h.model.start()

        h.model.searchFieldEdited("beta:*")
        h.model.applyPattern()
        await h.model.waitForLoad()
        #expect(h.model.appliedPattern == "beta:*")

        h.model.searchFieldEdited("beta")
        #expect(h.model.appliedPattern == "beta:*")
        h.model.searchFieldEdited("")
        #expect(h.model.appliedPattern == "*")
        await h.model.waitForLoad()
        #expect(!h.model.isFiltered)
        #expect(h.model.keys.count == 5)

        h.model.searchFieldEdited("")
        h.model.searchFieldCleared()
        #expect(h.model.appliedPattern == "*")

        h.model.patternText = "alpha:*"
        h.model.applyPattern()
        await h.model.waitForLoad()
        h.model.patternText = ""
        #expect(h.model.appliedPattern == "alpha:*")
    }

    @Test(RedisTestServer.needs(.json, .timeSeries, .vectorSet)) func typeFilterPrefillsType() async throws {
        let h = try await BrowserHarness.make()
        defer { Task { await h.close() } }
        let seeded = try await RedisTestServer.seedAllTypes(h.connection, prefix: "t:")
        await h.model.start()
        #expect(h.model.keys.count == seeded.keys.count)
        h.model.setTypeFilter(.hash)
        await h.model.waitForLoad()
        #expect(h.model.keys.map(\.name) == [seeded.name(.hash)])
        #expect(h.model.keys.first?.type == .hash)
        #expect(h.model.isFiltered)
        h.model.setTypeFilter(.zset)
        await h.model.waitForLoad()
        #expect(h.model.keys.map(\.name) == [seeded.name(.zset)])
    }

    @Test(RedisTestServer.needs(.json, .timeSeries, .vectorSet)) func historyAppliesTypeFilterAndPersists() async throws {
        let h = try await BrowserHarness.make()
        defer { Task { await h.close() } }
        _ = try await RedisTestServer.seedAllTypes(h.connection, prefix: "h:")
        await h.model.start()
        h.model.setTypeFilter(.set)
        await h.model.waitForLoad()
        h.model.patternText = "h:*"
        h.model.applyPattern()
        await h.model.waitForLoad()
        let item = try #require(h.model.historyItems.first)
        #expect(item.type == .set)
        h.model.resetFilters()
        await h.model.waitForLoad()
        #expect(h.model.typeFilter == nil)
        h.model.applyHistory(item)
        await h.model.waitForLoad()
        #expect(h.model.typeFilter == .set)
        #expect(h.model.keys.count == 1)
        let saved = await waitForSettings(h.session) { $0.searchHistory.contains { $0.match == "h:*" } }
        #expect(saved != nil)
        h.model.clearHistory()
        #expect(h.model.historyItems.isEmpty)
    }

    // MARK: - Metadata and columns

    @Test func lazyMetadataLoadsVisibleRows() async throws {
        let h = try await BrowserHarness.make()
        defer { Task { await h.close() } }
        try await h.run(["SET", "meta:ttl", "value", "EX", "500"])
        try await h.run(["HSET", "meta:hash", "f", "v"])
        await h.model.start()
        for item in h.model.keys { h.model.rowAppeared(item.name) }
        let loaded = await waitUntil { h.model.keys.allSatisfy { $0.type != nil && $0.ttl != nil } }
        #expect(loaded)
        let ttlRow = try #require(h.model.item(for: h.key("meta:ttl")))
        #expect(ttlRow.type == .string)
        #expect((ttlRow.ttl ?? 0) > 400)
        #expect((ttlRow.size ?? 0) > 0)
        #expect(h.model.item(for: h.key("meta:hash"))?.ttl == -1)
        #expect(h.model.item(for: h.key("meta:hash"))?.type == .hash)
    }

    @Test func hidingColumnsPersistsAndClearsSort() async throws {
        let h = try await BrowserHarness.make()
        defer { Task { await h.close() } }
        await h.model.start()
        h.model.toggleSort(.size, order: .desc)
        #expect(h.model.sort == KeyListSort(field: .size, order: .desc))
        h.model.setColumn(.size, shown: false)
        #expect(!h.model.showsSize)
        #expect(h.model.sort == nil)
        h.model.toggleSort(.name, order: .asc)
        h.model.toggleSort(.name, order: .asc)
        #expect(h.model.sort == nil)
        let settings = await waitForSettings(h.session) { $0.didUserConfigureColumns }
        #expect(settings?.browserShownColumns == [.ttl])
    }

    // MARK: - Tree

    @Test func treeViewGroupsAndAutoExpands() async throws {
        let h = try await BrowserHarness.make(view: .tree)
        defer { Task { await h.close() } }
        try await RedisTestServer.seedStrings(h.connection, prefix: "user:", count: 5)
        try await RedisTestServer.seedStrings(h.connection, prefix: "order:", count: 3)
        try await h.run(["SET", "solo", "1"])
        await h.model.start()
        await h.model.waitForTree()
        #expect(h.model.viewType == .tree)
        #expect(h.model.treeRoots.map(\.name) == ["order", "user", "solo"])
        #expect(h.model.treeRoots[1].keyCount == 5)
        #expect(h.model.summaryText.hasPrefix("Found 9 ·"))
        #expect(h.model.showsScanMoreButton == false)
        #expect(h.model.treeRows.count == 3)
        h.model.toggleFolder("user")
        #expect(h.model.treeRows.count == 8)
        h.model.toggleFolder("user")
        #expect(h.model.treeRows.count == 3)
    }

    @Test func treeAutoExpandsSingleChildChainAndSelectedParents() async throws {
        let h = try await BrowserHarness.make(view: .tree)
        defer { Task { await h.close() } }
        try await h.run(["SET", "app:cache:1", "a"])
        try await h.run(["SET", "app:cache:2", "b"])
        await h.model.start()
        await h.model.waitForTree()
        let sep = KeyTreeBuilder.pathSeparator
        #expect(h.model.expandedFolders.isSuperset(of: ["app", "app\(sep)cache"]))
        #expect(h.model.treeRows.count == 4)

        try await h.run(["SET", "zzz:deep:key", "c"])
        h.model.reload()
        await h.model.waitForLoad()
        await h.model.waitForTree()
        h.model.select(h.key("zzz:deep:key"))
        #expect(h.model.expandedFolders.isSuperset(of: ["zzz", "zzz\(sep)deep"]))
        #expect(h.model.treeRows.contains { $0.node.keyName == h.key("zzz:deep:key") })
    }

    @Test func treeSettingsPersistAndRebuild() async throws {
        let h = try await BrowserHarness.make(view: .tree)
        defer { Task { await h.close() } }
        try await h.run(["SET", "a-b-1", "x"])
        try await h.run(["SET", "a-b-2", "x"])
        await h.model.start()
        await h.model.waitForTree()
        #expect(h.model.treeRoots.count == 2)
        h.model.applyTreeSettings(delimiters: ["-", ""], prefixLength: 900, sort: .desc)
        await h.model.waitForTree()
        #expect(h.model.treeOptions.delimiters == ["-"])
        #expect(h.model.treeOptions.prefixLength == KeyTreeBuilder.maxPrefixLength)
        h.model.applyTreeSettings(delimiters: ["-"], prefixLength: 0, sort: .asc)
        await h.model.waitForTree()
        #expect(h.model.treeRoots.count == 1)
        #expect(h.model.treeRoots[0].keyCount == 2)
        let folder = h.model.treeRoots[0]
        #expect(h.model.canDeleteFolder(folder))
        #expect(h.model.folderPattern(folder) == "a-*")
        let saved = await waitForSettings(h.session) {
            $0.treeViewDelimiters == ["-"] && $0.treeViewDelimiterPrefixLength == 0
        }
        #expect(saved != nil)
        h.model.applyTreeSettings(delimiters: [], prefixLength: 0, sort: .asc)
        #expect(h.model.treeOptions.delimiters == [":"])
    }

    // MARK: - Delete, add, details

    @Test func rowDeleteRemovesKeyAndDecrementsTotal() async throws {
        let h = try await BrowserHarness.make()
        defer { Task { await h.close() } }
        try await RedisTestServer.seedStrings(h.connection, prefix: "d:", count: 3)
        await h.model.start()
        h.model.select(h.key("d:1"))
        await h.model.deleteKey(h.key("d:1"))
        #expect(h.model.keys.count == 2)
        #expect(h.model.total == 2)
        #expect(h.model.selectedKey == nil)
        #expect(h.model.rightPanel == .none)
        #expect(try await h.exists("d:1") == false)
        #expect(h.toastTitles.isEmpty, "unexpected errors: \(h.session.toasts.toasts.map { "\($0.title): \($0.message ?? "")" })")

        await h.model.deleteKey(h.key("d:missing"))
        #expect(h.toastTitles.contains("Error"))
    }

    @Test func detailsContextAndKeyNotFound() async throws {
        let h = try await BrowserHarness.make()
        defer { Task { await h.close() } }
        try await h.run(["HSET", "det:hash", "f1", "v1", "f2", "v2"])
        await h.model.start()
        h.model.select(h.key("det:hash"))
        let loaded = await waitUntil { h.model.details?.info != nil }
        #expect(loaded)
        let context = try #require(h.model.detailsContext)
        #expect(context.type == .hash)
        #expect(context.key == h.key("det:hash"))
        #expect(context.state.info?.length == 2)

        context.onToggleFullScreen()
        #expect(h.model.isListHidden)
        context.onToggleFullScreen()
        #expect(!h.model.isListHidden)

        try await h.run(["DEL", "det:hash"])
        await context.refreshKeyInfo()
        #expect(h.model.details == nil)
        #expect(h.model.rightPanel == .none)
        #expect(h.model.item(for: h.key("det:hash")) == nil)
        #expect(h.toastTitles.contains("Error"))
    }

    @Test func renameAndDeleteCallbacksUpdateList() async throws {
        let h = try await BrowserHarness.make()
        defer { Task { await h.close() } }
        try await h.run(["SET", "ren:old", "v"])
        try await h.run(["SET", "ren:other", "v"])
        await h.model.start()
        h.model.select(h.key("ren:old"))
        _ = await waitUntil { h.model.details?.info != nil }
        h.model.details?.isFullScreen = true
        let context = try #require(h.model.detailsContext)
        try await h.run(["RENAME", "ren:old", "ren:new"])
        context.onKeyRenamed(h.key("ren:new"))
        #expect(h.model.selectedKey == h.key("ren:new"))
        #expect(h.model.item(for: h.key("ren:new")) != nil)
        #expect(h.model.item(for: h.key("ren:old")) == nil)
        #expect(h.model.details?.key == h.key("ren:new"))
        #expect(h.model.details?.isFullScreen == true)

        let renamedContext = try #require(h.model.detailsContext)
        try await h.run(["DEL", "ren:new"])
        renamedContext.onKeyDeleted()
        #expect(h.model.details == nil)
        #expect(!h.model.isListHidden)
        #expect(h.names() == ["ren:other"])
    }

    @Test(RedisTestServer.needs(.json, .timeSeries)) func addKeyForEveryBuiltInType() async throws {
        let h = try await BrowserHarness.make()
        defer { Task { await h.close() } }
        await h.model.start()

        func add(_ type: KeyType, _ name: String, configure: (AddKeyViewModel) -> Void) async throws {
            h.model.openAddKey()
            let form = try #require(h.model.addKey)
            form.type = type
            form.keyName = name
            configure(form)
            #expect(form.validationMessage == nil, "\(type): \(form.validationMessage ?? "")")
            let result = try #require(await form.submit(), "\(type): \(form.errorMessage ?? "")")
            h.model.keyAdded(result.name, type: result.type)
            let reply = try await h.run(["TYPE", .string(name)])
            #expect(KeyType(typeReply: reply.stringValue ?? "") == type)
        }

        try await add(.string, "add:string") { $0.stringValue = "hello"; $0.ttlText = "0100" }
        try await add(.hash, "add:hash") { $0.hashRows = [AddKeyPairRow(name: "f", value: "v")] }
        try await add(.list, "add:list") {
            $0.listDestination = .head
            $0.listElements = [AddKeyTextRow(value: "a"), AddKeyTextRow(value: "b")]
        }
        try await add(.set, "add:set") { $0.setMembers = [AddKeyTextRow(value: "m1"), AddKeyTextRow(value: "m2")] }
        try await add(.zset, "add:zset") { $0.zsetRows = [AddKeyPairRow(name: "m", extra: "1.5")] }
        try await add(.json, "add:json") { $0.jsonText = #"{"a": [1, 2]}"# }
        try await add(.stream, "add:stream") { $0.streamRows = [AddKeyPairRow(name: "f", value: "v")] }
        try await add(.timeSeries, "add:ts") {
            $0.tsRetention = "60000"
            $0.tsLabels = [AddKeyPairRow(name: "sensor", value: "1")]
            $0.tsSamples = [AddKeyPairRow(name: "1000", value: "2.5")]
        }

        let ttl = try await h.run(["TTL", "add:string"]).intValue ?? -1
        #expect(ttl > 90)
        #expect(try await h.run(["LINDEX", "add:list", "0"]).stringValue == "b")
        #expect(try await h.run(["ZSCORE", "add:zset", "m"]).stringValue == "1.5")
        #expect(try await h.run(["TS.GET", "add:ts"]).arrayValue?.count == 2)
        #expect(h.names().first == "add:ts")
        #expect(h.model.keys.count == 8)
        #expect(h.model.total == 8)
        #expect(h.model.selectedKey == h.key("add:ts"))
        #expect(h.model.rightPanel == .details)
        #expect(h.model.addKey == nil)
        #expect(h.model.sheet == nil)
        #expect(h.toastTitles.isEmpty)

        h.model.openAddKey()
        let duplicate = try #require(h.model.addKey)
        duplicate.type = .string
        duplicate.keyName = "add:string"
        #expect(await duplicate.submit() == nil)
        #expect(duplicate.errorMessage == "This key name is already in use.")
        #expect(h.model.sheet == .newKey)
        h.model.closeAddKey()
        #expect(h.model.sheet == nil)
        #expect(h.model.rightPanel == .details)
    }

    @Test(RedisTestServer.needs(.vectorSet)) func addKeyValidation() async throws {
        let h = try await BrowserHarness.make()
        defer { Task { await h.close() } }
        let form = AddKeyViewModel(session: h.session)
        #expect(form.validationMessage == "Enter a key name")
        form.keyName = "v"
        form.type = .zset
        form.zsetRows = [AddKeyPairRow(name: "m", extra: "abc")]
        #expect(form.validationMessage != nil)
        form.zsetRows = [AddKeyPairRow(name: "m", extra: "-inf")]
        #expect(form.validationMessage == nil)
        form.type = .stream
        form.streamID = "abc"
        #expect(form.validationMessage == "Entry ID format is incorrect")
        form.streamID = "*"
        form.streamRows = [AddKeyPairRow()]
        #expect(form.validationMessage == "Enter at least one field")
        form.type = .json
        form.jsonText = "{bad"
        #expect(form.validationMessage == "Enter valid JSON.")
        form.ttlText = "abc12"
        #expect(form.ttlText == "12")
        #expect(form.ttl == 12)
        #expect(form.usesInjectedForm == false)
        form.type = .vectorSet
        #expect(form.usesInjectedForm)
        #expect(form.isAvailable(.vectorSet))
    }

    // MARK: - Bulk actions and sample data

    @Test func bulkDeleteByPattern() async throws {
        let h = try await BrowserHarness.make()
        defer { Task { await h.close() } }
        try await RedisTestServer.seedStrings(h.connection, prefix: "del:", count: 50)
        try await RedisTestServer.seedStrings(h.connection, prefix: "keep:", count: 5)
        await h.model.start()
        h.model.patternText = "del:*"
        h.model.applyPattern()
        await h.model.waitForLoad()
        h.model.openBulkActions()
        let bulk = try #require(h.model.bulkActions)
        let filter = h.model.currentBulkFilter
        #expect(filter.match == "del:*")
        var finished: BulkActionOverview?
        bulk.startDelete(filter) { overview in
            finished = overview
            h.model.bulkDeleteFinished()
        }
        await bulk.waitForDelete()
        #expect(finished?.status == .completed)
        #expect(bulk.deleteOverview?.succeeded == 50)
        #expect(bulk.deleteStatusText == "Completed")
        #expect(bulk.deleteProgress == 100)
        #expect(try await h.run(["DBSIZE"]).intValue == 5)
        await h.model.waitForLoad()
        #expect(h.model.keys.isEmpty)
        bulk.resetDelete()
        #expect(bulk.deleteOverview == nil)
        h.model.closeBulkActions()
        #expect(h.model.bulkActions == nil)
        #expect(h.model.sheet == nil)
    }

    @Test func folderDeleteUsesOverrideFilter() async throws {
        let h = try await BrowserHarness.make(view: .tree)
        defer { Task { await h.close() } }
        await h.model.start()
        let filter = BulkActionFilter(match: "f:*", type: .hash)
        h.model.openBulkActions(filter: filter)
        #expect(h.model.sheet == .bulkActions)
        #expect(h.model.currentBulkFilter == filter)
        h.model.closeBulkActions()
        #expect(h.model.sheet == nil)
    }

    @Test func bulkUploadRunsCommandFile() async throws {
        let h = try await BrowserHarness.make()
        defer { Task { await h.close() } }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("browser-upload-\(UUID().uuidString).txt")
        try Data("SET up:1 a\nSET \"up:2\" \"b c\"\n\nNOTACOMMAND x\n".utf8).write(to: url)
        let bulk = BulkActionsViewModel(session: h.session)
        bulk.fileURL = url
        var final: BulkImportSummary?
        bulk.startUpload { final = $0 }
        await bulk.waitForUpload()
        #expect(!bulk.isUploading)
        #expect(final?.isFinished == true)
        #expect(bulk.uploadSummary?.processed == 3)
        #expect(bulk.uploadSummary?.succeeded == 2)
        #expect(bulk.uploadSummary?.failed == 1)
        #expect(bulk.uploadFileName == url.lastPathComponent)
        #expect(try await h.run(["GET", "up:2"]).stringValue == "b c")
        bulk.resetUpload()
        #expect(bulk.fileURL == nil)
        #expect(bulk.uploadSummary == nil)
    }

    @Test func loadSampleDataFillsEmptyDatabase() async throws {
        let h = try await BrowserHarness.make()
        defer { Task { await h.close() } }
        await h.model.start()
        #expect(h.model.isDatabaseEmpty)
        await h.model.loadSampleData(modules: [])
        #expect(!h.model.isDatabaseEmpty)
        #expect(h.model.keys.count > 10)
        #expect(h.model.viewType == .tree)
        #expect(h.toastTitles.isEmpty)
    }

    // MARK: - Navigation and reloads

    @Test func navigationRequestAppliesPatternAndSelection() async throws {
        let h = try await BrowserHarness.make()
        defer { Task { await h.close() } }
        try await RedisTestServer.seedStrings(h.connection, prefix: "nav:", count: 3)
        try await RedisTestServer.seedStrings(h.connection, prefix: "other:", count: 3)
        let request = DatabaseNavigationRequest.browser(
            BrowserNavigationRequest(pattern: "nav:*", typeFilter: .string, selectedKey: Data("nav:1".utf8)))
        await h.model.start(navigation: request)
        await h.model.waitForLoad()
        #expect(h.model.patternText == "nav:*")
        #expect(h.model.typeFilter == .string)
        #expect(Set(h.names()) == ["nav:0", "nav:1", "nav:2"])
        #expect(h.model.selectedKey == Data("nav:1".utf8))
        #expect(h.model.rightPanel == .details)
    }

    @Test func refreshReturningNothingClearsSelection() async throws {
        let h = try await BrowserHarness.make()
        defer { Task { await h.close() } }
        try await h.run(["SET", "gone", "1"])
        await h.model.start()
        h.model.select(h.key("gone"))
        try await h.run(["DEL", "gone"])
        h.model.reload()
        await h.model.waitForLoad()
        #expect(h.model.keys.isEmpty)
        #expect(h.model.selectedKey == nil)
        #expect(h.model.lastRefresh != nil)
    }

    @Test func logicalDatabaseChangeReloads() async throws {
        let h = try await BrowserHarness.make()
        defer { Task { await h.close() } }
        let prefix = RedisTestServer.uniquePrefix("browsergen")
        try await RedisTestServer.seedStrings(h.connection, prefix: prefix, count: 3)
        await h.model.start()
        #expect(h.model.keys.count == 3)
        h.model.select(h.model.keys[0].name)
        try await h.session.select(db: 0)
        await h.model.start()
        #expect(h.model.selectedKey == nil)
        let reloaded = await waitUntil(timeout: 10) {
            h.model.hasStarted && !h.model.isLoading && !h.names().contains { $0.hasPrefix(prefix) }
        }
        #expect(reloaded)
    }

    // MARK: - Review fixes

    @Test func expiredKeysLeaveTheListInsteadOfStayingSkeletons() async throws {
        let h = try await BrowserHarness.make()
        defer { Task { await h.close() } }
        try await h.run(["SET", "exp:ttl", "1", "PX", "300"])
        try await h.run(["SET", "exp:type", "1", "PX", "300"])
        try await h.run(["SET", "exp:keep", "1"])
        await h.model.start()
        #expect(h.model.keys.count == 3)
        try await Task.sleep(for: .milliseconds(450))
        await h.model.loadMetadata([h.key("exp:ttl"), h.key("exp:keep")])
        #expect(h.model.item(for: h.key("exp:ttl")) == nil)
        #expect(h.model.item(for: h.key("exp:keep"))?.type == .string)
        h.model.setColumn(.ttl, shown: false)
        h.model.setColumn(.size, shown: false)
        await h.model.loadMetadata([h.key("exp:type")])
        #expect(h.model.item(for: h.key("exp:type")) == nil)
        #expect(Set(h.names()) == ["exp:keep"])
        #expect(h.model.total == 1)
    }

    @Test func folderPatternMatchesOnlyTheFolder() async throws {
        let h = try await BrowserHarness.make(view: .tree)
        defer { Task { await h.close() } }
        for name in ["a?b", "a?c", "apple", "abc:1"] { try await h.run(["SET", .string(name), "1"]) }
        await h.model.start()
        h.model.applyTreeSettings(delimiters: ["?"], prefixLength: 0, sort: .asc)
        await h.model.waitForTree()
        let folder = try #require(h.model.treeRoots.first { $0.name == "a" && !$0.isLeaf })
        let pattern = h.model.folderPattern(folder)
        let reply = try await h.run(["SCAN", "0", "MATCH", .string(pattern), "COUNT", "1000"])
        let matched = Set((reply.arrayValue?[1].arrayValue ?? []).compactMap(\.stringValue))
        #expect(matched == ["a?b", "a?c"])
    }

    @Test func wheelScrollScansMoreWhenLastBatchWasEmpty() async throws {
        let h = try await BrowserHarness.make()
        defer { Task { await h.close() } }
        try await RedisTestServer.seedStrings(h.connection, prefix: "wheel:", count: 3_000)
        h.session.services.settings.app.scanThreshold = AppSettings.minimumScanThreshold
        await h.model.start()
        h.model.patternText = "nomatch*"
        h.model.applyPattern()
        await h.model.waitForLoad()
        try #require(!h.model.isComplete)
        #expect(h.model.lastBatchCount == 0)
        #expect(h.model.wantsWheelScanMore)
        let before = h.model.scanned
        h.model.listScrolledDown()
        h.model.listScrolledDown()
        await h.model.waitForWheelScan()
        #expect(h.model.scanned > before || h.model.isComplete)
        h.model.resetFilters()
        await h.model.waitForLoad()
        #expect(!h.model.wantsWheelScanMore)
    }

    @Test func stoppedUploadNeverReportsCompletion() async throws {
        let h = try await BrowserHarness.make()
        defer { Task { await h.close() } }
        let big = FileManager.default.temporaryDirectory.appendingPathComponent("browser-stop-\(UUID().uuidString).txt")
        let lines = (0..<50_000).map { "SET stop:\($0) x" }.joined(separator: "\n")
        try Data(lines.utf8).write(to: big)
        defer { try? FileManager.default.trashItem(at: big, resultingItemURL: nil) }
        let bulk = BulkActionsViewModel(session: h.session)
        bulk.fileURL = big
        var finishedCalls = 0
        bulk.startUpload { _ in finishedCalls += 1 }
        #expect(bulk.isUploading)
        bulk.stopUpload()
        #expect(bulk.isUploading)
        bulk.startUpload { _ in finishedCalls += 1 }
        await bulk.waitForUpload()
        #expect(!bulk.isUploading)
        #expect(bulk.uploadWasStopped)
        #expect(finishedCalls == 0)
        if bulk.uploadSummary != nil { #expect(bulk.uploadStatusText == "Stopped") }

        let small = FileManager.default.temporaryDirectory.appendingPathComponent("browser-small-\(UUID().uuidString).txt")
        try Data("SET after:stop 1\n".utf8).write(to: small)
        defer { try? FileManager.default.trashItem(at: small, resultingItemURL: nil) }
        bulk.resetUpload()
        bulk.fileURL = small
        var final: BulkImportSummary?
        bulk.startUpload { final = $0 }
        await bulk.waitForUpload()
        #expect(final?.processed == 1)
        #expect(!bulk.uploadWasStopped)
        #expect(bulk.uploadStatusText == "Completed")
        #expect(finishedCalls == 0)
    }

    @Test func scrollAnchorRemembersTopVisibleRow() async throws {
        let h = try await BrowserHarness.make()
        defer { Task { await h.close() } }
        try await RedisTestServer.seedStrings(h.connection, prefix: "scroll:", count: 30)
        await h.model.start()
        #expect(h.model.listScrollAnchor() == nil)
        h.model.resumeScrollTracking()
        let rows = h.model.displayedKeys
        for item in rows[8..<20] { h.model.rowAppeared(item.name) }
        h.model.updateScrollAnchor()
        #expect(h.model.listScrollAnchor() == rows[8].name)
        h.model.pauseScrollTracking()
        for item in rows[8..<20] { h.model.rowDisappeared(item.name) }
        try await Task.sleep(for: .milliseconds(250))
        #expect(h.model.listScrollAnchor() == rows[8].name)
        h.model.resumeScrollTracking()
        for item in rows[0..<12] { h.model.rowAppeared(item.name) }
        let moved = await waitUntil { h.model.listScrollAnchor() == rows[0].name }
        #expect(moved)
    }

    @Test(RedisTestServer.needs(.search)) func redisearchModeListsIndexedKeys() async throws {
        let h = try await BrowserHarness.make(db: RedisTestServer.DB.search)
        let prefix = RedisTestServer.uniquePrefix("browsersearch")
        let index = "idx:" + prefix
        do {
            try await searchScenario(h, prefix: prefix, index: index)
        } catch {
            _ = try? await h.run(["FT.DROPINDEX", .string(index)])
            try? await RedisTestServer.deleteKeys(h.connection, prefix: prefix)
            await h.close()
            throw error
        }

        _ = try? await h.run(["FT.DROPINDEX", .string(index)])
        try? await RedisTestServer.deleteKeys(h.connection, prefix: prefix)
        await h.close()
    }

    private func searchScenario(_ h: BrowserHarness, prefix: String, index: String) async throws {
        try await h.run(["HSET", .string(prefix + "1"), "name", "red bike"])
        try await h.run(["HSET", .string(prefix + "2"), "name", "blue bike"])
        try await h.run(["FT.CREATE", .string(index), "ON", "HASH", "PREFIX", "1", .string(prefix),
                         "SCHEMA", "name", "TEXT"])
        await h.model.ensureSettingsLoaded()
        try #require(h.model.isSearchAvailable)
        h.model.setSearchMode(.redisearch)
        #expect(h.model.searchMode == .redisearch)
        let listed = await waitUntil { h.model.indexes.contains(Data(index.utf8)) }
        #expect(listed)
        #expect(h.model.summaryText.isEmpty)
        h.model.selectIndex(Data(index.utf8))
        await h.model.waitForLoad()
        _ = await waitUntil { h.model.keys.count == 2 }
        #expect(Set(h.names()) == [prefix + "1", prefix + "2"])
        #expect(h.model.keys.allSatisfy { $0.type == .hash })

        h.model.patternText = "red"
        h.model.applyPattern()
        await h.model.waitForLoad()
        #expect(h.names() == [prefix + "1"])
        #expect(h.model.historyItems.first?.match == "red")
        h.model.setSearchMode(.pattern)
        #expect(h.model.searchMode == .pattern)
    }

    // MARK: - Key list sheets

    @Test func listRenameAndTTLSheetsUpdateTheList() async throws {
        let h = try await BrowserHarness.make()
        defer { Task { await h.close() } }
        try await h.run(["SET", "sheet:a", "1"])
        try await h.run(["SET", "sheet:b", "2"])
        await h.model.start()
        h.model.select(h.key("sheet:a"))
        h.model.openRename(h.key("sheet:a"))
        #expect(h.model.sheet == .renameKey)
        #expect(h.model.renameDraft(h.key("sheet:a")) == "sheet:a")

        #expect(await h.model.renameKey(h.key("sheet:a"), to: h.key("sheet:b")) == .nameInUse)
        #expect(await h.model.renameKey(h.key("sheet:a"), to: h.key("sheet:c")) == .renamed)
        #expect(h.model.selectedKey == h.key("sheet:c"))
        #expect(Set(h.names()) == ["sheet:b", "sheet:c"])
        h.model.sheetDismissed()
        #expect(h.model.sheet == nil)

        h.model.openSetTTL(h.key("sheet:c"))
        #expect(h.model.ttlDraft(h.key("sheet:c")).isEmpty)
        #expect(await h.model.setTTL(h.key("sheet:c"), seconds: 300))
        let ttl = try await h.run(["TTL", "sheet:c"]).intValue ?? -1
        #expect(ttl > 200)
        #expect(await h.model.setTTL(h.key("sheet:c"), seconds: 0))
        #expect(try await h.exists("sheet:c") == false)
        #expect(h.model.selectedKey == nil)
        #expect(h.names() == ["sheet:b"])
    }

    @Test func deleteRequestAndFolderSubtree() async throws {
        let h = try await BrowserHarness.make(view: .tree)
        defer { Task { await h.close() } }
        try await h.run(["SET", "t:a:1", "x"])
        try await h.run(["SET", "t:a:2", "x"])
        try await h.run(["SET", "t:b:1", "x"])
        await h.model.start()
        await h.model.waitForTree()
        h.model.setFolderSubtree("t", expanded: false)
        #expect(!h.model.expandedFolders.contains("t"))
        h.model.setFolderSubtree("t", expanded: true)
        let separator = KeyTreeBuilder.pathSeparator
        #expect(h.model.expandedFolders.isSuperset(of: ["t", "t\(separator)a", "t\(separator)b"]))

        h.model.requestDelete(h.key("t:b:1"))
        #expect(h.model.pendingDeleteKey == h.key("t:b:1"))
    }

    @Test func nonUTF8KeysAreFoundWithHexEscapes() async throws {
        let h = try await BrowserHarness.make()
        defer { Task { await h.close() } }
        let binary = Data([0x62, 0x69, 0x6E, 0x3A, 0xFF, 0xFE])
        try await h.run(["SET", .data(binary), "v"])
        try await h.run(["SET", "bin:plain", "v"])
        await h.model.start()

        h.model.patternText = "bin:\\xff*"
        h.model.applyPattern()
        await h.model.waitForLoad()
        #expect(h.model.keys.map(\.name) == [binary])

        h.model.patternText = "bin:\\xff\\xfe"
        h.model.applyPattern()
        await h.model.waitForLoad()
        #expect(h.model.keys.map(\.name) == [binary])
    }

    @Test func clientSortFollowsMetadataOnlyForTTLAndSize() async throws {
        let h = try await BrowserHarness.make()
        defer { Task { await h.close() } }
        for (name, ttl) in [("s:a", 300), ("s:b", 100), ("s:c", 200)] {
            try await h.run(["SET", .string(name), "v", "EX", .string(String(ttl))])
        }

        await h.model.start()
        let names = { h.model.displayedKeys.map { String(decoding: $0.name, as: UTF8.self) } }

        h.model.sort = KeyListSort(field: .name, order: .asc)
        #expect(names() == ["s:a", "s:b", "s:c"])
        h.model.syncRow(from: KeyInfo(name: h.key("s:a"), type: .string, ttl: 5))
        #expect(names() == ["s:a", "s:b", "s:c"])
        #expect(h.model.displayedKeys.first?.ttl == 5)

        h.model.sort = KeyListSort(field: .ttl, order: .asc)
        h.model.syncRow(from: KeyInfo(name: h.key("s:b"), type: .string, ttl: 100))
        h.model.syncRow(from: KeyInfo(name: h.key("s:c"), type: .string, ttl: 200))
        #expect(names() == ["s:a", "s:b", "s:c"])
        h.model.syncRow(from: KeyInfo(name: h.key("s:a"), type: .string, ttl: 900))
        #expect(names() == ["s:b", "s:c", "s:a"])
    }
}
