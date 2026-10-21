import Foundation
import RedisCore
import Synchronization
import TestSupport
import Testing

private final class Locked<Value: Sendable>: Sendable {
    private let state: Mutex<Value>

    init(_ value: Value) {
        state = Mutex(value)
    }

    var value: Value {
        get { state.withLock { $0 } }
        set { state.withLock { $0 = newValue } }
    }
}

@MainActor
private func waitUntil(_ timeout: Duration = .seconds(5), _ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while !condition() {
        guard ContinuousClock.now < deadline else { throw RedisClientError.timeout }
        try await Task.sleep(for: .milliseconds(20))
    }
}

/// A port nothing listens on, so a connect fails at once.
private let closedPort = 1

@MainActor
private func savedSession(port: Int, services: AppServices) async throws -> (DatabaseSession, DatabaseConfig) {
    let config = DatabaseConfig(name: "Fake", host: "127.0.0.1", port: port, timeoutMs: 2_000, connectionType: .standalone)
    try await services.saveDatabase(config)
    return (try await services.sessions.session(for: config.id), config)
}

@MainActor
@Suite(.serialized)
struct SessionConnectionTests {
    @Test func editWhileConnectingDoesNotPersistThePreviousServer() async throws {
        let aclStarted = Locked(false)
        let server = try await FakeRedisServer.start { command in
            guard command.first?.uppercased() == "ACL" else { return nil }
            aclStarted.value = true
            try? await Task.sleep(for: .milliseconds(600))
            return .array([])
        }
        defer { server.stop() }
        let services = RedisTestServer.makeServices()
        var (session, config) = try await savedSession(port: server.port, services: services)

        let connecting = Task { await session.connect() }
        try await waitUntil { aclStarted.value }
        config.port = closedPort
        try await services.saveDatabase(config)
        await connecting.value

        let stored = try await services.databaseStore.get(config.id)
        #expect(stored.port == closedPort)
        #expect(stored.version == nil, "the previous server's version must not land on the edited database")
        #expect(stored.lastConnection == nil)
        #expect(session.config.lastConnection == nil)
    }

    @Test func disconnectWhileConnectingWins() async throws {
        let infoStarted = Locked(false)
        let server = try await FakeRedisServer.start { command in
            guard command == ["INFO"] else { return nil }
            infoStarted.value = true
            try? await Task.sleep(for: .milliseconds(400))
            return nil
        }
        defer { server.stop() }
        let services = RedisTestServer.makeServices()
        let (session, config) = try await savedSession(port: server.port, services: services)
        let connecting = Task { await session.connect() }
        try await waitUntil { infoStarted.value }
        await session.disconnect()
        await connecting.value
        #expect(session.state == .disconnected)
        #expect(try await services.databaseStore.get(config.id).lastConnection == nil)
    }

    @Test func switchingDatabaseReportsTheServerError() async throws {
        let server = try await FakeRedisServer.start { command in
            guard command.first?.uppercased() == "SELECT", command.last == "5" else { return nil }
            return .error(RESPError("NOPERM this user has no permissions to access one of the databases"))
        }
        defer { server.stop() }
        let services = RedisTestServer.makeServices()
        let (session, _) = try await savedSession(port: server.port, services: services)
        await session.connect()
        #expect(session.state == .connected)
        do {
            try await session.select(db: 5)
            Issue.record("expected the SELECT error")
        } catch {
            #expect(error.localizedDescription.contains("NOPERM"))
        }

        #expect(session.dbIndex == 0)
        await #expect(throws: RedisClientError.self) { try await session.select(db: -1) }
        await session.disconnect()
    }

    @Test func reconnectMakesFeaturesReload() async throws {
        let server = try await FakeRedisServer.start()
        defer { server.stop() }
        let services = RedisTestServer.makeServices()
        let (session, _) = try await savedSession(port: server.port, services: services)
        await session.connect()
        let generation = session.dbGeneration
        await session.reconnect()
        #expect(session.state == .connected)
        #expect(session.dbGeneration == generation + 1)
        await session.disconnect()
    }

    @Test func pooledContextsThatNeverBlockHaveACommandTimeout() {
        #expect(DatabaseSession.commandTimeout(for: .common) == RedisConnectionConfig.defaultCommandTimeout)
        #expect(DatabaseSession.commandTimeout(for: .background) != nil)
        #expect(DatabaseSession.commandTimeout(for: .workbench) == nil)
        #expect(DatabaseSession.commandTimeout(for: .cli) == nil)
    }

    @Test func pingGivesUpOnAStuckConnection() async throws {
        let stuck = Locked(false)
        let server = try await FakeRedisServer.start { command in
            guard command.first?.uppercased() == "PING", stuck.value else { return nil }
            try? await Task.sleep(for: .seconds(30))
            return nil
        }
        defer { server.stop() }
        let services = RedisTestServer.makeServices()
        let (session, _) = try await savedSession(port: server.port, services: services)
        await session.connect()
        try await session.ping(timeout: 1)
        stuck.value = true
        let started = ContinuousClock.now
        await #expect(throws: RedisClientError.self) { try await session.ping(timeout: 0.3) }
        #expect(ContinuousClock.now - started < .seconds(3))
        stuck.value = false
        try await session.ping(timeout: 1)
        await session.disconnect()
    }

