import Foundation
import RedisCore
@testable import SettingsFeature
import TestSupport
import Testing

@MainActor
struct OverviewMockTests {
    static let info = """
    # Server\r
    redis_version:7.4.1\r
    uptime_in_seconds:100\r
    # Clients\r
    connected_clients:2\r
    # Memory\r
    used_memory:2048\r
    # Stats\r
    instantaneous_ops_per_sec:7\r
    instantaneous_input_kbps:1.5\r
    instantaneous_output_kbps:0.5\r
    # CPU\r
    used_cpu_sys:1.0\r
    used_cpu_user:1.0\r
    # Keyspace\r
    db0:keys=3,expires=0,avg_ttl=0\r

    """

    @Test func refreshFormatsSessionOverview() async {
        let client = MockRedisClient(responses: ["INFO": .bulk(Self.info), "CONFIG": .bulkArray(["io-threads", "1"])])
        let session = RedisTestServer.mockSession(client)
        let model = OverviewBarViewModel(session: session)
        #expect(model.metrics.isEmpty)
        #expect(model.isWaitingForFirstSample)

        await model.refresh()
        #expect(model.lastRefresh != nil)
        #expect(model.errorMessage == nil)
        #expect(model.version == "7.4.1")
        let kinds = model.metrics.map(\.kind)
        #expect(kinds == [.cpu, .commands, .memory, .keys, .clients])
        #expect(model.metrics.first?.isLoading == true)
        #expect(model.metrics.first { $0.kind == .keys }?.value == "3")
        #expect(model.metrics.first { $0.kind == .memory }?.value == "2 KB")
        #expect(model.metrics.first { $0.kind == .commands }?.details[1].value == "1.5 kb/s")
    }

    @Test func transportErrorSurfacesAsError() async {
        let client = MockRedisClient()
        await client.setTransportError(.notConnected)
        let session = RedisTestServer.mockSession(client)
        let model = OverviewBarViewModel(session: session)
        await model.refresh()
        #expect(model.errorMessage != nil)
        #expect(model.metrics.isEmpty)
        #expect(!model.isWaitingForFirstSample)
    }

    @Test func errorClearsOnNextSuccess() async {
        let client = MockRedisClient(responses: ["INFO": .bulk(Self.info)])
        await client.setTransportError(.notConnected)
        let session = RedisTestServer.mockSession(client)
        let model = OverviewBarViewModel(session: session)
        await model.refresh()
        #expect(model.errorMessage != nil)
        await client.setTransportError(nil)
        await model.refresh()
        #expect(model.errorMessage == nil)
        #expect(!model.metrics.isEmpty)
    }

    @Test func barTakesOverPolling() {
        let session = RedisTestServer.mockSession()
        let model = OverviewBarViewModel(session: session)
        model.barDidAppear()
        #expect(session.overviewRefreshInterval == OverviewBarViewModel.dormantPollingInterval)
        model.barDidDisappear()
        #expect(session.overviewRefreshInterval == 5)
    }

    @Test func autoRefreshSkipsTicksWhileWindowHidden() async {
        let client = MockRedisClient(responses: ["INFO": .bulk(Self.info)])
        let session = RedisTestServer.mockSession(client)
        let model = OverviewBarViewModel(session: session)

        await model.autoRefresh(isWindowVisible: false)
        await model.autoRefresh(isWindowVisible: false)
        #expect(await client.executedCommandStrings.filter { $0.hasPrefix("INFO") }.isEmpty)
        #expect(model.lastRefresh == nil)
        #expect(model.missedTickWhileHidden)

        await model.windowBecameVisible()
        #expect(await client.executedCommandStrings.filter { $0.hasPrefix("INFO") }.count == 1)
        #expect(!model.missedTickWhileHidden)

        await model.windowBecameVisible()
        #expect(await client.executedCommandStrings.filter { $0.hasPrefix("INFO") }.count == 1)

        await model.autoRefresh(isWindowVisible: true)
        #expect(await client.executedCommandStrings.filter { $0.hasPrefix("INFO") }.count == 2)
    }

