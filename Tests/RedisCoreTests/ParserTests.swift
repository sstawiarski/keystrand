import Foundation
@testable import RedisCore
import TestSupport
import Testing

struct ServerInfoTests {
    static let sample = """
    # Server\r
    redis_version:8.10.2\r
    redis_mode:standalone\r
    executable:/usr/local/bin/redis-server\r
    uptime_in_seconds:100\r
    \r
    # Clients\r
    connected_clients:4\r
    \r
    # Memory\r
    used_memory:2048\r
    \r
    # Stats\r
    instantaneous_ops_per_sec:12\r
    instantaneous_input_kbps:1.5\r
    instantaneous_output_kbps:2.5\r
    keyspace_hits:3\r
    keyspace_misses:1\r
    \r
    # Replication\r
    role:master\r
    \r
    # CPU\r
    used_cpu_sys:10.0\r
    used_cpu_user:5.0\r
    \r
    # Keyspace\r
    db0:keys=10,expires=1,avg_ttl=0\r
    db3:keys=5,expires=0,avg_ttl=0\r
    """

    @Test func parsesSections() {
        let info = ServerInfoParser.parse(Self.sample)
        #expect(info.redisVersion == "8.10.2")
        #expect(info["clients"]?["connected_clients"] == "4")
        #expect(info.usedMemory == 2048)
        #expect(info.keyspace[3]?.keys == 5)
        #expect(info.keyspace[0]?.expires == 1)
        let general = DatabaseInfoService.generalInfo(from: info, databases: 16)
        #expect(general.totalKeys == 15)
        #expect(general.hitRatio == 0.75)
        #expect(general.role == "master")
        #expect(general.databases == 16)
        #expect(DatabaseInfoService.detectProvider(host: "10.1.2.3", info: info) == .redisCommunityEdition)
    }

    @Test func providerDetection() {
        #expect(DatabaseInfoService.detectProvider(host: "x.cache.amazonaws.com", info: nil) == .awsElastiCache)
        #expect(DatabaseInfoService.detectProvider(host: "redis-1.c1.us-east-1.redns.redis-cloud.com", info: nil) == .redisCloud)
        #expect(DatabaseInfoService.detectProvider(host: "a.redisenterprise.cache.azure.net", info: nil) == .azureCacheRedisEnterprise)
        #expect(DatabaseInfoService.detectProvider(host: "a.redis.cache.windows.net", info: nil) == .azureCache)
        #expect(DatabaseInfoService.detectProvider(host: "localhost", info: nil) == .localhost)
        #expect(DatabaseInfoService.detectProvider(host: "192.168.1.5", info: nil) == .localhost)
        #expect(DatabaseInfoService.detectProvider(host: "example.com", info: nil) == .unknown)
        let valkey = ServerInfoParser.parse("# Server\r\nserver_name:valkey\r\n")
        #expect(DatabaseInfoService.detectProvider(host: "example.com", info: valkey) == .valkey)
    }

    @Test func parsesModuleList() {
        let reply = RESPValue.array([
            .array([.bulk("name"), .bulk("search"), .bulk("ver"), .integer(81001), .bulk("path"), .bulk("/x")]),
            .array([.bulk("name"), .bulk("ReJSON"), .bulk("ver"), .integer(20811)]),
            .array([.bulk("name"), .bulk("vectorset"), .bulk("ver"), .integer(1)]),
        ])
        let modules = DatabaseInfoService.parseModuleList(reply, flavor: .redis)
        #expect(modules.map(\.name) == ["search", "ReJSON", "vectorset"])
        #expect(modules[0].semanticVersion == "8.10.1")
        #expect(modules[1].semanticVersion == "2.8.11")
        #expect(modules[2].semanticVersion == nil)
        #expect(DatabaseInfoService.semanticVersion(10203) == "1.2.3")
        let caps = DatabaseCapabilities(redisVersion: "8.10.2", modules: modules)
        #expect(caps.hasSearch && caps.hasJSON && !caps.hasTimeSeries)
        #expect(caps.jsonMajorVersion == 2)
        #expect(caps.supportsVectorSets)
    }

