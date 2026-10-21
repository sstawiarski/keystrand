import Foundation
@testable import ConnectionsFeature
import RedisCore
import TestSupport
import Testing

/// View-model flows against the live test server (127.0.0.1:6390, DB 12). No port other than 6390, the Valkey
/// server on 6392, and a refused local port is ever contacted.
@MainActor
@Suite(.tags(.live), RedisTestServer.live(.redis), .serialized)
struct LiveFlowTests {
    private let db = RedisTestServer.DB.connections
    private let liveURL = "redis://127.0.0.1:\(RedisTestServer.port)/\(RedisTestServer.DB.connections)"
    /// Nothing listens here, so connecting is refused immediately.
    private let closedPort = 1

    private func waitUntil(_ condition: @MainActor () -> Bool, timeout: Duration = .seconds(5)) async {
        let deadline = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    // MARK: - Add Database start screen

    @Test(RedisTestServer.needs(.json)) func addFromURLDetectsStandaloneAndSaves() async throws {
        let services = RedisTestServer.makeServices()
        let flow = AddDatabaseFlowModel(services: services)
        flow.urlText = liveURL
        #expect(flow.urlDisabledReason == nil)
        let saved = try #require(await flow.addFromURL())
        #expect(saved.connectionType == .standalone)
        #expect(saved.db == db)
        #expect(saved.name == "127.0.0.1:\(RedisTestServer.port)")
        #expect(saved.isNew)
        #expect(saved.modules.contains { $0.name == "ReJSON" })
        let stored = try await services.databaseStore.list()
        #expect(stored.map(\.id) == [saved.id])
        #expect(services.toasts.toasts.isEmpty)
    }

    @Test func testURLSucceedsAndFailsWithClassifiedError() async throws {
        let services = RedisTestServer.makeServices()
        let flow = AddDatabaseFlowModel(services: services)
        flow.urlText = liveURL
        await flow.testURL()
        #expect(flow.testSucceeded)
        #expect(flow.error == nil)

        flow.urlText = "127.0.0.1:\(closedPort)"
        await flow.testURL()
        #expect(!flow.testSucceeded)
        #expect(flow.error?.code == .unavailable)
        #expect(flow.error?.title == "Connection unavailable")
        #expect(try await services.databaseStore.list().isEmpty)
    }

    @Test func invalidURLDisablesActions() async {
        let flow = AddDatabaseFlowModel(services: RedisTestServer.makeServices())
        flow.urlText = "ftp://nope"
        #expect(flow.urlDisabledReason == ConnectionURLParser.unsupportedMessage)
        #expect(flow.settingsDisabledReason == ConnectionURLParser.unsupportedMessage)
        #expect(await flow.addFromURL() == nil)
        flow.urlText = ""
        #expect(flow.settingsDisabledReason == nil)
        flow.urlText = liveURL
        flow.openConnectionSettings()
        #expect(flow.screen == .form)
        #expect(flow.form.port == String(RedisTestServer.port))
        #expect(flow.form.dbIndexValue == db)
        flow.backToStart()
        #expect(flow.screen == .start)
    }

    // MARK: - Connection settings form

    @Test func formTestResultClearsWhenAConnectionFieldChanges() async {
        let form = DatabaseFormModel(mode: .add, services: RedisTestServer.makeServices())
        form.name = "Tested"
        form.host = "127.0.0.1"
        form.port = String(RedisTestServer.port)
        await form.testConnection()
        #expect(form.testSucceeded)
        form.name = "Renamed"
        #expect(form.testSucceeded)
        form.host = "localhost"
        #expect(!form.testSucceeded)
    }

    @Test func formSubmitAddsThenEditsOnlyChangedFields() async throws {
        let services = RedisTestServer.makeServices()
        let form = DatabaseFormModel(mode: .add, services: services)
        form.name = "Form DB"
        form.port = String(RedisTestServer.port)
        form.username = ""
        form.selectLogicalDatabase = true
        form.dbIndex = String(db)
        form.environment = .development
        await form.testConnection()
        #expect(form.testSucceeded)
        guard case .saved(let saved) = await form.submit() else {
            Issue.record("submit failed: \(String(describing: form.error))")
            return
        }
        #expect(saved.connectionType == .standalone)
        #expect(saved.environment == .development)
        #expect(saved.version != nil)

        let listed = try #require(try await services.databaseStore.list().first)
        let edit = DatabaseFormModel(mode: .edit(listed), services: services)
        await edit.prepare()
        edit.name = "Renamed"
        edit.keyNameFormat = .hex
        guard case .saved(let updated) = await edit.submit() else {
            Issue.record("edit failed: \(String(describing: edit.error))")
            return
        }
        #expect(updated.id == saved.id)
        let stored = try await services.databaseStore.get(saved.id)
        #expect(stored.name == "Renamed")
        #expect(stored.keyNameFormat == .hex)
        #expect(stored.db == db)
        #expect(stored.connectionType == .standalone)
        #expect(try await services.databaseStore.list().count == 1)
    }

    @Test func formSubmitWithPasswordKeepsStoredSecret() async throws {
        let services = RedisTestServer.makeServices()
        var config = RedisTestServer.databaseConfig(db: db, name: "Secret DB")
        config.password = "unused-secret"
        try await services.databaseStore.create(config)
        let listed = try #require(try await services.databaseStore.list().first)
        #expect(listed.password == nil)
        let edit = DatabaseFormModel(mode: .edit(listed), services: services)
        await edit.prepare()
        #expect(edit.password.isStored)
        #expect(edit.buildDraft().password == "unused-secret")
        edit.environment = .production
        guard case .saved = await edit.submit() else {
            Issue.record("edit failed: \(String(describing: edit.error))")
            return
        }
        let stored = try await services.databaseStore.get(config.id)
        #expect(stored.password == "unused-secret")
        #expect(stored.environment == .production)
    }

    @Test func formSubmitFailureShowsConnectionError() async throws {
        let services = RedisTestServer.makeServices()
        let form = DatabaseFormModel(mode: .add, services: services)
        form.name = "Broken"
        form.port = String(closedPort)
        guard case .failed = await form.submit() else {
            Issue.record("expected failure")
            return
        }
        #expect(form.error?.code == .unavailable)
        #expect(form.error?.message.contains("127.0.0.1:\(closedPort)") == true)
        #expect(try await services.databaseStore.list().isEmpty)
    }

    @Test func cloneCreatesSecondDatabase() async throws {
        let services = RedisTestServer.makeServices()
        let original = RedisTestServer.databaseConfig(db: db, name: "Source")
        try await services.databaseStore.create(original)
        let form = DatabaseFormModel(mode: .clone(original), services: services)
        await form.prepare()
        form.name = "Copy"
        guard case .saved(let clone) = await form.submit() else {
            Issue.record("clone failed: \(String(describing: form.error))")
            return
        }
        #expect(clone.id != original.id)
        #expect(clone.isNew)
        let names = try await services.databaseStore.list().map(\.name).sorted()
        #expect(names == ["Copy", "Source"])
    }

    // MARK: - Sentinel

    @Test func sentinelDiscoveryOnPlainRedisReportsWrongTool() async {
        let services = RedisTestServer.makeServices()
        let sentinel = SentinelFlowModel(services: services)
        sentinel.port = String(RedisTestServer.port)
        await sentinel.discover()
        #expect(sentinel.stage == .form)
        #expect(sentinel.error?.message
            == "This endpoint didn't answer as a Redis Sentinel. Add it as a regular database with its host and port instead.")
    }

