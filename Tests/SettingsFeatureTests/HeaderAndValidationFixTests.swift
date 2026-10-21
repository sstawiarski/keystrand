import Foundation
import RedisCore
@testable import SettingsFeature
import TestSupport
import Testing

struct DateFormatProtectedTokenTests {
    @Test func rejectsWeekYearAndDayOfYearTokens() {
        for pattern in ["YYYY-MM-DD", "yyyy-MM-DD", "YYYY-MM-dd", "YY/MM/dd", "D MMM yyyy", "DD.MM.yyyy", "DDo YYYY"] {
            #expect(!DateFormatValidator.isSupported(pattern), "\(pattern)")
            #expect(DateFormatValidator.error(for: pattern) == DateFormatValidator.unsupportedMessage, "\(pattern)")
            #expect(!DateFormatValidator.canSave(pattern), "\(pattern)")
        }
    }

    @Test func acceptsLookalikesDateFnsAllows() {
        for pattern in ["yyyy-MM-dd", "yyyy-MM-dd HH:mm:ss", "Do MMM yyyy", "do MMMM yyyy", "'YYYY-DD' yyyy",
                        "yyyy 'D' dd"] {
            #expect(DateFormatValidator.isSupported(pattern), "\(pattern)")
            #expect(DateFormatValidator.error(for: pattern) == nil, "\(pattern)")
        }
    }

    @Test func previewOfRejectedPatternIsInvalid() throws {
        let utc = try #require(TimeZone(identifier: "UTC"))
        #expect(DateFormatValidator.preview("YYYY-MM-DD", timeZone: utc) == DateFormatValidator.invalidPreview)
    }
}

struct ShortcutBindingTests {
    static let menuBindings: [String: String] = [
        "Add database": "⌘N",
        "Import connections": "⇧⌘I",
        "Show Redis databases": "⌘0",
        "Keyboard shortcuts": "⌘/",
        "Browser": "⌘1",
        "Workbench": "⌘2",
        "Vector Search": "⌘3",
        "Database Analysis": "⌘4",
        "Slow Log": "⌘5",
        "Cluster Details": "⌘6",
        "Pub/Sub": "⌘7",
        "Show or hide the sidebar": "⌃⌘S",
        "Show or hide the inspector": "⌥⌘I",
        "Command Helper": "⇧⌘H",
        "Show or hide the bottom panel": "⇧⌘Y",
        "Show or hide the CLI": "⌃`",
        "Show or hide the Profiler": "⇧⌘P",
        "Refresh": "⌘R",
        "Switch database": "⌘O",
        "Edit database": "⌥⌘E",
        "Reconnect": "⇧⌘R",
        "New key": "⇧⌘N",
        "View options": "⌘J",
        "Copy key name": "⌥⌘C",
        "Run commands": "⌘↩",
    ]

    @Test func catalogMatchesMenuBindings() {
        let items = ShortcutCatalog.groups.flatMap(\.items)
        for (description, keys) in Self.menuBindings {
            let item = items.first { $0.description == description }
            #expect(item?.keys == keys, "\(description)")
        }
    }

    @Test func groupsFollowTheDesignOrder() {
        #expect(ShortcutCatalog.groups.map(\.title) == ["Application", "Database Window", "Browser", "Vector Search",
                                                        "Workbench", "CLI"])
    }

    @Test func listsNoRemovedShortcuts() {
        let items = ShortcutCatalog.groups.flatMap(\.items)
        #expect(!items.contains { $0.description == "Open a new window" })
        #expect(!items.contains { $0.description.contains("Insights") })
        #expect(!items.contains { $0.keys.contains("...") })
    }
}

@MainActor
struct OverviewFailedStateTests {
    @Test func failedConnectionShowsErrorInsteadOfSpinner() async {
        let services = RedisTestServer.makeServices()
        let config = DatabaseConfig(name: "Unreachable", host: "127.0.0.1", port: 1, timeoutMs: 1_000,
                                    connectionType: .standalone)
        let session = DatabaseSession(config: config, services: services)
        let model = OverviewBarViewModel(session: session)
        #expect(!model.isWaitingForFirstSample)
        await session.connect()
        guard case .failed(let error) = session.state else {
            Issue.record("expected a failed connection, got \(session.state)")
            return
        }
        #expect(!model.isWaitingForFirstSample)
        #expect(model.errorMessage == error.message)
        #expect(model.metrics.isEmpty)
    }

