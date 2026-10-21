import Foundation
import RedisClient
import RESP
import Synchronization
import TestSupport
import Testing

private let robustA = RedisEndpoint(host: "127.0.0.1", port: 7200)
private let robustB = RedisEndpoint(host: "127.0.0.1", port: 7201)

private func slots(_ ranges: [(Int, Int, RedisEndpoint)]) -> RESPValue {
    .array(ranges.map { start, end, node in
        .array([.integer(Int64(start)), .integer(Int64(end)),
                .array([.bulk(node.host), .integer(Int64(node.port)), .bulk(node.description)])])
    })
}

private let splitSlots = slots([(0, 8191, robustA), (8192, 16383, robustB)])
private let allOnA = slots([(0, 16383, robustA)])

private func commandText(_ command: [Data]) -> String {
    command.map { String(decoding: $0, as: UTF8.self) }.joined(separator: " ")
}

private func keysOnB(_ count: Int) -> [String] {
    (0..<10_000).lazy.map { "key:\($0)" }.filter { ClusterSlot.slot(for: $0) >= 8192 }.prefix(count).map { $0 }
}

struct ClusterRobustnessTests {
    @Test func movedPipelineIsRegroupedAfterOneRefresh() async throws {
        let a = MockRedisClient(responses: ["CLUSTER SLOTS": allOnA],
                                handler: { $0.first == Data("GET".utf8) ? .bulk("A:" + String(decoding: $0[1], as: UTF8.self)) : nil })
        await a.enqueue([splitSlots], for: "CLUSTER SLOTS")
        let b = MockRedisClient(responses: ["CLUSTER SLOTS": allOnA], handler: { command in
            guard command.first == Data("GET".utf8) else { return nil }
            return .error(RESPError("MOVED \(ClusterSlot.slot(for: command[1])) 127.0.0.1:7200"))
        })
        let mocks = [robustA: a, robustB: b]
        let cluster = ClusterClient(seeds: [robustA], nodeConfig: RedisConnectionConfig(),
                                    nodeClientFactory: { config in
                                        guard let mock = mocks[config.endpoint] else { throw RedisClientError.notConnected }
                                        return mock
                                    })
        try await cluster.connect()
        let keys = keysOnB(40)
        await a.resetRecording()
        let replies = try await cluster.pipeline(keys.map { ["GET", .string($0)] })
        #expect(replies == keys.map { .bulk("A:\($0)") })
        let getBatches = await a.batchCount - a.executedCommandStrings.filter { $0 == "CLUSTER SLOTS" }.count
        #expect(getBatches == 1, "the moved commands go to the new owner in one pipeline")
        #expect(await b.batchCount >= 1)
    }

    @Test func droppedNodeClientStaysOpenUntilTheClusterCloses() async throws {
        let a = MockRedisClient(responses: ["CLUSTER SLOTS": splitSlots])
        let b = MockRedisClient(responses: ["CLUSTER SLOTS": splitSlots, "GET": .bulk("b")])
        let mocks = [robustA: a, robustB: b]
        let cluster = ClusterClient(seeds: [robustA], nodeConfig: RedisConnectionConfig(),
                                    nodeClientFactory: { config in
                                        guard let mock = mocks[config.endpoint] else { throw RedisClientError.notConnected }
                                        return mock
                                    })
        try await cluster.connect()
        let held = try await cluster.client(for: robustB)
        await b.setTransportError(.connectionClosed)
        _ = try? await cluster.pipeline([["GET", .string(keysOnB(1)[0])]])
        #expect(await !b.isClosed, "a caller holding the node client keeps using it")
        await b.setTransportError(nil)
        #expect(try await held.execute(["GET", "x"]) == .bulk("b"))
        await cluster.close()
        #expect(await b.isClosed)
    }

    @Test func tryAgainBacksOffAndRetries() async throws {
        let a = MockRedisClient(responses: ["CLUSTER SLOTS": allOnA, "GET foo": .bulk("bar")])
        await a.enqueue([.error(RESPError("TRYAGAIN Multiple keys request during rehashing of slot"))], for: "GET foo")
        let cluster = ClusterClient(seeds: [robustA], nodeConfig: RedisConnectionConfig(), nodeClientFactory: { _ in a })
        try await cluster.connect()
        let started = ContinuousClock.now
        #expect(try await cluster.execute(["GET", "foo"]) == .bulk("bar"))
        #expect(ContinuousClock.now - started >= .milliseconds(90), "TRYAGAIN waits before retrying")
        #expect(await a.executedCommandStrings.filter { $0 == "GET foo" }.count == 2)
    }

