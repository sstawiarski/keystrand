import Foundation
import RESP

public struct SentinelMasterInfo: Hashable, Sendable, Identifiable {
    public var name: String
    public var host: String
    public var port: Int
    public var numberOfSlaves: Int
    public var status: String
    public var id: String { name }

    public init(name: String, host: String, port: Int, numberOfSlaves: Int = 0, status: String = "ok") {
        self.name = name
        self.host = host
        self.port = port
        self.numberOfSlaves = numberOfSlaves
        self.status = status
    }

    public var endpoint: RedisEndpoint { RedisEndpoint(host: host, port: port) }
}

/// Talks to Sentinel nodes (`SENTINEL MASTERS`, `SENTINEL GET-MASTER-ADDR-BY-NAME`, `SENTINEL SENTINELS`).
public struct SentinelResolver: Sendable {
    /// Connection template for the sentinels themselves (sentinel username/password, TLS, timeouts).
    public var sentinelConfig: RedisConnectionConfig

    public init(sentinelConfig: RedisConnectionConfig) {
        var config = sentinelConfig
        config.dbIndex = 0
        config.readyCheck = false
        self.sentinelConfig = config
    }

    /// All monitored masters of the sentinel at `sentinelConfig.endpoint`.
    public func masters() async throws -> [SentinelMasterInfo] {
        try await withSentinel(sentinelConfig.endpoint) { connection in
            let reply = try await connection.execute(["SENTINEL", "MASTERS"])
            return Self.parseMasters(reply)
        }
    }

    /// Asks each sentinel in turn for the current address of `masterName`.
    public func resolveMaster(name masterName: String, sentinels: [RedisEndpoint]) async throws -> RedisEndpoint {
        var candidates: [RedisEndpoint] = []
        for endpoint in (sentinels.isEmpty ? [sentinelConfig.endpoint] : sentinels) where !candidates.contains(endpoint) {
            candidates.append(endpoint)
        }

        var lastError: Error = RedisClientError.sentinelMasterNotFound(masterName)
        for endpoint in candidates {
            do {
                return try await withSentinel(endpoint) { connection in
                    let reply = try await connection.execute(["SENTINEL", "GET-MASTER-ADDR-BY-NAME", .string(masterName)])
                    guard let address = Self.parseMasterAddress(reply) else {
                        throw RedisClientError.sentinelMasterNotFound(masterName)
                    }
                    return address
                }
            } catch {
                lastError = error
            }
        }

        throw lastError
    }

    /// Returns other sentinels monitoring `masterName`.
    public func sentinels(for masterName: String) async throws -> [RedisEndpoint] {
        try await withSentinel(sentinelConfig.endpoint) { connection in
            let reply = try await connection.execute(["SENTINEL", "SENTINELS", .string(masterName)])
            return Self.parseSentinels(reply)
        }
    }

    // MARK: - Parsing (pure)

    public static func parseMasters(_ reply: RESPValue) -> [SentinelMasterInfo] {
        (reply.arrayValue ?? []).compactMap { entry -> SentinelMasterInfo? in
            guard let fields = entry.stringKeyedMap, let name = fields["name"]?.stringValue else { return nil }
            let host = fields["ip"]?.stringValue ?? ""
            let port = fields["port"]?.intValue.map(Int.init) ?? 0
            let slaves = fields["num-slaves"]?.intValue.map(Int.init) ?? 0
            let flags = fields["flags"]?.stringValue ?? ""
            return SentinelMasterInfo(name: name, host: host, port: port, numberOfSlaves: slaves,
                                      status: flags.contains("down") ? "down" : "active")
        }
    }

    public static func parseMasterAddress(_ reply: RESPValue) -> RedisEndpoint? {
        guard let items = reply.arrayValue, items.count >= 2, let host = items[0].stringValue,
              let port = items[1].intValue else { return nil }
        return RedisEndpoint(host: host, port: Int(port))
    }

    public static func parseSentinels(_ reply: RESPValue) -> [RedisEndpoint] {
        (reply.arrayValue ?? []).compactMap { entry in
            guard let fields = entry.stringKeyedMap, let host = fields["ip"]?.stringValue,
                  let port = fields["port"]?.intValue else { return nil }
            return RedisEndpoint(host: host, port: Int(port))
        }
    }

    // MARK: - Connections

    private func withSentinel<T>(_ endpoint: RedisEndpoint,
                                 _ body: (RedisConnection) async throws -> T) async throws -> T {
        var config = sentinelConfig.with(endpoint: endpoint)
        config.retry = .none
        let connection = try await RedisConnection.connect(config: config)
        do {
            let result = try await body(connection)
            await connection.close()
            return result
        } catch {
            await connection.close()
            throw error
        }
    }

    /// Resolves the master, connects with `masterConfig` auth and database, and checks ROLE.
    /// Tries up to three times if failover changes the master.
    public func connectToMaster(name: String, sentinels: [RedisEndpoint],
                                masterConfig: RedisConnectionConfig) async throws -> RedisConnection {
        try await withVerifiedMaster(name: name, sentinels: sentinels, masterConfig: masterConfig) { connection, _ in
            connection
        }
    }

    /// Verifies the master address through ROLE on a short-lived connection before reconnecting.
    public func resolveVerifiedMaster(name: String, sentinels: [RedisEndpoint],
                                      masterConfig: RedisConnectionConfig) async throws -> RedisEndpoint {
        var probeConfig = masterConfig
        probeConfig.retry = .none
        probeConfig.readyCheck = false
        return try await withVerifiedMaster(name: name, sentinels: sentinels, masterConfig: probeConfig) { connection, endpoint in
            await connection.close()
            return endpoint
        }
    }

    /// Resolves, connects, and checks `ROLE` up to three times; `body` receives the verified connection, which it owns.
    private func withVerifiedMaster<T>(name: String, sentinels: [RedisEndpoint], masterConfig: RedisConnectionConfig,
                                       _ body: (RedisConnection, RedisEndpoint) async throws -> T) async throws -> T {
        var lastError: Error = RedisClientError.sentinelMasterNotFound(name)
        for attempt in 0..<3 {
            if attempt > 0 { try await Task.sleep(nanoseconds: 500_000_000) }
            let endpoint = try await resolveMaster(name: name, sentinels: sentinels)
            let connection = try await RedisConnection.connect(config: masterConfig.with(endpoint: endpoint))
            do {
                if try await Self.isMaster(connection) { return try await body(connection, endpoint) }
                lastError = RedisClientError.connectionFailed("\(endpoint) is not a master")
            } catch {
                lastError = error
            }
            await connection.close()
        }

        throw lastError
    }

    /// Accepts ROLE `master` or a server error if ROLE is not permitted.
    private static func isMaster(_ connection: RedisConnection) async throws -> Bool {
        do {
            let role = try await connection.execute(["ROLE"])
            return role.arrayValue?.first?.stringValue?.lowercased() == "master"
        } catch RedisClientError.server {
            return true
        }
    }
}
