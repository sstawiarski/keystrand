import Foundation
import RedisCore
import TestSupport
import Testing

@MainActor
struct EffectiveDBTests {
    private static func session(connectionType: ConnectionType, db: Int, info: String,
                                clusterDatabases: Int? = nil) -> DatabaseSession {
        let client = MockRedisClient { command in
            let text = command.map { String(decoding: $0, as: UTF8.self) }.joined(separator: " ").uppercased()
            if text.hasPrefix("INFO") { return .bulk(info) }
            if text == "CONFIG GET CLUSTER-DATABASES" {
                return .bulkArray(clusterDatabases.map { ["cluster-databases", String($0)] } ?? [])
            }

            if text == "CONFIG GET DATABASES" { return .bulkArray(["databases", "16"]) }
            return nil
        }
        let config = DatabaseConfig(name: "Mock", host: "127.0.0.1", port: 7001, db: db, connectionType: connectionType)
        return RedisTestServer.mockSession(client, config: config)
    }

    private static let redisClusterInfo = "# Server\r\nredis_version:8.0.3\r\nredis_mode:cluster\r\n"
    private static let valkeyClusterInfo =
        ValkeyFixtures.serverInfo + "server_mode:cluster\r\n"

    @Test func redisClusterAlwaysUsesDB0() async throws {
        let session = Self.session(connectionType: .cluster, db: 2, info: Self.redisClusterInfo, clusterDatabases: 4)
        try await session.refreshInfo()
        #expect(session.isCluster)
        #expect(session.effectiveDB == 0)
        #expect(session.databaseCount == 1)
        #expect(await session.canSelect(db: 1) == false)
    }

    @Test func standaloneUsesSelectedDB() async throws {
        let session = Self.session(connectionType: .standalone, db: 3, info: "# Server\r\nredis_version:8.0.3\r\n")
        #expect(session.effectiveDB == 3)
        try await session.refreshInfo()
        #expect(session.effectiveDB == 3)
        #expect(session.databaseCount == 16)
    }

    @Test func valkey9ClusterUsesSelectedDBOnceDetailsLoad() async throws {
        let session = Self.session(connectionType: .cluster, db: 2, info: Self.valkeyClusterInfo, clusterDatabases: 4)
        #expect(session.effectiveDB == 0)
        try await session.refreshInfo()
        #expect(session.effectiveDB == 2)
        #expect(session.databaseCount == 4)
        #expect(await session.canSelect(db: 3))
        #expect(await session.canSelect(db: 4) == false)
    }

    @Test func valkey9ClusterFallsBackToDB0AboveClusterDatabases() async throws {
        let session = Self.session(connectionType: .cluster, db: 5, info: Self.valkeyClusterInfo, clusterDatabases: 4)
        try await session.refreshInfo()
        #expect(session.effectiveDB == 0)
    }

    @Test func clusterScanCountsKeysOfTheEffectiveDBWhenDBSIZEFails() async throws {
        let info = Self.valkeyClusterInfo + "# Keyspace\r\ndb2:keys=3,expires=0,avg_ttl=0\r\n"
        let client = MockRedisClient { command in
            let text = command.map { String(decoding: $0, as: UTF8.self) }.joined(separator: " ").uppercased()
            if text.hasPrefix("INFO") { return .bulk(info) }
            if text == "CONFIG GET CLUSTER-DATABASES" { return .bulkArray(["cluster-databases", "4"]) }
            if text == "DBSIZE" { return .error(RESPError("ERR unknown command 'DBSIZE'")) }
            if text.hasPrefix("SCAN") { return .array([.bulk("0"), .array([.bulk("k1"), .bulk("k2"), .bulk("k3")])]) }
            return nil
        }
        let config = DatabaseConfig(name: "Mock", host: "127.0.0.1", port: 7001, db: 2, connectionType: .cluster)
        let session = RedisTestServer.mockSession(client, config: config)
        try await session.refreshInfo()
        #expect(session.effectiveDB == 2)

        let state = try await KeyScanner(session: session).scan(ScanRequest(match: "*", count: 500))
        #expect(await client.executedCommandStrings.contains { $0.hasPrefix("SCAN 0") })
        #expect(state.keys.count == 3)
    }
}

/// Live tests against the Valkey 9 cluster (`RedisTestServer.valkeyCluster`, `cluster-databases 4`).
@MainActor
@Suite(.serialized, .tags(.live), RedisTestServer.live(.valkeyCluster))
struct ValkeyClusterDatabaseTests {
    static let db = RedisTestServer.DB.redisCore