    @Test func clusterDownGivesUpAfterTheRetries() async throws {
        let a = MockRedisClient(responses: ["CLUSTER SLOTS": allOnA,
                                            "GET foo": .error(RESPError("CLUSTERDOWN The cluster is down"))])
        let cluster = ClusterClient(seeds: [robustA], nodeConfig: RedisConnectionConfig(), maxRedirections: 2,
                                    nodeClientFactory: { _ in a })
        try await cluster.connect()
        do {
            _ = try await cluster.execute(["GET", "foo"])
            Issue.record("expected CLUSTERDOWN")
        } catch let error as RedisClientError {
            #expect(error.serverError?.code == "CLUSTERDOWN")
        }

        #expect(await a.executedCommandStrings.filter { $0 == "GET foo" }.count == 3)
        let replies = try await cluster.pipeline([["GET", "foo"]])
        #expect(replies[0].errorValue?.code == "CLUSTERDOWN")
    }

    @Test func topologyLoadSurvivesNoPermOnClusterCommands() async throws {
        let noPerm = RESPValue.error(RESPError("NOPERM User limited has no permissions to run the 'cluster|slots' command"))
        let a = MockRedisClient(responses: ["CLUSTER SLOTS": noPerm, "CLUSTER SHARDS": noPerm], handler: { command in
            guard command.first == Data("GET".utf8) else { return nil }
            let slot = ClusterSlot.slot(for: command[1])
            return slot >= 8192 ? .error(RESPError("MOVED \(slot) 127.0.0.1:7201")) : .bulk("a")
        })
        let b = MockRedisClient(responses: ["GET": .bulk("b")])
        let mocks = [robustA: a, robustB: b]
        let cluster = ClusterClient(seeds: [robustA], nodeConfig: RedisConnectionConfig(),
                                    nodeClientFactory: { config in
                                        guard let mock = mocks[config.endpoint] else { throw RedisClientError.notConnected }
                                        return mock
                                    })
        try await cluster.connect()
        #expect(try await cluster.nodes().map(\.endpoint) == [robustA])
        let onB = keysOnB(1)[0]
        #expect(try await cluster.execute(["GET", .string(onB)]) == .bulk("b"))
        #expect(try await cluster.owner(ofKey: Data(onB.utf8)) == robustB)
    }

    @Test func otherClusterErrorsStillFailTheTopologyLoad() async throws {
        let disabled = RESPValue.error(RESPError("ERR This instance has cluster support disabled"))
        let a = MockRedisClient(responses: ["CLUSTER SLOTS": disabled, "CLUSTER SHARDS": disabled])
        let cluster = ClusterClient(seeds: [robustA], nodeConfig: RedisConnectionConfig(), nodeClientFactory: { _ in a })
        await #expect(throws: RedisClientError.self) { try await cluster.connect() }
    }
}

struct TransportHelperTests {
    @Test func sshArgumentsEndOptionsBeforeTheHost() {
        let options = SSHTunnelOptions(sshHost: "-oProxyCommand=evil", username: "u", auth: .password("p"),
                                       remoteHost: "10.0.0.1", remotePort: 6379)
        let args = SSHTunnel.arguments(options: options, localPort: 4000, keyPath: nil, usesAskpass: true)
        #expect(Array(args.suffix(2)) == ["--", "-oProxyCommand=evil"])
    }

