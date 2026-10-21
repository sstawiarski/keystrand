import Foundation
@testable import AnalyticsFeature
import RedisCore
import TestSupport
import Testing

struct SlowLogParsingTests {
    static let reply: RESPValue = .array([
        .array([.integer(7), .integer(1_700_000_000), .integer(12_345), .bulkArray(["SET", "k", "v"]),
                .bulk("127.0.0.1:5000"), .bulk("worker")]),
        .array([.integer(6), .integer(1_699_999_990), .integer(15), .bulkArray(["PING"])]),
        .bulk("garbage"),
    ])

    @Test func parsesEntriesWithAndWithoutClientFields() {
        let entries = SlowLogParser.parseEntries(Self.reply, node: "n1:1")
        #expect(entries.count == 2)
        #expect(entries[0].entryID == 7)
        #expect(entries[0].args == "SET k v")
        #expect(entries[0].durationUs == 12_345)
        #expect(entries[0].clientText == "worker (127.0.0.1:5000)")
        #expect(entries[0].node == "n1:1")
        #expect(entries[1].clientText == "-")
        #expect(entries[0].id != entries[1].id)
    }

    @Test func parsesConfigPairsAndMaps() {
        let resp2 = SlowLogParser.parseConfig(.bulkArray(["slowlog-max-len", "256", "slowlog-log-slower-than", "-1"]))
        #expect(resp2 == SlowLogConfig(slowlogMaxLen: 256, slowlogLogSlowerThan: -1))
        let resp3 = SlowLogParser.parseConfig(.map([(.bulk("slowlog-max-len"), .bulk("x")), (.bulk("slowlog-log-slower-than"), .bulk("10000"))]))
        #expect(resp3 == SlowLogConfig(slowlogMaxLen: 0, slowlogLogSlowerThan: 10_000))
    }

    @Test func fetchConcatenatesNodesInOrderAndLabelsThem() async throws {
        let a = MockRedisClient(responses: ["SLOWLOG": Self.reply])
        let b = MockRedisClient(responses: ["SLOWLOG": .array([.array([.integer(1), .integer(5), .integer(9), .bulkArray(["GET", "x"])])])])
        let nodes = [NodeClient(endpoint: RedisEndpoint(host: "10.0.0.1", port: 7000), role: .primary, client: a),
                     NodeClient(endpoint: RedisEndpoint(host: "10.0.0.2", port: 7001), role: .replica, client: b)]
        let entries = try await SlowLogService.fetch(nodes: nodes, count: 25, labelNodes: true)
        #expect(entries.map(\.args) == ["SET k v", "PING", "GET x"])
        #expect(entries.last?.node == "10.0.0.2:7001")
        #expect(await a.executedCommandStrings == ["SLOWLOG GET 25"])
        let unlabeled = try await SlowLogService.fetch(nodes: Array(nodes.prefix(1)), count: 10, labelNodes: false)
        #expect(unlabeled.allSatisfy { $0.node == nil })
    }

    @Test func countValues() {
        #expect(SlowLogCount.fifty.value(maxLen: nil) == 50)
        #expect(SlowLogCount.max.value(maxLen: 300) == 300)
        #expect(SlowLogCount.max.value(maxLen: nil) == 128)
        #expect(SlowLogCount.max.value(maxLen: 0) == 1)
    }
}

struct SlowLogConfigFormTests {
    @Test func initFromConfigConvertsToUnit() {
        let config = SlowLogConfig(slowlogMaxLen: 128, slowlogLogSlowerThan: 10_500)
        #expect(SlowLogConfigForm(config: config, unit: .milliseconds).slowerThan == "10.5")
        #expect(SlowLogConfigForm(config: config, unit: .microseconds).slowerThan == "10500")
        #expect(SlowLogConfigForm(config: SlowLogConfig(slowlogMaxLen: 1, slowlogLogSlowerThan: -1), unit: .milliseconds).slowerThan == "-1")
    }

