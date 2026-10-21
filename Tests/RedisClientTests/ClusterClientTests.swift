import Foundation
import RedisClient
import RESP
import Testing

private let nodeA = RedisEndpoint(host: "127.0.0.1", port: 7000)
private let nodeB = RedisEndpoint(host: "127.0.0.1", port: 7001)

private func nodeEntry(_ endpoint: RedisEndpoint, id: String) -> RESPValue {
    .array([.bulk(endpoint.host), .integer(Int64(endpoint.port)), .bulk(id)])
}

private let slotsReply: RESPValue = .array([
    .array([.integer(0), .integer(8191), nodeEntry(nodeA, id: "a")]),
    .array([.integer(8192), .integer(16383), nodeEntry(nodeB, id: "b")]),
])

private func text(_ command: [Data]) -> String {
    command.map { String(decoding: $0, as: UTF8.self) }.joined(separator: " ")
}

private struct Fixture {
    let a: MockRedisClient
    let b: MockRedisClient
    let cluster: ClusterClient

    init(a aHandler: MockRedisClient.Handler? = nil, b bHandler: MockRedisClient.Handler? = nil,
         natMap: [RedisEndpoint: RedisEndpoint] = [:]) {
        let a = MockRedisClient(responses: ["CLUSTER SLOTS": slotsReply], handler: aHandler)
        let b = MockRedisClient(responses: ["CLUSTER SLOTS": slotsReply], handler: bHandler)
        let mocks: [RedisEndpoint: MockRedisClient] = [nodeA: a, nodeB: b]
        let reverse = Dictionary(uniqueKeysWithValues: natMap.map { ($0.value, $0.key) })
        self.a = a
        self.b = b
        cluster = ClusterClient(seeds: [nodeA], nodeConfig: RedisConnectionConfig(), natMap: natMap,
                                nodeClientFactory: { config in
                                    let announced = reverse[config.endpoint] ?? config.endpoint
                                    guard let mock = mocks[announced] else { throw RedisClientError.connectionFailed("no mock") }
                                    return mock
                                })
    }
}

struct ClusterRoutingTests {
    @Test func routesBySlot() async throws {
        let fixture = Fixture(a: { text($0) == "GET {b}x" ? .bulk("from-a") : nil },
                              b: { text($0) == "GET foo" ? .bulk("from-b") : nil })
        try await fixture.cluster.connect()
        #expect(ClusterSlot.slot(for: "foo") == 12182)
        #expect(ClusterSlot.slot(for: "{b}x") < 8192)
        #expect(try await fixture.cluster.execute(["GET", "foo"]) == .bulk("from-b"))
        #expect(try await fixture.cluster.execute(["GET", "{b}x"]) == .bulk("from-a"))
        #expect(await fixture.b.executedCommandStrings.contains("GET foo"))
        #expect(!(await fixture.a.executedCommandStrings.contains("GET foo")))
    }

    @Test func hashTagsColocate() async throws {
        let fixture = Fixture()
        try await fixture.cluster.connect()
        let keys = ["{user1000}.following", "{user1000}.followers", "{user1000}"]
        let owners = try await keys.asyncMap { try await fixture.cluster.owner(ofKey: Data($0.utf8)) }
        #expect(Set(owners).count == 1)
        #expect(ClusterSlot.slot(for: "{user1000}.following") == ClusterSlot.slot(for: "user1000"))
        #expect(ClusterSlot.slot(for: "{}.x") != ClusterSlot.slot(for: "x"))
        #expect(ClusterSlot.slot(for: "foo{}{bar}") == ClusterSlot.slot(for: "foo{}{bar}"))
        #expect(ClusterSlot.slot(for: "foo{{bar}}zap") == ClusterSlot.slot(for: "{bar"))
        #expect(ClusterSlot.slot(for: "123456789") == 12739)
    }

    @Test func followsMovedAndUpdatesSlotTable() async throws {
        let fixture = Fixture(a: { text($0) == "GET foo" ? .bulk("bar") : nil },
                              b: { text($0) == "GET foo" ? .error(RESPError("MOVED 12182 127.0.0.1:7000")) : nil })
        try await fixture.cluster.connect()
        #expect(try await fixture.cluster.execute(["GET", "foo"]) == .bulk("bar"))
        #expect(try await fixture.cluster.execute(["GET", "foo"]) == .bulk("bar"))
        let bGets = await fixture.b.executedCommandStrings.filter { $0 == "GET foo" }
        let aGets = await fixture.a.executedCommandStrings.filter { $0 == "GET foo" }
        #expect(bGets.count == 1)
        #expect(aGets.count == 2)
        #expect(try await fixture.cluster.owner(ofKey: Data("foo".utf8)) == nodeA)
    }

