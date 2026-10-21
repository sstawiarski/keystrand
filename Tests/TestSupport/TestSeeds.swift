import Foundation
import RedisCore

/// Live-session and data-seeding helpers shared by every test target.
public extension RedisTestServer {
    /// Connects to `db` with isolated services and in-memory secrets.
    /// Saves the config so the session can resolve its secrets.
    @MainActor
    static func liveSession(db: Int, name: String = "Test DB", endpoint: RedisEndpoint = RedisTestServer.endpoint,
                            configure: (inout DatabaseConfig) -> Void = { _ in }) async throws -> DatabaseSession {
        var config = databaseConfig(db: db, name: name, endpoint: endpoint)
        configure(&config)
        return try await liveSession(config: config)
    }

    /// Saves `config` in isolated services and returns a connected session.
    @MainActor
    static func liveSession(config: DatabaseConfig) async throws -> DatabaseSession {
        let services = makeServices()
        try await services.databaseStore.create(config)
        let session = try await services.sessions.session(for: config.id)
        await session.connect()
        if case .failed(let error) = session.state { throw error }
        return session
    }

    /// Names of the keys created by `seedAllTypes`, by type.
    struct SeededKeys: Sendable {
        public var prefix: String
        public var keys: [KeyType: Data]

        public func name(_ type: KeyType) -> Data { keys[type] ?? Data() }
    }

    /// Creates one key of every type the test server supports under `prefix`:
    /// string, hash (3 fields), list (3), set (3), zset (3), stream (2 entries), JSON (object with 3 members),
    /// time series (3 samples), vector set (2 elements, dim 3).
    @discardableResult
    static func seedAllTypes(_ client: any RedisClient, prefix: String = "seed:") async throws -> SeededKeys {
        func key(_ suffix: String) -> Data { Data((prefix + suffix).utf8) }
        let keys: [KeyType: Data] = [
            .string: key("string"), .hash: key("hash"), .list: key("list"), .set: key("set"), .zset: key("zset"),
            .stream: key("stream"), .json: key("json"), .timeSeries: key("ts"), .vectorSet: key("vset"),
        ]
        func k(_ type: KeyType) -> RedisArgument { .data(keys[type] ?? Data()) }
        let commands: [[RedisArgument]] = [
            ["SET", k(.string), "hello"],
            ["HSET", k(.hash), "f1", "v1", "f2", "v2", "f3", "v3"],
            ["RPUSH", k(.list), "a", "b", "c"],
            ["SADD", k(.set), "x", "y", "z"],
            ["ZADD", k(.zset), "1", "one", "2", "two", "3", "three"],
            ["XADD", k(.stream), "1-1", "field", "value1"],
            ["XADD", k(.stream), "1-2", "field", "value2"],
            ["JSON.SET", k(.json), "$", #"{"name":"bike","price":10,"tags":["a","b"]}"#],
            ["TS.CREATE", k(.timeSeries), "LABELS", "sensor", "1"],
            ["TS.ADD", k(.timeSeries), "1000", "1.5"],
            ["TS.ADD", k(.timeSeries), "2000", "2.5"],
            ["TS.ADD", k(.timeSeries), "3000", "3.5"],
            ["VADD", k(.vectorSet), "VALUES", "3", "0.1", "0.2", "0.3", "e1"],
            ["VADD", k(.vectorSet), "VALUES", "3", "0.4", "0.5", "0.6", "e2"],
        ]
        let replies = try await client.pipeline(commands)
        if let error = replies.compactMap(\.errorValue).first { throw RedisClientError.server(error) }
        return SeededKeys(prefix: prefix, keys: keys)
    }

    /// `count` string keys `<prefix><i>` with value `v<i>` (pipelined in batches of 1 000).
    @discardableResult
    static func seedStrings(_ client: any RedisClient, prefix: String, count: Int) async throws -> [Data] {
        var names: [Data] = []
        var start = 0
        while start < count {
            let end = min(start + 1_000, count)
            let batch = (start..<end).map { i -> [RedisArgument] in ["SET", .string("\(prefix)\(i)"), .string("v\(i)")] }
            names += (start..<end).map { Data("\(prefix)\($0)".utf8) }
            _ = try await client.pipeline(batch)
            start = end
        }

        return names
    }

    /// Deletes every key matching `prefix*` (for tests that share DB 0).
    static func deleteKeys(_ client: any RedisClient, prefix: String) async throws {
        var cursor = "0"
        repeat {
            let reply = try await client.execute(["SCAN", .string(cursor), "MATCH", .string(KeyPattern.escape(prefix) + "*"),
                                                  "COUNT", "1000"])
            guard let items = reply.arrayValue, items.count == 2 else { return }
            cursor = items[0].stringValue ?? "0"
            let keys = (items[1].arrayValue ?? []).compactMap(\.dataValue)
            if !keys.isEmpty { _ = try await client.pipeline(keys.map { ["UNLINK", .data($0)] }) }
        } while cursor != "0"
    }
}
