import Foundation
import RedisCore
import TestSupport
import Testing

/// Every JSON store reads its unversioned layout, writes `schemaVersion`, and backs up a newer or damaged file.
struct SchemaVersionTests {
    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func json<T: Encodable>(_ value: T) throws -> String {
        try #require(String(data: JSONFile.makeEncoder().encode(value), encoding: .utf8))
    }

    private func object(at url: URL) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    /// Backup files beside `url` whose name starts with `<name>.<label>-`.
    private func backups(of url: URL, label: String) throws -> [String] {
        let prefix = url.deletingPathExtension().lastPathComponent + ".\(label)-"
        return try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
            .filter { $0.hasPrefix(prefix) }
    }

    // MARK: - QueryLibraryStore

    private func query(_ id: DatabaseID, _ name: String) -> QueryLibraryItem {
        QueryLibraryItem(databaseId: id, indexName: "idx", name: name, query: "*")
    }

    @Test func queryLibraryReadsTheLegacyArrayAndWritesTheVersionedLayout() async throws {
        let paths = AppPaths.temporary()
        let id = DatabaseID()
        try write(json([query(id, "Old")]), to: paths.queryLibraryFile)
        let store = QueryLibraryStore(paths: paths)
        #expect(await store.list(databaseID: id).map(\.name) == ["Old"])
        try await store.create(query(id, "New"))

        let file = try object(at: paths.queryLibraryFile)
        #expect(file["schemaVersion"] as? Int == 1)
        #expect((file["items"] as? [Any])?.count == 2)
        #expect(await QueryLibraryStore(paths: paths).list(databaseID: id).map(\.name) == ["Old", "New"])
        #expect(try backups(of: paths.queryLibraryFile, label: "damaged").isEmpty)
    }

