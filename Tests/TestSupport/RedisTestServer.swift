import Darwin
import Foundation
import RedisCore

/// Live Redis used by integration tests: Redis 8.10 with modules at 127.0.0.1:6390.
/// Never point tests at 6379 (the user's own instance).
public enum RedisTestServer {
    public static let host = "127.0.0.1"
    public static let port = 6390
    public static let endpoint = RedisEndpoint(host: host, port: port)

    /// DB index per test target (RediSearch tests use DB 0 with a unique prefix + index name).
    public enum DB {
        public static let resp = 1
        public static let redisClient = 2
        public static let redisCore = 3
        /// Second index for RedisCore tests that move a connection to another database.
        public static let redisCoreSpare = 15
        public static let browser = 4
        public static let keyTypesBasic = 5
        public static let keyTypesAdvanced = 6
        public static let workbench = 7
        public static let cli = 8
        public static let analytics = 9
        public static let monitoring = 10
        public static let vectorSearch = 11
        public static let connections = 12
        public static let settings = 13
        public static let redisUI = 14
        public static let search = 0
    }

    /// If `KEYSTRAND_REQUIRE_LIVE=1`, all availability flags are true so missing servers fail tests.
    public static let requireLiveEnvironmentKey = "KEYSTRAND_REQUIRE_LIVE"

    public static let requiresLive: Bool = ProcessInfo.processInfo.environment[requireLiveEnvironmentKey] == "1"

    /// True when a TCP connection to 127.0.0.1:6390 succeeds (checked once per process).
    /// Gate live tests with `.tags(.live), RedisTestServer.live(.redis)`, which also checks this flag.
    public static let isAvailable: Bool = !skipsLive && (requiresLive || probe(host: host, port: port, timeoutMs: 500))

    public static func connectionConfig(db: Int, endpoint: RedisEndpoint = RedisTestServer.endpoint) -> RedisConnectionConfig {
        RedisConnectionConfig(host: endpoint.host, port: endpoint.port, dbIndex: db, connectTimeout: 5,
                              clientName: "keystrand-tests")
    }

    /// Valkey 9 bundle (JSON, Bloom, Search, LDAP modules), container `keystrand-valkey`.
    /// Use the same `DB` index as the Redis tests of the target.
    public static let valkey = RedisEndpoint(host: "127.0.0.1", port: 6392)

    /// True when a TCP connection to the Valkey server succeeds (checked once per process).
    /// Gate Valkey tests with `.tags(.live), RedisTestServer.live(.valkey)`.
    public static let isValkeyAvailable: Bool = !skipsLive
        && (requiresLive || probe(host: valkey.host, port: valkey.port, timeoutMs: 500))

    /// Valkey 9 cluster of three primaries started with `--cluster-databases 4`, containers `keystrand-vkc-0/1/2`.
    /// Seed it with `valkey-cli -c -p 7001 -n <db>`, using the target's `DB` index only when it is below 4.
    public static let valkeyCluster = [7001, 7002, 7003].map { RedisEndpoint(host: "127.0.0.1", port: $0) }

    /// True when the first Valkey cluster node answers `CLUSTER INFO` with `cluster_state:ok` (checked once per process).
    /// Gate cluster tests with `.tags(.live), RedisTestServer.live(.valkeyCluster)`.
    public static let isValkeyClusterAvailable: Bool = !skipsLive
        && (requiresLive || probeClusterState(valkeyCluster[0], timeoutMs: 500))

    /// Saved-database model for the Valkey cluster (connection type already detected).
    public static func valkeyClusterDatabaseConfig(db: Int, name: String = "Test Valkey Cluster") -> DatabaseConfig {
        var config = DatabaseConfig(name: name, host: valkeyCluster[0].host, port: valkeyCluster[0].port, db: db,
                                    connectionType: .cluster)
        config.nodes = valkeyCluster
        return config
    }

    /// Saved-database model pointing at the test server (or `endpoint`).
    public static func databaseConfig(db: Int, name: String = "Test DB",
                                      endpoint: RedisEndpoint = RedisTestServer.endpoint) -> DatabaseConfig {
        DatabaseConfig(name: name, host: endpoint.host, port: endpoint.port, db: db, connectionType: .standalone)
    }