    @Test func sentinelRowsBuildDatabasesAndSummaries() {
        let services = RedisTestServer.makeServices()
        let model = SentinelFlowModel(services: services)
        model.host = "10.0.0.9"
        model.password = "sentinel-pw"
        let masters = [
            SentinelMasterInfo(name: "beta", host: "10.0.0.2", port: 6380, numberOfSlaves: 2),
            SentinelMasterInfo(name: "alpha", host: "10.0.0.1", port: 6379, numberOfSlaves: 1),
        ]
        model.rows = masters.enumerated().map { SentinelFlowModel.Row(id: String($0.offset + 1), master: $0.element) }
        #expect(model.addDisabledReason == "Choose at least one primary group.")
        model.rows[0].isSelected = true
        model.rows[0].alias = " "
        #expect(model.addDisabledReason?.hasPrefix("Fill in the required fields (1)") == true)
        model.rows[0].alias = "Beta DB"
        model.rows[0].db = "3"
        model.rows[0].username = "app"
        #expect(model.addDisabledReason == nil)

        let config = SentinelFlowModel.databaseConfig(for: model.rows[0], sentinel: model.sentinelDraft(), tls: TLSSettings())
        #expect(config.name == "Beta DB")
        #expect(config.host == "10.0.0.9")
        #expect(config.port == 26379)
        #expect(config.password == "sentinel-pw")
        #expect(config.db == 3)
        #expect(config.connectionType == .sentinel)
        #expect(config.sentinelMaster == SentinelMasterConfig(name: "beta", username: "app", password: nil))

        model.searchText = "alpha"
        #expect(model.filteredRows.map(\.master.name) == ["alpha"])
        model.searchText = "6380"
        #expect(model.filteredRows.map(\.master.name) == ["beta"])

        model.rows[0].result = .added(DatabaseID())
        model.rows[1].result = .failed(.unauthorized)
        #expect(model.resultRows.map(\.master.name) == ["alpha", "beta"])
        #expect(model.rows[1].isRetryable)
        #expect(model.summaryText == "Added 1 primary group. 1 failed.")
    }