    @Test func queryLibraryReadsTheCurrentLayout() async throws {
        let paths = AppPaths.temporary()
        let id = DatabaseID()
        try write(#"{"schemaVersion": 1, "items": \#(json([query(id, "Saved")]))}"#, to: paths.queryLibraryFile)
        #expect(await QueryLibraryStore(paths: paths).list(databaseID: id).map(\.name) == ["Saved"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: paths.root.path) == ["QueryLibrary.json"])
    }

    @Test func queryLibraryFromANewerVersionIsBackedUpAndStillLoads() async throws {
        let paths = AppPaths.temporary()
        let id = DatabaseID()
        try write(#"{"schemaVersion": 7, "items": \#(json([query(id, "Future")])), "extra": true}"#,
                  to: paths.queryLibraryFile)
        let store = QueryLibraryStore(paths: paths)
        #expect(await store.list(databaseID: id).map(\.name) == ["Future"])
        #expect(try backups(of: paths.queryLibraryFile, label: "v7").count == 1)
        try await store.create(query(id, "Now"))
        #expect(try object(at: paths.queryLibraryFile)["schemaVersion"] as? Int == 1)
    }

    @Test func queryLibraryWithDroppedItemsIsBackedUp() async throws {
        let paths = AppPaths.temporary()
        let id = DatabaseID()
        try write(#"{"schemaVersion": 1, "items": [\#(json(query(id, "Kept"))), {"bad": 1}]}"#,
                  to: paths.queryLibraryFile)
        #expect(await QueryLibraryStore(paths: paths).list(databaseID: id).map(\.name) == ["Kept"])
        #expect(try backups(of: paths.queryLibraryFile, label: "damaged").count == 1)
    }

    // MARK: - CommandHistoryStore

    private func execution(_ id: DatabaseID, _ command: String,
                           type: CommandExecutionType = .workbench) -> CommandExecution {
        CommandExecution(databaseId: id, command: command, mode: .ascii, type: type)
    }

    @Test func historyReadsTheLegacyArrayAndWritesTheVersionedLayout() async throws {
        let paths = AppPaths.temporary()
        let id = DatabaseID()
        let url = paths.commandHistoryFile(for: id, type: .search)
        try write(json([execution(id, "FT.SEARCH old *", type: .search)]), to: url)
        let store = CommandHistoryStore(paths: paths)
        #expect(await store.list(databaseID: id, type: .search).map(\.command) == ["FT.SEARCH old *"])
        try await store.add([execution(id, "FT.SEARCH new *", type: .search)])

        let file = try object(at: url)
        #expect(file["schemaVersion"] as? Int == 1)
        #expect((file["items"] as? [Any])?.count == 2)
        let reloaded = await CommandHistoryStore(paths: paths).list(databaseID: id, type: .search)
        #expect(reloaded.map(\.command) == ["FT.SEARCH new *", "FT.SEARCH old *"])
        #expect(try backups(of: url, label: "damaged").isEmpty)
    }

    @Test func historyReadsTheCurrentLayout() async throws {
        let paths = AppPaths.temporary()
        let id = DatabaseID()
        let url = paths.commandHistoryFile(for: id, type: .workbench)
        try write(#"{"schemaVersion": 1, "items": \#(json([execution(id, "PING")]))}"#, to: url)
        #expect(await CommandHistoryStore(paths: paths).list(databaseID: id, type: .workbench).map(\.command) == ["PING"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: paths.workbenchDirectory.path).count == 1)
    }

    @Test func historyFromANewerVersionIsBackedUpAndStillLoads() async throws {
        let paths = AppPaths.temporary()
        let id = DatabaseID()
        let url = paths.commandHistoryFile(for: id, type: .workbench)
        try write(#"{"schemaVersion": 3, "items": \#(json([execution(id, "PING")]))}"#, to: url)
        let store = CommandHistoryStore(paths: paths)
        #expect(await store.list(databaseID: id, type: .workbench).map(\.command) == ["PING"])
        #expect(try backups(of: url, label: "v3").count == 1)
        try await store.add([execution(id, "INFO")])
        #expect(try object(at: url)["schemaVersion"] as? Int == 1)
    }

    @Test func damagedHistoryIsBackedUp() async throws {
        let paths = AppPaths.temporary()
        let id = DatabaseID()
        let url = paths.commandHistoryFile(for: id, type: .workbench)
        try write("{ not json", to: url)
        let store = CommandHistoryStore(paths: paths)
        #expect(await store.list(databaseID: id, type: .workbench).isEmpty)
        #expect(try backups(of: url, label: "damaged").count == 1)
        try await store.add([execution(id, "PING")])
        #expect(await CommandHistoryStore(paths: paths).list(databaseID: id, type: .workbench).count == 1)
    }

    // MARK: - DatabaseSettingsStore

    @Test func databaseSettingsReadTheUnversionedObjectAndWriteTheVersion() async throws {
        let paths = AppPaths.temporary()
        let id = DatabaseID()
        let url = paths.databaseSettingsFile(for: id)
        try write(#"{"treeViewDelimiters": ["-"]}"#, to: url)
        let store = DatabaseSettingsStore(paths: paths)
        #expect(await store.settings(for: id).treeViewDelimiters == ["-"])
        try await store.update(id) { $0.treeViewDelimiterPrefixLength = 3 }

        let file = try object(at: url)
        #expect(file["schemaVersion"] as? Int == 1)
        #expect(file["treeViewDelimiters"] as? [String] == ["-"])
        let reloaded = await DatabaseSettingsStore(paths: paths).settings(for: id)
        #expect(reloaded.treeViewDelimiters == ["-"])
        #expect(reloaded.treeViewDelimiterPrefixLength == 3)
        #expect(try backups(of: url, label: "damaged").isEmpty)
    }

    @Test func databaseSettingsReadTheCurrentLayout() async throws {
        let paths = AppPaths.temporary()
        let id = DatabaseID()
        let url = paths.databaseSettingsFile(for: id)
        try write(#"{"schemaVersion": 1, "treeViewDelimiters": [":", "/"]}"#, to: url)
        #expect(await DatabaseSettingsStore(paths: paths).settings(for: id).treeViewDelimiters == [":", "/"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: paths.databaseSettingsDirectory.path).count == 1)
    }

    @Test func databaseSettingsFromANewerVersionAreBackedUpAndStillLoad() async throws {
        let paths = AppPaths.temporary()
        let id = DatabaseID()
        let url = paths.databaseSettingsFile(for: id)
        try write(#"{"schemaVersion": 2, "treeViewDelimiters": ["|"], "futureField": 1}"#, to: url)
        let store = DatabaseSettingsStore(paths: paths)
        #expect(await store.settings(for: id).treeViewDelimiters == ["|"])
        #expect(try backups(of: url, label: "v2").count == 1)
        try await store.update(id) { $0.showHiddenRecommendations = true }
        #expect(try object(at: url)["schemaVersion"] as? Int == 1)
    }

    @Test func damagedDatabaseSettingsAreBackedUpAndReset() async throws {
        let paths = AppPaths.temporary()
        let id = DatabaseID()
        let url = paths.databaseSettingsFile(for: id)
        try write(#"["not", "an", "object"]"#, to: url)
        #expect(await DatabaseSettingsStore(paths: paths).settings(for: id) == DatabaseSettings())
        #expect(try backups(of: url, label: "damaged").count == 1)
    }

    // MARK: - SettingsStore

    @MainActor
    @Test func settingsReadTheUnversionedFileAndWriteTheVersion() throws {
        let paths = AppPaths.temporary()
        try write(#"{"app": {"theme": "dark"}, "browser": {"viewType": "list"}}"#, to: paths.settingsFile)
        let store = SettingsStore(paths: paths)
        #expect(store.app.theme == .dark)
        #expect(store.browser.viewType == .list)
        store.ui.pubSubPageSize = 50

        let file = try object(at: paths.settingsFile)
        #expect(file["schemaVersion"] as? Int == 1)
        #expect(SettingsStore(paths: paths).app.theme == .dark)
        #expect(SettingsStore(paths: paths).ui.pubSubPageSize == 50)
        #expect(try backups(of: paths.settingsFile, label: "damaged").isEmpty)
    }

    @MainActor
    @Test func settingsReadTheCurrentLayout() throws {
        let paths = AppPaths.temporary()
        try write(#"{"schemaVersion": 1, "app": {"theme": "light"}}"#, to: paths.settingsFile)
        #expect(SettingsStore(paths: paths).app.theme == .light)
        #expect(try FileManager.default.contentsOfDirectory(atPath: paths.root.path) == ["settings.json"])
    }

    @MainActor
    @Test func settingsFromANewerVersionAreBackedUpAndStillLoad() throws {
        let paths = AppPaths.temporary()
        try write(#"{"schemaVersion": 4, "app": {"theme": "light"}, "future": {}}"#, to: paths.settingsFile)
        let store = SettingsStore(paths: paths)
        #expect(store.app.theme == .light)
        #expect(try backups(of: paths.settingsFile, label: "v4").count == 1)
        store.app.holdToQuit = false
        #expect(try object(at: paths.settingsFile)["schemaVersion"] as? Int == 1)
    }

    @MainActor
    @Test func damagedSettingsAreBackedUp() throws {
        let paths = AppPaths.temporary()
        try write("{ not json", to: paths.settingsFile)
        #expect(SettingsStore(paths: paths).app == AppSettings())
        #expect(try backups(of: paths.settingsFile, label: "damaged").count == 1)

        let partial = AppPaths.temporary()
        try write(#"{"app": {"theme": "dark"}, "ui": "nope"}"#, to: partial.settingsFile)
        let store = SettingsStore(paths: partial)
        #expect(store.app.theme == .dark)
        #expect(store.ui == UIPreferences())
        #expect(try backups(of: partial.settingsFile, label: "damaged").count == 1)
    }
}