    @Test func overviewAggregation() {
        let a = ServerInfoParser.parse(Self.sample)
        let sample = DatabaseOverviewService.NodeSample(endpoint: RedisEndpoint(host: "h", port: 1), role: .primary,
                                                        info: a, dbSize: nil, ioThreads: 2)
        let overview = DatabaseOverviewService.aggregate([sample], isCluster: false, dbIndex: 3)
        #expect(overview.version == "8.10.2")
        #expect(overview.totalKeys == 15)
        #expect(overview.totalKeysPerDb == ["db3": 5])
        #expect(overview.usedMemory == 2048)
        #expect(overview.connectedClients == 4)
        #expect(overview.opsPerSecond == 12)
        #expect(overview.networkInKbps == 1.5)
        #expect(overview.maxCpuUsagePercentage == 200)

        var b = sample
        b.endpoint = RedisEndpoint(host: "h", port: 2)
        b.dbSize = 7
        var replica = sample
        replica.endpoint = RedisEndpoint(host: "h", port: 3)
        replica.role = .replica
        replica.info.sections["replication"] = ["role": "slave"]
        replica.info.sections["clients"] = ["connected_clients": "10"]
        var first = sample
        first.dbSize = 3
        let cluster = DatabaseOverviewService.aggregate([first, b, replica], isCluster: true, dbIndex: 0)
        #expect(cluster.totalKeys == 10)
        #expect(cluster.usedMemory == 4096)
        #expect(cluster.connectedClients == 4)
        #expect(cluster.opsPerSecond == 36)
    }

    @Test func versionComparisons() {
        #expect(RedisVersion("7.4.0")! > RedisVersion("7.2.10")!)
        #expect(RedisVersion("8.0.3")?.isAtLeast("8.0.3") == true)
        #expect(RedisVersion("x") == nil)
    }
}

struct ConnectionErrorTests {
    let endpoint = RedisEndpoint(host: "h", port: 1)

    @Test func classifiesClientErrors() {
        #expect(ConnectionError.classify(RedisClientError.timeout, endpoint: endpoint) == .timeout)
        #expect(ConnectionError.classify(RedisClientError.authenticationFailed("WRONGPASS"), endpoint: endpoint) == .unauthorized)
        #expect(ConnectionError.classify(RedisClientError.connectionFailed("connect ECONNREFUSED h:1"), endpoint: endpoint).code == .unavailable)
        #expect(ConnectionError.classify(RedisClientError.tlsFailure("x"), endpoint: endpoint).code == .incorrectCertificate)
        #expect(ConnectionError.classify(RedisClientError.clusterNodeUnavailable(endpoint), endpoint: endpoint) == .clusterNodesUnavailable)
        #expect(ConnectionError.classify(RedisClientError.ssh("boom"), endpoint: endpoint).code == .sshConnection)
        #expect(ConnectionError.classify(RedisClientError.server(RESPError("NOAUTH Authentication required.")), endpoint: endpoint) == .unauthorized)
        #expect(ConnectionError.classify(RedisClientError.server(RESPError("ERR unknown command 'auth'")), endpoint: endpoint) == .authUnsupported)
        #expect(ConnectionError.classify(DatabaseFactoryError.sentinelMasterRequired, endpoint: endpoint) == .sentinelMasterRequired)
        let other = ConnectionError.classify(RedisClientError.protocolError("weird"), endpoint: endpoint)
        #expect(other.code == .failed)
        #expect(other.message.hasPrefix("Couldn't connect to the Redis server.\n"))
        #expect(ConnectionError.classify(RedisClientError.connectionClosed, endpoint: endpoint).message.contains("Server closed the connection."))
    }
}

struct WorkbenchScriptParserTests {
    @Test func splitsContinuationsAndComments() throws {
        let script = """
        SET a 1
        // a comment
        FT.CREATE idx
          ON HASH
          // indented comment
          SCHEMA name TEXT
        SET url "http://x" // trailing
        3 INCR c
        0 INCR d

        """
        let commands = try WorkbenchScriptParser.parse(script)
        #expect(commands == [
            "SET a 1",
            "FT.CREATE idx\n  ON HASH\n  SCHEMA name TEXT",
            "SET url \"http://x\"",
            "INCR c", "INCR c", "INCR c",
            "0 INCR d",
        ])
        #expect(WorkbenchScriptParser.multilineToOneLine(commands[1]) == "FT.CREATE idx ON HASH SCHEMA name TEXT")
        #expect(WorkbenchScriptParser.hasInvalidRepeat("0 INCR d"))
        #expect(!WorkbenchScriptParser.hasInvalidRepeat("INCR 10"))
        #expect(WorkbenchScriptParser.repeatCount("10 GET k").command == "GET k")
        #expect(WorkbenchScriptParser.repeatCount("10 GET k").count == 10)
        #expect(WorkbenchScriptParser.repeatCount("1.5 GET k").count == 0)
    }

    @Test func argumentsAreWhatTheExecutorSends() {
        #expect(WorkbenchScriptParser.arguments(of: #""\x46LUSHDB""#) == ["FLUSHDB"])
        #expect(WorkbenchScriptParser.arguments(of: "CONFIG\n  SET maxmemory 1") == ["CONFIG", "SET", "maxmemory", "1"])
        #expect(WorkbenchScriptParser.arguments(of: #"'SELECT' "3""#) == ["SELECT", "3"])
        #expect(WorkbenchScriptParser.arguments(of: #"GET "a"#) == nil)
        #expect(WorkbenchScriptParser.arguments(of: "  ") == [])
    }

    @Test func paramsLine() throws {
        let script = "[pipeline=3;mode=raw;results=group;run_confirmation=true;executable=false;bogus=1] GET a\nGET b"
        let params = try #require(WorkbenchScriptParser.parseParams(script))
        #expect(params.batchSize == 3)
        #expect(params.mode == .raw)
        #expect(params.resultsMode == .group)
        #expect(params.runConfirmation == true)
        #expect(params.executable == false)
        #expect(try WorkbenchScriptParser.parse(script) == ["GET a", "GET b"])
        #expect(WorkbenchScriptParser.parseParams("GET a") == nil)
        #expect(WorkbenchScriptParser.parseParams("[results=silent; mode = ASCII]")?.resultsMode == .silent)
        #expect(WorkbenchScriptParser.parseParams("[results=silent; mode = ASCII]")?.mode == .ascii)
    }
}