    @Test func followsAskWithoutUpdatingSlotTable() async throws {
        let fixture = Fixture(a: { text($0) == "GET foo" ? .bulk("migrating") : nil },
                              b: { text($0) == "GET foo" ? .error(RESPError("ASK 12182 127.0.0.1:7000")) : nil })
        try await fixture.cluster.connect()
        #expect(try await fixture.cluster.execute(["GET", "foo"]) == .bulk("migrating"))
        let aCommands = await fixture.a.executedCommandStrings
        let askingIndex = aCommands.firstIndex(of: "ASKING")
        #expect(askingIndex != nil)
        #expect(askingIndex.map { aCommands[$0 + 1] } == "GET foo")
        #expect(try await fixture.cluster.owner(ofKey: Data("foo".utf8)) == nodeB)
    }

    @Test func tooManyRedirections() async throws {
        let fixture = Fixture(a: { text($0) == "GET foo" ? .error(RESPError("MOVED 12182 127.0.0.1:7001")) : nil },
                              b: { text($0) == "GET foo" ? .error(RESPError("MOVED 12182 127.0.0.1:7000")) : nil })
        try await fixture.cluster.connect()
        await #expect(throws: RedisClientError.self) { _ = try await fixture.cluster.execute(["GET", "foo"]) }
    }

    @Test func pipelineGroupsByNodeAndKeepsOrder() async throws {
        let isGet: @Sendable ([Data]) -> Bool = { $0.count == 2 && $0[0] == Data("GET".utf8) }
        let fixture = Fixture(a: { isGet($0) ? .bulk("A:" + String(decoding: $0[1], as: UTF8.self)) : nil },
                              b: { isGet($0) ? .bulk("B:" + String(decoding: $0[1], as: UTF8.self)) : nil })
        try await fixture.cluster.connect()
        await fixture.a.resetRecording()
        await fixture.b.resetRecording()
        let keys = ["foo", "{b}1", "bar", "{b}2", "baz"]
        let replies = try await fixture.cluster.pipeline(keys.map { ["GET", .string($0)] })
        let expected = keys.map { key -> RESPValue in
            let owner = ClusterSlot.slot(for: key) < 8192 ? "A" : "B"
            return .bulk("\(owner):\(key)")
        }
        #expect(replies == expected, "\(replies) vs \(expected)")
        #expect(await fixture.a.batchCount == 1)
        #expect(await fixture.b.batchCount == 1)
    }

    @Test func pipelineRetriesMovedReplies() async throws {
        let fixture = Fixture(a: { text($0) == "GET foo" ? .bulk("bar") : nil },
                              b: { text($0) == "GET foo" ? .error(RESPError("MOVED 12182 127.0.0.1:7000")) : nil })
        try await fixture.cluster.connect()
        let replies = try await fixture.cluster.pipeline([["GET", "foo"], ["NOSUCH", "foo"]])
        #expect(replies[0] == .bulk("bar"))
        #expect(replies[1] == .null)
    }

    @Test func errorRepliesStayInPlace() async throws {
        let fixture = Fixture(b: { text($0) == "GET foo" ? .error(RESPError("WRONGTYPE nope")) : nil })
        try await fixture.cluster.connect()
        let replies = try await fixture.cluster.pipeline([["GET", "foo"]])
        #expect(replies[0].errorValue?.code == "WRONGTYPE")
        await #expect(throws: RedisClientError.self) { _ = try await fixture.cluster.execute(["GET", "foo"]) }
    }

    @Test func keylessCommandsGoToAPrimary() async throws {
        let fixture = Fixture(a: { text($0) == "DBSIZE" ? .integer(5) : nil })
        try await fixture.cluster.connect()
        #expect(try await fixture.cluster.execute(["DBSIZE"]) == .integer(5))
    }