    @Test func validationAndMicroseconds() {
        var form = SlowLogConfigForm(slowerThan: "", unit: .milliseconds, maxLen: "")
        #expect(form.isValid)
        #expect(form.slowerThanMicroseconds == 10_000)
        #expect(form.maxLenValue == 128)

        form.slowerThan = "-1"
        #expect(form.slowerThanMicroseconds == -1)
        form.slowerThan = "2.5"
        #expect(form.slowerThanMicroseconds == 2_500)
        form.slowerThan = "-2"
        #expect(!form.isValid)
        #expect(form.slowerThanMicroseconds == nil)
        form.slowerThan = "1-2"
        #expect(!form.isValid)

        form.unit = .microseconds
        form.slowerThan = "2.5"
        #expect(!form.isValid)
        form.slowerThan = "750"
        #expect(form.slowerThanMicroseconds == 750)
        form.maxLen = "64"
        #expect(form.maxLenValue == 64)
    }

    @Test func conversionHint() {
        #expect(SlowLogConfigForm(slowerThan: "10", unit: .milliseconds).conversionHint == "10,000 µs")
        #expect(SlowLogConfigForm(slowerThan: "1500", unit: .microseconds).conversionHint == "1.5 ms")
        #expect(SlowLogConfigForm(slowerThan: "-1", unit: .microseconds).conversionHint == "-1 ms")
        #expect(SlowLogConfigForm(slowerThan: "", unit: .microseconds).conversionHint == "- ms")
    }

    @Test func sanitizersAndDefaults() {
        #expect(SlowLogConfigForm.sanitizeSlowerThan("1a-2.5x", unit: .microseconds) == "1-25")
        #expect(SlowLogConfigForm.sanitizeSlowerThan("1a-2.5x", unit: .milliseconds) == "1-2.5")
        #expect(SlowLogConfigForm.sanitizeMaxLen("-12ab3") == "123")
        var form = SlowLogConfigForm(slowerThan: "5", unit: .microseconds, maxLen: "9")
        form.applyDefaults()
        #expect(form == SlowLogConfigForm(slowerThan: "10", unit: .milliseconds, maxLen: "128"))
    }
}

struct ClusterParsingTests {
    static let nodesText = """
    07c37dfeb235213a872192d90877d0cd55635b91 127.0.0.1:30004@31004,hostname4 slave e7d1eecce10fd6bb5eb35b9f99a514335d9ba9ca 0 1426238317239 4 connected
    67ed2db8d677e59ec4a4cefb06858cf2a1a89fa1 127.0.0.1:30002@31002,hostname2 master - 0 1426238316232 2 connected 5461-10922
    292f8b365bb7edb5e285caf0b7e6ddc7265d2f4f 127.0.0.1:30003@31003 master,fail - 0 1426238318243 3 connected 10923-16383 [93->-abc]
    e7d1eecce10fd6bb5eb35b9f99a514335d9ba9ca :30001@31001 myself,master - 0 0 1 connected 0-5460
    9fd8800b31d569538917c0aaeaa5588e2f9c6edf 127.0.0.1:30005@31005 master,fail?,noflags - 0 0 1 connected
    """

    @Test func parsesClusterNodes() {
        let nodes = ClusterDetailsParser.parseClusterNodes(Self.nodesText, seedHost: "seed.local")
        #expect(nodes.count == 5)
        #expect(nodes[0].role == .replica)
        #expect(nodes[0].primaryID == "e7d1eecce10fd6bb5eb35b9f99a514335d9ba9ca")
        #expect(nodes[0].endpoint == "127.0.0.1:30004")
        #expect(nodes[1].slots == ["5461-10922"])
        #expect(nodes[2].health == .offline)
        #expect(nodes[2].slots == ["10923-16383"])
        #expect(nodes[3].host == "seed.local")
        #expect(nodes[3].health == .online)
        #expect(nodes[4].health == .online)
    }