    @Test func windowVisibilityRule() {
        #expect(WindowVisibility.isVisible(nil))
        #expect(WindowVisibility.isVisible(isOnScreen: true, isMiniaturized: false, isOccluded: false))
        #expect(!WindowVisibility.isVisible(isOnScreen: true, isMiniaturized: true, isOccluded: false))
        #expect(!WindowVisibility.isVisible(isOnScreen: true, isMiniaturized: false, isOccluded: true))
        #expect(!WindowVisibility.isVisible(isOnScreen: false, isMiniaturized: false, isOccluded: false))

        let visibility = WindowVisibility()
        var calls = 0
        visibility.onBecameVisible = { calls += 1 }
        visibility.windowStateChanged()
        #expect(calls == 1)
    }

    @Test func connectionTypeText() {
        let session = RedisTestServer.mockSession()
        let model = OverviewBarViewModel(session: session)
        #expect(model.connectionTypeText == "Standalone")
    }

    @Test func databaseInfoErrorIsInline() async {
        let client = MockRedisClient()
        await client.setTransportError(.notConnected)
        let session = RedisTestServer.mockSession(client, config: DatabaseConfig(name: "Mocked", host: "10.0.0.1", port: 6000))
        let model = DatabaseInfoViewModel(session: session)
        #expect(model.details.name == "Mocked")
        #expect(model.details.hostPort == "10.0.0.1:6000")
        await model.load()
        #expect(model.errorMessage != nil)
        #expect(!model.hasLoaded)
        #expect(!model.isLoading)
    }

    @Test func databaseInfoFromMockServer() async {
        let client = MockRedisClient(responses: [
            "INFO": .bulk(Self.info),
            "CONFIG GET databases": .bulkArray(["databases", "16"]),
            "MODULE LIST": .array([.array([.bulk("name"), .bulk("search"), .bulk("ver"), .integer(21_012)])]),
        ])
        let session = RedisTestServer.mockSession(client)
        let model = DatabaseInfoViewModel(session: session)
        await model.load()
        #expect(model.errorMessage == nil)
        #expect(model.details.version == "7.4.1")
        #expect(model.details.databaseCount == 16)
        #expect(model.details.modules.map(\.text) == ["Redis Search v. 2.10.12"])
        #expect(model.details.keyspace.map(\.keys) == [3])
    }

    @Test func databaseInfoDecodesValkeyModuleVersions() async {
        func module(_ name: String, _ version: Int) -> RESPValue {
            .array([.bulk("name"), .bulk(name), .bulk("ver"), .integer(Int64(version))])
        }

        let client = MockRedisClient(responses: [
            "INFO": .bulk(ValkeyFixtures.serverInfo),
            "CONFIG GET databases": .bulkArray(["databases", "16"]),
            "MODULE LIST": .array([module("json", 10_003), module("bf", 10_001), module("search", 66_049)]),
        ])
        let session = RedisTestServer.mockSession(client)
        let model = DatabaseInfoViewModel(session: session)
        await model.load()
        #expect(model.details.version == "9.1.2")
        #expect(model.details.versionLabel == "Valkey Version")
        #expect(model.details.modules.map(\.text) == ["JSON v. 1.0.3", "Probabilistic v. 1.0.1", "Valkey Search v. 1.2.1"])
    }
}

@MainActor
@Suite(.serialized)
struct LiveOverviewTests {
    @Test(.tags(.live), RedisTestServer.live(.valkey)) func valkeyShowsItsOwnVersion() async throws {
        let session = try await RedisTestServer.liveSession(db: RedisTestServer.DB.settings, name: "Valkey Live", endpoint: RedisTestServer.valkey)
        let overview = OverviewBarViewModel(session: session)
        await overview.refresh()
        let parts = OverviewSummary.parts(overview: session.overview, version: overview.version,
                                          flavor: session.serverFlavor, dbIndex: session.effectiveDB)
        let versionText = try #require(parts.first { $0.kind == .version }?.text)
        #expect(versionText.hasPrefix("Valkey "))
        #expect(versionText != "Valkey 7.2.4")

        let info = DatabaseInfoViewModel(session: session)
        await info.load()
        #expect(info.details.versionLabel == "Valkey Version")
        #expect(info.details.version == session.serverVersion)
        if let search = info.details.modules.first(where: { $0.name == "Valkey Search" }) {
            let major = search.version.flatMap(RedisVersion.init)?.components.first ?? .max
            #expect(major < 6)
        }

        await session.close()
    }