    @Test func nodesAndExecuteOnNode() async throws {
        let fixture = Fixture(b: { text($0) == "INFO" ? .bulk("b-info") : nil })
        try await fixture.cluster.connect()
        let all = try await fixture.cluster.nodes()
        #expect(all.map(\.endpoint) == [nodeA, nodeB])
        #expect(try await fixture.cluster.nodes(role: .replica).isEmpty)
        #expect(all.first?.slots == [0...8191])
        #expect(try await fixture.cluster.send(["INFO"], to: nodeB) == .bulk("b-info"))
        await #expect(throws: RedisClientError.self) { _ = try await fixture.cluster.connection(for: nodeA) }
    }

    @Test func scanAllMasters() async throws {
        let fixture = Fixture(a: { $0.first.map { String(decoding: $0, as: UTF8.self) } == "SCAN" ? .array([.bulk("0"), .bulkArray(["k1", "k2"])]) : nil },
                              b: { $0.first.map { String(decoding: $0, as: UTF8.self) } == "SCAN" ? .array([.bulk("0"), .bulkArray(["k3"])]) : nil })
        try await fixture.cluster.connect()
        let keys = try await fixture.cluster.scanAllMasters(match: Data("k*".utf8), count: 100)
        #expect(keys[nodeA]?.count == 2)
        #expect(keys[nodeB] == [Data("k3".utf8)])
        #expect(await fixture.a.executedCommandStrings.contains("SCAN 0 MATCH k* COUNT 100"))
    }

    @Test func natMapRejectsUnknownNodes() async throws {
        let natMap = [nodeA: RedisEndpoint(host: "127.0.0.1", port: 17000), nodeB: RedisEndpoint(host: "127.0.0.1", port: 17001)]
        let fixture = Fixture(b: { text($0) == "GET foo" ? .error(RESPError("MOVED 12182 10.9.9.9:7005")) : nil },
                              natMap: natMap)
        try await fixture.cluster.connect()
        #expect(try await fixture.cluster.execute(["GET", "{b}1"]) == .null)
        do {
            _ = try await fixture.cluster.execute(["GET", "foo"])
            Issue.record("expected unavailable node")
        } catch let error as RedisClientError {
            guard case .clusterNodeUnavailable(let endpoint) = error else {
                Issue.record("unexpected \(error)")
                return
            }
            #expect(endpoint == RedisEndpoint(host: "10.9.9.9", port: 7005))
        }
    }

    @Test func transportFailureRefreshesTopology() async throws {
        let fixture = Fixture(b: { text($0) == "GET foo" ? .bulk("ok") : nil })
        try await fixture.cluster.connect()
        await fixture.b.setTransportError(.connectionClosed)
        await #expect(throws: RedisClientError.self) { _ = try await fixture.cluster.execute(["GET", "foo"]) }
        #expect(await fixture.a.executedCommandStrings.filter { $0 == "CLUSTER SLOTS" }.count >= 2)
        await fixture.b.setTransportError(nil)
        #expect(try await fixture.cluster.execute(["GET", "foo"]) == .bulk("ok"))
    }

    @Test func customKeyLocatorWins() async throws {
        let a = MockRedisClient(responses: ["CLUSTER SLOTS": slotsReply, "CUSTOM": .bulk("a")])
        let b = MockRedisClient(responses: ["CLUSTER SLOTS": slotsReply, "CUSTOM": .bulk("b")])
        let mocks = [nodeA: a, nodeB: b]
        let cluster = ClusterClient(seeds: [nodeA], nodeConfig: RedisConnectionConfig(),
                                    keyLocator: { args in String(decoding: args[0], as: UTF8.self) == "CUSTOM" ? 2 : nil },
                                    nodeClientFactory: { mocks[$0.endpoint]! })
        // args[2] = "foo" lives on B; args[1] = "{b}" would be A.
        #expect(try await cluster.execute(["CUSTOM", "{b}", "foo"]) == .bulk("b"))
    }

    @Test func closeClosesNodeClients() async throws {
        let fixture = Fixture()
        try await fixture.cluster.connect()
        _ = try await fixture.cluster.execute(["GET", "foo"])
        await fixture.cluster.close()
        #expect(await fixture.a.isClosed)
        #expect(await fixture.b.isClosed)
        await #expect(throws: RedisClientError.self) { _ = try await fixture.cluster.execute(["GET", "foo"]) }
    }