    @Test func parsesClusterShards() {
        func node(_ fields: [(String, RESPValue)]) -> RESPValue {
            .array(fields.flatMap { [RESPValue.bulk($0.0), $0.1] })
        }

        let reply: RESPValue = .array([
            .array([
                .bulk("slots"), .array([.integer(0), .integer(5460), .integer(6000), .integer(6000)]),
                .bulk("nodes"), .array([
                    node([("id", .bulk("p1")), ("port", .integer(7000)), ("ip", .bulk("10.0.0.1")), ("endpoint", .bulk("?")),
                          ("role", .bulk("master")), ("health", .bulk("online"))]),
                    node([("id", .bulk("r1")), ("tls-port", .integer(7100)), ("ip", .bulk("")), ("endpoint", .bulk("")),
                          ("role", .bulk("slave")), ("health", .bulk("loading"))]),
                ]),
            ]),
        ])
        let nodes = ClusterDetailsParser.parseClusterShards(reply, seedHost: "seed")
        #expect(nodes.count == 2)
        #expect(nodes[0].endpoint == "10.0.0.1:7000")
        #expect(nodes[0].slots == ["0-5460", "6000"])
        #expect(nodes[1].endpoint == "seed:7100")
        #expect(nodes[1].role == .replica)
        #expect(nodes[1].primaryID == "p1")
        #expect(nodes[1].health == .loading)
    }

    @Test func parsesClusterInfo() {
        let info = ClusterDetailsParser.parseClusterInfo("cluster_state:ok\r\ncluster_slots_assigned:16000\r\ncluster_slots_ok:16000\r\ncluster_known_nodes:6\r\ncluster_size:3\r\ncluster_current_epoch:6\r\n")
        #expect(info.state == "ok")
        #expect(info.slotsAssigned == 16_000)
        #expect(info.slotsUnassigned == 384)
        #expect(info.knownNodes == 6)
        #expect(info.size == 3)
        #expect(info.currentEpoch == 6)
    }

    @Test func nodeMetricsFromInfo() {
        let info = ServerInfoParser.parse("""
        # Server\r\nredis_version:7.2.4\r\nredis_mode:cluster\r\nuptime_in_seconds:3600\r\n# Clients\r\nconnected_clients:12\r\n\
        # Memory\r\nused_memory:2048\r\n# Stats\r\ninstantaneous_ops_per_sec:42\r\ninstantaneous_input_kbps:1.25\r\n\
        instantaneous_output_kbps:3.5\r\nkeyspace_hits:3\r\nkeyspace_misses:1\r\ntotal_commands_processed:99\r\n\
        # Replication\r\nmaster_repl_offset:500\r\n# Keyspace\r\ndb0:keys=10,expires=0,avg_ttl=0\r\ndb1:keys=5,expires=0,avg_ttl=0\r\n
        """)
        let metrics = ClusterDetailsParser.metrics(from: info)
        #expect(metrics.totalKeys == 15)
        #expect(metrics.usedMemory == 2_048)
        #expect(metrics.opsPerSecond == 42)
        #expect(metrics.connectedClients == 12)
        #expect(metrics.networkInKbps == 1.25)
        #expect(metrics.networkOutKbps == 3.5)
        #expect(metrics.cacheHitRatio == 0.75)
        #expect(metrics.replicationOffset == 500)
        #expect(metrics.uptimeSec == 3_600)
        #expect(metrics.version == "7.2.4")
        #expect(metrics.mode == "cluster")
        #expect(ClusterDetailsParser.metrics(from: ServerInfoParser.parse("")).cacheHitRatio == nil)
    }

    @Test func valkeyNodeReportsItsRealVersion() {
        let info = ServerInfoParser.parse(
            ValkeyFixtures.serverInfo + "redis_mode:cluster\r\n")
        let metrics = ClusterDetailsParser.metrics(from: info)
        #expect(metrics.version == "9.1.2")
        #expect(metrics.serverFlavor == .valkey)
        let topology = [ClusterTopologyNode(id: "p1", host: "10.0.0.1", port: 7000, role: .primary, slots: ["0-16383"])]
        let details = ClusterDetailsParser.assemble(topology: topology, metrics: ["10.0.0.1:7000": metrics],
                                                    info: ClusterInfoSummary(), user: nil)
        #expect(details.versionText == "Valkey 9.1.2")
    }