    @Test func connectedWithoutSampleShowsSpinner() {
        let model = OverviewBarViewModel(session: RedisTestServer.mockSession())
        #expect(model.isWaitingForFirstSample)
        #expect(model.errorMessage == nil)
    }
}

struct ProductionHeuristicTests {
    @Test func keyCountSignalOnlyAboveThreshold() {
        func signal(_ keys: Int?) -> Bool {
            ProductionHeuristic.signals(host: nil, tls: false, connectionKind: .standalone, username: nil,
                                        hasPassword: false, totalKeys: keys).hasKeyCountSignal
        }

        #expect(!signal(ProductionHeuristic.keyCountThreshold))
        #expect(signal(ProductionHeuristic.keyCountThreshold + 1))
        #expect(!signal(nil))
    }

    @Test func localHostsAreNotRemote() {
        func remote(_ host: String) -> Bool {
            ProductionHeuristic.signals(host: host, tls: false, connectionKind: .standalone, username: nil,
                                        hasPassword: false, totalKeys: nil).isRemoteHost
        }

        #expect(!remote("localhost"))
        #expect(!remote("127.0.0.1"))
        #expect(!remote(" LOCALHOST "))
        #expect(!remote("::1"))
        #expect(remote("redis.prod.example.com"))
    }

    @Test func requiresKeyCountAndAConnectionSignal() {
        let many = ProductionHeuristic.keyCountThreshold + 1

        func looks(host: String = "localhost", tls: Bool = false, kind: ConnectionKind = .standalone,
                   username: String? = nil, password: Bool = false, keys: Int = many) -> Bool {
            ProductionHeuristic.looksLikeProduction(ProductionHeuristic.signals(
                host: host, tls: tls, connectionKind: kind, username: username, hasPassword: password, totalKeys: keys))
        }

        #expect(!looks())
        #expect(!looks(host: "redis.prod.example.com", tls: true, keys: 1))
        #expect(looks(host: "redis.prod.example.com"))
        #expect(looks(tls: true))
        #expect(looks(kind: .cluster))
        #expect(looks(username: "default"))
        #expect(looks(password: true))
        #expect(!looks(username: ""))
    }
}

@MainActor
struct ProductionPromptModelTests {
    static func info(keys: Int) -> String {
        "# Server\r\nredis_version:7.4.1\r\n# Keyspace\r\ndb0:keys=\(keys),expires=0,avg_ttl=0\r\n"
    }

    static func makeSession(keys: Int, host: String = "redis.prod.example.com", environment: DatabaseEnvironment = .unspecified,
                            connectionType: ConnectionType = .standalone, password: String? = nil,
                            save: Bool = true) async throws -> DatabaseSession {
        let client = MockRedisClient(responses: ["INFO": .bulk(info(keys: keys)), "CONFIG": .bulkArray(["io-threads", "1"])])
        let config = DatabaseConfig(name: "Prod?", host: host, port: 6380, password: password,
                                    connectionType: connectionType, environment: environment)
        let session = RedisTestServer.mockSession(client, config: config)
        if save { try await session.services.databaseStore.create(config) }
        await session.refreshOverview()
        return session
    }

    @Test func opensForLargeRemoteUnclassifiedDatabase() async throws {
        let session = try await Self.makeSession(keys: 20_000)
        let prompt = ProductionPromptModel(session: session)
        await prompt.evaluate()
        #expect(prompt.isOpen)
    }