    @Test func nodeClientOpenedDuringCloseIsClosed() async throws {
        let a = MockRedisClient(responses: ["CLUSTER SLOTS": slotsReply])
        let b = MockRedisClient(responses: ["CLUSTER SLOTS": slotsReply])
        let gate = Gate()
        let cluster = ClusterClient(seeds: [nodeA], nodeConfig: RedisConnectionConfig(), nodeClientFactory: { config in
            guard config.endpoint == nodeB else { return a }
            await gate.pass()
            return b
        })
        try await cluster.connect()
        let pending = Task { try await cluster.execute(["GET", "foo"]) }
        await gate.waitUntilEntered()
        await cluster.close()
        await gate.open()
        do {
            _ = try await pending.value
            Issue.record("expected the closed cluster to refuse the command")
        } catch RedisClientError.notConnected {
        } catch {
            Issue.record("unexpected \(error)")
        }

        #expect(await b.isClosed)
        #expect(await b.executedCommandStrings.isEmpty)
    }
}

/// Holds callers of `pass()` until `open()`; `waitUntilEntered()` returns once a caller has arrived.
private actor Gate {
    private var isOpen = false
    private var entered = false
    private var held: [CheckedContinuation<Void, Never>] = []
    private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []

    func pass() async {
        entered = true
        arrivalWaiters.forEach { $0.resume() }
        arrivalWaiters.removeAll()
        guard !isOpen else { return }
        await withCheckedContinuation { held.append($0) }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { arrivalWaiters.append($0) }
    }

    func open() {
        isOpen = true
        held.forEach { $0.resume() }
        held.removeAll()
    }
}

struct ClusterParsingTests {
    @Test func keyLocator() {
        func idx(_ s: String) -> Int? { ClusterKeyLocator.keyIndex(s.split(separator: " ").map { Data($0.utf8) }) }
        #expect(idx("GET k") == 1)
        #expect(idx("set k v") == 1)
        #expect(idx("PING") == nil)
        #expect(idx("KEYS *") == nil)
        #expect(idx("SCAN 0") == nil)
        #expect(idx("INFO keyspace") == nil)
        #expect(idx("EVAL script 1 k a") == 3)
        #expect(idx("EVALSHA sha 0 a") == nil)
        #expect(idx("FCALL f 2 k1 k2") == 3)
        #expect(idx("XREAD COUNT 2 STREAMS s1 s2 0 0") == 4)
        #expect(idx("XREADGROUP GROUP g c STREAMS s >") == 5)
        #expect(idx("BITOP AND dest k1 k2") == 2)
        #expect(idx("MEMORY USAGE k") == 2)
        #expect(idx("MEMORY STATS") == nil)
        #expect(idx("OBJECT ENCODING k") == 2)
        #expect(idx("XINFO STREAM s") == 2)
        #expect(idx("ZUNION 2 a b") == 2)
        #expect(idx("ZUNIONSTORE dest 2 a b") == 1)
        #expect(idx("BLMPOP 0 1 k LEFT") == 3)
        #expect(idx("FT.SEARCH idx *") == nil)
        #expect(idx("SPUBLISH ch m") == 1)
        #expect(idx("PUBLISH ch m") == nil)
    }

    @Test func redirectParsing() {
        #expect(ClusterRedirect(RESPError("MOVED 3999 127.0.0.1:6381"), defaultHost: "x") == .moved(slot: 3999, endpoint: RedisEndpoint(host: "127.0.0.1", port: 6381)))
        #expect(ClusterRedirect(RESPError("ASK 1 :6381"), defaultHost: "seed") == .ask(slot: 1, endpoint: RedisEndpoint(host: "seed", port: 6381)))
        #expect(ClusterRedirect(RESPError("MOVED 5 ::1:7000"), defaultHost: "x")?.endpoint == RedisEndpoint(host: "::1", port: 7000))
        #expect(ClusterRedirect(RESPError("ERR nope"), defaultHost: "x") == nil)
        #expect(ClusterRedirect(RESPError("MOVED x y"), defaultHost: "x") == nil)
        #expect(ClusterRedirect(RESPError("MOVED 16384 127.0.0.1:7000"), defaultHost: "x") == nil)
        #expect(ClusterRedirect(RESPError("MOVED -1 127.0.0.1:7000"), defaultHost: "x") == nil)
        #expect(ClusterRedirect(RESPError("ASK 99999 127.0.0.1:7000"), defaultHost: "x") == nil)
        #expect(ClusterRedirect(RESPError("MOVED 16383 127.0.0.1:7000"), defaultHost: "x") != nil)
    }