struct KeyPatternTests {
    @Test func globDetection() {
        #expect(KeyPattern.isGlob("*"))
        #expect(KeyPattern.isGlob("user:?"))
        #expect(KeyPattern.isGlob("a[bc]"))
        #expect(!KeyPattern.isGlob("a[bc"))
        #expect(!KeyPattern.isGlob(#"key\*"#))
        #expect(!KeyPattern.isGlob("plain:key"))
        #expect(KeyPattern.unescape(#"a\*b\?c\[d\]e\\f"#) == #"a*b?c[d]e\f"#)
        #expect(KeyPattern.escape("a*b") == #"a\*b"#)
    }

    @Test func scanStateCompletion() {
        var state = KeyScanState()
        #expect(!state.isComplete)
        state.hasStarted = true
        #expect(state.isComplete)
        state.cursor = .cluster([RedisEndpoint(host: "a", port: 1): 5])
        #expect(!state.isComplete)
    }
}

struct SearchInfoParsingTests {
    @Test func parsesFTInfo() {
        let reply = RESPValue.array([
            .bulk("index_name"), .bulk("idx"),
            .bulk("index_options"), .array([]),
            .bulk("index_definition"), .array([.bulk("key_type"), .bulk("HASH"), .bulk("prefixes"), .array([.bulk("bike:")]),
                                                .bulk("default_score"), .bulk("1")]),
            .bulk("attributes"), .array([
                .array([.bulk("identifier"), .bulk("name"), .bulk("attribute"), .bulk("name"), .bulk("type"), .bulk("TEXT"),
                        .bulk("WEIGHT"), .bulk("1"), .bulk("SORTABLE")]),
                .array([.bulk("identifier"), .bulk("v"), .bulk("attribute"), .bulk("v"), .bulk("type"), .bulk("VECTOR"),
                        .bulk("algorithm"), .bulk("FLAT"), .bulk("dim"), .bulk("4")]),
            ]),
            .bulk("num_docs"), .bulk("12"),
            .bulk("max_doc_id"), .integer(14),
            .bulk("num_records"), .bulk("1.2e2"),
        ])
        let info = SearchIndexService.parseInfo(reply, name: Data("idx".utf8))
        #expect(info.keyType == .hash)
        #expect(info.prefixes == ["bike:"])
        #expect(info.numDocs == 12)
        #expect(info.maxDocId == 14)
        #expect(info.numRecords == 120)
        #expect(info.attributes.count == 2)
        #expect(info.attributes[0].flags == ["SORTABLE"])
        #expect(info.attributes[0].weight == "1")
        #expect(info.attributes[0].fieldType == .text)
        #expect(info.attributes[1].raw["dim"] == "4")
        #expect(info.attributes[1].type == "vector")
        #expect(SearchIndexService.parseConfigNumber(.array([.array([.bulk("MAXSEARCHRESULTS"), .bulk("10000")])])) == 10_000)
        #expect(SearchIndexService.parseConfigNumber(.array([.array([.bulk("MAXSEARCHRESULTS"), .bulk("-1")])])) == nil)
    }
}

struct KeyTypeHelperTests {
    @Test func creatableTypesFollowCapabilities() {
        let bare = DatabaseCapabilities(redisVersion: "7.2.0")
        #expect(KeyType.hash.isCreatable(with: bare))
        #expect(!KeyType.json.isCreatable(with: bare))
        #expect(!KeyType.vectorSet.isCreatable(with: bare))
        let full = DatabaseCapabilities(redisVersion: "8.0.0", modules: [RedisModuleInfo(name: "ReJSON"), RedisModuleInfo(name: "timeseries")])
        #expect(KeyType.json.isCreatable(with: full))
        #expect(KeyType.timeSeries.isCreatable(with: full))
        #expect(KeyType.vectorSet.isCreatable(with: full))
        #expect(!KeyType.graph.isCreatable(with: full))
        #expect(NewKeyDraft(name: Data(), value: .timeSeries(TimeSeriesDraft())).type == .timeSeries)
    }
}
