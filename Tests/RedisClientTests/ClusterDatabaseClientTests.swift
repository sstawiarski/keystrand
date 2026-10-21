import Foundation
import RedisClient
import RESP
import TestSupport
import Testing

struct ClusterNumberedDatabaseTests {
    private static func config(db: Int) -> RedisConnectionConfig {
        RedisConnectionConfig(host: "127.0.0.1", port: 7001, dbIndex: db)
    }

    @Test func nodeConnectionsUseTheGivenDB() async {
        let cluster = ClusterClient(seeds: [RedisEndpoint(host: "127.0.0.1", port: 7001)], nodeConfig: Self.config(db: 2),
                                    nodeClientFactory: { _ in MockRedisClient() })
        #expect(await cluster.nodeConfig.dbIndex == 2)
    }
}

private actor OpenedNodes {
    private(set) var databases: [RedisEndpoint: Int] = [:]

    func record(_ config: RedisConnectionConfig) {
        databases[config.endpoint] = config.dbIndex
    }
}

/// Live tests against the Valkey 9 cluster (`RedisTestServer.valkeyCluster`, `cluster-databases 4`).
@Suite(.serialized, .tags(.live), RedisTestServer.live(.valkeyCluster))
struct ValkeyClusterClientTests {
    static let db = RedisTestServer.DB.redisClient

    @Test func movedInsideDB2LandsOnTheOwnerInDB2() async throws {
        let prefix = RedisTestServer.uniquePrefix("cluster-moved")
        let key = prefix + "{a}"
        let seed = RedisTestServer.valkeyCluster[0]
        let opened = OpenedNodes()
        // Every command looks keyless, so it goes to the first primary and the owner of `{a}` answers with MOVED.
        let cluster = ClusterClient(
            seeds: [seed], nodeConfig: RedisConnectionConfig(host: seed.host, port: seed.port, dbIndex: Self.db,
                                                             connectTimeout: 5, clientName: "keystrand-tests"),
            keyLocator: { _ in Int.max },
            nodeClientFactory: { config in
                await opened.record(config)
                return try await RedisConnection.connect(config: config)
            })
        let owner = try #require(try await cluster.owner(ofKey: Data(key.utf8)))
        let first = try #require(try await cluster.nodes(role: .primary).first { !$0.slots.isEmpty })
        #expect(owner != first.endpoint)

        let ownerConnection = try await RedisConnection.connect(
            config: RedisConnectionConfig(host: owner.host, port: owner.port, dbIndex: Self.db, connectTimeout: 5))
        let ownerDB0 = try await RedisConnection.connect(
            config: RedisConnectionConfig(host: owner.host, port: owner.port, dbIndex: 0, connectTimeout: 5))
        _ = try await ownerConnection.execute(["SET", .string(key), "in-db2"])
        _ = try await ownerDB0.execute(["SET", .string(key), "in-db0"])

        let direct = try await cluster.send(["GET", .string(key)], to: first.endpoint)
        #expect(direct.errorValue.flatMap { ClusterRedirect($0, defaultHost: first.endpoint.host) }?.endpoint == owner)
        #expect(try await cluster.execute(["GET", .string(key)]).stringValue == "in-db2")
        #expect(await opened.databases[owner] == Self.db)
        let ownerClient = try await cluster.connection(for: owner)
        #expect(await ownerClient.selectedDB == Self.db)

        _ = try await ownerConnection.execute(["UNLINK", .string(key)])
        _ = try await ownerDB0.execute(["UNLINK", .string(key)])
        await ownerConnection.close()
        await ownerDB0.close()
        await cluster.close()
    }
}