    @Test func outOfRangeSlotRangesAreClampedOrDropped() {
        let slots: RESPValue = .array([
            .array([.integer(20000), .integer(30000), .array([.bulk("10.0.0.1"), .integer(7000), .bulk("m1")])]),
            .array([.integer(-5), .integer(-1), .array([.bulk("10.0.0.1"), .integer(7000), .bulk("m1")])]),
            .array([.integer(-5), .integer(10), .array([.bulk("10.0.0.2"), .integer(7001), .bulk("m2")])]),
            .array([.integer(16000), .integer(20000), .array([.bulk("10.0.0.2"), .integer(7001), .bulk("m2")])]),
        ])
        let nodes = ClusterTopologyParser.parseSlots(slots, seedHost: "seed")
        #expect(nodes.map(\.id) == ["m2"])
        #expect(nodes[0].slots == [0...10, 16000...16383])

        let nodeFields: [RESPValue] = [.bulk("id"), .bulk("n1"), .bulk("port"), .integer(7000), .bulk("ip"), .bulk("10.0.0.1"),
                                       .bulk("role"), .bulk("master")]
        let shard: RESPValue = .array([.bulk("slots"), .array([.integer(20000), .integer(30000), .integer(-3), .integer(4),
                                                               .integer(-9), .integer(-2)]),
                                       .bulk("nodes"), .array([.array(nodeFields)])])
        #expect(ClusterTopologyParser.parseShards(.array([shard]), seedHost: "seed", tls: false).first?.slots == [0...4])
    }

    @Test func malformedTopologyAndRedirectDoNotCrash() async throws {
        let malformed: RESPValue = .array([
            .array([.integer(20000), .integer(30000), nodeEntry(nodeB, id: "b")]),
            .array([.integer(0), .integer(16383), nodeEntry(nodeA, id: "a")]),
        ])
        let a = MockRedisClient(responses: ["CLUSTER SLOTS": malformed],
                                handler: { text($0) == "GET foo" ? .error(RESPError("MOVED 99999 127.0.0.1:7001")) : nil })
        let cluster = ClusterClient(seeds: [nodeA], nodeConfig: RedisConnectionConfig(), natMap: [:],
                                    nodeClientFactory: { config in
                                        guard config.endpoint == nodeA else { throw RedisClientError.connectionFailed("no mock") }
                                        return a
                                    })
        try await cluster.connect()
        #expect(try await cluster.owner(ofKey: Data("foo".utf8)) == nodeA)
        await #expect(throws: RedisClientError.self) { _ = try await cluster.execute(["GET", "foo"]) }
    }

    @Test func parsesClusterSlotsWithReplicasAndOddHosts() {
        let reply: RESPValue = .array([
            .array([.integer(0), .integer(5460),
                    .array([.bulk("10.0.0.1"), .integer(7000), .bulk("m1")]),
                    .array([.bulk("10.0.0.4"), .integer(7003), .bulk("r1")])]),
            .array([.integer(5461), .integer(10922),
                    .array([.bulk(""), .integer(7001), .bulk("m2")]),
                    .array([.bulk("?"), .integer(7004), .bulk("r2")])]),
            .array([.integer(10923), .integer(16383),
                    .array([.bulk("10.0.0.3"), .integer(7002)])]),
            .array([.integer(16000), .integer(16000), .array([.bulk("10.0.0.1"), .integer(7000), .bulk("m1")])]),
        ])
        let nodes = ClusterTopologyParser.parseSlots(reply, seedHost: "seed.local")
        #expect(nodes.map(\.id) == ["m1", "r1", "m2", "10.0.0.3:7002"])
        #expect(nodes[0].slots == [0...5460, 16000...16000])
        #expect(nodes[1].role == .replica && nodes[1].primaryID == "m1" && nodes[1].slots.isEmpty)
        #expect(nodes[2].endpoint == RedisEndpoint(host: "seed.local", port: 7001))
        #expect(nodes[3].role == .primary)
    }