    @Test func sentinelDiscoveryDisabledMessages() {
        let model = SentinelFlowModel(services: RedisTestServer.makeServices())
        model.rows = [SentinelFlowModel.Row(id: "1", master: SentinelMasterInfo(name: "alpha", host: "h", port: 6380))]
        #expect(model.addDisabledMessage == "Choose at least one primary group.")
        #expect(!model.hasUnsavedChanges)
        model.rows[0].isSelected = true
        #expect(model.addDisabledMessage == nil)
        #expect(model.hasUnsavedChanges)
        model.rows[0].alias = " "
        #expect(model.addDisabledMessage == "Enter an alias for every selected group.")
        model.rows[0].alias = "a"
        model.rows[0].db = "x"
        #expect(model.addDisabledMessage == "Enter a database index of 0 or more for every selected group.")
    }

    @Test func sentinelHostPasteDefaultsTo26379() {
        let model = SentinelFlowModel(services: RedisTestServer.makeServices())
        let old = model.host
        model.host = "redis://u:p@sentinel.local"
        #expect(model.hostChanged(from: old, to: model.host))
        #expect(model.host == "sentinel.local")
        #expect(model.port == "26379")
        #expect(model.username == "u")
        #expect(model.password == "p")
    }

    // MARK: - Home list

    @Test func listLoadsSortsSearchesAndPersistsSorting() async throws {
        let services = RedisTestServer.makeServices()
        var older = RedisTestServer.databaseConfig(db: db, name: "Older")
        older.lastConnection = Date().addingTimeInterval(-3600)
        older.tags = [DatabaseTag(key: "env", value: "prod")]
        var newer = RedisTestServer.databaseConfig(db: db, name: "Newer")
        newer.lastConnection = Date().addingTimeInterval(-60)
        let never = RedisTestServer.databaseConfig(db: db, name: "Never")
        for config in [older, never, newer] { try await services.databaseStore.create(config) }

        let model = DatabaseListViewModel(services: services)
        await model.reload()
        #expect(model.hasLoaded)
        #expect(model.visibleDatabases.map(\.name) == ["Newer", "Older", "Never"])
        model.sort(by: .name)
        #expect(services.settings.ui.homeSorting == HomeSorting(field: .name, direction: .asc))
        #expect(model.visibleDatabases.map(\.name) == ["Never", "Newer", "Older"])
        model.sort(by: .name)
        #expect(model.sorting.direction == .desc)
        model.searchText = "OLD"
        #expect(model.visibleDatabases.map(\.name) == ["Older"])
        model.searchText = ""
        model.filters = [.tag(DatabaseTag(key: "env", value: "prod"))]
        #expect(model.visibleDatabases.map(\.name) == ["Older"])
        model.searchText = "zzz"
        #expect(model.visibleDatabases.isEmpty)
        #expect(model.isNarrowed)

        model.setColumn(.tags, shown: false)
        #expect(!model.shownColumns.contains(.tags))
        #expect(services.settings.ui.homeShownColumns.contains("name"))
        for column in HomeColumn.allCases { model.setColumn(column, shown: false) }
        #expect(model.shownColumns == [.name])
    }