    @Test func deadlineThrowsTimeoutWithoutWaitingForTheOperation() async throws {
        let started = ContinuousClock.now
        await #expect(throws: RedisClientError.self) {
            try await withDeadline(seconds: 0.1) {
                try await Task.sleep(for: .seconds(3))
                return 1
            }
        }
        #expect(ContinuousClock.now - started < .seconds(2))
        #expect(try await withDeadline(seconds: 2) { 42 } == 42)
    }

    @Test func unansweredRequestDropsTheSocketAndTheNextCommandReconnects() async throws {
        let silent = Locked(true)
        let server = try await FakeRedisServer.start { command in
            if command.first?.uppercased() == "GET", silent.value {
                try? await Task.sleep(for: .seconds(30))
            }

            return nil
        }
        defer { server.stop() }
        let config = RedisConnectionConfig(host: "127.0.0.1", port: server.port, connectTimeout: 2, commandTimeout: 0.3,
                                           readyCheck: false, retry: .none)
        let connection = try await RedisConnection.connect(config: config)
        defer { Task { await connection.close() } }
        let started = ContinuousClock.now
        do {
            _ = try await connection.execute(["GET", "k"])
            Issue.record("expected a timeout")
        } catch RedisClientError.timeout {
        }

        #expect(ContinuousClock.now - started < .seconds(5))
        #expect(await !connection.isConnected, "the stuck socket is dropped")
        silent.value = false
        #expect(try await connection.ping())
        #expect(server.received("PING").count == 1)
    }
}

/// Fake Sentinel and Redis nodes. The Sentinel reports `masters` in order, repeating the last entry.
private final class SentinelFixture: Sendable {
    let sentinel: FakeRedisServer
    let master: FakeRedisServer
    let replica: FakeRedisServer
    private let answers = Locked<[Int]>([])

    init() async throws {
        let master = try await FakeRedisServer.start { command in
            command.first?.uppercased() == "ROLE" ? .array([.bulk("master"), .integer(0), .array([])]) : nil
        }
        let replica = try await FakeRedisServer.start { command in
            command.first?.uppercased() == "ROLE" ? .array([.bulk("slave"), .bulk("127.0.0.1"), .integer(1)]) : nil
        }
        let answers = self.answers
        sentinel = try await FakeRedisServer.start { command in
            guard command.count == 3, command[1].uppercased() == "GET-MASTER-ADDR-BY-NAME" else { return nil }
            let port = answers.update { list in list.count > 1 ? list.removeFirst() : (list.first ?? 0) }
            return .array([.bulk("127.0.0.1"), .bulk(String(port))])
        }
        self.master = master
        self.replica = replica
    }

    func answer(_ servers: [FakeRedisServer]) {
        answers.value = servers.map(\.port)
    }

    var descriptor: RedisClientDescriptor {
        RedisClientDescriptor(topology: .sentinel(masterName: "mymaster", sentinels: [sentinel.endpoint],
                                                  sentinelUsername: nil, sentinelPassword: nil),
                              connection: RedisConnectionConfig(host: "127.0.0.1", port: sentinel.port, connectTimeout: 2))
    }

    func stop() {
        sentinel.stop()
        master.stop()
        replica.stop()
    }
}

@Suite(.serialized)
struct SentinelFailoverTests {
    @Test func connectToMasterSkipsAReplicaAndReconnectChecksTheRoleAgain() async throws {
        let fixture = try await SentinelFixture()
        defer { fixture.stop() }
        fixture.answer([fixture.replica, fixture.master])
        let client = try await RedisClientFactory().makeClient(fixture.descriptor)
        defer { Task { await client.close() } }
        let connection = try #require(client as? RedisConnection)
        #expect(await connection.config.port == fixture.master.port)
        #expect(fixture.replica.received("ROLE").count == 1)
        #expect(try await connection.ping())

        fixture.answer([fixture.replica, fixture.master])
        fixture.master.dropConnections()
        try await Task.sleep(for: .milliseconds(200))
        #expect(try await connection.ping())
        #expect(fixture.replica.received("ROLE").count == 2, "the reconnect asked the replica for its role")
        #expect(fixture.replica.received("PING").isEmpty, "no command ran on the replica")
        #expect(fixture.master.received("PING").count == 2)
        #expect(fixture.sentinel.received("SENTINEL").count >= 4)
    }
}

private final class Locked<Value: Sendable>: Sendable {
    private let state: Mutex<Value>

    init(_ value: Value) {
        state = Mutex(value)
    }

    var value: Value {
        get { state.withLock { $0 } }
        set { state.withLock { $0 = newValue } }
    }

    func update<T: Sendable>(_ body: (inout Value) -> T) -> T {
        state.withLock { body(&$0) }
    }
}