    @Test func parsesClusterShardsResp2AndResp3() {
        let nodeFields: [RESPValue] = [.bulk("id"), .bulk("n1"), .bulk("port"), .integer(7000), .bulk("ip"), .bulk("10.0.0.1"),
                                       .bulk("endpoint"), .bulk("?"), .bulk("role"), .bulk("master"), .bulk("health"), .bulk("online")]
        let replicaFields: [RESPValue] = [.bulk("id"), .bulk("n2"), .bulk("tls-port"), .integer(8000), .bulk("ip"), .bulk("10.0.0.2"),
                                          .bulk("endpoint"), .bulk("node2.local"), .bulk("role"), .bulk("replica"), .bulk("health"), .bulk("loading")]
        let shard: RESPValue = .array([.bulk("slots"), .array([.integer(0), .integer(100), .integer(200), .integer(300)]),
                                       .bulk("nodes"), .array([.array(nodeFields), .array(replicaFields)])])
        let resp2 = ClusterTopologyParser.parseShards(.array([shard]), seedHost: "seed", tls: false)
        #expect(resp2.count == 2)
        #expect(resp2[0].endpoint == RedisEndpoint(host: "10.0.0.1", port: 7000))
        #expect(resp2[0].slots == [0...100, 200...300])
        #expect(resp2[1].endpoint == RedisEndpoint(host: "node2.local", port: 8000))
        #expect(resp2[1].primaryID == "n1")
        #expect(resp2[1].flags.contains("loading"))

        func toMap(_ items: [RESPValue]) -> RESPValue {
            .map(stride(from: 0, to: items.count, by: 2).map { (items[$0], items[$0 + 1]) })
        }

        let resp3Shard: RESPValue = toMap([.bulk("slots"), .array([.integer(0), .integer(100), .integer(200), .integer(300)]),
                                           .bulk("nodes"), .array([toMap(nodeFields), toMap(replicaFields)])])
        let resp3 = ClusterTopologyParser.parseShards(.array([resp3Shard]), seedHost: "seed", tls: false)
        #expect(resp3 == resp2)
    }

    @Test func clusterShardsPortFollowsTLSMode() {
        func port(_ ports: KeyValuePairs<String, Int64>, tls: Bool) -> Int? {
            var fields: [RESPValue] = [.bulk("id"), .bulk("n1"), .bulk("ip"), .bulk("10.0.0.1"), .bulk("role"), .bulk("master")]
            for (name, value) in ports { fields += [.bulk(name), .integer(value)] }
            let shard: RESPValue = .array([.bulk("slots"), .array([.integer(0), .integer(16383)]),
                                           .bulk("nodes"), .array([.array(fields)])])
            return ClusterTopologyParser.parseShards(.array([shard]), seedHost: "seed", tls: tls).first?.endpoint.port
        }

        #expect(port(["port": 6379, "tls-port": 6380], tls: true) == 6380)
        #expect(port(["port": 6379, "tls-port": 6380], tls: false) == 6379)
        #expect(port(["port": 0, "tls-port": 7443], tls: false) == 7443)
        #expect(port(["port": 0, "tls-port": 7443], tls: true) == 7443)
        #expect(port(["port": 7000, "tls-port": 0], tls: true) == 7000)
        #expect(port(["port": 0], tls: false) == nil)
        #expect(port(["port": 0, "tls-port": 70000], tls: true) == nil)
        #expect(port([:], tls: true) == nil)
    }

    @Test func clusterShardsFallbackUsesTheTLSPortOverTLS() async throws {
        let fields: [RESPValue] = [.bulk("id"), .bulk("n1"), .bulk("ip"), .bulk("127.0.0.1"), .bulk("port"), .integer(7000),
                                   .bulk("tls-port"), .integer(7443), .bulk("role"), .bulk("master")]
        let shards: RESPValue = .array([.array([.bulk("slots"), .array([.integer(0), .integer(16383)]),
                                                .bulk("nodes"), .array([.array(fields)])])])
        let seed = MockRedisClient(responses: ["CLUSTER SLOTS": .error(RESPError("ERR unknown subcommand")),
                                               "CLUSTER SHARDS": shards])
        let cluster = ClusterClient(seeds: [nodeA], nodeConfig: RedisConnectionConfig(tls: TLSConfig()),
                                    nodeClientFactory: { _ in seed })
        #expect(try await cluster.nodes().map(\.endpoint) == [RedisEndpoint(host: "127.0.0.1", port: 7443)])
    }
}

extension Array {
    func asyncMap<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
        var out: [T] = []
        for element in self { out.append(try await transform(element)) }
        return out
    }
}