    @Test func emptyListShowsEmptyState() async {
        let model = DatabaseListViewModel(services: RedisTestServer.makeServices())
        #expect(!model.showsEmptyState)
        await model.reload()
        #expect(model.showsEmptyState)
        #expect(model.subtitle == "0 databases")
    }

    @Test func storeChangesReloadTheList() async throws {
        let services = RedisTestServer.makeServices()
        let model = DatabaseListViewModel(services: services)
        await model.start()
        defer { model.stop() }
        #expect(model.databases.isEmpty)
        try await services.databaseStore.create(RedisTestServer.databaseConfig(db: db, name: "Late"))
        await waitUntil { model.databases.count == 1 }
        #expect(model.databases.map(\.name) == ["Late"])
    }

    @Test(RedisTestServer.needs(.json)) func openConnectsAndRefreshesLastConnection() async throws {
        let services = RedisTestServer.makeServices()
        let config = RedisTestServer.databaseConfig(db: db, name: "Openable")
        try await services.databaseStore.create(config)
        let model = DatabaseListViewModel(services: services)
        await model.reload()
        var opened: DatabaseConfig?
        await model.open(config.id) { opened = $0 }
        let result = try #require(opened)
        #expect(result.id == config.id)
        #expect(services.sessions.existingSession(for: config.id)?.state == .connected)
        let stored = try await services.databaseStore.get(config.id)
        #expect(stored.lastConnection != nil)
        #expect(!stored.isNew)
        #expect(!stored.modules.isEmpty)
        #expect(model.connecting.isEmpty)
        await services.sessions.close(config.id)
    }

    @Test func openFailureOpensTheWindowInTheFailedState() async throws {
        let services = RedisTestServer.makeServices()
        let config = DatabaseConfig(name: "Dead", host: "127.0.0.1", port: closedPort, connectionType: .standalone)
        try await services.databaseStore.create(config)
        let model = DatabaseListViewModel(services: services)
        await model.reload()
        var opened = false
        await model.open(config.id) { _ in opened = true }
        #expect(opened)
        guard case .failed(let error)? = services.sessions.existingSession(for: config.id)?.state else {
            Issue.record("expected a failed session")
            return
        }
        #expect(error.title == "Connection unavailable")
        #expect(services.toasts.toasts.isEmpty)
        await services.sessions.close(config.id)
    }

    @Test func deleteRemovesDatabases() async throws {
        let services = RedisTestServer.makeServices()
        let configs = (1...3).map { RedisTestServer.databaseConfig(db: db, name: "Del \($0)") }
        for config in configs { try await services.databaseStore.create(config) }
        let model = DatabaseListViewModel(services: services)
        await model.reload()
        model.selection = Set(configs.prefix(2).map(\.id))
        #expect(model.actionTargets.count == 2)
        let ok = await model.delete(configs.prefix(2).map(\.id))
        #expect(ok)
        #expect(model.selection.isEmpty)
        #expect(model.databases.map(\.name) == ["Del 3"])
        _ = await model.delete([configs[2].id])
        #expect(try await services.databaseStore.list().isEmpty)
        #expect(services.toasts.toasts.isEmpty)
    }