    /// Connected `RedisConnection` with `db` selected.
    public static func makeConnection(db: Int, endpoint: RedisEndpoint = RedisTestServer.endpoint) async throws -> RedisConnection {
        try await RedisConnection.connect(config: connectionConfig(db: db, endpoint: endpoint))
    }

    /// Empties `db` with SCAN + UNLINK; DB 0 is reserved for shared search tests.
    /// RediSearch drops every index on any FLUSHDB, including one on another logical database.
    public static func flush(db: Int) async throws {
        precondition(db != 0, "Do not flush database 0; clean up by prefix instead.")
        let connection = try await makeConnection(db: db)
        try await emptyDatabase(connection)
        await connection.close()
    }

    /// Returns a connected client and empties its database unless `db` is 0.
    public static func freshConnection(db: Int, endpoint: RedisEndpoint = RedisTestServer.endpoint) async throws -> RedisConnection {
        let connection = try await makeConnection(db: db, endpoint: endpoint)
        if db != 0 { try await emptyDatabase(connection) }
        return connection
    }

    /// Deletes every key of the connection's current database without `FLUSHDB`.
    public static func emptyDatabase(_ client: any RedisClient) async throws {
        var cursor = "0"
        repeat {
            let reply = try await client.execute(["SCAN", .string(cursor), "COUNT", "5000"])
            guard let items = reply.arrayValue, items.count == 2 else { return }
            cursor = items[0].stringValue ?? "0"
            let keys = (items[1].arrayValue ?? []).compactMap(\.dataValue)
            if !keys.isEmpty { _ = try await client.pipeline(keys.map { ["UNLINK", .data($0)] }) }
        } while cursor != "0"
    }

    /// Unique key prefix for tests that share DB 0 (`rgtest:<area>:<uuid>:`).
    public static func uniquePrefix(_ area: String) -> String {
        "rgtest:\(area):\(UUID().uuidString.prefix(8).lowercased()):"
    }

    /// Isolated services (temp folder, in-memory secrets).
    @MainActor
    public static func makeServices() -> AppServices {
        AppServices(paths: .temporary(), secrets: InMemorySecretStore())
    }

    /// Session backed by a scripted client (no network).
    @MainActor
    public static func mockSession(_ client: MockRedisClient = MockRedisClient(),
                                   config: DatabaseConfig = DatabaseConfig(name: "Mock")) -> DatabaseSession {
        DatabaseSession(config: config, services: makeServices(), client: client)
    }

    static func probe(host: String, port: Int, timeoutMs: Int32) -> Bool {
        guard let fd = connectedSocket(host: host, port: port, timeoutMs: timeoutMs) else { return false }
        close(fd)
        return true
    }

    /// Sends an inline `CLUSTER INFO` and checks the `cluster_state` line.
    static func probeClusterState(_ endpoint: RedisEndpoint, timeoutMs: Int32) -> Bool {
        inlineCommand("CLUSTER INFO", at: endpoint, timeoutMs: timeoutMs)?.stringValue?.contains("cluster_state:ok") == true
    }

    /// A connected TCP socket (non-blocking), or nil when nothing accepts within `timeoutMs`. The caller closes it.
    static func connectedSocket(host: String, port: Int, timeoutMs: Int32) -> Int32? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else {
            close(fd)
            return nil
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if result == 0 { return fd }
        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        var error: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        guard errno == EINPROGRESS, poll(&pfd, 1, timeoutMs) == 1,
              getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0, error == 0 else {
            close(fd)
            return nil
        }
        return fd
    }
}

/// Valkey 9.1.2 as the `valkey/valkey-bundle:9` image reports it, for scripted sessions and capability checks.
public enum ValkeyFixtures {
    /// Server identification lines for Valkey.
    public static let serverInfo = "# Server\r\nredis_version:7.2.4\r\nserver_name:valkey\r\nvalkey_version:9.1.2\r\n"

    /// valkey-json 1.0.3, valkey-bloom 1.0.1, and valkey-search 1.2.1 (hex-encoded version).
    public static let capabilities = DatabaseCapabilities(
        redisVersion: "7.2.4", serverFlavor: .valkey, serverVersion: "9.1.2",
        modules: [RedisModuleInfo(name: "json", version: 10_003), RedisModuleInfo(name: "bf", version: 10_001),
                  RedisModuleInfo(name: "search", version: 66_049)])
}