    @Test func registryCloseWaitsForTheSessionToClose() async throws {
        let services = RedisTestServer.makeServices()
        let session = DatabaseSession(config: DatabaseConfig(name: "Closing"), services: services, client: MockRedisClient())
        services.sessions.register(session)
        let scoped = session.scopedObject(SlowClosingObject.self) { SlowClosingObject() }
        let first = Task { await services.sessions.close(session.id); return scoped.didClose }
        try await waitUntil { services.sessions.existingSession(for: session.id) == nil }
        #expect(services.sessions.sessionsIncludingClosing.contains { $0 === session })
        let second = Task { await services.sessions.close(session.id); return scoped.didClose }
        #expect(await second.value, "a second close waits for the first")
        #expect(await first.value)
        #expect(!services.sessions.sessionsIncludingClosing.contains { $0 === session })
    }
}

@MainActor
private final class SlowClosingObject: SessionScopedObject {
    private(set) var didClose = false

    func sessionWillClose() async {
        try? await Task.sleep(for: .milliseconds(300))
        didClose = true
    }
}

struct ClientPoolCancellationTests {
    @Test func invalidateCancelsAConnectInProgress() async throws {
        let server = try await FakeRedisServer.start()
        defer { server.stop() }
        let pool = ClientPool(factory: RedisClientFactory(scriptRunner: ConnectionScriptRunner(shell: "/bin/sh")))
        let descriptor = RedisClientDescriptor(
            topology: .standalone(server.endpoint),
            connection: RedisConnectionConfig(host: "127.0.0.1", port: server.port, connectTimeout: 2),
            preConnectScript: "sleep 5")
        let key = ClientKey(databaseID: DatabaseID(), context: .common)
        let pending = Task { try await pool.client(for: key, descriptor: descriptor) }
        try await Task.sleep(for: .milliseconds(300))
        let started = ContinuousClock.now
        await pool.invalidate(databaseID: key.databaseID)
        await #expect(throws: (any Error).self) { _ = try await pending.value }
        #expect(ContinuousClock.now - started < .seconds(3), "the pre-connect script was stopped")
        #expect(server.received.isEmpty, "no connection was opened after the invalidation")
        #expect(await pool.count == 0)
    }
}

private let scanNodeA = RedisEndpoint(host: "127.0.0.1", port: 7300)
private let scanNodeB = RedisEndpoint(host: "127.0.0.1", port: 7301)
private let scanNodeC = RedisEndpoint(host: "127.0.0.1", port: 7302)

private func slotsReply(_ low: RedisEndpoint, _ high: RedisEndpoint) -> RESPValue {
    .array([
        .array([.integer(0), .integer(8191), .array([.bulk(low.host), .integer(Int64(low.port)), .bulk(low.description)])]),
        .array([.integer(8192), .integer(16383), .array([.bulk(high.host), .integer(Int64(high.port)), .bulk(high.description)])]),
    ])
}

private func scanReply(cursor: String, _ keys: [String]) -> RESPValue {
    .array([.bulk(cursor), .bulkArray(keys)])
}

@MainActor
struct ClusterKeyScanTests {
    private func session(_ mocks: [RedisEndpoint: MockRedisClient]) -> (DatabaseSession, ClusterClient) {
        let cluster = ClusterClient(seeds: [scanNodeA], nodeConfig: RedisConnectionConfig(), nodeClientFactory: { config in
            guard let mock = mocks[config.endpoint] else { throw RedisClientError.notConnected }
            return mock
        })
        let config = DatabaseConfig(name: "Cluster", connectionType: .cluster)
        return (DatabaseSession(config: config, services: RedisTestServer.makeServices(), client: cluster), cluster)
    }

    @Test func nodeReportingZeroKeysIsStillScanned() async throws {
        let a = MockRedisClient(responses: ["CLUSTER SLOTS": slotsReply(scanNodeA, scanNodeB), "DBSIZE": .integer(0),
                                            "SCAN": scanReply(cursor: "0", ["ghost"])])
        let b = MockRedisClient(responses: ["DBSIZE": .integer(2), "SCAN": scanReply(cursor: "0", ["b1", "b2"])])
        let (session, _) = session([scanNodeA: a, scanNodeB: b])
        let state = try await KeyScanner(session: session).scan(ScanRequest(count: 100))
        #expect(Set(state.keys.map { String(decoding: $0.name, as: UTF8.self) }) == ["ghost", "b1", "b2"])
        #expect(state.isComplete)
    }

    @Test func newPrimaryAfterFailoverIsScanned() async throws {
        let a = MockRedisClient(responses: ["CLUSTER SLOTS": slotsReply(scanNodeC, scanNodeB), "DBSIZE": .integer(3),
                                            "SCAN": scanReply(cursor: "7", ["a1"])])
        await a.enqueue([slotsReply(scanNodeA, scanNodeB)], for: "CLUSTER SLOTS")
        let b = MockRedisClient(responses: ["CLUSTER SLOTS": slotsReply(scanNodeC, scanNodeB), "DBSIZE": .integer(1),
                                            "SCAN": scanReply(cursor: "0", ["b1"])])
        let c = MockRedisClient(responses: ["CLUSTER SLOTS": slotsReply(scanNodeC, scanNodeB), "DBSIZE": .integer(3),
                                            "SCAN": scanReply(cursor: "0", ["a1", "a2", "a3"])])
        let (session, cluster) = session([scanNodeA: a, scanNodeB: b, scanNodeC: c])
        let scanner = KeyScanner(session: session)
        let first = try await scanner.scan(ScanRequest(count: 1))
        #expect(!first.isComplete)

        try await cluster.refreshTopology()
        #expect(try await cluster.nodes(role: .primary).map(\.endpoint).contains(scanNodeC))
        let next = try await scanner.scan(ScanRequest(count: 1), continuing: first)
        #expect(await c.executedCommandStrings.contains { $0.hasPrefix("SCAN 0 ") })
        #expect(Set(next.keys.map { String(decoding: $0.name, as: UTF8.self) }).isSuperset(of: ["a2", "a3", "b1"]))
    }
}