    @Test func tagsAreSavedPerDatabase() async throws {
        let services = RedisTestServer.makeServices()
        let config = RedisTestServer.databaseConfig(db: db, name: "Tagged")
        try await services.databaseStore.create(config)
        let model = DatabaseListViewModel(services: services)
        await model.reload()
        let saved = await model.saveTags([DatabaseTag(key: "team", value: "core")], for: config.id)
        #expect(saved)
        #expect(model.database(config.id)?.tags == [DatabaseTag(key: "team", value: "core")])
        #expect(model.allTags == [DatabaseTag(key: "team", value: "core")])
        #expect(services.toasts.toasts.isEmpty)
    }

    @Test func exportHonoursPasswordToggle() async throws {
        let services = RedisTestServer.makeServices()
        var config = RedisTestServer.databaseConfig(db: db, name: "Exported")
        config.password = "top-secret"
        try await services.databaseStore.create(config)
        let model = DatabaseListViewModel(services: services)
        await model.reload()
        let withSecrets = String(decoding: try await model.exportData([config.id], includePasswords: true), as: UTF8.self)
        #expect(withSecrets.contains("top-secret"))
        #expect(withSecrets.contains("\"Exported\""))
        let without = String(decoding: try await model.exportData([config.id], includePasswords: false), as: UTF8.self)
        #expect(!without.contains("top-secret"))
        let array = try JSONSerialization.jsonObject(with: Data(without.utf8)) as? [[String: Any]]
        #expect(array?.count == 1)
    }

    // MARK: - Import

    @Test func importReportsPerItemResults() async throws {
        let services = RedisTestServer.makeServices()
        let model = ImportModel(services: services)
        #expect(!model.canSubmit)
        let json = """
            [
              {"name": "Imported", "host": "127.0.0.1", "port": \(RedisTestServer.port), "db": \(db)},
              {"host": "127.0.0.1", "port": 6400, "compressor": "BOGUS"},
              {"name": "No host"}
            ]
            """
        let encoded = Data(Data(json.utf8).base64EncodedString().utf8)
        await model.submit(data: encoded, filename: "connections.json")
        guard case .results(let result) = model.state else {
            Issue.record("unexpected state \(model.state)")
            return
        }
        #expect(result.total == 3)
        #expect(result.success.map(\.index) == [0])
        #expect(result.partial.map(\.index) == [1])
        #expect(result.fail.map(\.index) == [2])
        let stored = try await services.databaseStore.list()
        #expect(stored.count == 2)
        #expect(stored.allSatisfy { $0.isNew })
    }

    @Test func importReviewKeepsScriptsOnlyWhenChosen() async throws {
        let services = RedisTestServer.makeServices()
        let model = ImportModel(services: services)
        let json = #"[{"host": "10.1.1.1", "port": 6379, "preConnectScript": "echo hi"}, {"host": "10.1.1.2", "port": 6379}]"#
        await model.submit(data: Data(json.utf8), filename: "connections.json")
        let item = try #require(model.itemsWithScripts.first)
        #expect(model.itemsWithScripts.count == 1)
        let id = try #require(item.databaseID)
        #expect(try await services.databaseStore.get(id).preConnectScript == nil)

        await model.setKeepScripts(true, for: item)
        #expect(model.keptScripts == [item.index])
        #expect(try await services.databaseStore.get(id).preConnectScript == "echo hi")
        await model.setKeepScripts(false, for: item)
        #expect(model.keptScripts.isEmpty)
        #expect(try await services.databaseStore.get(id).preConnectScript == nil)
    }