    @Test func staysClosedForSmallOrLocalOrClassifiedDatabases() async throws {
        let small = ProductionPromptModel(session: try await Self.makeSession(keys: 50))
        await small.evaluate()
        #expect(!small.isOpen)

        let local = ProductionPromptModel(session: try await Self.makeSession(keys: 20_000, host: "localhost"))
        await local.evaluate()
        #expect(!local.isOpen)

        let classified = ProductionPromptModel(session: try await Self.makeSession(keys: 20_000, environment: .development))
        await classified.evaluate()
        #expect(!classified.isOpen)

        let unsaved = ProductionPromptModel(session: try await Self.makeSession(keys: 20_000, save: false))
        await unsaved.evaluate()
        #expect(!unsaved.isOpen)
    }

    @Test func opensForSentinelDatabases() async throws {
        let session = try await Self.makeSession(keys: 20_000, host: "localhost", connectionType: .sentinel)
        let prompt = ProductionPromptModel(session: session)
        await prompt.evaluate()
        #expect(prompt.isOpen)
    }

    @Test func opensEvenWhenAnotherDatabaseIsClassified() async throws {
        let session = try await Self.makeSession(keys: 20_000)
        try await session.services.databaseStore.create(DatabaseConfig(name: "Other", environment: .production))
        let prompt = ProductionPromptModel(session: session)
        await prompt.evaluate()
        #expect(prompt.isOpen)
    }

    @Test func savedPasswordCountsAsAuthOnLocalHost() async throws {
        let session = try await Self.makeSession(keys: 20_000, host: "127.0.0.1", password: "secret")
        let prompt = ProductionPromptModel(session: session)
        await prompt.evaluate()
        #expect(prompt.isOpen)
    }

    @Test func notNowPersistsAndHides() async throws {
        let session = try await Self.makeSession(keys: 20_000)
        let prompt = ProductionPromptModel(session: session)
        await prompt.evaluate()
        prompt.notNow()
        #expect(!prompt.isOpen)
        #expect(session.services.settings.ui.prodModeCtaActioned)
        let again = ProductionPromptModel(session: session)
        await again.evaluate()
        #expect(!again.isOpen)
    }

    @Test func takeMeToSettingsOpensEditSheetFocusedOnEnvironment() async throws {
        let session = try await Self.makeSession(keys: 20_000)
        var requested: Bool?
        session.navigator.onEditDatabase = { requested = $0 }
        let prompt = ProductionPromptModel(session: session)
        await prompt.evaluate()
        prompt.openDatabaseSettings()
        #expect(requested == true)
        #expect(!prompt.isOpen)
        #expect(session.services.settings.ui.prodModeCtaActioned)
    }

    @Test func closingWithoutChoiceHidesOnlyForThisWindow() async throws {
        let session = try await Self.makeSession(keys: 20_000)
        let prompt = ProductionPromptModel(session: session)
        await prompt.evaluate()
        prompt.close()
        await prompt.evaluate()
        #expect(!prompt.isOpen)
        #expect(!session.services.settings.ui.prodModeCtaActioned)
    }
}

@MainActor
struct DatabaseInfoHeaderTests {
    @Test func editDatabaseDismissesAndOpensEditSheet() {
        let session = RedisTestServer.mockSession()
        var requested: Bool?
        session.navigator.onEditDatabase = { requested = $0 }
        var dismissed = false
        DatabaseInfoViewModel(session: session).editDatabase { dismissed = true }
        #expect(dismissed)
        #expect(requested == false)
    }

    @Test func showsDetectedHostingProvider() {
        var config = DatabaseConfig(name: "Cloud")
        config.provider = .redisCloud
        let model = DatabaseInfoViewModel(session: RedisTestServer.mockSession(config: config))
        #expect(model.details.server.first { $0.label == "Hosting provider" }?.value == "Redis Cloud")
    }

    @Test func hidesUnknownProvider() {
        var config = DatabaseConfig(name: "Mystery")
        config.provider = .unknown
        let model = DatabaseInfoViewModel(session: RedisTestServer.mockSession(config: config))
        #expect(!model.details.server.contains { $0.label == "Hosting provider" })
        for provider in HostingProvider.allCases where provider != .unknown {
            #expect(DatabaseInfoDetails.providerName(provider) != nil)
        }
    }
}
