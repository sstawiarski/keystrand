import Foundation
@testable import CLIFeature
import RedisCore
import Testing

/// Hands out one mock client per endpoint and records which endpoints were dialed.
actor MockNodes {
    private var clients: [String: MockRedisClient] = [:]
    private(set) var dialed: [String] = []

    func client(for node: RedisEndpoint?) -> MockRedisClient {
        let key = node.map { "\($0.host):\($0.port)" } ?? "seed"
        dialed.append(key)
        if let existing = clients[key] { return existing }
        let created = MockRedisClient()
        clients[key] = created
        return created
    }

    func existing(_ key: String) -> MockRedisClient? { clients[key] }
}

/// Holds connector calls starting at `holdFrom` until `release()`.
actor ConnectGate {
    private let holdFrom: Int
    private(set) var calls = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(holdFrom: Int) {
        self.holdFrom = holdFrom
    }

    func arrive() async -> Int {
        calls += 1
        let call = calls
        if call >= holdFrom { await withCheckedContinuation { waiters.append($0) } }
        return call
    }

    var isHolding: Bool { !waiters.isEmpty }

    func release() {
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }

    func waitUntilHolding() async throws {
        for _ in 0..<200 where !isHolding {
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

struct CLISessionTests {
    private func makeSession(_ nodes: MockNodes, isCluster: Bool = true, db: Int = 0) -> CLISession {
        CLISession(connector: { node in
            CLISession.Link(client: await nodes.client(for: node), db: db)
        }, isCluster: isCluster, defaultHost: "10.0.0.1", initialDB: db)
    }

    @Test func followsMovedLikeRedisCLI() async throws {
        let nodes = MockNodes()
        let seed = await nodes.client(for: nil)
        await seed.setResponse(.error(RESPError("MOVED 12539 10.0.0.2:7002")), for: "GET")
        let target = await nodes.client(for: RedisEndpoint(host: "10.0.0.2", port: 7002))
        await target.setResponse(.bulk("v"), for: "GET")
        let session = makeSession(nodes)

        let reply = try await session.execute([Data("GET".utf8), Data("k".utf8)], commandLine: "GET k")
        #expect(reply.redirects == ["-> Redirected to slot [12539] located at 10.0.0.2:7002"])
        #expect(reply.text == "\"v\"")
        #expect(!reply.isError)
        #expect(await seed.isClosed)

        let again = try await session.execute([Data("GET".utf8), Data("k".utf8)], commandLine: "GET k")
        #expect(again.redirects.isEmpty)
        #expect(await target.executedCommandStrings == ["GET k", "GET k"])
    }

    @Test func askSendsAskingFirst() async throws {
        let nodes = MockNodes()
        let seed = await nodes.client(for: nil)
        await seed.setResponse(.error(RESPError("ASK 3999 :7003")), for: "SET")
        let target = await nodes.client(for: RedisEndpoint(host: "10.0.0.1", port: 7003))
        await target.setResponse(.ok, for: "SET")
        let session = makeSession(nodes)

        let reply = try await session.execute(["SET", "k", "v"].map { Data($0.utf8) }, commandLine: "SET k v")
        #expect(reply.redirects == ["-> Redirected to slot [3999] located at 10.0.0.1:7003"])
        #expect(await target.executedCommandStrings == ["ASKING", "SET k v"])
        #expect(reply.text == "\"OK\"")
    }

    @Test func stopsAfterTooManyRedirections() async throws {
        let nodes = MockNodes()
        let seed = await nodes.client(for: nil)
        await seed.setResponse(.error(RESPError("MOVED 1 10.0.0.1:7000")), for: "GET")
        let loop = await nodes.client(for: RedisEndpoint(host: "10.0.0.1", port: 7000))
        await loop.setResponse(.error(RESPError("MOVED 1 10.0.0.1:7000")), for: "GET")
        let session = makeSession(nodes)

        let reply = try await session.execute([Data("GET".utf8), Data("k".utf8)], commandLine: "GET k")
        #expect(reply.isError)
        #expect(reply.redirects.count == CLISession.maxRedirections)
    }

    @Test func standaloneDoesNotFollowRedirects() async throws {
        let nodes = MockNodes()
        let seed = await nodes.client(for: nil)
        await seed.setResponse(.error(RESPError("MOVED 1 10.0.0.1:7000")), for: "GET")
        let session = makeSession(nodes, isCluster: false)
        let reply = try await session.execute([Data("GET".utf8), Data("k".utf8)], commandLine: "GET k")
        #expect(reply.isError)
        #expect(reply.text == "MOVED 1 10.0.0.1:7000")
        #expect(await nodes.dialed == ["seed", "seed"])
    }

    @Test func selectIsTrackedAndRestoredOnReconnect() async throws {
        let nodes = MockNodes()
        let seed = await nodes.client(for: nil)
        await seed.setResponse(.ok, for: "SELECT")
        let session = makeSession(nodes, isCluster: false, db: 2)
        #expect(try await session.connect() == 2)
        let reply = try await session.execute([Data("SELECT".utf8), Data("5".utf8)], commandLine: "SELECT 5")
        #expect(reply.db == 5)

        await seed.setResponse(.error(RESPError("ERR DB index is out of range")), for: "SELECT 99")
        let failed = try await session.execute([Data("SELECT".utf8), Data("99".utf8)], commandLine: "SELECT 99")
        #expect(failed.isError)
        #expect(failed.db == 5)

        await seed.resetRecording()
        #expect(try await session.reconnect() == 5)
        #expect(await seed.executedCommandStrings == ["SELECT 5"])
    }

    @Test func clusterRedirectKeepsTheSelectedDatabase() async throws {
        let nodes = MockNodes()
        let seed = await nodes.client(for: nil)
        await seed.setResponse(.ok, for: "SELECT")
        await seed.setResponse(.error(RESPError("MOVED 15495 10.0.0.2:7003")), for: "GET")
        let target = await nodes.client(for: RedisEndpoint(host: "10.0.0.2", port: 7003))
        await target.setResponse(.ok, for: "SELECT")
        await target.setResponse(.bulk("v"), for: "GET")
        let session = makeSession(nodes, db: 0)

        #expect(try await session.execute([Data("SELECT".utf8), Data("2".utf8)], commandLine: "SELECT 2").db == 2)
        let reply = try await session.execute([Data("GET".utf8), Data("a".utf8)], commandLine: "GET a")
        #expect(reply.text == "\"v\"")
        #expect(reply.db == 2)
        #expect(await target.executedCommandStrings == ["SELECT 2", "GET a"])
    }

    @Test func clusterRedirectKeepsTheFirstConnectionsDatabase() async throws {
        let nodes = MockNodes()
        let seed = await nodes.client(for: nil)
        await seed.setResponse(.error(RESPError("MOVED 15495 10.0.0.2:7003")), for: "SET")
        let target = await nodes.client(for: RedisEndpoint(host: "10.0.0.2", port: 7003))
        await target.setResponse(.ok, for: "SELECT")
        await target.setResponse(.ok, for: "SET")
        let session = CLISession(connector: { node in
            CLISession.Link(client: await nodes.client(for: node), db: node == nil ? 2 : 1)
        }, isCluster: true, defaultHost: "10.0.0.1", initialDB: 2)

        #expect(try await session.connect() == 2)
        let reply = try await session.execute(["SET", "k", "v"].map { Data($0.utf8) }, commandLine: "SET k v")
        #expect(!reply.isError)
        #expect(reply.db == 2)
        #expect(await target.executedCommandStrings == ["SELECT 2", "SET k v"])
    }

    @Test func closeDuringConnectDiscardsTheNewConnection() async throws {
        let gate = ConnectGate(holdFrom: 1)
        let client = MockRedisClient(responses: ["PING": .simpleString("PONG")])
        let session = CLISession(connector: { _ in
            _ = await gate.arrive()
            return CLISession.Link(client: client, db: 0)
        }, isCluster: false, defaultHost: "127.0.0.1")
        let run = Task { try await session.execute([Data("PING".utf8)], commandLine: "PING") }
        try await gate.waitUntilHolding()
        await session.close()
        await gate.release()
        await #expect(throws: RedisClientError.self) { _ = try await run.value }
        #expect(await client.isClosed)
        #expect(await !session.isConnected)
        #expect(await client.executedCommands.isEmpty)
    }

    @Test func transportErrorsThrow() async throws {
        let nodes = MockNodes()
        let seed = await nodes.client(for: nil)
        await seed.setTransportError(.connectionClosed)
        let session = makeSession(nodes, isCluster: false)
        await #expect(throws: RedisClientError.self) {
            _ = try await session.execute([Data("PING".utf8)], commandLine: "PING")
        }
    }
}