    @Test func importOfGarbageFails() async throws {
        let model = ImportModel(services: RedisTestServer.makeServices())
        await model.submit(data: Data("{}".utf8), filename: "bad.json")
        guard case .failed(let message) = model.state else {
            Issue.record("expected failure")
            return
        }
        #expect(!message.isEmpty)
        model.retry()
        #expect(model.state == .form)
    }

    @Test func importFromFileURL() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("connections.json")
        try Data(#"[{"host":"127.0.0.1","port":6390}]"#.utf8).write(to: file)
        let services = RedisTestServer.makeServices()
        let model = ImportModel(services: services, fileURL: file)
        #expect(model.canSubmit)
        await model.submit()
        guard case .results(let result) = model.state else {
            Issue.record("unexpected state \(model.state)")
            return
        }
        #expect(result.success.count == 1)
        #expect(try await services.databaseStore.list().first?.name == "127.0.0.1:6390")
    }

    // MARK: - Auto-discovery and picker

    @Test func autoDiscoveryUsesInjectedPortsOnly() async throws {
        let discovery = LocalAutoDiscovery(portSource: FixedPortSource([RedisTestServer.port, closedPort]),
                                           probeTimeout: 1)
        let found = await discovery.discover()
        #expect(found.map(\.port) == [RedisTestServer.port])
        #expect(found.first?.connectionType == .standalone)
        #expect(found.first?.name == "127.0.0.1:\(RedisTestServer.port)")
        #expect(found.first?.provider == .localhost)
        let excluded = await discovery.discover(excluding: [RedisEndpoint(host: "127.0.0.1", port: RedisTestServer.port)])
        #expect(excluded.isEmpty)
    }

    @Test func firstRunAutoDiscoveryAddsOnceOnly() async throws {
        let services = RedisTestServer.makeServices()
        let discovery = LocalAutoDiscovery(portSource: FixedPortSource([RedisTestServer.port]), probeTimeout: 1)
        let model = DatabaseListViewModel(services: services, autoDiscovery: discovery)
        await model.reload()
        await model.runAutoDiscoveryIfNeeded()
        #expect(services.settings.ui.didRunAutoDiscovery)
        #expect(model.databases.map(\.port) == [RedisTestServer.port])
        try await services.deleteDatabases(model.databases.map(\.id))
        await model.reload()
        await model.runAutoDiscoveryIfNeeded()
        #expect(model.databases.isEmpty)
    }

    @Test func pickerSearchesAndSortsLikeHome() async throws {
        let services = RedisTestServer.makeServices()
        var a = RedisTestServer.databaseConfig(db: 0, name: "Alpha")
        a.lastConnection = Date()
        let b = RedisTestServer.databaseConfig(db: 4, name: "Bravo")
        for config in [b, a] { try await services.databaseStore.create(config) }
        let picker = DatabasePickerModel(services: services)
        await picker.load()
        #expect(picker.visibleDatabases.map(\.name) == ["Alpha", "Bravo"])
        picker.searchText = "[db4]"
        #expect(picker.visibleDatabases.map(\.name) == ["Bravo"])
        picker.searchText = "nothing"
        #expect(picker.visibleDatabases.isEmpty)
    }
}

struct LiveValkeyDiscoveryTests {
    @Test(.tags(.live), RedisTestServer.live(.valkey)) func discoverySavesTheValkeyVersionAndProvider() async throws {
        let discovery = LocalAutoDiscovery(portSource: FixedPortSource([RedisTestServer.valkey.port]), probeTimeout: 1)
        let found = try #require(await discovery.discover().first)
        #expect(found.port == RedisTestServer.valkey.port)
        #expect(found.provider == .valkey)
        let version = try #require(found.version)
        #expect(version != "7.2.4")
        #expect((RedisVersion(version)?.components.first ?? 0) >= 8)
    }
}
