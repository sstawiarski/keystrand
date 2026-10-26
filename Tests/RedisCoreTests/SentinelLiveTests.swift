import Foundation
import RedisCore
import TestSupport
import Testing

/// Live tests against the Sentinel group that `scripts/test-servers.sh start sentinel` runs. Every Sentinel test is in
/// this one serialized suite, because `sessionFollowsAFailover` swaps the primary and the replica.
@MainActor
@Suite(.serialized, .tags(.live), RedisTestServer.live(.sentinel))
struct SentinelLiveTests {
    static let db = RedisTestServer.DB.redisCore
    static let group = RedisTestServer.sentinelGroup
    /// Nothing listens here, so connecting is refused immediately.
    static let closedEndpoint = RedisEndpoint(host: "127.0.0.1", port: 6391)

    static var sentinelConfig: RedisConnectionConfig {
        var config = RedisTestServer.connectionConfig(db: 0, endpoint: RedisTestServer.sentinel)
        config.readyCheck = false
        return config
    }

    static let resolver = SentinelResolver(sentinelConfig: sentinelConfig)

    /// The Sentinel database as the Add Database form saves it.
    static func databaseConfig() -> DatabaseConfig {
        var config = RedisTestServer.databaseConfig(db: db, name: "Sentinel", endpoint: RedisTestServer.sentinel)
        config.connectionType = .sentinel
        config.sentinelMaster = SentinelMasterConfig(name: group)
        return config
    }

    @Test func resolverFindsThePrimary() async throws {
        let master = try #require(try await Self.resolver.masters().first { $0.name == Self.group })
        #expect(RedisTestServer.sentinelNodes.contains(master.endpoint))
        #expect(master.status == "active")
        #expect(master.numberOfSlaves == 1)

        let primary = try await Self.resolver.resolveMaster(name: Self.group,
                                                            sentinels: [Self.closedEndpoint, RedisTestServer.sentinel])
        #expect(primary == master.endpoint)
        #expect(try await Self.role(of: primary) == "master")
        #expect(try await Self.resolver.sentinels(for: Self.group).isEmpty)
    }

    @Test func resolverRejectsAnUnknownGroup() async throws {
        do {
            _ = try await Self.resolver.resolveMaster(name: "keystrand-missing", sentinels: [RedisTestServer.sentinel])
            Issue.record("expected RedisClientError.sentinelMasterNotFound")
        } catch RedisClientError.sentinelMasterNotFound(let name) {
            #expect(name == "keystrand-missing")
        }
    }

    @Test func databaseFactoryDetectsTheSentinel() async throws {
        let factory = DatabaseFactory()
        var draft = RedisTestServer.databaseConfig(db: Self.db, name: "Sentinel", endpoint: RedisTestServer.sentinel)
        draft.connectionType = .notConnected
        try await factory.test(draft)
        do {
            _ = try await factory.createDetected(draft)
            Issue.record("expected DatabaseFactoryError.sentinelMasterRequired")
        } catch DatabaseFactoryError.sentinelMasterRequired {}

        #expect(try await factory.sentinelMasters(draft).map(\.name).contains(Self.group))

        draft.sentinelMaster = SentinelMasterConfig(name: Self.group)
        let detected = try await factory.createDetected(draft)
        #expect(detected.connectionType == .sentinel)
        #expect(detected.nodes == [])
        #expect(detected.version?.isEmpty == false)

        draft.sentinelMaster = SentinelMasterConfig(name: "keystrand-missing")
        do {
            _ = try await factory.createDetected(draft)
            Issue.record("expected an unknown primary group to fail")
        } catch DatabaseFactoryError.connection(let error) {
            #expect(error.title == "Primary group not found")
        }
    }

    @Test func sessionFollowsAFailover() async throws {
        let session = try await RedisTestServer.liveSession(config: Self.databaseConfig())
        #expect(session.connectionKind == .sentinel)
        let before = try await Self.resolver.resolveMaster(name: Self.group, sentinels: [RedisTestServer.sentinel])
        let key = RedisTestServer.uniquePrefix("sentinel") + "failover"
        _ = try await session.execute(["SET", .string(key), "before"])
        #expect(try await session.execute(["WAIT", "1", "5000"]).intValue == 1)

        let after = try await Self.failOver(from: before)
        #expect(after != before)
        #expect(try await session.execute(["GET", .string(key)]).stringValue == "before")
        _ = try await session.execute(["SET", .string(key), "after"])

        let dedicated = try await session.makeDedicatedConnection()
        #expect(await dedicated.config.endpoint == after)
        #expect(try await dedicated.execute(["GET", .string(key)]).stringValue == "after")
        _ = try await dedicated.execute(["UNLINK", .string(key)])
        await dedicated.close()
        await session.close()
    }

    // MARK: - Helpers

    /// Fails the group over and returns the new primary once the old primary has become its replica. The demotion
    /// closes every client connection to the old primary, so a session's next command reconnects through the Sentinel.
    static func failOver(from primary: RedisEndpoint) async throws -> RedisEndpoint {
        let sentinel = try await RedisConnection.connect(config: sentinelConfig)
        do {
            try await waitUntil("the Sentinel sees a replica it can promote") {
                let replicas = try await sentinel.execute(["SENTINEL", "REPLICAS", .string(group)])
                return (replicas.arrayValue ?? []).contains { replica in
                    let fields = replica.stringKeyedMap
                    return fields?["flags"]?.stringValue == "slave" && fields?["master-link-status"]?.stringValue == "ok"
                }
            }
            _ = try await sentinel.execute(["SENTINEL", "FAILOVER", .string(group)])
            await sentinel.close()
        } catch {
            await sentinel.close()
            throw error
        }

        try await waitUntil("the old primary becomes a replica") { try await role(of: primary) == "slave" }
        // Lets the session's connection see the close before the test sends its next command.
        try await Task.sleep(for: .milliseconds(500))
        return try await resolver.resolveMaster(name: group, sentinels: [RedisTestServer.sentinel])
    }

    /// `ROLE` of the server at `endpoint`, on a short-lived connection.
    static func role(of endpoint: RedisEndpoint) async throws -> String? {
        let connection = try await RedisConnection.connect(config: RedisTestServer.connectionConfig(db: db, endpoint: endpoint))
        do {
            let reply = try await connection.execute(["ROLE"])
            await connection.close()
            return reply.arrayValue?.first?.stringValue
        } catch {
            await connection.close()
            throw error
        }
    }

    struct WaitTimeout: Error, CustomStringConvertible {
        var description: String
    }

    /// Polls `condition` every 250 ms until it holds. An error counts as "not yet", because a failover drops
    /// connections.
    static func waitUntil(_ description: String, timeout: Duration = .seconds(60),
                          _ condition: () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if (try? await condition()) == true { return }
            try await Task.sleep(for: .milliseconds(250))
        }

        throw WaitTimeout(description: "Timed out waiting until \(description)")
    }
}
