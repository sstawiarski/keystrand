import Foundation
import RedisClient
import RESP
import TestSupport
import Testing

private let failNodeA = RedisEndpoint(host: "127.0.0.1", port: 7100)
private let failNodeB = RedisEndpoint(host: "127.0.0.1", port: 7101)

private let failSlotsReply: RESPValue = .array([
    .array([.integer(0), .integer(8191), .array([.bulk("127.0.0.1"), .integer(7100), .bulk("a")])]),
    .array([.integer(8192), .integer(16383), .array([.bulk("127.0.0.1"), .integer(7101), .bulk("b")])]),
])

/// Node client that answers topology queries and fails the next `drops` other batches with `error`, after
/// "executing" them unless `beforeRunning`. Later batches succeed.
private actor DroppingClient: RedisClient {
    private(set) var received: [[String]] = []
    private var drops: Int
    let error: RedisClientError
    let beforeRunning: Bool

    init(drops: Int, error: RedisClientError = .connectionClosed, beforeRunning: Bool = false) {
        self.drops = drops
        self.error = error
        self.beforeRunning = beforeRunning
    }

    func execute(_ args: [RedisArgument]) async throws -> RESPValue {
        let reply = try await pipeline([args])[0]
        if case .error(let e) = reply { throw RedisClientError.server(e) }
        return reply
    }

    func pipeline(_ commands: [[RedisArgument]]) async throws -> [RESPValue] {
        let text = commands.map { $0.map { String(decoding: $0.data, as: UTF8.self) } }
        if text.first?.first == "CLUSTER" { return [failSlotsReply] }
        if drops > 0 {
            drops -= 1
            if !beforeRunning { received += text }
            throw error
        }

        received += text
        return text.map { _ in .simpleString("OK") }
    }

    func close() async {}

    var receivedCount: Int { received.count }
}

struct ClusterPipelineFailureTests {
    @Test func transportFailureIsNotResent() async throws {
        let a = DroppingClient(drops: 0)
        let b = DroppingClient(drops: .max)
        let cluster = ClusterClient(seeds: [failNodeA], nodeConfig: RedisConnectionConfig(),
                                    nodeClientFactory: { config in config.endpoint == failNodeA ? a : b })
        try await cluster.connect()
        #expect(ClusterSlot.slot(for: "foo") >= 8192)
        #expect(ClusterSlot.slot(for: "{b}x") < 8192)
        let replies = try await cluster.pipeline([["INCR", "foo"], ["INCR", "{b}x"], ["INCR", "foo"]])
        #expect(replies[0].errorValue?.message.hasPrefix("ERR ") == true)
        #expect(replies[1] == .simpleString("OK"))
        #expect(replies[2].errorValue != nil)
        #expect(await b.receivedCount == 2, "the dropped batch must not be re-executed")
        #expect(await a.receivedCount == 1)
    }

    @Test func throwsWhenEveryNodeFailed() async throws {
        let b = DroppingClient(drops: .max)
        let cluster = ClusterClient(seeds: [failNodeB], nodeConfig: RedisConnectionConfig(),
                                    nodeClientFactory: { _ in b })
        try await cluster.connect()
        await #expect(throws: RedisClientError.self) { _ = try await cluster.pipeline([["INCR", "foo"]]) }
        #expect(await b.receivedCount == 1)
    }
}

struct ClusterSendFailureTests {
    @Test(arguments: [RedisClientError.connectionClosed, .timeout, .protocolError("bad frame"), .cancelled,
                      .connectionFailed("read ECONNRESET")])
    func lostReplyIsNotResent(_ failure: RedisClientError) async throws {
        let a = DroppingClient(drops: 0)
        let b = DroppingClient(drops: 1, error: failure)
        let cluster = ClusterClient(seeds: [failNodeA], nodeConfig: RedisConnectionConfig(),
                                    nodeClientFactory: { config in config.endpoint == failNodeA ? a : b })
        try await cluster.connect()
        let thrown = await #expect(throws: RedisClientError.self) { _ = try await cluster.execute(["INCR", "foo"]) }
        #expect(thrown?.errorDescription == failure.errorDescription)
        #expect(await b.receivedCount == 1, "a command whose reply was lost must not run again")
        #expect(try await cluster.execute(["INCR", "foo"]) == .simpleString("OK"))
    }

    @Test func unsentCommandIsRetried() async throws {
        let a = DroppingClient(drops: 0)
        let b = DroppingClient(drops: 1, error: .notConnected, beforeRunning: true)
        let cluster = ClusterClient(seeds: [failNodeA], nodeConfig: RedisConnectionConfig(),
                                    nodeClientFactory: { config in config.endpoint == failNodeA ? a : b })
        try await cluster.connect()
        #expect(try await cluster.execute(["INCR", "foo"]) == .simpleString("OK"))
        #expect(await b.receivedCount == 1)
    }

    @Test func nodeConnectFailureIsRetried() async throws {
        let a = DroppingClient(drops: 0)
        let b = DroppingClient(drops: 0)
        let bConnects = Counter()
        let cluster = ClusterClient(seeds: [failNodeA], nodeConfig: RedisConnectionConfig(),
                                    nodeClientFactory: { config in
                                        guard config.endpoint == failNodeB else { return a }
                                        await bConnects.increment()
                                        if await bConnects.value == 1 {
                                            throw RedisClientError.connectionFailed("connect ECONNREFUSED")
                                        }
                                        return b
                                    })
        try await cluster.connect()
        #expect(try await cluster.execute(["INCR", "foo"]) == .simpleString("OK"))
        #expect(await b.receivedCount == 1)
        #expect(await bConnects.value == 2)
    }
}

private actor Counter {
    private(set) var value = 0
    func increment() { value += 1 }
}

@Suite(.serialized, .tags(.live), RedisTestServer.live(.redis))
struct ReconnectProviderLiveTests {
    @Test func providerRunsBeforeReconnectOnly() async throws {
        let config = RedisTestServer.connectionConfig(db: RedisTestServer.DB.redisClient)
        let connection = try await RedisConnection.connect(config: config)
        defer { Task { await connection.close() } }
        let calls = Counter()
        await connection.setReconnectProvider {
            await calls.increment()
            return config
        }
        #expect(try await connection.ping())
        #expect(await calls.value == 0)

        let id = try await connection.execute(["CLIENT", "ID"]).intValue ?? -1
        let killer = try await RedisTestServer.makeConnection(db: RedisTestServer.DB.redisClient)
        _ = try await killer.execute(["CLIENT", "KILL", "ID", .int(id)])
        await killer.close()
        try await Task.sleep(nanoseconds: 200_000_000)

        #expect(try await connection.ping())
        #expect(await calls.value == 1)
    }

    @Test func providerErrorFailsTheReconnect() async throws {
        let config = RedisTestServer.connectionConfig(db: RedisTestServer.DB.redisClient)
        let connection = try await RedisConnection.connect(config: config)
        defer { Task { await connection.close() } }
        await connection.setReconnectProvider { throw RedisClientError.ssh("tunnel down") }
        let id = try await connection.execute(["CLIENT", "ID"]).intValue ?? -1
        let killer = try await RedisTestServer.makeConnection(db: RedisTestServer.DB.redisClient)
        _ = try await killer.execute(["CLIENT", "KILL", "ID", .int(id)])
        await killer.close()
        try await Task.sleep(nanoseconds: 200_000_000)
        await #expect(throws: RedisClientError.self) { _ = try await connection.ping() }
    }
}