    /// Seeds through the first node and follows one `MOVED` redirect.
    private static func seed(_ pairs: [(String, String)], db: Int) async throws {
        var connections: [RedisEndpoint: RedisConnection] = [:]

        func connection(_ endpoint: RedisEndpoint) async throws -> RedisConnection {
            if let existing = connections[endpoint] { return existing }
            var config = RedisConnectionConfig(host: endpoint.host, port: endpoint.port, dbIndex: db, connectTimeout: 5)
            config.clientName = "keystrand-tests"
            let opened = try await RedisConnection.connect(config: config)
            connections[endpoint] = opened
            return opened
        }

        for (key, value) in pairs {
            let first = RedisTestServer.valkeyCluster[0]
            var reply = try await connection(first).send(["SET", .string(key), .string(value)])
            if case .error(let error) = reply, let redirect = ClusterRedirect(error, defaultHost: first.host) {
                reply = try await connection(redirect.endpoint).send(["SET", .string(key), .string(value)])
            }

            #expect(!reply.isError)
        }

        for opened in connections.values { await opened.close() }
    }

    private static func deleteKeys(prefix: String, db: Int) async throws {
        for endpoint in RedisTestServer.valkeyCluster {
            let connection = try await RedisConnection.connect(
                config: RedisConnectionConfig(host: endpoint.host, port: endpoint.port, dbIndex: db, connectTimeout: 5))
            let reply = try await connection.execute(["KEYS", .string(prefix + "*")])
            let keys = (reply.arrayValue ?? []).compactMap(\.dataValue)
            if !keys.isEmpty { _ = try await connection.pipeline(keys.map { ["UNLINK", .data($0)] }) }
            await connection.close()
        }
    }

    private static func scannedNames(_ session: DatabaseSession, prefix: String) async throws -> Set<String> {
        let scanner = KeyScanner(session: session)
        var state = try await scanner.scan(ScanRequest(match: prefix + "*", count: 100))
        while !state.isComplete { state = try await scanner.scan(ScanRequest(match: prefix + "*", count: 100), continuing: state) }
        return Set(state.keys.map { String(decoding: $0.name, as: UTF8.self) })
    }

    /// Key names spread over all three primaries (slot owners differ for a, b, c with hash tags).
    private static func keyNames(_ prefix: String) -> [String] {
        ["{a}", "{b}", "{c}", "{foo}", "{bar}", "{baz}"].map { prefix + $0 }
    }

    @Test func databaseCountComesFromClusterDatabases() async throws {
        let session = try await RedisTestServer.liveSession(config: RedisTestServer.valkeyClusterDatabaseConfig(db: Self.db))
        #expect(session.isCluster)
        #expect(session.capabilities.supportsClusterDatabases)
        #expect(session.databaseCount == 4)
        #expect(session.effectiveDB == Self.db)
        await session.close()
    }

    @Test func sessionOnSelectedDBScansAndReadsItsKeysOnly() async throws {
        let prefix = RedisTestServer.uniquePrefix("cluster-db")
        let names = Self.keyNames(prefix)
        var session: DatabaseSession?
        do {
            try await Self.seed(names.map { ($0, "selected:" + $0) }, db: Self.db)
            try await Self.seed([(prefix + "only-db0", "db0")] + names.map { ($0, "db0:" + $0) }, db: 0)
            let live = try await RedisTestServer.liveSession(config: RedisTestServer.valkeyClusterDatabaseConfig(db: Self.db))
            session = live
            #expect(try await Self.scannedNames(live, prefix: prefix) == Set(names))
            for name in names {
                #expect(try await live.execute(["GET", .string(name)]).stringValue == "selected:" + name)
            }

            #expect(try await live.execute(["EXISTS", .string(prefix + "only-db0")]).intValue == 0)
            #expect(try await KeyScanner(session: live).totalKeys() >= names.count)

            let dedicated = try await live.makeDedicatedConnection()
            #expect(await dedicated.selectedDB == Self.db)
            let clientInfo = try await dedicated.execute(["CLIENT", "INFO"]).stringValue ?? ""
            #expect(clientInfo.contains("db=\(Self.db)"))
            await dedicated.close()
        } catch {
            Issue.record(error)
        }

        await session?.close()
        try? await Self.deleteKeys(prefix: prefix, db: Self.db)
        try? await Self.deleteKeys(prefix: prefix, db: 0)
    }

    @Test func selectingAnotherDatabaseReloadsLikeStandalone() async throws {
        let prefix = RedisTestServer.uniquePrefix("cluster-select")
        var session: DatabaseSession?
        do {
            try await Self.seed([(prefix + "{a}", "selected")], db: Self.db)
            let live = try await RedisTestServer.liveSession(config: RedisTestServer.valkeyClusterDatabaseConfig(db: 0))
            session = live
            #expect(try await Self.scannedNames(live, prefix: prefix).isEmpty)
            let generation = live.dbGeneration
            try await live.select(db: Self.db)
            #expect(live.dbGeneration == generation + 1)
            #expect(live.effectiveDB == Self.db)
            #expect(try await Self.scannedNames(live, prefix: prefix) == [prefix + "{a}"])
            await #expect(throws: RedisClientError.self) { try await live.select(db: 4) }
            #expect(live.dbIndex == Self.db)
        } catch {
            Issue.record(error)
        }

        await session?.close()
        try? await Self.deleteKeys(prefix: prefix, db: Self.db)
    }
}