    @Test(.tags(.live), RedisTestServer.live(.redis)) func overviewCountsSeededKeys() async throws {
        let connection = try await RedisTestServer.freshConnection(db: RedisTestServer.DB.settings)
        let prefix = RedisTestServer.uniquePrefix("settings")
        try await RedisTestServer.seedStrings(connection, prefix: prefix, count: 250)
        await connection.close()

        let session = try await RedisTestServer.liveSession(db: RedisTestServer.DB.settings)
        let model = OverviewBarViewModel(session: session)
        await model.refresh()
        #expect(model.errorMessage == nil)
        let overview = try #require(session.overview)
        #expect((overview.totalKeys ?? 0) >= 250)
        if let perDb = overview.totalKeysPerDb?["db\(RedisTestServer.DB.settings)"] {
            #expect(perDb == 250)
        }

        #expect(overview.usedMemory != nil)
        #expect(overview.version != nil)
        #expect(model.metrics.contains { $0.kind == .keys })
        #expect(model.metrics.first { $0.kind == .cpu }?.isLoading == true)

        try await Task.sleep(for: .milliseconds(1100))
        await model.refresh()
        #expect(model.metrics.first { $0.kind == .cpu }?.isLoading == false)
        await session.close()
    }

    @Test(.tags(.live), RedisTestServer.live(.redis, modules: .search)) func databaseInfoLoadsKeyspaceAndModules() async throws {
        let connection = try await RedisTestServer.freshConnection(db: RedisTestServer.DB.settings)
        let prefix = RedisTestServer.uniquePrefix("settings-info")
        try await RedisTestServer.seedStrings(connection, prefix: prefix, count: 12)
        _ = try await connection.execute(["SET", .data(Data([0xFF, 0x00, 0xFE])), .data(Data([0x01, 0x02]))])
        await connection.close()

        let session = try await RedisTestServer.liveSession(db: RedisTestServer.DB.settings, name: "Settings Live")
        let model = DatabaseInfoViewModel(session: session)
        await model.load()
        #expect(model.errorMessage == nil)
        #expect(model.hasLoaded)
        let details = model.details
        #expect(details.name == "Settings Live")
        #expect(details.hostPort == "127.0.0.1:6390")
        #expect(details.version != nil)
        #expect(details.databaseCount >= 14)
        #expect(details.showsLogicalDatabasesHint)
        let current = try #require(details.keyspace.first { $0.db == RedisTestServer.DB.settings })
        #expect(current.isCurrent)
        #expect(current.keys == 13)
        #expect(details.modules.contains { $0.name == "Redis Search" })
        #expect(details.server.contains { $0.label == "Uptime" })
        #expect(details.memory.contains { $0.label == "Used memory peak" })
        await session.close()
    }

    @Test(.tags(.live), RedisTestServer.live(.redis)) func overviewFollowsLogicalDatabaseSwitch() async throws {
        try await RedisTestServer.flush(db: RedisTestServer.DB.settings)
        let session = try await RedisTestServer.liveSession(db: 0)
        let model = OverviewBarViewModel(session: session)
        try await session.select(db: RedisTestServer.DB.settings)
        await model.refresh()
        let overview = try #require(session.overview)
        if let total = overview.totalKeys, total > 0 {
            #expect(overview.totalKeysPerDb?["db\(RedisTestServer.DB.settings)"] == 0)
        }

        #expect(model.session.dbIndex == RedisTestServer.DB.settings)
        await session.close()
    }
}