    @Test func lettersAndUniqueMax() {
        #expect(ClusterDetailsParser.letter(for: 0) == "A")
        #expect(ClusterDetailsParser.letter(for: 25) == "Z")
        #expect(ClusterDetailsParser.letter(for: 26) == "AA")
        #expect(ClusterDetailsParser.letter(for: 27) == "AB")
        #expect(ClusterDetailsParser.letter(for: 701) == "ZZ")
        #expect(ClusterDetailsParser.letter(for: 702) == "AAA")
        #expect(ClusterDetailsParser.uniqueMaxIndex([1, 3, 2]) == 1)
        #expect(ClusterDetailsParser.uniqueMaxIndex([3, 1, 3]) == nil)
        #expect(ClusterDetailsParser.uniqueMaxIndex([Int]()) == nil)
    }

    @Test func assembleSortsLettersAndNestsReplicas() {
        let topology = [
            ClusterTopologyNode(id: "p2", host: "10.0.0.2", port: 7000, role: .primary, slots: ["5461-16383"]),
            ClusterTopologyNode(id: "p1", host: "10.0.0.1", port: 7000, role: .primary, slots: ["0-5460"]),
            ClusterTopologyNode(id: "r1", host: "10.0.0.3", port: 7000, role: .replica, primaryID: "p1"),
            ClusterTopologyNode(id: "p3", host: "10.0.0.9", port: 7000, role: .primary),
        ]
        var m1 = ClusterNodeMetrics(); m1.uptimeSec = 10; m1.replicationOffset = 100; m1.version = "7.2.0"
        var m2 = ClusterNodeMetrics(); m2.uptimeSec = 50
        var r1 = ClusterNodeMetrics(); r1.replicaOffset = 90
        let details = ClusterDetailsParser.assemble(
            topology: topology, metrics: ["10.0.0.1:7000": m1, "10.0.0.2:7000": m2, "10.0.0.3:7000": r1],
            info: ClusterInfoSummary(), user: nil)
        #expect(details.primaries.map(\.endpoint) == ["10.0.0.1:7000", "10.0.0.2:7000"])
        #expect(details.primaries.map(\.letter) == ["A", "B"])
        #expect(details.primaries[0].replicas?.first?.replicationLag == 10)
        #expect(details.primaries[0].replicas?.first?.letter == "A")
        #expect(details.primaries[1].replicas == nil)
        #expect(details.uptimeSec == 50)
        #expect(details.version == "7.2.0")
        #expect(details.versionText == "Redis 7.2.0")
    }

    @Test func collectMetricsMatchesConnections() async {
        let info = RESPValue.bulk("used_memory:100\r\nconnected_clients:3\r\n")
        let clients = [
            NodeClient(endpoint: RedisEndpoint(host: "10.0.0.1", port: 7000), role: .primary, client: MockRedisClient(responses: ["INFO": info])),
            NodeClient(endpoint: RedisEndpoint(host: "public.host", port: 7001), role: .primary, client: MockRedisClient(responses: ["INFO": info])),
        ]
        let topology = [
            ClusterTopologyNode(id: "a", host: "10.0.0.1", port: 7000, role: .primary),
            ClusterTopologyNode(id: "b", host: "172.16.0.2", port: 7001, role: .primary),
            ClusterTopologyNode(id: "c", host: "172.16.0.3", port: 7002, role: .primary),
        ]
        let metrics = await ClusterDetailsService.collectMetrics(topology: topology, clients: clients)
        #expect(Set(metrics.keys) == ["10.0.0.1:7000", "172.16.0.2:7001"])
        #expect(metrics["10.0.0.1:7000"]?.usedMemory == 100)
    }
}

@MainActor
struct ClusterViewModelMockTests {
    @Test func nonClusterSessionDoesNotFetch() async {
        let client = MockRedisClient()
        let session = RedisTestServer.mockSession(client)
        let model = ClusterDetailsViewModel(session: session)
        #expect(!model.isCluster)
        await model.refresh(manual: true)
        #expect(model.details == nil)
        #expect(await client.executedCommandStrings.isEmpty)
        #expect(model.primaryNodesHeader == "0 Primary nodes")
        #expect(model.userText == "Default")
        await #expect(throws: ClusterDetailsError.notCluster) { try await ClusterDetailsService(session: session).fetch() }
    }
}

struct AnalyzerMockTests {
    static func node(_ host: String, keys: [String], info: String) -> NodeClient {
        let client = MockRedisClient { args in
            let command = String(decoding: args.first ?? Data(), as: UTF8.self).uppercased()
            switch command {
            case "DBSIZE": return .integer(Int64(keys.count))
            case "INFO": return .bulk(info)
            case "SCAN": return .array([.bulk("0"), .bulkArray(keys)])
            case "MEMORY": return .integer(64)
            case "TYPE": return .simpleString("string")
            case "TTL": return .integer(-1)
            case "STRLEN": return .integer(3)
            default: return .null
            }
        }
        return NodeClient(endpoint: RedisEndpoint(host: host, port: 7000), role: .primary, client: client)
    }

    @Test func clusterRunMergesNodesAndDedupesRecommendations() async throws {
        let info = "redis_version:6.2.0\r\nconnected_clients:500\r\n"
        let nodes = [Self.node("a", keys: (0..<6).map { "a:\($0)" }, info: info),
                     Self.node("b", keys: (0..<6).map { "b:\($0)" }, info: info)]
        let context = DatabaseAnalyzer.Context(databaseId: DatabaseID(), db: 0, isCluster: true, delimiter: ":",
                                               filter: AnalysisFilter())
        let report = try await DatabaseAnalyzer.run(nodes: nodes, routed: MockRedisClient(), context: context) { _ in }
        #expect(report.progress.total == 12)
        #expect(report.progress.processed == 12)
        #expect(report.totalKeys.total == 12)
        #expect(report.totalMemory.total == 12 * 64)
        #expect(report.topKeysNsp.map(\.keys) == [6, 6])
        #expect(report.topKeysLength.first?.length == 3)
        let names = report.recommendations.map(\.name)
        #expect(names.filter { $0 == "redisVersion" }.count == 1)
        #expect(names.filter { $0 == "bigAmountOfConnectedClients" }.count == 1)
        #expect(names.filter { $0 == "combineSmallStringsToHashes" }.isEmpty)
    }

    @Test func scanStopsAtFilterCount() async throws {
        let client = MockRedisClient { args in
            let command = String(decoding: args.first ?? Data(), as: UTF8.self).uppercased()
            guard command == "SCAN" else { return nil }
            let cursor = Int(String(decoding: args[1], as: UTF8.self)) ?? 0
            return .array([.bulk("\(cursor + 1)"), .bulkArray(["k\(cursor)", "k\(cursor)"])])
        }
        let node = NodeClient(endpoint: RedisEndpoint(host: "h", port: 1), role: .primary, client: client)
        let names = try await DatabaseAnalyzer.scanKeys(node, filter: AnalysisFilter(count: 10_000)) { _ in }
        #expect(names.count == 5)
        #expect(await client.executedCommandStrings.first == "SCAN 0 COUNT 2000 MATCH *")
        let small = try await DatabaseAnalyzer.scanKeys(node, filter: AnalysisFilter(count: 3)) { _ in }
        #expect(small.count == 1)
    }

    @Test func lengthCommandsPerType() {
        let key = Data("k".utf8)
        #expect(DatabaseAnalyzer.lengthCommand(for: "hash", key: key) == ["HLEN", .data(key)])
        #expect(DatabaseAnalyzer.lengthCommand(for: "TSDB-TYPE", key: key) == ["TS.INFO", .data(key)])
        #expect(DatabaseAnalyzer.lengthCommand(for: "vectorset", key: key) == nil)
        #expect(DatabaseAnalyzer.jsonLengthCommand(jsonType: "array", key: key) == ["JSON.ARRLEN", .data(key)])
        #expect(DatabaseAnalyzer.jsonLengthCommand(jsonType: "integer", key: key) == nil)
        #expect(DatabaseAnalyzer.jsonTypeName(.bulkArray(["object"])) == "object")
        #expect(DatabaseAnalyzer.timeSeriesSamples(.array([.bulk("totalSamples"), .integer(7), .bulk("memoryUsage"), .integer(1)])) == 7)
        #expect(DatabaseAnalyzer.parseConfigPair(.bulkArray(["set-max-intset-entries", "512"]))?.1 == 512)
        #expect(DatabaseAnalyzer.parseConfigPair(.bulkArray([])) == nil)
    }
}
